# Security model

Sheltie provides remote input to real Mac terminal processes. Treat bridge access as remote code execution with the privileges of the user running Herdr.

## Trust boundaries

1. **Tailnet:** Tailscale controls network reachability and supplies TLS.
2. **Serve ingress:** the bridge validates the expected Host and allowlisted `Tailscale-User-Login` header.
3. **Device pairing:** an iPhone/iPad-held P-256 private key signs a fresh bridge challenge and the user enters a six-digit code displayed on the Mac.
4. **Device credential:** pairing returns a random credential stored in the device Keychain; the bridge stores only its SHA-256 hash.
5. **Short-lived session:** the device credential is exchanged for an in-memory 15-minute bearer token used by HTTPS and WebSocket requests.
6. **Herdr adapter:** only an explicit action allowlist reaches the Unix socket.

Tailscale identity alone does not authorize writes. A caller-provided device name, ID, Host, or identity header is not sufficient on its own.

## Host deployment requirements

- Bind the bridge only to `127.0.0.1` or `::1`.
- Expose it with Tailscale Serve, never Funnel.
- Set `SHELTIE_EXPECTED_HOST` to the MagicDNS host used by the app.
- Set `SHELTIE_ALLOWED_TAILSCALE_LOGINS` explicitly.
- Keep `SHELTIE_DEV_MODE` disabled whenever Serve is active.
- Store bridge data under a private user-owned directory.
- Run Herdr and the bridge as the intended non-root user.

The process refuses non-loopback binding and refuses production startup without an allowlisted Tailscale login.

## Pairing and credentials

The Apple mobile client uses Secure Enclave P-256 signing when available and a Keychain-protected software P-256 key in environments such as Simulator. Pairing requests expire after five minutes, allow at most five code attempts, and are globally bounded to prevent unbounded pending state.

The pairing code and signature prove two separate facts:

- the user can see the Mac bridge console; and
- the requester possesses the device private key corresponding to the submitted public key.

Device access tokens are shown only once. They are stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on iPhone and iPad and hashed at rest on the Mac.

## Revocation

List and revoke devices on the Mac:

```bash
cd bridge
bun run admin devices
bun run admin revoke <device-id>
```

Restart the bridge after revocation to discard any already-issued in-memory session immediately. Otherwise the maximum remaining session lifetime is 15 minutes.

## Request controls

- HTTP bodies are limited to 128 KiB.
- Terminal text and agent messages are limited to 64 KiB.
- Workspace `todo.md` is resolved from authoritative Herdr state, rejects symlinks and path escapes, and is limited to 256 KiB of UTF-8 Markdown.
- Workspace file browsing is confined to authoritative Herdr roots. It rejects absolute paths, traversal, symlinks, binary/invalid UTF-8 data, and files above 1 MiB; saves use short-lived opaque handles bound to the paired device.
- Key batches are limited to 32 validated key names.
- A WebSocket may subscribe to at most eight terminal panes.
- Terminal dimensions are clamped.
- Herdr methods are selected by a closed action switch; clients cannot submit arbitrary method names.
- Slow terminal consumers receive bounded current frames rather than an unbounded history queue.

## Audit and sensitive data

Write and structural actions are appended to `audit.jsonl` with device, request, session, action type, target, result, and time. Todo and workspace-file writes are audited without file content. Terminal text, todo content, workspace-file content, key values, access tokens, pairing codes, APNs device tokens, live terminal frames, and terminal-history snapshots are intentionally omitted.

APNs provider keys stay in a host-local file outside Git. Push payloads are deliberately generic and contain no project names, paths, pane IDs, prompts, or terminal output. Revoked devices and APNs-invalid tokens are excluded from future delivery.

Do not place secrets in diagnostics, screenshots, usage-meter files, or committed configuration. The ignored design directory is not a secret store.

## Known limitations before public release

- The implementation has not received an independent security audit.
- Tailscale identity-header behavior must be reverified against the deployed Serve version.
- Device revocation currently requires a bridge restart for immediate session eviction.
- Secure Enclave user-presence policy is intentionally not required for every terminal keystroke.
- Dependency and bridge update signing/distribution are not yet defined.
- App Store privacy, encryption/export, and incident-response documentation remain open.
