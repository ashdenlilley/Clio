# Liquid Glass UI and Settings Respec Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert all Clio chrome to macOS 26/27 Liquid Glass over the unchanged black writing surface, rebuild Settings as a categorised glass panel exposing every shipped feature, and verify with automated and visual UI passes.

**Architecture:** One design module (`Clio/Design/Glass.swift`) owns every `glassEffect` call; surfaces adopt it instead of `Palette.backgroundRaised`. New preferences follow the existing `EditorPreferences` clamp-and-persist pattern, with window/launch/export keys in a sibling `AppPreferences`. Settings is split into `Clio/App/Settings/` with one file per category page; the separate MCP `NSWindow` is retired and routed to the Local MCP page.

**Tech Stack:** Swift 5.9 language mode, SwiftUI + AppKit, macOS 27 SDK (Xcode at `/Applications/Xcode.app`), XcodeGen 2.46.0, XCTest / XCUITest.

**Spec:** `docs/superpowers/specs/2026-09-23-liquid-glass-settings-design.md`

## Global Constraints

- Deployment target **macOS 26.0** everywhere in `project.yml`; no `#available` fallback path for pre-glass systems.
- `Palette.background` stays `#000000`; the editor text view, scroll view, window background, minimap strokes and block caret stay solid/unchanged.
- Glass variant is `.regular`; accent tint only on selected/active/primary elements.
- Only `Clio/Design/Glass.swift` calls `.glassEffect(` / `GlassEffectContainer(` (buttons may use `.buttonStyle(.glass)` / `.glassProminent` anywhere).
- No glass on glass except inside a `ClioGlassGroup`.
- Every new preference's default equals current behaviour.
- Preserve existing accessibility identifiers (`settings.editorFont`, `settings.intelligence.*`, `sidebar*`, `palette.*`, `editor.*`); new ones use `settings.<page>.<control>` and `settings.category.<rawValue>`.
- `SWIFT_VERSION` stays `5.9`.
- All build/test commands run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select points at CommandLineTools; do not change it).
- `xcodegen generate` must be re-run and `Clio.xcodeproj` committed whenever files are added/removed (scripts/test.sh fails on a dirty generated project).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

### Standard commands (referenced by tasks)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# UNIT(<filter>): run unit tests, optionally filtered
xcodebuild -project Clio.xcodeproj -scheme Clio -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData/UnitTests -only-testing:ClioTests/<filter> CODE_SIGNING_ALLOWED=NO test 2>&1 \
  | grep -E "Executed|error:|failed|passed" | tail -20
# UI(<filter>): run UI tests (needs unlocked desktop)
xcodebuild -project Clio.xcodeproj -scheme Clio -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData/UITests -only-testing:ClioUITests/<filter> \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test 2>&1 | grep -E "Executed|error:|failed|passed" | tail -20
# BUILD: compile app only
xcodebuild -project Clio.xcodeproj -scheme Clio -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData/UnitTests CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|warning: .*glass|BUILD" | tail -20
```

Always read the `Executed N tests` line: a crashed host reports 0 failures with a low N.

## Review Focus

1. **Unknown / stale raw values in defaults** (e.g. `editor.caretStyle = "bar"`, `export.defaultFormat = "rtf"`, `settings.lastCategory = "appearance"`) must fall back to the default, never crash — tests in Task 2.
2. **Settings at the minimum window size (480×400)** must remain usable: the category list collapses to icon-only below 600pt available width — UI test in Task 8, visual check in Task 9.
3. **"MCP Settings…" from the menu bar with zero or several windows open** must open exactly one window's Settings on the Local MCP page — unit test on request consumption in Task 6.
4. **Slash commands turned off**: typing `/` must insert a literal slash and never open the palette — test in Task 4.
5. **Cancelling "Change…" for the recovery folder in Settings** must leave state untouched and raise no error banner (the existing banner flow sets `needsRecoveryAuthorization` on cancel) — test in Task 5.

---

### Task 1: Raise the platform to macOS 26 and record a baseline

**Files:**
- Modify: `project.yml:7,19,38,142,166` (all `14.0` → `26.0`), remove lines 83-84 (`EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx15*]` / `[sdk=macosx14*]`)
- Modify: `README.md:28,55`
- Regenerate: `Clio.xcodeproj`

**Interfaces:** Produces: a project that builds against the macOS 27 SDK with deployment target 26.0.

- [ ] **Step 1: Record the baseline before changing anything**

Run UNIT with no filter (drop `/<filter>`: `-only-testing:ClioTests`). Save the `Executed N tests, with M failures` line into the scratchpad as `baseline-unit.txt`. Run UI with `-only-testing:ClioUITests`; save as `baseline-ui.txt`. Expected: the two known failures `testFullscreenMouseSelectionContextMenuAndReturnToWindow`, `testSidebarNewDocumentCancellationDoesNotAddATab` may appear; note any others.

- [ ] **Step 2: Edit project.yml**

```bash
sed -i '' 's/macOS: "14.0"/macOS: "26.0"/; s/MACOSX_DEPLOYMENT_TARGET: "14.0"/MACOSX_DEPLOYMENT_TARGET: "26.0"/; s/deploymentTarget: "14.0"/deploymentTarget: "26.0"/g' project.yml
sed -i '' '/EXCLUDED_SOURCE_FILE_NAMES\[sdk=macosx1[45]\*\]/d' project.yml
grep -n '14\.0\|26\.0\|EXCLUDED' project.yml
```
Expected: five `26.0` lines, zero `14.0`, zero `EXCLUDED`.

- [ ] **Step 3: Update README**

Line 28: "…running macOS 14" → "…running macOS 26 or later". Line 55: "the deployment target is macOS 14" → "the deployment target is macOS 26 (Liquid Glass)".

- [ ] **Step 4: Regenerate and build**

```bash
xcodegen generate && git status --short Clio.xcodeproj
```
Run BUILD. Expected: `BUILD SUCCEEDED`. Fix any new deprecation *errors* only (warnings are fine).

- [ ] **Step 5: Re-run unit tests**

Run UNIT (all). Expected: same executed count and failures as baseline.

- [ ] **Step 6: Commit**

```bash
git add project.yml README.md Clio.xcodeproj
git commit -m "build: raise deployment target to macOS 26 for Liquid Glass"
```

---

### Task 2: Preferences — new editor keys, `AppPreferences`, amber fix

**Files:**
- Modify: `Clio/App/EditorPreferences.swift`
- Create: `Clio/App/AppPreferences.swift`
- Create: `Clio/App/Settings/SettingsCategory.swift`
- Modify: `Clio/App/AppState.swift:26-75,243` (add `appPreferences`, forwarders not required — views read `appState.preferences` / `appState.appPreferences` directly)
- Test: `ClioTests/EditorPreferencesTests.swift`, Create: `ClioTests/AppPreferencesTests.swift`

**Interfaces:**
- Produces:
  - `enum CaretStyle: String, CaseIterable, Identifiable, Sendable { case block, line }`
  - `EditorPreferences` new vars: `caretStyle: CaretStyle` (`.block`), `showsMinimap: Bool` (true), `showsStatusLine: Bool` (true), `showsReadingTime: Bool` (true), `showsSpeakingTime: Bool` (true), `hidesPointerWhileTyping: Bool` (true), `isGrammarCheckingEnabled: Bool` (false), `isSmartPunctuationEnabled: Bool` (false), `isSlashCommandEnabled: Bool` (true), `autoWrapsSelection: Bool` (true)
  - `enum LaunchBehavior: String, CaseIterable, Identifiable, Sendable { case mostRecent, newDocument }`
  - `@MainActor @Observable final class AppPreferences { init(defaults:); var launchBehavior; var showsSidebarInNewWindows: Bool; var pinsSidebarInNewWindows: Bool; var defaultExportFormat: ExportFormat; var lastSettingsCategory: SettingsCategory; func initialWindowRequest() -> EditorWindowRequest }`
  - `enum SettingsCategory: String, CaseIterable, Identifiable, Sendable { case general, editor, writing, workspaces, export, assisted, localMCP; var title: String; var symbol: String }`
  - `AppState.appPreferences: AppPreferences`

- [ ] **Step 1: Write failing tests** — append to `EditorPreferencesTests`:

```swift
    func testNewEditorPreferencesDefaultToCurrentBehaviour() {
        let p = EditorPreferences(defaults: defaults)
        XCTAssertEqual(p.caretStyle, .block)
        XCTAssertTrue(p.showsMinimap)
        XCTAssertTrue(p.showsStatusLine)
        XCTAssertTrue(p.showsReadingTime)
        XCTAssertTrue(p.showsSpeakingTime)
        XCTAssertTrue(p.hidesPointerWhileTyping)
        XCTAssertFalse(p.isGrammarCheckingEnabled)
        XCTAssertFalse(p.isSmartPunctuationEnabled)
        XCTAssertTrue(p.isSlashCommandEnabled)
        XCTAssertTrue(p.autoWrapsSelection)
    }

    func testNewEditorPreferencesRoundTrip() {
        let p = EditorPreferences(defaults: defaults)
        p.caretStyle = .line
        p.showsMinimap = false
        p.showsStatusLine = false
        p.showsReadingTime = false
        p.showsSpeakingTime = false
        p.hidesPointerWhileTyping = false
        p.isGrammarCheckingEnabled = true
        p.isSmartPunctuationEnabled = true
        p.isSlashCommandEnabled = false
        p.autoWrapsSelection = false
        let r = EditorPreferences(defaults: defaults)
        XCTAssertEqual(r.caretStyle, .line)
        XCTAssertFalse(r.showsMinimap)
        XCTAssertFalse(r.showsStatusLine)
        XCTAssertFalse(r.showsReadingTime)
        XCTAssertFalse(r.showsSpeakingTime)
        XCTAssertFalse(r.hidesPointerWhileTyping)
        XCTAssertTrue(r.isGrammarCheckingEnabled)
        XCTAssertTrue(r.isSmartPunctuationEnabled)
        XCTAssertFalse(r.isSlashCommandEnabled)
        XCTAssertFalse(r.autoWrapsSelection)
    }

    func testUnknownCaretStyleFallsBackToBlock() {
        defaults.set("bar", forKey: EditorPreferences.Keys.caretStyle)
        XCTAssertEqual(EditorPreferences(defaults: defaults).caretStyle, .block)
    }

    func testAmberAndOrangeAreDistinctColours() {
        let amber = EditorPreferences.AccentPreset.amber.nsColor.usingColorSpace(.sRGB)!
        let orange = EditorPreferences.AccentPreset.orange.nsColor.usingColorSpace(.sRGB)!
        XCTAssertNotEqual(amber, orange)
    }
```

Create `ClioTests/AppPreferencesTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run to verify failure**

`xcodegen generate`, then UNIT(`EditorPreferencesTests`) — Expected: compile errors (`caretStyle` not a member, `AppPreferences` not found).

- [ ] **Step 3: Implement `EditorPreferences` additions**

In `EditorPreferences.swift` add above the class:

```swift
enum CaretStyle: String, CaseIterable, Identifiable, Sendable {
    case block, line
    var id: Self { self }
    var title: String { self == .block ? "Block" : "Line" }
}
```

Fix amber (line 51): split `case .orange, .amber: .systemOrange` into
```swift
            case .orange: .systemOrange
            case .amber: NSColor(srgbRed: 1.0, green: 0.69, blue: 0.0, alpha: 1)
```

Add to `Keys`:
```swift
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
```

Add properties after `isChromeFadeEnabled` (longhand `didSet`, matching file idiom):
```swift
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
```

In `init` after `accent = …`:
```swift
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
```

- [ ] **Step 4: Create `Clio/App/Settings/SettingsCategory.swift`**

```swift
/// The pages of the Settings panel, in sidebar order. The raw value is
/// persisted, so renaming a case orphans the stored selection (it falls back
/// to `.general`) rather than failing.
enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case general, editor, writing, workspaces, export, assisted, localMCP

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .editor: "Editor"
        case .writing: "Writing"
        case .workspaces: "Workspaces"
        case .export: "Export"
        case .assisted: "Assisted Commands"
        case .localMCP: "Local MCP"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .editor: "textformat"
        case .writing: "pencil.line"
        case .workspaces: "folder"
        case .export: "square.and.arrow.up"
        case .assisted: "sparkles"
        case .localMCP: "point.3.connected.trianglepath.dotted"
        }
    }
}
```

- [ ] **Step 5: Create `Clio/App/AppPreferences.swift`**

```swift
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
```

- [ ] **Step 6: Wire into AppState**

After `let preferences: EditorPreferences` (AppState.swift:30) add `let appPreferences: AppPreferences`. After line 243 (`self.preferences = EditorPreferences(defaults: defaults)`) add `self.appPreferences = AppPreferences(defaults: defaults)`.

- [ ] **Step 7: Run tests**

`xcodegen generate`; UNIT(`EditorPreferencesTests`) and UNIT(`AppPreferencesTests`). Expected: all pass, executed count = previous + 4 and 3 respectively.

- [ ] **Step 8: Commit**

```bash
git add Clio/App/EditorPreferences.swift Clio/App/AppPreferences.swift Clio/App/Settings/SettingsCategory.swift Clio/App/AppState.swift ClioTests/EditorPreferencesTests.swift ClioTests/AppPreferencesTests.swift Clio.xcodeproj
git commit -m "feat(settings): add preferences for shipped editor, window and export behaviour"
```

---

### Task 3: Glass design layer

**Files:**
- Create: `Clio/Design/Glass.swift`
- Test: Create `ClioTests/GlassTests.swift`

**Interfaces:**
- Produces:
  - `enum GlassShape { case panel, card, capsule, row }` with `var cornerRadius: CGFloat?` (panel 16, card 12, row 8, capsule nil)
  - `enum ClioGlass { static func glass(selected: Bool, accent: Color, interactive: Bool) -> Glass; static let selectedTintOpacity: Double = 0.28 }`
  - `extension View { func clioGlass(_ shape: GlassShape, selected: Bool = false, interactive: Bool = false) -> some View }` — reads accent from `@Environment(AppState.self)` via an inner modifier; falls back to `Palette.accent` when no AppState in environment is not possible, so the modifier takes accent from `EnvironmentValues.clioAccent` (set once at `ContentView` root, default `Color(nsColor: Palette.accent)`).
  - `struct ClioGlassGroup<Content: View>: View { init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) }`
  - `extension EnvironmentValues { @Entry var clioAccent: Color }`

- [ ] **Step 1: Write failing test**

```swift
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
```

- [ ] **Step 2: Run** `xcodegen generate`; UNIT(`GlassTests`) — Expected: compile failure, `ClioGlass` not found.

- [ ] **Step 3: Implement `Clio/Design/Glass.swift`**

```swift
import SwiftUI

/// The only place Clio calls `glassEffect`. Surfaces pick a shape and whether
/// they are the selected/active element; everything else (variant, tint
/// strength, radii) is decided here so the chrome stays consistent and any
/// artifact can be tuned in one file.
///
/// The writing surface is never glass: glass samples what is behind it, and
/// behind the editor is only black.
enum GlassShape {
    case panel, card, capsule, row

    var cornerRadius: CGFloat? {
        switch self {
        case .panel: 16
        case .card: 12
        case .row: 8
        case .capsule: nil
        }
    }
}

enum ClioGlass {
    /// Strong enough to read over black, weak enough not to compete with text.
    static let selectedTintOpacity: Double = 0.28

    static func glass(selected: Bool, accent: Color, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if selected { glass = glass.tint(accent.opacity(selectedTintOpacity)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension EnvironmentValues {
    @Entry var clioAccent: Color = Color(nsColor: Palette.accent)
}

private struct ClioGlassModifier: ViewModifier {
    let shape: GlassShape
    let selected: Bool
    let interactive: Bool
    @Environment(\.clioAccent) private var accent

    func body(content: Content) -> some View {
        let glass = ClioGlass.glass(selected: selected, accent: accent, interactive: interactive)
        if let radius = shape.cornerRadius {
            content.glassEffect(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.glassEffect(glass, in: Capsule())
        }
    }
}

extension View {
    func clioGlass(_ shape: GlassShape, selected: Bool = false, interactive: Bool = false) -> some View {
        modifier(ClioGlassModifier(shape: shape, selected: selected, interactive: interactive))
    }
}

/// Groups sibling glass shapes so they blend instead of stacking when close.
struct ClioGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) { content }
    }
}
```

- [ ] **Step 4: Set the accent environment once**

In `ContentView.body` (ContentView.swift, after `.background(Color(nsColor: Palette.background))` at line 91) add `.environment(\.clioAccent, appState.accent.color)`.

- [ ] **Step 5: Run** UNIT(`GlassTests`) — Expected: 4 pass. If `Glass` equality for tint compares unequal because `Color.opacity` produces a new instance each time, change the test and implementation to compare `ClioGlass.tintColor(accent:)` (a `Color`) instead and keep `glass(…)` untested for tint; document why in a comment.

- [ ] **Step 6: Commit**

```bash
git add Clio/Design/Glass.swift ClioTests/GlassTests.swift Clio/App/ContentView.swift Clio.xcodeproj
git commit -m "feat(design): add shared Liquid Glass layer"
```

---

### Task 4: Wire editor and writing behaviour preferences

**Files:**
- Modify: `Clio/Editor/EditorView.swift:10-50` (`EditorConfiguration`)
- Modify: `Clio/Editor/EditorTextView.swift:77-85,154-174,176-212`
- Modify: `Clio/Editor/WritingTime.swift` (add `StatusLineText`)
- Modify: `Clio/App/ContentView.swift:175-224` (configuration, slash, minimap, status line), `:583-610` (StatusLine), WindowChromeProbe/WindowProbeView (`hidesPointerWhileTyping`)
- Test: Create `ClioTests/EditorBehaviourPreferencesTests.swift`

**Interfaces:**
- Consumes: `EditorPreferences` vars from Task 2, `CaretStyle`.
- Produces:
  - `EditorConfiguration` new stored vars (with init params defaulting to current behaviour): `caretStyle: CaretStyle = .block`, `isGrammarCheckingEnabled: Bool = false`, `isSmartPunctuationEnabled: Bool = false`, `autoWrapsSelection: Bool = true`
  - `EditorTextView.caretStyle: CaretStyle`, `EditorTextView.autoWrapsSelection: Bool`
  - `enum StatusLineText { static func statistics(wordCountLabel: String, wordCount: Int, showsReadingTime: Bool, showsSpeakingTime: Bool) -> String }`

- [ ] **Step 1: Write failing tests**

```swift
import AppKit
import XCTest
@testable import Clio

@MainActor
final class EditorBehaviourPreferencesTests: XCTestCase {
    private func makeTextView(_ configuration: EditorConfiguration) -> EditorTextView {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.applyEditorConfiguration(configuration)
        return view
    }

    func testDefaultsKeepSubstitutionsOff() {
        let view = makeTextView(EditorConfiguration())
        XCTAssertFalse(view.isGrammarCheckingEnabled)
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertEqual(view.caretStyle, .block)
        XCTAssertTrue(view.autoWrapsSelection)
    }

    func testPreferencesReachTheTextView() {
        var configuration = EditorConfiguration()
        configuration.isGrammarCheckingEnabled = true
        configuration.isSmartPunctuationEnabled = true
        configuration.caretStyle = .line
        configuration.autoWrapsSelection = false
        let view = makeTextView(configuration)
        XCTAssertTrue(view.isGrammarCheckingEnabled)
        XCTAssertTrue(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertTrue(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertEqual(view.caretStyle, .line)
        XCTAssertFalse(view.autoWrapsSelection)
    }

    func testTypingAMarkerOverASelectionReplacesItWhenAutoWrapIsOff() {
        var configuration = EditorConfiguration()
        configuration.autoWrapsSelection = false
        let view = makeTextView(configuration)
        view.string = "word"
        var wrapped = false
        view.onMarkdownAction = { action in
            if case .wrap = action { wrapped = true; return true }
            return false
        }
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(wrapped)
        XCTAssertEqual(view.string, "*")
    }

    func testStatusLineTextHonoursToggles() {
        XCTAssertEqual(
            StatusLineText.statistics(wordCountLabel: "10 words", wordCount: 10, showsReadingTime: true, showsSpeakingTime: true),
            "10 words · Read \(WritingTime.label(words: 10, wordsPerMinute: 250)) · Speak \(WritingTime.label(words: 10, wordsPerMinute: 140))"
        )
        XCTAssertEqual(
            StatusLineText.statistics(wordCountLabel: "10 words", wordCount: 10, showsReadingTime: false, showsSpeakingTime: false),
            "10 words"
        )
        XCTAssertEqual(
            StatusLineText.statistics(wordCountLabel: "10 words", wordCount: 10, showsReadingTime: false, showsSpeakingTime: true),
            "10 words · Speak \(WritingTime.label(words: 10, wordsPerMinute: 140))"
        )
    }
}
```

(If `onMarkdownAction` is not settable from tests, check its declaration in EditorTextView.swift and use the same access the coordinator uses; it is `var onMarkdownAction: ((MarkdownEditorAction) -> Bool)?`.)

- [ ] **Step 2: Run** `xcodegen generate`; UNIT(`EditorBehaviourPreferencesTests`) — Expected: compile failure.

- [ ] **Step 3: Extend `EditorConfiguration`** — add stored vars and init params (append after `accent`):

```swift
    var caretStyle: CaretStyle
    var isGrammarCheckingEnabled: Bool
    var isSmartPunctuationEnabled: Bool
    var autoWrapsSelection: Bool
```
init params: `caretStyle: CaretStyle = .block, isGrammarCheckingEnabled: Bool = false, isSmartPunctuationEnabled: Bool = false, autoWrapsSelection: Bool = true`, assigned in the body.

- [ ] **Step 4: Apply in `EditorTextView`**

Add stored properties near the top of the class:
```swift
    private(set) var caretStyle: CaretStyle = .block
    private(set) var autoWrapsSelection = true
```
In `applyEditorConfiguration` replace the substitution block lines for quote/dash/grammar with:
```swift
        caretStyle = configuration.caretStyle
        autoWrapsSelection = configuration.autoWrapsSelection
        isAutomaticQuoteSubstitutionEnabled = configuration.isSmartPunctuationEnabled
        isAutomaticDashSubstitutionEnabled = configuration.isSmartPunctuationEnabled
        …(unchanged lines)…
        isGrammarCheckingEnabled = configuration.isGrammarCheckingEnabled
```
In `insertText(_:replacementRange:)` change the guard to `if autoWrapsSelection, selectedRange().length > 0, …`.
In `drawInsertionPoint` add at the top:
```swift
        if caretStyle == .line {
            blockCaret.isHidden = true
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
```
(Check how the class suppresses AppKit's own caret for block mode — if it overrides `shouldDrawInsertionPoint` or skips `super`, keep that path for `.block` only.)

- [ ] **Step 5: Add `StatusLineText` to `Clio/Editor/WritingTime.swift`**

```swift
enum StatusLineText {
    static func statistics(
        wordCountLabel: String,
        wordCount: Int,
        showsReadingTime: Bool,
        showsSpeakingTime: Bool
    ) -> String {
        var parts = [wordCountLabel]
        if showsReadingTime { parts.append("Read \(WritingTime.label(words: wordCount, wordsPerMinute: 250))") }
        if showsSpeakingTime { parts.append("Speak \(WritingTime.label(words: wordCount, wordsPerMinute: 140))") }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 6: Wire ContentView**

In `editorPane` `EditorConfiguration(…)` add:
```swift
                    accent: appState.accent,
                    caretStyle: appState.preferences.caretStyle,
                    isGrammarCheckingEnabled: appState.preferences.isGrammarCheckingEnabled,
                    isSmartPunctuationEnabled: appState.preferences.isSmartPunctuationEnabled,
                    autoWrapsSelection: appState.preferences.autoWrapsSelection
```
Slash (Review Focus 4): replace `onSlashCommand: { … }` with
```swift
                onSlashCommand: appState.preferences.isSlashCommandEnabled
                    ? { presentation in windowSession.presentInlineSlashPalette(presentation) }
                    : nil,
```
Confirm in `EditorCoordinator` that a nil `onSlashCommand` lets the `/` insert literally (it returns `true` from `shouldChangeTextIn` when no handler). If it doesn't, guard the trigger with `onSlashCommand != nil`.
Minimap: `.overlay(alignment: .topTrailing) { if appState.preferences.showsMinimap { EditorMinimapOverlay().frame(width: 32) } }`.
Status line: pass `showsReadingTime`/`showsSpeakingTime` into `StatusLine`, wrap it in `if appState.preferences.showsStatusLine`, and have `StatusLine` use `StatusLineText.statistics(…)` for both the visible text and the accessibility label (the capsule restyle is Task 7 — keep the current layout here).
Pointer: add `var hidesPointerWhileTyping = true` to `WindowProbeView`; set it from `WindowChromeProbe` (`let hidesPointerWhileTyping: Bool`, passed as `appState.preferences.hidesPointerWhileTyping` at ContentView.swift:94) in both `makeNSView` and `updateNSView`; in `updateNativeChrome` change the hide condition to `if hidesPointerWhileTyping, session.motion.chrome.pointer.target == 0, …`, and in `updateNSView` call `view.restorePointerIfDisabled()` which is `if !hidesPointerWhileTyping { restorePointer() }` (make `restorePointer` non-private or add the wrapper).

- [ ] **Step 7: Add a slash test to `EditorBehaviourPreferencesTests`**

```swift
    func testSlashIsLiteralWithoutAHandler() {
        let host = EditorView(
            text: "",
            contentGeneration: .init(),
            onTextEdit: { _ in },
            onSlashCommand: nil
        )
        XCTAssertNotNil(host) // compile-level guard: nil handler is accepted
    }
```
If `EditorCoordinator` exposes a testable decision point (e.g. `static func isInlineSlashTrigger` plus the handler check), replace the above with a direct assertion that the coordinator returns "insert literally" when `onSlashCommand == nil`. Otherwise cover it in the UI test in Task 8 (`testSlashCommandsOffInsertsLiteralSlash`). Check `BufferGeneration`'s initializer name before writing this.

- [ ] **Step 8: Run** UNIT(`EditorBehaviourPreferencesTests`) then UNIT(all). Expected: new tests pass; full suite executed count ≥ baseline + new tests, no new failures.

- [ ] **Step 9: Commit**

```bash
git add Clio/Editor Clio/App/ContentView.swift ClioTests/EditorBehaviourPreferencesTests.swift Clio.xcodeproj
git commit -m "feat(editor): honour caret, grammar, smart punctuation, wrap, slash, minimap, status and pointer preferences"
```

---

### Task 5: Window, launch, export and recovery-folder preferences

**Files:**
- Modify: `Clio/App/EditorWindowSession.swift:101-113` (init)
- Modify: `Clio/App/ClioApp.swift:34-37` (`EditorWindowRoot` session creation), `:209-213` (delegate `init(appState:)`)
- Modify: `Clio/App/LaunchConfiguration.swift:11-16`
- Modify: `Clio/Export/DocumentExportPresentation.swift:283-300,381-390`
- Modify: `Clio/App/AppState.swift:94-102,1175-1195`
- Test: `ClioTests/AppPreferencesTests.swift`, `ClioTests/ExportPresentationTests.swift`, `ClioTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `AppPreferences` (Task 2).
- Produces:
  - `EditorWindowSession.init(request: EditorWindowRequest, sidebarVisibleByDefault: Bool = true, sidebarPinnedByDefault: Bool = false)`
  - `DocumentExportPresentation.init(…, defaultFormat: @escaping @MainActor () -> ExportFormat = { .pdf })`
  - `AppState.recoveryFolderURL: URL?`, `AppState.changeRecoveryFolder()` (cancel = no-op)
  - `AppState.chooseRecoveryFolder(flagsCancellation: Bool = true)`

- [ ] **Step 1: Write failing tests**

Append to `AppPreferencesTests`:
```swift
    func testNewWindowsUseSidebarDefaultsWithoutRestoration() {
        let session = EditorWindowSession(request: .newDocument(), sidebarVisibleByDefault: false, sidebarPinnedByDefault: true)
        XCTAssertFalse(session.isSidebarVisible)
        XCTAssertTrue(session.isSidebarPinned)
    }

    func testRestoredWindowsIgnoreSidebarDefaults() {
        var request = EditorWindowRequest.newDocument()
        request.restoration = EditorWindowRestorationState(tabs: [], activeTabID: nil, isSidebarVisible: true, isSidebarPinned: false, isFullScreen: false)
        let session = EditorWindowSession(request: request, sidebarVisibleByDefault: false, sidebarPinnedByDefault: true)
        XCTAssertTrue(session.isSidebarVisible)
        XCTAssertFalse(session.isSidebarPinned)
    }
```
(Match `EditorWindowRestorationState`'s real memberwise initializer — read its declaration in EditorSession.swift first and adjust the argument list.)

Append to `ExportPresentationTests`:
```swift
    func testOptionsSheetStartsOnTheDefaultFormat() {
        let presentation = DocumentExportPresentation(
            coordinator: DocumentExportCoordinator(),
            printSettingsStore: PDFPrintSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            panelPresenter: NativeExportPanelPresenter(),
            recoveryCatalog: ExportRecoveryCatalog.shared,
            defaultFormat: { .html }
        )
        presentation.requestExport()
        XCTAssertTrue(presentation.isOptionsPresented)
        XCTAssertEqual(presentation.selectedFormat, .html)
    }
```
(If the test file already has a fake panel presenter / catalog, use those instead of the native ones.)

Append to `AppStateTests` (Review Focus 5), using the file's existing factory (`TestAppStateFactory`) and its folder-selection injection hook — read `TestAppStateFactory.swift` and how `configuredFolderPanel` can be faked. If the panel is not injectable, add `folderPanelRunner: (@MainActor (NSOpenPanel) -> URL?)?` to AppState's init (default runs the panel modally) and use it:
```swift
    func testCancellingRecoveryFolderChangeLeavesStateUntouched() {
        let state = TestAppStateFactory.make(folderPanelRunner: { _ in nil })
        state.changeRecoveryFolder()
        XCTAssertFalse(state.needsRecoveryAuthorization)
        XCTAssertNil(state.workspaceErrorMessage)
    }
```

- [ ] **Step 2: Run** UNIT(`AppPreferencesTests`), UNIT(`ExportPresentationTests`), UNIT(`AppStateTests`) — Expected: compile failures.

- [ ] **Step 3: EditorWindowSession init**

```swift
    init(
        request: EditorWindowRequest,
        sidebarVisibleByDefault: Bool = true,
        sidebarPinnedByDefault: Bool = false
    ) {
        id = request.id
        isFullScreenEnabled = request.restoration?.isFullScreen
            ?? request.isFullScreen
        isSidebarVisible = request.restoration?.isSidebarVisible ?? sidebarVisibleByDefault
        isSidebarPinned = request.restoration?.isSidebarPinned ?? sidebarPinnedByDefault
        motion = WindowMotionAdapter(
            sidebarVisible: isSidebarVisible,
            pinned: isSidebarPinned
        )
```
In `EditorWindowRoot.init` (ClioApp.swift:~60):
```swift
            initialValue: EditorWindowSession(
                request: initialRequest,
                sidebarVisibleByDefault: appState.appPreferences.showsSidebarInNewWindows,
                sidebarPinnedByDefault: appState.appPreferences.pinsSidebarInNewWindows
            )
```

- [ ] **Step 4: Launch behaviour**

`LaunchConfiguration.current` non-test branch:
```swift
            let appState = AppState()
            return Self(
                appState: appState,
                initialWindowRequest: appState.appPreferences.initialWindowRequest()
            )
```
Delegate `init(appState:)` (ClioApp.swift:~210): `initialWindowRequest = appState.appPreferences.initialWindowRequest()`.

- [ ] **Step 5: Export default format**

Add `@ObservationIgnored private let defaultFormat: @MainActor () -> ExportFormat` and the init parameter `defaultFormat: @escaping @MainActor () -> ExportFormat = { .pdf }` (last parameter); the convenience init passes nothing. In `requestExport(arguments:)` just before `isOptionsPresented = true` add `selectedFormat = defaultFormat()`. In `AppState.makeWindowExportPresentation()` pass `defaultFormat: { [weak self] in self?.appPreferences.defaultExportFormat ?? .pdf }`.

- [ ] **Step 6: Recovery folder**

In AppState:
```swift
    /// Where conflict and replacement recovery copies are written, when known.
    var recoveryFolderURL: URL? { (recoveryStore as? RecoveryStore)?.rootURL }

    /// Settings entry point. Unlike the banner flow, cancelling here changes
    /// nothing: the writer was not asked to authorize, only offered a change.
    func changeRecoveryFolder() { chooseRecoveryFolder(flagsCancellation: false) }
```
Change `func chooseRecoveryFolder()` to `func chooseRecoveryFolder(flagsCancellation: Bool = true)` and in its cancel branch wrap the two assignments in `if flagsCancellation { … }`, then `return`. Route the modal run through the injectable runner if you added it in Step 1. `recoveryFolderURL` must be observable: if `recoveryStore` is `@ObservationIgnored`, add `private(set) var recoveryFolderPath: String?` updated in `activateRecovery(from:)` and init, and use that in Settings instead.

- [ ] **Step 7: Run** the three filtered suites, then UNIT(all). Expected: pass; no regressions vs baseline.

- [ ] **Step 8: Commit**

```bash
git add Clio ClioTests Clio.xcodeproj
git commit -m "feat(settings): apply sidebar, launch, export-format and recovery-folder preferences"
```

---

### Task 6: Settings panel rebuild with categories and inline MCP

**Files:**
- Delete: `Clio/App/SettingsView.swift`
- Create: `Clio/App/Settings/SettingsView.swift` (container), `SettingsControls.swift` (moved `AccentSwatch`, `NativeEditorFontPicker`, `SliderRow`, `IntegerSliderRow`, `SettingsFootnote`), `GeneralSettingsPage.swift`, `EditorSettingsPage.swift`, `WritingSettingsPage.swift`, `WorkspacesSettingsPage.swift`, `ExportSettingsPage.swift`, `AssistedCommandsSettingsPage.swift`, `LocalMCPSettingsPage.swift`
- Modify: `Clio/App/ContentView.swift:292-308` (settings surface container)
- Modify: `Clio/MCP/ClioMCPService.swift:71,206-263` (retire window, remove `MCPSettingsView`)
- Modify: `Clio/App/AppState.swift` (settings request routing)
- Modify: `Clio/App/EditorWindowSession.swift` (consume requests)
- Test: `ClioTests/AppStateTests.swift` (request routing)

**Interfaces:**
- Consumes: `SettingsCategory`, `AppPreferences.lastSettingsCategory`, `EditorPreferences` vars, `AppState.changeRecoveryFolder()`, `AppState.recoveryFolderURL`, `PDFPrintSettingsStore.resetToRegionalDefault()`, `clioGlass`, `ClioGlassGroup`.
- Produces:
  - `struct SettingsView: View` (container: category list + page), `@Binding`-free; reads/writes `appState.appPreferences.lastSettingsCategory`.
  - `AppState.requestSettings(_ category: SettingsCategory)`; `AppState.pendingSettingsRequest: SettingsCategory?`; `AppState.consumeSettingsRequest(for windowID: UUID, isKeyOrOnlyWindow: Bool) -> SettingsCategory?`
  - `ClioMCPService.showSettings()` now: `loadCredentials`, `refreshLoginStatus`, `openEditor?()`, `app.requestSettings(.localMCP)`.

- [ ] **Step 1: Write failing test for request routing** (Review Focus 3)

```swift
    func testSettingsRequestIsConsumedByExactlyOneWindow() {
        let state = TestAppStateFactory.make()
        state.requestSettings(.localMCP)
        let first = UUID(), second = UUID()
        XCTAssertNil(state.consumeSettingsRequest(for: second, isKeyOrOnlyWindow: false))
        XCTAssertEqual(state.consumeSettingsRequest(for: first, isKeyOrOnlyWindow: true), .localMCP)
        XCTAssertNil(state.consumeSettingsRequest(for: second, isKeyOrOnlyWindow: true))
        XCTAssertEqual(state.appPreferences.lastSettingsCategory, .localMCP)
    }
```

- [ ] **Step 2: Run** UNIT(`AppStateTests/testSettingsRequestIsConsumedByExactlyOneWindow`) — Expected: compile failure.

- [ ] **Step 3: Implement routing in AppState**

```swift
    /// A Settings page asked for from outside a window (the menu bar's MCP
    /// item). Held until a window claims it, because the window may not exist
    /// yet when the request is made.
    private(set) var pendingSettingsRequest: SettingsCategory?

    func requestSettings(_ category: SettingsCategory) {
        appPreferences.lastSettingsCategory = category
        pendingSettingsRequest = category
    }

    func consumeSettingsRequest(for windowID: UUID, isKeyOrOnlyWindow: Bool) -> SettingsCategory? {
        guard isKeyOrOnlyWindow, let category = pendingSettingsRequest else { return nil }
        pendingSettingsRequest = nil
        return category
    }
```
In `ContentView.body` add:
```swift
        .onChange(of: appState.pendingSettingsRequest, initial: true) { _, _ in
            let editorWindows = NSApp.windows.filter(isClioEditorWindow)
            let isKey = NSApp.keyWindow.flatMap(clioEditorSessionID(for:)) == windowSession.id
            if appState.consumeSettingsRequest(for: windowSession.id, isKeyOrOnlyWindow: isKey || editorWindows.count <= 1) != nil {
                windowSession.isSettingsPresented = true
            }
        }
```
(`windowID` is kept in the signature for diagnostics; unused otherwise — mark `_ = windowID` is not needed, Swift allows unused params.)

- [ ] **Step 4: Retire the MCP window**

In `ClioMCPService`: delete `settingsWindow` (line 71) and replace `showSettings()` body with:
```swift
    func showSettings() {
        do { try loadCredentials() } catch { errorMessage = "Allow Keychain access to manage MCP clients." }
        refreshLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        openEditor?()
        app.requestSettings(.localMCP)
    }
```
Move `MCPSettingsView`'s body into `LocalMCPSettingsPage` (Step 6) and delete the struct. Also make `LocalMCPSettingsPage.onAppear` call `try? service.loadCredentials()` and `service.refreshLoginStatus()` (change `loadCredentials` from private to internal if needed).

- [ ] **Step 5: Container `Clio/App/Settings/SettingsView.swift`**

```swift
import SwiftUI

/// The Settings panel: a category list beside one page. Presented inside the
/// editor window by `ContentView`; the panel's glass is applied there, so
/// nothing in here draws its own glass background (no glass on glass).
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    let done: () -> Void
    let doneFocus: FocusState<Bool>.Binding
    let compact: Bool

    var body: some View {
        let selection = appState.appPreferences.lastSettingsCategory
        HStack(spacing: 0) {
            categoryList(selection: selection)
                .frame(width: compact ? 52 : 176)
                .padding(.vertical, 12)
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                HStack {
                    Text(selection.title).font(.headline)
                    Spacer()
                    Button("Done", action: done)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.cancelAction)
                        .focused(doneFocus)
                }
                .padding(16)
                page(for: selection)
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
        }
        .tint(appState.accent.color)
    }

    private func categoryList(selection: SettingsCategory) -> some View {
        ClioGlassGroup(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsCategory.allCases) { category in
                    Button {
                        appState.appPreferences.lastSettingsCategory = category
                    } label: {
                        Label(category.title, systemImage: category.symbol)
                            .labelStyle(CategoryLabelStyle(compact: compact))
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: compact ? .center : .leading)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clioGlass(.row, selected: category == selection)
                    .opacity(category == selection ? 1 : 0.85)
                    .help(category.title)
                    .accessibilityIdentifier("settings.category.\(category.rawValue)")
                    .accessibilityAddTraits(category == selection ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder private func page(for category: SettingsCategory) -> some View {
        switch category {
        case .general: GeneralSettingsPage()
        case .editor: EditorSettingsPage()
        case .writing: WritingSettingsPage()
        case .workspaces: WorkspacesSettingsPage()
        case .export: ExportSettingsPage()
        case .assisted: AssistedCommandsSettingsPage()
        case .localMCP: LocalMCPSettingsPage()
        }
    }
}

private struct CategoryLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 18)
            if !compact { configuration.title }
        }
    }
}
```

**Form section fills:** grouped `Form` rows draw the system secondary fill, which reads as flat grey on glass-over-black. If Task 9 flags it, add `.listRowBackground(Color.white.opacity(0.04))` per Section via a `SettingsSection` wrapper in `SettingsControls.swift`.

**Glass-on-rows caveat:** unselected rows should not carry glass (that would stack glass on the panel). If `clioGlass(.row, selected: false)` renders visible plain glass rows, change the row modifier to apply `clioGlass(.row, selected: true)` only when selected (`.modifier` with an `if`), and verify in Task 9.

- [ ] **Step 6: Pages**

Each page is a `Form { … }` reading `@Environment(AppState.self)` with `@Bindable var preferences = appState.preferences` / `@Bindable var app = appState.appPreferences` inside `body`. Move existing section content verbatim where noted (keep copy and identifiers unchanged).

`GeneralSettingsPage.swift`:
```swift
import SwiftUI

struct GeneralSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var app = appState.appPreferences
        @Bindable var appState = appState
        Form {
            Section("Startup") {
                Picker("When Clio opens", selection: $app.launchBehavior) {
                    ForEach(LaunchBehavior.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.general.launch")
                SettingsFootnote("Applies to the first window when macOS has no windows to restore.")
            }
            Section("New Windows") {
                Toggle("Show sidebar", isOn: $app.showsSidebarInNewWindows)
                    .accessibilityIdentifier("settings.general.sidebarVisible")
                Toggle("Pin sidebar", isOn: $app.pinsSidebarInNewWindows)
                    .disabled(!app.showsSidebarInNewWindows)
                    .accessibilityIdentifier("settings.general.sidebarPinned")
            }
            Section("Appearance") {
                // moved verbatim from old SettingsView "Appearance" section (accent Picker)
            }
        }
    }
}
```

`EditorSettingsPage.swift`: Section "Typography" = old Typography section verbatim. Section "Caret": `Picker("Caret", selection: $preferences.caretStyle) { ForEach(CaretStyle.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("settings.editor.caret")`. Section "Chrome": `Toggle("Show minimap", isOn: $preferences.showsMinimap).accessibilityIdentifier("settings.editor.minimap")`, `Toggle("Show status line", isOn: $preferences.showsStatusLine).accessibilityIdentifier("settings.editor.statusLine")`, then `Toggle("Reading time", …showsReadingTime)` and `Toggle("Speaking time", …showsSpeakingTime)` both `.disabled(!preferences.showsStatusLine)` with identifiers `settings.editor.readingTime` / `settings.editor.speakingTime`.

`WritingSettingsPage.swift`: Section "Focus" = old Focus section verbatim, plus after "Fade chrome while typing": `Toggle("Hide pointer while typing", isOn: $preferences.hidesPointerWhileTyping).disabled(!appState.isChromeFadeEnabled).accessibilityIdentifier("settings.writing.hidePointer")`. Section "Text": `Toggle("Check spelling", …)` (moved), `Toggle("Check grammar", isOn: $preferences.isGrammarCheckingEnabled)` (`settings.writing.grammar`), `Toggle("Smart quotes and dashes", isOn: $preferences.isSmartPunctuationEnabled)` (`settings.writing.smartPunctuation`) with footnote "Off by default so Markdown stays literal: smart quotes change the characters written to disk." Section "Shortcuts": `Toggle("Slash command palette", isOn: $preferences.isSlashCommandEnabled)` (`settings.writing.slash`) footnote "Typing / opens commands. When off, / is always a literal slash; ⌘K still opens the palette."; `Toggle("Wrap selection when typing * _ ~ `", isOn: $preferences.autoWrapsSelection)` (`settings.writing.autoWrap`).

`WorkspacesSettingsPage.swift`: Section "Folders" = old Workspace section verbatim. Section "Recovery":
```swift
                LabeledContent("Recovery folder") {
                    HStack {
                        Text(appState.recoveryFolderURL?.path ?? "Not authorized")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(appState.recoveryFolderURL?.path ?? "")
                        Button("Change…") { appState.changeRecoveryFolder() }
                            .accessibilityIdentifier("settings.workspaces.recoveryFolder")
                    }
                }
                SettingsFootnote("Clio writes a recovery copy here before replacing either side of a conflict. Copies are kept for seven days.")
```
Section "Discovery" = old Workspace Rules section verbatim; keep `.onChange(of: discovery.policy) { appState.discoveryPolicyDidChange() }` on this page's Form.

`ExportSettingsPage.swift`:
```swift
import SwiftUI

struct ExportSettingsPage: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession

    var body: some View {
        @Bindable var app = appState.appPreferences
        let presentation = windowSession.exportPresentation
        Form {
            Section("Format") {
                Picker("Default format", selection: $app.defaultExportFormat) {
                    Text("PDF").tag(ExportFormat.pdf)
                    Text("Word (.docx)").tag(ExportFormat.docx)
                    Text("Plain Text (.txt)").tag(ExportFormat.txt)
                    Text("HTML").tag(ExportFormat.html)
                }
                .accessibilityIdentifier("settings.export.defaultFormat")
            }
            Section("PDF Page Setup") {
                LabeledContent("Page", value: presentation.pageSetupSummary)
                HStack {
                    Button("Page Setup…") { presentation.presentPageSetup() }
                        .accessibilityIdentifier("settings.export.pageSetup")
                    Button("Reset to Regional Default") { presentation.printSettingsStore.resetToRegionalDefault() }
                        .accessibilityIdentifier("settings.export.resetPageSetup")
                }
            }
        }
    }
}
```
(Check that `pageSetupSummary` reads `printSettingsStore.settings` so it updates after reset; `PDFPrintSettingsStore` is `@Observable` so it will.)

`AssistedCommandsSettingsPage.swift`: move the whole "Assisted Commands" section verbatim, including `@State private var typeSafeKeyEntry`, `trimmedTypeSafeKeyEntry`, `saveTypeSafeKey()`, into this struct; section title "TypeSafe".

`LocalMCPSettingsPage.swift`: Section "Server": the enable toggle and status (from old Local MCP section), `LabeledContent("Endpoint") { Text("http://127.0.0.1:19847/mcp").textSelection(.enabled) }`, the explanatory caption from `MCPSettingsView`, and `Toggle("Open Clio at login without a window", …)` + `loginStatus` caption. Section "Authorize a client" and Section "Authorized clients (N sessions)": verbatim from `MCPSettingsView` (with its `@State name`/`selected`), buttons get identifiers `settings.mcp.authorize`, `settings.mcp.revoke.\(client.id)`. Error text at bottom. Use `let service = appState.mcpService` and `@Bindable var service = appState.mcpService` as needed.

`SettingsControls.swift`: move `AccentSwatch`, `NativeEditorFontPicker`, `SliderRow`, `IntegerSliderRow` verbatim (make the latter three `struct` without `private`, internal), and add:
```swift
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
```

- [ ] **Step 7: Update the settings surface in ContentView (292-308)**

```swift
        case .settings:
            let width = min(760, availableSize.width - 32)
            SettingsView(
                done: { windowSession.isSettingsPresented = false },
                doneFocus: $settingsDoneFocused,
                compact: width < 600
            )
            .frame(width: width, height: min(620, availableSize.height - 32))
            .clioGlass(.panel)
            .modifier(SurfacePresentation(progress: state.settings.presentation, y: 8, scale: 0.99, reduceMotion: reduceMotion))
            .onAppear { settingsDoneFocused = true }
            .onChange(of: windowSession.isSettingsPresented) { _, presented in settingsDoneFocused = presented }
```

- [ ] **Step 8: Build, regenerate, run**

`git rm Clio/App/SettingsView.swift`; `xcodegen generate`; BUILD; UNIT(all). Expected: builds; routing test passes; no regressions. Launch the app manually (`open .build/DerivedData/UnitTests/Build/Products/Debug/Clio.app`) and press ⌘, — every category renders.

- [ ] **Step 9: Commit**

```bash
git add -A Clio ClioTests Clio.xcodeproj
git commit -m "feat(settings): categorised glass settings panel with inline MCP management"
```

---

### Task 7: Convert chrome surfaces to glass

**Files:**
- Modify: `Clio/App/WorkspaceSidebar.swift:39-44,266`
- Modify: `Clio/App/ContentView.swift` (sidebar overlay 341-354, banners 375-581, conflict strip 246-255, conflict sheet 309-318 & 527, status line 583-610 & 213-221, titlebar button 801-819)
- Modify: `Clio/App/CommandPaletteView.swift:117-123,261-265,302-307,50-78`
- Modify: `Clio/Export/DocumentExportPresentation.swift:704-816`
- Modify: `Clio/App/WorkspaceSetupView.swift`
- Test: `ClioTests/GlassTests.swift` (source guard)

**Interfaces:** Consumes: `clioGlass`, `ClioGlassGroup`, `GlassShape`.

- [ ] **Step 1: Write a failing source-guard test** (enforces the single-owner rule and removal of raised fills from chrome)

```swift
    func testOnlyTheDesignLayerCallsGlassEffect() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Clio")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
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
```
Run UNIT(`GlassTests`) — Expected: `testChromeNoLongerUsesRaisedFill` FAILS for all three files, and `testOnlyTheDesignLayerCallsGlassEffect` FAILS listing `DocumentExportPresentation.swift`.

- [ ] **Step 2: Sidebar**

`WorkspaceSidebar.body` — replace lines 40-44 (`.frame(width: 252)` … trailing hairline overlay) with:
```swift
        .frame(width: 244)
        .clioGlass(.panel)
        .padding(.leading, 8)
        .padding(.vertical, 8)
```
Selected row (line 266): replace the `.background(isSelected ? … )` with
```swift
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(appState.accent.color.opacity(ClioGlass.selectedTintOpacity))
            }
        }
```
(fill, not glass — the panel is already glass; add `@Environment(AppState.self) private var appState` to that row view if missing). Do the same for the open-documents selected row if it uses the hairline fill. Replace the `Divider()` under New Document with `Divider().opacity(0.3)`.
In `MotionSidebarOverlay`, the offset `-252` stays (panel 244 + 8 inset = 252). In `WindowProbeView.installScrollMonitor` the `event.locationInWindow.x < 252` hit test stays valid.
Sidebar top must clear the traffic lights: add `.padding(.top, 28)` inside the panel's content (above the New Document button) when not in full screen — use `windowSession.isFullScreenEnabled ? 0 : 20`.

- [ ] **Step 3: Command palette**

Replace CommandPaletteView.swift:117-123 with `.clioGlass(.panel)` (drop the clip, stroke and shadow). Row highlight (261-265 and 302-307): fill `appState.accent.color.opacity(ClioGlass.selectedTintOpacity)` in `RoundedRectangle(cornerRadius: 8, style: .continuous)` (pass `accent: Color` into `PaletteRow` as a parameter, taken from `@Environment(\.clioAccent)` in the parent). The "Show Ignored" toggle at 65-78: `.toggleStyle(.button).buttonStyle(.glass)`.

- [ ] **Step 4: Banners and conflict strip**

Create a private modifier in ContentView.swift:
```swift
private struct BannerCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .clioGlass(.card)
            .padding(.horizontal, 12)
            .padding(.top, 12)
    }
}
```
In `ExportRecoveryBanner`, `DetachedDocumentBanner`, `WorkspaceErrorBanner`: replace `.padding(12).background(Color(nsColor: Palette.backgroundRaised)).overlay(alignment: .bottom) { Rectangle()… }` with `.modifier(BannerCard())`. Primary buttons ("Restore Document", "Show in Finder", "Authorize Recovery…/Choose Folder…") get `.buttonStyle(.glassProminent)`; secondary ("Dismiss", "Discard") get `.buttonStyle(.glass)`.
Conflict strip (246-255): replace `.padding(12).frame(maxWidth: .infinity).background(Color(nsColor: Palette.backgroundRaised))` with `.modifier(BannerCard())`.
Top-of-window clearance: the banner overlay sits under a transparent titlebar; add `.padding(.top, windowSession.isFullScreenEnabled ? 0 : 20)` to the banner `overlay(alignment: .top)` group so cards don't collide with traffic lights.

- [ ] **Step 5: Conflict sheet**

At 309-318 replace `.background(Color(nsColor: Palette.background)).clipShape(RoundedRectangle(cornerRadius: 12))` with `.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).clioGlass(.panel)`. In `ConflictResolutionView` remove `.background(Color(nsColor: Palette.background))` (line 527). Change the preview box background (512) to `Color(nsColor: Palette.background)` — it shows document text, so it stays black. "Keep Clio" → `.buttonStyle(.glassProminent)`, the other two `.buttonStyle(.glass)`.

- [ ] **Step 6: Status capsule**

In `editorPane`, remove `StatusLine` from the `VStack` and instead overlay it on the `EditorView`:
```swift
            .overlay(alignment: .bottom) {
                if appState.preferences.showsStatusLine {
                    StatusLine(…same args as Task 4…)
                        .modifier(ContextChromeMotion(motion: motion))
                        .padding(.bottom, 10)
                        .padding(.horizontal, 48) // keeps clear of the 32pt minimap
                }
            }
```
In `StatusLine.body`: change `Spacer(minLength: 40)` to `Text("·")`, drop `.frame(height: Metrics.statusHeight)` and `.background(Palette.background)`, add `.padding(.horizontal, 14).padding(.vertical, 6).clioGlass(.capsule)`, and keep `.fixedSize(horizontal: false, vertical: true)` so it is content-sized. `ContextChromeMotion` fades the whole capsule (glass included); if Task 9 shows a flat grey frame during the fade, apply `glassEffectTransition(.materialize)` inside `Glass.swift` via a new `clioGlass(… transition:)` parameter rather than opacity.
Because the capsule overlays text, add `Metrics.statusHeight` to the editor's bottom inset: in `EditorTextView.applyEditorConfiguration`, keep `textContainerInset.height = Metrics.verticalPadding` (64 ≥ capsule height + 10) — verify visually in Task 9.

- [ ] **Step 7: Titlebar sidebar button**

In `installTitlebarControl` wrap the button in an `NSGlassEffectView`:
```swift
        let glass = NSGlassEffectView(frame: NSRect(x: 4, y: 2, width: 30, height: 24))
        glass.cornerRadius = 12
        glass.contentView = button
        button.frame = glass.bounds
        container.addSubview(glass)
```
and include `glass` alongside `sidebarButton` in `updateNativeChrome`'s alpha/hidden loop (store it as `sidebarGlass: NSView?`; set `alphaValue`/`isHidden` on the glass view, `isEnabled` on the button).

- [ ] **Step 8: Export surfaces and workspace setup**

`DocumentExportPresentation.swift:777,809`: replace `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))` and the following hairline stroke/shadow with `.clioGlass(.card)`. In `ExportOptionsView` the confirm button → `.buttonStyle(.glassProminent)`, Page Setup / Cancel → `.buttonStyle(.glass)`.
`WorkspaceSetupView.swift`: `.borderedProminent` → `.glassProminent`; `.link` buttons → `.glass`.

- [ ] **Step 9: Run** UNIT(`GlassTests`) — Expected: all pass. BUILD. UNIT(all) — no regressions.

- [ ] **Step 10: Commit**

```bash
git add Clio ClioTests
git commit -m "feat(ui): convert sidebar, palette, banners, conflict, status, toasts and setup to Liquid Glass"
```

---

### Task 8: UI tests for the new Settings and preferences

**Files:**
- Create: `ClioUITests/ClioSettingsUITests.swift`
- Modify: `ClioUITests/ClioIntelligenceUITests.swift:125-129` (`openSettings` selects the Assisted category)

**Interfaces:** Consumes identifiers from Task 6 (`settings.category.<raw>`, `settings.editor.minimap`, `settings.editor.statusLine`, `settings.writing.slash`), `editor.text`, `editor.statistics`.

- [ ] **Step 1: Fix the intelligence helper**

```swift
    private func openSettings() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.typeKey(",", modifierFlags: .command)
        let category = app.buttons["settings.category.assisted"]
        XCTAssertTrue(category.waitForExistence(timeout: 3))
        category.click()
    }
```

- [ ] **Step 2: Write `ClioSettingsUITests.swift`**

```swift
import XCTest

final class ClioSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        app.launch()
        app.windows.firstMatch.hover()
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 5))
    }

    override func tearDown() { app.terminate() }

    private func openSettings(_ category: String) {
        app.typeKey(",", modifierFlags: .command)
        let button = app.buttons["settings.category.\(category)"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.click()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testEveryCategoryShowsARepresentativeControl() {
        let expectations: [(String, String)] = [
            ("general", "settings.general.launch"),
            ("editor", "settings.editor.minimap"),
            ("writing", "settings.writing.slash"),
            ("workspaces", "settings.workspaces.recoveryFolder"),
            ("export", "settings.export.defaultFormat"),
            ("assisted", "settings.intelligence.enabled"),
            ("localMCP", "settings.mcp.authorize"),
        ]
        app.typeKey(",", modifierFlags: .command)
        for (category, control) in expectations {
            let button = app.buttons["settings.category.\(category)"]
            XCTAssertTrue(button.waitForExistence(timeout: 3), category)
            button.click()
            XCTAssertTrue(app.descendants(matching: .any)[control].waitForExistence(timeout: 3), control)
            attach("Settings – \(category)")
        }
    }

    func testStatusLineToggleHidesStatistics() {
        XCTAssertTrue(app.descendants(matching: .any)["editor.statistics"].exists)
        openSettings("editor")
        app.switches["settings.editor.statusLine"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.descendants(matching: .any)["editor.statistics"].waitForExistence(timeout: 1))
    }

    func testSlashCommandsOffInsertsLiteralSlash() {
        openSettings("writing")
        app.switches["settings.writing.slash"].click()
        app.typeKey(.escape, modifierFlags: [])
        let editor = app.textViews["editor.text"]
        editor.click()
        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeText("/")
        XCTAssertFalse(app.textFields["palette.query"].waitForExistence(timeout: 1))
        XCTAssertTrue((editor.value as? String)?.hasPrefix("/Alpha") == true)
    }

    func testSettingsFitsTheMinimumWindow() {
        let window = app.windows.firstMatch
        // Drag the bottom-right corner inward; the window's minimum size stops it at 480×400.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: .zero))
        openSettings("editor")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.switches["settings.editor.minimap"].waitForExistence(timeout: 3))
        attach("Settings at minimum window")
    }
}
```
(Check the palette query field's real identifier in CommandPaletteView.swift and replace `palette.query` if it differs.)

- [ ] **Step 3: Run** `xcodegen generate`; UI(`ClioSettingsUITests`) then UI(`ClioIntelligenceUITests`). Expected: all pass. Then UI(all): compare with `baseline-ui.txt` — only the two known failures may remain; report executed count.

- [ ] **Step 4: Commit**

```bash
git add ClioUITests Clio.xcodeproj
git commit -m "test(ui): cover categorised settings, status line, slash toggle and minimum window"
```

---

### Task 9: Visual artifact pass and fixes

**Files:**
- Create: `ClioUITests/ClioVisualAuditUITests.swift` (screenshot-only, gated by `CLIO_VISUAL_AUDIT=1` via `TEST_RUNNER_` env so it never runs in the normal gate)
- Modify: whichever surface files the audit implicates (most fixes belong in `Clio/Design/Glass.swift`)
- Create: `docs/ui-glass-audit.md` (findings + before/after)

- [ ] **Step 1: Write the audit test**

```swift
import XCTest

final class ClioVisualAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLIO_VISUAL_AUDIT"] == "1")
        app = XCUIApplication()
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        app.launch()
        app.windows.firstMatch.hover()
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 5))
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testCaptureEverySurface() {
        shot("01 editor idle")
        app.typeKey("s", modifierFlags: [.control, .command]); shot("02 sidebar hidden")
        app.typeKey("s", modifierFlags: [.control, .command]); shot("03 sidebar shown")
        app.typeKey("k", modifierFlags: .command); shot("04 palette centred")
        app.typeKey(.escape, modifierFlags: [])
        app.textViews["editor.text"].click(); app.typeText("\n/"); shot("05 palette inline slash")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("f", modifierFlags: [.command, .shift]); shot("06 workspace search")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(",", modifierFlags: .command)
        for c in ["general", "editor", "writing", "workspaces", "export", "assisted", "localMCP"] {
            app.buttons["settings.category.\(c)"].click(); shot("07 settings \(c)")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("e", modifierFlags: [.command, .shift]); shot("08 export sheet")
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("typing burst typing burst typing burst"); sleep(6); shot("09 chrome faded")
        app.typeKey("f", modifierFlags: [.command, .control]); sleep(2); shot("10 full screen")
        app.typeKey("f", modifierFlags: [.command, .control]); sleep(2)
    }
}
```

- [ ] **Step 2: Capture**

```bash
TEST_RUNNER_CLIO_VISUAL_AUDIT=1 xcodebuild … -only-testing:ClioUITests/ClioVisualAuditUITests -resultBundlePath "$SCRATCH/audit-1.xcresult" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
xcrun xcresulttool export attachments --path "$SCRATCH/audit-1.xcresult" --output-path "$SCRATCH/audit-1"
```
Repeat with System Settings → Accessibility → Display → **Reduce transparency** on (`audit-rt`) and **Reduce motion** on (`audit-rm`); ask the user to toggle these if automation cannot (`defaults write com.apple.universalaccess reduceTransparency -bool true` requires user approval — ask first). Also capture the banners by launching with a detached-document or error scenario if `CLIO_UI_TEST_SCENARIO` supports one (check `LaunchConfiguration.uiTestConfiguration`); otherwise capture the workspace error banner by triggering "Add Folder…" cancel.

- [ ] **Step 3: Review each screenshot against the checklist**

Open every PNG with the Read tool. For each, record pass/fail for:
1. Glass-on-glass (double edge highlights, grey-on-grey rows)
2. Clipped corners or shadows (panel edges, sidebar top vs traffic lights, banner cards)
3. Bright halos / edge glow on pure black
4. Text contrast on glass (body text must be clearly legible; muted text still readable)
5. Fade artifacts (09 chrome faded: no flat grey capsule/sidebar remnants)
6. Minimap vs status capsule overlap
7. Banner stacking / overflow at narrow width
8. Settings at min size (from Task 8 attachment): compact category column, nothing truncated mid-control
9. Reduce Transparency: glass renders opaque and text still readable; scrim 0.85
10. Full screen: sidebar and banners start at the top without titlebar gap

- [ ] **Step 4: Fix findings**

Prefer fixes in `Glass.swift` (tint strength, adding `.glassEffectTransition(.materialize)`, shape radii). Surface-specific fixes go in the surface file. Re-run the capture after each batch and re-check only the failed items. Do not declare a finding fixed without a new screenshot showing it.

- [ ] **Step 5: Write `docs/ui-glass-audit.md`**

Table: surface × checklist item → pass / fixed (commit sha) / open (reason). Note that screenshots stay in the scratchpad (they may contain personal paths — per docs/testing.md, redact before sharing).

- [ ] **Step 6: Full gate**

Run `scripts/test.sh` with `CLIO_SKIP_RELEASE_BUILD=0`. Report executed counts for unit, UI and native suites and compare with baseline. Only the two pre-existing UI failures are acceptable; anything else is a regression to fix.

- [ ] **Step 7: Commit**

```bash
git add ClioUITests/ClioVisualAuditUITests.swift docs/ui-glass-audit.md Clio Clio.xcodeproj
git commit -m "test(ui): add visual glass audit and fix artifacts it found"
```
