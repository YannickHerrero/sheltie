# Sheltie Mac bridge

The bridge is the only Sheltie component that talks to Herdr's local Unix socket. It exposes protocol v1 over loopback HTTP/WebSocket; Tailscale Serve supplies tailnet-only HTTPS ingress.

## Requirements

- macOS with Herdr running
- Herdr 0.7.3 or newer for live terminal observer streams
- [Bun](https://bun.sh/) 1.3 or newer
- Tailscale Serve

Herdr 0.7.1 remains usable during development through a `pane.read` polling fallback, but it does not provide the preferred live terminal stream. Authenticated clients can request a bounded, read-only ANSI history snapshot from Herdr's `recent` pane buffer on every supported Herdr version.

The bridge collects the Codex weekly rate-limit meter from the trusted local `codex app-server` API, caches it for one minute, and retains the last good reading across transient collector failures. Set `SHELTIE_CODEX_BINARY` when Codex is not on the LaunchAgent `PATH`; `SHELTIE_USAGE_FILE` remains an explicit local-file override.

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

Provider quota is optional. A trusted local collector may write the file named by `SHELTIE_USAGE_FILE` as a JSON array with `id`, `provider`, `label`, `remainingFraction`, `resetAtMillis`, and `observedAtMillis`. Invalid or stale-source files do not block Herdr access; the app simply hides the meter.

List and revoke paired devices locally:

```bash
bun run admin devices
bun run admin revoke <device-id>
```

Restart the bridge after revocation to evict any in-memory short-lived session immediately.

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
bun run admin devices
```
