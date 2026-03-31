import base64
import json
import os
import re
import shutil
import stat
import subprocess
import threading
import time
from pathlib import Path
from typing import Any


LOGIN_URL_RE = re.compile(r"https?://\S+")
LOGIN_CODE_RE = re.compile(r"\b[A-Z0-9]{4}(?:-[A-Z0-9]{4})+\b")


class CodexManager:
    def __init__(self) -> None:
        self.base_dir = Path(os.getenv("INSTALLER_CODEX_HOME", "/opt/installer-codex/state"))
        self.project_dir = Path(os.getenv("INSTALLER_CODEX_PROJECT_DIR", "/opt/installer-codex/workspace"))
        self.tmux_session = os.getenv("INSTALLER_CODEX_TMUX_SESSION", "codex")
        self.codex_bin = os.getenv("INSTALLER_CODEX_CLI_BIN", shutil.which("codex") or "/usr/bin/codex")
        self.server_name = os.getenv("INSTALLER_CODEX_SERVER_NAME", "codex-vps")
        self.login_process: subprocess.Popen[str] | None = None
        self.state_lock = threading.Lock()
        self.state_file = self.base_dir / "login_state.json"
        self.log_file = self.base_dir / "login.log"
        self.base_dir.mkdir(parents=True, exist_ok=True)
        self.project_dir.mkdir(parents=True, exist_ok=True)
        self._ensure_state()

    @property
    def auth_file(self) -> Path:
        return Path.home() / ".codex" / "auth.json"

    @property
    def config_file(self) -> Path:
        return Path.home() / ".codex" / "config.toml"

    def _ensure_state(self) -> None:
        if not self.state_file.exists():
            self._write_state(
                {
                    "phase": "idle",
                    "message": "No active login flow.",
                    "updated_at": int(time.time()),
                    "server_name": self.server_name,
                }
            )

    def _read_state(self) -> dict[str, Any]:
        if not self.state_file.exists():
            return {}
        return json.loads(self.state_file.read_text(encoding="utf-8"))

    def _write_state(self, data: dict[str, Any]) -> dict[str, Any]:
        payload = {**data, "updated_at": int(time.time()), "server_name": self.server_name}
        self.state_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        return payload

    def _run(self, args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            args,
            check=check,
            text=True,
            capture_output=True,
            cwd=str(self.project_dir),
        )

    def command_exists(self) -> bool:
        return Path(self.codex_bin).exists() or shutil.which(self.codex_bin) is not None

    def tmux_session_exists(self) -> bool:
        result = subprocess.run(
            ["tmux", "has-session", "-t", self.tmux_session],
            text=True,
            capture_output=True,
            check=False,
        )
        return result.returncode == 0

    def ensure_tmux_session(self) -> dict[str, Any]:
        if self.tmux_session_exists():
            return {"ok": True, "message": "Session already exists.", "session": self.tmux_session}

        self.project_dir.mkdir(parents=True, exist_ok=True)
        env_export = f"cd {self.project_dir} && clear && printf 'Codex session ready in {self.project_dir}\\n'"
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", self.tmux_session, env_export],
            text=True,
            capture_output=True,
            check=True,
        )
        return {"ok": True, "message": "Session created.", "session": self.tmux_session}

    def logout(self) -> dict[str, Any]:
        if self.command_exists():
            subprocess.run([self.codex_bin, "logout"], text=True, capture_output=True, check=False)

        if self.auth_file.exists():
            self.auth_file.unlink()

        state = self._write_state(
            {
                "phase": "idle",
                "message": "Logged out.",
                "login_url": None,
                "device_code": None,
            }
        )
        return {"ok": True, "state": state}

    def export_auth(self) -> dict[str, Any]:
        if not self.auth_file.exists():
            return {"ok": False, "message": "No auth file found."}

        encoded = base64.b64encode(self.auth_file.read_bytes()).decode("ascii")
        return {
            "ok": True,
            "filename": "auth.json.base64",
            "auth_b64": encoded,
            "message": "Treat this payload like a password.",
        }

    def import_auth(self, auth_b64: str) -> dict[str, Any]:
        decoded = base64.b64decode(auth_b64.encode("ascii"))
        self.auth_file.parent.mkdir(parents=True, exist_ok=True)
        self.auth_file.write_bytes(decoded)
        self.auth_file.chmod(stat.S_IRUSR | stat.S_IWUSR)
        return {"ok": True, "message": f"Imported auth cache into {self.auth_file}."}

    def _capture_login(self) -> None:
        assert self.login_process is not None
        with self.log_file.open("w", encoding="utf-8") as log_handle:
            parsed_url = None
            parsed_code = None
            self._write_state(
                {
                    "phase": "waiting_for_browser",
                    "message": "Waiting for device auth instructions.",
                    "login_url": None,
                    "device_code": None,
                }
            )

            for raw_line in self.login_process.stdout or []:
                line = raw_line.strip()
                log_handle.write(raw_line)
                log_handle.flush()

                if not parsed_url:
                    match = LOGIN_URL_RE.search(line)
                    if match:
                        parsed_url = match.group(0)

                if not parsed_code:
                    match = LOGIN_CODE_RE.search(line)
                    if match:
                        parsed_code = match.group(0)

                self._write_state(
                    {
                        "phase": "waiting_for_browser",
                        "message": line or "Waiting for device auth instructions.",
                        "login_url": parsed_url,
                        "device_code": parsed_code,
                    }
                )

            return_code = self.login_process.wait()
            if return_code == 0 and self.auth_file.exists():
                self._write_state(
                    {
                        "phase": "completed",
                        "message": "Login completed successfully.",
                        "login_url": parsed_url,
                        "device_code": parsed_code,
                    }
                )
            else:
                self._write_state(
                    {
                        "phase": "failed",
                        "message": f"Login exited with code {return_code}.",
                        "login_url": parsed_url,
                        "device_code": parsed_code,
                    }
                )

            self.login_process = None

    def start_login(self) -> dict[str, Any]:
        with self.state_lock:
            if self.login_process and self.login_process.poll() is None:
                return {"ok": True, "message": "Login flow already running.", "state": self._read_state()}

            if not self.command_exists():
                return {"ok": False, "message": f"Codex binary not found at {self.codex_bin}."}

            self.log_file.parent.mkdir(parents=True, exist_ok=True)
            self.login_process = subprocess.Popen(
                [self.codex_bin, "login", "--device-auth"],
                cwd=str(self.project_dir),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            threading.Thread(target=self._capture_login, daemon=True).start()

        time.sleep(1.0)
        return {"ok": True, "message": "Started device auth login.", "state": self._read_state()}

    def status(self) -> dict[str, Any]:
        state = self._read_state()
        auth_present = self.auth_file.exists()
        tmux_session_exists = self.tmux_session_exists()
        codex_installed = self.command_exists()
        if not codex_installed:
            availability = "setup_required"
            summary = "Codex CLI is not installed on this VPS yet."
        elif not auth_present:
            availability = "login_required"
            summary = "Codex is installed, but login is still required."
        elif not tmux_session_exists:
            availability = "session_stopped"
            summary = "Codex auth is ready, but the tmux session is not running."
        else:
            availability = "connected"
            summary = "Codex is ready on this VPS."

        return {
            "ok": True,
            "server_name": self.server_name,
            "availability": availability,
            "summary": summary,
            "codex_installed": codex_installed,
            "auth_present": auth_present,
            "config_present": self.config_file.exists(),
            "tmux_session": self.tmux_session,
            "tmux_session_exists": tmux_session_exists,
            "project_dir": str(self.project_dir),
            "auth_file": str(self.auth_file),
            "state": state,
        }
