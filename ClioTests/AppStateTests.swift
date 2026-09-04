import XCTest
@testable import Clio

@MainActor
final class AppStateTests: XCTestCase {
    func testFreshStateUsesSpecificationDefaults() {
        let defaults = makeDefaults()
        let state = isolatedAppState(defaults: defaults)

        XCTAssertEqual(state.fontSize, 14)
        XCTAssertEqual(state.measure, 72)
        XCTAssertEqual(state.lineHeight, 1.65)
        XCTAssertEqual(state.typewriterAnchor, 0.45)
        XCTAssertTrue(state.isSpellCheckingEnabled)
        XCTAssertTrue(state.isTypewriterModeEnabled)
        XCTAssertTrue(state.isFocusModeEnabled)
        XCTAssertTrue(state.isChromeFadeEnabled)
        XCTAssertFalse(EditorSession().isFullScreenEnabled)
        XCTAssertEqual(state.accent, .green)
    }

    func testPreferencesRoundTripThroughDefaults() {
        let defaults = makeDefaults()
        let state = isolatedAppState(defaults: defaults)

        state.fontSize = 18
        state.measure = 84
        state.isFocusModeEnabled = false
        state.accent = .cyan

        let restored = isolatedAppState(defaults: defaults)
        XCTAssertEqual(restored.fontSize, 18)
        XCTAssertEqual(restored.measure, 84)
        XCTAssertFalse(restored.isFocusModeEnabled)
        XCTAssertEqual(restored.accent, .cyan)
    }

    func testWordCountTreatsRunsOfWhitespaceAsSeparators() {
        let session = EditorSession()

        session.draftText = "One  two\nthree\t四"

        XCTAssertEqual(session.wordCount, 4)
        XCTAssertEqual(session.wordCountLabel, "4 words")
    }

    func testEveryWindowRequestHasAUniqueIdentity() {
        XCTAssertNotEqual(
            EditorWindowRequest.newDocument(),
            EditorWindowRequest.newDocument()
        )
        XCTAssertNotEqual(
            EditorWindowRequest.mostRecent(),
            EditorWindowRequest.mostRecent()
        )
    }

    func testDockMenuExposesNativeDocumentAndWindowActions() throws {
        let delegate = ClioApplicationDelegate(
            appState: isolatedAppState(defaults: makeDefaults())
        )
        let menu = try XCTUnwrap(delegate.applicationDockMenu(.shared))

        XCTAssertEqual(menu.items.map(\.title), ["New Document", "New Window"])
        XCTAssertTrue(menu.items.allSatisfy { $0.target === delegate })
        XCTAssertTrue(menu.items.allSatisfy { $0.action != nil })
        XCTAssertTrue(
            delegate.applicationSupportsSecureRestorableState(.shared)
        )
    }

    func testFileMenuExposesNativeDocumentAndWindowActions() throws {
        let fileMenu = try XCTUnwrap(
            NSApplication.shared.mainMenu?.items
                .first(where: { $0.title == "File" })?
                .submenu
        )

        let newDocument = try XCTUnwrap(
            fileMenu.items.first(where: { $0.title == "New Document" })
        )
        let newWindow = try XCTUnwrap(
            fileMenu.items.first(where: { $0.title == "New Window" })
        )

        XCTAssertEqual(newDocument.keyEquivalent, "n")
        XCTAssertEqual(newDocument.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(newDocument.isEnabled)
        XCTAssertEqual(newWindow.keyEquivalent, "n")
        XCTAssertEqual(newWindow.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(newWindow.isEnabled)
    }

    func testWindowRequestPersistsItsMaterializedRelativePath() throws {
        var request = EditorWindowRequest.newDocument()
        request.relativePath = "drafts/untitled 2.md"
        request.isFullScreen = true

        let restored = try JSONDecoder().decode(
            EditorWindowRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(restored, request)
    }

    func testBundledHackFontIsAvailableToTheTestHost() {
        let font = Typography.font()

        XCTAssertEqual(font.familyName, Typography.family)
        XCTAssertTrue(font.fontName.hasPrefix("Hack"))
    }

    func testAppDeclaresMarkdownAndTextDocumentsForFinderOpen() throws {
        let documentTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
                as? [[String: Any]]
        )
        let extensions = Set(
            documentTypes.flatMap {
                $0["CFBundleTypeExtensions"] as? [String] ?? []
            }
        )

        XCTAssertTrue(extensions.isSuperset(of: ["md", "markdown", "txt"]))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ClioTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
