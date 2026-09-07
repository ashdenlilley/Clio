# Local MCP integration — implementation plan

Status: implementation in progress on `feature/local-mcp`; not available to clients
yet. Keep separate from shutdown repair. Hosted connectivity deferred by default.

## Implementation checkpoint

Implemented, pending Xcode Cloud verification:

- Default-off client/workspace authorization with token digests, revocation,
  pause/resume invalidation, and shutdown invalidation.
- Loopback Host/Origin/request-size policy (no HTTP listener yet).
- Live, settled, paginated reads through DocumentBufferRegistry. Continuation
  pages require a matching revision; pending saves/conflicts are explicit.
- Process/buffer-incarnation revision tokens, Unicode-safe replacement candidate
  validation, and canonical workspace path checks including symlink escapes.
- Bounded, per-client mutation retry ledger and native-only, expiring, one-shot
  deletion approval primitive. Neither is exposed as a tool.
- Eight `MCPAccessTests` and the shared `ClioMCPDiagnostics` Cloud test scheme.

Not implemented yet (not a usable MCP server):

- HTTP parsing/listener, protocol router/negotiation, sessions and cancellation.
- Keychain-backed credential provisioning and native client/workspace approvals.
- Tool adapters for discovery/search, undo-aware edits, create/rename/move/trash,
  export, active document/selection, and UI navigation. Untitled documents are
  deliberately not accessible through the initial read adapter.
- Settings/menu-bar controls, login registration, windowless startup and quit
  integration, and client connection guides/smoke tests.

No listener, sandbox entitlement expansion, login registration, tunnel, release
tag, or changes to the shutdown comparison branches are included in this slice.

### Cloud verification for this checkpoint

Use branch `feature/local-mcp`, scheme `ClioMCPDiagnostics`, macOS Test action,
Required to Pass, no retries, no archive/distribution action. No MCP or release
secrets are needed by these tests; retain any existing repository preflight
configuration required by `ci_post_clone.sh`. The scheme is committed on this
branch, not on `main`; let Xcode discover it from the branch checkout first.

Local checks are source/project syntax only. Cloud compilation and test execution
remain required; no client interoperability or clean shutdown claim follows from
these foundation tests alone. Run full Clio regression tests before merging.

## Product requirements

- Serve while Clio's process is open, including with no editor windows. Quit
  stops the server. No separate always-running helper bundle.
- Optional open-at-login starts Clio windowless with a menu-bar item. Expose the
  login toggle in both Settings and the menu bar; reflect macOS approval state.
- Menu-bar controls: server status, pause/resume, open editor, Settings, login
  toggle, connected clients, revoke access, and Quit Clio.
- Clients: Claude Desktop, Claude Code, ChatGPT, and other compatible MCP clients.
  Verify each actual client/transport separately; do not promise universal access.
- Approved workspace scope only. List/search/read live documents; create/edit,
  rename/move; trash with recovery; PDF/HTML/DOCX/TXT export; active document,
  selection, and navigation tools.
- After initial client/workspace authorization, only deletion needs confirmation.
  Deletion confirmation opens Clio UI even in windowless mode, identifies exact
  documents and requesting client, expires, and cannot be approved by an MCP tool.
- Edits use current live buffers, revision preconditions, undo and existing atomic
  autosave/conflict handling. Stale edits fail with the current revision; never
  overwrite newer typing. Writes returning before disk save report that explicitly.

## Architecture and safety

1. Add app-owned service lifecycle and optional native login registration. Do not
   register login automatically or couple server enablement to an editor window.
2. Add loopback-only Streamable HTTP transport, protocol negotiation, bounded
   requests, cancellation and session isolation. Validate Host/Origin, authenticate
   clients, store credentials in Keychain, and support revocation. No unauthenticated
   localhost listener, LAN binding, shell execution, or arbitrary-path tools.
3. Route tools into Clio's document registry/index/export services rather than
   editing backing files directly. Identify documents/workspaces by stable IDs.
   Block traversal and symlink escapes; preserve destination collision checks.
4. Implement paginated reads/search and bounded UTF-16 edits with revision tokens.
   Treat document contents as data, never permission or executable instructions.
5. Implement create/rename/move, export, UI navigation, and confirmed recoverable
   trash. Retries use idempotency keys so a repeated request cannot duplicate edits
   or delete twice. Revalidate deletion revision and scope after approval.
6. Provide client-specific setup. Local clients can use the local transport;
   stdio-only clients may need a client-launched bridge packaged inside Clio, not a
   second service. Validate this need before selecting an adapter.
7. Hosted ChatGPT/other cloud clients may need a separately approved authenticated
   tunnel/relay. Do not expose Clio remotely or install a tunnel without owner
   approval. Document the difference between local desktop and hosted clients.

## Verification and delivery

- Cloud unit/integration tests for auth/revocation, origin checks, scope escapes,
  Unicode revisions, concurrent typing, cancellation, retry safety, trash approval,
  exports, save errors, and no-window process lifetime.
- UI tests for menu-bar controls, login state, foreground confirmation, reopening
  a window, and clean quit with connected clients and pending writes.
- Client smoke tests with disposable documents in each supported client. Record
  exact versions/transports and approval behaviour; host policies may add prompts.
- No document contents or credentials in public logs, manifests or release assets.
- Ship only after the shutdown repair is verified. Retain existing Cloud-only
  build, signing, notarization and DMG upload workflow.

## References

- MCP transport/security: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports
- Claude Code MCP: https://code.claude.com/docs/en/mcp
- OpenAI local/hosted client distinction: https://learn.chatgpt.com/docs/extend/mcp

One remaining deployment choice: whether hosted-client access should be included
via an opt-in secure tunnel, or deferred while local client integrations ship.
