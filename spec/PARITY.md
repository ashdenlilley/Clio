# Parity matrix

Legend: done, partial, planned, n/a (platform does not need it).

| Area | macOS | Windows | Notes |
| --- | --- | --- | --- |
| Document load/save, BOM, line endings | done | partial | Windows: vectors in `spec/vectors` |
| Atomic save + transaction manifest | done | done | Windows: manifest, then `ReplaceFileW` with the old file kept as a displaced sibling (macOS keeps it in the temp slot). No directory fsync on Windows. Vector: `atomic-write-recovery.json` |
| Crash recovery journal | done | done | JSON records under `%LOCALAPPDATA%\Clio\Crash Recovery`; vector: `recovery-journal.json`. Not yet called by the app: autosave and external-edit flows come with phase 2 |
| Document identity store | done | partial | Core store ported (file id from `FILE_ID_INFO`, case-folded locators); vector: `document-identity.json`. Used by `WorkspaceScanner.ScanFiles` and the search index |
| Move transactions + `DocumentMover` | done | done | Manifest, quarantine and recovery (`move-recovery.json`); `DocumentMover` drives them with collision choices, replace approval, identity migration and Recycle Bin delete (`document-move.json`). Buffer settling and displaced-buffer recovery stay with the caller. Not wired into the app yet |
| Safe file names | done | done | Windows adds reserved names, illegal characters, trailing dots, 255 cap; vector: `file-names.json` |
| Revision digest (SHA-256) | done | partial | Same vectors |
| Workspace scan + .gitignore | done | partial | |
| Workspace watcher | done (FSEvents) | done | Windows: `FileSystemWatcher` (ReadDirectoryChangesW) + 200 ms root liveness timer + snapshot diff (`workspace-snapshot-diff.json`); deletions confirmed after 120 ms because swap-style saves briefly remove the path. Not wired into the app yet |
| Search index (SQLite FTS5) | done | partial | Windows: `SearchIndex` on `Microsoft.Data.Sqlite`, 500-match cap, progressive batches; vector `search-queries.json`. Not yet ported: ignored-file tier and discovery policy; text files off by default |
| Recovery copies, 7 days | done | partial | `RecoveryStore` ported, vector `recovery-store.json`. No caller until conflict resolution and the mover are ported |
| Editor: focus, typewriter, minimap, selection, undo | done | partial | Windows: `Clio.Editor` logic + Win2D `EditorControl`; shares `focus-ranges.json` |
| Editor: Markdown highlighting (Full and Reduced modes) | done | partial | Windows: lexer ported, Markdig for emphasis/strong/strikethrough; shares `markdown-highlight.json`, which the macOS suite does not read yet. No incremental re-highlight, no safe-large-file semantic chunking, Foundation line separators (U+2028/2029/0085) are not line breaks |
| Editor: IME composition | done | partial | Windows: proxy `TextBox` inside `EditorControl`, not `CoreTextEditContext`; not yet tested with a real IME |
| Editor: UI Automation, slash commands, palette | done | planned | Remaining phase 3 items |
| Export PDF/HTML/DOCX/TXT | done | planned | |
| Local MCP | done | planned | Windows: Credential Manager, `clio-mcp-bridge.exe`, tray toggle, default off |
| Assisted commands / paste formatting | done | planned | |
| Security-scoped bookmarks | done | n/a | |
| Liquid Glass | done | n/a | Windows: black canvas, Mica chrome |
