#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/opt/installer-codex"
VENV_PATH="$APP_ROOT/.venv"
ENV_FILE="$APP_ROOT/.env"
STATE_DIR="$APP_ROOT/state"
WORKSPACE_DIR="$APP_ROOT/workspace"
CODEX_HOME="${HOME}/.codex"
AUTH_FILE="${CODEX_HOME}/auth.json"
NGINX_SITE_PATH="/etc/nginx/sites-available/installer-codex"
NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/installer-codex"
QUICK_TUNNEL_SCRIPT_PATH="/usr/local/bin/installer-codex-quick-tunnel"

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

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    return 0
  fi

  local arch download_url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
      ;;
    aarch64|arm64)
      download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
      ;;
    *)
      log "Unsupported architecture for cloudflared auto-install: $arch"
      return 1
      ;;
  esac

  curl -LfsS "$download_url" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
}

setup_nginx() {
  if [[ "${INSTALLER_CODEX_ENABLE_NGINX:-true}" != "true" ]]; then
    log "Skipping nginx setup because INSTALLER_CODEX_ENABLE_NGINX is not true."
    return 0
  fi

  ensure_package nginx

  cat > "$NGINX_SITE_PATH" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${INSTALLER_CODEX_NGINX_SERVER_NAME:-_};

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:${INSTALLER_CODEX_PORT:-8787};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 60;
    }
}
EOF

  ln -sf "$NGINX_SITE_PATH" "$NGINX_ENABLED_PATH"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl restart nginx

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
  fi

  log "Nginx reverse proxy is ready on port 80."
}

setup_quick_tunnel() {
  if [[ "${INSTALLER_CODEX_ENABLE_QUICK_TUNNEL:-true}" != "true" ]]; then
    log "Skipping Quick Tunnel because INSTALLER_CODEX_ENABLE_QUICK_TUNNEL is not true."
    return 0
  fi

  install_cloudflared
  install -m 0644 "$APP_ROOT/systemd/codex-quick-tunnel.service" /etc/systemd/system/codex-quick-tunnel.service
  install -m 0755 "$APP_ROOT/scripts/run_quick_tunnel.sh" "$QUICK_TUNNEL_SCRIPT_PATH"
  systemctl daemon-reload
  systemctl enable codex-quick-tunnel.service
  systemctl restart codex-quick-tunnel.service
  log "Cloudflare Quick Tunnel service is running."
}

setup_firebase_heartbeat() {
  if [[ -z "${INSTALLER_CODEX_FIREBASE_DB_URL:-}" ]]; then
    log "Skipping Firebase heartbeat because INSTALLER_CODEX_FIREBASE_DB_URL is empty."
    return 0
  fi

  install -m 0644 "$APP_ROOT/systemd/codex-firebase-heartbeat.service" /etc/systemd/system/codex-firebase-heartbeat.service
  install -m 0755 "$APP_ROOT/scripts/firebase_heartbeat.sh" /usr/local/bin/installer-codex-firebase-heartbeat
  systemctl daemon-reload
  systemctl enable codex-firebase-heartbeat.service
  systemctl restart codex-firebase-heartbeat.service
  log "Firebase heartbeat service is running."
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
ensure_package curl
ensure_python_venv
"$VENV_PATH/bin/pip" install --upgrade pip
"$VENV_PATH/bin/pip" install -r "$APP_ROOT/requirements.txt"

npm install -g @openai/codex
restore_codex_auth

install -m 0644 "$APP_ROOT/systemd/codex-backend.service" /etc/systemd/system/codex-backend.service
install -m 0644 "$APP_ROOT/systemd/codex-session.service" /etc/systemd/system/codex-session.service
install -m 0755 "$APP_ROOT/scripts/ensure_tmux_session.sh" /usr/local/bin/ensure-codex-tmux-session
install -m 0755 "$APP_ROOT/scripts/run_backend.sh" /usr/local/bin/installer-codex-run-backend

systemctl daemon-reload
systemctl enable codex-backend.service
systemctl enable codex-session.service
systemctl restart codex-session.service
systemctl restart codex-backend.service
setup_nginx
setup_quick_tunnel
setup_firebase_heartbeat

log "Bootstrap complete."
