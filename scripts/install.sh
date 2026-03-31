#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
REPO_URL="${1:-}"

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

bash "$APP_ROOT/scripts/bootstrap.sh"

echo "Installer complete."
echo "Next step: edit $APP_ROOT/.env and restart services if needed."

