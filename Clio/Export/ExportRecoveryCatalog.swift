import AppKit
import Darwin
import Foundation

enum ExportRecoveryStrategy: Sendable, Equatable {
    /// A durable folder grant lets the crash-safe atomic writer leave and
    /// recover a transaction immediately beside the destination.
    case directoryTransaction
    /// NSSavePanel is only documented to grant the selected file. If its
    /// parent cannot be bookmarked, keep a bounded staged-file checkpoint in
    /// Clio's container while Foundation performs a coordinated safe save.
    case appContainerCheckpoint
}

protocol ExportRecoveryCataloging: AnyObject, Sendable {
    /// Parent access is an optimization, not a precondition for exporting.
    /// App Sandbox guarantees the file selected by NSSavePanel, but does not
    /// guarantee an implicit grant for its parent directory.
    func recoveryStrategy(for destinationURL: URL) async -> ExportRecoveryStrategy
}

protocol ExportTransactionRecoveryCataloging: AnyObject, Sendable {
    func interruptedExports() async throws -> [ExportRecoveryItem]
    func reveal(_ item: ExportRecoveryItem) async throws
    func discard(_ item: ExportRecoveryItem) async throws
}

/// Export destinations may sit outside every searchable workspace. This
/// app-owned catalog retains only their parent grants, allowing startup to
/// recover crash-safe atomic transactions without broadly scanning the user's
/// filesystem or treating export folders as writing workspaces.
final class ExportRecoveryCatalog: ExportRecoveryCataloging,
    ExportTransactionRecoveryCataloging, @unchecked Sendable {
    typealias BookmarkMaker = @Sendable (URL) throws -> Data
    typealias BookmarkResolver = @Sendable (Data) throws -> Workspace.BookmarkResolution

    static let shared = ExportRecoveryCatalog(rootURL: defaultRootURL)

    private struct Entry: Codable, Hashable {
        let directoryURL: URL
        let bookmark: Data
        var lastUsedAt: Date
    }

    private struct Catalog: Codable {
        static let schemaVersion = 1
        let schemaVersion: Int
        var entries: [Entry]
    }

    private static let maximumEntries = 32
    private static let maximumCatalogByteCount = 4 * 1_024 * 1_024

    let rootURL: URL

    private let fileManager: FileManager
    private let bookmarkMaker: BookmarkMaker
    private let bookmarkResolver: BookmarkResolver
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(
        label: "olympus.clio.export-recovery",
        qos: .utility
    )

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        bookmarkMaker: @escaping BookmarkMaker = {
            try Workspace.makeSecurityScopedBookmark(for: $0)
        },
        bookmarkResolver: @escaping BookmarkResolver = {
            try Workspace.resolveSecurityScopedBookmark($0)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.bookmarkMaker = bookmarkMaker
        self.bookmarkResolver = bookmarkResolver
        self.now = now
    }

    func remember(destinationDirectory: URL) throws {
        let directory = destinationDirectory.standardizedFileURL
        let values = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DocumentExportError.unsupportedDestination(directory)
        }
        let bookmark = try bookmarkMaker(directory)
        try queue.sync {
            var entries = try load().entries.filter {
                $0.directoryURL.standardizedFileURL != directory
            }
            entries.append(Entry(
                directoryURL: directory,
                bookmark: bookmark,
                lastUsedAt: Date()
            ))
            entries.sort { $0.lastUsedAt > $1.lastUsedAt }
            if entries.count > Self.maximumEntries {
                entries.removeLast(entries.count - Self.maximumEntries)
            }
            try persist(Catalog(
                schemaVersion: Catalog.schemaVersion,
                entries: entries
            ))
        }
    }

    func recoveryStrategy(for destinationURL: URL) async -> ExportRecoveryStrategy {
        await Task.detached(priority: .utility) { [self] in
            do {
                try remember(
                    destinationDirectory: destinationURL.deletingLastPathComponent()
                )
                return .directoryTransaction
            } catch {
                return .appContainerCheckpoint
            }
        }.value
    }

    /// Performs exact-directory scans. Workspace recovery remains recursive;
    /// export recovery inspects only manifests immediately beside destinations
    /// that were actually selected in NSSavePanel. Derived bytes remain in
    /// their bounded files instead of entering the Markdown recovery journal.
    func interruptedExports() async throws -> [ExportRecoveryItem] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { [self] in
            try interruptedExportsSynchronously()
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }

    func reveal(_ item: ExportRecoveryItem) async throws {
        let resolved = try await Task.detached(priority: .utility) { [self] in
            try resolveArtifact(item)
        }.value
        defer {
            if resolved.didStartAccess {
                resolved.accessURL.stopAccessingSecurityScopedResource()
            }
        }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([
                resolved.artifact.contentURL
            ])
        }
    }

    func discard(_ item: ExportRecoveryItem) async throws {
        try await Task.detached(priority: .utility) { [self] in
            let resolved = try resolveArtifact(item)
            defer {
                if resolved.didStartAccess {
                    resolved.accessURL.stopAccessingSecurityScopedResource()
                }
            }
            try AtomicWriteTransactions.discardInterruptedExportArtifact(
                resolved.artifact,
                in: resolved.accessURL
            )
        }.value
    }
}

private extension ExportRecoveryCatalog {
    struct ResolvedArtifact: Sendable {
        let artifact: AtomicExportRecoveryArtifact
        let accessURL: URL
        let didStartAccess: Bool
    }

    func interruptedExportsSynchronously() throws -> [ExportRecoveryItem] {
        let entries = try queue.sync { try load().entries }
        var recovered: [ExportRecoveryItem] = []
        var inspectedDirectories = Set<URL>()

        for entry in entries {
            try Task.checkCancellation()
            do {
                let resolution = try bookmarkResolver(entry.bookmark)
                let resolvedDirectory = resolution.url.standardizedFileURL
                    .resolvingSymlinksInPath()
                guard inspectedDirectories.insert(resolvedDirectory).inserted else {
                    if resolution.isStale {
                        try remember(destinationDirectory: resolution.url)
                    }
                    continue
                }
                let didStart = resolution.url.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        resolution.url.stopAccessingSecurityScopedResource()
                    }
                }
                let inspection = try AtomicWriteTransactions
                    .inspectInterruptedExportTransactions(in: resolution.url)
                for manifestURL in inspection.manifestOnlyTransactions {
                    try AtomicWriteTransactions.discardManifestOnlyTransaction(
                        at: manifestURL,
                        in: resolution.url
                    )
                }
                let expirationDate = now().addingTimeInterval(
                    -RecoveryStore.retention
                )
                for artifact in inspection.artifacts {
                    if artifact.createdAt < expirationDate {
                        try AtomicWriteTransactions
                            .discardInterruptedExportArtifact(
                                artifact,
                                in: resolution.url
                            )
                    } else if let item = recoveryItem(
                        from: artifact,
                        directoryURL: resolution.url
                    ) {
                        recovered.append(item)
                    }
                }
                if resolution.isStale {
                    try remember(destinationDirectory: resolution.url)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep disconnected volumes and temporarily revoked roots in
                // the bounded catalog so a later launch can retry.
            }
        }
        return recovered.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func resolveArtifact(_ item: ExportRecoveryItem) throws -> ResolvedArtifact {
        guard case .rememberedDirectory(
            let directoryURL,
            let storedManifestURL
        ) = item.storage else {
            throw DocumentRevisionReader.RevisionError.changedWhileReading(
                item.candidateURL
            )
        }
        let storedDirectory = directoryURL.standardizedFileURL
        guard storedManifestURL.deletingLastPathComponent().standardizedFileURL
                == storedDirectory,
              item.candidateURL.deletingLastPathComponent().standardizedFileURL
                == storedDirectory,
              item.intendedDestinationURL.deletingLastPathComponent().standardizedFileURL
                == storedDirectory else {
            throw DocumentRevisionReader.RevisionError.changedWhileReading(
                item.candidateURL
            )
        }
        let entry = try queue.sync {
            try load().entries.first {
                $0.directoryURL.standardizedFileURL == storedDirectory
            }
        }
        guard let entry else {
            throw Workspace.WorkspaceError.securityScopedAccessDenied(directoryURL)
        }
        let resolution = try bookmarkResolver(entry.bookmark)
        let accessURL = resolution.url.standardizedFileURL
        let didStartAccess = accessURL.startAccessingSecurityScopedResource()
        do {
            let expectedManifestURL = accessURL.appendingPathComponent(
                storedManifestURL.lastPathComponent,
                isDirectory: false
            ).standardizedFileURL
            let expectedContentURL = accessURL.appendingPathComponent(
                item.candidateURL.lastPathComponent,
                isDirectory: false
            ).standardizedFileURL
            let expectedDestinationURL = accessURL.appendingPathComponent(
                item.intendedDestinationURL.lastPathComponent,
                isDirectory: false
            ).standardizedFileURL
            let inspection = try AtomicWriteTransactions
                .inspectInterruptedExportTransactions(in: accessURL)
            guard let artifact = inspection.artifacts.first(where: {
                $0.id == item.id
                    && $0.byteCount == item.byteCount
                    && $0.contentDigest == item.contentDigest
                    && recoveryKind(from: $0.kind) == item.kind
                    && $0.manifestURL.standardizedFileURL == expectedManifestURL
                    && $0.contentURL.standardizedFileURL == expectedContentURL
                    && $0.destinationURL.standardizedFileURL
                        == expectedDestinationURL
            }) else {
                throw DocumentRevisionReader.RevisionError.changedWhileReading(
                    item.candidateURL
                )
            }
            return ResolvedArtifact(
                artifact: artifact,
                accessURL: accessURL,
                didStartAccess: didStartAccess
            )
        } catch {
            if didStartAccess { accessURL.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func recoveryItem(
        from artifact: AtomicExportRecoveryArtifact,
        directoryURL: URL
    ) -> ExportRecoveryItem? {
        guard let format = ExportFormat(
            rawValue: artifact.destinationURL.pathExtension.lowercased()
        ) else { return nil }
        return ExportRecoveryItem(
            id: artifact.id,
            kind: recoveryKind(from: artifact.kind),
            format: format,
            candidateURL: artifact.contentURL,
            intendedDestinationURL: artifact.destinationURL,
            byteCount: artifact.byteCount,
            contentDigest: artifact.contentDigest,
            documentID: DocumentID(rawValue: artifact.id),
            generation: BufferGeneration(bufferID: artifact.id, revision: 0),
            sourceFingerprint: artifact.contentDigest,
            createdAt: artifact.createdAt,
            storage: .rememberedDirectory(
                directoryURL: directoryURL.standardizedFileURL,
                manifestURL: artifact.manifestURL
            )
        )
    }

    func recoveryKind(
        from kind: AtomicExportRecoveryArtifactKind
    ) -> ExportRecoveryKind {
        switch kind {
        case .renderedCandidate: .renderedCandidate
        case .displacedDestination: .displacedDestination
        case .completedDestination: .completedDestination
        }
    }

    static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Clio", isDirectory: true)
            .appendingPathComponent("Export Recovery", isDirectory: true)
    }

    var catalogURL: URL {
        rootURL.appendingPathComponent("roots.plist", isDirectory: false)
    }

    var previousCatalogURL: URL {
        rootURL.appendingPathComponent("roots.previous.plist", isDirectory: false)
    }

    private func load() throws -> Catalog {
        var firstError: Error?
        for url in [catalogURL, previousCatalogURL]
        where fileManager.fileExists(atPath: url.path) {
            do {
                return try loadCatalog(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return Catalog(schemaVersion: Catalog.schemaVersion, entries: [])
    }

    private func loadCatalog(at url: URL) throws -> Catalog {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= Self.maximumCatalogByteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: url)
        let decoded = try PropertyListDecoder().decode(Catalog.self, from: data)
        guard decoded.schemaVersion == Catalog.schemaVersion,
              decoded.entries.count <= Self.maximumEntries else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
    }

    private func persist(_ catalog: Catalog) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = rootURL.appendingPathComponent(
            ".roots-\(UUID().uuidString.lowercased()).tmp"
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(catalog)
        guard data.count <= Self.maximumCatalogByteCount else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try syncFile(temporaryURL)

            // Retain the last valid catalog as a second durable generation.
            // A crash can occur before or after either rename and startup will
            // still find a completely synced primary or previous file.
            if fileManager.fileExists(atPath: catalogURL.path) {
                if (try? loadCatalog(at: catalogURL)) != nil {
                    guard rename(catalogURL.path, previousCatalogURL.path) == 0 else {
                        throw posixError(for: previousCatalogURL)
                    }
                    try syncDirectory(rootURL)
                } else {
                    try fileManager.removeItem(at: catalogURL)
                    try syncDirectory(rootURL)
                }
            }
            guard rename(temporaryURL.path, catalogURL.path) == 0 else {
                throw posixError(for: catalogURL)
            }
            try syncDirectory(rootURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
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
