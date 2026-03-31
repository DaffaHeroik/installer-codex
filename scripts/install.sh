#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
REPO_URL="${1:-}"
AUTH_B64_FILE="${2:-}"

if [[ -z "$REPO_URL" ]]; then
  echo "Usage: ./scripts/install.sh <git-repo-url>"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl git tmux python3 python3-venv python3-pip ca-certificates

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
fi

mkdir -p "$APP_ROOT"

if [[ ! -d "$APP_ROOT/.git" ]]; then
  git clone "$REPO_URL" "$APP_ROOT"
else
  git -C "$APP_ROOT" pull --ff-only
fi

if [[ -n "$AUTH_B64_FILE" ]]; then
  mkdir -p "$APP_ROOT/auth"
  cp "$AUTH_B64_FILE" "$APP_ROOT/auth/auth.json.base64"
fi

bash "$APP_ROOT/scripts/bootstrap.sh"

echo "Installer complete."
echo "Next step: edit $APP_ROOT/.env and restart services if needed."
if [[ -n "$AUTH_B64_FILE" ]]; then
  echo "Auth restore file argument detected: $AUTH_B64_FILE"
fi
