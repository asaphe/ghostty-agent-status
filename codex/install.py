#!/usr/bin/env python3
"""Add (or with --uninstall, remove) this repo's status hook in Codex's hooks.json.

Idempotent: an event that already runs this hook is left alone. The previous file is kept
as hooks.json.bak-<timestamp> before any change. The hook command points at this clone,
so keep the clone where it is. Codex runs a new or changed hook only after you trust it
in the TUI's hook review.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
          "SubagentStop", "Stop", "SessionEnd")
HOOK = Path(__file__).resolve().parents[1] / "scripts" / "ghostty-status.py"
MARKER = "ghostty-status.py"


def hooks_file() -> Path:
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "hooks.json"


def ours(hook: dict) -> bool:
    return MARKER in str(hook.get("command", "")) and "codex" in str(hook.get("command", ""))


def install(config: dict) -> int:
    command = f'"{HOOK}" codex'
    added = 0
    for event in EVENTS:
        groups = config.setdefault("hooks", {}).setdefault(event, [])
        if any(ours(h) for g in groups for h in g.get("hooks", [])):
            continue
        groups.append({"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 5}]})
        added += 1
    return added


def uninstall(config: dict) -> int:
    removed = 0
    for event, groups in list(config.get("hooks", {}).items()):
        for group in groups:
            kept = [h for h in group.get("hooks", []) if not ours(h)]
            removed += len(group.get("hooks", [])) - len(kept)
            group["hooks"] = kept
        config["hooks"][event] = [g for g in groups if g.get("hooks")]
        if not config["hooks"][event]:
            del config["hooks"][event]
    return removed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="print the result instead of writing it")
    args = parser.parse_args()
    path = hooks_file()
    config = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"hooks": {}}
    changed = uninstall(config) if args.uninstall else install(config)
    verb = "removed from" if args.uninstall else "added to"
    if args.dry_run:
        print(json.dumps(config, indent=2))
        print(f"dry run: {changed} event(s) would be {verb} {path}", file=sys.stderr)
        return 0
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            shutil.copy2(path, path.with_name(f"hooks.json.bak-{time.strftime('%Y%m%d-%H%M%S')}"))
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, path)
    print(f"{changed} event(s) {verb} {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
