import Darwin
import Foundation

/// Safe-save adapter for an NSSavePanel file grant. It deliberately creates no
/// Clio-owned siblings beside the destination: those require a folder grant
/// that App Sandbox does not promise for save panels. The caller publishes an
/// app-container recovery checkpoint before entering this writer.
struct ExportFileGrantWriter: AtomicFileWriting {
    func replace(
        contents data: Data,
        at destinationURL: URL,
        onlyIf revision: DiskRevision?
    ) throws -> AtomicReplaceOutcome {
        try coordinate(at: destinationURL) { coordinatedURL in
            let current = try DocumentRevisionReader.revision(at: coordinatedURL)
            if let revision, !Workspace.sameContent(current, revision) {
                return .revisionMismatch(retainedURL: nil)
            }
            guard access(coordinatedURL.path, W_OK) == 0 else {
                throw CocoaError(
                    .fileWriteNoPermission,
                    userInfo: [NSFilePathErrorKey: coordinatedURL.path]
                )
            }
            try data.write(to: coordinatedURL, options: .atomic)
            try syncFile(coordinatedURL)
            let installed = try DocumentRevisionReader.revision(at: coordinatedURL)
            guard installed.byteCount == Int64(data.count),
                  installed.contentDigest == DocumentRevisionReader.digest(data) else {
                return .revisionMismatch(retainedURL: nil)
            }
            return .replaced
        }
    }

    func create(contents data: Data, at destinationURL: URL) throws -> Bool {
        try coordinate(at: destinationURL) { coordinatedURL in
            guard !FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                return false
            }
            do {
                try data.write(
                    to: coordinatedURL,
                    options: .withoutOverwriting
                )
                try syncFile(coordinatedURL)
                return true
            } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && error.code == CocoaError.fileWriteFileExists.rawValue {
                return false
            }
        }
    }
}

private extension ExportFileGrantWriter {
    func coordinate<T>(
        at destinationURL: URL,
        _ operation: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: destinationURL.standardizedFileURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: destinationURL.path]
            )
        }
        return try result.get()
    }

    func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }
}
