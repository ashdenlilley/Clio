import AppKit
import PDFKit
import XCTest
@testable import Clio

@MainActor
final class ExportLargeFileTests: XCTestCase {
    func testTenMiBParserModelCarriesTailThroughBothExporters() async throws {
        try await withTemporaryDirectory { directory in
            let tail = "\n# EXPORT-TAIL-10MIB-CAFÉ-日本語\n"
            let padding = PerformanceContract.fullMarkdownByteLimit - tail.utf8.count
            let source = String(repeating: " ", count: padding) + tail
            let snapshot = makeSnapshot(source: source, filename: "Large.md")
            XCTAssertEqual(snapshot.sizeMode, .full)
            let parsed = try await SourcePreservingMarkdownParser().parse(snapshot)
            XCTAssertTrue(parsed.document.blocks.contains { block in
                guard case .heading(_, let content, _) = block else { return false }
                return content.contains { inline in
                    if case .text(let value, _) = inline { return value.contains("EXPORT-TAIL") }
                    return false
                }
            })

            let htmlURL = directory.appendingPathComponent("Large.html")
            let html = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.html, snapshot: snapshot, destination: htmlURL),
                collisionResolution: nil
            )
            _ = try html.install()
            let pdfURL = directory.appendingPathComponent("Large.pdf")
            let pdf = try await PDFDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.pdf, snapshot: snapshot, destination: pdfURL),
                collisionResolution: nil
            )
            _ = try pdf.install()

            XCTAssertTrue(try String(contentsOf: htmlURL).contains("EXPORT-TAIL-10MIB-CAFÉ-日本語"))
            XCTAssertTrue((PDFDocument(url: pdfURL)?.string ?? "").contains("EXPORT-TAIL-10MIB-CAFÉ-日本語"))
        }
    }

    func testFiftyMiBCancellationIsBoundedAndLeavesBothDestinationsUntouched() async throws {
        try await withTemporaryDirectory { directory in
            let tail = "\n# UNREACHABLE-TAIL\n"
            let padding = PerformanceContract.safeLargeFileByteLimit - tail.utf8.count
            let source = String(repeating: " ", count: padding) + tail
            let snapshot = makeSnapshot(source: source, filename: "Safe-large.md")
            XCTAssertEqual(snapshot.sizeMode, .safeLargeFile)

            for format in ExportFormat.allCases {
                let destination = directory.appendingPathComponent("cancel.\(format.rawValue)")
                try Data("outside bytes".utf8).write(to: destination)
                let collision = try XCTUnwrap(ExportDestination.collision(at: destination))
                let probe = ExportParseProbe()
                let coordinator = DocumentExportCoordinator(
                    parser: ProbedSourcePreservingParser(probe: probe)
                )
                let clock = ContinuousClock()
                let started = clock.now
                let operation = Task {
                    try await coordinator.export(
                        makeRequest(format, snapshot: snapshot, destination: destination),
                        collisionResolution: ExportCollisionResolution(
                            collision: collision,
                            choice: .replace
                        )
                    )
                }
                for _ in 0..<5_000 {
                    if await probe.hasStarted { break }
                    await Task.yield()
                }
                let parserStarted = await probe.hasStarted
                XCTAssertTrue(parserStarted)
                try await Task.sleep(for: .milliseconds(5))
                coordinator.cancel()
                do {
                    _ = try await operation.value
                    XCTFail("A cancelled safe-large \(format.rawValue) export installed")
                } catch is CancellationError {
                    // Expected.
                }
                XCTAssertLessThan(started.duration(to: clock.now), .seconds(12))
                XCTAssertEqual(try String(contentsOf: destination), "outside bytes")
                let residue = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).filter {
                    $0.lastPathComponent.hasPrefix(".clio-export-")
                        || $0.lastPathComponent.hasPrefix(".clio-save-")
                }
                XCTAssertTrue(residue.isEmpty, "Unexpected temporary files: \(residue)")
            }
        }
    }

    func testRenderedPDFFirstMiddleAndLastPagesKeepUnicodeLayoutAndTail() async throws {
        try await withTemporaryDirectory { directory in
            var sections = ["# FIRST-PAGE café 日本語 🙂"]
            for index in 0..<110 {
                let marker = index == 55 ? "MIDDLE-PAGE-Ω" : "paragraph-\(index)"
                sections.append("\(marker) Writing remains quiet and searchable across pagination.")
            }
            sections.append("""
            - Parent item
              - Nested item with emoji 📝

            | Column | Value |
            | --- | ---: |
            | Unicode | 日本語 |

            `\(String(repeating: "long-token-", count: 40))`

            ## LAST-PAGE-TAIL-Z9
            """)
            let source = sections.joined(separator: "\n\n")
            let snapshot = makeSnapshot(source: source, filename: "Pagination.md")
            let parsed = try await SourcePreservingMarkdownParser().parse(snapshot)
            let destination = directory.appendingPathComponent("Pagination.pdf")
            let settings = PDFPrintSettings(
                paperName: "qa-small",
                paperWidthPoints: 300,
                paperHeightPoints: 360,
                margins: PrintMargins(top: 28, leading: 28, bottom: 28, trailing: 28),
                orientation: .portrait
            )
            let staged = try await PDFDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.pdf, snapshot: snapshot, destination: destination, settings: settings),
                collisionResolution: nil
            )
            _ = try staged.install()
            let document = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertGreaterThan(document.pageCount, 3)
            let first = try XCTUnwrap(document.page(at: 0))
            let middle = try XCTUnwrap(document.page(at: document.pageCount / 2))
            let last = try XCTUnwrap(document.page(at: document.pageCount - 1))
            XCTAssertTrue((first.string ?? "").contains("FIRST-PAGE"))
            XCTAssertTrue((first.string ?? "").contains("café"))
            XCTAssertTrue(["日", "本", "語"].allSatisfy { (first.string ?? "").contains($0) })
            let markerPage = (0..<document.pageCount).first {
                document.page(at: $0)?.string?.contains("MIDDLE-PAGE-Ω") == true
            }
            let markerIndex = try XCTUnwrap(markerPage)
            XCTAssertLessThanOrEqual(abs(markerIndex - document.pageCount / 2), 1)
            XCTAssertTrue((last.string ?? "").contains("LAST-PAGE-TAIL-Z9"))
            XCTAssertTrue(document.string?.contains("Nested item with emoji 📝") == true)
            XCTAssertTrue(document.string?.contains("Unicode") == true)
            XCTAssertTrue(document.string?.contains("long-token-") == true)
            for page in [first, middle, last] {
                try assertBlackInkOnWhite(page)
            }
        }
    }
}

private actor ExportParseProbe {
    private(set) var hasStarted = false

    func markStarted() { hasStarted = true }
}

private struct ProbedSourcePreservingParser: MarkdownParsing {
    let probe: ExportParseProbe

    func parse(_ snapshot: DocumentTextSnapshot) async throws -> ParsedMarkdown {
        await probe.markStarted()
        return try await SourcePreservingMarkdownParser().parse(snapshot)
    }
}

private extension ExportLargeFileTests {
    func assertBlackInkOnWhite(
        _ page: PDFPage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let image = page.thumbnail(of: NSSize(width: 180, height: 220), for: .mediaBox)
        let bitmap = try XCTUnwrap(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
            file: file,
            line: line
        )
        var foundDark = false
        var foundLight = false
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                foundDark = foundDark || brightness < 0.35
                foundLight = foundLight || brightness > 0.95
            }
        }
        XCTAssertTrue(foundDark, "Rendered page contains no black ink", file: file, line: line)
        XCTAssertTrue(foundLight, "Rendered page contains no white paper", file: file, line: line)
    }

    func makeSnapshot(source: String, filename: String) -> DocumentTextSnapshot {
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
            .appendingPathComponent("ClioExportLarge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }
}
