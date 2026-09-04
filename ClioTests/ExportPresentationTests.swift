import AppKit
import XCTest
@testable import Clio

@MainActor
final class ExportPresentationTests: XCTestCase {
    func testCommandRouteSupportsAskPDFAndHTML() throws {
        XCTAssertNil(try ExportCommandRoute.format(for: []))
        XCTAssertEqual(try ExportCommandRoute.format(for: ["PDF"]), .pdf)
        XCTAssertEqual(try ExportCommandRoute.format(for: ["html"]), .html)
        XCTAssertThrowsError(try ExportCommandRoute.format(for: ["markdown"])) { error in
            XCTAssertEqual(
                error as? ExportPresentationError,
                .invalidCommandArguments(["markdown"])
            )
        }
        XCTAssertThrowsError(try ExportCommandRoute.format(for: ["pdf", "extra"]))
    }

    func testSavePanelConfigurationUsesCanonicalExtension() {
        let pdf = ExportSavePanelConfiguration.make(
            format: .pdf,
            sourceFilename: "Launch notes.md"
        )
        XCTAssertEqual(pdf.suggestedFilename, "Launch notes.pdf")
        XCTAssertEqual(pdf.contentTypeIdentifier, "com.adobe.pdf")

        let html = ExportSavePanelConfiguration.make(
            format: .html,
            sourceFilename: "untitled.md"
        )
        XCTAssertEqual(html.suggestedFilename, "untitled.html")
        XCTAssertEqual(html.contentTypeIdentifier, "public.html")
    }

    func testFailureMapperExplainsDiskAccessAndMissingVolumeFailures() {
        let noSpace = ExportFailureMapper.failure(for: NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC)
        ))
        XCTAssertEqual(noSpace.title, "Not enough disk space")
        XCTAssertTrue(noSpace.message.contains("existing file untouched"))
        XCTAssertTrue(noSpace.canRetry)

        let readOnly = ExportFailureMapper.failure(for: NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EROFS)
        ))
        XCTAssertEqual(readOnly.title, "Destination is not writable")

        let missing = ExportFailureMapper.failure(for: NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENODEV)
        ))
        XCTAssertEqual(missing.title, "Destination is unavailable")
    }

    func testWindowScopedHTMLFlowCapturesSnapshotAfterSheetAndCompletes() async throws {
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Draft.html")
            let panel = FakeExportPanelPresenter(destination: destination)
            let defaults = try XCTUnwrap(UserDefaults(
                suiteName: "ExportPresentationTests-\(UUID().uuidString)"
            ))
            let presentation = DocumentExportPresentation(
                coordinator: DocumentExportCoordinator(),
                printSettingsStore: PDFPrintSettingsStore(defaults: defaults),
                panelPresenter: panel,
                recoveryCatalog: FakeExportRecoveryCatalog()
            )
            var source = "# Before panel"
            var snapshotCallCount = 0
            let window = NSWindow()
            presentation.attach(
                snapshotProvider: {
                    snapshotCallCount += 1
                    return self.snapshot(source: source, filename: "Draft.md")
                },
                sourceURLProvider: {
                    directory.appendingPathComponent("Draft.md")
                },
                sourceFilenameProvider: { "Draft.md" },
                windowProvider: { window }
            )

            source = "# Captured after panel\n\nBody"
            presentation.requestExport(as: .html)
            try await waitUntil { presentation.completedReceipt != nil }

            XCTAssertEqual(snapshotCallCount, 1)
            XCTAssertEqual(panel.configurations.map(\.format), [.html])
            XCTAssertEqual(panel.initialDirectories, [directory])
            XCTAssertEqual(presentation.completedReceipt?.destinationURL, destination)
            let html = try String(contentsOf: destination, encoding: .utf8)
            XCTAssertTrue(html.contains("<h1>Captured after panel</h1>"))
            XCTAssertTrue(html.contains("color-scheme: light"))
        }
    }

    func testCollisionRequiresChoiceAndKeepBothPreservesReviewedOccupant() async throws {
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Draft.html")
            try Data("outside".utf8).write(to: destination)
            let panel = FakeExportPanelPresenter(destination: destination)
            let presentation = makePresentation(panel: panel)
            let window = NSWindow()
            presentation.attach(
                snapshotProvider: { self.snapshot(source: "# Clio", filename: "Draft.md") },
                sourceURLProvider: { nil },
                sourceFilenameProvider: { "Draft.md" },
                windowProvider: { window }
            )

            presentation.requestExport(as: .html)
            try await waitUntil { presentation.pendingCollision != nil }
            XCTAssertEqual(try String(contentsOf: destination), "outside")

            presentation.resolveCollision(.keepBoth)
            try await waitUntil { presentation.completedReceipt != nil }
            XCTAssertEqual(try String(contentsOf: destination), "outside")
            let copy = directory.appendingPathComponent("Draft (2).html")
            XCTAssertEqual(presentation.completedReceipt?.destinationURL, copy)
            XCTAssertTrue(try String(contentsOf: copy).contains("<h1>Clio</h1>"))
        }
    }

    func testPageSetupSheetUpdatesWindowScopedPersistentSettings() async throws {
        let custom = PDFPrintSettings(
            paperName: "qa-custom",
            paperWidthPoints: 420,
            paperHeightPoints: 720,
            margins: PrintMargins(top: 30, leading: 31, bottom: 32, trailing: 33),
            orientation: .landscape
        )
        let panel = FakeExportPanelPresenter(destination: nil, pageSettings: custom)
        let suiteName = "ExportPageSetupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PDFPrintSettingsStore(defaults: defaults)
        let presentation = DocumentExportPresentation(
            coordinator: DocumentExportCoordinator(),
            printSettingsStore: store,
            panelPresenter: panel,
            recoveryCatalog: FakeExportRecoveryCatalog()
        )
        let window = NSWindow()
        presentation.attach(
            snapshotProvider: { self.snapshot(source: "text", filename: "Text.md") },
            sourceURLProvider: { nil },
            sourceFilenameProvider: { "Text.md" },
            windowProvider: { window }
        )

        presentation.requestExport()
        XCTAssertTrue(presentation.isOptionsPresented)
        presentation.presentPageSetup()
        try await waitUntil { store.settings.paperName == "qa-custom" }
        XCTAssertEqual(store.settings, custom)
        XCTAssertEqual(panel.pageSetupRequests, 1)

        let restored = PDFPrintSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings, custom)
    }
}

@MainActor
private final class FakeExportPanelPresenter: ExportPanelPresenting {
    var destination: URL?
    var pageSettings: PDFPrintSettings?
    private(set) var configurations: [ExportSavePanelConfiguration] = []
    private(set) var initialDirectories: [URL?] = []
    private(set) var pageSetupRequests = 0

    init(destination: URL?, pageSettings: PDFPrintSettings? = nil) {
        self.destination = destination
        self.pageSettings = pageSettings
    }

    func chooseDestination(
        configuration: ExportSavePanelConfiguration,
        initialDirectory: URL?,
        on _: NSWindow
    ) async -> URL? {
        configurations.append(configuration)
        initialDirectories.append(initialDirectory)
        return destination
    }

    func choosePageSetup(
        current _: PDFPrintSettings,
        on _: NSWindow
    ) async -> PDFPrintSettings? {
        pageSetupRequests += 1
        return pageSettings
    }
}

private final class FakeExportRecoveryCatalog: ExportRecoveryCataloging,
    @unchecked Sendable {
    private(set) var directories: [URL] = []
    var strategy: ExportRecoveryStrategy = .directoryTransaction

    func recoveryStrategy(for destinationURL: URL) async -> ExportRecoveryStrategy {
        directories.append(
            destinationURL.deletingLastPathComponent().standardizedFileURL
        )
        return strategy
    }
}

@MainActor
private extension ExportPresentationTests {
    func makePresentation(
        panel: FakeExportPanelPresenter
    ) -> DocumentExportPresentation {
        let defaults = UserDefaults(
            suiteName: "ExportPresentationTests-\(UUID().uuidString)"
        )!
        return DocumentExportPresentation(
            coordinator: DocumentExportCoordinator(),
            printSettingsStore: PDFPrintSettingsStore(defaults: defaults),
            panelPresenter: panel,
            recoveryCatalog: FakeExportRecoveryCatalog()
        )
    }

    func snapshot(source: String, filename: String) -> DocumentTextSnapshot {
        DocumentTextSnapshot(
            documentID: DocumentID(),
            generation: BufferGeneration(),
            filename: filename,
            source: source,
            sourceFingerprint: StableSourceFingerprint.make(source)
        )
    }

    func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for export presentation state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func withTemporaryDirectory<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClioExportPresentation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }
}
