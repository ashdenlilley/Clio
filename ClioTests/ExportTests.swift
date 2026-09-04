import AppKit
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
            XCTAssertTrue(html.contains("Content-Security-Policy"))
            XCTAssertTrue(html.contains("@media print"))
            XCTAssertFalse(html.contains("<link "))
            XCTAssertFalse(html.contains("<script src="))
            XCTAssertEqual(coordinator.phase, .completed(receipt))
            XCTAssertEqual(coordinator.progress, 1)
        }
    }

    func testHTMLRendererSanitizesControlsScopesTablesAndUsesSafeFootnoteIDs() throws {
        let hostileLabel = "bad\" onclick=\"alert(1) ❤️"
        let text = "before\u{0000}after\u{0085}done"
        let cell: (String) -> MarkdownTableCell = {
            MarkdownTableCell(
                content: [.text(value: $0, range: .init(location: 0, length: $0.utf16.count))],
                range: .init(location: 0, length: $0.utf16.count)
            )
        }
        let footnoteBody: [MarkdownBlock] = [
            .paragraph(
                content: [.text(value: "Footnote body", range: .init(location: 0, length: 13))],
                range: .init(location: 0, length: 13)
            ),
        ]
        let model = MarkdownDocumentModel(blocks: [
            .paragraph(
                content: [
                    .text(value: text, range: .init(location: 0, length: text.utf16.count)),
                    .link(
                        destination: "java\u{0000}script:alert(1)",
                        title: "\" onmouseover=\"alert(1)",
                        content: [.text(value: "unsafe link", range: .init(location: 0, length: 11))],
                        range: .init(location: 0, length: 11)
                    ),
                    .link(
                        destination: " \tjavascript:alert(2)",
                        title: nil,
                        content: [.text(value: "padded link", range: .init(location: 0, length: 11))],
                        range: .init(location: 0, length: 11)
                    ),
                    .image(
                        source: "data:image/png;text/html;base64,PHNjcmlwdD4=",
                        title: nil,
                        alt: [.text(value: "fallback", range: .init(location: 0, length: 8))],
                        range: .init(location: 0, length: 8)
                    ),
                    .footnoteReference(label: hostileLabel, range: .init(location: 0, length: 1)),
                ],
                range: .init(location: 0, length: text.utf16.count)
            ),
            .table(
                MarkdownTable(
                    alignments: [.leading, .trailing],
                    header: [cell("Name"), cell("Value")],
                    rows: [[cell("one"), cell("two")]],
                    range: .init(location: 0, length: 16)
                )
            ),
            .footnoteDefinition(
                label: hostileLabel,
                blocks: footnoteBody,
                range: .init(location: 0, length: 1)
            ),
            .footnoteDefinition(
                label: hostileLabel,
                blocks: footnoteBody,
                range: .init(location: 0, length: 1)
            ),
        ])

        let html = try HTMLDocumentRenderer.render(document: model, title: "Hostile\u{0000}title")
        let safeID = "fn-" + hostileLabel.utf8.map { String(format: "%02x", $0) }.joined()

        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("base-uri 'none'"))
        XCTAssertTrue(html.contains("<th scope=\"col\">Name</th>"))
        XCTAssertTrue(html.contains("href=\"#\(safeID)\""))
        XCTAssertTrue(html.contains("id=\"\(safeID)\""))
        XCTAssertTrue(html.contains("id=\"\(safeID)-2\""))
        XCTAssertFalse(html.contains("id=\"fn-\(hostileLabel)"))
        XCTAssertFalse(html.contains("java\u{0000}script"))
        XCTAssertFalse(html.contains("javascript:alert(2)"))
        XCTAssertFalse(html.contains("data:image/png;text/html"))
        XCTAssertFalse(html.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x85 }))
        XCTAssertTrue(html.contains("before�after�done"))
        XCTAssertTrue(html.contains("<span role=\"img\" aria-label=\"fallback\">fallback</span>"))
    }

    func testStreamingHTMLMatchesSemanticRendererAndEnforcesBoundedOutput() async throws {
        try await withTemporaryDirectory { directory in
            let parsed = try await SourcePreservingMarkdownParser.parse(source: """
            # Stream & verify

            > Quoted **body**

            - [x] finished
            - [ ] pending

            | Name | Value |
            | --- | ---: |
            | café | <safe> |

            [link](https://example.com?a=1&b=2)
            """)
            let expected = try HTMLDocumentRenderer.render(
                document: parsed.document,
                title: "Stream & verify.md"
            )
            let destination = directory.appendingPathComponent("stream.html")
            let count = try HTMLDocumentStreamRenderer.write(
                document: parsed.document,
                title: "Stream & verify.md",
                to: destination,
                reportingDestination: destination
            )
            let bytes = try Data(contentsOf: destination)
            let expectedBytes = Data(expected.utf8)
            XCTAssertEqual(bytes, expectedBytes)
            XCTAssertEqual(count, Int64(bytes.count))

            let boundedURL = directory.appendingPathComponent("bounded.html")
            XCTAssertThrowsError(try HTMLDocumentStreamRenderer.write(
                document: MarkdownDocumentModel(blocks: [
                    .paragraph(
                        content: [
                            .text(
                                value: String(repeating: "<&\"", count: 2_000),
                                range: .init(location: 0, length: 6_000)
                            ),
                        ],
                        range: .init(location: 0, length: 6_000)
                    ),
                ]),
                title: "Bounded",
                to: boundedURL,
                reportingDestination: boundedURL,
                maximumByteCount: 1_024
            )) { error in
                guard case DocumentExportError.artifactTooLarge = error else {
                    return XCTFail("Expected a bounded-output error, got \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: boundedURL.path))
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

            let collision: ExportCollision
            do {
                _ = try await coordinator.export(
                    makeRequest(.html, snapshot: snapshot, destination: destination)
                )
                XCTFail("An existing destination must require a collision choice")
                return
            } catch DocumentExportError.destinationExists(let found) {
                collision = found
            } catch let error as DocumentExportError {
                throw error
            }

            let receipt = try await coordinator.export(
                makeRequest(.html, snapshot: snapshot, destination: destination),
                collisionResolution: ExportCollisionResolution(
                    collision: collision,
                    choice: .keepBoth
                )
            )
            XCTAssertEqual(receipt.destinationURL.lastPathComponent, "Notes (2).html")
            XCTAssertEqual(try String(contentsOf: destination), "original")
        }
    }

    func testExporterStagesACompleteArtifactBeforeInstallation() async throws {
        try await withTemporaryDirectory { directory in
            let snapshot = makeSnapshot(source: "staged")
            let model = MarkdownDocumentModel(blocks: [
                .paragraph(
                    content: [.text(value: "staged", range: .init(location: 0, length: 6))],
                    range: .init(location: 0, length: 6)
                ),
            ])
            let parsed = try await FixtureParser(model: model).parse(snapshot)
            let destination = directory.appendingPathComponent("staged.html")
            let staged = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.html, snapshot: snapshot, destination: destination),
                collisionResolution: nil
            )
            defer { staged.discard() }

            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.temporaryURL.path))
            XCTAssertNotEqual(
                staged.temporaryURL.deletingLastPathComponent().standardizedFileURL,
                destination.deletingLastPathComponent().standardizedFileURL
            )
            XCTAssertGreaterThan(staged.byteCount, 0)

            let receipt = try staged.install()
            XCTAssertEqual(receipt.destinationURL, destination)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.temporaryURL.path))
        }
    }

    func testLateCollisionCannotOverwriteWithoutExplicitReplace() async throws {
        try await withTemporaryDirectory { directory in
            let snapshot = makeSnapshot(source: "staged")
            let model = MarkdownDocumentModel(blocks: [
                .paragraph(
                    content: [.text(value: "staged", range: .init(location: 0, length: 6))],
                    range: .init(location: 0, length: 6)
                ),
            ])
            let parsed = try await FixtureParser(model: model).parse(snapshot)
            let destination = directory.appendingPathComponent("late-collision.html")
            let staged = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(.html, snapshot: snapshot, destination: destination),
                collisionResolution: nil
            )
            defer { staged.discard() }

            try Data("arrived later".utf8).write(to: destination)

            XCTAssertThrowsError(try staged.install()) { error in
                guard case DocumentExportError.destinationExists(let collision) = error else {
                    return XCTFail("Expected destinationExists, got \(error)")
                }
                XCTAssertEqual(collision.destinationURL, destination)
            }
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "arrived later")
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.temporaryURL.path))
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

    func testPDFPaginationRetainsTheDeterministicTailBoundary() async throws {
        try await withTemporaryDirectory { directory in
            let body = (0..<2_500).map { "token-\($0)-café" }.joined(separator: " ")
            let penultimate = "PENULTIMA"
            let tail = "TAIL-Z9-END"
            let snapshot = makeSnapshot(
                source: body + "\n\n" + penultimate + "\n\n" + tail,
                filename: "Boundary.md"
            )
            let model = MarkdownDocumentModel(blocks: [
                .paragraph(
                    content: [.text(value: body, range: .init(location: 0, length: body.utf16.count))],
                    range: .init(location: 0, length: body.utf16.count)
                ),
                .paragraph(
                    content: [.text(value: penultimate, range: .init(location: 0, length: penultimate.utf16.count))],
                    range: .init(location: 0, length: penultimate.utf16.count)
                ),
                .paragraph(
                    content: [.text(value: tail, range: .init(location: 0, length: tail.utf16.count))],
                    range: .init(location: 0, length: tail.utf16.count)
                ),
            ])
            let coordinator = DocumentExportCoordinator(parser: FixtureParser(model: model))
            let destination = directory.appendingPathComponent("Boundary.pdf")
            let settings = PDFPrintSettings(
                paperName: "qa-tail",
                paperWidthPoints: 216,
                paperHeightPoints: 216,
                margins: PrintMargins(top: 18, leading: 18, bottom: 18, trailing: 18),
                orientation: .portrait
            )

            _ = try await coordinator.export(
                makeRequest(.pdf, snapshot: snapshot, destination: destination, settings: settings)
            )
            let pdf = try XCTUnwrap(PDFDocument(url: destination))
            let extracted = try XCTUnwrap(pdf.string)

            XCTAssertGreaterThan(pdf.pageCount, 10)
            XCTAssertTrue(extracted.contains("token-0-café"))
            XCTAssertTrue(extracted.contains(penultimate))
            XCTAssertEqual(extracted.components(separatedBy: tail).count - 1, 1)
        }
    }

    func testPDFTablesAlignColumnsAndWrapLongCellsAcrossPages() async throws {
        try await withTemporaryDirectory { directory in
            let longCell = Array(repeating: "Long cells wrap within their own column", count: 45).joined(separator: " ")
            let source = """
            | Name | Quantity |
            | :--- | ---: |
            | Short | 10 |
            | \(longCell) WRAPPED-END | 200 |
            | Bottom | 3000 |
            """
            let snapshot = makeSnapshot(source: source, filename: "Table.md")
            let destination = directory.appendingPathComponent("Table.pdf")
            let settings = PDFPrintSettings(
                paperName: "table-small",
                paperWidthPoints: 300,
                paperHeightPoints: 360,
                margins: PrintMargins(top: 28, leading: 28, bottom: 28, trailing: 28),
                orientation: .portrait
            )
            _ = try await DocumentExportCoordinator().export(
                makeRequest(.pdf, snapshot: snapshot, destination: destination, settings: settings)
            )
            let document = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertGreaterThan(document.pageCount, 1)
            let headers = document.findString("Table.md", withOptions: [])
            XCTAssertEqual(headers.count, document.pageCount)
            let firstHeader = try XCTUnwrap(headers.first)
            let firstHeaderPage = try XCTUnwrap(firstHeader.pages.first)
            let expectedHeader = firstHeader.bounds(for: firstHeaderPage)
            let contentRect = try PDFPrintGeometry.resolve(settings, fallback: settings).contentRect
            var bodyTop: CGFloat?
            for pageIndex in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: pageIndex))
                let header = try XCTUnwrap(headers.first { $0.pages.contains(page) }, "Missing header on page \(pageIndex + 1)")
                XCTAssertEqual(header.bounds(for: page).minX, expectedHeader.minX, accuracy: 0.5)
                XCTAssertEqual(header.bounds(for: page).minY, expectedHeader.minY, accuracy: 0.5)
                if pageIndex > 0 {
                    let body = try XCTUnwrap(page.selection(for: contentRect))
                    if let bodyTop {
                        XCTAssertEqual(body.bounds(for: page).maxY, bodyTop, accuracy: 0.5)
                    } else {
                        bodyTop = body.bounds(for: page).maxY
                    }
                }
            }
            if FileManager.default.fileExists(atPath: "/tmp/ClioRunPDFVisualFixture") {
                let preserved = FileManager.default.temporaryDirectory.appendingPathComponent("ClioExportTableWrappingFixture.pdf")
                if FileManager.default.fileExists(atPath: preserved.path) {
                    try FileManager.default.removeItem(at: preserved)
                }
                try FileManager.default.copyItem(at: destination, to: preserved)
                print("CLIO_TABLE_WRAPPING_PDF=\(preserved.path)")
            }
            let selection: (String) throws -> (PDFSelection, PDFPage) = { text in
                let selected = try XCTUnwrap(document.findString(text, withOptions: []).first, "Missing table text: \(text)")
                return (selected, try XCTUnwrap(selected.pages.first))
            }
            let (short, shortPage) = try selection("Short")
            let (bottom, bottomPage) = try selection("Bottom")
            XCTAssertEqual(short.bounds(for: shortPage).minX, bottom.bounds(for: bottomPage).minX, accuracy: 0.5)
            let (ten, tenPage) = try selection("10")
            let (threeThousand, lastPage) = try selection("3000")
            XCTAssertEqual(ten.bounds(for: tenPage).maxX, threeThousand.bounds(for: lastPage).maxX, accuracy: 0.5)
            let (tail, tailPage) = try selection("WRAPPED")
            XCTAssertLessThanOrEqual(tail.bounds(for: tailPage).maxX, 150)
            let (tailEnd, tailEndPage) = try selection("END")
            XCTAssertLessThanOrEqual(tailEnd.bounds(for: tailEndPage).maxX, 150)
            XCTAssertLessThanOrEqual(threeThousand.bounds(for: lastPage).maxX, 272)
            XCTAssertFalse(document.string?.contains(" | ") == true)
            XCTAssertFalse(document.string?.contains("-------") == true)
        }
    }

    func testPDFAttributedBuilderPreservesSoftBreaksAndNestedIndentation() throws {
        let breakModel = MarkdownDocumentModel(blocks: [
            .paragraph(
                content: [
                    .text(value: "alpha", range: .init(location: 0, length: 5)),
                    .softBreak(range: .init(location: 5, length: 1)),
                    .text(value: "beta", range: .init(location: 6, length: 4)),
                    .hardBreak(range: .init(location: 10, length: 1)),
                    .text(value: "gamma", range: .init(location: 11, length: 5)),
                ],
                range: .init(location: 0, length: 16)
            ),
        ])
        let breaks = try PDFAttributedDocumentBuilder.build(breakModel)
        XCTAssertEqual(breaks.string, "alpha beta\ngamma\n")

        let nestedModel = MarkdownDocumentModel(blocks: [
            .list(
                MarkdownList(
                    isOrdered: false,
                    start: nil,
                    isTight: false,
                    items: [
                        MarkdownListItem(
                            taskState: nil,
                            blocks: [
                                .paragraph(
                                    content: [.text(value: "first", range: .init(location: 0, length: 5))],
                                    range: .init(location: 0, length: 5)
                                ),
                                .paragraph(
                                    content: [.text(value: "second", range: .init(location: 0, length: 6))],
                                    range: .init(location: 0, length: 6)
                                ),
                            ],
                            range: .init(location: 0, length: 12)
                        ),
                    ],
                    range: .init(location: 0, length: 12)
                )
            ),
        ])
        let nested = try PDFAttributedDocumentBuilder.build(nestedModel)
        let secondLocation = (nested.string as NSString).range(of: "second").location
        let paragraph = try XCTUnwrap(
            nested.attribute(.paragraphStyle, at: secondLocation, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.headIndent, 18, accuracy: 0.01)
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

        let headerAndFooterCollision = PDFPrintSettings(
            paperName: "invalid-landscape",
            paperWidthPoints: 100,
            paperHeightPoints: 200,
            margins: PrintMargins(top: 30, leading: 10, bottom: 30, trailing: 10),
            orientation: .landscape
        )
        XCTAssertTrue(headerAndFooterCollision.isValid)
        XCTAssertThrowsError(try store.update(headerAndFooterCollision))

        let unresolvedWithHugeMargins = PDFPrintSettings(
            paperName: nil,
            paperWidthPoints: nil,
            paperHeightPoints: nil,
            margins: PrintMargins(top: 10_000, leading: 10_000, bottom: 10_000, trailing: 10_000),
            orientation: .portrait
        )
        XCTAssertThrowsError(try store.update(unresolvedWithHugeMargins))

        let nonFinite = PDFPrintSettings(
            paperName: "invalid-infinity",
            paperWidthPoints: .infinity,
            paperHeightPoints: 792,
            margins: PrintMargins(top: 54, leading: 54, bottom: 54, trailing: 54),
            orientation: .portrait
        )
        XCTAssertFalse(nonFinite.isValid)

        defaults.set(try JSONEncoder().encode(headerAndFooterCollision), forKey: "export.pdf.printSettings")
        XCTAssertNotEqual(PDFPrintSettingsStore(defaults: defaults).settings, headerAndFooterCollision)
    }

    func testPDFDefaultsUseSystemPrintInfoWithRegionalFallback() throws {
        let canada = PDFPrintSettingsStore.regionalDefault(locale: Locale(identifier: "en_CA"))
        let australia = PDFPrintSettingsStore.regionalDefault(locale: Locale(identifier: "en_AU"))
        XCTAssertEqual(canada.paperName, "na-letter")
        XCTAssertEqual(canada.paperWidthPoints, 612)
        XCTAssertEqual(australia.paperName, "iso-a4")
        XCTAssertEqual(australia.paperWidthPoints ?? 0, 595.2756, accuracy: 0.001)

        let printInfo = NSPrintInfo(dictionary: [:])
        printInfo.paperSize = NSSize(width: 500, height: 700)
        printInfo.orientation = .landscape
        printInfo.topMargin = 31
        printInfo.leftMargin = 32
        printInfo.bottomMargin = 33
        printInfo.rightMargin = 34
        let system = PDFPrintSettingsStore.systemDefault(
            printInfo: printInfo,
            locale: Locale(identifier: "en_AU")
        )

        XCTAssertEqual(system.paperWidthPoints, 500)
        XCTAssertEqual(system.paperHeightPoints, 700)
        XCTAssertEqual(system.orientation, .landscape)
        XCTAssertEqual(system.margins, PrintMargins(top: 31, leading: 32, bottom: 33, trailing: 34))
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
            XCTAssertNil(coordinator.progress)
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

    func testCancellationDuringLargeHTMLRenderingPreservesExistingDestination() async throws {
        try await withTemporaryDirectory { directory in
            let snapshot = makeSnapshot(source: "large cancellation fixture")
            let largeText = String(repeating: "<&", count: 8_000_000)
            let model = MarkdownDocumentModel(blocks: [
                .paragraph(
                    content: [
                        .text(
                            value: largeText,
                            range: .init(location: 0, length: largeText.utf16.count)
                        ),
                    ],
                    range: .init(location: 0, length: largeText.utf16.count)
                ),
            ])
            let coordinator = DocumentExportCoordinator(parser: FixtureParser(model: model))
            let destination = directory.appendingPathComponent("cancel-render.html")
            try Data("original".utf8).write(to: destination)
            let collision = try XCTUnwrap(ExportDestination.collision(at: destination))

            let operation = Task {
                try await coordinator.export(
                    makeRequest(.html, snapshot: snapshot, destination: destination),
                    collisionResolution: ExportCollisionResolution(
                        collision: collision,
                        choice: .replace
                    )
                )
            }
            for _ in 0..<2_000 where coordinator.phase != .rendering(.html) {
                await Task.yield()
            }
            XCTAssertEqual(coordinator.phase, .rendering(.html))
            try await Task.sleep(for: .milliseconds(5))
            operation.cancel()

            do {
                _ = try await operation.value
                XCTFail("Cancellation during rendering should escape to the caller")
            } catch is CancellationError {
                XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
                XCTAssertEqual(coordinator.phase, .cancelled)
                let temporaryFiles = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).filter { $0.lastPathComponent.hasPrefix(".clio-export-") }
                XCTAssertTrue(temporaryFiles.isEmpty)
            }
        }
    }

    func testCancelAfterCommittedExportDoesNotRewriteSuccessfulState() async throws {
        try await withTemporaryDirectory { directory in
            let snapshot = makeSnapshot(source: "committed")
            let model = MarkdownDocumentModel(blocks: [
                .paragraph(
                    content: [.text(value: "committed", range: .init(location: 0, length: 9))],
                    range: .init(location: 0, length: 9)
                ),
            ])
            let coordinator = DocumentExportCoordinator(parser: FixtureParser(model: model))
            let destination = directory.appendingPathComponent("committed.html")
            let receipt = try await coordinator.export(
                makeRequest(.html, snapshot: snapshot, destination: destination)
            )

            coordinator.cancel()

            XCTAssertEqual(coordinator.phase, .completed(receipt))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8).isEmpty, false)
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
        let resolution = try ExportDestination.collision(at: destination).map {
            ExportCollisionResolution(collision: $0, choice: .replace)
        }
        _ = try await coordinator.export(
            makeRequest(
                .pdf,
                snapshot: snapshot,
                destination: destination,
                settings: PDFPrintSettingsStore.regionalDefault()
            ),
            collisionResolution: resolution
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let htmlDestination = destination.deletingPathExtension()
            .appendingPathExtension("html")
        let htmlResolution = try ExportDestination.collision(at: htmlDestination).map {
            ExportCollisionResolution(collision: $0, choice: .replace)
        }
        _ = try await coordinator.export(
            makeRequest(.html, snapshot: snapshot, destination: htmlDestination),
            collisionResolution: htmlResolution
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlDestination.path))
        print("CLIO_VISUAL_PDF=\(destination.path)")
        print("CLIO_VISUAL_HTML=\(htmlDestination.path)")
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
