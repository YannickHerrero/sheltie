# Sheltie

Sheltie is a planned native iPad client for [Herdr](https://herdr.dev). It will reproduce Herdr's workspace, agent, tab, and split-pane experience with native Swift interfaces while connecting to the existing Herdr server through a secure companion bridge on the Mac.

> [!IMPORTANT]
> Sheltie is currently in the design and architecture phase. There is no runnable application or bridge yet.

## Vision

- Native SwiftUI interface inspired by Herdr's layout and interaction model
- Full terminal panes rather than simplified agent transcripts
- Physical-keyboard-first operation with complete touch and software-keyboard controls
- No SSH and no embedded web application
- Tailnet-only communication through Tailscale Serve
- Personal use initially, with an architecture suitable for a possible public release

## Proposed architecture

```text
iPad app (SwiftUI + native terminal views)
        │ HTTPS / WebSocket over Tailscale
        ▼
Sheltie bridge on the Mac
        │ local Herdr sockets and terminal sessions
        ▼
Herdr server and its existing panes
```

The bridge will expose a versioned mobile protocol, synchronize Herdr's semantic state, multiplex live terminal streams, authenticate paired devices, and audit remote input.

See [PLAN.md](PLAN.md) for the current product and technical plan.

## Design mockups

Local mockups and exported design files belong in:

```text
do-not-commit/
```

That directory is intentionally ignored by Git. Design files may be used as local implementation references but must not be committed without an explicit review of their contents and licensing.

## Security

Sheltie will provide remote terminal control with the privileges of the user running Herdr. The bridge must remain loopback-only behind a tailnet-only authenticated ingress. Public Tailscale Funnel exposure is not supported.

## Relationship to Herdr

Sheltie is an independent client project and is not currently an official Herdr application.

## License

No license has been selected yet. Public visibility does not grant permission to copy, modify, or redistribute the project until a license is added.
