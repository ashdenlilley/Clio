import Darwin
import Foundation

enum AtomicWriteOperation: String, Codable, Sendable {
  case create
  case replace
}

enum AtomicWritePhase: String, Sendable {
  case manifestSynced
  case candidateSynced
  case swapped
  case validated
  case parentSynced
}

struct AtomicWriteTransactionManifest: Codable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let id: UUID
  let operation: AtomicWriteOperation
  let destinationURL: URL
  let temporaryURL: URL
  let candidateByteCount: Int64
  let candidateDigest: String
  let expectedRevision: DiskRevision?
  let createdAt: Date
}

struct AtomicWriteTransactionContext: Sendable {
  let manifest: AtomicWriteTransactionManifest
  let manifestURL: URL
}

enum AtomicWriteTransactions {
  static let manifestPrefix = ".clio-transaction-"
  static let manifestSuffix = ".plist"
  static let temporaryPrefix = ".clio-save-"
  static let maximumRecoverableByteCount = Int64(
    PerformanceContract.safeLargeFileByteLimit * 4
  )

  static func begin(
    contents: Data,
    destinationURL: URL,
    operation: AtomicWriteOperation,
    expectedRevision: DiskRevision?
  ) throws -> AtomicWriteTransactionContext {
    let destination = destinationURL.standardizedFileURL
    let id = UUID()
    let parent = destination.deletingLastPathComponent()
    try rejectSymlink(destination)
    try rejectSymlink(parent)
    let temporaryURL = parent.appendingPathComponent(temporaryPrefix + id.uuidString.lowercased())
    let manifestURL = parent.appendingPathComponent(
      manifestPrefix + id.uuidString.lowercased() + manifestSuffix
    )
    let manifest = AtomicWriteTransactionManifest(
      schemaVersion: AtomicWriteTransactionManifest.schemaVersion,
      id: id,
      operation: operation,
      destinationURL: destination,
      temporaryURL: temporaryURL,
      candidateByteCount: Int64(contents.count),
      candidateDigest: DocumentRevisionReader.digest(contents),
      expectedRevision: expectedRevision,
      createdAt: Date()
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(manifest).write(to: manifestURL, options: .withoutOverwriting)
    try syncFile(manifestURL)
    try syncDirectory(parent)
    return AtomicWriteTransactionContext(manifest: manifest, manifestURL: manifestURL)
  }

  static func finish(_ context: AtomicWriteTransactionContext, removeTemporary: Bool) throws {
    let parent = context.manifestURL.deletingLastPathComponent()
    if removeTemporary,
      FileManager.default.fileExists(atPath: context.manifest.temporaryURL.path)
    {
      try FileManager.default.removeItem(at: context.manifest.temporaryURL)
    }
    if FileManager.default.fileExists(atPath: context.manifestURL.path) {
      try FileManager.default.removeItem(at: context.manifestURL)
    }
    try syncDirectory(parent)
  }

  static func discardRetainedSidecar(at sidecarURL: URL) throws {
    let sidecar = sidecarURL.standardizedFileURL
    let name = sidecar.lastPathComponent
    guard name.hasPrefix(temporaryPrefix) else { return }
    let identifier = String(name.dropFirst(temporaryPrefix.count))
    guard UUID(uuidString: identifier) != nil else { return }
    let manifestURL = sidecar.deletingLastPathComponent().appendingPathComponent(
      manifestPrefix + identifier.lowercased() + manifestSuffix
    )
    if FileManager.default.fileExists(atPath: sidecar.path) {
      try FileManager.default.removeItem(at: sidecar)
    }
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      try FileManager.default.removeItem(at: manifestURL)
    }
    try syncDirectory(sidecar.deletingLastPathComponent())
  }

  @discardableResult
  static func recoverInterruptedTransactions(
    in rootURL: URL,
    journal: CrashRecoveryJournal
  ) throws -> Int {
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsPackageDescendants]
      )
    else { return 0 }

    var recovered = 0
    for case let url as URL in enumerator where isManifestName(url.lastPathComponent) {
      guard let manifest = validManifest(at: url, inside: root) else { continue }
      let recoveryLimit = max(
        manifest.candidateByteCount,
        manifest.expectedRevision?.byteCount ?? 0
      )
      guard recoveryLimit >= 0,
        recoveryLimit <= maximumRecoverableByteCount
      else { continue }
      let destination = snapshotIfSafe(
        at: manifest.destinationURL,
        inside: root,
        maximumByteCount: recoveryLimit
      )
      let temporary = snapshotIfSafe(
        at: manifest.temporaryURL,
        inside: root,
        maximumByteCount: recoveryLimit
      )
      let destinationIsCandidate =
        destination.map {
          matches(
            $0.revision, byteCount: manifest.candidateByteCount, digest: manifest.candidateDigest)
        } ?? false
      let temporaryIsCandidate =
        temporary.map {
          matches(
            $0.revision, byteCount: manifest.candidateByteCount, digest: manifest.candidateDigest)
        } ?? false
      let temporaryIsAbsent = isAbsent(manifest.temporaryURL)
      let destinationIsExpected =
        manifest.expectedRevision.map { expected in
          destination.map { Workspace.sameContent($0.revision, expected) } ?? false
        } ?? isAbsent(manifest.destinationURL)
      let temporaryIsExpected =
        manifest.expectedRevision.map { expected in
          temporary.map { Workspace.sameContent($0.revision, expected) } ?? false
        } ?? false

      if let temporary, temporaryIsCandidate || temporaryIsExpected {
        try checkpoint(
          temporary.data,
          manifest: manifest,
          reason: temporaryIsCandidate ? .atomicCandidate : .atomicDisplaced,
          journal: journal
        )
        recovered += 1
      }
      if destinationIsCandidate, temporaryIsAbsent {
        try checkpoint(
          destination!.data,
          manifest: manifest,
          reason: .atomicCandidate,
          journal: journal
        )
        recovered += 1
      }

      let recognizedPreCommit = temporaryIsCandidate && destinationIsExpected
      let recognizedInstalled =
        destinationIsCandidate
        && (temporaryIsAbsent || temporaryIsExpected)
      let recognizedManifestOnly = temporaryIsAbsent && destinationIsExpected
      if recognizedPreCommit || recognizedInstalled || recognizedManifestOnly {
        if temporary != nil {
          try FileManager.default.removeItem(at: manifest.temporaryURL)
        }
        try FileManager.default.removeItem(at: url)
        try syncDirectory(url.deletingLastPathComponent())
      }
    }
    return recovered
  }
}

extension AtomicWriteTransactions {
  fileprivate static func isManifestName(_ name: String) -> Bool {
    name.hasPrefix(manifestPrefix) && name.hasSuffix(manifestSuffix)
  }

  fileprivate static func validManifest(
    at manifestURL: URL,
    inside rootURL: URL
  ) -> AtomicWriteTransactionManifest? {
    guard isSafeRegularFile(manifestURL, inside: rootURL),
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? PropertyListDecoder().decode(
        AtomicWriteTransactionManifest.self,
        from: data
      ),
      manifest.schemaVersion == AtomicWriteTransactionManifest.schemaVersion,
      isContained(manifest.destinationURL, in: rootURL),
      isContained(manifest.temporaryURL, in: rootURL),
      manifest.destinationURL.deletingLastPathComponent().standardizedFileURL
        == manifest.temporaryURL.deletingLastPathComponent().standardizedFileURL,
      manifestURL.deletingLastPathComponent().standardizedFileURL
        == manifest.destinationURL.deletingLastPathComponent().standardizedFileURL,
      manifestURL.lastPathComponent
        == manifestPrefix + manifest.id.uuidString.lowercased() + manifestSuffix,
      manifest.temporaryURL.lastPathComponent
        == temporaryPrefix + manifest.id.uuidString.lowercased()
    else {
      return nil
    }
    return manifest
  }

  fileprivate static func snapshotIfSafe(
    at url: URL,
    inside rootURL: URL,
    maximumByteCount: Int64
  ) -> (data: Data, revision: DiskRevision)? {
    guard isSafeRegularFile(url, inside: rootURL) else { return nil }
    return try? DocumentRevisionReader.snapshot(
      at: url,
      maximumByteCount: maximumByteCount
    )
  }

  fileprivate static func isSafeRegularFile(_ url: URL, inside rootURL: URL) -> Bool {
    guard isContained(url, in: rootURL),
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  fileprivate static func isContained(_ url: URL, in rootURL: URL) -> Bool {
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return parent == root || parent.path.hasPrefix(prefix)
  }

  fileprivate static func isAbsent(_ url: URL) -> Bool {
    var status = stat()
    return url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      if lstat(path, &status) == 0 { return false }
      return errno == ENOENT
    }
  }

  fileprivate static func matches(_ revision: DiskRevision, byteCount: Int64, digest: String)
    -> Bool
  {
    revision.byteCount == byteCount && revision.contentDigest == digest
  }

  fileprivate static func checkpoint(
    _ data: Data,
    manifest: AtomicWriteTransactionManifest,
    reason: CrashRecoveryReason,
    journal: CrashRecoveryJournal
  ) throws {
    _ = try journal.checkpoint(
      CrashRecoveryRecord(
        documentID: DocumentID(rawValue: manifest.id),
        generation: BufferGeneration(bufferID: manifest.id, revision: 0),
        filename: manifest.destinationURL.lastPathComponent,
        targetURL: manifest.destinationURL,
        reason: reason,
        createdAt: manifest.createdAt,
        data: data
      ))
  }

  fileprivate static func rejectSymlink(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
  }

  fileprivate static func syncFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw posixError(for: url) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw posixError(for: url) }
  }

  fileprivate static func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { throw posixError(for: url) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw posixError(for: url) }
  }

  fileprivate static func posixError(for url: URL) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(errno),
      userInfo: [NSFilePathErrorKey: url.path]
    )
  }
}
