# Local MCP (unreleased, verification pending)

Clio serves documents while the app is running, even with its editor windows
closed. Quit stops access. There is no independent background document daemon.
These instructions target the candidate branch, not the published 0.1.4 DMG.

## Authorize a local client

1. Open Clio → Settings → Local MCP → Manage clients and folders, or use the
   Clio menu-bar item → MCP Settings.
2. Enter a recognizable client name and explicitly select its workspace folders.
   Click **Authorize selected folders**. Add folders to Clio first if none appear.
3. Enable local MCP. Its endpoint is `http://127.0.0.1:19847/mcp`.
4. Configure the client using one of the methods below. No Apple notarization,
   GitHub, or LLM-provider API credential belongs in Clio MCP settings.

Authorization permits reads and writes, including unsaved text, within the
selected folders. Clio asks again only for deletion. Model/host software can add
its own prompts. Document text never grants authority or approves a deletion.

Tokens are stored in the local Keychain. “Copy token” and “Desktop config” are
explicit clipboard actions; Clio clears its unchanged clipboard after 60 seconds.
Treat copied configuration as a secret. Do not paste it into chats, commits,
screenshots, issue reports or public logs. Client configuration files may store
their token in plaintext: keep them private with owner-only file permissions.

## Claude Desktop / other stdio clients

Use **Desktop config** beside an authorized client to copy a configuration entry
containing the installed bridge path and that client's token. Merge the `clio`
entry into your existing `mcpServers` object, preserving other entries.

The shape is:

```json
{
  "mcpServers": {
    "clio": {
      "command": "/Applications/Clio.app/Contents/Helpers/ClioMCPBridge",
      "env": { "CLIO_MCP_TOKEN": "PASTE_YOUR_PRIVATE_CLIO_TOKEN_HERE" }
    }
  }
}
```

The actual app path may differ; the copied config uses the running app's path.
Restart/reconnect the client after configuring it. Keep Clio open. The adapter
does not start Clio, access files, or install a login agent. It forwards only to
the fixed loopback endpoint; redirects are refused so a token cannot be forwarded
to another host. Quit/pause/revocation requires reconnecting the client session.

Claude's local-server configuration is documented in the
[official local-server guide](https://modelcontextprotocol.io/docs/develop/connect-local-servers).
Actual signed Claude Desktop interoperability is still to be smoke-tested.

## Claude Code / Streamable HTTP clients

Configure Streamable HTTP, the loopback URL, and an `Authorization: Bearer …`
header using the private token. Claude Code supports HTTP with a `--header`:

```sh
claude mcp add --transport http clio http://127.0.0.1:19847/mcp \
  --header "Authorization: Bearer YOUR_PRIVATE_CLIO_TOKEN"
```

That is a placeholder, not a credential. Avoid entering a real token in shell
history; use your client's secure/local configuration facilities or the stdio
entry above. See [Claude Code's MCP documentation](https://code.claude.com/docs/en/mcp).
Do not use a hosted/custom-connector URL setting for this localhost endpoint.

## Other services

Local clients that support stdio or the negotiated HTTP versions can use the
same adapters. Hosted services cannot generally reach this Mac's loopback
interface. No tunnel, LAN listener, remote OAuth endpoint, or universal client
compatibility is included. Hosted access needs a separately approved design.

## Tool behavior

- Start with `list_workspaces`, then `list_documents` or `search_documents`.
- Reads return a revision and optional UTF-16 continuation offset. Supply the
  same revision when continuing; if typing changed it, restart the read.
- Changes require the returned revision plus a fresh UUID `mutationID`. Reuse
  that UUID only when retrying the identical operation after a lost response.
  A new intent needs a new UUID. Stale edits return the current revision.
- `edit_document` uses native text editing and Undo. `select_text` uses UTF-16
  offsets. Composed-character/emoji boundaries are validated.
- `move_document` covers rename and move. Destinations are never overwritten.
  Creation keeps both names on collision and reports the actual filename.
- `trash_document` presents native confirmation naming the document and client;
  it expires after 60 seconds and is checked against the revision again.
- `export_document` accepts `pdf`, `html`, `docx`, or `txt`; it exports the requested
  snapshot, not subsequent typing, and refuses an existing destination.
- A pending save is reported as pending, not durable. A conflict is not silently
  resolved. Search is batched and reports whether workspace indexing is complete.

For initial size/location limits, see [the implementation plan](local-mcp-plan.md).

## Cloud and acceptance checklist

Use `feature/local-mcp`, scheme `ClioMCPDiagnostics`, macOS Test, Required to Pass,
no retries, no distribution. The test target includes 14 policy/protocol tests;
it does not register login items, use real Keychain credentials, or open a listener.
Then run the full Clio regression suite. All builds and tests stay in Xcode Cloud.

Before merge/release, verify a Cloud-built, signed candidate with a disposable
workspace and record client version, macOS version and results:

- HTTP and stdio initialize/list/read work; a wrong/revoked token cannot read.
- Unsaved typing is returned; stale/emoji edits fail safely; accepted edits Undo
  and autosave; switching tabs during a request never edits the wrong document.
- Create empty/nonempty files; retry one create; rename/move collisions preserve
  both files. Approve/cancel/timeout trash; edit during approval rejects deletion.
- All four exports open correctly; retries/collisions do not overwrite output.
- Pause/revoke while operations run; reconnect; verify no new access is admitted.
- Close every window, read a document, reopen the editor, then quit with pending
  edits/exports and connected clients. Relaunch and verify persistence and no
  crash/sanitizer report. Include the independently verified shutdown repair.
- Opt in/out of login; check OS approval state; login starts without an editor
  window; the menu opens an editor; ordinary launch/restoration still works.
- Verify the embedded bridge is universal, Developer ID signed, sandboxed with
  outbound-network only, and included in successful notarization/stapling checks.

No test pass, signed client compatibility, login behavior, or release acceptance
is claimed until those checks have actually run.
