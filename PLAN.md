# Sheltie product and architecture plan

_Last updated: 2026-07-18_

## 1. Product definition

Sheltie is an iPad-first native client for Herdr. It should feel like using Herdr directly while replacing terminal-host interaction with controls designed for iPadOS.

The app will recreate Herdr's workspace, agent, tab, and pane layout in SwiftUI. Terminal contents remain real interactive terminals hosted by the Mac. A companion bridge running beside Herdr will expose semantic state, actions, and terminal streams over a secure Tailscale connection.

### Confirmed requirements

- Native Swift application; no `WKWebView` application shell.
- Mimic Herdr's layout and interaction model rather than displaying Collie's mobile dashboard.
- Physical keyboard is the primary input method.
- All essential operations must also work with touch and the software keyboard.
- Do not use SSH.
- Connect to a service exposed by the Mac that already runs the Herdr server.
- Use Tailscale as the private network and ingress boundary, similarly to Collie.
- Personal application initially, while preserving a path to public distribution.
- Design mockups will be supplied separately and remain uncommitted until reviewed.

### Goals

- Display all Herdr workspaces, tabs, panes, layouts, and agent states.
- Render every visible terminal pane with low-latency incremental updates.
- Support terminal text, special keys, modifier chords, paste, scroll, and resize.
- Support workspace, tab, pane, split, focus, zoom, move, rename, and close operations.
- Recover cleanly after iPadOS suspension, network loss, Tailscale reconnection, or a Herdr restart.
- Keep the host unreachable from the public internet.
- Make protocol and security boundaries suitable for eventual public use.

### Non-goals for the initial version

- Running Herdr or agent processes on the iPad.
- Acting as a general-purpose SSH client.
- Reimplementing Herdr's server, PTY ownership, or agent detection.
- Public internet access or Tailscale Funnel support.
- iPhone, macOS, visionOS, or Android support in the first milestone.
- Background push notifications in the first interactive prototype.
- Pixel-identical terminal rendering of Herdr's own TUI chrome; the chrome will be native SwiftUI informed by the design mockup.

## 2. System architecture

```text
┌─────────────────────────────────────────────────────────────┐
│ Native iPad application                                     │
│                                                             │
│ SwiftUI shell  ·  terminal views  ·  keyboard/input router  │
│ state cache    ·  pairing         ·  reconnect coordinator  │
└─────────────────────────────┬───────────────────────────────┘
                              │ HTTPS + WebSocket
                              │ over the user's tailnet
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Tailscale Serve                                             │
│ TLS termination · MagicDNS · Tailscale identity             │
└─────────────────────────────┬───────────────────────────────┘
                              │ loopback only
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Sheltie bridge                                              │
│                                                             │
│ pairing/auth · mobile API · state adapter · event stream    │
│ terminal multiplexer · capability negotiation · audit log   │
└─────────────────────────────┬───────────────────────────────┘
                              │ local sockets/processes only
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Herdr server                                                │
│ session state · workspaces/tabs/panes · PTYs · agents       │
└─────────────────────────────────────────────────────────────┘
```

### Architectural boundary

The iPad app must not speak Herdr's private binary client protocol directly. The bridge will translate Herdr's local APIs into a versioned Sheltie protocol. This keeps Herdr compatibility code on the Mac and allows the app and bridge to negotiate their own stable contract.

The bridge should use documented Herdr interfaces wherever possible:

- `session.snapshot` for bootstrap and authoritative resynchronization.
- `events.subscribe` for lifecycle, layout, focus, and agent-status changes.
- Workspace, tab, pane, layout, and agent socket methods for actions.
- `herdr terminal session observe` for visible read-only terminal streams.
- `herdr terminal session control` for focused writable terminal streams.

The preferred baseline is Herdr 0.7.3 or newer. The bridge must query version and capabilities instead of assuming every method exists.

## 3. Native iPad application

### 3.1 Application shell

The final structure will be derived from the supplied HTML mockup. The expected native regions are:

- Workspace/space sidebar
- Agent list and attention states
- Active workspace header
- Tab strip
- Recursive split-pane surface
- Focus and zoom indicators
- Connection and session state
- Native menus, sheets, alerts, and command palette

Landscape should preserve the complete multi-column layout. Portrait should collapse secondary navigation into overlays or drawers without changing the underlying Herdr state.

### 3.2 State model

A single actor-isolated store should own:

- Connection and pairing status
- Bridge and Herdr capabilities
- Sessions
- Workspaces and worktrees
- Tabs
- Panes and agents
- Layout snapshots and split ratios
- Focus and zoom state
- Terminal subscriptions
- Pending mutations and recoverable errors

Bootstrap provides a complete snapshot. WebSocket events update the cache. Any sequence gap, reconnect, or stale-state indication triggers a fresh bootstrap rather than attempting speculative repair.

### 3.3 Pane layout

Use a custom SwiftUI layout driven by Herdr's layout snapshot:

- Preserve horizontal and vertical split structure.
- Normalize server layout rectangles into available iPad geometry.
- Keep pane IDs stable across redraws.
- Render visible dividers with native drag targets.
- Send split-ratio changes deliberately and debounce drag updates.
- Support zoom without destroying the cached full layout.

### 3.4 Terminal rendering

Terminal contents should use a native UIKit-backed terminal view wrapped for SwiftUI. Evaluate an existing terminal component before considering a custom emulator.

Required behavior:

- Initial full ANSI frame followed by ordered incremental frames.
- Per-pane sequence numbers and explicit resynchronization.
- UTF-8, wide characters, combining characters, color, cursor, hyperlinks, and scrollback.
- Independent terminal dimensions for every visible pane.
- Read-only subscriptions for background panes.
- Writable control for the focused pane.
- Clean teardown and restoration when switching tabs or sessions.

Kitty graphics and image protocols can be deferred until text terminal fidelity is established.

### 3.5 Keyboard and input

#### Physical keyboard

- Route normal text and terminal keys to the focused pane.
- Preserve key repeat and modifier state.
- Reserve explicit app shortcuts for workspace, tab, pane, command-palette, and connection actions.
- Provide a discoverable shortcut overlay.
- Make app-versus-terminal shortcut precedence deterministic and testable.

#### Touch and software keyboard

- Compose field supporting autocorrect, marked text, paste, and dictation.
- Explicit Send action.
- Accessory controls for Escape, Tab, Shift-Tab, arrows, Enter, and Backspace.
- Sticky Control, Option, Shift, and Command modifiers.
- Configurable buttons for common chords such as Control-C.
- Tap to focus panes and native context menus for structural actions.
- Separate terminal interaction and text-selection behavior where gestures conflict.

### 3.6 Lifecycle

The app cannot rely on a WebSocket remaining alive in the background. On foregrounding it should:

1. Check Tailscale/MagicDNS reachability.
2. Re-establish the authenticated session.
3. Fetch a fresh bootstrap snapshot.
4. Restore the selected session, workspace, tab, and pane when still valid.
5. Re-subscribe visible terminals.
6. Request full terminal frames before accepting incremental updates.

## 4. Mac bridge

### 4.1 Responsibilities

- Run independently of the Herdr TUI client.
- Bind only to loopback.
- Configure and report the Tailscale Serve ingress.
- Discover default and named Herdr sessions.
- Adapt Herdr snapshots, events, actions, and terminal sessions.
- Multiplex terminal streams onto one authenticated WebSocket.
- Enforce capability and protocol compatibility.
- Pair and revoke iPad devices.
- Apply request limits and backpressure.
- Audit every input and structural mutation.
- Recover after Herdr socket replacement or server restart.

### 4.2 Process model

For the active tab, the bridge may maintain:

- One terminal observer for each visible non-focused pane.
- One terminal controller for the focused pane.
- One Herdr event subscription per session.
- One authoritative snapshot cache per session.

Terminal processes must be released when no client subscribes. Slow clients must receive a new full frame instead of an unbounded queue of stale incremental frames.

### 4.3 Proposed mobile API

The exact schema will be designed before implementation.

#### HTTPS

```text
POST /v1/pair/start
POST /v1/pair/complete
POST /v1/session/refresh
GET  /v1/bootstrap
POST /v1/actions
GET  /v1/health
```

`bootstrap` should include:

- Sheltie protocol version
- Bridge version and capabilities
- Herdr version, protocol, and capabilities
- Available sessions
- Workspaces, tabs, panes, agents, and layouts
- Focus and zoom state
- Theme/display tokens needed by the client

#### WebSocket

```text
GET /v1/stream
```

Server messages:

- State event
- Snapshot invalidation
- Terminal full frame
- Terminal incremental frame
- Terminal closed/error
- Action acknowledgement/error
- Ping and session-expiry notice

Client messages:

- Subscribe/unsubscribe pane
- Focus/control pane
- Terminal input
- Terminal resize
- Terminal scroll
- Structural action
- Resync request
- Pong

Every message should carry a protocol version, request or stream identifier, and enough sequence information to detect loss.

## 5. Security model

Sheltie is remote shell access and must be designed accordingly.

### Required controls

- Tailscale Serve only; never Funnel.
- Bridge binds to `127.0.0.1` only.
- Validate the Tailscale user identity injected by Serve.
- Validate expected public hosts.
- Use a cryptographic per-device pairing flow in addition to Tailscale identity.
- Generate the iPad device key in the Secure Enclave when available.
- Store credentials in Keychain with biometric/user-presence protection where practical.
- Support host-side device revocation.
- Use short-lived authenticated sessions and replay-resistant challenges.
- Require confirmation for destructive structural actions.
- Record write actions in a private audit log without exposing secrets unnecessarily.
- Apply payload, connection, subscription, and terminal-frame limits.

A client-supplied device-name or device-ID header is not authentication and must never grant write access.

### Public-release considerations

Before public distribution, review:

- Herdr's AGPL/commercial licensing boundary.
- Any terminal-emulator dependency license.
- App Store encryption/export declarations.
- Privacy disclosures and diagnostic collection.
- A supportable pairing and bridge-update mechanism.
- Whether the bridge remains a separate executable or Herdr plugin.

## 6. Delivery roadmap

### Phase 0 — design and contracts

- Import and inspect the local HTML mockup.
- Inventory every screen, state, interaction, and responsive rule.
- Convert the visual design into native design tokens and component specifications.
- Define the Sheltie mobile protocol and capability negotiation.
- Decide bridge language and packaging.
- Produce threat model and pairing sequence diagrams.

### Phase 1 — bridge foundation

- Herdr discovery and capability checks.
- Versioned bootstrap endpoint.
- Snapshot cache plus event-driven invalidation.
- Loopback server and Tailscale Serve integration.
- Development-only pairing and audit foundations.

### Phase 2 — read-only iPad client

- Native shell matching the approved mockup.
- Connection, pairing, and reconnect state.
- Workspace, agent, tab, and pane layout rendering.
- Read-only live terminals for all panes in the active tab.

### Phase 3 — interactive terminal client

- Focused terminal control.
- Physical keyboard routing.
- Software-keyboard composer and special-key toolbar.
- Paste, scroll, resize, selection, and tab switching.
- Reconnection and full-frame recovery.

### Phase 4 — full Herdr operations

- Create, rename, move, focus, zoom, split, resize, and close operations.
- Native context menus and command palette.
- Multiple named sessions.
- Error recovery and destructive-action confirmations.

### Phase 5 — polish and public-readiness

- Device revocation and hardened pairing.
- Accessibility and VoiceOver semantics.
- Portrait adaptation and Stage Manager behavior.
- Performance and energy profiling.
- Optional notifications and image support.
- Documentation, licensing, CI, release automation, and TestFlight evaluation.

## 7. Verification strategy

### Automated

- Codable protocol fixtures shared between bridge and app.
- Bridge unit tests for Herdr adaptation, capability negotiation, auth, sequencing, and limits.
- Swift model/store tests for snapshots, event application, resync, and mutation rollback.
- Terminal stream tests for full/incremental ordering and reconnect recovery.
- SwiftUI snapshot tests for key layout sizes and states.
- Integration tests against a disposable Herdr session.
- Security tests for missing identity, wrong host, expired sessions, replay, revoked devices, and oversized input.

### Simulator and device

- iPad portrait and landscape sizes.
- Split View and Stage Manager resizing.
- Network interruption and Tailscale reconnection.
- App background/foreground restoration.
- External keyboard typing, chords, key repeat, and shortcuts.
- Software keyboard, dictation, marked text, and autocorrect.
- Touch focus, divider dragging, scroll, selection, and context menus.
- Simultaneous Mac and iPad attachment behavior.

Screenshots can verify layout, but physical-keyboard timing, gestures, dictation, background suspension, biometric prompts, and native menu behavior require manual device testing.

## 8. Risks and open decisions

- Exact behavior when Herdr has multiple attached clients with different pane dimensions.
- Whether terminal control should be held continuously or acquired only during active input.
- How split-divider dragging maps to Herdr's public layout operations.
- Terminal component selection and support for arbitrary TUIs.
- Theme synchronization and custom Herdr configurations.
- Background notification architecture without requiring a hosted service.
- Minimum supported iPadOS version.
- Bridge implementation language and update mechanism.
- Scope of the first release: terminal control only versus complete structural management.
- Public project license and relationship to upstream Herdr.

## 9. Proposed future repository layout

```text
Sheltie/
├── ios/                    # Xcode project and native application
├── bridge/                 # Mac companion service/plugin
├── protocol/               # Versioned schemas and fixtures
├── docs/                   # Architecture, security, and design specifications
├── do-not-commit/          # Local mockups and references; Git-ignored
├── README.md
└── PLAN.md
```

Directories should be created only when their first independently valid implementation is approved.
