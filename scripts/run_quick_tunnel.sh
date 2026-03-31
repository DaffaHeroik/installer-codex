#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
ENV_FILE="$APP_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

PORT="${INSTALLER_CODEX_PORT:-8787}"
STATE_FILE="${INSTALLER_CODEX_QUICK_TUNNEL_STATE_FILE:-/opt/installer-codex/state/quick_tunnel_url.txt}"

mkdir -p "$(dirname "$STATE_FILE")"
rm -f "$STATE_FILE"

cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${PORT}" 2>&1 | while IFS= read -r line; do
  printf '%s\n' "$line"
  tunnel_url="$(printf '%s' "$line" | grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' | head -n 1 || true)"
  if [[ -n "$tunnel_url" ]]; then
    printf '%s' "$tunnel_url" > "$STATE_FILE"
  fi
done
