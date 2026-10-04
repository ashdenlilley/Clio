# Clio cross-platform spec

The macOS app (`Clio/`) and the Windows app (`windows/`) are separate native
codebases. This directory is the contract they share, so behaviour that touches
user data cannot drift between them.

## Rules

1. **Spec first.** A change to document I/O, revisions, workspace scanning,
   search limits, recovery, export or MCP starts here, then lands in both apps.
   If one platform cannot follow yet, record the gap in `PARITY.md`.
2. **One source of truth per fixture.** Vectors live in `spec/vectors`.
   Markdown conformance fixtures stay in `ClioTests/Fixtures/Markdown/Conformance`;
   the Windows tests read that directory directly. Never copy fixtures.
3. **Each platform tests the same vectors** with its own test runner
   (XCTest on macOS, xUnit on Windows). A vector change that breaks either
   suite blocks both.
4. **Platform-only behaviour is allowed** (Liquid Glass, Mica, Keychain,
   Credential Manager) but must be listed in `PARITY.md`.

## Contents

| Path | Contract |
| --- | --- |
| `vectors/revision-digest.json` | Content digest = lowercase hex SHA-256 of the raw file bytes |
| `vectors/line-endings.json` | BOM and CRLF/LF detection and round-trip rules |
| `vectors/file-names.json` | Safe file names; Windows-only hardening is listed separately |
| `vectors/recovery-store.json` | Recovery copy naming, collision suffixes, 7-day retention |
| `vectors/atomic-write-recovery.json` | Recovery decision table for interrupted atomic writes |
| `vectors/recovery-journal.json` | Crash journal supersede, clear and coalescing rules |
| `vectors/move-recovery.json` | Recovery decision table for interrupted moves |
| `vectors/document-identity.json` | Document identity across rename, delete, replace and overlapping roots |
| `vectors/workspace-snapshot-diff.json` | Watcher snapshot diff: replace, move, modify, delete, create pairing |
| `vectors/search-queries.json` | Search term splitting, FTS query, LIKE escaping, result limits, batch behaviour |
| `vectors/document-move.json` | Mover naming, collision choices, replace approval, path rejection |
| `vectors/external-change.json` | Reconcile, save and conflict-resolution outcomes for an open document |
| `vectors/export-policy.json` | Export: safe links, HTML escaping, footnote ids, PDF print geometry and regional paper defaults, plain-text projection |
| `vectors/slash-commands.json` | Slash command parsing, palette filtering and state, inline-slash trigger, palette placement |
| `vectors/mcp-access.json` | Local MCP loopback policy, UTF-16 edit boundaries, authorization lifecycle, retry ledger, one-shot deletion approval, path scope |
| `vectors/mcp-protocol.json` | Local MCP HTTP framing, version negotiation, tool catalogue and schema rules, session flow, client config shapes |
| `PARITY.md` | Feature matrix and known gaps |
