#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/opt/installer-codex/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

SESSION_NAME="${INSTALLER_CODEX_TMUX_SESSION:-codex}"
PROJECT_DIR="${INSTALLER_CODEX_PROJECT_DIR:-/opt/installer-codex/workspace}"

mkdir -p "$PROJECT_DIR"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  exit 0
fi

tmux new-session -d -s "$SESSION_NAME" "cd '$PROJECT_DIR' && bash"

