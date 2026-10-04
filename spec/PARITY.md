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
| Editor: highlighting, focus, typewriter, minimap | done | planned | Windows: custom DirectWrite control |
| Export PDF/HTML/DOCX/TXT | done | planned | |
| Local MCP | done | planned | Windows: Credential Manager, `clio-mcp-bridge.exe`, tray toggle, default off |
| Assisted commands / paste formatting | done | planned | |
| Security-scoped bookmarks | done | n/a | |
| Liquid Glass | done | n/a | Windows: black canvas, Mica chrome |
