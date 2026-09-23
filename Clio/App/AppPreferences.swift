import Foundation
import Observation

enum LaunchBehavior: String, CaseIterable, Identifiable, Sendable {
    case mostRecent, newDocument
    var id: Self { self }
    var title: String { self == .mostRecent ? "Most recent document" : "A new document" }
}

/// Window, launch and export defaults. Kept apart from `EditorPreferences`,
/// which is about how text is presented; nothing here affects a document.
@MainActor
@Observable
final class AppPreferences {
    enum Keys {
        static let launchBehavior = "app.launchBehavior"
        static let showsSidebarInNewWindows = "window.sidebarVisibleByDefault"
        static let pinsSidebarInNewWindows = "window.sidebarPinnedByDefault"
        static let defaultExportFormat = "export.defaultFormat"
        static let lastSettingsCategory = "settings.lastCategory"
    }

    var launchBehavior: LaunchBehavior {
        didSet { defaults.set(launchBehavior.rawValue, forKey: Keys.launchBehavior) }
    }

    var showsSidebarInNewWindows: Bool {
        didSet { defaults.set(showsSidebarInNewWindows, forKey: Keys.showsSidebarInNewWindows) }
    }

    var pinsSidebarInNewWindows: Bool {
        didSet { defaults.set(pinsSidebarInNewWindows, forKey: Keys.pinsSidebarInNewWindows) }
    }

    var defaultExportFormat: ExportFormat {
        didSet { defaults.set(defaultExportFormat.rawValue, forKey: Keys.defaultExportFormat) }
    }

    var lastSettingsCategory: SettingsCategory {
        didSet { defaults.set(lastSettingsCategory.rawValue, forKey: Keys.lastSettingsCategory) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        launchBehavior = defaults.string(forKey: Keys.launchBehavior)
            .flatMap(LaunchBehavior.init(rawValue:)) ?? .mostRecent
        showsSidebarInNewWindows = defaults.object(forKey: Keys.showsSidebarInNewWindows) == nil
            ? true : defaults.bool(forKey: Keys.showsSidebarInNewWindows)
        pinsSidebarInNewWindows = defaults.bool(forKey: Keys.pinsSidebarInNewWindows)
        defaultExportFormat = defaults.string(forKey: Keys.defaultExportFormat)
            .flatMap(ExportFormat.init(rawValue:)) ?? .pdf
        lastSettingsCategory = defaults.string(forKey: Keys.lastSettingsCategory)
            .flatMap(SettingsCategory.init(rawValue:)) ?? .general
    }

    func initialWindowRequest() -> EditorWindowRequest {
        launchBehavior == .newDocument ? .newDocument() : .mostRecent()
    }
}
