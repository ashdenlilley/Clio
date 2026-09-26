import Foundation
import XCTest
@testable import Clio

final class FocusDimmerTests: XCTestCase {
    func testParagraphFocusIncludesContiguousNonBlankLines() {
        let text = "first line\ncontinues\n\nsecond paragraph"
        let source = text as NSString
        let caret = source.range(of: "continues").location

        let range = FocusDimmer.focusRange(
            in: text,
            selection: NSRange(location: caret, length: 0)
        )

        XCTAssertEqual(range, source.range(of: "first line\ncontinues\n"))
    }

    func testSelectionAcrossParagraphsSuppressesFocusMode() {
        let text = "first\n\nsecond"
        let source = text as NSString

        let range = FocusDimmer.focusRange(
            in: text,
            selection: NSRange(location: 0, length: source.length)
        )

        XCTAssertNil(range)
    }

    func testCaretOnBlankLineSuppressesFocusMode() {
        let text = "\nfirst\n\nsecond\n"
        let source = text as NSString

        XCTAssertNil(FocusDimmer.focusRange(in: text, selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(FocusDimmer.focusRange(
            in: text,
            selection: NSRange(location: source.range(of: "first\n\n").upperBound - 1, length: 0)
        ))
        XCTAssertNil(FocusDimmer.focusRange(in: text, selection: NSRange(location: source.length, length: 0)))
    }

    func testBlankLineInsideFencedCodeBlockStaysInsideTheBlock() {
        let text = "```\nlet a = 1\n\nlet b = 2\n```\n"
        let source = text as NSString
        let caret = source.range(of: "\n\n").location + 1

        XCTAssertEqual(
            FocusDimmer.focusRange(in: text, selection: NSRange(location: caret, length: 0)),
            source.range(of: "```\nlet a = 1\n\nlet b = 2\n```\n")
        )
    }

    func testFencedCodeBlockIsOneFocusUnit() {
        let text = "before\n\n```swift\nlet value = 1\n```\n\nafter"
        let source = text as NSString
        let caret = source.range(of: "value").location

        let range = FocusDimmer.focusRange(
            in: text,
            selection: NSRange(location: caret, length: 0)
        )

        XCTAssertEqual(range, source.range(of: "```swift\nlet value = 1\n```\n"))
    }

    func testListRunIsOneFocusUnit() {
        let text = "- one\n  continuation\n- two\n\nafter"
        let source = text as NSString
        let caret = source.range(of: "two").location

        let range = FocusDimmer.focusRange(
            in: text,
            selection: NSRange(location: caret, length: 0)
        )

        XCTAssertEqual(range, source.range(of: "- one\n  continuation\n- two\n"))
    }

    func testLargeDocumentFocusDiscoveryIsBoundedNearCaret() {
        let prefix = String(repeating: "paragraph\n\n", count: 900_000)
        let text = prefix + "tail thought\ncontinues\n"
        let source = text as NSString
        let caret = source.range(of: "tail thought", options: .backwards).location
        let clock = ContinuousClock()
        let started = clock.now

        let range = FocusDimmer.focusRange(
            in: source,
            selection: NSRange(location: caret, length: 0)
        )

        XCTAssertEqual(range, source.range(of: "tail thought\ncontinues\n", options: .backwards))
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(500))
        XCTAssertLessThan(FocusDimmer.maximumSynchronousScanLength, source.length)
    }
}
