import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ExportPresentationError: LocalizedError, Equatable {
    case noDocument
    case noWindow
    case invalidCommandArguments([String])

    var errorDescription: String? {
        switch self {
        case .noDocument:
            return "There is no document to export."
        case .noWindow:
            return "Clio could not find the document window for this export."
        case .invalidCommandArguments(let arguments):
            let supplied = arguments.joined(separator: " ")
            return "Unknown export format “\(supplied)”. Use /export, /export pdf, or /export html."
        }
    }
}

enum ExportCommandRoute {
    /// No argument deliberately means “ask”. Both the command palette and an
    /// inline `/export` invocation enter the same window-scoped flow.
    static func format(for arguments: [String]) throws -> ExportFormat? {
        guard !arguments.isEmpty else { return nil }
        guard arguments.count == 1,
              let format = ExportFormat(rawValue: arguments[0].lowercased()) else {
            throw ExportPresentationError.invalidCommandArguments(arguments)
        }
        return format
    }
}

struct ExportSavePanelConfiguration: Equatable, Sendable {
    let format: ExportFormat
    let title: String
    let prompt: String
    let suggestedFilename: String
    let contentTypeIdentifier: String

    static func make(format: ExportFormat, sourceFilename: String) -> Self {
        let source = sourceFilename as NSString
        let stem = source.deletingPathExtension.isEmpty
            ? "Untitled"
            : source.deletingPathExtension
        switch format {
        case .pdf:
            return Self(
                format: format,
                title: "Export PDF",
                prompt: "Export",
                suggestedFilename: "\(stem).pdf",
                contentTypeIdentifier: UTType.pdf.identifier
            )
        case .html:
            return Self(
                format: format,
                title: "Export HTML",
                prompt: "Export",
                suggestedFilename: "\(stem).html",
                contentTypeIdentifier: UTType.html.identifier
            )
        }
    }
}

@MainActor
protocol ExportPanelPresenting: AnyObject {
    func chooseDestination(
        configuration: ExportSavePanelConfiguration,
        initialDirectory: URL?,
        on window: NSWindow
    ) async -> URL?

    func choosePageSetup(
        current: PDFPrintSettings,
        on window: NSWindow
    ) async -> PDFPrintSettings?
}

@MainActor
final class NativeExportPanelPresenter: ExportPanelPresenting {
    func chooseDestination(
        configuration: ExportSavePanelConfiguration,
        initialDirectory: URL?,
        on window: NSWindow
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = configuration.title
        panel.prompt = configuration.prompt
        panel.nameFieldStringValue = configuration.suggestedFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.directoryURL = initialDirectory
        if let type = UTType(configuration.contentTypeIdentifier) {
            panel.allowedContentTypes = [type]
        }

        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    func choosePageSetup(
        current: PDFPrintSettings,
        on window: NSWindow
    ) async -> PDFPrintSettings? {
        let printInfo = current.clioPrintInfo()
        let pageLayout = NSPageLayout()
        return await withCheckedContinuation { continuation in
            pageLayout.beginSheet(using: printInfo, on: window) { result in
                let settings = result == .changed
                    ? PDFPrintSettingsStore.systemDefault(printInfo: printInfo)
                    : nil
                continuation.resume(returning: settings)
            }
        }
    }
}

struct ExportFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let canRetry: Bool
}

enum ExportFailureMapper {
    static func failure(for error: Error) -> ExportFailure {
        let nsError = error as NSError
        let chain = errorChain(startingAt: nsError)
        if chain.contains(where: isOutOfSpace) {
            return ExportFailure(
                title: "Not enough disk space",
                message: "Clio left the existing file untouched. Free space on the destination volume, then retry.",
                canRetry: true
            )
        }
        if chain.contains(where: isPermissionFailure) {
            return ExportFailure(
                title: "Destination is not writable",
                message: "Clio left the existing file untouched. Restore folder access or choose another destination, then retry.",
                canRetry: true
            )
        }
        if chain.contains(where: isMissingDestination) {
            return ExportFailure(
                title: "Destination is unavailable",
                message: "Clio left the existing file untouched. Reconnect the volume or restore folder access, then retry.",
                canRetry: true
            )
        }
        return ExportFailure(
            title: "Export failed",
            message: error.localizedDescription,
            canRetry: !(error is CancellationError)
        )
    }
}

private extension ExportFailureMapper {
    static func errorChain(startingAt error: NSError) -> [NSError] {
        var result: [NSError] = []
        var cursor: NSError? = error
        while let current = cursor, result.count < 8 {
            result.append(current)
            cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    static func isOutOfSpace(_ error: NSError) -> Bool {
        (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
            || (error.domain == NSCocoaErrorDomain
                && error.code == CocoaError.fileWriteOutOfSpace.rawValue)
    }

    static func isPermissionFailure(_ error: NSError) -> Bool {
        (error.domain == NSPOSIXErrorDomain
            && [EACCES, EPERM, EROFS].map(Int.init).contains(error.code))
            || (error.domain == NSCocoaErrorDomain
                && [
                    CocoaError.fileWriteNoPermission.rawValue,
                    CocoaError.fileWriteVolumeReadOnly.rawValue,
                ].contains(error.code))
    }

    static func isMissingDestination(_ error: NSError) -> Bool {
        (error.domain == NSPOSIXErrorDomain
            && [ENOENT, ENODEV, ESTALE].map(Int.init).contains(error.code))
            || (error.domain == NSCocoaErrorDomain
                && [
                    CocoaError.fileNoSuchFile.rawValue,
                ].contains(error.code))
    }
}

@MainActor
@Observable
final class DocumentExportPresentation {
    private(set) var isOptionsPresented = false
    private(set) var isExporting = false
    private(set) var selectedFormat: ExportFormat = .pdf
    private(set) var pendingCollision: ExportCollision?
    private(set) var failure: ExportFailure?
    private(set) var completedReceipt: ExportReceipt?

    @ObservationIgnored
    let coordinator: DocumentExportCoordinator

    @ObservationIgnored
    let printSettingsStore: PDFPrintSettingsStore

    @ObservationIgnored
    private let panelPresenter: any ExportPanelPresenting

    @ObservationIgnored
    private let recoveryCatalog: any ExportRecoveryCataloging

    @ObservationIgnored
    private var snapshotProvider: (@MainActor () async throws -> DocumentTextSnapshot)?

    @ObservationIgnored
    private var sourceURLProvider: (@MainActor () -> URL?)?

    @ObservationIgnored
    private var sourceFilenameProvider: (@MainActor () -> String)?

    @ObservationIgnored
    private var windowProvider: (@MainActor () -> NSWindow?)?

    @ObservationIgnored
    private var operationTask: Task<Void, Never>?

    @ObservationIgnored
    private var retryRequest: ExportRequest?

    convenience init() {
        self.init(
            coordinator: DocumentExportCoordinator(),
            printSettingsStore: PDFPrintSettingsStore(),
            panelPresenter: NativeExportPanelPresenter(),
            recoveryCatalog: ExportRecoveryCatalog.shared
        )
    }

    init(
        coordinator: DocumentExportCoordinator,
        printSettingsStore: PDFPrintSettingsStore,
        panelPresenter: any ExportPanelPresenting,
        recoveryCatalog: any ExportRecoveryCataloging
    ) {
        self.coordinator = coordinator
        self.printSettingsStore = printSettingsStore
        self.panelPresenter = panelPresenter
        self.recoveryCatalog = recoveryCatalog
    }

    var phase: DocumentExportPhase { coordinator.phase }
    var progress: Double? { coordinator.progress }

    var statusText: String {
        switch coordinator.phase {
        case .idle: "Ready"
        case .parsing: "Preparing Markdown…"
        case .rendering(.pdf): "Laying out PDF pages…"
        case .rendering(.html): "Rendering HTML…"
        case .installing: "Saving atomically…"
        case .completed(let receipt): "Exported \(receipt.destinationURL.lastPathComponent)"
        case .failed: "Export failed"
        case .cancelled: "Export cancelled"
        }
    }

    var pageSetupSummary: String {
        let settings = printSettingsStore.settings
        let name = settings.paperName ?? "Custom"
        return "\(name) · \(settings.orientation == .portrait ? "Portrait" : "Landscape")"
    }

    func attach(to session: EditorSession) {
        snapshotProvider = { [weak session] in
            guard let session else { throw ExportPresentationError.noDocument }
            return try await session.snapshotForExport()
        }
        sourceURLProvider = { [weak session] in session?.fileURL }
        sourceFilenameProvider = { [weak session] in session?.filename ?? "Untitled.md" }
        windowProvider = { [weak session] in
            guard let id = session?.id else { return nil }
            return NSApplication.shared.windows.first {
                clioEditorSessionID(for: $0) == id
            }
        }
    }

    /// Test and integration seam for the tabbed editor. Stage 5 updates these
    /// providers whenever the active tab changes, while the export state stays
    /// owned by its window.
    func attach(
        snapshotProvider: @escaping @MainActor () async throws -> DocumentTextSnapshot,
        sourceURLProvider: @escaping @MainActor () -> URL?,
        sourceFilenameProvider: @escaping @MainActor () -> String,
        windowProvider: @escaping @MainActor () -> NSWindow?
    ) {
        self.snapshotProvider = snapshotProvider
        self.sourceURLProvider = sourceURLProvider
        self.sourceFilenameProvider = sourceFilenameProvider
        self.windowProvider = windowProvider
    }

    func requestExport(arguments: [String] = []) {
        do {
            if let format = try ExportCommandRoute.format(for: arguments) {
                requestExport(as: format)
            } else {
                failure = nil
                completedReceipt = nil
                isOptionsPresented = true
            }
        } catch {
            failure = ExportFailureMapper.failure(for: error)
        }
    }

    func requestExport(as format: ExportFormat) {
        guard !isExporting else { return }
        let waitsForOptionsSheet = isOptionsPresented
        selectedFormat = format
        failure = nil
        completedReceipt = nil
        isOptionsPresented = false
        chooseDestinationAndExport(
            format,
            waitsForOptionsSheet: waitsForOptionsSheet
        )
    }

    func selectFormat(_ format: ExportFormat) {
        selectedFormat = format
    }

    func confirmOptions() {
        requestExport(as: selectedFormat)
    }

    func cancelOptions() {
        isOptionsPresented = false
    }

    func presentPageSetup() {
        guard let window = windowProvider?() else {
            failure = ExportFailureMapper.failure(for: ExportPresentationError.noWindow)
            return
        }
        let restoresOptions = isOptionsPresented
        isOptionsPresented = false
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if restoresOptions {
                // AppKit cannot attach Page Layout while SwiftUI is still
                // dismissing its options sheet from the same window.
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled else { return }
            let settings = await panelPresenter.choosePageSetup(
                    current: printSettingsStore.settings,
                    on: window
                  )
            if let settings {
                do {
                    try printSettingsStore.update(settings)
                } catch {
                    failure = ExportFailureMapper.failure(for: error)
                }
            }
            if restoresOptions { isOptionsPresented = true }
        }
    }

    func resolveCollision(_ choice: CollisionChoice) {
        guard let request = retryRequest,
              let collision = pendingCollision else { return }
        pendingCollision = nil
        if choice == .cancel {
            retryRequest = nil
            return
        }
        run(
            request,
            resolution: ExportCollisionResolution(
                collision: collision,
                choice: choice
            )
        )
    }

    func retry() {
        guard let request = retryRequest else { return }
        failure = nil
        run(request, resolution: nil)
    }

    func cancel() {
        operationTask?.cancel()
        operationTask = nil
        coordinator.cancel()
        isExporting = false
    }

    func dismissFailure() {
        failure = nil
        retryRequest = nil
    }

    func dismissCompletion() {
        completedReceipt = nil
        coordinator.reset()
    }

    func revealCompletedExport() {
        guard let url = completedReceipt?.destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private extension DocumentExportPresentation {
    func chooseDestinationAndExport(
        _ format: ExportFormat,
        waitsForOptionsSheet: Bool
    ) {
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if waitsForOptionsSheet {
                // Give the SwiftUI sheet time to detach before NSSavePanel is
                // attached document-modally to the exact same window.
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled else { return }
            guard let window = windowProvider?() else {
                failure = ExportFailureMapper.failure(for: ExportPresentationError.noWindow)
                return
            }
            let configuration = ExportSavePanelConfiguration.make(
                format: format,
                sourceFilename: sourceFilenameProvider?() ?? "Untitled.md"
            )
            let initialDirectory = sourceURLProvider?()?.deletingLastPathComponent()
            guard let destination = await panelPresenter.chooseDestination(
                configuration: configuration,
                initialDirectory: initialDirectory,
                on: window
            ) else { return }
            guard !Task.isCancelled else { return }
            do {
                try recoveryCatalog.remember(
                    destinationDirectory: destination.deletingLastPathComponent()
                )
                guard let snapshotProvider else {
                    throw ExportPresentationError.noDocument
                }
                // This call is the single editor/export synchronization seam.
                // The batched editor implementation settles queued TextKit
                // deltas here before creating the immutable generation.
                let snapshot = try await snapshotProvider()
                let request = ExportRequest(
                    format: format,
                    snapshot: snapshot,
                    destinationURL: destination,
                    pdfSettings: format == .pdf ? printSettingsStore.settings : nil
                )
                run(request, resolution: nil)
            } catch is CancellationError {
                return
            } catch {
                failure = ExportFailureMapper.failure(for: error)
            }
        }
    }

    func run(
        _ request: ExportRequest,
        resolution: ExportCollisionResolution?
    ) {
        operationTask?.cancel()
        retryRequest = request
        isExporting = true
        failure = nil
        completedReceipt = nil
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didStartAccess = request.destinationURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    request.destinationURL.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let receipt = try await coordinator.export(
                    request,
                    collisionResolution: resolution
                )
                guard !Task.isCancelled else { return }
                isExporting = false
                retryRequest = nil
                completedReceipt = receipt
            } catch is CancellationError {
                isExporting = false
            } catch let error as DocumentExportError {
                isExporting = false
                if let collision = error.retryCollision {
                    pendingCollision = collision
                    if let retained = error.retainedRecoveryURL {
                        failure = ExportFailure(
                            title: "Destination changed again",
                            message: "Clio preserved the displaced bytes at \(retained.lastPathComponent). Choose what to do with the newest destination.",
                            canRetry: false
                        )
                    }
                } else {
                    failure = ExportFailureMapper.failure(for: error)
                }
            } catch {
                isExporting = false
                failure = ExportFailureMapper.failure(for: error)
            }
        }
    }
}

private struct DocumentExportPresentationFocusedValueKey: FocusedValueKey {
    typealias Value = DocumentExportPresentation
}

extension FocusedValues {
    var documentExportPresentation: DocumentExportPresentation? {
        get { self[DocumentExportPresentationFocusedValueKey.self] }
        set { self[DocumentExportPresentationFocusedValueKey.self] = newValue }
    }
}

extension Notification.Name {
    static let clioRequestedExport = Notification.Name("ClioRequestedExport")
}

enum ClioExportNotificationKey {
    static let arguments = "ClioExportArguments"
}

struct DocumentExportPresentationModifier: ViewModifier {
    @Environment(DocumentExportPresentation.self) private var presentation

    func body(content: Content) -> some View {
        @Bindable var presentation = presentation

        content
            .sheet(isPresented: Binding(
                get: { presentation.isOptionsPresented },
                set: { if !$0 { presentation.cancelOptions() } }
            )) {
                ExportOptionsView()
                    .environment(presentation)
                    .interactiveDismissDisabled(presentation.isExporting)
            }
            .alert(
                "An export already exists",
                isPresented: Binding(
                    get: { presentation.pendingCollision != nil },
                    set: { if !$0 { presentation.resolveCollision(.cancel) } }
                ),
                presenting: presentation.pendingCollision
            ) { _ in
                Button("Cancel", role: .cancel) {
                    presentation.resolveCollision(.cancel)
                }
                Button("Keep Both") {
                    presentation.resolveCollision(.keepBoth)
                }
                Button("Replace", role: .destructive) {
                    presentation.resolveCollision(.replace)
                }
            } message: { collision in
                Text("\(collision.destinationURL.lastPathComponent) changed or already exists. Replace only that reviewed version, or add the next numbered copy.")
            }
            .alert(item: Binding(
                get: { presentation.failure },
                set: { if $0 == nil { presentation.dismissFailure() } }
            )) { failure in
                if failure.canRetry {
                    return Alert(
                        title: Text(failure.title),
                        message: Text(failure.message),
                        primaryButton: .default(Text("Retry"), action: presentation.retry),
                        secondaryButton: .cancel(Text("Dismiss"), action: presentation.dismissFailure)
                    )
                }
                return Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    dismissButton: .default(Text("OK"), action: presentation.dismissFailure)
                )
            }
            .overlay(alignment: .topTrailing) {
                if presentation.isExporting {
                    ExportActivityView()
                        .environment(presentation)
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                } else if presentation.completedReceipt != nil {
                    ExportCompletionView()
                        .environment(presentation)
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
            }
    }
}

private struct ExportOptionsView: View {
    @Environment(DocumentExportPresentation.self) private var presentation

    var body: some View {
        @Bindable var presentation = presentation

        VStack(alignment: .leading, spacing: 20) {
            Text("Export Document")
                .font(.title2.weight(.semibold))

            Picker("Format", selection: Binding(
                get: { presentation.selectedFormat },
                set: presentation.selectFormat
            )) {
                Text("PDF").tag(ExportFormat.pdf)
                Text("HTML").tag(ExportFormat.html)
            }
            .pickerStyle(.segmented)

            if presentation.selectedFormat == .pdf {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Page setup")
                            .font(.headline)
                        Text(presentation.pageSetupSummary)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Page Setup…", action: presentation.presentPageSetup)
                }
            } else {
                Text("A self-contained light reading and print layout. Remote content is never loaded while exporting.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(presentation.selectedFormat == .pdf
                ? "PDF uses black text on white paper."
                : "HTML uses a white reading surface and print stylesheet.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel, action: presentation.cancelOptions)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Destination…", action: presentation.confirmOptions)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

private struct ExportActivityView: View {
    @Environment(DocumentExportPresentation.self) private var presentation

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: presentation.progress)
                .controlSize(.small)
                .frame(width: 72)
            Text(presentation.statusText)
                .lineLimit(1)
            Button("Cancel", action: presentation.cancel)
                .controlSize(.small)
        }
        .font(.custom(Typography.family, fixedSize: 11))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(nsColor: Palette.hairline), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.statusText)
    }
}

private struct ExportCompletionView: View {
    @Environment(DocumentExportPresentation.self) private var presentation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(presentation.statusText)
                .lineLimit(1)
            Button("Show", action: presentation.revealCompletedExport)
                .controlSize(.small)
            Button(action: presentation.dismissCompletion) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss export confirmation")
        }
        .font(.custom(Typography.family, fixedSize: 11))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(nsColor: Palette.hairline), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}

private extension PDFPrintSettings {
    func clioPrintInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        if let paperWidthPoints, let paperHeightPoints {
            info.paperSize = NSSize(
                width: min(paperWidthPoints, paperHeightPoints),
                height: max(paperWidthPoints, paperHeightPoints)
            )
        }
        info.orientation = orientation == .portrait ? .portrait : .landscape
        info.topMargin = margins.top
        info.leftMargin = margins.leading
        info.bottomMargin = margins.bottom
        info.rightMargin = margins.trailing
        return info
    }
}

extension EditorSession {
    /// Export owns one immutable document generation. In the immediate editor
    /// this is already canonical; the batched editor replaces this method's
    /// body with `settlePendingEditorEdits()` before taking the same snapshot.
    func snapshotForExport() async throws -> DocumentTextSnapshot {
        guard let document else { throw ExportPresentationError.noDocument }
        let snapshot = document.snapshot()
        return DocumentTextSnapshot(
            documentID: snapshot.documentID,
            generation: BufferGeneration(
                bufferID: snapshot.documentID.rawValue,
                revision: snapshot.revision
            ),
            filename: snapshot.preferredFilename,
            source: snapshot.text,
            sourceFingerprint: try StableSourceFingerprint.makeCheckingCancellation(
                snapshot.text
            )
        )
    }
}
