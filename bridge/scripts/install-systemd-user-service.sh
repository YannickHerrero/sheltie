#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer is for Linux and WSL. Use the macOS LaunchAgent workflow on macOS." >&2
  exit 1
fi

bridge_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${SHELTIE_ENV_FILE:-$HOME/.config/sheltie/bridge.env}"
bun_binary="$(command -v bun || true)"

if [[ -z "$bun_binary" ]]; then
  echo "Bun is not installed or is not on PATH." >&2
  exit 1
fi
if [[ ! -f "$env_file" ]]; then
  echo "Missing private bridge environment file: $env_file" >&2
  echo "Copy bridge/.env.example there, configure it, and rerun this installer." >&2
  exit 1
fi
if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "A systemd user manager is required. On WSL, enable systemd in /etc/wsl.conf and restart the distro." >&2
  exit 1
fi

chmod 600 "$env_file"
unit_dir="$HOME/.config/systemd/user"
unit_path="$unit_dir/sheltie-bridge.service"
mkdir -p "$unit_dir"

escape_systemd() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

bridge_dir_escaped="$(escape_systemd "$bridge_dir")"
env_file_escaped="$(escape_systemd "$env_file")"
bun_binary_escaped="$(escape_systemd "$bun_binary")"
home_escaped="$(escape_systemd "$HOME")"

cat > "$unit_path" <<EOF
[Unit]
Description=Sheltie bridge for Herdr
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory="$bridge_dir_escaped"
Environment="HOME=$home_escaped"
EnvironmentFile="$env_file_escaped"
ExecStart="$bun_binary_escaped" "$bridge_dir_escaped/src/index.ts"
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF

chmod 600 "$unit_path"
systemctl --user daemon-reload
systemctl --user enable --now sheltie-bridge.service

echo "Installed and started sheltie-bridge.service"
echo "Check it with: systemctl --user status sheltie-bridge.service"
