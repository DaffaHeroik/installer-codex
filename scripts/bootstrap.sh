#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
VENV_PATH="$APP_ROOT/.venv"
ENV_FILE="$APP_ROOT/.env"
STATE_DIR="$APP_ROOT/state"
WORKSPACE_DIR="$APP_ROOT/workspace"
CODEX_HOME="${HOME}/.codex"
AUTH_FILE="${CODEX_HOME}/auth.json"

log() {
  printf '[installer-codex] %s\n' "$1"
}

ensure_package() {
  local package_name="$1"
  if dpkg -s "$package_name" >/dev/null 2>&1; then
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "$package_name"
}

ensure_python_venv() {
  if python3 -m venv "$VENV_PATH" >/dev/null 2>&1; then
    return 0
  fi

  local py_version
  py_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

  ensure_package "python3-venv" || true
  ensure_package "python${py_version}-venv"

  rm -rf "$VENV_PATH"
  python3 -m venv "$VENV_PATH"
}

restore_codex_auth() {
  local auth_b64=""

  mkdir -p "$CODEX_HOME"

  if [[ -f "$AUTH_FILE" ]]; then
    log "Existing Codex auth found at $AUTH_FILE. Preserving current login."
    return 0
  fi

  if [[ -n "${INSTALLER_CODEX_AUTH_B64_FILE:-}" ]] && [[ -f "${INSTALLER_CODEX_AUTH_B64_FILE}" ]]; then
    auth_b64="$(tr -d '\r\n' < "${INSTALLER_CODEX_AUTH_B64_FILE}")"
  elif [[ -f "$APP_ROOT/auth/auth.json.base64" ]]; then
    auth_b64="$(tr -d '\r\n' < "$APP_ROOT/auth/auth.json.base64")"
  elif [[ -n "${INSTALLER_CODEX_AUTH_B64:-}" ]]; then
    auth_b64="${INSTALLER_CODEX_AUTH_B64}"
  fi

  if [[ -z "$auth_b64" ]]; then
    log "No existing Codex auth found and no backup auth provided."
    return 0
  fi

  log "Restoring Codex auth into $AUTH_FILE."
  printf '%s' "$auth_b64" | base64 -d > "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"
}

mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$APP_ROOT/.env.example" "$ENV_FILE"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

ensure_package tmux
ensure_package python3
ensure_package python3-pip
ensure_python_venv
"$VENV_PATH/bin/pip" install --upgrade pip
"$VENV_PATH/bin/pip" install -r "$APP_ROOT/requirements.txt"

npm install -g @openai/codex
restore_codex_auth

install -m 0644 "$APP_ROOT/systemd/codex-backend.service" /etc/systemd/system/codex-backend.service
install -m 0644 "$APP_ROOT/systemd/codex-session.service" /etc/systemd/system/codex-session.service
install -m 0755 "$APP_ROOT/scripts/ensure_tmux_session.sh" /usr/local/bin/ensure-codex-tmux-session

systemctl daemon-reload
systemctl enable codex-backend.service
systemctl enable codex-session.service
systemctl restart codex-session.service
systemctl restart codex-backend.service

log "Bootstrap complete."
