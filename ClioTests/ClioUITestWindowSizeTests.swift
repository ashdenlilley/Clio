import XCTest
@testable import Clio

final class ClioUITestWindowSizeTests: XCTestCase {
    func testParsesAValidSize() {
        XCTAssertEqual(ClioUITestWindowSize.parse("480x400"), CGSize(width: 480, height: 400))
    }

    func testParsesFractionalDimensions() {
        XCTAssertEqual(ClioUITestWindowSize.parse("480.5x400.25"), CGSize(width: 480.5, height: 400.25))
    }

    func testRejectsMissingValue() {
        XCTAssertNil(ClioUITestWindowSize.parse(nil))
    }

    func testRejectsEmptyString() {
        XCTAssertNil(ClioUITestWindowSize.parse(""))
    }

    func testRejectsMissingSeparator() {
        XCTAssertNil(ClioUITestWindowSize.parse("480,400"))
    }

    func testRejectsNonNumericComponents() {
        XCTAssertNil(ClioUITestWindowSize.parse("abcxdef"))
    }

    func testRejectsZeroOrNegativeDimensions() {
        XCTAssertNil(ClioUITestWindowSize.parse("0x400"))
        XCTAssertNil(ClioUITestWindowSize.parse("480x0"))
        XCTAssertNil(ClioUITestWindowSize.parse("-480x400"))
    }

    func testRejectsExtraComponents() {
        XCTAssertNil(ClioUITestWindowSize.parse("480x400x100"))
    }

    func testRejectsMissingComponent() {
        XCTAssertNil(ClioUITestWindowSize.parse("480x"))
        XCTAssertNil(ClioUITestWindowSize.parse("x400"))
    }
}
