import XCTest
@testable import Clio

@MainActor
final class ContractTests: XCTestCase {
    func testDocumentIdentityRoundTrips() throws {
        let uuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let identity = DocumentID(rawValue: uuid)
        let encoded = try JSONEncoder().encode(identity)

        XCTAssertEqual(try JSONDecoder().decode(DocumentID.self, from: encoded), identity)
        XCTAssertEqual(identity.rawValue, uuid)
    }

    func testPhysicalFileIdentityCoalescesEquivalentPaths() throws {
        try withTemporaryDirectory { directoryURL in
            let nestedURL = directoryURL.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
            let fileURL = nestedURL.appendingPathComponent("note.md")
            try Data("text".utf8).write(to: fileURL)
            let equivalentURL = nestedURL
                .appendingPathComponent("..")
                .appendingPathComponent("folder/note.md")

            XCTAssertEqual(
                PhysicalFileIdentity.authorizedFile(at: fileURL),
                PhysicalFileIdentity.authorizedFile(at: equivalentURL)
            )
        }
    }

    func testPhysicalFileIdentityUsesOneExactHashingStrategy() {
        let resource = PhysicalFileIdentity.resource(
            volumeIdentifier: "volume",
            fileResourceIdentifier: "file"
        )
        let sameResource = PhysicalFileIdentity.resource(
            volumeIdentifier: "volume",
            fileResourceIdentifier: "file"
        )
        let path = PhysicalFileIdentity.path(canonicalPath: "/tmp/note.md")

        XCTAssertEqual(resource, sameResource)
        XCTAssertNotEqual(resource, path)
        XCTAssertEqual(Set([resource, sameResource, path]).count, 2)
    }

    func testDocumentLocatorRejectsWorkspaceEscapeDuringInitAndDecode() throws {
        let workspaceID = WorkspaceID()
        XCTAssertThrowsError(
            try DocumentLocator(workspaceID: workspaceID, relativePath: "../outside.md")
        )

        let valid = try DocumentLocator(
            workspaceID: workspaceID,
            relativePath: "notes/draft.md"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        var invalidObject = object
        invalidObject["relativePath"] = "../outside.md"
        let invalidData = try JSONSerialization.data(withJSONObject: invalidObject)
        XCTAssertThrowsError(
            try JSONDecoder().decode(DocumentLocator.self, from: invalidData)
        )
    }

    func testViewportClampingIsUTF16Safe() {
        let state = EditorViewportState(
            selection: UTF16Range(location: 9, length: 40),
            topVisibleUTF16Offset: -10,
            fractionalYOffset: 3
        )

        XCTAssertEqual(
            state.clamped(toUTF16Length: 12),
            EditorViewportState(
                selection: UTF16Range(location: 9, length: 3),
                topVisibleUTF16Offset: 0,
                fractionalYOffset: 1
            )
        )
    }

    func testRestorationNormalizesMissingAndNilActiveTabs() {
        let tab = EditorTabRestorationState(
            id: UUID(),
            documentID: DocumentID(),
            locator: nil,
            preferredFilename: "untitled.md",
            viewport: .zero
        )
        var window = EditorWindowRestorationState(
            id: UUID(),
            tabs: [tab],
            activeTabID: UUID(),
            isSidebarVisible: false,
            isSidebarPinned: false,
            isFullScreen: false
        )

        window.normalize()
        XCTAssertEqual(window.activeTabID, tab.id)
        window.activeTabID = nil
        window.normalize()
        XCTAssertEqual(window.activeTabID, tab.id)
        window.tabs = []
        window.normalize()
        XCTAssertNil(window.activeTabID)
    }

    func testPerformanceFixtureIsDeterministicAndExact() {
        let first = PerformanceFixtureGenerator.document(index: 42, utf8ByteCount: 8_192)
        let second = PerformanceFixtureGenerator.document(index: 42, utf8ByteCount: 8_192)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.utf8.count, 8_192)
        XCTAssertNotEqual(
            first,
            PerformanceFixtureGenerator.document(index: 43, utf8ByteCount: 8_192)
        )
    }

    func testPerformanceWorkspaceFixtureIsReproducible() throws {
        try withTemporaryDirectory { directoryURL in
            let firstRoot = directoryURL.appendingPathComponent("first")
            let secondRoot = directoryURL.appendingPathComponent("second")
            let first = try PerformanceFixtureGenerator.writeWorkspace(
                at: firstRoot,
                documentCount: 17,
                totalUTF8ByteCount: 65_537
            )
            let second = try PerformanceFixtureGenerator.writeWorkspace(
                at: secondRoot,
                documentCount: 17,
                totalUTF8ByteCount: 65_537
            )

            XCTAssertEqual(first.count, 17)
            XCTAssertEqual(second.count, 17)
            XCTAssertEqual(
                try first.map { try Data(contentsOf: $0) },
                try second.map { try Data(contentsOf: $0) }
            )
            XCTAssertEqual(
                try first.reduce(Int64(0)) {
                    $0 + Int64(try Data(contentsOf: $1).count)
                },
                65_537
            )
        }
    }

    func testDocumentSizeModesUseContractBoundaries() {
        XCTAssertEqual(
            DocumentSizeMode.mode(forUTF8ByteCount: PerformanceContract.fullMarkdownByteLimit),
            .full
        )
        XCTAssertEqual(
            DocumentSizeMode.mode(forUTF8ByteCount: PerformanceContract.fullMarkdownByteLimit + 1),
            .safeLargeFile
        )
        XCTAssertEqual(
            DocumentSizeMode.mode(forUTF8ByteCount: PerformanceContract.safeLargeFileByteLimit + 1),
            .unsupported
        )
    }

    func testMarkdownTreeExpressesNestedExportSemantics() throws {
        let range = UTF16Range(location: 0, length: 12)
        let link = MarkdownInline.link(
            destination: "https://example.com",
            title: "Example",
            content: [.text(value: "site", range: range)],
            range: range
        )
        let nested = MarkdownBlock.list(
            MarkdownList(
                isOrdered: false,
                start: nil,
                isTight: true,
                items: [
                    MarkdownListItem(
                        taskState: .checked,
                        blocks: [.paragraph(content: [link], range: range)],
                        range: range
                    ),
                ],
                range: range
            )
        )
        let table = MarkdownBlock.table(
            MarkdownTable(
                alignments: [.leading],
                header: [
                    MarkdownTableCell(
                        content: [.text(value: "Name", range: range)],
                        range: range
                    ),
                ],
                rows: [[
                    MarkdownTableCell(
                        content: [.text(value: "Clio", range: range)],
                        range: range
                    ),
                ]],
                range: range
            )
        )
        let model = MarkdownDocumentModel(
            blocks: [
                nested,
                table,
                .footnoteDefinition(
                    label: "1",
                    blocks: [
                        .paragraph(
                            content: [.text(value: "note", range: range)],
                            range: range
                        ),
                    ],
                    range: range
                ),
            ]
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                MarkdownDocumentModel.self,
                from: JSONEncoder().encode(model)
            ),
            model
        )
    }

    func testMarkdownModelRetainsAutolinkDisplayAndDestination() throws {
        let range = UTF16Range(location: 0, length: 15)
        let model = MarkdownDocumentModel(
            blocks: [
                .paragraph(
                    content: [
                        .autolink(
                            text: "www.example.com",
                            destination: "http://www.example.com",
                            range: range
                        ),
                        .autolink(
                            text: "user@example.com",
                            destination: "mailto:user@example.com",
                            range: range
                        ),
                    ],
                    range: range
                ),
            ]
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                MarkdownDocumentModel.self,
                from: JSONEncoder().encode(model)
            ),
            model
        )
    }

    func testMarkdownSpansAreStableValues() {
        let span = MarkdownSpan(
            kind: .heading,
            role: .content,
            range: UTF16Range(location: 2, length: 5),
            level: 1
        )
        XCTAssertEqual(Set([span, span]).count, 1)
    }

    func testReopenedRevisionZeroBuffersHaveDistinctGenerations() {
        XCTAssertNotEqual(
            BufferGeneration(bufferID: UUID(), revision: 0),
            BufferGeneration(bufferID: UUID(), revision: 0)
        )
    }

    func testParsedMarkdownRejectsStaleGeneration() {
        let documentID = DocumentID()
        let current = DocumentTextSnapshot(
            documentID: documentID,
            generation: BufferGeneration(revision: 1),
            filename: "note.md",
            source: "# Current",
            sourceFingerprint: "current"
        )
        let stale = ParsedMarkdown(
            documentID: documentID,
            generation: BufferGeneration(revision: 0),
            sourceFingerprint: "stale",
            sizeMode: .full,
            document: MarkdownDocumentModel(blocks: []),
            spans: [],
            diagnostics: []
        )

        XCTAssertFalse(stale.canApply(to: current))
    }

    func testPDFPrintSettingsRejectInvalidPrintableArea() {
        let invalid = PDFPrintSettings(
            paperName: "A4",
            paperWidthPoints: 100,
            paperHeightPoints: 100,
            margins: PrintMargins(top: 60, leading: 60, bottom: 60, trailing: 60),
            orientation: .portrait
        )
        let valid = PDFPrintSettings(
            paperName: "A4",
            paperWidthPoints: 595,
            paperHeightPoints: 842,
            margins: PrintMargins(top: 36, leading: 36, bottom: 36, trailing: 36),
            orientation: .portrait
        )
        let partial = PDFPrintSettings(
            paperName: "A4",
            paperWidthPoints: 595,
            paperHeightPoints: nil,
            margins: PrintMargins(top: 36, leading: 36, bottom: 36, trailing: 36),
            orientation: .landscape
        )

        XCTAssertFalse(invalid.isValid)
        XCTAssertTrue(valid.isValid)
        XCTAssertFalse(partial.isValid)
    }

    func testMainActorExportCoordinatorContractRetainsGeneration() async throws {
        let generation = BufferGeneration(revision: 7)
        let snapshot = DocumentTextSnapshot(
            documentID: DocumentID(),
            generation: generation,
            filename: "draft.md",
            source: "Draft",
            sourceFingerprint: "fingerprint"
        )
        let coordinator: any DocumentExportCoordinating = FakeExportCoordinator()
        let receipt = try await coordinator.export(
            ExportRequest(
                format: .html,
                snapshot: snapshot,
                destinationURL: URL(fileURLWithPath: "/tmp/draft.html"),
                pdfSettings: nil
            )
        )

        XCTAssertEqual(receipt.generation, generation)
        XCTAssertEqual(receipt.sourceFingerprint, "fingerprint")
    }

    func testContractDoublesCompileAndProduceProgressiveSearch() async throws {
        let workspaceID = WorkspaceID()
        let locator = try DocumentLocator(
            workspaceID: workspaceID,
            relativePath: "notes/example.md"
        )
        let result = WorkspaceSearchResult(
            documentID: DocumentID(),
            workspaceID: workspaceID,
            relativePath: locator.relativePath,
            documentMatchRange: UTF16Range(location: 2, length: 4),
            excerptMatchRange: UTF16Range(location: 0, length: 4),
            score: 1
        )
        let index: any SearchIndexing = FakeSearchIndex(result: result)
        let stream = await index.search(WorkspaceSearchQuery(text: "clio"))
        var batches: [SearchBatch] = []
        for try await batch in stream {
            batches.append(batch)
        }

        XCTAssertEqual(batches, [
            SearchBatch(results: [result], isFinal: false),
            SearchBatch(results: [result], isFinal: true),
        ])

        let eventSource: any WorkspaceEventSource = FakeWorkspaceEventSource()
        var eventCount = 0
        for await _ in await eventSource.events() { eventCount += 1 }
        XCTAssertEqual(eventCount, 0)

        let restoration: any SessionRestorationPersisting = FakeRestorationStore()
        let restoredStates = try await restoration.load()
        XCTAssertEqual(restoredStates, [])
        _ = FakeFileRepository()
        _ = FakeRecoveryStore()
        _ = FakeBufferRegistry()
        _ = FakeCommandDispatcher()
    }
}

@MainActor
private final class FakeExportCoordinator: DocumentExportCoordinating {
    func export(_ request: ExportRequest) async throws -> ExportReceipt {
        ExportReceipt(
            format: request.format,
            destinationURL: request.destinationURL,
            byteCount: Int64(request.snapshot.source.utf8.count),
            completedAt: Date(timeIntervalSince1970: 0),
            generation: request.snapshot.generation,
            sourceFingerprint: request.snapshot.sourceFingerprint
        )
    }
}

private actor FakeSearchIndex: SearchIndexing {
    let result: WorkspaceSearchResult

    init(result: WorkspaceSearchResult) {
        self.result = result
    }

    func rebuild(workspaces _: [WorkspaceDescriptor], policy _: DiscoveryPolicy) async throws {}
    func apply(_: [WorkspaceEvent]) async throws {}

    func quickOpen(_ query: WorkspaceSearchQuery) async -> AsyncThrowingStream<SearchBatch, Error> {
        search(query)
    }

    func search(_: WorkspaceSearchQuery) -> AsyncThrowingStream<SearchBatch, Error> {
        let result = result
        return AsyncThrowingStream { continuation in
            continuation.yield(SearchBatch(results: [result], isFinal: false))
            continuation.yield(SearchBatch(results: [result], isFinal: true))
            continuation.finish()
        }
    }
}

private actor FakeWorkspaceEventSource: WorkspaceEventSource {
    func events() -> AsyncStream<WorkspaceEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor FakeRestorationStore: SessionRestorationPersisting {
    func load() async throws -> [EditorWindowRestorationState] { [] }
    func save(_: [EditorWindowRestorationState]) async throws {}
}

private actor FakeFileRepository: FileRepositoryProtocol {
    enum StubError: Error { case unimplemented }

    func read(_: DocumentLocator) async throws -> DiskSnapshot { throw StubError.unimplemented }
    func save(_: SaveRequest) async throws -> SaveOutcome { throw StubError.unimplemented }
    func resolve(_: ConflictResolutionRequest) async throws -> SaveOutcome { throw StubError.unimplemented }
    func move(_: FileMoveRequest) async throws -> FileMutationOutcome { throw StubError.unimplemented }
    func moveToTrash(_: DocumentLocator) async throws { throw StubError.unimplemented }
}

private actor FakeRecoveryStore: RecoveryPersisting {
    enum StubError: Error { case unimplemented }

    func preserve(
        documentID _: DocumentID,
        filename _: String,
        data _: Data,
        sourceModificationDate _: Date?
    ) async throws -> RecoveryReceipt {
        throw StubError.unimplemented
    }

    func prune(olderThan _: Date) async throws {}
}

@MainActor
private final class FakeBufferRegistry: DocumentBufferRegistering {
    func documentID(
        for _: PhysicalFileIdentity,
        locator _: DocumentLocator
    ) -> DocumentID {
        DocumentID()
    }

    func updateAliases(
        for _: DocumentID,
        identity _: PhysicalFileIdentity,
        locator _: DocumentLocator
    ) {}
}

@MainActor
private final class FakeCommandDispatcher: ClioCommandDispatching {
    func perform(
        _: ClioCommandInvocation,
        context _: ClioCommandContext
    ) async {}
}

private extension ContractTests {
    func withTemporaryDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        return try operation(directoryURL)
    }
}
