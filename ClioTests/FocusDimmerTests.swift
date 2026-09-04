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
}
