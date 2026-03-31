#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
ENV_FILE="$APP_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

HOST="${INSTALLER_CODEX_HOST:-0.0.0.0}"
PORT="${INSTALLER_CODEX_PORT:-8787}"

cd "$APP_ROOT/backend"
exec "$APP_ROOT/.venv/bin/uvicorn" app:app --host "$HOST" --port "$PORT"
