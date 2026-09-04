import Foundation
import Observation

enum DocumentExportPhase: Equatable, Sendable {
    case idle
    case parsing
    case rendering(ExportFormat)
    case installing
    case completed(ExportReceipt)
    case failed(String)
    case cancelled
}

@MainActor
@Observable
final class DocumentExportCoordinator: DocumentExportCoordinating {
    private(set) var phase: DocumentExportPhase = .idle
    /// Rendering and parsing are intentionally indeterminate. A numeric value
    /// is exposed only once the atomic installation has completed.
    private(set) var progress: Double?

    @ObservationIgnored
    private let parser: any MarkdownParsing

    @ObservationIgnored
    private let pdfExporter: PDFDocumentExporter

    @ObservationIgnored
    private let htmlExporter: HTMLDocumentExporter

    @ObservationIgnored
    private let fileManager: FileManager

    @ObservationIgnored
    private var activeTask: Task<ExportReceipt, Error>?

    @ObservationIgnored
    private var activeOperationID: UUID?

    init(
        parser: any MarkdownParsing = SourcePreservingMarkdownParser(),
        fileManager: FileManager = .default,
        pdfExporter: PDFDocumentExporter? = nil,
        htmlExporter: HTMLDocumentExporter? = nil
    ) {
        self.parser = parser
        self.fileManager = fileManager
        self.pdfExporter = pdfExporter ?? PDFDocumentExporter(fileManager: fileManager)
        self.htmlExporter = htmlExporter ?? HTMLDocumentExporter(fileManager: fileManager)
    }

    func export(_ request: ExportRequest) async throws -> ExportReceipt {
        try await export(request, collisionResolution: nil)
    }

    func export(
        _ request: ExportRequest,
        collisionResolution: ExportCollisionResolution?
    ) async throws -> ExportReceipt {
        activeTask?.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        phase = .parsing
        progress = nil

        let task = Task { @MainActor [parser, pdfExporter, htmlExporter] in
            let parsed = try await parser.parse(request.snapshot)
            try Task.checkCancellation()
            guard parsed.canApply(to: request.snapshot) else {
                throw DocumentExportError.staleParse
            }
            self.phase = .rendering(request.format)

            let staged: StagedDocumentExport
            switch request.format {
            case .pdf:
                staged = try await pdfExporter.prepare(
                    parsed: parsed,
                    request: request,
                    collisionResolution: collisionResolution
                )
            case .html:
                staged = try await htmlExporter.prepare(
                    parsed: parsed,
                    request: request,
                    collisionResolution: collisionResolution
                )
            }
            defer { staged.discard(fileManager: self.fileManager) }

            guard self.activeOperationID == operationID else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            self.phase = .installing

            // There must be no suspension or cancellation check between this
            // atomic filesystem commit and publishing completion.
            let receipt = try staged.install(fileManager: self.fileManager)
            self.activeTask = nil
            self.activeOperationID = nil
            self.phase = .completed(receipt)
            self.progress = 1
            return receipt
        }
        activeTask = task

        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            if activeOperationID == operationID {
                activeTask = nil
                activeOperationID = nil
                phase = .cancelled
                progress = nil
            }
            throw CancellationError()
        } catch {
            if activeOperationID == operationID {
                activeTask = nil
                activeOperationID = nil
                phase = .failed(error.localizedDescription)
                progress = nil
            }
            throw error
        }
    }

    func cancel() {
        guard let activeTask else { return }
        activeTask.cancel()
        self.activeTask = nil
        activeOperationID = nil
        phase = .cancelled
        progress = nil
    }

    func reset() {
        guard activeTask == nil else { return }
        phase = .idle
        progress = nil
    }
}
