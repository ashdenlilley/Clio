# Parity matrix

Legend: done, partial, planned, n/a (platform does not need it).

| Area | macOS | Windows | Notes |
| --- | --- | --- | --- |
| Document load/save, BOM, line endings | done | partial | Windows: vectors in `spec/vectors` |
| Atomic save + transaction manifest | done | done | Windows: manifest, then `ReplaceFileW` with the old file kept as a displaced sibling (macOS keeps it in the temp slot). No directory fsync on Windows. Vector: `atomic-write-recovery.json` |
| Crash recovery journal | done | done | JSON records under `%LOCALAPPDATA%\Clio\Crash Recovery`; vector: `recovery-journal.json`. Not yet called by the app: autosave and external-edit flows come with phase 2 |
| Document identity store | done | partial | Core store ported (file id from `FILE_ID_INFO`, case-folded locators); vector: `document-identity.json`. Not yet used by the scanner or search index |
| Move transactions | done | partial | Manifest, quarantine and recovery ported (`move-recovery.json`). The `DocumentMover` flow that drives them is not ported |
| Safe file names | done | done | Windows adds reserved names, illegal characters, trailing dots, 255 cap; vector: `file-names.json` |
| Revision digest (SHA-256) | done | partial | Same vectors |
| Workspace scan + .gitignore | done | partial | |
| Workspace watcher | done (FSEvents) | planned | |
| Search index (SQLite FTS5) | done | planned | 500-match cap |
| Recovery copies, 7 days | done | partial | `RecoveryStore` ported, vector `recovery-store.json`. No caller until conflict resolution and the mover are ported |
| Editor: focus, typewriter, minimap, selection, undo | done | partial | Windows: `Clio.Editor` logic + Win2D `EditorControl`; shares `focus-ranges.json` |
| Editor: Markdown highlighting (Full and Reduced modes) | done | partial | Windows: lexer ported, Markdig for emphasis/strong/strikethrough; shares `markdown-highlight.json`, which the macOS suite does not read yet. No safe-large-file semantic chunking; Foundation line separators (U+2028/2029/0085) are not line breaks |
| Editor: incremental re-highlight | done | done | Windows: IncrementalHighlighter, always equal to a full highlight (seeded fuzz over the conformance fixtures). Deviations from the macOS policy, which cannot see them: fences, front matter and footnotes spanning blank lines, indented islands, edits in leading whitespace, link reference definitions and ~ all force a full reparse. The macOS policy has the same blind spots |
| Editor: IME composition | done | partial | Windows: proxy `TextBox` inside `EditorControl`, not `CoreTextEditContext`. No Windows App SDK package ships a window-based text service (`Microsoft.UI.Text.Core`), and the Windows SDK type needs a CoreWindow; a window-handle interop entry exists in the SDK but its header is not available to port from. Not yet tested with a real IME |
| Editor: slash commands and command palette | done | partial | Windows: logic in `Clio.Editor.Commands`, vector `slash-commands.json` (the macOS suite does not read it yet). Ctrl+K and a typed `/` open the palette. Wired commands: open, folder, reveal, focus, typewriter, sidebar. new, rename, delete, search, export and settings wait for phases 2 and 4. Workspace search mode of the palette waits for phase 2 |
| Editor: UI Automation | done | partial | Windows: Document element with a Text pattern (units, move, endpoints, find, select, point and rectangles) served by the IME proxy peer; checked against a live UIA client. No text attributes beyond font name and read-only, no ITextEditProvider, not tried with Narrator |
| Editor: high contrast | done | partial | Windows: system colours, hue-coded roles collapse to text colour, links underlined, selection uses highlight text. Polled every 1.5 s because the high-contrast change event cannot be subscribed to unpackaged. Not seen under a real high-contrast theme |
| Export PDF/HTML/DOCX/TXT | done | planned | |
| Local MCP | done | planned | Windows: Credential Manager, `clio-mcp-bridge.exe`, tray toggle, default off |
| Assisted commands / paste formatting | done | planned | |
| Security-scoped bookmarks | done | n/a | |
| Liquid Glass | done | n/a | Windows: black canvas, Mica chrome |
