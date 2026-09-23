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

    func testOnlyTheDesignLayerCallsGlassEffect() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Clio")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "source guard found no Swift files under \(root.path)")
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "Glass.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".glassEffect(") || text.contains("GlassEffectContainer(") || text.contains(".regularMaterial") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testChromeNoLongerUsesRaisedFill() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Clio/App")
        for name in ["WorkspaceSidebar.swift", "CommandPaletteView.swift", "ContentView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("Palette.backgroundRaised"), name)
        }
    }
}
