import AppKit
import XCTest
@testable import Clio

final class EditorPerformanceTests: XCTestCase {
    @MainActor
    func testRevisionAwareSynchronizationDoesNotReplaceBufferAfterLocalEdit() {
        var model = "alpha"
        var revision: UInt64 = 0
        let applyEdit: @MainActor (MarkdownTextEdit) -> Void = { edit in
            if let updated = MarkdownTextEditApplier.applying(edit, to: model) {
                model = updated
                revision &+= 1
            }
        }
        let configuration = EditorConfiguration(isFocusModeEnabled: false)
        let coordinator = EditorCoordinator(
            configuration: configuration,
            onTextEdit: applyEdit
        )
        let textView = EditorTextView.makeTextKit2TextView()
        let surface = EditorContainerView(textView: textView)
        let bufferID = UUID()
        coordinator.attach(to: surface)
        coordinator.update(
            text: model,
            contentGeneration: BufferGeneration(bufferID: bufferID, revision: revision),
            configuration: configuration,
            onTextEdit: applyEdit
        )

        let insertion = NSRange(location: textView.textStorage?.length ?? 0, length: 0)
        XCTAssertTrue(coordinator.textView(
            textView,
            shouldChangeTextIn: insertion,
            replacementString: "!"
        ))
        textView.textStorage?.replaceCharacters(in: insertion, with: "!")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.update(
            text: model,
            contentGeneration: BufferGeneration(bufferID: bufferID, revision: revision),
            configuration: configuration,
            onTextEdit: applyEdit
        )

        XCTAssertEqual(model, "alpha!")
        XCTAssertEqual(coordinator.acceptedEditorMutationCount, 1)
        XCTAssertEqual(coordinator.externalBufferReplacementCount, 1)

        model = "bravo!"
        revision &+= 1
        coordinator.update(
            text: model,
            contentGeneration: BufferGeneration(bufferID: bufferID, revision: revision),
            configuration: configuration,
            onTextEdit: applyEdit
        )
        XCTAssertEqual(textView.string, "bravo!")
        XCTAssertEqual(coordinator.externalBufferReplacementCount, 2)

        model = "other!"
        coordinator.update(
            text: model,
            contentGeneration: BufferGeneration(bufferID: UUID(), revision: revision),
            configuration: configuration,
            onTextEdit: applyEdit
        )
        XCTAssertEqual(textView.string, "other!")
        XCTAssertEqual(coordinator.externalBufferReplacementCount, 3)
    }

    @MainActor
    func testRealTextViewTailInsertionsKeepMainActorHeartbeatWithinFrameBudget() async {
        for byteCount in [10, 50].map({ $0 * 1_024 * 1_024 }) {
            let line = String(repeating: "a", count: 79) + "\n"
            let source = String(repeating: line, count: byteCount / line.utf8.count)
                + String(repeating: "a", count: byteCount % line.utf8.count)
            var capturedEdit: MarkdownTextEdit?
            let sink: @MainActor (MarkdownTextEdit) -> Void = { capturedEdit = $0 }
            let configuration = EditorConfiguration(
                isSpellCheckingEnabled: false,
                isTypewriterScrollingEnabled: false,
                isFocusModeEnabled: false
            )
            let coordinator = EditorCoordinator(
                configuration: configuration,
                onTextEdit: sink
            )
            let textView = EditorTextView.makeTextKit2TextView()
            let surface = EditorContainerView(textView: textView)
            coordinator.attach(to: surface)
            coordinator.update(
                text: source,
                contentGeneration: BufferGeneration(revision: 0),
                configuration: configuration,
                onTextEdit: sink
            )
            let insertion = NSRange(location: byteCount, length: 0)
            let clock = ContinuousClock()
            let start = clock.now
            XCTAssertTrue(coordinator.textView(
                textView,
                shouldChangeTextIn: insertion,
                replacementString: "!"
            ))
            textView.textStorage?.replaceCharacters(in: insertion, with: "!")
            coordinator.textDidChange(
                Notification(name: NSText.didChangeNotification, object: textView)
            )
            let elapsed = start.duration(to: clock.now)

            XCTAssertEqual(
                capturedEdit,
                MarkdownTextEdit(
                    replacedRange: UTF16Range(location: byteCount, length: 0),
                    replacement: "!"
                )
            )
            XCTAssertLessThan(
                elapsed,
                .milliseconds(16),
                "\(byteCount / 1_024 / 1_024) MiB tail edit stalled the main actor for \(elapsed)"
            )

            // Give the run loop an opportunity to prove the edit returned to
            // the main actor instead of hiding deferred synchronous work.
            await Task.yield()
        }
    }

    @MainActor
    func testRapidLargeSessionEditsBatchToExactDurableBytes() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )

        for mebibytes in [10, 50] {
            let byteCount = mebibytes * 1_024 * 1_024
            let line = String(repeating: "word ", count: 15) + "end\n"
            let source = String(repeating: line, count: byteCount / line.utf8.count)
                + String(repeating: "x", count: byteCount % line.utf8.count)
            let fileURL = directoryURL.appendingPathComponent("large-\(mebibytes).md")
            try Data(source.utf8).write(to: fileURL)
            let session = EditorSession(openingMode: .mostRecent)
            session.activate(in: workspace, documentURLs: [fileURL])

            let suffix = (0..<100).map { String($0 % 10) }.joined()
            let clock = ContinuousClock()
            let enqueueStarted = clock.now
            for (offset, character) in suffix.enumerated() {
                session.editorTextDidChange(MarkdownTextEdit(
                    replacedRange: UTF16Range(
                        location: byteCount + offset,
                        length: 0
                    ),
                    replacement: String(character)
                ))
            }
            XCTAssertLessThan(
                enqueueStarted.duration(to: clock.now),
                .milliseconds(16),
                "\(mebibytes) MiB edit burst blocked the main actor"
            )

            let modelDeadline = clock.now.advanced(by: .seconds(5))
            var heartbeats = 0
            while session.contentRevision != 100, clock.now < modelDeadline {
                try await Task.sleep(for: .milliseconds(5))
                heartbeats += 1
            }

            let expected = source + suffix
            XCTAssertGreaterThan(heartbeats, 0)
            XCTAssertEqual(session.contentRevision, 100)
            XCTAssertEqual(session.draftText, expected)
            XCTAssertLessThanOrEqual(session.editorMaterializationCount, 2)
            XCTAssertLessThanOrEqual(session.editorPublicationCount, 2)

            let saveDeadline = clock.now.advanced(by: .seconds(5))
            while ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    != expected.utf8.count), clock.now < saveDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(try Data(contentsOf: fileURL), Data(expected.utf8))
            session.deactivate()
        }
    }

    @MainActor
    func testLargeWordCountRunsOffMainAndOnlyLatestRevisionPublishes() async throws {
        let session = EditorSession(openingMode: .newDocument)
        let stale = String(repeating: "stale ", count: 300_000)
        let latest = String(repeating: "latest ", count: 280_000)
        session.draftText = stale
        session.draftText = latest

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var heartbeats = 0
        while session.wordCount != 280_000, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            heartbeats += 1
        }

        XCTAssertEqual(session.wordCount, 280_000)
        XCTAssertGreaterThan(heartbeats, 0)
    }

    func testConflictPreviewBoundsDecodeAndDisplayedLineLength() async throws {
        let prefix = Data(String(repeating: "a", count: 5 * 1_024 * 1_024).utf8)
        let external = Data(String(repeating: "b", count: 5 * 1_024 * 1_024).utf8)
        let workspaceID = WorkspaceID()
        let conflict = try DocumentConflict(
            documentID: DocumentID(),
            locator: DocumentLocator(workspaceID: workspaceID, relativePath: "draft.md"),
            generation: BufferGeneration(),
            clio: ConflictSide(
                modificationDate: .distantPast,
                revision: nil,
                data: prefix
            ),
            external: ConflictSide(
                modificationDate: .now,
                revision: nil,
                data: external
            )
        )

        let preview = await ConflictPreviewBuilder.preview(for: conflict)

        XCTAssertLessThan(preview.utf8.count, 2_048)
        XCTAssertTrue(preview.contains("outside this bounded preview"))
        XCTAssertTrue(preview.contains("− "))
        XCTAssertTrue(preview.contains("+ "))
    }
}
