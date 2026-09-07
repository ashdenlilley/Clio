import AppKit
import XCTest
@testable import Clio

final class WritingWorkspaceTests: XCTestCase {
    @MainActor
    func testEditorTeardownDisconnectsCallbacksAndIsIdempotent() async throws {
        let config = EditorConfiguration()
        let view = EditorTextView.makeTextKit2TextView()
        let surface = EditorContainerView(textView: view)
        let coordinator = EditorCoordinator(configuration: config, onTextEdit: { _ in XCTFail("Detached editor published an edit") })
        coordinator.attach(to: surface)
        let wasEditable = view.isEditable
        coordinator.detach()
        coordinator.detach()
        surface.prepareForRemoval()
        surface.prepareForRemoval()
        XCTAssertNil(view.delegate)
        XCTAssertNil(view.onUserScroll)
        XCTAssertNil(view.onKeyEventBegan)
        XCTAssertNil(view.onKeyEventEnded)
        XCTAssertNil(view.onMarkdownAction)
        XCTAssertNil(surface.onViewportSizeChanged)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(view.isEditable, wasEditable)
    }

    @MainActor
    func testSelectedFontChangesDisplayWithoutChangingMarkdownOrSelection() throws {
        let name = try XCTUnwrap(NSFont(name: "Helvetica", size: 16)).fontName
        let view = EditorTextView.makeTextKit2TextView()
        view.string = "**Bold** and *italic*"
        let range = NSRange(location: 2, length: 4)
        view.setSelectedRange(range)
        let configuration = EditorConfiguration(fontSize: 16, fontName: name)
        view.applyEditorConfiguration(configuration)
        view.applyBaseAttributes(for: configuration)
        XCTAssertEqual(view.font?.fontName, name)
        XCTAssertEqual(view.string, "**Bold** and *italic*")
        XCTAssertEqual(view.selectedRange(), range)
        XCTAssertEqual(Typography.font(size: 16, traits: .boldFontMask, name: name).familyName,
                       NSFont(name: name, size: 16)?.familyName)
        XCTAssertEqual(Typography.font(size: 16, name: "Unavailable-Clio-Test-Font").fontName,
                       Typography.font(size: 16).fontName)
    }

    @MainActor
    func testAccentSwatchesAreFullColourMenuImages() {
        for accent in AppState.AccentPreset.allCases {
            let image = AccentSwatch.image(for: accent.nsColor)
            XCTAssertFalse(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 14, height: 14))
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }

    @MainActor
    func testTypewriterPaddingKeepsVisibleLinesInsideNativeHitAreaAcrossResizeAndToggle() {
        let view = EditorTextView.makeTextKit2TextView()
        let surface = EditorContainerView(textView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        let scroller = TypewriterScroller()
        let source = "Alpha beta gamma\nSecond line\nThird line"
        view.string = source
        for enabled in [true, false, true] {
            for anchor in [CGFloat(0.30), CGFloat(0.45), CGFloat(0.60)] {
                let config = EditorConfiguration(isTypewriterScrollingEnabled: enabled,
                                                 typewriterAnchor: anchor, isFocusModeEnabled: false)
                surface.apply(configuration: config)
                view.applyBaseAttributes(for: config)
                for size in [NSSize(width: 900, height: 600), NSSize(width: 1440, height: 1000), NSSize(width: 900, height: 600)] {
                    window.setContentSize(size)
                    surface.layoutSubtreeIfNeeded()
                    scroller.updateViewportInsets(in: surface, configuration: config)
                    XCTAssertEqual(surface.scrollView.contentInsets.top, 0)
                    XCTAssertEqual(surface.scrollView.contentInsets.bottom, 0)
                    for offset in [0, 17, 29] {
                        view.setSelectedRange(NSRange(location: offset, length: 0))
                        scroller.scrollCaretToAnchor(in: surface, configuration: config, animated: false)
                        view.scrollRangeToVisible(view.selectedRange())
                        let screen = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
                        let rect = view.convert(window.convertFromScreen(screen), from: nil)
                        let point = NSPoint(x: rect.midX + 2, y: rect.midY)
                        XCTAssertTrue(view.bounds.contains(point))
                        XCTAssertTrue(surface.scrollView.documentVisibleRect.contains(point))
                        let hit = surface.hitTest(surface.convert(point, from: view))
                        XCTAssertTrue(hit === view, "Visible text must receive native mouse input")
                    }
                    XCTAssertEqual(view.string, source)
                }
                if !enabled { XCTAssertEqual(view.textContainerInset.height, Metrics.verticalPadding) }
            }
        }
    }

    func testReadingAndSpeakingTimesRoundUpToWholeSeconds() {
        XCTAssertEqual(WritingTime.label(words: 500, wordsPerMinute: 250), "2m")
        XCTAssertEqual(WritingTime.label(words: 500, wordsPerMinute: 140), "3m 35s")
        XCTAssertEqual(WritingTime.label(words: 1, wordsPerMinute: 250), "1s")
        XCTAssertEqual(WritingTime.label(words: 0, wordsPerMinute: 140), "0s")
        XCTAssertEqual(WritingTime.label(words: -1, wordsPerMinute: 140), "0s")
    }

    @MainActor
    func testEveryAccentUpdatesCaretAndSelectionWithoutChangingText() {
        let view = EditorTextView.makeTextKit2TextView()
        view.string = "Alpha 🙂 beta"
        view.setSelectedRange(NSRange(location: 1, length: 3))
        for accent in AppState.AccentPreset.allCases {
            view.applyEditorConfiguration(EditorConfiguration(accent: accent))
            XCTAssertEqual(view.insertionPointColor, accent.nsColor)
            XCTAssertEqual(view.selectedTextAttributes[.backgroundColor] as? NSColor,
                           accent.nsColor.withAlphaComponent(0.55))
            XCTAssertEqual(view.string, "Alpha 🙂 beta")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 3))
        }
    }

    @MainActor
    func testMouseSelectionDoesNotReanchorViewport() {
        let configuration = EditorConfiguration(isFocusModeEnabled: false)
        let coordinator = EditorCoordinator(configuration: configuration, onTextEdit: { _ in })
        let surface = EditorContainerView(textView: EditorTextView.makeTextKit2TextView())
        surface.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        coordinator.attach(to: surface)
        coordinator.update(text: String(repeating: "Alpha beta gamma\n", count: 50),
                           contentGeneration: BufferGeneration(bufferID: UUID(), revision: 0),
                           configuration: configuration, onTextEdit: { _ in })
        surface.layoutSubtreeIfNeeded()
        let before = surface.scrollView.contentView.bounds.origin
        surface.textView.setSelectedRange(NSRange(location: 40, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: surface.textView))
        XCTAssertEqual(surface.scrollView.contentView.bounds.origin, before)
    }

    @MainActor
    func testCoordinatorFollowsEveryCompletedNativeNewline() async throws {
        let config = EditorConfiguration(isFocusModeEnabled: false)
        let coordinator = EditorCoordinator(configuration: config, onTextEdit: { _ in })
        let view = EditorTextView.makeTextKit2TextView()
        let surface = EditorContainerView(textView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        coordinator.attach(to: surface)
        coordinator.update(text: "", contentGeneration: BufferGeneration(bufferID: UUID(), revision: 0),
                           configuration: config, onTextEdit: { _ in })
        surface.layoutSubtreeIfNeeded()
        for line in 0..<12 {
            view.insertText("A line\n", replacementRange: view.selectedRange())
            try await Task.sleep(for: .milliseconds(30))
            let screen = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
            let caret = view.convert(window.convertFromScreen(screen), from: nil)
            let clip = surface.scrollView.contentView
            XCTAssertEqual(caret.midY - clip.bounds.minY, clip.bounds.height * config.resolvedTypewriterAnchor,
                           accuracy: 2, "Completed native newline \(line)")
        }
    }

    @MainActor
    func testTypewriterReturnIsGradualAndManualScrollCancelsIt() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Reduced-motion desktop: animated return is intentionally disabled")
        }
        let view = EditorTextView.makeTextKit2TextView()
        let surface = EditorContainerView(textView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        let config = EditorConfiguration(isFocusModeEnabled: false)
        surface.apply(configuration: config)
        view.string = String(repeating: "A line\n", count: 60)
        view.applyBaseAttributes(for: config)
        surface.layoutSubtreeIfNeeded()
        view.setSelectedRange(NSRange(location: 200, length: 0))
        let scroller = TypewriterScroller()
        scroller.scrollCaretToAnchor(in: surface, configuration: config, animated: false)
        let target = surface.scrollView.contentView.bounds.minY
        let clip = surface.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: target - 150))
        scroller.suspendUntilNextEdit()
        scroller.resumeAfterEdit()
        scroller.scrollCaretToAnchor(in: surface, configuration: config, animated: false)
        XCTAssertEqual(clip.bounds.minY, target - 150, accuracy: 1)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(clip.bounds.minY, target - 150)
        XCTAssertLessThan(clip.bounds.minY, target - 20)
        scroller.suspendUntilNextEdit()
        let cancelledY = clip.bounds.minY
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(clip.bounds.minY, cancelledY, accuracy: 0.5)
    }
}
