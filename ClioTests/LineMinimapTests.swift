import AppKit
import XCTest
@testable import Clio

final class LineMinimapTests: XCTestCase {
    func testEmptyAndWhitespaceDocumentsHaveNoStrokes() {
        XCTAssertTrue(LineMinimapSnapshot.make(from: "").strokes.isEmpty)
        XCTAssertTrue(LineMinimapSnapshot.make(from: "  \n\t\r\n").strokes.isEmpty)
        XCTAssertTrue(LineMinimapSnapshot.make(from: String(repeating: " \n", count: 40_000) as NSString).strokes.isEmpty)
    }

    func testLinesGrowDownwardWithLengthsAndUTF16Offsets() {
        let snapshot = LineMinimapSnapshot.make(from: "Hi\n\n🙂 longer line\nend")
        XCTAssertEqual(snapshot.strokes.map(\.offset), [0, 4, 19])
        XCTAssertEqual(snapshot.strokes.count, 3)
        XCTAssertLessThan(snapshot.strokes[0].width, snapshot.strokes[1].width)
        XCTAssertFalse(snapshot.isSampled)
        XCTAssertEqual(snapshot.activeIndex(at: 5), 1)
    }

    func testLargeFilesUseBoundedSortedSampling() {
        let source = String(repeating: "🙂 a line of writing\n", count: 100_000) as NSString
        let snapshot = LineMinimapSnapshot.make(from: source)
        XCTAssertTrue(snapshot.isSampled)
        XCTAssertLessThanOrEqual(snapshot.strokes.count, LineMinimapSnapshot.maximumStrokes)
        XCTAssertFalse(snapshot.strokes.isEmpty)
        XCTAssertEqual(snapshot.sourceLength, source.length)
        XCTAssertEqual(snapshot.strokes.map(\.offset), snapshot.strokes.map(\.offset).sorted())
        for stroke in snapshot.strokes {
            XCTAssertFalse((0xDC00...0xDFFF).contains(source.character(at: stroke.offset)))
            XCTAssertTrue((0...1).contains(stroke.width))
        }
    }

    func testShortViewportKeepsFirstAndLastStrokeWithoutOverflow() {
        let snapshot = LineMinimapSnapshot.make(from: String(repeating: "line\n", count: 300) as NSString)
        let displayed = snapshot.displayed(in: 80)
        XCTAssertEqual(displayed.count, 10)
        XCTAssertEqual(displayed.first, snapshot.strokes.first)
        XCTAssertEqual(displayed.last, snapshot.strokes.last)
        XCTAssertEqual(snapshot.displayed(in: 0).count, 1)
    }

    func testActorPublishesMinimapAlongsideIncrementalEdits() async throws {
        let engine = IncrementalMarkdownHighlighter()
        let initial = try await engine.update(source: "One")
        XCTAssertEqual(initial.minimap.strokes.count, 1)
        let next = try await engine.update(edit: MarkdownTextEdit(replacedRange: UTF16Range(location: 3, length: 0), replacement: "\nSecond line"))
        XCTAssertEqual(next.minimap.strokes.count, 2)
        XCTAssertEqual(next.minimap.strokes[1].offset, 4)
        let empty = try await engine.update(source: "")
        XCTAssertTrue(empty.minimap.strokes.isEmpty)
    }

    @MainActor
    func testNavigationPreservesCaretAndSource() {
        let model = EditorMinimapModel()
        let source = String(repeating: "A paragraph\n", count: 60)
        let coordinator = EditorCoordinator(configuration: EditorConfiguration(), onTextEdit: { _ in }, minimap: model)
        let surface = EditorContainerView(textView: EditorTextView.makeTextKit2TextView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        coordinator.attach(to: surface)
        coordinator.update(text: source, contentGeneration: BufferGeneration(bufferID: UUID(), revision: 0), configuration: EditorConfiguration(), onTextEdit: { _ in })
        surface.layoutSubtreeIfNeeded()
        let selection = NSRange(location: source.utf16.count, length: 0)
        surface.textView.setSelectedRange(selection)
        model.navigate?(120)
        XCTAssertEqual(surface.textView.selectedRange(), selection)
        XCTAssertEqual(surface.textView.string, source)
        XCTAssertEqual(surface.scrollView.hasVerticalScroller, NSScroller.preferredScrollerStyle == .legacy)
    }
}
