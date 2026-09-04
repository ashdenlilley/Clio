import Foundation

struct EditorViewportState: Codable, Hashable, Sendable {
    var selection: UTF16Range
    var topVisibleUTF16Offset: Int
    /// Fraction of the anchor line clipped above the viewport, in `0...1`.
    var fractionalYOffset: Double

    static let zero = Self(
        selection: UTF16Range(location: 0, length: 0),
        topVisibleUTF16Offset: 0,
        fractionalYOffset: 0
    )

    func clamped(toUTF16Length length: Int) -> Self {
        Self(
            selection: selection.clamped(toUTF16Length: length),
            topVisibleUTF16Offset: min(max(0, topVisibleUTF16Offset), max(0, length)),
            fractionalYOffset: min(max(0, fractionalYOffset), 1)
        )
    }
}

struct EditorTabRestorationState: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let documentID: DocumentID
    let locator: DocumentLocator?
    var preferredFilename: String
    var viewport: EditorViewportState
}

struct EditorWindowRestorationState: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var tabs: [EditorTabRestorationState]
    var activeTabID: UUID?
    var isSidebarVisible: Bool
    var isSidebarPinned: Bool
    var isFullScreen: Bool

    mutating func normalize() {
        guard !tabs.isEmpty else {
            activeTabID = nil
            return
        }
        guard let activeTabID,
              tabs.contains(where: { $0.id == activeTabID }) else {
            self.activeTabID = tabs[0].id
            return
        }
    }
}

protocol SessionRestorationPersisting: Sendable {
    func load() async throws -> [EditorWindowRestorationState]
    func save(_ states: [EditorWindowRestorationState]) async throws
}

enum ClioCommandID: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case new
    case open
    case search
    case rename
    case delete
    case reveal
    case folder
    case export
    case focus
    case typewriter
    case sidebar
    case settings

    var id: Self { self }
    var slashName: String { "/\(rawValue)" }
}

struct ClioCommandInvocation: Codable, Hashable, Sendable {
    let command: ClioCommandID
    let arguments: [String]
}

enum ClioCommandSource: String, Codable, CaseIterable, Hashable, Sendable {
    case menu
    case dock
    case palette
    case inlineSlash
    case keyboardShortcut
}

struct ClioCommandContext: Codable, Hashable, Sendable {
    let windowID: UUID?
    let tabID: UUID?
    let source: ClioCommandSource
}

@MainActor
protocol ClioCommandDispatching: AnyObject {
    func perform(
        _ invocation: ClioCommandInvocation,
        context: ClioCommandContext
    ) async
}
