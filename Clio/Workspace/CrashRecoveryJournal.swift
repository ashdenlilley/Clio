import Darwin
import Foundation

enum CrashRecoveryReason: String, Codable, Sendable {
  case dirtyBuffer
  case saveFailed
  case externalConflict
  case externalDeletion
  case atomicCandidate
  case atomicDisplaced
  case interruptedMove
}

struct CrashRecoveryRecord: Codable, Hashable, Sendable, Identifiable {
  let id: UUID
  let documentID: DocumentID
  let generation: BufferGeneration
  let filename: String
  let targetURL: URL?
  let reason: CrashRecoveryReason
  let createdAt: Date
  let data: Data
  let contentDigest: String

  init(
    id: UUID = UUID(),
    documentID: DocumentID,
    generation: BufferGeneration,
    filename: String,
    targetURL: URL?,
    reason: CrashRecoveryReason,
    createdAt: Date = Date(),
    data: Data
  ) {
    self.id = id
    self.documentID = documentID
    self.generation = generation
    self.filename = filename
    self.targetURL = targetURL?.standardizedFileURL
    self.reason = reason
    self.createdAt = createdAt
    self.data = data
    contentDigest = DocumentRevisionReader.digest(data)
  }
}

/// A cheap MainActor hand-off. UTF-8 materialization and hashing happen on the
/// journal's utility queue so every keystroke can be scheduled without doing
/// whole-buffer work on the UI thread.
struct CrashRecoverySnapshot: Sendable {
  let id: UUID
  let documentID: DocumentID
  let generation: BufferGeneration
  let filename: String
  let targetURL: URL?
  let reason: CrashRecoveryReason
  let createdAt: Date
  let source: String

  init(
    id: UUID = UUID(),
    documentID: DocumentID,
    generation: BufferGeneration,
    filename: String,
    targetURL: URL?,
    reason: CrashRecoveryReason,
    createdAt: Date = Date(),
    source: String
  ) {
    self.id = id
    self.documentID = documentID
    self.generation = generation
    self.filename = filename
    self.targetURL = targetURL
    self.reason = reason
    self.createdAt = createdAt
    self.source = source
  }

  func record() -> CrashRecoveryRecord {
    CrashRecoveryRecord(
      id: id,
      documentID: documentID,
      generation: generation,
      filename: filename,
      targetURL: targetURL,
      reason: reason,
      createdAt: createdAt,
      data: Data(source.utf8)
    )
  }
}

/// App-owned durable storage for editor generations that are not yet known to
/// exist at their canonical path. Records are append-only; a partial pending
/// write never replaces an older valid generation.
final class CrashRecoveryJournal: @unchecked Sendable {
  static let shared = CrashRecoveryJournal(rootURL: defaultRootURL)

  let rootURL: URL

  private let fileManager: FileManager
  private let queue = DispatchQueue(label: "olympus.clio.crash-recovery", qos: .utility)
  private let lock = NSLock()
  private var pending: [DocumentID: CrashRecoverySnapshot] = [:]
  private var isDrainScheduled = false
  private var asynchronousErrors: [DocumentID: Error] = [:]
  private var statusHandler: (@Sendable (DocumentID, String?) -> Void)?

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
  }

  func schedule(_ snapshot: CrashRecoverySnapshot) {
    lock.lock()
    if let current = pending[snapshot.documentID],
      current.generation.revision > snapshot.generation.revision
    {
      lock.unlock()
      return
    }
    pending[snapshot.documentID] = snapshot
    let shouldSchedule = !isDrainScheduled
    isDrainScheduled = true
    lock.unlock()

    if shouldSchedule {
      queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
        self?.drainPendingRecords()
      }
    }
  }

  @discardableResult
  func checkpoint(_ record: CrashRecoveryRecord) throws -> URL {
    try queue.sync {
      removePending(upTo: record.generation.revision, for: record.documentID)
      do {
        let url = try write(record)
        try pruneSupersededRecords(afterWriting: record)
        lock.lock()
        asynchronousErrors.removeValue(forKey: record.documentID)
        let handler = statusHandler
        lock.unlock()
        handler?(record.documentID, nil)
        return url
      } catch {
        lock.lock()
        asynchronousErrors[record.documentID] = error
        let handler = statusHandler
        lock.unlock()
        handler?(record.documentID, error.localizedDescription)
        throw error
      }
    }
  }

  func flush() {
    queue.sync { drainPendingRecords() }
  }

  func setStatusHandler(
    _ handler: (@Sendable (DocumentID, String?) -> Void)?
  ) {
    lock.lock()
    statusHandler = handler
    lock.unlock()
  }

  func lastError(for documentID: DocumentID) -> Error? {
    lock.lock()
    defer { lock.unlock() }
    return asynchronousErrors[documentID]
  }

  func validRecords() throws -> [CrashRecoveryRecord] {
    try queue.sync {
      guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
      let urls = try fileManager.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
      )
      return urls.compactMap(validRecord(at:)).sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.generation.revision < $1.generation.revision
      }
    }
  }

  func clear(documentID: DocumentID, through revision: UInt64) {
    queue.async { [weak self] in
      guard let self else { return }
      self.removePending(upTo: revision, for: documentID)
      guard
        let urls = try? self.fileManager.contentsOfDirectory(
          at: self.rootURL,
          includingPropertiesForKeys: nil
        )
      else { return }
      for url in urls {
        guard let record = self.validRecord(at: url),
          record.documentID == documentID,
          record.reason == .dirtyBuffer,
          record.generation.revision <= revision
        else { continue }
        try? self.fileManager.removeItem(at: url)
      }
      try? Self.syncDirectory(self.rootURL)
    }
  }

  func remove(recordID: UUID) {
    queue.async { [weak self] in
      guard let self,
        let urls = try? self.fileManager.contentsOfDirectory(
          at: self.rootURL,
          includingPropertiesForKeys: nil
        )
      else { return }
      for url in urls where url.lastPathComponent.contains(recordID.uuidString.lowercased()) {
        guard self.validRecord(at: url)?.id == recordID else { continue }
        try? self.fileManager.removeItem(at: url)
      }
      try? Self.syncDirectory(self.rootURL)
    }
  }
}

extension CrashRecoveryJournal {
  fileprivate static var defaultRootURL: URL {
    let applicationSupport =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      applicationSupport
      .appendingPathComponent("Clio", isDirectory: true)
      .appendingPathComponent("Crash Recovery", isDirectory: true)
  }

  fileprivate func drainPendingRecords() {
    while true {
      let snapshots: [CrashRecoverySnapshot]
      lock.lock()
      snapshots = Array(pending.values)
      pending.removeAll()
      if snapshots.isEmpty {
        isDrainScheduled = false
        lock.unlock()
        return
      }
      lock.unlock()

      for snapshot in snapshots {
        let record = snapshot.record()
        do {
          _ = try write(record)
          try pruneSupersededRecords(afterWriting: record)
          lock.lock()
          asynchronousErrors.removeValue(forKey: record.documentID)
          let handler = statusHandler
          lock.unlock()
          handler?(record.documentID, nil)
        } catch {
          lock.lock()
          asynchronousErrors[record.documentID] = error
          let handler = statusHandler
          lock.unlock()
          handler?(record.documentID, error.localizedDescription)
        }
      }
    }
  }

  fileprivate func removePending(upTo revision: UInt64, for documentID: DocumentID) {
    lock.lock()
    if let record = pending[documentID], record.generation.revision <= revision {
      pending.removeValue(forKey: documentID)
    }
    lock.unlock()
  }

  fileprivate func write(_ record: CrashRecoveryRecord) throws -> URL {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let encoded = try encoder.encode(record)
    let stem =
      "buffer-\(record.documentID.rawValue.uuidString.lowercased())-\(record.generation.revision)-\(record.id.uuidString.lowercased())"
    let pendingURL = rootURL.appendingPathComponent(".\(stem).pending")
    let finalURL = rootURL.appendingPathComponent("\(stem).clio-recovery")

    if fileManager.fileExists(atPath: finalURL.path), validRecord(at: finalURL) == record {
      return finalURL
    }
    try encoded.write(to: pendingURL, options: .withoutOverwriting)
    try Self.syncFile(pendingURL)
    let result = pendingURL.withUnsafeFileSystemRepresentation { source in
      finalURL.withUnsafeFileSystemRepresentation { destination in
        renamex_np(source, destination, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0 else { throw Self.posixError(for: finalURL) }
    try Self.syncDirectory(rootURL)
    return finalURL
  }

  fileprivate func pruneSupersededRecords(afterWriting newest: CrashRecoveryRecord) throws {
    let urls = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    var removed = false
    for url in urls {
      guard let record = validRecord(at: url),
        record.documentID == newest.documentID,
        record.id != newest.id,
        record.reason == .dirtyBuffer,
        newest.reason == .dirtyBuffer,
        record.generation.revision <= newest.generation.revision
      else { continue }
      try fileManager.removeItem(at: url)
      removed = true
    }
    if removed { try Self.syncDirectory(rootURL) }
  }

  fileprivate func validRecord(at url: URL) -> CrashRecoveryRecord? {
    guard url.deletingLastPathComponent().standardizedFileURL == rootURL,
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let data = try? Data(contentsOf: url),
      let record = try? PropertyListDecoder().decode(CrashRecoveryRecord.self, from: data),
      record.contentDigest == DocumentRevisionReader.digest(record.data)
    else {
      return nil
    }
    return record
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
