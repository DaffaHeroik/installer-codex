#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
ENV_FILE="$APP_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

API_TOKEN="${INSTALLER_CODEX_API_TOKEN:-change-me}"
QUICK_TUNNEL_STATE_FILE="${INSTALLER_CODEX_QUICK_TUNNEL_STATE_FILE:-/opt/installer-codex/state/quick_tunnel_url.txt}"
FIREBASE_DB_URL="${INSTALLER_CODEX_FIREBASE_DB_URL:-}"
FIREBASE_SERVERS_PATH="${INSTALLER_CODEX_FIREBASE_SERVERS_PATH:-codex_servers}"
SERVER_ID="${INSTALLER_CODEX_SERVER_ID:-}"

if [[ -z "$SERVER_ID" ]]; then
  SERVER_ID="$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
fi

ok() {
  printf '[doctor] OK: %s\n' "$1"
}

fail() {
  printf '[doctor] FAIL: %s\n' "$1" >&2
  exit 1
}

curl -fsS http://127.0.0.1:8787/health >/dev/null \
  && ok "backend local health is reachable" \
  || fail "backend local health is not reachable at 127.0.0.1:8787"

tmux has-session -t "${INSTALLER_CODEX_TMUX_SESSION:-codex}" 2>/dev/null \
  && ok "tmux session exists" \
  || fail "tmux session is missing"

if [[ "${INSTALLER_CODEX_ENABLE_QUICK_TUNNEL:-true}" == "true" ]]; then
  [[ -f "$QUICK_TUNNEL_STATE_FILE" ]] || fail "quick tunnel state file is missing"
  QUICK_URL="$(tr -d '\r\n' < "$QUICK_TUNNEL_STATE_FILE")"
  [[ -n "$QUICK_URL" ]] || fail "quick tunnel URL is empty"
  curl -fsS "$QUICK_URL/health" >/dev/null \
    && ok "quick tunnel health is reachable" \
    || fail "quick tunnel URL is not healthy"
fi

if [[ -n "$FIREBASE_DB_URL" ]]; then
  FIREBASE_JSON="$(curl -fsS "${FIREBASE_DB_URL%/}/${FIREBASE_SERVERS_PATH}/${SERVER_ID}.json" || true)"
  [[ -n "$FIREBASE_JSON" && "$FIREBASE_JSON" != "null" ]] \
    && ok "firebase registry entry exists" \
    || fail "firebase registry entry is missing"
fi

curl -fsS http://127.0.0.1:8787/api/app/overview -H "X-API-Token: $API_TOKEN" >/dev/null \
  && ok "backend overview endpoint responds" \
  || fail "backend overview endpoint failed"

printf '[doctor] All checks passed.\n'
