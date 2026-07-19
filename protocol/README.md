# Sheltie protocol

This directory owns the versioned, bridge-independent wire contract shared by the iPhone/iPad app and Mac bridge.

- `Sources/SheltieProtocol/` contains the Swift `Codable` models used by the app.
- `schema/sheltie-v1.schema.json` is the language-neutral bootstrap schema.
- `Tests/.../Fixtures/` contains representative wire fixtures.

Protocol version `1` uses JSON over HTTPS and WebSocket. Adding optional fields is backwards-compatible. Renaming/removing fields or changing their meaning requires a new protocol version and capability negotiation.

Terminal bytes are base64-encoded so WebSocket JSON frames remain inspectable and deterministic. A `full` terminal frame replaces local emulator state; incremental frames are accepted only in sequence. Canonical scrollback is requested separately as a bounded, read-only `terminal.history` snapshot because live viewport frames do not contain terminal history. Additive capability-gated messages cover revision-checked workspace todo documents, workspace-scoped UTF-8 file browsing/editing, and per-device notification configuration.
