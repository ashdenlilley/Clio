import Foundation

enum DocumentExportError: LocalizedError, Equatable {
    case destinationExists(URL)
    case invalidPrintSettings
    case staleParse
    case emptyPDFPage
    case couldNotCreatePDF(URL)
    case unsupportedDestination(URL)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let url):
            "A file named \(url.lastPathComponent) already exists."
        case .invalidPrintSettings:
            "The selected paper size and margins leave no printable area."
        case .staleParse:
            "The document changed while Clio was preparing the export. Try again."
        case .emptyPDFPage:
            "Clio could not fit any document content on the selected page."
        case .couldNotCreatePDF(let url):
            "Clio could not create a PDF at \(url.path)."
        case .unsupportedDestination(let url):
            "Clio cannot export to \(url.path)."
        }
    }
}

enum ExportDestination {
    static func resolve(
        requestedURL: URL,
        choice: CollisionChoice?,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = requestedURL.standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else { return url }

        switch choice {
        case .cancel:
            throw CancellationError()
        case .replace:
            return url
        case .keepBoth:
            return try firstAvailableVariant(of: url, fileManager: fileManager)
        case nil:
            throw DocumentExportError.destinationExists(url)
        }
    }

    static func install(
        temporaryURL: URL,
        at destinationURL: URL,
        replacing: Bool,
        fileManager: FileManager = .default
    ) throws {
        try Task.checkCancellation()
        if replacing, fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}

private extension ExportDestination {
    static let maximumCollisionAttempts = 10_000

    static func firstAvailableVariant(
        of url: URL,
        fileManager: FileManager
    ) throws -> URL {
        let extensionName = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()

        for number in 2...maximumCollisionAttempts {
            let filename = extensionName.isEmpty
                ? "\(stem) (\(number))"
                : "\(stem) (\(number)).\(extensionName)"
            let candidate = parent.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw DocumentExportError.unsupportedDestination(url)
    }
}

extension URL {
    func clioTemporarySibling() -> URL {
        deletingLastPathComponent().appendingPathComponent(
            ".clio-export-\(UUID().uuidString).tmp"
        )
    }
}
