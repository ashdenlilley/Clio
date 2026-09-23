import XCTest
@testable import Clio

@MainActor
final class AppPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ClioTests.appPreferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsMatchCurrentBehaviour() {
        let p = AppPreferences(defaults: defaults)
        XCTAssertEqual(p.launchBehavior, .mostRecent)
        XCTAssertTrue(p.showsSidebarInNewWindows)
        XCTAssertFalse(p.pinsSidebarInNewWindows)
        XCTAssertEqual(p.defaultExportFormat, .pdf)
        XCTAssertEqual(p.lastSettingsCategory, .general)
        XCTAssertEqual(p.initialWindowRequest().openingMode, .mostRecent)
    }

    func testRoundTrip() {
        let p = AppPreferences(defaults: defaults)
        p.launchBehavior = .newDocument
        p.showsSidebarInNewWindows = false
        p.pinsSidebarInNewWindows = true
        p.defaultExportFormat = .docx
        p.lastSettingsCategory = .localMCP
        let r = AppPreferences(defaults: defaults)
        XCTAssertEqual(r.launchBehavior, .newDocument)
        XCTAssertFalse(r.showsSidebarInNewWindows)
        XCTAssertTrue(r.pinsSidebarInNewWindows)
        XCTAssertEqual(r.defaultExportFormat, .docx)
        XCTAssertEqual(r.lastSettingsCategory, .localMCP)
        XCTAssertEqual(r.initialWindowRequest().openingMode, .newDocument)
    }

    func testUnknownRawValuesFallBackToDefaults() {
        defaults.set("restoreEverything", forKey: AppPreferences.Keys.launchBehavior)
        defaults.set("rtf", forKey: AppPreferences.Keys.defaultExportFormat)
        defaults.set("appearance", forKey: AppPreferences.Keys.lastSettingsCategory)
        let p = AppPreferences(defaults: defaults)
        XCTAssertEqual(p.launchBehavior, .mostRecent)
        XCTAssertEqual(p.defaultExportFormat, .pdf)
        XCTAssertEqual(p.lastSettingsCategory, .general)
    }

    func testNewWindowsUseSidebarDefaultsWithoutRestoration() {
        let session = EditorWindowSession(request: .newDocument(), sidebarVisibleByDefault: false, sidebarPinnedByDefault: true)
        XCTAssertFalse(session.isSidebarVisible)
        XCTAssertTrue(session.isSidebarPinned)
    }

    func testRestoredWindowsIgnoreSidebarDefaults() {
        var request = EditorWindowRequest.newDocument()
        request.restoration = EditorWindowRestorationState(id: request.id, tabs: [], activeTabID: nil, isSidebarVisible: true, isSidebarPinned: false, isFullScreen: false)
        let session = EditorWindowSession(request: request, sidebarVisibleByDefault: false, sidebarPinnedByDefault: true)
        XCTAssertTrue(session.isSidebarVisible)
        XCTAssertFalse(session.isSidebarPinned)
    }
}
