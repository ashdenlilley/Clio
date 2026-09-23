import AppKit
import Foundation
import Observation

/// The writer's presentation preferences and their persistence.
///
/// Split out of `AppState`, which owns workspaces, recovery, export and
/// navigation and had no reason to also own eleven sliders. Nothing here
/// touches the filesystem or a document: it reads and writes `UserDefaults`
/// and nothing else, so it can be exercised on its own.
///
/// Every value is clamped on the way in as well as on the way out. Loading
/// alone used to be clamped, which left a preference written by an older build,
/// a defaults import or a `defaults write` free to drive the editor out of
/// range until the next launch.
///
/// Each `didSet` is written out longhand rather than shared through a helper.
/// A helper taking the property as `inout` looks tidier and is a trap: under
/// `@Observable` the property is a computed pair, so an `inout` argument goes
/// through the `modify` accessor and writes back on *every* return, whether or
/// not the helper assigned anything. That write-back re-enters `didSet`, and
/// the recursion is unconditional and infinite - it overflows the stack on the
/// first assignment a writer makes, in range or not. Assigning the property
/// directly re-enters `didSet` only when a clamp actually changed the value,
/// and the second pass finds it already in range and stops.
enum CaretStyle: String, CaseIterable, Identifiable, Sendable {
    case block, line
    var id: Self { self }
    var title: String { self == .block ? "Block" : "Line" }
}

@MainActor
@Observable
final class EditorPreferences {
    enum AccentPreset: String, CaseIterable, Identifiable, Sendable {
        case clio
        case system
        case blue, purple, pink, red, orange, yellow, graphite
        case green
        case amber
        case cyan

        var id: Self { self }

        var title: String {
            rawValue.capitalized
        }

        var nsColor: NSColor {
            switch self {
            case .clio: Palette.accent
            case .system: .controlAccentColor
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .pink: .systemPink
            case .red: .systemRed
            case .orange: .systemOrange
            case .amber: NSColor(srgbRed: 1.0, green: 0.69, blue: 0.0, alpha: 1)
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .graphite: .systemGray
            case .cyan: .systemCyan
            }
        }
    }

    /// The supported range for each numeric preference. Settings controls read
    /// these rather than repeating the bounds, so a slider cannot disagree with
    /// what the value will accept.
    enum Limits {
        static let fontSize: ClosedRange<Double> = 12...20
        static let measure: ClosedRange<Int> = 60...90
        static let lineHeight: ClosedRange<Double> = 1.2...2.0
        static let typewriterAnchor: ClosedRange<Double> = 0.3...0.6
        static let focusDimmingOpacity: ClosedRange<Double> = 0.1...0.6
    }

    enum Defaults {
        static let editorFontName = "Hack-Regular"
        static let fontSize: Double = 14
        static let measure = 72
        static let lineHeight = 1.65
        static let typewriterAnchor = 0.45
        static let focusDimmingOpacity = 0.28
    }

    enum Keys {
        static let editorFontName = "editor.fontName"
        static let fontSize = "editor.fontSize"
        static let measure = "editor.measure"
        static let lineHeight = "editor.lineHeight"
        static let typewriterAnchor = "editor.typewriterAnchor"
        static let focusDimmingOpacity = "editor.focusDimmingOpacity"
        static let spellChecking = "editor.spellChecking"
        static let accent = "appearance.accent"
        static let typewriterMode = "mode.typewriter"
        static let focusMode = "mode.focus"
        static let chromeFade = "mode.chromeFade"
        static let caretStyle = "editor.caretStyle"
        static let showsMinimap = "editor.showsMinimap"
        static let showsStatusLine = "status.visible"
        static let showsReadingTime = "status.readingTime"
        static let showsSpeakingTime = "status.speakingTime"
        static let hidesPointer = "mode.hidesPointer"
        static let grammarChecking = "editor.grammarChecking"
        static let smartPunctuation = "editor.smartPunctuation"
        static let slashCommands = "editor.slashCommands"
        static let autoWrapSelection = "editor.autoWrapSelection"
    }

    var editorFontName: String {
        didSet {
            guard editorFontName != oldValue else { return }
            if editorFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editorFontName = Defaults.editorFontName
                return
            }
            defaults.set(editorFontName, forKey: Keys.editorFontName)
        }
    }

    var fontSize: Double {
        didSet {
            let clamped = Self.clamp(fontSize, to: Limits.fontSize)
            if fontSize != clamped { fontSize = clamped; return }
            guard fontSize != oldValue else { return }
            defaults.set(fontSize, forKey: Keys.fontSize)
        }
    }

    var measure: Int {
        didSet {
            let clamped = Self.clamp(measure, to: Limits.measure)
            if measure != clamped { measure = clamped; return }
            guard measure != oldValue else { return }
            defaults.set(measure, forKey: Keys.measure)
        }
    }

    var lineHeight: Double {
        didSet {
            let clamped = Self.clamp(lineHeight, to: Limits.lineHeight)
            if lineHeight != clamped { lineHeight = clamped; return }
            guard lineHeight != oldValue else { return }
            defaults.set(lineHeight, forKey: Keys.lineHeight)
        }
    }

    var typewriterAnchor: Double {
        didSet {
            let clamped = Self.clamp(typewriterAnchor, to: Limits.typewriterAnchor)
            if typewriterAnchor != clamped { typewriterAnchor = clamped; return }
            guard typewriterAnchor != oldValue else { return }
            defaults.set(typewriterAnchor, forKey: Keys.typewriterAnchor)
        }
    }

    var focusDimmingOpacity: Double {
        didSet {
            let clamped = Self.clamp(focusDimmingOpacity, to: Limits.focusDimmingOpacity)
            if focusDimmingOpacity != clamped { focusDimmingOpacity = clamped; return }
            guard focusDimmingOpacity != oldValue else { return }
            defaults.set(focusDimmingOpacity, forKey: Keys.focusDimmingOpacity)
        }
    }

    var isSpellCheckingEnabled: Bool {
        didSet { defaults.set(isSpellCheckingEnabled, forKey: Keys.spellChecking) }
    }

    var accent: AccentPreset {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    var isTypewriterModeEnabled: Bool {
        didSet { defaults.set(isTypewriterModeEnabled, forKey: Keys.typewriterMode) }
    }

    var isFocusModeEnabled: Bool {
        didSet { defaults.set(isFocusModeEnabled, forKey: Keys.focusMode) }
    }

    var isChromeFadeEnabled: Bool {
        didSet { defaults.set(isChromeFadeEnabled, forKey: Keys.chromeFade) }
    }

    var caretStyle: CaretStyle {
        didSet { defaults.set(caretStyle.rawValue, forKey: Keys.caretStyle) }
    }

    var showsMinimap: Bool {
        didSet { defaults.set(showsMinimap, forKey: Keys.showsMinimap) }
    }

    var showsStatusLine: Bool {
        didSet { defaults.set(showsStatusLine, forKey: Keys.showsStatusLine) }
    }

    var showsReadingTime: Bool {
        didSet { defaults.set(showsReadingTime, forKey: Keys.showsReadingTime) }
    }

    var showsSpeakingTime: Bool {
        didSet { defaults.set(showsSpeakingTime, forKey: Keys.showsSpeakingTime) }
    }

    var hidesPointerWhileTyping: Bool {
        didSet { defaults.set(hidesPointerWhileTyping, forKey: Keys.hidesPointer) }
    }

    var isGrammarCheckingEnabled: Bool {
        didSet { defaults.set(isGrammarCheckingEnabled, forKey: Keys.grammarChecking) }
    }

    var isSmartPunctuationEnabled: Bool {
        didSet { defaults.set(isSmartPunctuationEnabled, forKey: Keys.smartPunctuation) }
    }

    var isSlashCommandEnabled: Bool {
        didSet { defaults.set(isSlashCommandEnabled, forKey: Keys.slashCommands) }
    }

    var autoWrapsSelection: Bool {
        didSet { defaults.set(autoWrapsSelection, forKey: Keys.autoWrapSelection) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        editorFontName = Self.string(
            forKey: Keys.editorFontName,
            default: Defaults.editorFontName,
            in: defaults
        )
        fontSize = Self.clamp(
            Self.double(forKey: Keys.fontSize, default: Defaults.fontSize, in: defaults),
            to: Limits.fontSize
        )
        measure = Self.clamp(
            Self.integer(forKey: Keys.measure, default: Defaults.measure, in: defaults),
            to: Limits.measure
        )
        lineHeight = Self.clamp(
            Self.double(forKey: Keys.lineHeight, default: Defaults.lineHeight, in: defaults),
            to: Limits.lineHeight
        )
        typewriterAnchor = Self.clamp(
            Self.double(forKey: Keys.typewriterAnchor, default: Defaults.typewriterAnchor, in: defaults),
            to: Limits.typewriterAnchor
        )
        focusDimmingOpacity = Self.clamp(
            Self.double(
                forKey: Keys.focusDimmingOpacity,
                default: Defaults.focusDimmingOpacity,
                in: defaults
            ),
            to: Limits.focusDimmingOpacity
        )
        isSpellCheckingEnabled = Self.bool(forKey: Keys.spellChecking, default: true, in: defaults)
        isTypewriterModeEnabled = Self.bool(forKey: Keys.typewriterMode, default: true, in: defaults)
        isFocusModeEnabled = Self.bool(forKey: Keys.focusMode, default: true, in: defaults)
        isChromeFadeEnabled = Self.bool(forKey: Keys.chromeFade, default: true, in: defaults)
        accent = defaults.string(forKey: Keys.accent)
            .flatMap(AccentPreset.init(rawValue:)) ?? .clio
        caretStyle = defaults.string(forKey: Keys.caretStyle)
            .flatMap(CaretStyle.init(rawValue:)) ?? .block
        showsMinimap = Self.bool(forKey: Keys.showsMinimap, default: true, in: defaults)
        showsStatusLine = Self.bool(forKey: Keys.showsStatusLine, default: true, in: defaults)
        showsReadingTime = Self.bool(forKey: Keys.showsReadingTime, default: true, in: defaults)
        showsSpeakingTime = Self.bool(forKey: Keys.showsSpeakingTime, default: true, in: defaults)
        hidesPointerWhileTyping = Self.bool(forKey: Keys.hidesPointer, default: true, in: defaults)
        isGrammarCheckingEnabled = Self.bool(forKey: Keys.grammarChecking, default: false, in: defaults)
        isSmartPunctuationEnabled = Self.bool(forKey: Keys.smartPunctuation, default: false, in: defaults)
        isSlashCommandEnabled = Self.bool(forKey: Keys.slashCommands, default: true, in: defaults)
        autoWrapsSelection = Self.bool(forKey: Keys.autoWrapSelection, default: true, in: defaults)
    }

    func adjustFontSize(by amount: Double) {
        fontSize += amount
    }

    func resetFontSize() {
        fontSize = Defaults.fontSize
    }

    static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func string(
        forKey key: String,
        default defaultValue: String,
        in defaults: UserDefaults
    ) -> String {
        guard let stored = defaults.string(forKey: key),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultValue
        }
        return stored
    }

    private static func double(
        forKey key: String,
        default defaultValue: Double,
        in defaults: UserDefaults
    ) -> Double {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.double(forKey: key)
    }

    private static func integer(
        forKey key: String,
        default defaultValue: Int,
        in defaults: UserDefaults
    ) -> Int {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.integer(forKey: key)
    }

    private static func bool(
        forKey key: String,
        default defaultValue: Bool,
        in defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}
