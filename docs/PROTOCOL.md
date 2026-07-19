# Sheltie protocol v1

The Sheltie protocol is JSON over HTTPS and WebSocket. The Swift models in `protocol/Sources/SheltieProtocol`, the JSON schema, and fixtures are the canonical contract. The bridge adapts Herdr; clients do not depend on Herdr wire shapes.

## Versioning

Every bootstrap includes:

- Sheltie protocol version;
- bridge version and capabilities;
- Herdr version, protocol, and capabilities.

Adding optional fields or capabilities is backwards-compatible. Removing, renaming, or changing field meaning requires a new Sheltie protocol version.

## HTTPS

```text
POST /v1/pair/start
POST /v1/pair/complete
POST /v1/session/refresh
GET  /v1/bootstrap?session=<id>
POST /v1/actions
GET  /v1/health
```

Pairing endpoints require valid Tailscale ingress identity. Refresh requires the long-lived paired-device credential. Bootstrap and action endpoints require the short-lived session credential.

`bootstrap` is authoritative and contains instances, Herdr sessions, workspaces, tabs, panes, agents, recursive layouts, focus, optional usage meters, and capability data.

## WebSocket

```text
GET /v1/stream?session=<id>
```

The native client supplies the short-lived bearer token in the upgrade request.

Server messages:

- `snapshot`
- `terminal.frame`
- `terminal.history`
- `workspace.todo`
- `workspace.directory`
- `workspace.file`
- `notifications.configuration`
- `terminal.closed`
- `action.result`
- `session.expiring`
- `ping`

Client messages:

- `subscribe`
- `terminal.history.request`
- `workspace.todo.read`
- `workspace.todo.save`
- `workspace.directory.list`
- `workspace.file.read`
- `workspace.file.save`
- `notifications.configure`
- `action`
- `resync`
- `pong`

A connection may subscribe only to panes visible in the current adaptive layout. Every subscription carries independent columns and rows.

## Terminal frames

Terminal bytes are base64-encoded ANSI data. Each frame carries session ID, pane ID, sequence, dimensions, and a `full` flag.

- A full frame replaces emulator state.
- Incremental frames are applied only in sequence.
- A gap triggers resynchronization.
- Herdr 0.7.3+ frames come from `herdr terminal session observe`.
- Older Herdr versions use bounded ANSI `pane.read` snapshots transformed into full frames.

Input uses explicit actions. Raw SwiftTerm bytes are base64-encoded; composed shell text plus Enter uses Herdr `pane.send_input` atomically. Herdr rejects semantic `PageUp` and `PageDown` key names, so the bridge translates those terminal-key actions (including Ctrl/Alt/Shift variants) to canonical xterm `CSI 5~` and `CSI 6~` input sequences. Agent messages use `agent.send` followed by the submit key.

## Terminal history

Live terminal frames describe the current viewport and cannot reconstruct canonical scrollback. A client may therefore request recent history for one pane. The bridge reads Herdr's ANSI `pane.read` `recent` source and returns a base64-encoded, read-only snapshot. Requests are clamped to Herdr's 1,000-line limit and a bridge byte ceiling. The iOS client presents the stable snapshot over the still-updating live terminal, then dismisses it to return immediately to current output. History remains memory-only and is never audited or logged.

## Workspace todo documents

Authenticated clients address todo documents by Herdr session and workspace ID; they never supply a filesystem path. The bridge resolves the authoritative workspace root and reads or atomically writes `todo.md`. Documents carry SHA-256 revisions for conflict detection. Reads reject symlinks, non-UTF-8 data, path escapes, and files above 256 KiB. Writes are audited without recording Markdown content.

## Workspace files

The `workspace.files` capability adds a native text-file workflow scoped to authoritative Herdr workspace roots. Clients list one directory at a time and open a file by workspace ID plus relative path. The bridge rejects absolute paths, traversal, symbolic links, non-regular files, invalid UTF-8, null bytes, and files above 1 MiB.

A successful open returns file bytes, metadata, a SHA-256 revision, and an opaque device-bound document ID. Saves identify that document rather than selecting a new destination; the bridge revalidates the workspace and path, compares the expected revision, preserves file permissions, and atomically replaces the file in its original directory. Handles survive authenticated WebSocket reconnects for one hour. A missing handle or external edit returns an explicit conflict instead of silently overwriting data. File content is never audited.

## Notifications and usage

Notification registration binds an APNs device token and independent done/blocked preferences to the authenticated paired device. The bridge seeds agent state from bootstrap, emits only real post-bootstrap transitions, and sends generic APNs payloads without project, path, prompt, or terminal data. Delivery capability is advertised only when local APNs credentials are configured.

Codex usage is collected from the trusted local `account/rateLimits/read` app-server method, cached, and mapped to an optional weekly meter. The explicit trusted JSON file remains an override. Clients use `observedAtMillis` to distinguish current and stale readings.

## Structural actions

Protocol v1 supports a closed set of workspace, tab, pane, layout, terminal, and agent actions. The bridge maps each action to typed Herdr parameters. Semantic split axes translate to Herdr placement directions (`horizontal` → `right`, `vertical` → `down`) for pane creation and moves. Pane move destinations are discriminated as existing tab, new tab, or new workspace. Split-divider updates include the recursive Boolean split path and a clamped ratio.

Unknown action names are rejected before reaching Herdr.

## Resynchronization

The bridge snapshot cache is authoritative. It prefers `session.snapshot` on Herdr 0.7.2+ and falls back to the workspace/tab/pane list calls on older servers. Layouts are exported per tab so the app receives recursive split structure. A long-lived `events.subscribe` connection triggers a debounced refresh after lifecycle, focus, layout, or agent-state events; events accelerate snapshots but never replace them as the source of truth.

The app requests a fresh bootstrap after foregrounding, session expiry, WebSocket loss, or invalid selection. It restores IDs only if they still exist and obtains full terminal frames before accepting new increments.
