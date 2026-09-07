# MCP review repair workflow

Review baseline: v0.1.4 through main `522c5d0`. This repair pass covers all 11 review findings. The quit-lifecycle fix remains included. No existing release tag is moved, and this pass does not create a DMG/release tag.

## Ownership and integration

The coordinator owns discovery/performance, integration, and this evidence ledger. Three agent workstreams own shutdown diagnostics, bridge/project packaging, and literal editing/authority. Agents use narrow, non-overlapping edits; the coordinator reviews all cross-file contracts and regenerates the project after integration. A second agent reviews the integrated discovery/index changes.

All app compilation, signing, runtime tests, notarization, and DMG verification remain Xcode Cloud-only. Local verification is limited to source parsing, plist/XML/Python syntax inspection, generation stability, and diff checks.

| Finding | Owner | Repair and regression evidence to collect in Cloud |
| --- | --- | --- |
| 1. Ambiguous Quit command | Shutdown agent | Query the opened application menu; require exactly one match. Run menu quit with the menu-bar extra present. |
| 2. Fullscreen target/wait | Shutdown agent | UI-test-only stable window UUID and completed fullscreen-state marker. Run repeated multiwindow/fullscreen quit, without geometry assumptions. |
| 3. Bridge sandbox startup | Packaging agent | Embedded Info.plist in both Mach-O architectures; archive verifier checks metadata, signing and entitlements. Launch the signed packaged helper and complete MCP initialize/initialized/tools/list. |
| 4. Interactive shortcuts corrupt edits | Editing agent | Literal native replacement, undo grouping and slash bypass. `MarkdownEditingTests.testLiteralReplacementBypassesMarkersAndSlashButPreservesNativeUndo` covers markers, a different selected range, undo/redo and canonical edits. |
| 5. Moved-document edit authority | Editing agent | Recheck current workspace, session, canonical buffer and path at the non-suspending commit boundary. `MCPAccessTests.testFinalEditorAuthorityRejectsMoveWithoutTextRevisionChange`. |
| 6. Ineligible buffers break discovery | Coordinator | Handle oversized buffers as metadata-only listings, omit detached/out-of-scope buffers, propagate authorization failures. `MCPProtocolTests.testDiscoverySkipsDetachedAndOversizedBuffersWithoutLosingOtherResults`. |
| 7. Live search diverges | Coordinator | Reuse index query construction and SQLite FTS5 unicode61, indexing both filename and content in memory. Prefix, AND, diacritics, underscore, non-Latin and cross-field tests. |
| 8. Later-window untitled editor | Coordinator | Find the owning tab across all registered windows, focus it and revalidate scope each retry. `MCPProtocolTests.testUntitledEditorLookupFindsSecondWindow`; additionally exercise real open/select/edit against that window. |
| 9. Per-mutation full reindex | Coordinator | Apply committed path events/moves without external-buffer reconciliation or whole-catalog scanning for known deletes. Return `indexUpdatePending` if derived data updates fail after a successful write. Spy regressions assert incremental updates, no new rebuild. |
| 10. Quadratic revision lookup | Coordinator | Constant-time retained-buffer lookup; cleanup interval captured between amortized insertion scans. A 5,000-buffer regression checks stable tokens/no cleanup on reads and continued cleanup under churn. |
| 11. Generated project drift | Packaging agent | Regenerate with XcodeGen 2.46.0; repeated generation must be identical, and the committed project must pass the generation diff gate. |

## Verification sequence

1. Finish integration and source review, including privacy review of new metadata and test fixtures. Never commit user crash reports, credentials or raw production diagnostics.
2. Generate using `/opt/homebrew/bin/xcodegen generate` with version 2.46.0; repeat and compare output. Parse Swift sources without compiling/typechecking, lint plists, parse schemes/Python and run `git diff --check`.
3. Commit the complete repair together with the generated project. Do not run `scripts/test.sh` locally: it builds and executes tests. Publication/Cloud scheduling is a separate step, not implied by this document.
4. In Cloud, compile both Debug test products and the universal Release archive. Run Clio unit tests (including MCPAccessTests, MCPProtocolTests, MarkdownEditingTests and WorkspaceIndexTests). The narrow ClioMCPDiagnostics scheme alone does not include all editing/index regressions.
5. Run ClioShutdownDiagnostics on an unlocked Cloud VM. Capture exact commit/build IDs, test counts, menu targeting, fullscreen state and save/relaunch assertions. A missing OS crash-report directory is an explicit diagnostic coverage limitation, not proof that no crash occurred.
6. Validate the signed, embedded bridge on the packaged archive: both slices contain the expected metadata; initialization does not SIGTRAP. Exercise a stdio client against Clio with a separately approved token and workspace. Do not print the token in evidence.
7. Live acceptance: create/edit/read across two windows, open an oversized/detached buffer without breaking discovery, compare search before/after opening, rename/move/trash and observe incremental navigation updates. Test quit with unsaved edits and MCP connected; test cancelled quit if saving fails. Confirm no new unexpected-quit dialog.
8. Report Cloud/runtime outcomes and remaining limitations before any new version tag. Preserve the existing policy: UI test failures are advisory for internal releases; archive, signing, notarization and artifact verification remain required. Do not equate an advisory/green workflow with passing tests.

## Current evidence

- Source repairs and regression additions: integrated, pending Cloud verification.
- Local Swift syntax, project/bridge plist validation and diff whitespace checks: passed during integration.
- XcodeGen 2.46.0: generated canonical output; repeated generation checked before handoff.
- Cloud compilation, unit/UI results, signed bridge startup, quit-crash resolution and DMG: **not verified by this repair pass**.
- Runtime observations from the original review remain baseline evidence until replaced by results from the repaired commit.

Record follow-up results here using commit/build identifiers, exact failing test names and artifact references. Only mark a finding verified when its corresponding regression or acceptance check actually passes.

### Cloud follow-up: repair commit `84b9f65`

ClioMac build `04ea2171-7dd2-428d-80a8-b0365155a53f` completed Analyze and Archive successfully. The test action reported zero build errors and four test failures; its neutral status reflects the advisory policy, not passing tests:

- `MCPAccessTests.testPathScopeBlocksSymlinkAndSiblingPrefixEscape`: the missing destination `scope/escape/no.md` was incorrectly accepted when `escape` symlinked outside the approved root. This is a real boundary defect, requiring production hardening and another Cloud regression run.
- `NavigationSessionTests.testSlashCommandParserPreservesExportArgumentsAndQuotedValues`: stale assertion rejected DOCX after DOCX became supported. Check all supported formats positively and retain an unsupported-format rejection.
- `ClioNavigationUITests.testFullscreenMouseSelectionContextMenuAndReturnToWindow`: application-wide Copy lookup matched both the Edit menu and the text-view context menu. Scope to the editor's context menu, preserving the enabled/selection assertions.
- `ClioShutdownUITests.testFullscreenMultiwindowQuitSavesAndRelaunches`: the state marker existed but its accessibility label was empty. Expose the completed fullscreen state explicitly and assert that field; do not weaken the fullscreen requirement.

The successful non-tag archive does not establish notarization, packaged bridge startup, or DMG verification. The follow-up fixes need a fresh ClioMac run and shutdown diagnostics before closing these findings.
