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
    private(set) var progress: Double = 0

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
        parser: any MarkdownParsing,
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
        try await export(request, collisionChoice: nil)
    }

    func export(
        _ request: ExportRequest,
        collisionChoice: CollisionChoice?
    ) async throws -> ExportReceipt {
        activeTask?.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        phase = .parsing
        progress = 0.08

        let task = Task { @MainActor [parser, pdfExporter, htmlExporter] in
            let parsed = try await parser.parse(request.snapshot)
            try Task.checkCancellation()
            guard parsed.canApply(to: request.snapshot) else {
                throw DocumentExportError.staleParse
            }
            self.phase = .rendering(request.format)
            self.progress = 0.35

            let staged: StagedDocumentExport
            switch request.format {
            case .pdf:
                staged = try await pdfExporter.prepare(
                    parsed: parsed,
                    request: request,
                    collisionChoice: collisionChoice
                )
            case .html:
                staged = try await htmlExporter.prepare(
                    parsed: parsed,
                    request: request,
                    collisionChoice: collisionChoice
                )
            }
            defer { staged.discard(fileManager: self.fileManager) }

            guard self.activeOperationID == operationID else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            self.phase = .installing
            self.progress = 0.92

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
                progress = 0
            }
            throw CancellationError()
        } catch {
            if activeOperationID == operationID {
                activeTask = nil
                activeOperationID = nil
                phase = .failed(error.localizedDescription)
                progress = 0
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
        progress = 0
    }

    func reset() {
        guard activeTask == nil else { return }
        phase = .idle
        progress = 0
    }
}
