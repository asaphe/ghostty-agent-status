from __future__ import annotations

import json
import os
import tempfile
import uuid
from pathlib import Path


def registry() -> Path:
    base = Path(os.environ.get("GHOSTTY_AGENT_STATUS_DIR") or Path.home() / ".local/state/ghostty-agent-status")
    return base / "diagnostics" / "routes.json"


def route_for(agent: str, session_id: str) -> dict | None:
    try:
        session = str(uuid.UUID(session_id))
        data = json.loads(registry().read_text(encoding="utf-8"))
        route = data.get(f"{agent}-{session}")
        if agent not in {"claude", "codex"} or not isinstance(route, dict):
            return None
        source, output = Path(route["source"]), Path(route["output"])
        if not source.is_absolute() or not output.is_absolute():
            return None
        if not all((source / name).is_file() for name in ("ghostty-status.py", "terminal_status.py", "diagnostics.py", "ghostty_tabs.py")):
            return None
        return {"source": str(source), "output": str(output)}
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None


def set_route(agent: str, session_id: str, source: str | None, output: str | None) -> None:
    session = str(uuid.UUID(session_id))
    if agent not in {"claude", "codex"}:
        raise ValueError("invalid agent")
    path = registry()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    if path.is_symlink():
        raise ValueError("route registry must not be a symlink")
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if not isinstance(data, dict):
        raise ValueError("invalid route registry")
    key = f"{agent}-{session}"
    if source is None:
        data.pop(key, None)
    else:
        source_path = Path(source).resolve(strict=True)
        if not all((source_path / name).is_file() for name in ("ghostty-status.py", "terminal_status.py", "diagnostics.py", "ghostty_tabs.py")):
            raise ValueError("diagnostic source is incomplete")
        data[key] = {"source": str(source_path), "output": str(Path(output).resolve())}
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".routes-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
