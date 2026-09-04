import CryptoKit
import Darwin
import Foundation

enum DocumentRevisionReader {
    enum RevisionError: LocalizedError {
        case notRegularFile(URL)

        var errorDescription: String? {
            switch self {
            case .notRegularFile(let url):
                "The document no longer exists at \(url.path)."
            }
        }
    }

    static func snapshot(at url: URL) throws -> (data: Data, revision: DiskRevision) {
        let standardizedURL = url.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ])
        guard values.isRegularFile == true else {
            throw RevisionError.notRegularFile(standardizedURL)
        }

        let data = try Data(contentsOf: standardizedURL, options: .mappedIfSafe)
        let revision = DiskRevision(
            modificationDate: values.contentModificationDate ?? .distantPast,
            byteCount: Int64(data.count),
            contentDigest: digest(data)
        )
        return (data, revision)
    }

    static func revision(at url: URL) throws -> DiskRevision {
        try snapshot(at: url).revision
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

protocol AtomicFileWriting {
    func replace(
        contents data: Data,
        at destinationURL: URL,
        onlyIf revision: DiskRevision?
    ) throws -> AtomicReplaceOutcome
    func create(contents data: Data, at destinationURL: URL) throws -> Bool
}

enum AtomicReplaceOutcome: Equatable {
    case replaced
    /// The expected revision lost the race. A retained URL is supplied only
    /// when a second writer changed the destination after the atomic swap;
    /// it contains the displaced outside bytes and must not be deleted.
    case revisionMismatch(retainedURL: URL?)
}

struct AtomicFileWriter: AtomicFileWriting {
    var beforeSwap: (() throws -> Void)?
    var afterSwap: (() throws -> Void)?

    func replace(
        contents data: Data,
        at destinationURL: URL,
        onlyIf revision: DiskRevision? = nil
    ) throws -> AtomicReplaceOutcome {
        let temporaryURL = temporaryURL(beside: destinationURL)
        try writeAndSync(data, to: temporaryURL)
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        guard let revision else {
            guard rename(temporaryURL.path, destinationURL.path) == 0 else {
                throw posixError(for: destinationURL)
            }
            try syncParent(of: destinationURL)
            return .replaced
        }

        try beforeSwap?()
        let swapResult = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_SWAP))
            }
        }
        guard swapResult == 0 else { throw posixError(for: destinationURL) }
        // From this point the temporary URL owns the exact displaced inode.
        // Retain it by default across every exceptional path until we have
        // positively established that deleting it is safe.
        shouldRemoveTemporary = false
        do {
            try afterSwap?()
        } catch {
            // The destination now contains Clio's candidate and the temporary
            // file contains the exact displaced inode. Never erase those
            // outside bytes if an injected post-swap operation fails.
            shouldRemoveTemporary = false
            throw error
        }

        let displaced = try DocumentRevisionReader.revision(at: temporaryURL)
        let installed = try DocumentRevisionReader.revision(at: destinationURL)
        let localRevision = DiskRevision(
            modificationDate: installed.modificationDate,
            byteCount: Int64(data.count),
            contentDigest: DocumentRevisionReader.digest(data)
        )
        let destinationStillContainsLocal = Workspace.sameContent(installed, localRevision)

        if Workspace.sameContent(displaced, revision), destinationStillContainsLocal {
            try syncParent(of: destinationURL)
            shouldRemoveTemporary = true
            return .replaced
        }

        if !Workspace.sameContent(displaced, revision), destinationStillContainsLocal {
            let restoreResult = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
                destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                    renamex_np(sourcePath, destinationPath, UInt32(RENAME_SWAP))
                }
            }
            guard restoreResult == 0 else {
                return .revisionMismatch(retainedURL: temporaryURL)
            }
            shouldRemoveTemporary = true
            try syncParent(of: destinationURL)
            return .revisionMismatch(retainedURL: nil)
        }

        // A third writer touched the destination after our swap. Leave its
        // bytes in place and retain the displaced inode regardless of whether
        // it matched the approved revision: restoring it would overwrite the
        // newest occupant, while deleting it would discard external bytes.
        return .revisionMismatch(retainedURL: temporaryURL)
    }

    func create(contents data: Data, at destinationURL: URL) throws -> Bool {
        let temporaryURL = temporaryURL(beside: destinationURL)
        try writeAndSync(data, to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let result = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 {
            try syncParent(of: destinationURL)
            return true
        }
        if errno == EEXIST { return false }
        throw posixError(for: destinationURL)
    }

    private func writeAndSync(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        let descriptor = open(url.path, O_WRONLY)
        guard descriptor >= 0 else { throw posixError(for: url) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(for: url) }
    }

    private func syncParent(of url: URL) throws {
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError(for: url) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(for: url) }
    }

    private func temporaryURL(beside destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".clio-save-\(UUID().uuidString)",
            isDirectory: false
        )
    }

    private func posixError(for url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
}
