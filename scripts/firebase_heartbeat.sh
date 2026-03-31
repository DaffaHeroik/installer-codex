#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
ENV_FILE="$APP_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

SERVER_ID="${INSTALLER_CODEX_SERVER_ID:-}"
SERVER_NAME="${INSTALLER_CODEX_SERVER_NAME:-vps-main}"
FIREBASE_DB_URL="${INSTALLER_CODEX_FIREBASE_DB_URL:-}"
FIREBASE_AUTH="${INSTALLER_CODEX_FIREBASE_AUTH:-}"
FIREBASE_SERVERS_PATH="${INSTALLER_CODEX_FIREBASE_SERVERS_PATH:-codex_servers}"
HEARTBEAT_SECONDS="${INSTALLER_CODEX_FIREBASE_HEARTBEAT_SECONDS:-30}"
API_TOKEN="${INSTALLER_CODEX_API_TOKEN:-change-me}"
PUBLIC_BASE_URL="${INSTALLER_CODEX_PUBLIC_BASE_URL:-}"
ENABLE_QUICK_TUNNEL="${INSTALLER_CODEX_ENABLE_QUICK_TUNNEL:-true}"
QUICK_TUNNEL_STATE_FILE="${INSTALLER_CODEX_QUICK_TUNNEL_STATE_FILE:-/opt/installer-codex/state/quick_tunnel_url.txt}"

if [[ -z "$SERVER_ID" ]]; then
  if command -v hostname >/dev/null 2>&1; then
    SERVER_ID="$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  else
    SERVER_ID="codex-server"
  fi
fi

if [[ -z "$FIREBASE_DB_URL" ]]; then
  echo "INSTALLER_CODEX_FIREBASE_DB_URL is empty; exiting heartbeat loop."
  exit 0
fi

detect_public_url() {
  if [[ "$ENABLE_QUICK_TUNNEL" == "true" ]] && [[ -f "$QUICK_TUNNEL_STATE_FILE" ]]; then
    local quick_tunnel_url
    quick_tunnel_url="$(tr -d '\r\n' < "$QUICK_TUNNEL_STATE_FILE")"
    if [[ -n "$quick_tunnel_url" ]]; then
      printf '%s' "$quick_tunnel_url"
      return 0
    fi
  fi

  if [[ -n "$PUBLIC_BASE_URL" ]]; then
    printf '%s' "$PUBLIC_BASE_URL"
    return 0
  fi

  local ip
  ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -n "$ip" ]]; then
    printf 'http://%s' "$ip"
  fi
}

build_payload() {
  local base_url overview now
  base_url="$(detect_public_url)"
  overview="$(curl -fsS --max-time 15 http://127.0.0.1:8787/api/app/overview -H "X-API-Token: $API_TOKEN" || true)"
  now="$(date +%s)"

  python3 - "$SERVER_ID" "$SERVER_NAME" "$base_url" "$API_TOKEN" "$now" "$overview" <<'PY'
import json
import sys

server_id, server_name, server_url, api_token, updated_at, overview = sys.argv[1:]

try:
    overview_data = json.loads(overview) if overview else {}
except json.JSONDecodeError:
    overview_data = {}

payload = {
    "server_id": server_id,
    "server_name": server_name,
    "server_url": server_url,
    "api_token": api_token,
    "status": "online" if overview_data else "degraded",
    "updated_at": int(updated_at),
    "availability": overview_data.get("availability", "unknown"),
    "summary": overview_data.get("summary", "No summary available."),
    "auth_present": overview_data.get("auth_present", False),
    "tmux_session_exists": overview_data.get("tmux_session_exists", False),
}

print(json.dumps(payload, separators=(",", ":")))
PY
}

publish_payload() {
  local payload url
  payload="$(build_payload)"
  url="${FIREBASE_DB_URL%/}/${FIREBASE_SERVERS_PATH}/${SERVER_ID}.json"
  if [[ -n "$FIREBASE_AUTH" ]]; then
    url="${url}?auth=${FIREBASE_AUTH}"
  fi
  curl -fsS -X PUT -H "Content-Type: application/json" -d "$payload" "$url" >/dev/null
}

while true; do
  publish_payload || true
  sleep "$HEARTBEAT_SECONDS"
done
