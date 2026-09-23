# Changelog

All notable changes to Clio are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Clio uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Only canonical
`vMAJOR.MINOR.PATCH` tags publish a release.

## [Unreleased]

### Added

- **Liquid Glass chrome.** The sidebar, command palette, workspace search,
  Settings, and the export and conflict sheets now sit on macOS 26's Liquid
  Glass over a black window, instead of flat raised panels. Only
  `Clio/Design/Glass.swift` calls the system glass APIs, so every surface's
  material stays consistent and tunable in one place.
- **Categorised Settings.** Settings is now split into General, Editor,
  Writing, Workspaces, Export, Assisted Commands and Local MCP pages, each
  reachable from a category sidebar, and exposes several previously
  unreachable preferences (grammar checking, smart punctuation, minimap and
  status-line toggles, discovery exclusions, and more) alongside the
  existing ones.
- Local MCP client and folder management moved out of its own window and
  into Settings → **Local MCP**, next to the rest of Clio's preferences.

### Changed

- **Minimum macOS raised to 26.** This drops support for macOS 14 through 25;
  Liquid Glass has no fallback rendering path for earlier systems.

## [1.0.0] - 2026-09-20

First stable release. Clio is a local-first Markdown writing app for macOS: your
documents stay plain `.md` files in folders you control.

### Added

- **Assisted commands.** When what you type into the command bar matches no
  command name, Clio reads the request and offers the commands that fit —
  "send this to my editor in Word" reaches `/export docx`. It ranks and
  preselects; nothing runs until you choose it.
- **Paste formatting.** Plain text pasted with its Markdown stripped — hard
  wrapped mid-sentence, no headings, no bullets — has its structure rebuilt.
  The reformatting is a separate undo step from the paste.
- Both features are powered by [TypeSafe](https://docs.typesafe.ai), are off
  until you enable them in Settings and add your own API key, and fall back to
  Clio's local behaviour when off or offline. See
  [assisted commands](docs/assisted-commands.md) for exactly what each sends.
- Settings gained an **Assisted Commands** section with key entry, a **Check**
  button that verifies the key against the API, and **Remove**.

### Changed

- `com.apple.security.network.client` is now present in the sandbox. It is used
  only by `IntelligenceService`, which refuses to build a request while the
  feature is off or no key is stored. Every other part of Clio remains offline.
- Presentation preferences moved out of `AppState` into `EditorPreferences`,
  which clamps every value on assignment as well as on load. A font size or
  measure written by an older build, a defaults import or `defaults write` can
  no longer drive the editor out of range.
- The command palette's own substring matching is memoized, so an open palette
  no longer repeats locale-aware comparisons once per row per frame.

### Fixed

- The MCP router no longer force-casts a tool's `inputSchema`. A malformed
  definition answers `-32602` instead of trapping the app — that is the one
  code path fed by a connected client.
- The crash-recovery subprocess test now derives its shared root from
  `NSTemporaryDirectory()`, which resolves to the app container under a signed
  sandboxed host and to an ordinary temporary directory otherwise. It named the
  physical container path before, which only an app that owns that container may
  write to, so the test failed on unsigned local runs.

### Known limitations

- Assisted commands and paste formatting have been verified against recorded
  payloads and a stubbed transport. Their behaviour against the live TypeSafe
  API depends on your key and your documents; check the results on your own
  writing before relying on them.
- Internal and pre-release builds remain evaluation builds. Keep independent
  backups of anything important.

## [0.1.0] - [0.1.9]

Pre-1.0 development builds, published as internal testing and pre-release only.
Over this line Clio gained its source-preserving Markdown editor and
highlighting, the vertical document sidebar and separate windows, workspace
search across bookmarked folders, PDF/HTML/Word/text export, focus dimming,
typewriter scrolling and the document minimap, autosave with external-edit
conflict handling and recovery copies, crash-recovery journalling with atomic
writes, and a local MCP bridge. Release notes for those builds are on their
[GitHub releases](https://github.com/ashdenlilley/Clio/releases).
