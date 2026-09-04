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

/// The bounded edit description emitted by AppKit before an editor mutation.
/// `replacedRange` is expressed in the pre-edit string's UTF-16 coordinates.
struct EditorTextEdit: Codable, Hashable, Sendable {
    let replacedRange: UTF16Range
    let replacement: String
}

struct EditorTabRestorationState: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let documentID: DocumentID
    let locator: DocumentLocator?
    var preferredFilename: String
    var viewport: EditorViewportState
    /// Exact-file Powerbox access for documents whose parent was not added as
    /// a workspace. Optional fields preserve decoding of older saved state.
    var externalFileBookmark: Data? = nil
    var externalFileURL: URL? = nil
}

struct EditorWindowRestorationState: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var tabs: [EditorTabRestorationState]
    var activeTabID: UUID?
    var isSidebarVisible: Bool
    var isSidebarPinned: Bool
    var isFullScreen: Bool

    mutating func normalize() {
        struct RestorationIntent: Hashable {
            let documentID: DocumentID
            let locator: DocumentLocator?
            let externalFileURL: URL?
        }

        var retainedByIntent: [RestorationIntent: UUID] = [:]
        var normalizedTabs: [EditorTabRestorationState] = []
        normalizedTabs.reserveCapacity(tabs.count)
        for tab in tabs {
            let intent = RestorationIntent(
                documentID: tab.documentID,
                locator: tab.locator,
                externalFileURL: tab.externalFileURL?.standardizedFileURL
            )
            if let retainedID = retainedByIntent[intent] {
                if activeTabID == tab.id { activeTabID = retainedID }
                continue
            }
            retainedByIntent[intent] = tab.id
            normalizedTabs.append(tab)
        }
        tabs = normalizedTabs

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

enum ClioCommandParseError: LocalizedError, Equatable {
    case missingSlash
    case missingCommand
    case unknownCommand(String)
    case unterminatedQuote
    case danglingEscape
    case invalidExportFormat(String)
    case tooManyExportArguments

    var errorDescription: String? {
        switch self {
        case .missingSlash:
            return "Commands begin with /."
        case .missingCommand:
            return "Type a command after /."
        case let .unknownCommand(command):
            return "Unknown command: /\(command)"
        case .unterminatedQuote:
            return "Close the quoted argument before running this command."
        case .danglingEscape:
            return "An argument cannot end with an escape character."
        case let .invalidExportFormat(format):
            return "Unsupported export format “\(format)”. Use pdf or html."
        case .tooManyExportArguments:
            return "Export accepts one format: pdf or html."
        }
    }
}

enum ClioCommandParser {
    /// Returns the first, possibly partial command token for palette filtering.
    /// Argument text is deliberately excluded so `/export pdf` keeps Export selected.
    static func commandToken(in source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutSlash = trimmed.first == "/" ? trimmed.dropFirst() : trimmed[...]
        return String(withoutSlash.prefix { !$0.isWhitespace })
    }

    static func parse(_ source: String) throws -> ClioCommandInvocation {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { throw ClioCommandParseError.missingSlash }
        let tokens = try tokenize(String(trimmed.dropFirst()))
        guard let commandName = tokens.first, !commandName.isEmpty else {
            throw ClioCommandParseError.missingCommand
        }
        guard let command = ClioCommandID(rawValue: commandName.lowercased()) else {
            throw ClioCommandParseError.unknownCommand(commandName)
        }

        let arguments = Array(tokens.dropFirst())
        if command == .export {
            guard arguments.count <= 1 else {
                throw ClioCommandParseError.tooManyExportArguments
            }
            if let format = arguments.first,
               !["pdf", "html"].contains(format.lowercased()) {
                throw ClioCommandParseError.invalidExportFormat(format)
            }
        }
        return ClioCommandInvocation(command: command, arguments: arguments)
    }

    private static func tokenize(_ source: String) throws -> [String] {
        enum Quote { case single, double }

        var tokens: [String] = []
        var token = ""
        var quote: Quote?
        var isEscaping = false
        var hasToken = false

        for character in source {
            if isEscaping {
                token.append(character)
                hasToken = true
                isEscaping = false
                continue
            }
            if character == "\\", quote != .single {
                isEscaping = true
                hasToken = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"):
                quote = nil
            case (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
                hasToken = true
            case (nil, "\""):
                quote = .double
                hasToken = true
            case (nil, _) where character.isWhitespace:
                if hasToken {
                    tokens.append(token)
                    token = ""
                    hasToken = false
                }
            default:
                token.append(character)
                hasToken = true
            }
        }
        guard !isEscaping else { throw ClioCommandParseError.danglingEscape }
        guard quote == nil else { throw ClioCommandParseError.unterminatedQuote }
        if hasToken { tokens.append(token) }
        return tokens
    }
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
