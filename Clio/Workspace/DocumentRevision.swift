import CryptoKit
import Darwin
import Foundation

enum DocumentRevisionReader {
    static func sameContent(_ lhs: DiskRevision, _ rhs: DiskRevision) -> Bool {
        lhs.byteCount == rhs.byteCount && lhs.contentDigest == rhs.contentDigest
    }
    static let maximumDocumentByteCount = Int64(
        PerformanceContract.safeLargeFileByteLimit
    )

    enum RevisionError: LocalizedError {
        case notRegularFile(URL)
        case fileTooLarge(URL, byteCount: Int64, maximumByteCount: Int64)
        case changedWhileReading(URL)

        var errorDescription: String? {
            switch self {
            case .notRegularFile(let url):
                "The document no longer exists at \(url.path)."
            case .fileTooLarge(let url, let byteCount, let maximumByteCount):
                "\(url.lastPathComponent) is \(byteCount.formatted(.byteCount(style: .file))) and exceeds Clio's \(maximumByteCount.formatted(.byteCount(style: .file))) safe-file limit. It was left unopened."
            case .changedWhileReading(let url):
                "\(url.lastPathComponent) changed while Clio was reading it. Try again."
            }
        }
    }

    /// Reads from one opened inode, bounds allocation before the first byte is
    /// materialized, and rejects an in-place mutation instead of returning a
    /// torn mixture of two outside versions.
    static func snapshot(
        at url: URL,
        maximumByteCount: Int64? = nil
    ) throws -> (data: Data, revision: DiskRevision) {
        let standardizedURL = url.standardizedFileURL
        let descriptor = open(standardizedURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError(for: standardizedURL) }
        defer { close(descriptor) }

        let initial = try fileStatus(descriptor, url: standardizedURL)
        try validateRegularFile(initial, url: standardizedURL)
        try validateSize(initial.st_size, maximumByteCount: maximumByteCount, url: standardizedURL)

        let data = try readData(
            descriptor,
            expectedByteCount: initial.st_size,
            maximumByteCount: maximumByteCount,
            url: standardizedURL
        )
        let final = try fileStatus(descriptor, url: standardizedURL)
        guard sameOpenedRevision(initial, final), final.st_size == data.count else {
            throw RevisionError.changedWhileReading(standardizedURL)
        }
        let revision = DiskRevision(
            modificationDate: modificationDate(final),
            byteCount: Int64(data.count),
            contentDigest: digest(data)
        )
        return (data, revision)
    }

    static func documentSnapshot(
        at url: URL
    ) throws -> (data: Data, revision: DiskRevision) {
        try snapshot(at: url, maximumByteCount: maximumDocumentByteCount)
    }

    /// Cheap no-follow size probe used only to route hydration away from the
    /// UI executor. The actual read repeats every safety check below.
    static func byteCount(at url: URL) throws -> Int64 {
        let standardizedURL = url.standardizedFileURL
        let descriptor = open(standardizedURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError(for: standardizedURL) }
        defer { close(descriptor) }
        let status = try fileStatus(descriptor, url: standardizedURL)
        try validateRegularFile(status, url: standardizedURL)
        return status.st_size
    }

    static func revision(
        at url: URL,
        maximumByteCount: Int64? = nil
    ) throws -> DiskRevision {
        let standardizedURL = url.standardizedFileURL
        let descriptor = open(standardizedURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError(for: standardizedURL) }
        defer { close(descriptor) }

        let initial = try fileStatus(descriptor, url: standardizedURL)
        try validateRegularFile(initial, url: standardizedURL)
        try validateSize(
            initial.st_size,
            maximumByteCount: maximumByteCount,
            url: standardizedURL
        )
        var hasher = SHA256()
        var hashedByteCount: Int64 = 0
        let byteCount = try readChunks(descriptor, url: standardizedURL) { chunk in
            hashedByteCount += Int64(chunk.count)
            try validateSize(
                hashedByteCount,
                maximumByteCount: maximumByteCount,
                url: standardizedURL
            )
            hasher.update(data: chunk)
        }
        let final = try fileStatus(descriptor, url: standardizedURL)
        guard sameOpenedRevision(initial, final), final.st_size == byteCount else {
            throw RevisionError.changedWhileReading(standardizedURL)
        }
        return DiskRevision(
            modificationDate: modificationDate(final),
            byteCount: Int64(byteCount),
            contentDigest: hexDigest(hasher.finalize())
        )
    }

    static func digest(_ data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }
}

private extension DocumentRevisionReader {
    static let readChunkByteCount = 1_024 * 1_024

    static func readData(
        _ descriptor: Int32,
        expectedByteCount: Int64,
        maximumByteCount: Int64?,
        url: URL
    ) throws -> Data {
        var result = Data()
        if expectedByteCount > 0, expectedByteCount <= Int64(Int.max) {
            result.reserveCapacity(Int(expectedByteCount))
        }
        let byteCount = try readChunks(descriptor, url: url) { chunk in
            result.append(chunk)
            if let maximumByteCount, result.count > maximumByteCount {
                throw RevisionError.fileTooLarge(
                    url,
                    byteCount: Int64(result.count),
                    maximumByteCount: maximumByteCount
                )
            }
        }
        try validateSize(Int64(byteCount), maximumByteCount: maximumByteCount, url: url)
        return result
    }

    static func readChunks(
        _ descriptor: Int32,
        url: URL,
        consume: (Data) throws -> Void
    ) throws -> Int {
        var total = 0
        var storage = [UInt8](repeating: 0, count: readChunkByteCount)
        while true {
            try Task.checkCancellation()
            let count = read(descriptor, &storage, storage.count)
            if count == 0 { return total }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(for: url)
            }
            total += count
            try storage.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                try consume(Data(bytes: baseAddress, count: count))
            }
        }
    }

    static func fileStatus(_ descriptor: Int32, url: URL) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw posixError(for: url) }
        return value
    }

    static func validateRegularFile(_ value: stat, url: URL) throws {
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw RevisionError.notRegularFile(url)
        }
    }

    static func validateSize(
        _ byteCount: Int64,
        maximumByteCount: Int64?,
        url: URL
    ) throws {
        guard let maximumByteCount, byteCount > maximumByteCount else { return }
        throw RevisionError.fileTooLarge(
            url,
            byteCount: byteCount,
            maximumByteCount: maximumByteCount
        )
    }

    static func sameOpenedRevision(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func modificationDate(_ value: stat) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    static func hexDigest<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func posixError(for url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
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

private struct DestinationFileMetadata {
    let sourceURL: URL

    static func capture(at url: URL) throws -> Self {
        let destination = url.standardizedFileURL
        var status = stat()
        let result = destination.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &status)
        }
        guard result == 0 else { throw posixError(for: destination) }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw DocumentRevisionReader.RevisionError.notRegularFile(destination)
        }
        guard access(destination.path, W_OK) == 0 else {
            throw CocoaError(
                .fileWriteNoPermission,
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
        return Self(sourceURL: destination)
    }

    func apply(to candidateURL: URL) throws {
        let flags = copyfile_flags_t(
            COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST
        )
        let result = copyfile(sourceURL.path, candidateURL.path, nil, flags)
        guard result == 0 else { throw Self.posixError(for: candidateURL) }

        // Metadata copy intentionally retains mode, ACLs, Finder tags, and
        // other xattrs, but new canonical bytes receive a new modification
        // date so external-change comparison remains meaningful.
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: candidateURL.path
        )
        try Self.syncFile(candidateURL)
    }

    private static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError(for: url) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(for: url) }
    }

    private static func posixError(for url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
}

struct AtomicFileWriter: AtomicFileWriting {
    var beforeSwap: (() throws -> Void)?
    var afterSwap: (() throws -> Void)?
    var phaseHook: ((AtomicWritePhase) throws -> Void)?

    func replace(
        contents data: Data,
        at destinationURL: URL,
        onlyIf revision: DiskRevision? = nil
    ) throws -> AtomicReplaceOutcome {
        let destinationMetadata = try DestinationFileMetadata.capture(
            at: destinationURL
        )
        let transaction = try AtomicWriteTransactions.begin(
            contents: data,
            destinationURL: destinationURL,
            operation: .replace,
            expectedRevision: revision
        )
        try phaseHook?(.manifestSynced)
        let temporaryURL = transaction.manifest.temporaryURL
        try writeAndSync(data, to: temporaryURL)
        try destinationMetadata.apply(to: temporaryURL)
        try phaseHook?(.candidateSynced)

        guard let revision else {
            _ = try DestinationFileMetadata.capture(at: destinationURL)
            guard rename(temporaryURL.path, destinationURL.path) == 0 else {
                throw posixError(for: destinationURL)
            }
            try phaseHook?(.swapped)
            try syncParent(of: destinationURL)
            try phaseHook?(.parentSynced)
            try AtomicWriteTransactions.finish(transaction, removeTemporary: false)
            return .replaced
        }

        try beforeSwap?()
        let currentMetadata = try DestinationFileMetadata.capture(at: destinationURL)
        try currentMetadata.apply(to: temporaryURL)
        let swapResult = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_SWAP))
            }
        }
        guard swapResult == 0 else { throw posixError(for: destinationURL) }
        try phaseHook?(.swapped)
        do {
            try afterSwap?()
        } catch {
            // The destination now contains Clio's candidate and the temporary
            // file contains the exact displaced inode. Never erase those
            // outside bytes if an injected post-swap operation fails.
            throw error
        }

        let displaced = try DocumentRevisionReader.revision(at: temporaryURL)
        let installed = try DocumentRevisionReader.revision(at: destinationURL)
        let localRevision = DiskRevision(
            modificationDate: installed.modificationDate,
            byteCount: Int64(data.count),
            contentDigest: DocumentRevisionReader.digest(data)
        )
        let destinationStillContainsLocal = DocumentRevisionReader.sameContent(installed, localRevision)
        try phaseHook?(.validated)

        if DocumentRevisionReader.sameContent(displaced, revision), destinationStillContainsLocal {
            try syncParent(of: destinationURL)
            try phaseHook?(.parentSynced)
            try AtomicWriteTransactions.finish(transaction, removeTemporary: true)
            return .replaced
        }

        if !DocumentRevisionReader.sameContent(displaced, revision), destinationStillContainsLocal {
            let restoreResult = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
                destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                    renamex_np(sourcePath, destinationPath, UInt32(RENAME_SWAP))
                }
            }
            guard restoreResult == 0 else {
                return .revisionMismatch(retainedURL: temporaryURL)
            }
            try syncParent(of: destinationURL)
            try phaseHook?(.parentSynced)
            try AtomicWriteTransactions.finish(transaction, removeTemporary: true)
            return .revisionMismatch(retainedURL: nil)
        }

        // A third writer touched the destination after our swap. Leave its
        // bytes in place and retain the displaced inode regardless of whether
        // it matched the approved revision: restoring it would overwrite the
        // newest occupant, while deleting it would discard external bytes.
        return .revisionMismatch(retainedURL: temporaryURL)
    }

    func create(contents data: Data, at destinationURL: URL) throws -> Bool {
        let transaction = try AtomicWriteTransactions.begin(
            contents: data,
            destinationURL: destinationURL,
            operation: .create,
            expectedRevision: nil
        )
        try phaseHook?(.manifestSynced)
        let temporaryURL = transaction.manifest.temporaryURL
        try writeAndSync(data, to: temporaryURL)
        try phaseHook?(.candidateSynced)

        let result = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 {
            try phaseHook?(.swapped)
            try syncParent(of: destinationURL)
            try phaseHook?(.parentSynced)
            try AtomicWriteTransactions.finish(transaction, removeTemporary: false)
            return true
        }
        if errno == EEXIST {
            try AtomicWriteTransactions.finish(transaction, removeTemporary: true)
            return false
        }
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

    private func posixError(for url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
}
