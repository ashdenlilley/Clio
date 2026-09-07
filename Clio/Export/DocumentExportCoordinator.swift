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
    private let installer: DocumentExportInstaller

    @ObservationIgnored
    private var activeTask: Task<ExportReceipt, Error>?

    @ObservationIgnored
    private var activeOperationID: UUID?

    init(
        parser: any MarkdownParsing = SourcePreservingMarkdownParser(),
        fileManager: FileManager = .default,
        pdfExporter: PDFDocumentExporter? = nil,
        htmlExporter: HTMLDocumentExporter? = nil,
        recoveryCheckpointStore: any ExportRecoveryCheckpointing = ExportRecoveryCheckpointStore.shared,
        directoryWriter: any AtomicFileWriting = AtomicFileWriter(),
        fileGrantWriter: any AtomicFileWriting = ExportFileGrantWriter()
    ) {
        self.parser = parser
        self.pdfExporter = pdfExporter ?? PDFDocumentExporter(fileManager: fileManager)
        self.htmlExporter = htmlExporter ?? HTMLDocumentExporter(fileManager: fileManager)
        installer = DocumentExportInstaller(
            fileManager: fileManager,
            recoveryCheckpointStore: recoveryCheckpointStore,
            directoryWriter: directoryWriter,
            fileGrantWriter: fileGrantWriter
        )
    }

    func export(_ request: ExportRequest) async throws -> ExportReceipt {
        try await export(request, collisionResolution: nil)
    }

    func export(
        _ request: ExportRequest,
        collisionResolution: ExportCollisionResolution?,
        validateAuthority: @escaping @MainActor () throws -> Void = {}
    ) async throws -> ExportReceipt {
        activeTask?.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        phase = .parsing
        progress = nil

        let task = Task { @MainActor [
            parser,
            pdfExporter,
            htmlExporter,
            installer,
        ] in
            let parsed = try await parser.parse(request.snapshot)
            try Task.checkCancellation()
            guard parsed.canApply(to: request.snapshot) else {
                throw DocumentExportError.staleParse
            }
            self.phase = .rendering(request.format)

            let staged: StagedDocumentExport
            switch request.format {
            case .docx, .txt:
                staged = try EditableDocumentExporter.prepare(parsed: parsed, request: request, collisionResolution: collisionResolution)
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
            defer {
                Task(priority: .utility) {
                    await installer.discard(staged)
                }
            }

            guard self.activeOperationID == operationID else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            self.phase = .installing

            try validateAuthority()
            let receipt = try await installer.install(
                staged,
                strategy: request.recoveryStrategy
            )
            // Installer never suspends or checks cancellation between its
            // commit and receipt. Publish that receipt without another check.
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
