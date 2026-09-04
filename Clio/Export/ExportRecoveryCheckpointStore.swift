import Darwin
import Foundation

struct ExportRecoveryCheckpoint: Sendable, Equatable {
    let id: UUID
    let manifestURL: URL
    let candidateURL: URL
}

protocol ExportRecoveryCheckpointing: Sendable {
    func checkpoint(_ staged: StagedDocumentExport) async throws
        -> ExportRecoveryCheckpoint
    func complete(_ checkpoint: ExportRecoveryCheckpoint) async throws
    func recoverInterruptedCheckpoints(
        journal: CrashRecoveryJournal
    ) async throws -> Int
}

/// File-only Powerbox grants cannot safely be widened to a destination folder.
/// This store clones a bounded rendered artifact into Clio's container and
/// publishes a tiny append-only manifest before the destination is touched.
/// Normal completion removes both; a process crash leaves the derived export
/// available to the existing seven-day recovery flow.
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

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
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
                createdAt: Date()
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
        if fileManager.fileExists(atPath: checkpoint.manifestURL.path) {
            try fileManager.removeItem(at: checkpoint.manifestURL)
            try syncDirectory(rootURL)
        }
        if fileManager.fileExists(atPath: checkpoint.candidateURL.path) {
            try fileManager.removeItem(at: checkpoint.candidateURL)
            try syncDirectory(rootURL)
        }
    }

    @discardableResult
    func recoverInterruptedCheckpoints(
        journal: CrashRecoveryJournal
    ) throws -> Int {
        guard fileManager.fileExists(atPath: rootURL.path) else { return 0 }
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        var recovered = 0
        for manifestURL in urls where isManifestName(manifestURL.lastPathComponent) {
            try Task.checkCancellation()
            guard let manifest = validManifest(at: manifestURL) else { continue }
            let checkpoint = makeCheckpoint(id: manifest.id, format: manifest.format)
            guard checkpoint.manifestURL == manifestURL.standardizedFileURL,
                  checkpoint.candidateURL.lastPathComponent == manifest.candidateFilename,
                  let snapshot = try? DocumentRevisionReader.snapshot(
                    at: checkpoint.candidateURL,
                    maximumByteCount: AtomicWriteTransactions.maximumRecoverableByteCount
                  ),
                  snapshot.revision.byteCount == manifest.byteCount,
                  snapshot.revision.contentDigest == manifest.digest else {
                continue
            }
            _ = try journal.checkpoint(CrashRecoveryRecord(
                id: manifest.id,
                documentID: manifest.documentID,
                generation: manifest.generation,
                filename: manifest.destinationURL.lastPathComponent,
                targetURL: manifest.destinationURL,
                reason: .atomicCandidate,
                createdAt: manifest.createdAt,
                data: snapshot.data
            ))
            try complete(checkpoint)
            recovered += 1
        }
        return recovered
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
