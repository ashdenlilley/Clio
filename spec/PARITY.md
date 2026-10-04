# Parity matrix

Legend: done, partial, planned, n/a (platform does not need it).

| Area | macOS | Windows | Notes |
| --- | --- | --- | --- |
| Document load/save, BOM, line endings | done | partial | Windows: vectors in `spec/vectors` |
| Atomic save | done | partial | Windows uses `ReplaceFileW`; macOS uses transaction manifest + swap. Windows has no manifest/recovery journal yet |
| Revision digest (SHA-256) | done | partial | Same vectors |
| Workspace scan + .gitignore | done | partial | |
| Workspace watcher | done (FSEvents) | planned | |
| Search index (SQLite FTS5) | done | planned | 500-match cap |
| Recovery copies, 7 days | done | planned | |
| Editor: focus, typewriter, minimap, selection, undo | done | partial | Windows: `Clio.Editor` logic + Win2D `EditorControl`; shares `focus-ranges.json` |
| Editor: Markdown highlighting (Full and Reduced modes) | done | partial | Windows: lexer ported, Markdig for emphasis/strong/strikethrough; shares `markdown-highlight.json`, which the macOS suite does not read yet. No incremental re-highlight, no safe-large-file semantic chunking, Foundation line separators (U+2028/2029/0085) are not line breaks |
| Editor: IME composition | done | partial | Windows: proxy `TextBox` inside `EditorControl`, not `CoreTextEditContext`; not yet tested with a real IME |
| Editor: UI Automation, slash commands, palette | done | planned | Remaining phase 3 items |
| Export PDF/HTML/DOCX/TXT | done | planned | |
| Local MCP | done | planned | Windows: Credential Manager, `clio-mcp-bridge.exe`, tray toggle, default off |
| Assisted commands / paste formatting | done | planned | |
| Security-scoped bookmarks | done | n/a | |
| Liquid Glass | done | n/a | Windows: black canvas, Mica chrome |
