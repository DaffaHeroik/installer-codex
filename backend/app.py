import os
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from codex_manager import CodexManager


app = FastAPI(title="installer-codex", version="0.1.0")
manager = CodexManager()


class AuthImportRequest(BaseModel):
    auth_b64: str = Field(..., description="Base64-encoded ~/.codex/auth.json")


def verify_api_token(x_api_token: str | None = Header(default=None)) -> None:
    required_token = os.getenv("INSTALLER_CODEX_API_TOKEN", "").strip()
    if not required_token:
        return
    if x_api_token != required_token:
        raise HTTPException(status_code=401, detail="Invalid API token.")


@app.get("/health")
def healthcheck() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/status", dependencies=[Depends(verify_api_token)])
def status() -> dict:
    return manager.status()


@app.post("/api/session/start", dependencies=[Depends(verify_api_token)])
def start_session() -> dict:
    return manager.ensure_tmux_session()


@app.post("/api/login/start", dependencies=[Depends(verify_api_token)])
def start_login() -> dict:
    return manager.start_login()


@app.get("/api/login/status", dependencies=[Depends(verify_api_token)])
def login_status() -> dict:
    return {"ok": True, "state": manager.status()["state"]}


@app.post("/api/logout", dependencies=[Depends(verify_api_token)])
def logout() -> dict:
    return manager.logout()


@app.get("/api/session/export", dependencies=[Depends(verify_api_token)])
def export_auth() -> dict:
    payload = manager.export_auth()
    if not payload["ok"]:
        raise HTTPException(status_code=404, detail=payload["message"])
    return payload


@app.post("/api/session/import", dependencies=[Depends(verify_api_token)])
def import_auth(body: AuthImportRequest) -> dict:
    return manager.import_auth(body.auth_b64)


@app.get("/api/terminal/hint", dependencies=[Depends(verify_api_token)])
def terminal_hint() -> dict:
    project_dir = Path(os.getenv("INSTALLER_CODEX_PROJECT_DIR", "/opt/installer-codex/workspace"))
    tmux_session = os.getenv("INSTALLER_CODEX_TMUX_SESSION", "codex")
    return {
        "ok": True,
        "message": "Attach your existing SSH or Web terminal client to this tmux session.",
        "tmux_attach": f"tmux attach -t {tmux_session}",
        "project_dir": str(project_dir),
    }

