import AppKit
import PDFKit
import XCTest
@testable import Clio

@MainActor
final class ExportIntegrationTests: XCTestCase {
    func testProductionCoordinatorDefaultsToSourcePreservingParser() async throws {
        try await withTemporaryDirectory { directory in
            let snapshot = makeSnapshot(source: "# Production parser\n\n**Semantic body**")
            let destination = directory.appendingPathComponent("Production.html")
            let coordinator = DocumentExportCoordinator()
            _ = try await coordinator.export(
                makeRequest(.html, snapshot: snapshot, destination: destination)
            )
            let html = try String(contentsOf: destination)
            XCTAssertTrue(html.contains("<h1>Production parser</h1>"))
            XCTAssertTrue(html.contains("<strong>Semantic body</strong>"))
        }
    }

    func testRealParserFeedsOneSemanticModelToBothExporters() async throws {
        try await withTemporaryDirectory { directory in
            let source = """
            # Semantic café 日本語 🙂

            Entity &amp; reference[^note], **strong**, *emphasis*, ~~removed~~,
            [safe link](https://example.com), and ![remote diagram](https://tracker.example/pixel.png).

            > Quoted `code`

            - [x] complete
              - nested item

            | Name | Value |
            | --- | ---: |
            | alpha | 42 |

            <script>alert('never execute')</script>

            [^note]: Footnote *emphasis* and [inside link](https://example.org)\u{20}\u{20}
                hard break

                - footnote list item
            """
            let snapshot = makeSnapshot(source: source, filename: "Semantic.md")
            let parsed = try await SourcePreservingMarkdownParser().parse(snapshot)
            let htmlURL = directory.appendingPathComponent("Semantic.html")
            let pdfURL = directory.appendingPathComponent("Semantic.pdf")

            let html = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.html, snapshot: snapshot, destination: htmlURL),
                collisionResolution: nil
            )
            defer { html.discard() }
            _ = try html.install()
            let pdf = try await PDFDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.pdf, snapshot: snapshot, destination: pdfURL),
                collisionResolution: nil
            )
            defer { pdf.discard() }
            _ = try pdf.install()

            let htmlSource = try String(contentsOf: htmlURL, encoding: .utf8)
            let pdfText = try XCTUnwrap(PDFDocument(url: pdfURL)?.string)
            for token in [
                "Semantic café 日本語 🙂", "Entity &amp; reference", "strong",
                "nested item", "alpha", "Footnote", "inside link",
                "hard break", "footnote list item",
            ] {
                XCTAssertTrue(htmlSource.contains(token), "HTML omitted \(token)")
                let decodedToken = token == "Entity &amp; reference" ? "Entity & reference" : token
                XCTAssertTrue(pdfText.contains(decodedToken), "PDF omitted \(decodedToken)")
            }
            XCTAssertTrue(htmlSource.contains("<strong>strong</strong>"))
            XCTAssertTrue(htmlSource.contains("<section class=\"footnote\""))
            XCTAssertTrue(htmlSource.contains("<ul>"))
            XCTAssertFalse(htmlSource.contains("src=\"https://tracker.example"))
            XCTAssertFalse(htmlSource.contains("<script>alert"))
            XCTAssertTrue(htmlSource.contains("&lt;script&gt;"))
            XCTAssertFalse(pdfText.contains("https://tracker.example"))
        }
    }

    func testOmittedSemanticSourceIsNeverRenderedAsRawFallback() async throws {
        try await withTemporaryDirectory { directory in
            let source = "[unused-reference]: https://secret.example/path\n"
            let snapshot = makeSnapshot(source: source)
            let parsed = try await SourcePreservingMarkdownParser().parse(snapshot)
            XCTAssertTrue(parsed.document.blocks.isEmpty)

            let htmlURL = directory.appendingPathComponent("Empty.html")
            let html = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.html, snapshot: snapshot, destination: htmlURL),
                collisionResolution: nil
            )
            _ = try html.install()
            let pdfURL = directory.appendingPathComponent("Empty.pdf")
            let pdf = try await PDFDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.pdf, snapshot: snapshot, destination: pdfURL),
                collisionResolution: nil
            )
            _ = try pdf.install()

            XCTAssertFalse(try String(contentsOf: htmlURL).contains("secret.example"))
            XCTAssertFalse((PDFDocument(url: pdfURL)?.string ?? "").contains("secret.example"))
        }
    }

    func testHostileRealParserLinksAndEveryImageSourceStayInert() async throws {
        let source = """
        [mixed](JaVaScRiPt:alert(1)) [entity](jav&#x61;script:alert(2))
        [file](file:///etc/passwd) [root](/etc/passwd) [data](data:text/html,boom)
        [network](//evil.example/path) [control](https://good.example/%0aevil)
        [relative](notes/next.html) ![remote](https://evil.example/x.png "Remote title")
        ![inline](data:image/png;base64,AAAA) <img src=x onerror=alert(1)>
        """
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        let html = try HTMLDocumentRenderer.render(document: parsed.document, title: "Security")
        let pdfText = try PDFAttributedDocumentBuilder.build(parsed.document).string
        XCTAssertTrue(parsed.document.blocks.contains { block in
            guard case .paragraph(let content, _) = block else { return false }
            return content.contains { inline in
                if case .image(_, let title, _, _) = inline { return title == "Remote title" }
                return false
            }
        })

        XCTAssertFalse(html.localizedCaseInsensitiveContains("javascript:"))
        XCTAssertFalse(pdfText.localizedCaseInsensitiveContains("javascript:"))
        XCTAssertFalse(html.contains("file:///"))
        XCTAssertFalse(pdfText.contains("file:///"))
        XCTAssertFalse(html.contains("/etc/passwd"))
        XCTAssertFalse(pdfText.contains("/etc/passwd"))
        XCTAssertFalse(html.contains("data:text/html"))
        XCTAssertFalse(pdfText.contains("data:text/html"))
        XCTAssertFalse(html.contains("href=\"//evil.example"))
        XCTAssertFalse(html.contains("<img "))
        XCTAssertFalse(html.contains("src=\""))
        XCTAssertFalse(pdfText.contains("https://evil.example/x.png"))
        XCTAssertTrue(html.contains("href=\"notes/next.html\""))
        XCTAssertTrue(html.contains("role=\"img\" aria-label=\"remote\""))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    func testDirectoryPackageAndSymlinkDestinationsAreRejected() async throws {
        try await withTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("Folder.html", isDirectory: true)
            let package = directory.appendingPathComponent("Bundle.app", isDirectory: true)
            let target = directory.appendingPathComponent("target.html")
            let link = directory.appendingPathComponent("link.html")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try Data("target".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            for url in [folder, package, link] {
                XCTAssertThrowsError(try ExportDestination.resolve(
                    requestedURL: url,
                    resolution: nil
                )) { error in
                    XCTAssertEqual(error as? DocumentExportError, .unsupportedDestination(url))
                }
            }
        }
    }

    func testReplaceApprovalRejectsARevisionChangedBeforeRendering() async throws {
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("replace.html")
            try Data("approved bytes".utf8).write(to: destination)
            let approved = try XCTUnwrap(ExportDestination.collision(at: destination))
            try Data("changed before retry".utf8).write(to: destination, options: .atomic)
            let snapshot = makeSnapshot(source: "new export")
            let coordinator = DocumentExportCoordinator()

            do {
                _ = try await coordinator.export(
                    makeRequest(.html, snapshot: snapshot, destination: destination),
                    collisionResolution: ExportCollisionResolution(
                        collision: approved,
                        choice: .replace
                    )
                )
                XCTFail("A stale replacement approval must not install")
            } catch DocumentExportError.destinationChanged(let url, let current, let retained) {
                XCTAssertEqual(url, destination)
                XCTAssertNotEqual(current?.revision, approved.revision)
                XCTAssertNil(retained)
            }
            XCTAssertEqual(try String(contentsOf: destination), "changed before retry")
        }
    }

    func testLateCreateCollisionIsTypedAndPreservesOccupant() async throws {
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("late.html")
            let snapshot = makeSnapshot(source: "candidate")
            let parsed = try await SourcePreservingMarkdownParser().parse(snapshot)
            let staged = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.html, snapshot: snapshot, destination: destination),
                collisionResolution: nil
            )
            defer { staged.discard() }
            try Data("late occupant".utf8).write(to: destination)

            XCTAssertThrowsError(try staged.install()) { error in
                guard case DocumentExportError.destinationExists(let collision) = error else {
                    return XCTFail("Expected a typed collision, got \(error)")
                }
                XCTAssertEqual(collision.destinationURL, destination)
            }
            XCTAssertEqual(try String(contentsOf: destination), "late occupant")
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.temporaryURL.path))
        }
    }

    func testAtomicReplacePreservesBothLateRevisionsAndReturnsRetryableConflict() async throws {
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("cas.html")
            try Data("approved occupant".utf8).write(to: destination)
            let approved = try XCTUnwrap(ExportDestination.collision(at: destination))
            let resolution = ExportCollisionResolution(collision: approved, choice: .replace)
            let snapshot = makeSnapshot(source: "candidate export")
            let parsed = try await SourcePreservingMarkdownParser().parse(snapshot)
            let staged = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.html, snapshot: snapshot, destination: destination),
                collisionResolution: resolution
            )
            defer { staged.discard() }
            let writer = AtomicFileWriter(
                beforeSwap: {
                    try Data("first late occupant".utf8).write(to: destination, options: .atomic)
                },
                afterSwap: {
                    try Data("second late occupant".utf8).write(to: destination, options: .atomic)
                }
            )

            do {
                _ = try staged.install(writer: writer)
                XCTFail("The compare-and-swap race must be reported")
            } catch DocumentExportError.destinationChanged(_, _, let retainedURL) {
                let retainedURL = try XCTUnwrap(retainedURL)
                defer { try? FileManager.default.removeItem(at: retainedURL) }
                XCTAssertEqual(try String(contentsOf: retainedURL), "first late occupant")
            }
            XCTAssertEqual(try String(contentsOf: destination), "second late occupant")
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.temporaryURL.path))
        }
    }

    func testAtomicReplaceRetainsApprovedBytesWhenAWriterArrivesAfterSwap() async throws {
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("post-swap.html")
            try Data("approved occupant".utf8).write(to: destination)
            let approved = try XCTUnwrap(ExportDestination.collision(at: destination))
            let snapshot = makeSnapshot(source: "candidate export")
            let parsed = try await SourcePreservingMarkdownParser().parse(snapshot)
            let staged = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.html, snapshot: snapshot, destination: destination),
                collisionResolution: ExportCollisionResolution(
                    collision: approved,
                    choice: .replace
                )
            )
            defer { staged.discard() }
            let writer = AtomicFileWriter(afterSwap: {
                try Data("late occupant".utf8).write(to: destination, options: .atomic)
            })

            do {
                _ = try staged.install(writer: writer)
                XCTFail("The post-swap writer must produce a retryable conflict")
            } catch DocumentExportError.destinationChanged(_, _, let retainedURL) {
                let retainedURL = try XCTUnwrap(retainedURL)
                defer { try? FileManager.default.removeItem(at: retainedURL) }
                XCTAssertEqual(try String(contentsOf: retainedURL), "approved occupant")
            }
            XCTAssertEqual(try String(contentsOf: destination), "late occupant")
        }
    }

    func testSemanticHTMLHasNoValidatorErrors() async throws {
        let parsed = try await SourcePreservingMarkdownParser.parse(
            source: "# Validated\n\nA [link](https://example.com) and a table.\n\n| A | B |\n| - | - |\n| 1 | 2 |"
        )
        let html = try HTMLDocumentRenderer.render(document: parsed.document, title: "Validated")
        let process = Process()
        let input = Pipe()
        let diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tidy")
        // The system Tidy build predates HTML5's `main` element, so register
        // that standards-defined block element before checking real errors.
        process.arguments = [
            "-errors", "-quiet", "-utf8", "--new-blocklevel-tags", "main",
        ]
        process.standardInput = input
        process.standardError = diagnostics
        try process.run()
        input.fileHandleForWriting.write(Data(html.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let message = String(
            decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertLessThan(process.terminationStatus, 2, message)
    }
}

private extension ExportIntegrationTests {
    func makeSnapshot(
        source: String,
        filename: String = "Notes.md"
    ) -> DocumentTextSnapshot {
        DocumentTextSnapshot(
            documentID: DocumentID(),
            generation: BufferGeneration(),
            filename: filename,
            source: source,
            sourceFingerprint: StableSourceFingerprint.make(source)
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
            .appendingPathComponent("ClioExportIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }
}
