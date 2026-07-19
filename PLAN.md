# Sheltie product and architecture plan

_Last updated: 2026-07-19_

## Implementation status

- Phases 0–4 have an initial implementation across `protocol/`, `bridge/`, and `ios/`.
- The bridge and protocol are covered by automated unit and live local Herdr integration checks.
- The iPhone/iPad app builds and its model, security, networking, and demo UI paths are covered by simulator tests.
- Phase 5 remains in progress: independent security review, physical-device interaction testing, performance/energy profiling, licensing, TestFlight, and public release automation are not complete.
- The local integration Mac still runs Herdr 0.7.1, so live verification uses the polling fallback; Herdr 0.7.3 observer support is implemented and unit-tested but still needs live verification after the server is upgraded.

## 1. Product definition

Sheltie is an iPad-first native client for Herdr with a compact iPhone experience. It should feel like using Herdr directly while replacing terminal-host interaction with controls designed for iOS and iPadOS.

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
- `do-not-commit/Web-Prototype.zip` is the local visual reference and must remain untracked.
- The exported `herdr-ipad-control.html` is the visual source of truth; handoff documents and images provide supporting context only.

### Goals

- Display all Herdr workspaces, tabs, panes, layouts, and agent states.
- Render every visible terminal pane with low-latency incremental updates.
- Support terminal text, special keys, modifier chords, paste, scroll, and resize.
- Support workspace, tab, pane, split, focus, zoom, move, rename, and close operations.
- Recover cleanly after iOS/iPadOS suspension, network loss, Tailscale reconnection, or a Herdr restart.
- Keep the host unreachable from the public internet.
- Make protocol and security boundaries suitable for eventual public use.

### Non-goals for the initial version

- Running Herdr or agent processes on the mobile device.
- Acting as a general-purpose SSH client.
- Reimplementing Herdr's server, PTY ownership, or agent detection.
- Public internet access or Tailscale Funnel support.
- iPhone, macOS, visionOS, or Android support in the first milestone.
- Background push notifications in the first interactive prototype.
- Pixel-identical terminal rendering of Herdr's own TUI chrome; the chrome will be native SwiftUI informed by the design mockup.
- Search, a global New Session button, and an agent inspector in the initial release. These appear only in earlier design iterations, not the final HTML source of truth.

### Design source of truth

The approved local design archive contains one final product screen. Implementation evidence is prioritized in this order:

1. `herdr-ipad-control.html` for final structure, tokens, responsive rules, and interactions.
2. `DESIGN-MANIFEST.json` and `DESIGN-HANDOFF.md` for fidelity and accessibility expectations.
3. The latest exported drawing for visual comparison.
4. Earlier drawings and the original Herdr screenshot for design history and context only.

The HTML is a behavioral contract, not a request to embed a web view. Web controls must be translated to native SwiftUI/UIKit equivalents while preserving hierarchy, geometry, state, and intent.

### Visual system

The initial theme is the exported Tokyo Night Day-derived light palette:

| Token | Source value | Intended use |
| --- | --- | --- |
| Background | `oklch(0.9135 0.0068 277.2)` | Terminal and workspace canvas |
| Surface | `oklch(0.8866 0.0096 279.7)` | App bar, tabs, composers, keybar |
| Foreground | `oklch(0.3252 0.0988 268.3)` | Primary text and decisive controls |
| Muted | `oklch(0.5551 0.0661 275.7)` | Metadata and secondary labels |
| Border | `oklch(0.7951 0.0315 275.5)` | Low-contrast pane boundaries |
| Accent | `oklch(0.5999 0.1804 257.5)` | Focused tab and primary selection |
| Success | `oklch(0.5249 0.0929 130.3)` | Connected and done |
| Warning | `oklch(0.5527 0.0749 75.2)` | Working |
| Danger | `oklch(0.6337 0.2326 11.6)` | Blocked and destructive actions |

Convert these source colors into named sRGB asset-catalog colors and visually validate the conversion rather than scattering literal values through Swift code. Initial typography maps display text to Iowan Old Style/Charter, interface text to the system sans-serif, and operational text to JetBrains Mono with SF Mono fallback.

The spacing rhythm is 8, 12, 20, and 32 points. Standard radii are 8 points, larger modal surfaces use 14 points, and interactive targets remain at least 44 points. Motion is restrained (roughly 120–220 ms) and must respect Reduce Motion.

Status presentation follows the prototype exactly: working is warning/gold, blocked is danger/pink, done and connected are success/olive, and paused or unknown is muted.

### Component and adaptive-layout contract

The native shell consists of:

- A 58-point app bar with Sheltie identity, current Mac/connection selector, and an optional provider-usage meter.
- A 205–240-point sidebar split vertically between Spaces and grouped Agents, defaulting to 42/58 with a persistent draggable ratio.
- A 46-point horizontally scrollable tab strip.
- A Herdr-driven split-pane workspace with 38-point pane headers.
- Separate agent-message and terminal-command composers.
- A 50-point horizontally scrollable special-key row.
- A registered-instance selection/pairing modal and transient toast/status feedback.

Use the phone idiom only to select the navigation model, then use available window width for layout adaptation:

- On iPhone: make the complete Spaces/Agents sidebar the full-screen root and open a selected workspace or agent as a full-screen terminal page with an explicit back control.
- On iPad above 820 points: keep the sidebar persistent and show the complete Herdr pane split.
- On iPad at or below 820 points: present the sidebar as a drawer and show one pane at a time with an explicit pane switcher.
- At or below 560 points: condense connection metadata, usage presentation, tabs, and keybar notes.
- Fill the app window edge to edge at every width; the prototype’s outer presentation frame is not application chrome.

The prototype documents the connected success path. Before implementation, specify native loading, empty, pairing-required, connecting, disconnected, reconnecting, incompatible-server, revoked-device, pane-stream-error, and optional-data-unavailable states without changing the established geometry unnecessarily.

## 2. System architecture

```text
┌─────────────────────────────────────────────────────────────┐
│ Native iPhone and iPad application                          │
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

Each registered Mac runs its own loopback bridge and Tailscale Serve ingress. The app stores multiple paired instance profiles locally, selects exactly one active instance per window, and keeps credentials isolated by instance. Multi-instance support is therefore part of the client model even if the first integration environment uses one Mac.

### Architectural boundary

The mobile app must not speak Herdr's private binary client protocol directly. The bridge will translate Herdr's local APIs into a versioned Sheltie protocol. This keeps Herdr compatibility code on the Mac and allows the app and bridge to negotiate their own stable contract.

The bridge should use documented Herdr interfaces wherever possible:

- `session.snapshot` for bootstrap and authoritative resynchronization.
- `events.subscribe` for lifecycle, layout, focus, and agent-status changes.
- Workspace, tab, pane, layout, and agent socket methods for actions.
- `herdr terminal session observe` for visible read-only terminal streams.
- `herdr terminal session control` for focused writable terminal streams.

The preferred baseline is Herdr 0.7.3 or newer. The bridge must query version and capabilities instead of assuming every method exists.

## 3. Native iPhone and iPad application

### 3.1 Application shell

The native application shell must follow the approved component and adaptive-layout contract above. It should use custom SwiftUI composition instead of default `NavigationSplitView`, `List`, or toolbar styling where platform defaults would materially change the mockup's geometry.

Data terminology maps as follows:

- **Spaces** are Herdr workspaces.
- **Tabs** in the horizontal strip are Herdr tabs, not named Herdr sessions.
- **Terminal panes** are Herdr panes arranged by a Herdr layout snapshot.
- **Agents** are Herdr-detected agents linked back to their workspace, tab, and pane.
- **Instances** are paired Macs/bridge installations; named Herdr sessions live within an instance.

Selecting a Space focuses its active tab and pane. Selecting an Agent focuses its linked Space, tab, and pane. The instance selector is a native modal that lists paired Macs, communicates current/connected/paused state, and launches a secure pairing flow for a new Mac.

The final HTML does not contain the workspace hero header, search control, global New Session control, or right-side agent inspector shown in earlier drawings. Do not implement those surfaces unless they are deliberately reintroduced in a later design revision.

### 3.2 State model

A single actor-isolated store should own:

- Registered instance profiles, active instance, pairing, and connection status
- Bridge and Herdr capabilities
- Sessions
- Workspaces and worktrees
- Tabs
- Panes and agents
- Layout snapshots and split ratios
- Focus, zoom, active composer, and keyboard-routing state
- Terminal subscriptions and frame sequence state
- Optional provider-usage meters and presentation metadata
- Pending mutations, toast/status feedback, and recoverable errors

Bootstrap provides a complete snapshot. WebSocket events update the cache. Any sequence gap, reconnect, or stale-state indication triggers a fresh bootstrap rather than attempting speculative repair.

### 3.3 Pane layout

Use a custom SwiftUI layout driven by Herdr's layout snapshot:

- Preserve horizontal and vertical split structure.
- Normalize server layout rectangles into the available window geometry.
- Keep pane IDs stable across redraws.
- Render visible dividers with native drag targets.
- Send split-ratio changes deliberately and debounce drag updates.
- Support zoom without destroying the cached full layout.
- At compact widths, retain the Herdr split model while rendering and subscribing only to the explicitly selected visible pane.
- Keep sidebar, its persisted Spaces/Agents ratio, and pane-switcher presentation state local to the app; do not mutate Herdr merely because the window crosses an adaptive threshold.

### 3.4 Terminal rendering

Terminal contents should use a native UIKit-backed terminal view wrapped for SwiftUI. Evaluate an existing terminal component before considering a custom emulator.

Required behavior:

- Initial full ANSI frame followed by ordered incremental frames.
- Per-pane sequence numbers and explicit resynchronization.
- UTF-8, wide characters, combining characters, color, cursor, hyperlinks, and scrollback.
- Independent terminal dimensions for every visible pane.
- Read-only subscriptions for background panes.
- Writable control for the focused pane.
- Clean teardown and restoration when switching tabs, sessions, or instances.

Pane headers, command composers, and the keybar are native chrome outside the terminal emulator. The terminal view must not reproduce those elements from ANSI output. Kitty graphics and image protocols can be deferred until text terminal fidelity is established.

### 3.5 Keyboard and input

#### Physical keyboard

- Route normal text and terminal keys directly to the focused pane when no composer or modal owns focus.
- Preserve key repeat and modifier state.
- Reserve explicit app shortcuts for workspace, tab, pane, command-palette, and connection actions.
- Provide a discoverable shortcut overlay.
- Make modal → composer → app shortcut → terminal precedence deterministic and testable.

#### Touch and software keyboard

- The agent composer sends semantic agent text followed by the configured submit key.
- The terminal composer sends literal terminal text and an explicit Enter only when submitted.
- Both composers support autocorrect, marked text, paste, and dictation as appropriate; terminal autocorrection remains off by default.
- The special-key row always targets the focused pane rather than inserting display labels into a text field.
- Provide Escape, Tab, Shift-Tab, arrows, Enter, Backspace, sticky modifiers, and configurable common chords such as Control-C.
- Preserve the prototype's quick literal keys (`|`, `~`, and `/`) as configurable defaults.
- Tap to focus panes and use native context menus for structural actions.
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
- Publish optional presentation metadata and provider-usage meters only when a trusted source supplies them.
- Multiplex terminal streams onto one authenticated WebSocket.
- Enforce capability and protocol compatibility.
- Pair and revoke iPhone and iPad devices.
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
- Optional provider-usage meters with source, remaining amount, reset time, and freshness

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
- Generate the mobile device key in the Secure Enclave when available.
- Store credentials in Keychain with biometric/user-presence protection where practical.
- Support host-side device revocation.
- Use short-lived authenticated sessions and replay-resistant challenges.
- Require confirmation for destructive structural actions.
- Record write actions in a private audit log without exposing secrets unnecessarily.
- Apply payload, connection, subscription, and terminal-frame limits.

A client-supplied device-name or device-ID header is not authentication and must never grant write access. The prototype's manually entered WebSocket URL and optional token are not the production security model: adding an instance must pair with a bridge, validate its HTTPS/MagicDNS identity, and store the resulting per-device credential in Keychain.

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

- Treat the final HTML export as the approved source of truth and keep the archive untracked.
- Freeze named native color, typography, spacing, radius, status, and motion tokens from the export.
- Inventory every visible component, interaction, adaptive rule, and missing operational state.
- Produce a native component specification for the app bar, sidebar, tabs, panes, composers, keybar, instance modal, and toast/status feedback.
- Define the Sheltie mobile protocol and capability negotiation.
- Decide bridge language and packaging.
- Produce threat model and pairing sequence diagrams.

### Phase 1 — bridge foundation

- Herdr discovery and capability checks.
- Versioned bootstrap endpoint.
- Snapshot cache plus event-driven invalidation.
- Loopback server and Tailscale Serve integration.
- Development-only pairing and audit foundations.

### Phase 2 — read-only Apple mobile client

- Native shell matching the approved mockup and adaptive width thresholds.
- Registered-instance selector, pairing, connection, and reconnect states.
- Workspace, grouped-agent, tab, and pane layout rendering.
- Optional usage-meter presentation with a clean absent-data state.
- Read-only live terminals for visible panes in the active tab.

### Phase 3 — interactive terminal client

- Focused terminal control.
- Physical keyboard routing with explicit focus precedence.
- Separate agent and terminal composers plus a focused-pane special-key toolbar.
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

### Near-term backlog

- [ ] Add push notifications when an agent transitions to `done` or `blocked`.
  - Add a Settings page with independent opt-ins for done and blocked notifications, including system-permission and denied states.
  - Prevent duplicate notifications after bootstrap or reconnect, and define the bridge/APNs delivery architecture and its privacy constraints.
- [ ] Fix the Codex usage-limit meter not appearing.
  - Trace the usage data from its trusted local source through the bridge bootstrap to the app bar, with useful handling for missing, stale, or malformed data.
- [ ] Add a per-Space to-do list backed by `todo.md` in the related workspace project root.
  - Add **Todo List** to each Space's long-press context menu and present the list in an in-app dialog.
  - Refine the Markdown editing model, save and conflict behavior, external-change handling, path security, and empty and error states before implementation.
- [ ] Show compact project paths in the Spaces section.
  - Display only the final path component, such as `/project` instead of `/Users/yannickherrero/dev/project`.
  - When final components collide, prepend the minimum parent component needed to disambiguate them, adding further parents only if necessary.

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

- Screenshot comparison against the final HTML at 1024×768, 820×1180, and representative widths above and below 820 and 560 points.
- Exact verification of app-bar, sidebar, tab, pane-header, composer, and keybar geometry.
- iPhone portrait plus iPad portrait and landscape sizes.
- Split View and Stage Manager resizing across both adaptive thresholds.
- Network interruption and Tailscale reconnection.
- App background/foreground restoration.
- External keyboard typing, chords, key repeat, and shortcuts.
- Software keyboard, dictation, marked text, and autocorrect.
- Touch focus, divider dragging, scroll, selection, and context menus.
- Simultaneous Mac and mobile-client attachment behavior.

Screenshots can verify layout, but physical-keyboard timing, gestures, dictation, background suspension, biometric prompts, and native menu behavior require manual device testing.

## 8. Risks and open decisions

- Exact behavior when Herdr has multiple attached clients with different pane dimensions.
- Whether terminal control should be held continuously or acquired only during active input.
- Source and freshness semantics for the optional Codex/provider usage meter.
- Secure multi-instance discovery and pairing without accepting arbitrary raw socket URLs.
- Maintaining direct terminal keyboard focus while native composers remain readily available.
- How split-divider dragging maps to Herdr's public layout operations.
- Terminal component selection and support for arbitrary TUIs.
- Theme synchronization and custom Herdr configurations.
- Background notification architecture without requiring a hosted service.
- Minimum supported iOS and iPadOS versions.
- Bridge implementation language and update mechanism.
- Scope of the first release: terminal control only versus complete structural management.
- Whether search, global New Session, or an agent inspector should return in a future design revision.
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
