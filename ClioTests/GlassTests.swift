import SwiftUI
import XCTest
@testable import Clio

final class GlassTests: XCTestCase {
    func testUnselectedGlassIsPlainRegular() {
        XCTAssertEqual(ClioGlass.glass(selected: false, accent: .red, interactive: false), .regular)
    }

    func testSelectedGlassIsAccentTinted() {
        XCTAssertEqual(
            ClioGlass.glass(selected: true, accent: .red, interactive: false),
            .regular.tint(Color.red.opacity(ClioGlass.selectedTintOpacity))
        )
    }

    func testInteractiveFlagIsApplied() {
        XCTAssertEqual(ClioGlass.glass(selected: false, accent: .red, interactive: true), .regular.interactive())
    }

    func testShapeRadii() {
        XCTAssertEqual(GlassShape.panel.cornerRadius, 16)
        XCTAssertEqual(GlassShape.card.cornerRadius, 12)
        XCTAssertEqual(GlassShape.row.cornerRadius, 8)
        XCTAssertNil(GlassShape.capsule.cornerRadius)
    }
}
