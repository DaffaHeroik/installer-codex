#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
VENV_PATH="$APP_ROOT/.venv"
ENV_FILE="$APP_ROOT/.env"
STATE_DIR="$APP_ROOT/state"
WORKSPACE_DIR="$APP_ROOT/workspace"

mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$APP_ROOT/.env.example" "$ENV_FILE"
fi

python3 -m venv "$VENV_PATH"
"$VENV_PATH/bin/pip" install --upgrade pip
"$VENV_PATH/bin/pip" install -r "$APP_ROOT/requirements.txt"

npm install -g @openai/codex

install -m 0644 "$APP_ROOT/systemd/codex-backend.service" /etc/systemd/system/codex-backend.service
install -m 0644 "$APP_ROOT/systemd/codex-session.service" /etc/systemd/system/codex-session.service
install -m 0755 "$APP_ROOT/scripts/ensure_tmux_session.sh" /usr/local/bin/ensure-codex-tmux-session

systemctl daemon-reload
systemctl enable codex-backend.service
systemctl enable codex-session.service
systemctl restart codex-session.service
systemctl restart codex-backend.service

echo "Bootstrap complete."

