# Windows 11 port: build workflow

Status: in progress on `feature/windows-port`. The macOS app stays the reference
implementation. The Windows app lives in `windows/`, shares no Swift code, and
shares behaviour contracts through [`spec/`](../spec/README.md).

## Decisions

| Topic | Decision |
| --- | --- |
| Stack | Fully native: WinUI 3 (Windows App SDK 2.x), C# on .NET 10, unpackaged, self-contained |
| Editor | Custom text control on DirectWrite/Win2D. No WebView, no stock `TextBox` beyond the interim placeholder |
| Platform | Windows 11 only (22000+), x64 only |
| Look | Pure black editor canvas; Mica Alt chrome and title bar; bundled Hack font for body and code; 240 px document sidebar |
| Distribution | GitHub Releases only; unsigned builds |
| MCP | Included. Claude Desktop and Claude Code supported, default off, tray toggle, optional login autostart, Credential Manager secrets, `clio-mcp-bridge.exe` stdio-to-HTTP bridge |
| Tandem | `spec/` holds shared vectors and a parity matrix; both apps test against the same vectors; spec changes land first |
| Search | SQLite FTS5 via `Microsoft.Data.Sqlite` |
| Markdown | Markdig for parse/export; source-preserving highlighter ported to the same conformance fixtures as macOS |

Risk accepted: a fully native editor means hand-building IME composition,
selection, undo, accessibility (UI Automation text provider) and scrolling.
Phase 3 is the largest single item and is gated by its own acceptance list.

## Solution layout

| Project | Role |
| --- | --- |
| `windows/Clio.Core` | Platform logic: atomic save, document I/O, scanner, later watcher, recovery, search, MCP |
| `windows/Clio.Core.Tests` | xUnit; reads `spec/vectors` and `ClioTests/Fixtures/Markdown/Conformance` directly |
| `windows/Clio.Editor` | Pure editor logic: text buffer, undo, selection, focus ranges, minimap, typewriter math |
| `windows/Clio.Editor.Tests` | xUnit; reads `spec/vectors/focus-ranges.json` |
| `windows/Clio.App` | WinUI 3 app |
| `scripts/windows-build.ps1` | Gate: build (warnings as errors), test, publish |

## Phases

A phase is done only when its acceptance checks pass and `spec/PARITY.md` is updated.

0. **Scaffold.** Done.
1. **Files and workspace core.** Done: atomic save with transaction manifest and
   recovery, BOM/CRLF, SHA-256 revisions, scanner with nested `.gitignore`, crash
   recovery journal, 7-day recovery copies, document identity store, move
   transactions, safe file names.
2. **Workspace UX.** Core services done and tested, UI not yet wired:
   `WorkspaceWatcher` (ReadDirectoryChangesW, file-ID snapshot diff keeps move
   semantics), `SearchIndex` (SQLite FTS5, 500-match cap), `DocumentMover`,
   `DocumentSession`/`DocumentService` (save, external-change reconcile, conflict
   resolution), `Autosaver`, `StartupRecovery`, identity-aware scanning.
   Remaining: tabs and multiple windows, new/rename/move UI, external-edit conflict
   UI, search UI, discovery policy and ignored-file tier, `.md` association (opt-in),
   and calling all of the above from `Clio.App`.
3. **Native editor.** DirectWrite text control: source-preserving highlighting,
   focus dimming (blank-line rule from commit `1a08c6b`), typewriter scrolling,
   minimap, slash commands, Ctrl+K palette, IME, UI Automation, high contrast.
   Done: highlighting (incremental), focus, typewriter, minimap, slash commands and palette
   logic and UI, UI Automation Text pattern, high-contrast palette, IME through a proxy
   control. Open: `CoreTextEditContext`, UI Automation text attributes and editing, a
   real IME and Narrator pass, wiring the remaining palette commands (phases 2 and 4).
4. **Export.** PDF, self-contained HTML, `.docx`, `.txt`; golden-file tests.
5. **Settings and optional network features.** Assisted commands and paste
   formatting, off by default, key in Credential Manager.
6. **Local MCP.** Port `Clio/MCP` to the limits in `docs/local-mcp-plan.md`:
   loopback HTTP, per-client authorization, one-shot deletion approval, protocol
   versions 2025-03-26, 2025-06-18, 2025-11-25. Tray icon toggle. Bridge exe.
7. **Release.** x64 zip and installer on GitHub Releases, unsigned, SmartScreen
   warning documented, Windows section in `docs/releasing.md`, clean-VM install test.

## Mac-to-Windows mapping

| macOS | Windows |
| --- | --- |
| Security-scoped bookmarks | Plain paths; user-chosen folders in settings |
| FSEvents + vnode root watch | `ReadDirectoryChangesW` + root-handle liveness + snapshot diff |
| Keychain | Credential Manager |
| SMAppService | Run key |
| Menu bar extra | Tray icon |
| Liquid Glass | Mica Alt; black editor canvas |
| iCloud Documents | OneDrive known-folder redirection; placeholders treated as offline |
| Xcode Cloud | GitHub Actions `windows-latest` |

## Working rules

- Read the Swift source and its tests before porting. Port tests with the code.
- Anything touching user data gets a vector in `spec/vectors` first.
- Never test against real documents. Use temp directories.
- Test every file feature against long paths, reserved names (`CON`, `NUL`),
  trailing dots, case-insensitive collisions, UNC paths, junctions, locked files.
- Keep `Clio/Resources/THIRD-PARTY-NOTICES.md` current for every NuGet package.
- No merge to `main` without the owner's approval.
