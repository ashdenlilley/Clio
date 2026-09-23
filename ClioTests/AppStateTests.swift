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
        XCTAssertEqual(state.accent, .clio)
    }

    func testSettingsRequestIsConsumedByExactlyOneWindow() {
        let state = isolatedAppState()
        state.requestSettings(.localMCP)
        let first = UUID(), second = UUID()
        XCTAssertNil(state.consumeSettingsRequest(for: second, isKeyOrOnlyWindow: false))
        XCTAssertEqual(state.consumeSettingsRequest(for: first, isKeyOrOnlyWindow: true), .localMCP)
        XCTAssertNil(state.consumeSettingsRequest(for: second, isKeyOrOnlyWindow: true))
        XCTAssertEqual(state.appPreferences.lastSettingsCategory, .localMCP)
    }

    func testClioAccentUsesRequestedSRGBComponents() throws {
        let color = try XCTUnwrap(Palette.accent.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 57.0 / 255, accuracy: 0.000001)
        XCTAssertEqual(color.greenComponent, 138.0 / 255, accuracy: 0.000001)
        XCTAssertEqual(color.blueComponent, 176.0 / 255, accuracy: 0.000001)
        XCTAssertEqual(color.alphaComponent, 1)
        XCTAssertEqual(Palette.caret, Palette.accent)
    }

    func testPreferencesRoundTripThroughDefaults() {
        let defaults = makeDefaults()
        let state = isolatedAppState(defaults: defaults)

        state.fontSize = 18
        state.editorFontName = "Helvetica"
        state.measure = 84
        state.isFocusModeEnabled = false
        state.accent = .cyan

        let restored = isolatedAppState(defaults: defaults)
        XCTAssertEqual(restored.fontSize, 18)
        XCTAssertEqual(restored.editorFontName, "Helvetica")
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
        // Release metadata uses UTI-based Finder registration, not the legacy
        // CFBundleTypeExtensions key. Verify the handlers and imported Markdown
        // tags together; public.plain-text is the system type for .txt files.
        let editorTypes = Set(documentTypes.filter {
            $0["CFBundleTypeRole"] as? String == "Editor"
        }.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        XCTAssertTrue(editorTypes.isSuperset(of: [
            "net.daringfireball.markdown", "public.plain-text"
        ]))
        let importedTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations")
                as? [[String: Any]]
        )
        let markdown = try XCTUnwrap(importedTypes.first {
            $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown"
        })
        let conformsTo = try XCTUnwrap(markdown["UTTypeConformsTo"] as? [String])
        XCTAssertTrue(conformsTo.contains("public.plain-text"))
        let tags = try XCTUnwrap(markdown["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try XCTUnwrap(tags["public.filename-extension"] as? [String])
        XCTAssertTrue(Set(extensions).isSuperset(of: ["md", "markdown"]))
        XCTAssertEqual(tags["public.mime-type"] as? String, "text/markdown")
    }

    func testCancellingRecoveryFolderChangeLeavesStateUntouched() {
        let state = isolatedAppState(defaults: makeDefaults(), folderPanelRunner: { _ in nil })
        state.changeRecoveryFolder()
        XCTAssertFalse(state.needsRecoveryAuthorization)
        XCTAssertNil(state.workspaceErrorMessage)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ClioTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
