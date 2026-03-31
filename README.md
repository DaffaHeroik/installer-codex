# installer-codex

`installer-codex` is a lightweight VPS kit for running Codex on your server and controlling the login/session flow from a mobile app or other remote client.

## What it gives you

- Ubuntu installer for a fresh VPS
- `systemd` services for backend startup and tmux session bootstrapping
- FastAPI backend for:
  - server status
  - device-auth login start/status
  - logout
  - auth cache export/import for VPS migration
- persistent tmux session so Codex work survives phone disconnects

## Architecture

- Codex CLI runs on the VPS
- Login happens with `codex login --device-auth`
- Your mobile app calls the backend API to:
  - start login
  - poll login state
  - check server health
  - import/export `~/.codex/auth.json`
- If the VPS is offline, your app should show `No server available`

## Important security note

`~/.codex/auth.json` behaves like a password. Never commit it to GitHub. If you use the import/export endpoints, protect them with `INSTALLER_CODEX_API_TOKEN`, HTTPS, and your own access controls.

## Quick start on a new VPS

Clone or install from your GitHub repo:

```bash
git clone <your-repo-url> /opt/installer-codex
cd /opt/installer-codex
cp .env.example .env
bash scripts/bootstrap.sh
```

Or use the one-shot installer:

```bash
curl -fsSL <raw-install-script-url> -o /tmp/install-codex.sh
bash /tmp/install-codex.sh <your-repo-url>
```

## Environment

Edit `/opt/installer-codex/.env`:

```env
INSTALLER_CODEX_HOST=0.0.0.0
INSTALLER_CODEX_PORT=8787
INSTALLER_CODEX_HOME=/opt/installer-codex/state
INSTALLER_CODEX_PROJECT_DIR=/opt/installer-codex/workspace
INSTALLER_CODEX_TMUX_SESSION=codex
INSTALLER_CODEX_USER=root
INSTALLER_CODEX_CLI_BIN=/usr/bin/codex
INSTALLER_CODEX_SERVER_NAME=vps-main
INSTALLER_CODEX_API_TOKEN=change-me
```

Restart after edits:

```bash
systemctl restart codex-session.service
systemctl restart codex-backend.service
```

## API

All API routes accept `X-API-Token` if you configured `INSTALLER_CODEX_API_TOKEN`.

### `GET /health`

Simple healthcheck.

### `GET /api/status`

Returns server status for your app. Use this to decide whether to show `Connected`, `Login required`, or `No server available`.

### `POST /api/session/start`

Ensures the tmux session exists.

### `POST /api/login/start`

Starts `codex login --device-auth`.

### `GET /api/login/status`

Returns the current login state. Your app should poll this after starting login.

### `POST /api/logout`

Logs Codex out and removes the local auth cache.

### `GET /api/session/export`

Exports `~/.codex/auth.json` as base64 for migration to a new VPS. Treat it like a password.

### `POST /api/session/import`

Imports a previously exported auth payload. Request body:

```json
{
  "auth_b64": "<base64-auth-json>"
}
```

## Suggested mobile app flow

1. App calls `GET /api/status`
2. If the server is unreachable, show `No server available`
3. If reachable but `auth_present` is `false`, show `Login required`
4. User taps login
5. App calls `POST /api/login/start`
6. App polls `GET /api/login/status`
7. App displays `login_url` and `device_code`
8. User completes login in the phone browser
9. App polls until `phase=completed`

## VPS migration without re-login

1. On the old VPS, call `GET /api/session/export`
2. Store the returned `auth_b64` in your own secure private store
3. Install this repo on the new VPS
4. Call `POST /api/session/import`
5. Restart `codex-backend.service` if needed

This reduces repeated login prompts, but re-auth can still be required if the token expires, is revoked, or OpenAI requests a fresh login.

## GitHub push

Inside this repo:

```bash
git init
git add .
git commit -m "Initial installer-codex scaffold"
gh repo create installer-codex --public --source=. --remote=origin --push
```

If you prefer private:

```bash
gh repo create installer-codex --private --source=. --remote=origin --push
```
