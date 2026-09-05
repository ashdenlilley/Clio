import AppKit
import Darwin
import Foundation
import XCTest

@testable import Clio

@MainActor
final class CrashSafetyTests: XCTestCase {
  struct InjectedCrash: Error {}

  func testDirtyDebounceSchedulesNewestGenerationInDurableJournal() throws {
    try withRoots { workspaceURL, journalURL, _ in
      let fileURL = workspaceURL.appendingPathComponent("draft.md")
      try Data("base".utf8).write(to: fileURL)
      let journal = CrashRecoveryJournal(rootURL: journalURL)
      let workspace = try Workspace(
        rootURL: workspaceURL,
        accessSecurityScopedResource: false,
        crashRecoveryJournal: journal
      )
      let document = try workspace.loadDocument(at: fileURL)
      let autosaver = Autosaver(workspace: workspace, delay: .seconds(30))

      document.replaceText(with: "first")
      autosaver.documentDidChange(document)
      document.replaceText(with: "newest \u{1F642}")
      autosaver.documentDidChange(document)
      journal.flush()

      let records = try journal.validRecords().filter { $0.documentID == document.id }
      XCTAssertEqual(records.last?.data, Data("newest \u{1F642}".utf8))
      XCTAssertEqual(records.last?.generation.revision, document.revision)
      autosaver.cancel()
    }
  }

  func testMalformedJournalRecordIsNeverDeleted() throws {
    try withRoots { _, journalURL, _ in
      try FileManager.default.createDirectory(
        at: journalURL,
        withIntermediateDirectories: true
      )
      let malformed = journalURL.appendingPathComponent(
        "buffer-malformed.clio-recovery"
      )
      let bytes = Data([0x00, 0xFF, 0x01, 0x7F])
      try bytes.write(to: malformed)

      let journal = CrashRecoveryJournal(rootURL: journalURL)
      XCTAssertTrue(try journal.validRecords().isEmpty)
      XCTAssertEqual(try Data(contentsOf: malformed), bytes)
    }
  }

  func testRapidGenerationsCoalesceToOneNewestDurableRecord() throws {
    try withRoots { _, journalURL, _ in
      let journal = CrashRecoveryJournal(rootURL: journalURL)
      let documentID = DocumentID()
      let payload = String(repeating: "x", count: 64 * 1_024)
      for revision in 1...100 {
        journal.schedule(
          CrashRecoverySnapshot(
            documentID: documentID,
            generation: BufferGeneration(
              bufferID: documentID.rawValue,
              revision: UInt64(revision)
            ),
            filename: "draft.md",
            targetURL: nil,
            reason: .dirtyBuffer,
            source: "\(revision):\(payload)"
          ))
      }
      journal.flush()

      let records = try journal.validRecords().filter { $0.documentID == documentID }
      XCTAssertEqual(records.count, 1)
      XCTAssertEqual(records[0].generation.revision, 100)
      XCTAssertEqual(
        records[0].data,
        Data("100:\(payload)".utf8)
      )
      let bytes = try FileManager.default.contentsOfDirectory(
        at: journalURL,
        includingPropertiesForKeys: [.fileSizeKey]
      ).reduce(Int64(0)) { partial, url in
        partial
          + Int64(
            (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
          )
      }
      XCTAssertLessThan(bytes, Int64(payload.utf8.count * 2))
    }
  }

  func testSuccessfulAutosaveClearsOnlyRedundantDirtyCheckpoint() throws {
    try withRoots { _, journalURL, _ in
      let journal = CrashRecoveryJournal(rootURL: journalURL)
      let documentID = DocumentID()
      let generation = BufferGeneration(bufferID: documentID.rawValue, revision: 9)
      _ = try journal.checkpoint(
        CrashRecoveryRecord(
          documentID: documentID,
          generation: generation,
          filename: "draft.md",
          targetURL: nil,
          reason: .dirtyBuffer,
          data: Data("canonical candidate".utf8)
        ))
      _ = try journal.checkpoint(
        CrashRecoveryRecord(
          documentID: documentID,
          generation: generation,
          filename: "draft.md",
          targetURL: nil,
          reason: .interruptedMove,
          data: Data("outside source".utf8)
        ))

      journal.clear(documentID: documentID, through: 9)
      journal.flush()

      let records = try journal.validRecords()
      XCTAssertEqual(records.count, 1)
      XCTAssertEqual(records[0].reason, .interruptedMove)
      XCTAssertEqual(records[0].data, Data("outside source".utf8))
    }
  }

  func testAtomicKillPointsRecoverEveryUniqueByteSequence() throws {
    for phase in [
      AtomicWritePhase.manifestSynced,
      .candidateSynced,
      .swapped,
      .parentSynced,
    ] {
      try withRoots { workspaceURL, journalURL, _ in
        let destination = workspaceURL.appendingPathComponent("draft.md")
        try Data("outside-base".utf8).write(to: destination)
        let expected = try DocumentRevisionReader.revision(at: destination)
        let writer = AtomicFileWriter(phaseHook: { current in
          if current == phase { throw InjectedCrash() }
        })

        XCTAssertThrowsError(
          try writer.replace(
            contents: Data("latest-local".utf8),
            at: destination,
            onlyIf: expected
          ))

        let journal = CrashRecoveryJournal(rootURL: journalURL)
        _ = try AtomicWriteTransactions.recoverInterruptedTransactions(
          in: workspaceURL,
          journal: journal
        )
        let canonical = try String(contentsOf: destination, encoding: .utf8)
        let recovered = try journal.validRecords().compactMap {
          String(data: $0.data, encoding: .utf8)
        }
        let required =
          phase == .manifestSynced
          ? Set(["outside-base"])
          : Set(["outside-base", "latest-local"])
        XCTAssertTrue(
          Set([canonical] + recovered).isSuperset(of: required),
          "phase \(phase.rawValue) lost bytes"
        )
        XCTAssertTrue(try transactionArtifacts(in: workspaceURL).isEmpty)
      }
    }
  }

  func testSIGKILLSubprocessPersistsJournalAndAtomicCandidate() throws {
    let physicalHome = try XCTUnwrap(
      FileManager.default.homeDirectory(forUser: NSUserName())
    )
    let root = physicalHome
      .appendingPathComponent("Library/Containers/olympus.clio.mac/Data/tmp", isDirectory: true)
      .appendingPathComponent("ClioCrashSafety-\(UUID().uuidString)", isDirectory: true)
    let workspaceURL = root.appendingPathComponent("Workspace", isDirectory: true)
    let journalURL = root.appendingPathComponent("Journal", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try runCrashSubprocess(mode: "journal", rootURL: journalURL)
    let journal = CrashRecoveryJournal(rootURL: journalURL)
    XCTAssertTrue(
      try journal.validRecords().contains {
        $0.data == Data("subprocess dirty generation".utf8)
          && $0.generation.revision == 41
      })

    let destination = workspaceURL.appendingPathComponent("draft.md")
    try Data("subprocess outside base".utf8).write(to: destination)
    try runCrashSubprocess(mode: "atomic-candidate", rootURL: workspaceURL)
    _ = try AtomicWriteTransactions.recoverInterruptedTransactions(
      in: workspaceURL,
      journal: journal
    )
    let allBytes = try journal.validRecords().map(\.data)
    XCTAssertTrue(allBytes.contains(Data("subprocess atomic candidate".utf8)))
    XCTAssertEqual(
      try String(contentsOf: destination, encoding: .utf8),
      "subprocess outside base"
    )
    XCTAssertTrue(try transactionArtifacts(in: workspaceURL).isEmpty)
  }

  func testMaliciousTransactionManifestAndSymlinkAreLeftUntouched() throws {
    try withRoots { workspaceURL, journalURL, _ in
      let outside = workspaceURL.deletingLastPathComponent()
        .appendingPathComponent("outside.md")
      let outsideBytes = Data("do-not-touch".utf8)
      try outsideBytes.write(to: outside)
      let id = UUID()
      let temporary = workspaceURL.appendingPathComponent(
        AtomicWriteTransactions.temporaryPrefix + id.uuidString.lowercased()
      )
      try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: outside)
      let destination = workspaceURL.appendingPathComponent("draft.md")
      try Data("base".utf8).write(to: destination)
      let manifest = AtomicWriteTransactionManifest(
        schemaVersion: AtomicWriteTransactionManifest.schemaVersion,
        id: id,
        operation: .replace,
        destinationURL: destination,
        temporaryURL: temporary,
        candidateByteCount: Int64(outsideBytes.count),
        candidateDigest: DocumentRevisionReader.digest(outsideBytes),
        expectedRevision: try DocumentRevisionReader.revision(at: destination),
        createdAt: Date()
      )
      let manifestURL = workspaceURL.appendingPathComponent(
        AtomicWriteTransactions.manifestPrefix
          + id.uuidString.lowercased()
          + AtomicWriteTransactions.manifestSuffix
      )
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      try encoder.encode(manifest).write(to: manifestURL)

      _ = try AtomicWriteTransactions.recoverInterruptedTransactions(
        in: workspaceURL,
        journal: CrashRecoveryJournal(rootURL: journalURL)
      )

      XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
      XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: temporary.path),
        outside.path
      )
    }
  }

  func testStaleReplaceApprovalReturnsRefreshedCollision() async throws {
    try await withRootsAsync { workspaceURL, _, recoveryURL in
      let destinationRoot = workspaceURL.appendingPathComponent("Destination")
      try FileManager.default.createDirectory(
        at: destinationRoot,
        withIntermediateDirectories: true
      )
      let sourceURL = workspaceURL.appendingPathComponent("draft.md")
      let destinationURL = destinationRoot.appendingPathComponent("draft.md")
      try Data("moving".utf8).write(to: sourceURL)
      try Data("first occupant".utf8).write(to: destinationURL)
      let source = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
      let destination = try Workspace(rootURL: destinationRoot, accessSecurityScopedResource: false)
      let document = try source.loadDocument(at: sourceURL)
      let mover = DocumentMover(recoveryStore: RecoveryStore(rootURL: recoveryURL))
      let proposal = try await mover.move(document, from: source, to: destination)
      guard case .collision(let approval) = proposal else {
        return XCTFail("Expected collision")
      }

      try Data("late occupant".utf8).write(to: destinationURL, options: .atomic)
      let outcome = try await mover.move(
        document,
        from: source,
        to: destination,
        collisionChoice: .replace,
        approvedCollision: approval
      )

      guard case .collision(let refreshed) = outcome else {
        return XCTFail("Expected refreshed collision")
      }
      XCTAssertNotEqual(refreshed.existingRevision, approval.existingRevision)
      XCTAssertEqual(try String(contentsOf: destinationURL), "late occupant")
      XCTAssertEqual(try String(contentsOf: sourceURL), "moving")
    }
  }

  func testCrossWorkspaceRecoveryWaitsForBothAuthorizedRoots() throws {
    try withRoots { sourceRoot, journalURL, _ in
      let destinationRoot = sourceRoot.deletingLastPathComponent()
        .appendingPathComponent("Destination", isDirectory: true)
      try FileManager.default.createDirectory(
        at: destinationRoot,
        withIntermediateDirectories: true
      )
      let sourceURL = sourceRoot.appendingPathComponent("draft.md")
      let destinationURL = destinationRoot.appendingPathComponent("draft.md")
      let sourceData = Data("source inode".utf8)
      let displacedData = Data("old destination".utf8)
      let candidate = Data("installed candidate".utf8)
      try sourceData.write(to: sourceURL)
      try displacedData.write(to: destinationURL)
      let sourceRevision = try DocumentRevisionReader.revision(at: sourceURL)
      let destinationRevision = try DocumentRevisionReader.revision(at: destinationURL)
      let documentID = DocumentID()
      let transaction = try InterruptedMoveTransactions.begin(
        documentID: documentID,
        generation: BufferGeneration(bufferID: documentID.rawValue, revision: 7),
        sourceRootURL: sourceRoot,
        destinationRootURL: destinationRoot,
        sourceURL: sourceURL,
        destinationURL: destinationURL,
        sourceRevision: sourceRevision,
        destinationRevision: destinationRevision,
        candidate: candidate
      )
      // Kill point: destination committed, source not yet quarantined.
      try candidate.write(to: destinationURL, options: .atomic)
      let journal = CrashRecoveryJournal(rootURL: journalURL)

      XCTAssertEqual(
        try InterruptedMoveTransactions.recover(in: sourceRoot, journal: journal),
        0
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.manifestURL.path))

      XCTAssertEqual(
        try InterruptedMoveTransactions.recover(
          inAuthorizedRoots: [sourceRoot, destinationRoot],
          journal: journal
        ),
        1
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.manifestURL.path))
      XCTAssertEqual(try Data(contentsOf: destinationURL), candidate)
      XCTAssertTrue(try journal.validRecords().contains { $0.data == sourceData })
    }
  }

  func testLateSourceEditDuringReplaceIsJournaledBeforeCleanup() async throws {
    try await withRootsAsync { workspaceURL, journalURL, recoveryURL in
      let destinationRoot = workspaceURL.appendingPathComponent("Destination")
      try FileManager.default.createDirectory(
        at: destinationRoot,
        withIntermediateDirectories: true
      )
      let sourceURL = workspaceURL.appendingPathComponent("draft.md")
      let destinationURL = destinationRoot.appendingPathComponent("draft.md")
      try Data("moving".utf8).write(to: sourceURL)
      try Data("occupied".utf8).write(to: destinationURL)
      let journal = CrashRecoveryJournal(rootURL: journalURL)
      let source = try Workspace(
        rootURL: workspaceURL,
        accessSecurityScopedResource: false,
        crashRecoveryJournal: journal
      )
      let destination = try Workspace(
        rootURL: destinationRoot,
        accessSecurityScopedResource: false,
        crashRecoveryJournal: journal
      )
      let document = try source.loadDocument(at: sourceURL)
      let writer = AtomicFileWriter(afterSwap: {
        try Data("late outside edit".utf8).write(to: sourceURL, options: .atomic)
      })
      let mover = DocumentMover(
        recoveryStore: RecoveryStore(rootURL: recoveryURL),
        writer: writer
      )
      let proposal = try await mover.move(document, from: source, to: destination)
      guard case .collision(let approval) = proposal else {
        return XCTFail("Expected collision")
      }

      let outcome = try await mover.move(
        document,
        from: source,
        to: destination,
        collisionChoice: .replace,
        approvedCollision: approval
      )

      guard case .completedWithRecovery = outcome else {
        return XCTFail("Expected a recovery notice")
      }
      journal.flush()
      XCTAssertEqual(try String(contentsOf: destinationURL), "moving")
      XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
      XCTAssertTrue(
        try journal.validRecords().contains {
          $0.data == Data("late outside edit".utf8)
        })
    }
  }

  func testLateSourceEditDuringKeepBothIsJournaledBeforeCleanup() async throws {
    try await withRootsAsync { workspaceURL, journalURL, recoveryURL in
      let destinationRoot = workspaceURL.appendingPathComponent("Destination")
      try FileManager.default.createDirectory(
        at: destinationRoot,
        withIntermediateDirectories: true
      )
      let sourceURL = workspaceURL.appendingPathComponent("draft.md")
      let occupiedURL = destinationRoot.appendingPathComponent("draft.md")
      let keptURL = destinationRoot.appendingPathComponent("draft (2).md")
      try Data("moving".utf8).write(to: sourceURL)
      try Data("occupied".utf8).write(to: occupiedURL)
      let journal = CrashRecoveryJournal(rootURL: journalURL)
      let source = try Workspace(
        rootURL: workspaceURL,
        accessSecurityScopedResource: false,
        crashRecoveryJournal: journal
      )
      let destination = try Workspace(
        rootURL: destinationRoot,
        accessSecurityScopedResource: false,
        crashRecoveryJournal: journal
      )
      let document = try source.loadDocument(at: sourceURL)
      let writer = AtomicFileWriter(phaseHook: { phase in
        if phase == .swapped {
          try Data("late keep-both edit".utf8).write(
            to: sourceURL,
            options: .atomic
          )
        }
      })
      let mover = DocumentMover(
        recoveryStore: RecoveryStore(rootURL: recoveryURL),
        writer: writer
      )

      let outcome = try await mover.move(
        document,
        from: source,
        to: destination,
        collisionChoice: .keepBoth
      )

      guard case .completedWithRecovery = outcome else {
        return XCTFail("Expected a recovery notice")
      }
      XCTAssertEqual(try String(contentsOf: occupiedURL), "occupied")
      XCTAssertEqual(try String(contentsOf: keptURL), "moving")
      XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
      XCTAssertTrue(
        try journal.validRecords().contains {
          $0.data == Data("late keep-both edit".utf8)
        })
    }
  }

  func testAsynchronousJournalFailureIsPersistentUserVisibleState() async throws {
    try await withRootsAsync { _, journalURL, recoveryURL in
      try Data("not a directory".utf8).write(to: journalURL)
      let journal = CrashRecoveryJournal(rootURL: journalURL)
      let state = isolatedAppState(
        defaults: UserDefaults(suiteName: "ClioCrashSafety.\(UUID().uuidString)")!,
        recoveryStore: RecoveryStore(rootURL: recoveryURL),
        crashRecoveryJournal: journal
      )
      let documentID = DocumentID()
      journal.schedule(
        CrashRecoverySnapshot(
          documentID: documentID,
          generation: BufferGeneration(bufferID: documentID.rawValue, revision: 1),
          filename: "draft.md",
          targetURL: nil,
          reason: .dirtyBuffer,
          source: "must survive"
        ))
      journal.flush()
      try await waitUntil { state.isCrashRecoveryDurabilityCompromised }

      XCTAssertNotNil(state.crashRecoveryMessage)
      state.dismissTransientMessage()
      XCTAssertNotNil(state.crashRecoveryMessage)

      try FileManager.default.removeItem(at: journalURL)
      journal.schedule(
        CrashRecoverySnapshot(
          documentID: documentID,
          generation: BufferGeneration(bufferID: documentID.rawValue, revision: 2),
          filename: "draft.md",
          targetURL: nil,
          reason: .dirtyBuffer,
          source: "now durable"
        ))
      journal.flush()
      try await waitUntil { !state.isCrashRecoveryDurabilityCompromised }
      state.dismissTransientMessage()
      XCTAssertNil(state.crashRecoveryMessage)
    }
  }

  func testRecoveredCrashBannerCanBeDismissed() async throws {
    try await withRootsAsync { _, journalURL, recoveryURL in
      let journal = CrashRecoveryJournal(rootURL: journalURL)
      let documentID = DocumentID()
      _ = try journal.checkpoint(
        CrashRecoveryRecord(
          documentID: documentID,
          generation: BufferGeneration(bufferID: documentID.rawValue, revision: 4),
          filename: "draft.md",
          targetURL: nil,
          reason: .dirtyBuffer,
          data: Data("relaunch bytes".utf8)
        ))
      let state = isolatedAppState(
        defaults: UserDefaults(suiteName: "ClioCrashSafety.\(UUID().uuidString)")!,
        recoveryStore: RecoveryStore(rootURL: recoveryURL),
        crashRecoveryJournal: journal
      )

      try await waitUntil { state.recoveredCrashBufferCount == 1 }
      XCTAssertNotNil(state.crashRecoveryMessage)
      state.dismissTransientMessage()
      XCTAssertNil(state.crashRecoveryMessage)
      let recovered = try FileManager.default.contentsOfDirectory(
        at: recoveryURL,
        includingPropertiesForKeys: nil
      )
      XCTAssertEqual(recovered.count, 1)
      XCTAssertEqual(try Data(contentsOf: recovered[0]), Data("relaunch bytes".utf8))
    }
  }

  func testApplicationTerminationFlushesNewestScheduledGeneration() async throws {
    try await withRootsAsync { workspaceURL, journalURL, recoveryURL in
      let fileURL = workspaceURL.appendingPathComponent("draft.md")
      try Data("base".utf8).write(to: fileURL)
      let journal = CrashRecoveryJournal(rootURL: journalURL)
      let workspace = try Workspace(
        rootURL: workspaceURL,
        accessSecurityScopedResource: false,
        crashRecoveryJournal: journal
      )
      let state = isolatedAppState(
        defaults: UserDefaults(suiteName: "ClioCrashSafety.\(UUID().uuidString)")!,
        initialWorkspace: workspace,
        recoveryStore: RecoveryStore(rootURL: recoveryURL),
        crashRecoveryJournal: journal
      )
      let session = EditorSession()
      state.register(session)
      try await waitUntil { session.document != nil }
      session.editorTextDidChange("newest before termination")
      let delegate = ClioApplicationDelegate(appState: state)

      XCTAssertEqual(
        delegate.applicationShouldTerminate(NSApplication.shared),
        .terminateNow
      )
      journal.flush()
      XCTAssertEqual(try String(contentsOf: fileURL), "newest before termination")
      XCTAssertTrue(try journal.validRecords().isEmpty)
    }
  }
}

extension CrashSafetyTests {
  fileprivate func withRoots<T>(
    _ operation: (URL, URL, URL) throws -> T
  ) throws -> T {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClioCrashSafety-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
    let journal = root.appendingPathComponent("Journal", isDirectory: true)
    let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try operation(workspace, journal, recovery)
  }

  fileprivate func withRootsAsync<T>(
    _ operation: (URL, URL, URL) async throws -> T
  ) async throws -> T {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClioCrashSafety-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
    let journal = root.appendingPathComponent("Journal", isDirectory: true)
    let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await operation(workspace, journal, recovery)
  }

  fileprivate func transactionArtifacts(in root: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter {
        $0.lastPathComponent.hasPrefix(AtomicWriteTransactions.manifestPrefix)
          || $0.lastPathComponent.hasPrefix(AtomicWriteTransactions.temporaryPrefix)
      }
  }

  fileprivate func runCrashSubprocess(mode: String, rootURL: URL) throws {
    let executable = try XCTUnwrap(
      Bundle(for: CrashSafetyTests.self).url(forResource: "ClioCrashProbe", withExtension: nil)
    )
    let process = Process()
    process.executableURL = executable
    // Do not inject XCTest/DYLD libraries or Cloud release secrets into the probe.
    var environment: [String: String] = [:]
    environment["CLIO_CRASH_TEST_MODE"] = mode
    environment["CLIO_CRASH_TEST_ROOT"] = rootURL.path
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    let diagnosticURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("probe-\(UUID().uuidString).stderr")
    FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil)
    let diagnostic = try FileHandle(forWritingTo: diagnosticURL)
    defer {
      try? diagnostic.close()
      try? FileManager.default.removeItem(at: diagnosticURL)
    }
    process.standardError = diagnostic
    try process.run()
    let deadline = Date().addingTimeInterval(15)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    let timedOut = process.isRunning
    if timedOut { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    XCTAssertFalse(timedOut, "Crash probe timed out before its intentional SIGKILL")
    if timedOut || process.terminationStatus != SIGKILL {
      let data = (try? Data(contentsOf: diagnosticURL)) ?? Data()
      let attachment = XCTAttachment(string: String(decoding: data.prefix(16_384), as: UTF8.self))
      attachment.name = "Crash probe stderr (\(mode))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    XCTAssertEqual(process.terminationStatus, SIGKILL)
  }

  fileprivate func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
