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
| Editor: highlighting, IME, UI Automation, slash commands, palette | done | planned | Remaining phase 3 items |
| Export PDF/HTML/DOCX/TXT | done | planned | |
| Local MCP | done | planned | Windows: Credential Manager, `clio-mcp-bridge.exe`, tray toggle, default off |
| Assisted commands / paste formatting | done | planned | |
| Security-scoped bookmarks | done | n/a | |
| Liquid Glass | done | n/a | Windows: black canvas, Mica chrome |
