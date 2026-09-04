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
    private var activeTask: Task<ExportReceipt, Error>?

    @ObservationIgnored
    private var activeOperationID: UUID?

    init(
        parser: any MarkdownParsing,
        pdfExporter: PDFDocumentExporter = PDFDocumentExporter(),
        htmlExporter: HTMLDocumentExporter = HTMLDocumentExporter()
    ) {
        self.parser = parser
        self.pdfExporter = pdfExporter
        self.htmlExporter = htmlExporter
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

            let receipt: ExportReceipt
            switch request.format {
            case .pdf:
                receipt = try await pdfExporter.export(
                    parsed: parsed,
                    request: request,
                    collisionChoice: collisionChoice
                )
            case .html:
                receipt = try await htmlExporter.export(
                    parsed: parsed,
                    request: request,
                    collisionChoice: collisionChoice
                )
            }
            try Task.checkCancellation()
            self.phase = .installing
            self.progress = 0.92
            return receipt
        }
        activeTask = task

        do {
            let receipt = try await task.value
            guard activeOperationID == operationID else { throw CancellationError() }
            activeTask = nil
            activeOperationID = nil
            phase = .completed(receipt)
            progress = 1
            return receipt
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
        activeTask?.cancel()
        activeTask = nil
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
