# installer-codex

`installer-codex` is a lightweight VPS kit for running Codex on your server and controlling the login/session flow from a mobile app or other remote client.

## What it gives you

- Ubuntu installer for a fresh VPS
- `systemd` services for backend startup and tmux session bootstrapping
- automatic `nginx` reverse proxy on port `80`
- optional Cloudflare Quick Tunnel with auto-updated URL
- Firebase auto-registration and heartbeat for server discovery
- FastAPI backend for:
  - server status
  - device-auth login start/status
  - logout
  - auth cache export/import for VPS migration
- Android app project for status, login, logout, and browser handoff
- persistent tmux session so Codex work survives phone disconnects

## Architecture

- Codex CLI runs on the VPS
- Login happens with `codex login --device-auth`
- If the machine already has `~/.codex/auth.json`, the installer preserves it
- If you provide a backup auth payload, the installer restores it automatically
- Your mobile app calls the backend API to:
  - start login
  - poll login state
  - check server health
  - import/export `~/.codex/auth.json`
- `nginx` exposes the app on standard web port `80`, so the APK can use `http://YOUR_VPS_IP`
- Quick Tunnel can publish a public `trycloudflare.com` URL even when your VPS inbound ports are blocked
- the VPS registers itself into Firebase so the APK can auto-discover it
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

If the VPS already has a Codex login at `~/.codex/auth.json`, `bootstrap.sh` keeps it and does not overwrite it.

If you are moving from another VPS and want automatic auth restore during install, use one of these:

1. Put a base64 backup file at `/opt/installer-codex/auth/auth.json.base64`
2. Or set `INSTALLER_CODEX_AUTH_B64` in `.env`
3. Or set `INSTALLER_CODEX_AUTH_B64_FILE` in `.env`

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
INSTALLER_CODEX_AUTH_B64=
INSTALLER_CODEX_AUTH_B64_FILE=
INSTALLER_CODEX_PUBLIC_BASE_URL=
INSTALLER_CODEX_ENABLE_NGINX=true
INSTALLER_CODEX_NGINX_SERVER_NAME=_
INSTALLER_CODEX_FIREBASE_DB_URL=https://kebun-pintar-dce3e-default-rtdb.firebaseio.com
INSTALLER_CODEX_FIREBASE_AUTH=
INSTALLER_CODEX_FIREBASE_SERVERS_PATH=codex_servers
INSTALLER_CODEX_FIREBASE_HEARTBEAT_SECONDS=30
INSTALLER_CODEX_SERVER_ID=
INSTALLER_CODEX_ENABLE_QUICK_TUNNEL=true
INSTALLER_CODEX_QUICK_TUNNEL_STATE_FILE=/opt/installer-codex/state/quick_tunnel_url.txt
```

Restart after edits:

```bash
systemctl restart codex-session.service
systemctl restart codex-backend.service
bash scripts/bootstrap.sh
```

## API

All API routes accept `X-API-Token` if you configured `INSTALLER_CODEX_API_TOKEN`.

### `GET /health`

Simple healthcheck.

### `GET /api/status`

Returns server status for your app. Use this to decide whether to show `Connected`, `Login required`, or `No server available`.

### `GET /api/app/overview`

Returns a simplified app-friendly payload with `availability`, `summary`, and the latest login state.

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

1. VPS heartbeat writes itself to Firebase
2. APK fetches the server list from Firebase
3. APK auto-picks the freshest online server
4. If no recent server exists, show `No server available`
5. If there are multiple servers, the user can select one manually
6. If a server is stale or dead, the user can delete it from the Firebase list
7. APK then calls your selected server's API for login, logout, and status actions

If two servers are online at the same time, the app will auto-connect to the newest heartbeat first, but manual selection is always available in the server list.

## Default access URL

After `bash scripts/bootstrap.sh`, the installer also configures `nginx` and exposes the backend on port `80`.

That means your APK should usually use:

```text
http://YOUR_VPS_IP
```

Instead of:

```text
http://YOUR_VPS_IP:8787
```

If your VPS provider has an external firewall panel, you still need to allow inbound `TCP 80`.

If port `80` is blocked by your VPS provider, keep:

```env
INSTALLER_CODEX_ENABLE_QUICK_TUNNEL=true
```

Then the installer will run `cloudflared`, capture the current `https://*.trycloudflare.com` URL, and publish that URL into Firebase automatically. The APK will pick it up on the next refresh without manual input.

## Firebase registry format

Each VPS writes one entry under:

```text
https://kebun-pintar-dce3e-default-rtdb.firebaseio.com/codex_servers/<server_id>.json
```

Example payload:

```json
{
  "server_id": "vps-main",
  "server_name": "vps-main",
  "server_url": "http://37.114.42.148",
  "api_token": "change-me",
  "status": "online",
  "updated_at": 1774920000,
  "availability": "connected",
  "summary": "Codex is ready on this VPS.",
  "auth_present": true,
  "tmux_session_exists": true
}
```

When Quick Tunnel is enabled, `server_url` will look like:

```json
{
  "server_url": "https://random-name.trycloudflare.com"
}
```

## VPS migration without re-login

1. On the old VPS, call `GET /api/session/export`
2. Store the returned `auth_b64` in your own secure private store
3. On the new VPS, do one of these before `bash scripts/bootstrap.sh`:
   - set `INSTALLER_CODEX_AUTH_B64` in `.env`
   - set `INSTALLER_CODEX_AUTH_B64_FILE` in `.env`
   - save the payload into `/opt/installer-codex/auth/auth.json.base64`
4. Run `bash scripts/bootstrap.sh`
5. The installer restores auth automatically if there is no existing `~/.codex/auth.json`
6. If you prefer API restore instead, call `POST /api/session/import`

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

## Android APK

The repo now includes an Android project in [`android-app`](/D:/ubot/installer-codex/android-app). It is intentionally simple for personal use:

- save `server_url` and `api_token`
- refresh server status
- start Codex login
- open the login URL in the phone browser
- show the device code
- logout and switch account

For HTTP access to a LAN or raw VPS IP, the app enables cleartext traffic to keep setup easy. For internet-facing use, HTTPS is still strongly recommended.

### Build in GitHub Actions

An Android workflow is included at [android.yml](/D:/ubot/installer-codex/.github/workflows/android.yml). Every push can build a debug APK artifact.

After the workflow succeeds, download the artifact from GitHub Actions and install the `app-debug.apk` on your phone.
