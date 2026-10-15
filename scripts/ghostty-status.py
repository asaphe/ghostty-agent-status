#!/usr/bin/env python3
"""Hook entry for every lifecycle event: `ghostty-status.py claude|codex`, the session's payload on stdin.

Never blocks and never prints: exits 0 always, and the Ghostty work runs in a detached worker.
Codex runs hooks in a shared app-server daemon whose environment may belong to another
terminal, so only Claude is gated on TERM_PROGRAM; terminal_status finds a Codex thread's tab, and a
backgrounded Claude session's (which runs under Claude's daemon, outside Ghostty), itself.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path


def main() -> int:
    started = time.monotonic()
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    diagnostics = None
    agent = sys.argv[1] if len(sys.argv) > 1 else "claude"
    payload = None
    try:
        override = os.environ.get("GHOSTTY_AGENT_STATUS_DIAGNOSTIC_SOURCE")
        if os.environ.get("GHOSTTY_AGENT_STATUS_DIAGNOSTICS") == "1" and override:
            target = Path(override) / "ghostty-status.py"
            if target.is_file() and target.resolve() != Path(__file__).resolve():
                os.execv(sys.executable, [sys.executable, str(target), *sys.argv[1:]])
                return 0
        payload = json.loads(sys.stdin.buffer.read() or b"{}")
        from diagnostic_dispatch import route_for
        route = route_for(agent, payload.get("session_id")) if isinstance(payload, dict) else None
        if route:
            sys.path.insert(0, route["source"])
            os.environ["GHOSTTY_AGENT_STATUS_DIAGNOSTICS"] = "1"
            os.environ["GHOSTTY_AGENT_STATUS_DIAGNOSTICS_DIR"] = route["output"]
        import diagnostics

        if agent not in ("claude", "codex") or not isinstance(payload, dict):
            diagnostics.emit("hook.skipped", reason="invalid_agent_or_payload")
            return 0
        with diagnostics.scope(agent, payload.get("session_id")):
            diagnostics.emit("hook.stdin_read", elapsed_ms=(time.monotonic() - started) * 1000)
        if (agent == "claude" and os.environ.get("TERM_PROGRAM", "").casefold() != "ghostty"
                and os.environ.get("CLAUDE_CODE_SESSION_KIND") != "bg"):
            with diagnostics.scope(agent, payload.get("session_id")):
                diagnostics.emit("hook.skipped", reason="outside_ghostty")
            return 0
        import terminal_status

        terminal_status.update(agent, payload)
    except Exception as exc:
        if diagnostics is not None:
            with diagnostics.scope(agent, payload.get("session_id") if isinstance(payload, dict) else None):
                diagnostics.emit("hook.error", error_type=type(exc).__name__, elapsed_ms=(time.monotonic() - started) * 1000)
    return 0


if __name__ == "__main__":
    sys.exit(main())
