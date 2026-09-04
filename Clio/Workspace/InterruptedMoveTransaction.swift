import Darwin
import Foundation

struct InterruptedMoveManifest: Codable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let id: UUID
  let documentID: DocumentID
  let generation: BufferGeneration
  let sourceRootURL: URL
  let destinationRootURL: URL
  let sourceURL: URL
  let destinationURL: URL
  let quarantineURL: URL
  let sourceRevision: DiskRevision
  let destinationRevision: DiskRevision?
  let candidateByteCount: Int64
  let candidateDigest: String
  let createdAt: Date
}

struct InterruptedMoveContext: Sendable {
  let manifest: InterruptedMoveManifest
  let manifestURL: URL
}

enum InterruptedMoveTransactions {
  static let manifestPrefix = ".clio-move-transaction-"
  static let manifestSuffix = ".plist"
  static let quarantinePrefix = ".clio-move-source-"

  static func begin(
    documentID: DocumentID,
    generation: BufferGeneration,
    sourceRootURL: URL,
    destinationRootURL: URL,
    sourceURL: URL,
    destinationURL: URL,
    sourceRevision: DiskRevision,
    destinationRevision: DiskRevision?,
    candidate: Data
  ) throws -> InterruptedMoveContext {
    let id = UUID()
    let source = sourceURL.standardizedFileURL
    let destination = destinationURL.standardizedFileURL
    let sourceRoot = sourceRootURL.standardizedFileURL.resolvingSymlinksInPath()
    let destinationRoot = destinationRootURL.standardizedFileURL.resolvingSymlinksInPath()
    guard isContained(source, in: sourceRoot),
      isContained(destination, in: destinationRoot),
      !isSymlink(source), !isSymlink(destination)
    else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let parent = source.deletingLastPathComponent()
    let quarantine = parent.appendingPathComponent(quarantinePrefix + id.uuidString.lowercased())
    let manifestURL = parent.appendingPathComponent(
      manifestPrefix + id.uuidString.lowercased() + manifestSuffix
    )
    let manifest = InterruptedMoveManifest(
      schemaVersion: InterruptedMoveManifest.schemaVersion,
      id: id,
      documentID: documentID,
      generation: generation,
      sourceRootURL: sourceRoot,
      destinationRootURL: destinationRoot,
      sourceURL: source,
      destinationURL: destination,
      quarantineURL: quarantine,
      sourceRevision: sourceRevision,
      destinationRevision: destinationRevision,
      candidateByteCount: Int64(candidate.count),
      candidateDigest: DocumentRevisionReader.digest(candidate),
      createdAt: Date()
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(manifest).write(to: manifestURL, options: .withoutOverwriting)
    try syncFile(manifestURL)
    try syncDirectory(parent)
    return InterruptedMoveContext(manifest: manifest, manifestURL: manifestURL)
  }

  static func finish(_ context: InterruptedMoveContext, removeQuarantine: Bool) throws {
    if removeQuarantine,
      FileManager.default.fileExists(atPath: context.manifest.quarantineURL.path)
    {
      try FileManager.default.removeItem(at: context.manifest.quarantineURL)
    }
    if FileManager.default.fileExists(atPath: context.manifestURL.path) {
      try FileManager.default.removeItem(at: context.manifestURL)
    }
    try syncDirectory(context.manifestURL.deletingLastPathComponent())
  }

  /// Hides the source inode without deleting it. `RENAME_EXCL` ensures an
  /// unrelated recovery file can never be overwritten.
  static func quarantineSource(_ context: InterruptedMoveContext) throws {
    let source = context.manifest.sourceURL
    let quarantine = context.manifest.quarantineURL
    let result = source.withUnsafeFileSystemRepresentation { sourcePath in
      quarantine.withUnsafeFileSystemRepresentation { quarantinePath in
        renamex_np(sourcePath, quarantinePath, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0 else { throw posixError(for: source) }
    try syncDirectory(source.deletingLastPathComponent())
  }

  static func sourceRevision(_ context: InterruptedMoveContext) throws -> DiskRevision {
    try DocumentRevisionReader.revision(at: context.manifest.quarantineURL)
  }

  static func abortIfDestinationUnchanged(_ context: InterruptedMoveContext) throws -> Bool {
    guard FileManager.default.fileExists(atPath: context.manifest.sourceURL.path),
      !FileManager.default.fileExists(atPath: context.manifest.quarantineURL.path)
    else {
      return false
    }
    let destination = try? DocumentRevisionReader.revision(at: context.manifest.destinationURL)
    let unchanged: Bool
    if let expected = context.manifest.destinationRevision {
      unchanged = destination.map { Workspace.sameContent($0, expected) } == true
    } else {
      unchanged = destination == nil
    }
    guard unchanged else {
      return false
    }
    try finish(context, removeQuarantine: false)
    return true
  }

  @discardableResult
  static func recover(in rootURL: URL, journal: CrashRecoveryJournal) throws -> Int {
    try recover(inAuthorizedRoots: [rootURL], journal: journal)
  }

  /// Catalog-aware recovery. Cross-workspace manifests are actionable only
  /// when both canonical roots are in this explicitly authorized set.
  @discardableResult
  static func recover(
    inAuthorizedRoots rootURLs: [URL],
    journal: CrashRecoveryJournal
  ) throws -> Int {
    let roots = Set(rootURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
    var recovered = 0
    var visited = Set<UUID>()
    for root in roots {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
          options: [.skipsPackageDescendants]
        )
      else { continue }
      for case let manifestURL as URL in enumerator
      where isManifestName(manifestURL.lastPathComponent) {
        guard
          let manifest = validManifest(
            at: manifestURL,
            sourceRoot: root,
            authorizedRoots: roots
          ), visited.insert(manifest.id).inserted
        else { continue }
        var quarantine = safeSnapshot(at: manifest.quarantineURL, inside: root)

        // Only act on a visible source when the destination is in this
        // already-authorized workspace. Cross-workspace records remain
        // untouched until both grants are active.
        if quarantine == nil,
          let source = safeSnapshot(at: manifest.sourceURL, inside: root),
          let destination = safeSnapshot(
            at: manifest.destinationURL,
            inside: manifest.destinationRootURL
          )
        {
          if let expected = manifest.destinationRevision,
            Workspace.sameContent(destination.revision, expected)
          {
            try FileManager.default.removeItem(at: manifestURL)
            try syncDirectory(manifestURL.deletingLastPathComponent())
            continue
          }
          if destination.revision.byteCount == manifest.candidateByteCount,
            destination.revision.contentDigest == manifest.candidateDigest
          {
            let context = InterruptedMoveContext(
              manifest: manifest,
              manifestURL: manifestURL
            )
            try quarantineSource(context)
            quarantine = safeSnapshot(at: manifest.quarantineURL, inside: root)
            // Keep `source` alive through the rename decision: its
            // revision is compared below via the quarantined inode.
            _ = source
          }
        }

        if quarantine == nil,
          safeSnapshot(at: manifest.sourceURL, inside: root) != nil,
          manifest.destinationRevision == nil,
          isAbsent(manifest.destinationURL)
        {
          try FileManager.default.removeItem(at: manifestURL)
          try syncDirectory(manifestURL.deletingLastPathComponent())
          continue
        }

        if let quarantine {
          _ = try journal.checkpoint(
            CrashRecoveryRecord(
              documentID: manifest.documentID,
              generation: manifest.generation,
              filename: manifest.sourceURL.lastPathComponent,
              targetURL: manifest.sourceURL,
              reason: .interruptedMove,
              createdAt: manifest.createdAt,
              data: quarantine.data
            ))
          try FileManager.default.removeItem(at: manifest.quarantineURL)
          try FileManager.default.removeItem(at: manifestURL)
          try syncDirectory(manifestURL.deletingLastPathComponent())
          recovered += 1
          continue
        }

        if isAbsent(manifest.sourceURL),
          isAbsent(manifest.quarantineURL),
          let destination = safeSnapshot(
            at: manifest.destinationURL,
            inside: manifest.destinationRootURL
          ),
          destination.revision.byteCount == manifest.candidateByteCount,
          destination.revision.contentDigest == manifest.candidateDigest
        {
          try FileManager.default.removeItem(at: manifestURL)
          try syncDirectory(manifestURL.deletingLastPathComponent())
        }
      }
    }
    return recovered
  }
}

extension InterruptedMoveTransactions {
  fileprivate static func isManifestName(_ name: String) -> Bool {
    name.hasPrefix(manifestPrefix) && name.hasSuffix(manifestSuffix)
  }

  fileprivate static func validManifest(
    at url: URL,
    sourceRoot root: URL,
    authorizedRoots: Set<URL>
  ) -> InterruptedMoveManifest? {
    guard isSafeRegularFile(url, inside: root),
      let data = try? Data(contentsOf: url),
      let manifest = try? PropertyListDecoder().decode(InterruptedMoveManifest.self, from: data),
      manifest.schemaVersion == InterruptedMoveManifest.schemaVersion,
      manifest.sourceRootURL.standardizedFileURL.resolvingSymlinksInPath() == root,
      isContained(manifest.sourceURL, in: root),
      isContained(manifest.quarantineURL, in: root),
      manifest.sourceURL.deletingLastPathComponent().standardizedFileURL
        == manifest.quarantineURL.deletingLastPathComponent().standardizedFileURL,
      url.deletingLastPathComponent().standardizedFileURL
        == manifest.sourceURL.deletingLastPathComponent().standardizedFileURL,
      url.lastPathComponent == manifestPrefix + manifest.id.uuidString.lowercased()
        + manifestSuffix,
      manifest.quarantineURL.lastPathComponent
        == quarantinePrefix + manifest.id.uuidString.lowercased(),
      isAuthorizedRoot(manifest.destinationRootURL, by: authorizedRoots),
      isContained(manifest.destinationURL, in: manifest.destinationRootURL)
    else {
      return nil
    }
    return manifest
  }

  fileprivate static func safeSnapshot(
    at url: URL,
    inside root: URL
  ) -> (data: Data, revision: DiskRevision)? {
    guard isSafeRegularFile(url, inside: root) else { return nil }
    return try? DocumentRevisionReader.documentSnapshot(at: url)
  }

  fileprivate static func isSafeRegularFile(_ url: URL, inside root: URL) -> Bool {
    guard isContained(url, in: root),
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  fileprivate static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  fileprivate static func isAbsent(_ url: URL) -> Bool {
    var status = stat()
    return url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      if lstat(path, &status) == 0 { return false }
      return errno == ENOENT
    }
  }

  fileprivate static func isContained(_ url: URL, in rootURL: URL) -> Bool {
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return parent == root || parent.path.hasPrefix(prefix)
  }

  fileprivate static func isAuthorizedRoot(_ candidateURL: URL, by roots: Set<URL>) -> Bool {
    let candidate = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
    guard
      let values = try? candidate.resourceValues(forKeys: [
        .isDirectoryKey,
        .isSymbolicLinkKey,
      ]), values.isDirectory == true, values.isSymbolicLink != true
    else { return false }
    return roots.contains { root in
      let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
      return candidate == root || candidate.path.hasPrefix(prefix)
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
