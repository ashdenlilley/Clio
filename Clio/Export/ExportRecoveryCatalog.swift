import Darwin
import Foundation

protocol ExportRecoveryCataloging: AnyObject, Sendable {
    /// Persists a security-scoped grant before an export can create an atomic
    /// transaction in this directory. A failure prevents the export from
    /// starting, because otherwise an abrupt exit could strand an artifact
    /// that Clio cannot inspect on relaunch.
    func remember(destinationDirectory: URL) throws
}

/// Export destinations may sit outside every searchable workspace. This
/// app-owned catalog retains only their parent grants, allowing startup to
/// recover crash-safe atomic transactions without broadly scanning the user's
/// filesystem or treating export folders as writing workspaces.
final class ExportRecoveryCatalog: ExportRecoveryCataloging, @unchecked Sendable {
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
        }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.bookmarkMaker = bookmarkMaker
        self.bookmarkResolver = bookmarkResolver
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

    /// Performs exact-directory scans. Workspace recovery remains recursive;
    /// export recovery inspects only manifests immediately beside destinations
    /// that were actually selected in NSSavePanel.
    @discardableResult
    func recoverInterruptedExports(
        journal: CrashRecoveryJournal
    ) throws -> Int {
        try queue.sync {
            let catalog = try load()
            var recovered = 0
            var refreshedEntries: [Entry] = []
            refreshedEntries.reserveCapacity(catalog.entries.count)

            for entry in catalog.entries {
                do {
                    let resolution = try bookmarkResolver(entry.bookmark)
                    let didStart = resolution.url.startAccessingSecurityScopedResource()
                    defer {
                        if didStart {
                            resolution.url.stopAccessingSecurityScopedResource()
                        }
                    }
                    recovered += try AtomicWriteTransactions
                        .recoverInterruptedTransactions(
                            in: resolution.url,
                            journal: journal,
                            recursively: false
                        )
                    let refreshedBookmark = resolution.isStale
                        ? try bookmarkMaker(resolution.url)
                        : entry.bookmark
                    refreshedEntries.append(Entry(
                        directoryURL: resolution.url,
                        bookmark: refreshedBookmark,
                        lastUsedAt: entry.lastUsedAt
                    ))
                } catch {
                    // Keep disconnected volumes and temporarily revoked roots
                    // in the bounded catalog so a later launch can retry.
                    refreshedEntries.append(entry)
                }
            }

            if refreshedEntries != catalog.entries {
                try persist(Catalog(
                    schemaVersion: Catalog.schemaVersion,
                    entries: refreshedEntries
                ))
            }
            return recovered
        }
    }
}

private extension ExportRecoveryCatalog {
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

    private func load() throws -> Catalog {
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return Catalog(schemaVersion: Catalog.schemaVersion, entries: [])
        }
        let values = try catalogURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= Self.maximumCatalogByteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: catalogURL)
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
