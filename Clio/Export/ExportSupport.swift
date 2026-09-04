import Foundation

enum DocumentExportError: LocalizedError, Equatable {
    case destinationExists(ExportCollision)
    case destinationChanged(URL, current: ExportCollision?, retainedURL: URL?)
    case invalidCollisionResolution
    case invalidPrintSettings
    case staleParse
    case emptyPDFPage
    case couldNotCreatePDF(URL)
    case unsupportedDestination(URL)
    case artifactTooLarge(URL, byteCount: Int64, maximumByteCount: Int64)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let collision):
            "A file named \(collision.destinationURL.lastPathComponent) already exists."
        case .destinationChanged(let url, _, let retainedURL):
            if retainedURL != nil {
                "\(url.lastPathComponent) changed while Clio was exporting. The unexpected bytes were retained for recovery; choose again."
            } else {
                "\(url.lastPathComponent) changed while Clio was exporting. Choose again."
            }
        case .invalidCollisionResolution:
            "That collision choice belongs to a different export. Choose again."
        case .invalidPrintSettings:
            "The selected paper size and margins leave no printable area."
        case .staleParse:
            "The document changed while Clio was preparing the export. Try again."
        case .emptyPDFPage:
            "Clio could not fit any document content on the selected page."
        case .couldNotCreatePDF(let url):
            "Clio could not create a PDF at \(url.path)."
        case .unsupportedDestination(let url):
            "Clio cannot export to \(url.path). Choose a regular file destination."
        case .artifactTooLarge(let url, let byteCount, let maximumByteCount):
            "\(url.lastPathComponent) expanded to \(byteCount.formatted(.byteCount(style: .file))), beyond Clio's recoverable export limit of \(maximumByteCount.formatted(.byteCount(style: .file)))."
        }
    }

    var retryCollision: ExportCollision? {
        switch self {
        case .destinationExists(let collision): return collision
        case .destinationChanged(_, let current, _): return current
        default: return nil
        }
    }

    var retainedRecoveryURL: URL? {
        guard case .destinationChanged(_, _, let retainedURL) = self else { return nil }
        return retainedURL
    }
}

enum ExportDestinationCommit: Sendable, Equatable {
    case create
    case replace(expectedRevision: DiskRevision)
}

struct ExportDestinationReservation: Sendable, Equatable {
    let url: URL
    let commit: ExportDestinationCommit
}

enum ExportDestination {
    static func resolve(
        requestedURL: URL,
        resolution: ExportCollisionResolution?,
        fileManager: FileManager = .default
    ) throws -> ExportDestinationReservation {
        let url = requestedURL.standardizedFileURL
        let current = try collision(at: url, fileManager: fileManager)
        guard let resolution else {
            if let current { throw DocumentExportError.destinationExists(current) }
            return ExportDestinationReservation(url: url, commit: .create)
        }
        guard resolution.collision.destinationURL.standardizedFileURL == url else {
            throw DocumentExportError.invalidCollisionResolution
        }
        switch resolution.choice {
        case .cancel:
            throw CancellationError()
        case .replace:
            guard current?.revision == resolution.collision.revision else {
                throw DocumentExportError.destinationChanged(
                    url,
                    current: current,
                    retainedURL: nil
                )
            }
            return ExportDestinationReservation(
                url: url,
                commit: .replace(expectedRevision: resolution.collision.revision)
            )
        case .keepBoth:
            return ExportDestinationReservation(
                url: try firstAvailableVariant(of: url, fileManager: fileManager),
                commit: .create
            )
        }
    }

    static func collision(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> ExportCollision? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw DocumentExportError.unsupportedDestination(url)
            }
            return ExportCollision(
                destinationURL: url,
                revision: try DocumentRevisionReader.revision(at: url)
            )
        } catch let error as DocumentExportError {
            throw error
        } catch let error as NSError
        where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
    }
}

enum ExportContentPolicy {
    static func safeLink(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: {
                  $0.value <= 0x20 || (0x7f...0x9f).contains($0.value)
              }),
              let components = URLComponents(string: value) else {
            return nil
        }
        guard let scheme = components.scheme?.lowercased() else {
            return value.hasPrefix("/") || value.hasPrefix("\\") ? nil : value
        }
        return ["http", "https", "mailto"].contains(scheme) ? value : nil
    }
}

/// A complete export that has not crossed the atomic destination boundary.
struct StagedDocumentExport: Sendable {
    let format: ExportFormat
    let temporaryURL: URL
    let reservation: ExportDestinationReservation
    let byteCount: Int64
    let documentID: DocumentID
    let generation: BufferGeneration
    let sourceFingerprint: String

    var destinationURL: URL { reservation.url }

    func install(
        fileManager: FileManager = .default,
        writer: any AtomicFileWriting = AtomicFileWriter()
    ) throws -> ExportReceipt {
        try Task.checkCancellation()
        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        try Task.checkCancellation()
        switch reservation.commit {
        case .create:
            guard try writer.create(contents: data, at: destinationURL) else {
                let collision = try ExportDestination.collision(
                    at: destinationURL,
                    fileManager: fileManager
                )
                guard let collision else {
                    throw DocumentExportError.destinationChanged(
                        destinationURL,
                        current: nil,
                        retainedURL: nil
                    )
                }
                throw DocumentExportError.destinationExists(collision)
            }
        case .replace(let expectedRevision):
            let outcome = try writer.replace(
                contents: data,
                at: destinationURL,
                onlyIf: expectedRevision
            )
            if case .revisionMismatch(let retainedURL) = outcome {
                let current = try? ExportDestination.collision(
                    at: destinationURL,
                    fileManager: fileManager
                )
                throw DocumentExportError.destinationChanged(
                    destinationURL,
                    current: current ?? nil,
                    retainedURL: retainedURL
                )
            }
        }
        try? fileManager.removeItem(at: temporaryURL)
        return ExportReceipt(
            format: format,
            destinationURL: destinationURL,
            byteCount: byteCount,
            completedAt: Date(),
            generation: generation,
            sourceFingerprint: sourceFingerprint
        )
    }

    func discard(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: temporaryURL)
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
            if try collision(at: candidate, fileManager: fileManager) == nil {
                return candidate
            }
        }
        throw DocumentExportError.unsupportedDestination(url)
    }
}

extension URL {
    func clioExportStagingURL(
        format: ExportFormat,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Clio Export Staging", isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DocumentExportError.unsupportedDestination(root)
        }
        return root.appendingPathComponent(
            "export-\(UUID().uuidString.lowercased()).\(format.rawValue)",
            isDirectory: false
        )
    }
}
