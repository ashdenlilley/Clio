import PDFKit
import XCTest
@testable import Clio

@MainActor
final class ExportTests: XCTestCase {
    func testHTMLExportIsSemanticSelfContainedAndEscapesHostileInput() async throws {
        try await withTemporaryDirectory { directory in
            let snapshot = makeSnapshot(source: "# Notes\nUnsafe")
            let model = MarkdownDocumentModel(blocks: [
                .heading(
                    level: 1,
                    content: [.text(value: "Notes & ideas", range: .init(location: 2, length: 13))],
                    range: .init(location: 0, length: 15)
                ),
                .paragraph(
                    content: [
                        .strong(
                            content: [.text(value: "Readable", range: .init(location: 0, length: 8))],
                            range: .init(location: 0, length: 12)
                        ),
                        .text(value: " and ", range: .init(location: 12, length: 5)),
                        .link(
                            destination: "javascript:alert(1)",
                            title: nil,
                            content: [.text(value: "safe", range: .init(location: 17, length: 4))],
                            range: .init(location: 17, length: 24)
                        ),
                        .image(
                            source: "data:image/svg+xml,<svg onload='alert(1)'>",
                            title: nil,
                            alt: [.text(value: "diagram", range: .init(location: 0, length: 7))],
                            range: .init(location: 41, length: 7)
                        ),
                    ],
                    range: .init(location: 0, length: 41)
                ),
                .rawHTML(source: "<script>alert('x')</script>", range: .init(location: 0, length: 27)),
            ])
            let coordinator = DocumentExportCoordinator(
                parser: FixtureParser(model: model)
            )
            let destination = directory.appendingPathComponent("Notes.html")
            let receipt = try await coordinator.export(
                makeRequest(.html, snapshot: snapshot, destination: destination)
            )

            let html = try String(contentsOf: destination, encoding: .utf8)
            XCTAssertEqual(receipt.destinationURL, destination)
            XCTAssertTrue(html.contains("<!doctype html>"))
            XCTAssertTrue(html.contains("<h1>Notes &amp; ideas</h1>"))
            XCTAssertTrue(html.contains("<strong>Readable</strong>"))
            XCTAssertFalse(html.contains("href=\"javascript:"))
            XCTAssertFalse(html.contains("data:image/svg+xml"))
            XCTAssertFalse(html.contains("<script>"))
            XCTAssertTrue(html.contains("&lt;script&gt;"))
            XCTAssertTrue(html.contains("@media print"))
            XCTAssertFalse(html.contains("<link "))
            XCTAssertFalse(html.contains("<script src="))
            XCTAssertEqual(coordinator.phase, .completed(receipt))
        }
    }

    func testExportCollisionRequiresAChoiceAndKeepBothUsesParenthesizedNumber() async throws {
        try await withTemporaryDirectory { directory in
            let snapshot = makeSnapshot(source: "Existing")
            let model = MarkdownDocumentModel(blocks: [
                .paragraph(
                    content: [.text(value: "Existing", range: .init(location: 0, length: 8))],
                    range: .init(location: 0, length: 8)
                ),
            ])
            let coordinator = DocumentExportCoordinator(parser: FixtureParser(model: model))
            let destination = directory.appendingPathComponent("Notes.html")
            try Data("original".utf8).write(to: destination)

            do {
                _ = try await coordinator.export(
                    makeRequest(.html, snapshot: snapshot, destination: destination)
                )
                XCTFail("An existing destination must require a collision choice")
            } catch let error as DocumentExportError {
                XCTAssertEqual(error, .destinationExists(destination))
            }

            let receipt = try await coordinator.export(
                makeRequest(.html, snapshot: snapshot, destination: destination),
                collisionChoice: .keepBoth
            )
            XCTAssertEqual(receipt.destinationURL.lastPathComponent, "Notes (2).html")
            XCTAssertEqual(try String(contentsOf: destination), "original")
        }
    }

    func testPDFExportUsesRequestedPaperAndProducesExtractablePaginatedText() async throws {
        try await withTemporaryDirectory { directory in
            let repeated = Array(repeating: "A calm paragraph with searchable Unicode café 日本語.", count: 90)
                .joined(separator: " ")
            let snapshot = makeSnapshot(source: repeated, filename: "Reading notes.md")
            let model = MarkdownDocumentModel(blocks: [
                .heading(
                    level: 1,
                    content: [.text(value: "Reading notes", range: .init(location: 0, length: 13))],
                    range: .init(location: 0, length: 13)
                ),
                .paragraph(
                    content: [.text(value: repeated, range: .init(location: 0, length: repeated.utf16.count))],
                    range: .init(location: 0, length: repeated.utf16.count)
                ),
                .codeFence(
                    language: "swift",
                    source: "let clio = true\n",
                    range: .init(location: 0, length: 16)
                ),
            ])
            let coordinator = DocumentExportCoordinator(parser: FixtureParser(model: model))
            let destination = directory.appendingPathComponent("Reading notes.pdf")
            let settings = PDFPrintSettings(
                paperName: "qa-small",
                paperWidthPoints: 360,
                paperHeightPoints: 480,
                margins: PrintMargins(top: 36, leading: 36, bottom: 36, trailing: 36),
                orientation: .portrait
            )

            let receipt = try await coordinator.export(
                makeRequest(.pdf, snapshot: snapshot, destination: destination, settings: settings)
            )
            let pdf = try XCTUnwrap(PDFDocument(url: destination))
            let firstPage = try XCTUnwrap(pdf.page(at: 0))
            let text = pdf.string ?? ""
            XCTAssertGreaterThan(pdf.pageCount, 1)
            XCTAssertEqual(firstPage.bounds(for: .mediaBox).size.width, 360, accuracy: 0.5)
            XCTAssertEqual(firstPage.bounds(for: .mediaBox).size.height, 480, accuracy: 0.5)
            XCTAssertTrue(text.contains("Reading notes"))
            XCTAssertTrue(text.contains("searchable Unicode café 日本語"))
            XCTAssertTrue(text.contains("let clio = true"))
            XCTAssertGreaterThan(receipt.byteCount, 1_000)
        }
    }

    func testPDFSettingsPersistAndRejectAnUnprintablePage() throws {
        let suite = "ClioExportSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PDFPrintSettingsStore(defaults: defaults)
        let landscape = PDFPrintSettings(
            paperName: "iso-a4",
            paperWidthPoints: 595.2756,
            paperHeightPoints: 841.8898,
            margins: PrintMargins(top: 40, leading: 42, bottom: 44, trailing: 46),
            orientation: .landscape
        )
        try store.update(landscape)
        XCTAssertEqual(PDFPrintSettingsStore(defaults: defaults).settings, landscape)

        let invalid = PDFPrintSettings(
            paperName: "invalid",
            paperWidthPoints: 100,
            paperHeightPoints: 100,
            margins: PrintMargins(top: 60, leading: 60, bottom: 60, trailing: 60),
            orientation: .portrait
        )
        XCTAssertThrowsError(try store.update(invalid))
    }

    func testCancellationStopsBeforeInstallingAnExport() async throws {
        try await withTemporaryDirectory { directory in
            let snapshot = makeSnapshot(source: "cancel")
            let coordinator = DocumentExportCoordinator(parser: DelayedParser())
            let destination = directory.appendingPathComponent("cancel.html")
            let operation = Task {
                try await coordinator.export(
                    makeRequest(.html, snapshot: snapshot, destination: destination)
                )
            }
            await Task.yield()
            coordinator.cancel()

            do {
                _ = try await operation.value
                XCTFail("Cancellation should escape to the caller")
            } catch is CancellationError {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                XCTAssertEqual(coordinator.phase, .cancelled)
            }
        }
    }

    func testGeneratePDFVisualFixture() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/ClioRunPDFVisualFixture") else {
            throw XCTSkip("Create /tmp/ClioRunPDFVisualFixture to render the visual QA document.")
        }
        let paragraphs = Array(
            repeating: "Writing tools should disappear at the exact moment an idea arrives. Clio keeps the document central, then brings structure back with intentional motion.",
            count: 14
        )
        let snapshot = makeSnapshot(
            source: paragraphs.joined(separator: "\n\n"),
            filename: "Clio export verification.md"
        )
        let cell: (String) -> MarkdownTableCell = {
            MarkdownTableCell(
                content: [.text(value: $0, range: .init(location: 0, length: $0.utf16.count))],
                range: .init(location: 0, length: $0.utf16.count)
            )
        }
        var blocks: [MarkdownBlock] = [
            .heading(level: 1, content: [.text(value: "A quieter interface", range: .init(location: 0, length: 19))], range: .init(location: 0, length: 19)),
            .blockquote(blocks: [.paragraph(content: [.text(value: "Chrome is useful context, not permanent furniture.", range: .init(location: 0, length: 49))], range: .init(location: 0, length: 49))], range: .init(location: 0, length: 49)),
            .heading(level: 2, content: [.text(value: "Working principles", range: .init(location: 0, length: 18))], range: .init(location: 0, length: 18)),
            .list(MarkdownList(isOrdered: false, start: nil, isTight: false, items: [
                MarkdownListItem(taskState: .checked, blocks: [.paragraph(content: [.text(value: "Plain Markdown remains canonical.", range: .init(location: 0, length: 33))], range: .init(location: 0, length: 33))], range: .init(location: 0, length: 33)),
                MarkdownListItem(taskState: .unchecked, blocks: [.paragraph(content: [.text(value: "Review every page before release.", range: .init(location: 0, length: 33))], range: .init(location: 0, length: 33))], range: .init(location: 0, length: 33)),
            ], range: .init(location: 0, length: 66))),
            .table(MarkdownTable(
                alignments: [.leading, .trailing],
                header: [cell("Contract"), cell("Target")],
                rows: [[cell("Search first result"), cell("100 ms")], [cell("External reflection"), cell("1 second")]],
                range: .init(location: 0, length: 80)
            )),
            .codeFence(language: "swift", source: "let workspace = URL.documentsDirectory\nawait clio.open(workspace)\n", range: .init(location: 0, length: 64)),
        ]
        blocks += paragraphs.map {
            .paragraph(
                content: [.text(value: $0, range: .init(location: 0, length: $0.utf16.count))],
                range: .init(location: 0, length: $0.utf16.count)
            )
        }
        let coordinator = DocumentExportCoordinator(
            parser: FixtureParser(model: MarkdownDocumentModel(blocks: blocks))
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioExportVisualFixture.pdf")
        _ = try await coordinator.export(
            makeRequest(
                .pdf,
                snapshot: snapshot,
                destination: destination,
                settings: PDFPrintSettingsStore.regionalDefault()
            ),
            collisionChoice: .replace
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }
}

private struct FixtureParser: MarkdownParsing {
    let model: MarkdownDocumentModel

    func parse(_ snapshot: DocumentTextSnapshot) async throws -> ParsedMarkdown {
        ParsedMarkdown(
            documentID: snapshot.documentID,
            generation: snapshot.generation,
            sourceFingerprint: snapshot.sourceFingerprint,
            sizeMode: snapshot.sizeMode,
            document: model,
            spans: [],
            diagnostics: []
        )
    }
}

private struct DelayedParser: MarkdownParsing {
    func parse(_ snapshot: DocumentTextSnapshot) async throws -> ParsedMarkdown {
        try await Task.sleep(for: .seconds(30))
        return ParsedMarkdown(
            documentID: snapshot.documentID,
            generation: snapshot.generation,
            sourceFingerprint: snapshot.sourceFingerprint,
            sizeMode: snapshot.sizeMode,
            document: MarkdownDocumentModel(blocks: []),
            spans: [],
            diagnostics: []
        )
    }
}

private extension ExportTests {
    func makeSnapshot(
        source: String,
        filename: String = "Notes.md"
    ) -> DocumentTextSnapshot {
        DocumentTextSnapshot(
            documentID: DocumentID(),
            generation: BufferGeneration(),
            filename: filename,
            source: source,
            sourceFingerprint: "fixture-\(source.utf8.count)"
        )
    }

    func makeRequest(
        _ format: ExportFormat,
        snapshot: DocumentTextSnapshot,
        destination: URL,
        settings: PDFPrintSettings? = nil
    ) -> ExportRequest {
        ExportRequest(
            format: format,
            snapshot: snapshot,
            destinationURL: destination,
            pdfSettings: settings
        )
    }

    func withTemporaryDirectory<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }
}
