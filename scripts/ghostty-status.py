#!/usr/bin/env python3
"""Hook entry for every lifecycle event: `ghostty-status.py claude|codex`, the session's payload on stdin.

Never blocks and never prints: exits 0 always, and the Ghostty work runs in a detached worker.
Codex runs hooks in a shared app-server daemon whose environment may belong to another
terminal, so only Claude is gated on TERM_PROGRAM; terminal_status finds a Codex thread's tab itself.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main() -> int:
    try:
        agent = sys.argv[1] if len(sys.argv) > 1 else "claude"
        payload = json.loads(sys.stdin.buffer.read() or b"{}")
        if agent not in ("claude", "codex") or not isinstance(payload, dict):
            return 0
        if agent == "claude" and os.environ.get("TERM_PROGRAM", "").casefold() != "ghostty":
            return 0
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import terminal_status

        terminal_status.update(agent, payload)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
