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
| `PARITY.md` | Feature matrix and known gaps |
