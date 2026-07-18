# Sheltie Mac bridge

The bridge is the only Sheltie component that talks to Herdr's local Unix socket. It exposes protocol v1 over loopback HTTP/WebSocket; Tailscale Serve supplies tailnet-only HTTPS ingress.

## Requirements

- macOS with Herdr running
- Herdr 0.7.3 or newer for live terminal observer streams
- [Bun](https://bun.sh/) 1.3 or newer
- Tailscale Serve

Herdr 0.7.1 remains usable during development through a `pane.read` polling fallback, but it does not provide the preferred live terminal stream.

## Development

```bash
bun install
SHELTIE_DEV_MODE=1 bun run dev
```

Then verify the loopback service:

```bash
curl http://127.0.0.1:9847/v1/health
curl -X POST -H 'Authorization: Bearer development' \
  http://127.0.0.1:9847/v1/session/refresh
```

Development mode accepts a fixed credential and must never be exposed through Serve.

## Production configuration

Copy `.env.example` values into a private launch-agent environment or other local service manager. Do not commit the resulting environment file.

The bridge refuses to start outside development mode unless:

- it is bound to loopback;
- at least one Tailscale login is allowlisted; and
- an expected public host is configured.

A client must then complete two gates:

1. Tailscale Serve host/login validation.
2. P-256 device pairing with the six-digit code printed on the Mac.

Pairing creates a revocable device credential. The app exchanges that credential for a 15-minute session token; API and WebSocket access use only the short-lived token. Sensitive actions are appended to `~/.config/sheltie/audit.jsonl` without terminal text or keys.

Expose the bridge under a path so it can coexist with Collie:

```bash
tailscale serve --bg --https=443 --set-path=/sheltie http://127.0.0.1:9847
```

Use `https://<mac-magicdns-name>/sheltie` as the app's instance URL. Never use Tailscale Funnel.

## Commands

```bash
bun run typecheck
bun test
bun run start
```
