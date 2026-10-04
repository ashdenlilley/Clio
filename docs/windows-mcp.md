# Local MCP on Windows

Status: library, listener, router, tools, credential storage, client config and the
stdio bridge are implemented and tested, and the app side is wired: `AppMcpHost` (the
live-document host), the tray icon, the Local MCP settings section, opt-in login autostart and
clipboard clearing. No Claude client has been smoke-tested yet; the app and the real bridge were
driven against a temporary folder (see the checklist at the end).
The macOS behaviour and limits in [local-mcp-plan.md](local-mcp-plan.md) and
[local-mcp-setup.md](local-mcp-setup.md) are the reference; the shared contract is
`spec/vectors/mcp-access.json` and `spec/vectors/mcp-protocol.json`.

## Pieces

| Project | Role |
| --- | --- |
| `windows/Clio.Mcp` | UI-free server: loopback policy, HTTP framing and listener, JSON-RPC router, the twelve tools, authorization, retry ledger, deletion approvals, Credential Manager storage, client config snippets |
| `windows/Clio.McpBridge` | `clio-mcp-bridge.exe`, a client-launched stdio-to-HTTP adapter shipped next to `Clio.exe` |
| `windows/Clio.Mcp.Tests` | xUnit; reads both vectors; includes real sockets, junctions and Credential Manager |

## What the app implements

`IMcpHost` is the app side. Everything about the protocol and authorization stays in the
library; the host works on live buffers and native UI:

- `SnapshotAsync` settles pending editor edits, then returns the live text and a revision
  from `McpRevisionTracker`.
- `ReplaceAsync` applies an edit through the editor with undo and autosave, using
  `McpTextReplacement.Applying` to produce the candidate. It rejects a stale revision with
  `McpToolFailure("stale_revision", {currentRevision})`.
- `ConfirmDeletionAsync` is a native prompt naming the document and the client. It must work with
  no editor window, expire after 60 seconds and return false on cancel. Nothing a client sends can
  complete it.
- Every call receives an `McpAuthority`. Call `Validate(workspaceId)` after each `await` and before
  touching a buffer, so pause, revoke and quit end work in flight.
- Use `McpWorkspaceBoundary.Validate(path, workspaceRoot)` before any file operation. It rejects
  `..`, device and extended paths, alternate data streams, and every junction or symlink inside the
  root, and it resolves links above the root.
- Resolve name collisions case-insensitively and never replace a destination.

Wire it up with `McpService`:

```csharp
var store = new CredentialMcpClientStore(new WindowsCredentialVault(), CredentialMcpClientStore.DefaultMetadataPath);
var mcp = new McpService(host, store);   // default off; touches nothing
mcp.StartConfigured();                    // starts only if the owner enabled it before
mcp.Changed += () => dispatcher.TryEnqueue(RefreshTray);
// Tray / settings: mcp.SetEnabled, AddClient, Revoke, Clients, Status, ConnectedSessions, ErrorMessage
// On quit, before the save gate: mcp.QuiesceForQuit();
```

Tokens reach the clipboard only through `TokenText`, `DesktopConfig` and `ClaudeCodeConfig`.
Clear the clipboard after 60 seconds, as on macOS.

## Authorize a client

1. In Clio, open Settings, Local MCP. Name the client and choose its workspace folders.
2. Switch MCP on. The endpoint is `http://127.0.0.1:19847/mcp`. Clio listens on the IPv4 loopback
   only, never a LAN address.
3. Configure the client.

### Claude Desktop (stdio)

Use the bridge. `McpService.WriteClaudeDesktopConfig` merges the entry into
`%APPDATA%\Claude\claude_desktop_config.json`, keeps a `.bak` of the old file and never overwrites a
damaged one. By hand, merge this into `mcpServers`:

```json
{
  "mcpServers": {
    "clio": {
      "command": "C:\\Program Files\\Clio\\clio-mcp-bridge.exe",
      "env": { "CLIO_MCP_TOKEN": "PASTE_YOUR_PRIVATE_CLIO_TOKEN_HERE" }
    }
  }
}
```

Restart Claude Desktop. The bridge does not start Clio, touch documents or install anything. It dials
only `http://127.0.0.1:19847/mcp`, ignores proxy settings and refuses redirects.

### Claude Code (Streamable HTTP)

Use `ClaudeCodeConfig` for the definition, for example with `claude mcp add-json`:

```json
{ "type": "http", "url": "http://127.0.0.1:19847/mcp",
  "headers": { "Authorization": "Bearer PASTE_YOUR_PRIVATE_CLIO_TOKEN_HERE" } }
```

Avoid typing a real token on a command line: it lands in shell history.

## Threat model and limits

- Any process of any user on the machine can reach loopback. The bearer token (32 random bytes,
  compared in constant time, stored in Credential Manager) is the only gate, and the Host check
  and Origin refusal stop browsers and DNS rebinding.
- A local process that grabs port 19847 before Clio starts could receive a token from a client that
  dials it. Clio sets exclusive address use, so a second listener cannot share the port, but it cannot
  evict one that is already there. This is the same exposure as on macOS.
- Client configuration files store the token in plaintext. Keep them in your user profile and out of
  repositories, chats and screenshots.
- Limits match macOS: 1 MiB requests and reads, 16 Ki UTF-16 read pages, 100-result pages, 500 indexed
  matches, 256 KiB for created, edited or trashed documents, one mutation at a time, 16 in-flight
  requests, 32 sessions, 16 connections, 110 second tool deadline.
- Windows difference: a busy answer (`another_mutation_in_progress`) is not recorded against the
  `mutationID`, so retrying the same intent works once the other mutation ends. On macOS the busy answer
  is cached for that id.
- Hosted clients cannot reach loopback. No tunnel or remote endpoint is included.

## Checklist before release

Run on the published zip, driving Settings and the tray through UI Automation and the real bridge over
stdio against a temporary folder: authorize a client, enable MCP (and at launch from the saved preference),
`tools/list` (all twelve), `list_workspaces`, `list_documents`, `search_documents`, `read_document`,
`open_document`, `active_document`, `edit_document` (lands in the editor, autosaves), the native deletion
prompt (Cancel gives `deletion_not_approved`, approve moves the file to the Recycle Bin), tray Pause, Resume,
MCP Settings and Quit, Clio staying resident with no window and `open_document` bringing one back, opt-in
login item written and removed, token clipboard cleared after 60 seconds, disable closes the port, Remove
deletes the Credential Manager entry.

Not yet run: Claude Desktop and Claude Code smoke tests, "Add to Claude Desktop" writing the real
configuration file (it is covered by `Clio.Mcp.Tests` only), `move_document`, `export_document` and
`create_document` through the app, a quit with a document that cannot be saved, the tray under a light
theme or high DPI, and a clean-VM check that the published bridge starts.

Note: a client built on Windows PowerShell 5.1's `HttpClient` or `Invoke-WebRequest` is refused with 400,
because it sends `Expect: 100-continue`, which the strict request parser rejects. Node, curl and the bridge
do not send it.
