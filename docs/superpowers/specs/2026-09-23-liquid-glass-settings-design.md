# Liquid Glass UI and Settings Respec — Design

Date: 2026-09-23
Branch: `feat/liquid-glass-settings`
Status: awaiting review

## Goal

Bring Clio's chrome in line with macOS 26/27 Liquid Glass while keeping the
pure-black writing surface, expose every shipped-but-unconfigurable feature in
Settings under clearer categories, and verify the result with an automated and
visual UI pass.

## Decisions (from interview)

| Question | Decision |
|---|---|
| Minimum macOS | Raise from 14.0 to **26.0**; no pre-glass fallback path |
| Glass variant | **Regular** glass; accent tint only on the active/selected/primary element |
| Edge chrome | **Floating** — status line capsule, inset banner cards |
| Settings presentation | **In-window glass panel** with a category sidebar (keeps ⌘, overlay model) |
| New settings | Editor behaviour, status line, export defaults, workspace/launch/MCP — all four groups |

## Non-goals

- No change to the black base (`Palette.background` stays `#000000`), editor text
  rendering, Markdown highlighting, or document handling.
- No key rebinding, autosave-delay, highlighting-mode, layout-padding or MCP-port
  settings.
- No native `Settings` scene; the overlay and its motion controller stay.
- No Swift 6 language-mode migration (stays `SWIFT_VERSION: 5.9` on the new SDK).

## 1. Glass layer

New file `Clio/Design/Glass.swift` — the only place that calls `glassEffect`.

- `enum GlassShape { panel (16pt continuous), card (12pt), capsule, row (8pt) }`
- `View.clioGlass(_ shape: GlassShape, selected: Bool = false, interactive: Bool = false)`
  applies `.glassEffect(.regular[.tint(accent)][.interactive()], in: shape)`.
  The selected tint is the current accent at low strength, which reads over black
  without competing with text.
- `ClioGlassGroup` wraps `GlassEffectContainer(spacing:)` for surfaces with many glass
  children (sidebar rows, palette rows, settings category list) so adjacent shapes
  blend instead of stacking.
- Buttons: `.buttonStyle(.glass)` for secondary, `.glassProminent` (accent-tinted) for
  primary actions (Done, Restore, Resolve).
- Rule: **no glass on glass.** A glass surface's children use fills/tints, not a second
  `glassEffect`, except inside a `ClioGlassGroup`.
- `Palette` keeps its surface tokens for the editor; `backgroundRaised` is no longer used
  by chrome and is kept only where AppKit needs a solid colour.

## 2. Surface conversion

| Surface | File | Today | After |
|---|---|---|---|
| Window, editor view, scroll view | ContentView.swift:673, EditorView.swift:152-164, EditorTextView.swift:184 | solid black | **unchanged** |
| Minimap, block caret | LineMinimap.swift, EditorTextView.swift:154-174 | custom draw | **unchanged** (check overlap with capsule) |
| Sidebar | WorkspaceSidebar.swift:41-44, ContentView.swift:341 | `backgroundRaised` + hairline | inset floating `panel` glass (8pt from window edges, below titlebar); rows in `ClioGlassGroup`; selected row `row` glass `selected: true` |
| Titlebar sidebar button | ContentView.swift:801-819 | borderless NSButton | `NSGlassEffectView`-backed or `.glass` button so it matches the sidebar |
| Command palette / search | CommandPaletteView.swift:117-123 | `backgroundRaised`, hairline, heavy shadow | `panel` glass, drop manual shadow and hairline; highlighted row accent-tinted; folder picker and Show Ignored use glass controls |
| Modal scrim | ContentView.swift:256-265 | black 0.38 / 0.85 RT | unchanged values |
| Settings panel | ContentView.swift:292-308, SettingsView.swift | solid black, grouped form default fills | `panel` glass; see §3 |
| Conflict sheet | ContentView.swift:468-537 | solid black | `panel` glass; preview box stays solid black (it shows document text) |
| Conflict strip | ContentView.swift:246-255 | `backgroundRaised` | inset `card` glass at top |
| Detached / export-recovery / workspace-error banners | ContentView.swift:375-581 | full-width `backgroundRaised` + hairline | inset `card` glass, 12pt from top/sides, stacked with 8pt gap in one `ClioGlassGroup` |
| Status line | ContentView.swift:583-610 | full-width solid strip | bottom-centre `capsule` glass, content-sized, 10pt from bottom; the 0.65 opacity cap applies to the content, not the glass |
| Export toasts | DocumentExportPresentation.swift:777, :809 | `.regularMaterial` | `card` glass |
| Export options sheet | DocumentExportPresentation.swift:704 | system sheet | system sheet (glass from SDK); controls adopt glass button styles |
| Workspace setup | WorkspaceSetupView.swift | `.borderedProminent` / `.link` | `.glassProminent` / `.glass` over black |
| MCP window | ClioMCPService.swift:210-263 | separate light/dark NSWindow | **retired** (see §3) |
| Menus, alerts, NSOpen/SavePanel, NSPageLayout, font panel | various | system | system (glass from SDK, no code change) |

Motion: surfaces that fade via `opacity` today (sidebar, palette, settings, banners,
status line) keep their `MotionContract` timings. Where opacity-animating a glass
view shimmers or shows a flat frame, switch that surface to
`glassEffectTransition(.materialize)` driven by the same controller state. Reduce
Motion keeps the 80ms cap. Reduce Transparency: the system renders glass opaque; the
scrim keeps its 0.85 path.

Build: `project.yml` deployment targets (lines 7, 19, 38, 142) → `26.0`; regenerate
with XcodeGen; build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
Any `#available(macOS 14/15, *)` branches become unconditional.

## 3. Settings respec

### Structure

`SettingsView` becomes a two-column glass panel:
- Left: category list (SF Symbol + title) in a `ClioGlassGroup`, selected category
  accent-tinted. Last selected category persisted (`settings.lastCategory`).
- Right: one grouped `Form` per category, `.scrollContentBackground(.hidden)` so the
  panel's glass shows through; section fills use a subtle white overlay rather than
  the default grey so they read on glass-over-black.
- Header: title of current category + `Done` (`.glassProminent`).
- `SettingsView` is split into `Clio/App/Settings/` — one file per page plus
  `SettingsCategory.swift` — replacing the single 430-line file. Shared rows
  (`SliderRow`, `IntegerSliderRow`, font picker, accent swatch) move to
  `SettingsControls.swift`.
- Every control keeps or gains an `accessibilityIdentifier` (`settings.<page>.<control>`);
  existing identifiers (`settings.editorFont`, `settings.intelligence.*`) are preserved.

### Pages

**General** (`gearshape`)
- On launch: *Restore last session* (default, today's behaviour) / *Open a new document*
  — new pref `app.launchBehavior`, read by `LaunchConfiguration`.
- Show sidebar in new windows (default on) — `window.sidebarVisibleByDefault`.
- Pin sidebar in new windows (default off) — `window.sidebarPinnedByDefault`.
- Accent colour (moved from Appearance). **Fix:** `.amber` gets a distinct colour
  (`#FFB000`-class amber) instead of duplicating `.systemOrange`.

**Editor** (`textformat`)
- Font, size, measure, line height (moved from Typography).
- Caret: *Block* (default) / *Line* — `editor.caretStyle`.
- Show minimap (default on) — `editor.showsMinimap`.
- Status line: Show status line (default on) — `status.visible`; Show reading time
  (on) — `status.readingTime`; Show speaking time (on) — `status.speakingTime`.

**Writing** (`pencil.line`)
- Focus mode, typewriter scrolling + position, background text dimming, fade chrome
  while typing (moved from Focus).
- Hide pointer while typing (default on, only enabled when chrome fade is on) —
  `mode.hidesPointer`; decoupled from chrome fade in ContentView.swift:836-839.
- Check spelling (moved), Check grammar (default off) — `editor.grammarChecking`,
  Smart quotes and dashes (default off) — `editor.smartPunctuation`.
- Slash command palette (default on) — `editor.slashCommands`.
- Wrap selection when typing `* _ ~ \`` (default on) — `editor.autoWrapSelection`.

**Workspaces** (`folder`)
- Folders list + Use Documents/Clio + Add Folder…, authorization failures (moved).
- Recovery folder: path + *Change…* (calls existing recovery authorization flow,
  AppState.swift:2350) — previously only reachable from an error banner.
- Discovery rules, built-in exclusions, additional patterns (moved from Workspace Rules).

**Export** (`square.and.arrow.up`)
- Default format: PDF (default) / Word / Plain Text / HTML — `export.defaultFormat`,
  read by `DocumentExportPresentation` (line 248) instead of hardcoded `.pdf`.
- Page setup: summary (paper, orientation, margins) + *Page Setup…* + *Reset to
  Regional Default* (exposes `PDFPrintSettingsStore.resetToRegionalDefault()`).

**Assisted Commands** (`sparkles`)
- Unchanged content and copy.

**Local MCP** (`point.3.connected.trianglepath.dotted`)
- Enable, Open at login (label unified to "Open Clio at login without a window").
- Endpoint (read-only, copyable).
- Clients: list with Revoke; Folders: list with Remove / Add — the content of
  `MCPSettingsView` moved inline.
- The separate "Clio MCP" `NSWindow` is removed. `mcpService.showSettings()` and the
  menu-bar "MCP Settings…" item open (or focus) an editor window and present Settings on
  the Local MCP page.

### Persistence

Editor, Writing and status keys live in `EditorPreferences`; General/launch/window
and export-default keys go in a new sibling `AppPreferences` (same file pattern), both
 using the existing longhand `didSet` clamp-and-persist pattern. Defaults equal
current behaviour, so an upgrade changes nothing visible until the user changes a
setting. Each new key gets a unit test for default, round-trip and out-of-range /
unknown-raw-value load.

## 4. Testing

1. Unit tests: new preference tests; existing suite. Report executed-test count, not
   only failure count.
2. UI tests (ClioUITests): update for Settings category navigation and moved MCP UI; add
   one test per category that opens it and asserts a representative control exists; one
   test that toggles minimap and status line and asserts visibility. The two pre-existing
   failures (`testFullscreenMouseSelectionContextMenuAndReturnToWindow`,
   `testSidebarNewDocumentCancellationDoesNotAddATab`) are reported separately.
3. Visual pass: launch the built app and screenshot each surface — sidebar
   (temporary / pinned / hover), palette (centred / inline slash), every Settings page,
   each banner, conflict sheet, export sheet and toasts, workspace setup, full screen,
   minimum window size (480×400), Reduce Transparency on, Reduce Motion on.
4. Artifact checklist: glass-on-glass stacking, clipped corners or shadows, bright halos
   on black, text contrast on glass (WCAG AA for body text), fade shimmer / flat frames,
   minimap vs status capsule overlap, banner stacking overflow, sidebar vs traffic
   lights overlap.
5. Findings fixed, then reported with screenshots.

## Risks

- Glass over pure black has little to refract; if Regular reads too flat, lower the
  tint or add a faint white overlay inside `Glass.swift` — one place to tune.
- Opacity animation of glass can flash; mitigated by `glassEffectTransition`.
- Raising the minimum to 26 drops macOS 14–25 users from future builds (accepted).
- Retiring the MCP window touches menu-bar flows used without an open window.
