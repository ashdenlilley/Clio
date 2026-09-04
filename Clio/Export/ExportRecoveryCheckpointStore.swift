import Darwin
import Foundation

struct ExportRecoveryCheckpoint: Sendable, Equatable {
    let id: UUID
    let manifestURL: URL
    let candidateURL: URL
}

enum ExportRecoveryKind: Sendable, Equatable {
    case renderedCandidate
    case displacedDestination
    case completedDestination
}

enum ExportRecoveryStorage: Sendable, Equatable {
    case appContainer(manifestURL: URL)
    case rememberedDirectory(directoryURL: URL, manifestURL: URL)
}

/// A validated, file-backed derived export left by an interrupted save. The
/// rendered bytes stay in Clio's container; unlike canonical Markdown crash
/// buffers, they are never copied into the in-memory recovery journal.
struct ExportRecoveryItem: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: ExportRecoveryKind
    let format: ExportFormat
    let candidateURL: URL
    let intendedDestinationURL: URL
    let byteCount: Int64
    let contentDigest: String
    let documentID: DocumentID
    let generation: BufferGeneration
    let sourceFingerprint: String
    let createdAt: Date
    let storage: ExportRecoveryStorage

    var filename: String { intendedDestinationURL.lastPathComponent }
}

protocol ExportRecoveryCheckpointing: Sendable {
    func checkpoint(_ staged: StagedDocumentExport) async throws
        -> ExportRecoveryCheckpoint
    func complete(_ checkpoint: ExportRecoveryCheckpoint) async throws
    func interruptedCheckpoints() async throws -> [ExportRecoveryItem]
    func discard(_ item: ExportRecoveryItem) async throws
}

/// File-only Powerbox grants cannot safely be widened to a destination folder.
/// This store clones a bounded rendered artifact into Clio's container and
/// publishes a tiny append-only manifest before the destination is touched.
/// Normal completion removes both; a process crash leaves the derived export
/// available here for seven days without ever materializing the whole artifact.
actor ExportRecoveryCheckpointStore: ExportRecoveryCheckpointing {
    static let shared = ExportRecoveryCheckpointStore(rootURL: defaultRootURL)

    fileprivate struct Manifest: Codable, Sendable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let id: UUID
        let candidateFilename: String
        let format: ExportFormat
        let destinationURL: URL
        let byteCount: Int64
        let digest: String
        let documentID: DocumentID
        let generation: BufferGeneration
        let sourceFingerprint: String
        let createdAt: Date
    }

    private static let manifestPrefix = "export-"
    private static let manifestSuffix = ".plist"
    private static let candidatePrefix = "candidate-"
    private static let maximumManifestByteCount = 1 * 1_024 * 1_024
    private static let transferChunkByteCount = 1 * 1_024 * 1_024

    nonisolated let rootURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    func checkpoint(
        _ staged: StagedDocumentExport
    ) throws -> ExportRecoveryCheckpoint {
        try Task.checkCancellation()
        guard staged.byteCount >= 0,
              staged.byteCount <= AtomicWriteTransactions.maximumRecoverableByteCount else {
            throw DocumentExportError.artifactTooLarge(
                staged.destinationURL,
                byteCount: staged.byteCount,
                maximumByteCount: AtomicWriteTransactions.maximumRecoverableByteCount
            )
        }
        try prepareRoot()

        let id = UUID()
        let token = makeCheckpoint(id: id, format: staged.format)
        let pendingManifestURL = rootURL.appendingPathComponent(
            ".\(Self.manifestPrefix)\(id.uuidString.lowercased()).pending",
            isDirectory: false
        )
        do {
            try copyBounded(
                from: staged.temporaryURL,
                to: token.candidateURL,
                expectedByteCount: staged.byteCount
            )
            let revision = try DocumentRevisionReader.revision(
                at: token.candidateURL
            )
            guard revision.byteCount == staged.byteCount else {
                throw DocumentRevisionReader.RevisionError.changedWhileReading(
                    staged.temporaryURL
                )
            }
            let manifest = Manifest(
                schemaVersion: Manifest.schemaVersion,
                id: id,
                candidateFilename: token.candidateURL.lastPathComponent,
                format: staged.format,
                destinationURL: staged.destinationURL,
                byteCount: revision.byteCount,
                digest: revision.contentDigest,
                documentID: staged.documentID,
                generation: staged.generation,
                sourceFingerprint: staged.sourceFingerprint,
                createdAt: now()
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let encoded = try encoder.encode(manifest)
            guard encoded.count <= Self.maximumManifestByteCount else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try encoded.write(to: pendingManifestURL, options: .withoutOverwriting)
            try syncFile(pendingManifestURL)
            let result = pendingManifestURL.withUnsafeFileSystemRepresentation { source in
                token.manifestURL.withUnsafeFileSystemRepresentation { destination in
                    renamex_np(source, destination, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw posixError(for: token.manifestURL) }
            try syncDirectory(rootURL)
            return token
        } catch {
            try? fileManager.removeItem(at: pendingManifestURL)
            try? fileManager.removeItem(at: token.manifestURL)
            try? fileManager.removeItem(at: token.candidateURL)
            try? syncDirectory(rootURL)
            throw error
        }
    }

    func complete(_ checkpoint: ExportRecoveryCheckpoint) throws {
        guard checkpoint.manifestURL.deletingLastPathComponent().standardizedFileURL == rootURL,
              checkpoint.candidateURL.deletingLastPathComponent().standardizedFileURL == rootURL
        else { return }
        if fileManager.fileExists(atPath: checkpoint.candidateURL.path) {
            try fileManager.removeItem(at: checkpoint.candidateURL)
            try syncDirectory(rootURL)
        }
        if fileManager.fileExists(atPath: checkpoint.manifestURL.path) {
            try fileManager.removeItem(at: checkpoint.manifestURL)
            try syncDirectory(rootURL)
        }
    }

    func interruptedCheckpoints() throws -> [ExportRecoveryItem] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        var urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        var promotedURLs: [URL] = []
        for pendingURL in urls where isPendingManifestName(
            pendingURL.lastPathComponent
        ) {
            try Task.checkCancellation()
            guard let manifest = validManifest(at: pendingURL) else { continue }
            let checkpoint = makeCheckpoint(id: manifest.id, format: manifest.format)
            guard pendingURL.lastPathComponent
                    == ".\(Self.manifestPrefix)\(manifest.id.uuidString.lowercased()).pending",
                  checkpoint.candidateURL.lastPathComponent
                    == manifest.candidateFilename,
                  fileManager.fileExists(atPath: checkpoint.candidateURL.path)
            else { continue }
            let result = pendingURL.withUnsafeFileSystemRepresentation { source in
                checkpoint.manifestURL.withUnsafeFileSystemRepresentation { destination in
                    renamex_np(source, destination, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                try syncDirectory(rootURL)
                promotedURLs.append(checkpoint.manifestURL)
            }
        }
        urls.append(contentsOf: promotedURLs)
        let expirationDate = now().addingTimeInterval(-RecoveryStore.retention)
        var recovered: [ExportRecoveryItem] = []
        for manifestURL in urls where isManifestName(manifestURL.lastPathComponent) {
            try Task.checkCancellation()
            guard let manifest = validManifest(at: manifestURL) else { continue }
            let checkpoint = makeCheckpoint(id: manifest.id, format: manifest.format)
            guard checkpoint.manifestURL == manifestURL.standardizedFileURL,
                  checkpoint.candidateURL.lastPathComponent == manifest.candidateFilename,
                  let revision = try? DocumentRevisionReader.revision(
                    at: checkpoint.candidateURL,
                    maximumByteCount: AtomicWriteTransactions.maximumRecoverableByteCount
                  ),
                  revision.byteCount == manifest.byteCount,
                  revision.byteCount <= AtomicWriteTransactions.maximumRecoverableByteCount,
                  revision.contentDigest == manifest.digest else {
                continue
            }
            if manifest.createdAt < expirationDate {
                try complete(checkpoint)
                continue
            }
            recovered.append(ExportRecoveryItem(
                id: manifest.id,
                kind: .renderedCandidate,
                format: manifest.format,
                candidateURL: checkpoint.candidateURL,
                intendedDestinationURL: manifest.destinationURL,
                byteCount: manifest.byteCount,
                contentDigest: manifest.digest,
                documentID: manifest.documentID,
                generation: manifest.generation,
                sourceFingerprint: manifest.sourceFingerprint,
                createdAt: manifest.createdAt,
                storage: .appContainer(manifestURL: checkpoint.manifestURL)
            ))
        }
        return recovered.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func discard(_ item: ExportRecoveryItem) throws {
        guard case .appContainer(let manifestURL) = item.storage else { return }
        let checkpoint = makeCheckpoint(id: item.id, format: item.format)
        guard checkpoint.manifestURL == manifestURL.standardizedFileURL,
              checkpoint.candidateURL == item.candidateURL.standardizedFileURL,
              let manifest = validManifest(at: checkpoint.manifestURL),
              manifest.id == item.id,
              manifest.digest == item.contentDigest,
              manifest.byteCount == item.byteCount,
              let revision = try? DocumentRevisionReader.revision(
                at: checkpoint.candidateURL,
                maximumByteCount: AtomicWriteTransactions.maximumRecoverableByteCount
              ),
              revision.byteCount == item.byteCount,
              revision.contentDigest == item.contentDigest else {
            throw DocumentRevisionReader.RevisionError.changedWhileReading(
                item.candidateURL
            )
        }
        try complete(checkpoint)
    }
}

private extension ExportRecoveryCheckpointStore {
    nonisolated static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Clio", isDirectory: true)
            .appendingPathComponent("Export Recovery", isDirectory: true)
            .appendingPathComponent("Checkpoints", isDirectory: true)
    }

    func makeCheckpoint(id: UUID, format: ExportFormat) -> ExportRecoveryCheckpoint {
        let identifier = id.uuidString.lowercased()
        return ExportRecoveryCheckpoint(
            id: id,
            manifestURL: rootURL.appendingPathComponent(
                Self.manifestPrefix + identifier + Self.manifestSuffix,
                isDirectory: false
            ),
            candidateURL: rootURL.appendingPathComponent(
                Self.candidatePrefix + identifier + "." + format.rawValue,
                isDirectory: false
            )
        )
    }

    func prepareRoot() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try rootURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    func validManifest(at url: URL) -> Manifest? {
        guard url.deletingLastPathComponent().standardizedFileURL == rootURL,
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= Self.maximumManifestByteCount,
              let data = try? Data(contentsOf: url),
              let manifest = try? PropertyListDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == Manifest.schemaVersion,
              manifest.byteCount >= 0,
              manifest.byteCount <= AtomicWriteTransactions.maximumRecoverableByteCount
        else { return nil }
        return manifest
    }

    func isManifestName(_ name: String) -> Bool {
        guard name.hasPrefix(Self.manifestPrefix),
              name.hasSuffix(Self.manifestSuffix) else { return false }
        let identifier = name
            .dropFirst(Self.manifestPrefix.count)
            .dropLast(Self.manifestSuffix.count)
        return UUID(uuidString: String(identifier)) != nil
    }

    func isPendingManifestName(_ name: String) -> Bool {
        guard name.hasPrefix(".\(Self.manifestPrefix)"),
              name.hasSuffix(".pending") else { return false }
        let identifier = name
            .dropFirst(Self.manifestPrefix.count + 1)
            .dropLast(".pending".count)
        return UUID(uuidString: String(identifier)) != nil
    }

    func copyBounded(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedByteCount: Int64
    ) throws {
        let source = open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard source >= 0 else { throw posixError(for: sourceURL) }
        defer { close(source) }
        var sourceStatus = stat()
        guard fstat(source, &sourceStatus) == 0 else {
            throw posixError(for: sourceURL)
        }
        guard sourceStatus.st_mode & S_IFMT == S_IFREG,
              sourceStatus.st_size == expectedByteCount,
              sourceStatus.st_size <= AtomicWriteTransactions.maximumRecoverableByteCount
        else {
            throw DocumentRevisionReader.RevisionError.changedWhileReading(sourceURL)
        }

        let destination = open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destination >= 0 else { throw posixError(for: destinationURL) }
        defer { close(destination) }

        var transferred: Int64 = 0
        var storage = [UInt8](
            repeating: 0,
            count: Self.transferChunkByteCount
        )
        while true {
            try Task.checkCancellation()
            let count = read(source, &storage, storage.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(for: sourceURL)
            }
            var written = 0
            while written < count {
                let result = storage.withUnsafeBytes { bytes in
                    write(
                        destination,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError(for: destinationURL)
                }
                written += result
            }
            transferred += Int64(count)
            guard transferred <= AtomicWriteTransactions.maximumRecoverableByteCount else {
                throw DocumentExportError.artifactTooLarge(
                    sourceURL,
                    byteCount: transferred,
                    maximumByteCount: AtomicWriteTransactions.maximumRecoverableByteCount
                )
            }
        }
        guard transferred == expectedByteCount else {
            throw DocumentRevisionReader.RevisionError.changedWhileReading(sourceURL)
        }
        guard fsync(destination) == 0 else {
            throw posixError(for: destinationURL)
        }
    }

    func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError(for: url) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(for: url) }
    }

    func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(for: url) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(for: url) }
    }

    func posixError(for url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
}
