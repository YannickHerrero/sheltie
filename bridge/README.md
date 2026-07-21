# Sheltie host bridge

The bridge is the only Sheltie component that talks to Herdr's local Unix socket. It exposes protocol v1 over loopback HTTP/WebSocket; Tailscale Serve supplies tailnet-only HTTPS ingress.

## Requirements

- macOS or Linux/WSL2 with Herdr running in the same operating-system environment
- Herdr 0.7.3 or newer for live terminal observer streams
- [Bun](https://bun.sh/) 1.3 or newer
- Tailscale Serve

Herdr 0.7.1 remains usable during development through a `pane.read` polling fallback, but it does not provide the preferred live terminal stream. Authenticated clients can request a bounded, read-only ANSI history snapshot from Herdr's `recent` pane buffer on every supported Herdr version.

The bridge collects the Codex weekly rate-limit meter from the trusted local `codex app-server` API, caches it for one minute, and retains the last good reading across transient collector failures. Set `SHELTIE_CODEX_BINARY` when Codex is not on the service manager's `PATH`; `SHELTIE_USAGE_FILE` remains an explicit local-file override.

Per-Space todo access resolves `todo.md` from Herdr's authoritative workspace root, uses revision-based conflict checks and atomic saves, and rejects path escapes, symlinks, oversized files, and invalid UTF-8. Todo content is never audited.

Optional done/blocked push alerts travel directly from the selected bridge host to APNs. Configure all `SHELTIE_APNS_*` values together with an Apple Push Notification service signing key kept outside Git. Without those credentials the bridge does not advertise notification delivery.

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
2. P-256 device pairing with the six-digit code printed on the bridge host.

Pairing creates a revocable device credential. The app exchanges that credential for a 15-minute session token; API and WebSocket access use only the short-lived token. Sensitive actions are appended to `~/.config/sheltie/audit.jsonl` without terminal text or keys.

## Managed macOS service

[`citadel.service.json`](citadel.service.json) is the machine-service contract used
by Citadel. It provides the same command, health-check, restart, and graceful-stop
metadata as other locally managed projects. `bun run service:start` is the stable
production entry point consumed by that contract.

Citadel should reference a private `~/.config/sheltie/bridge.env` file rather than
copying credentials into its service registry. The bridge remains loopback-only;
Tailscale Serve is configured independently during deployment. Linux and WSL hosts
should continue to use the systemd unit below.

## WSL2 and Linux service

Run Herdr, Bun, the Sheltie bridge, and Tailscale inside the same WSL distro. This preserves the loopback-only boundary; proxying from Windows-host Tailscale to a non-loopback WSL listener is not supported.

On WSL2, enable systemd in `/etc/wsl.conf`, run `wsl --shutdown` from Windows, restart the distro, then install and authenticate Tailscale inside WSL. Create a private environment file and install the user service:

```bash
mkdir -p ~/.config/sheltie
cp bridge/.env.example ~/.config/sheltie/bridge.env
chmod 600 ~/.config/sheltie/bridge.env
# Edit bridge.env with this host's unique name, MagicDNS host, login allowlist, and Herdr paths.
bridge/scripts/install-systemd-user-service.sh
systemctl --user status sheltie-bridge.service
```

For startup without an interactive Linux login, enable lingering once with `sudo loginctl enable-linger "$USER"`. The installer records absolute Bun and repository paths, so rerun it after moving the checkout or Bun installation.

Verify loopback health before enabling ingress:

```bash
curl http://127.0.0.1:9847/v1/health
tailscale serve --bg --https=443 --set-path=/sheltie http://127.0.0.1:9847
```

Use the WSL distro's Tailscale MagicDNS URL when pairing. Never enable Funnel or `SHELTIE_DEV_MODE` for this service.

Provider quota is optional. A trusted local collector may write the file named by `SHELTIE_USAGE_FILE` as a JSON array with `id`, `provider`, `label`, `remainingFraction`, `resetAtMillis`, and `observedAtMillis`. Invalid or stale-source files do not block Herdr access; the app simply hides the meter.

List and revoke paired devices locally:

```bash
bun run admin devices
bun run admin revoke <device-id>
```

Restart the bridge after revocation to evict any in-memory short-lived session immediately.

Expose the bridge under a dedicated path so it can coexist with other tailnet services:

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
