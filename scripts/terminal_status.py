"""Live working/waiting/idle/done status for Claude Code and Codex sessions in Ghostty tabs.

Every hook event of a session running in Ghostty updates its status file,
<state dir>/status/<agent>-<session_id>.json (read by the sidebar app; written to
a temp file and renamed into place), and its tab title override,
`<state glyph><color glyph> <title>`. The state dir is $GHOSTTY_AGENT_STATUS_DIR,
else ~/.local/state/ghostty-agent-status. Ghostty has no tab color, so a
deterministic repo:branch color is shown as the nearest colored-square emoji; the
exact color is in the status file.

The tab title override is the only channel: the agent's own terminal title (its
spinner) is hidden behind it and read back as the session title. Labels set with
`terminal_status.py label` go through the same composer, so the two never
overwrite each other.

A hook resolves its terminal once per agent process and caches it in the status
file. Claude's hooks share the agent's process tree, so its tty names the
terminal. Codex runs hooks in a shared app-server daemon whose environment
belongs to whichever tab started it, so the terminal is the Ghostty Codex TUI
that resumed the thread, else the only one that took input just now, else the
only unclaimed one in the session's directory; anything else stays unresolved.
A Codex thread whose rollout source is not "cli" (exec runs, VS Code, subagents)
has no tab of its own and gets no status file; neither does one with no rollout
yet, which ephemeral threads never write.

The Ghostty work runs in a detached worker (`terminal_status.py apply ...`) so a
hook returns in milliseconds.
"""

from __future__ import annotations

import colorsys
import contextlib
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ghostty_tabs

STATE_DIR = Path(os.environ.get("GHOSTTY_AGENT_STATUS_DIR") or Path.home() / ".local" / "state" / "ghostty-agent-status")
STATUS_DIR = STATE_DIR / "status"
WORK_DIR = STATE_DIR / "work"
CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
SESSION_INDEX = CODEX_HOME / "session_index.jsonl"

STATE_GLYPH = {"working": "⏳", "waiting": "✋", "idle": "💤", "done": "🏁"}
COLOR_GLYPHS = ((0, "🟥"), (30, "🟧"), (55, "🟨"), (120, "🟩"), (215, "🟦"), (280, "🟪"))
OUR_PREFIX = re.compile("^[" + "".join(STATE_GLYPH.values()) + "][" + "".join(g for _, g in COLOR_GLYPHS) + "]? ")
BELL = "🔔 "
AGENT_SPINNER = re.compile(r"^[^\w\s\[(]{1,2}\s+")
PROBE_TITLE = "tty-probe-"
WAITING_TOOLS = {"AskUserQuestion", "request_user_input", "request_user_input_async"}
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure"}
WAITING_NOTIFICATIONS = {"permission_prompt", "elicitation_dialog"}
GIT_EVENTS = {"SessionStart", "UserPromptSubmit", "Stop"}
RETITLE_EVENTS = {"SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"}
CODEX_NON_TUI = {"app-server", "exec", "mcp", "mcp-server", "sandbox", "login", "logout", "apply"}
INPUT_WINDOW_SECONDS = 10
LOCK_WAIT_SECONDS = 2.0
MESSAGE_MAX = 120
PRUNE_AFTER_SECONDS = 24 * 3600


def state_for(payload: dict) -> tuple[str, str | None] | None:
    """(state, message) for a hook event, or None when the event says nothing about the state."""
    event = payload.get("hook_event_name")
    tool = payload.get("tool_name") or ""
    short_tool = tool.rsplit(".", 1)[-1].rsplit("__", 1)[-1]
    if event == "SessionStart":
        return "idle", None
    if event == "Stop":
        running = [t for t in payload.get("background_tasks") or [] if t.get("status") == "running"]
        return "idle", f"{len(running)} background task{'s' * (len(running) != 1)} running" if running else None
    if event == "StopFailure":
        return "idle", "turn failed"
    if event == "SessionEnd":
        return "done", None
    if event == "PermissionRequest":
        return "waiting", f"permission: {tool}" if tool else "permission"
    if event == "PreToolUse" and short_tool in WAITING_TOOLS:
        questions = (payload.get("tool_input") or {}).get("questions") or [{}]
        return "waiting", (questions[0].get("question") or "question")[:MESSAGE_MAX]
    # A subagent's tool calls and its stop say nothing about whether the main agent is waiting on the user.
    if event == "SubagentStop" or (payload.get("agent_id") and event in TOOL_EVENTS):
        return None
    if event == "UserPromptSubmit" or event in TOOL_EVENTS:
        return "working", None
    if event == "Notification":
        kind = payload.get("notification_type")
        if kind in WAITING_NOTIFICATIONS:
            return "waiting", (payload.get("message") or kind)[:MESSAGE_MAX]
        if kind == "idle_prompt":
            return "idle", None
    return None


def call_key(payload: dict) -> str:
    """PermissionRequest carries no tool_use_id, so a call is keyed by its tool and input, which every tool event carries."""
    tool = payload.get("tool_name")
    if not tool:
        return "permission"
    body = json.dumps(payload.get("tool_input"), sort_keys=True, default=str)
    return f"{tool}:{hashlib.sha1(body.encode()).hexdigest()[:12]}"


def transition(old: dict, payload: dict, tracking: dict) -> tuple[str, str | None] | None:
    event = payload.get("hook_event_name")
    actor = str(payload.get("agent_id") or "main")
    key = f"{actor}:{call_key(payload)}"
    tracking.setdefault("main_state", old.get("state") if old.get("state") in {"working", "idle", "done"} else "idle")
    pending = tracking.setdefault("pending", {})
    before_pending = dict(pending)
    change = state_for(payload)
    if change is None and event not in {"SubagentStop", "PostToolUse", "PostToolUseFailure"}:
        return None
    if old.get("state") == "done" and event not in {"SessionStart", "UserPromptSubmit"}:
        return None
    if event in {"SessionStart", "SessionEnd"}:
        pending.clear()
    if event == "SubagentStop":
        if actor == "main":
            return None
        for waiting in list(pending):
            if waiting.startswith(f"{actor}:"):
                pending.pop(waiting)
    if event in {"UserPromptSubmit", "Stop", "StopFailure"}:
        for waiting in list(pending):
            if waiting.startswith("main:"):
                pending.pop(waiting)
    if event in {"PostToolUse", "PostToolUseFailure"}:
        pending.pop(key, None)
        pending.pop(f"{actor}:permission", None)
    if change and change[0] == "waiting":
        if event != "Notification" or not pending:
            pending[key] = change[1]
    elif change and actor == "main":
        tracking["main_state"] = change[0]
        tracking["main_message"] = change[1]
    if pending:
        return "waiting", next(reversed(pending.values()))
    if change is None and pending == before_pending:
        return None
    return tracking.get("main_state", old.get("state", "idle")), tracking.get("main_message")


def _crc_table() -> list[int]:
    table = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) if c & 0x80000000 else c << 1
        table.append(c & 0xFFFFFFFF)
    return table


CRC_TABLE = _crc_table()


def cksum(data: bytes) -> int:
    """POSIX cksum(1), so a shell script can derive the same color."""
    crc = 0
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ CRC_TABLE[(crc >> 24) ^ byte]
    n = len(data)
    while n:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ CRC_TABLE[(crc >> 24) ^ (n & 0xFF)]
        n >>= 8
    return ~crc & 0xFFFFFFFF


def color_of(repo: str, branch: str, cwd: str) -> str:
    hue = cksum(f"{repo}:{branch or cwd}".encode()) % 360
    frac = (hue % 60) * 255 // 60
    r, g, b = ((255, frac, 0), (255 - frac, 255, 0), (0, 255, frac),
               (0, 255 - frac, 255), (frac, 0, 255), (255, 0, 255 - frac))[hue // 60]
    return f"#{r:02x}{g:02x}{b:02x}"


def color_glyph(color: str | None) -> str:
    if not color or not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
        return ""
    r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    hue = colorsys.rgb_to_hsv(r, g, b)[0] * 360
    return min(COLOR_GLYPHS, key=lambda c: min(abs(hue - c[0]), 360 - abs(hue - c[0])))[1]


def compose(state: str, color: str | None, base: str) -> str:
    return f"{STATE_GLYPH.get(state, '')}{color_glyph(color)} {base}"


def unprefixed(title: str) -> str:
    """A tab title without the bell or this module's glyphs, as a spawner or a label set it."""
    title = title.removeprefix(BELL)
    return OUR_PREFIX.sub("", title, count=1)


def agent_title(terminal_title: str) -> str:
    """The agent's own title with its spinner glyph dropped; empty while a tty probe shows."""
    return "" if terminal_title.startswith(PROBE_TITLE) else AGENT_SPINNER.sub("", terminal_title, count=1).strip()


def foreign_override(terminal: ghostty_tabs.Terminal) -> str:
    """A tab title set by someone else: not ours, not the bell, not a spinner frame read mid-tick."""
    shown = terminal.tab_title.removeprefix(BELL)
    if OUR_PREFIX.match(shown) or agent_title(shown) == agent_title(terminal.title):
        return ""
    return shown


def git_info(cwd: str) -> tuple[str, str, bool]:
    def git(*args: str) -> str:
        try:
            return subprocess.run(["git", "-C", cwd, "--no-optional-locks", *args], capture_output=True,
                                  text=True, timeout=2, check=False).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""

    origin = git("remote", "get-url", "origin")
    repo = re.sub(r"\.git$", "", origin.rsplit("/", 1)[-1].rsplit(":", 1)[-1]) if origin else ""
    in_repo = bool(git("rev-parse", "--is-inside-work-tree"))
    return repo or os.path.basename(cwd.rstrip("/")) or cwd, git("branch", "--show-current"), in_repo


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _key(agent: str, session_id: str) -> str:
    return f"{agent}-{re.sub(r'[^A-Za-z0-9_-]', '', session_id)}"


def status_path(agent: str, session_id: str) -> Path:
    return STATUS_DIR / f"{_key(agent, session_id)}.json"


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.stem}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def read_status(agent: str, session_id: str) -> dict:
    return _read_json(status_path(agent, session_id))


def write_status(record: dict) -> None:
    fields = ("agent", "session_id", "state", "title", "cwd", "repo", "branch", "color",
              "ghostty_terminal_id", "pid", "updated_at", "message")
    _write_json(status_path(record["agent"], record["session_id"]), {f: record.get(f) for f in fields})


def all_status() -> list[dict]:
    return [r for r in (_read_json(p) for p in STATUS_DIR.glob("*.json")) if r.get("session_id")]


@contextlib.contextmanager
def locked(name: str):
    """Serialize updates, abandoning a timed-out update instead of overwriting a concurrent event."""
    path = WORK_DIR / "locks" / f"{name}.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as fh:
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        held = False
        while not held:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held = True
            except OSError:
                if time.monotonic() > deadline:
                    raise TimeoutError(f"status lock busy: {name}")
                time.sleep(0.02)
        try:
            yield
        finally:
            if held:
                fcntl.flock(fh, fcntl.LOCK_UN)


def pid_alive(pid) -> bool:
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def is_codex_app_server(command: str) -> bool:
    words = command.split()
    return len(words) > 1 and Path(words[0]).name == "codex" and words[1] == "app-server"


def process_owner() -> tuple[int, str | None, bool] | None:
    """(pid, tty, under_codex_daemon) of the nearest ancestor holding a tty or being Codex's app-server."""
    pid = os.getppid()
    for _ in range(40):
        if pid <= 1:
            return None
        out = subprocess.run(["ps", "-o", "ppid=,tty=,command=", "-p", str(pid)], capture_output=True,
                             text=True, check=False).stdout.split(None, 2)
        if len(out) < 3 or not out[0].isdigit():
            return None
        if not out[1].startswith("?"):
            return pid, f"/dev/{out[1]}", False
        if is_codex_app_server(out[2]):
            return pid, None, True
        pid = int(out[0])
    return None


def codex_tuis() -> list[dict]:
    """Interactive Codex processes running in Ghostty: pid, tty, cwd and the thread they resumed."""
    out = subprocess.run(["ps", "-axww", "-o", "pid=,tty=,args="], capture_output=True, text=True,
                         check=False).stdout
    found = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or parts[1].startswith("?"):
            continue
        words = parts[2].split()
        if Path(words[0]).name != "codex" or (words[1:2] and words[1] in CODEX_NON_TUI):
            continue
        resumed = re.search(r"\bresume\s+([0-9a-f-]{36})", parts[2])
        found[int(parts[0])] = {"pid": int(parts[0]), "tty": f"/dev/{parts[1]}",
                                "resumed": resumed.group(1) if resumed else None, "cwd": None}
    if not found:
        return []
    pids = ",".join(map(str, found))
    env = subprocess.run(["ps", "eww", "-o", "pid=,command=", "-p", pids], capture_output=True, text=True,
                         check=False).stdout
    ghostty = {int(line.split(None, 1)[0]) for line in env.splitlines()
               if line.strip() and " TERM_PROGRAM=ghostty" in line}
    cwds = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn", "-p", pids], capture_output=True, text=True,
                          check=False).stdout
    pid = None
    for line in cwds.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid = int(line[1:])
        elif line.startswith("n") and pid in found:
            found[pid]["cwd"] = line[1:]
    return [tui for pid, tui in found.items() if pid in ghostty]


def tty_input_age(tty: str) -> float:
    try:
        return time.time() - os.stat(tty).st_atime
    except OSError:
        return float("inf")


def pick_codex_tui(session_id: str, event: str, cwd: str, tuis: list[dict], claimed: set[int]) -> dict | None:
    """The TUI showing this thread, or None when the evidence does not single one out."""
    resumed = [t for t in tuis if t["resumed"] == session_id]
    if len(resumed) == 1:
        return resumed[0]
    if event in ("SessionStart", "UserPromptSubmit"):
        typed = [t for t in tuis if tty_input_age(t["tty"]) <= INPUT_WINDOW_SECONDS]
        if len(typed) == 1:
            return typed[0]
    here = [t for t in tuis if t["pid"] not in claimed and t["cwd"]
            and os.path.realpath(t["cwd"]) == os.path.realpath(cwd)]
    return here[0] if len(here) == 1 else None


def codex_source(payload: dict, session_id: str) -> object:
    """The thread's session_meta `source`: "cli" for a TUI tab; exec, vscode and subagent threads have no tab of their own."""
    path = payload.get("transcript_path")
    paths = [Path(path)] if path else list((CODEX_HOME / "sessions").rglob(f"*{session_id}.jsonl"))
    for rollout in paths:
        with contextlib.suppress(OSError, ValueError), rollout.open(encoding="utf-8") as fh:
            row = json.loads(fh.readline())
            if row.get("type") == "session_meta":
                return row.get("payload", {}).get("source")
    return None


def codex_thread_name(session_id: str) -> str | None:
    name = None
    try:
        with SESSION_INDEX.open(encoding="utf-8") as index:
            for line in index:
                if session_id in line:
                    with contextlib.suppress(ValueError):
                        row = json.loads(line)
                        if row.get("id") == session_id:
                            name = row.get("thread_name") or name
    except OSError:
        return None
    return name


def update(agent: str, payload: dict) -> None:
    """Hook entry: write the status file now; leave Ghostty to a detached worker when the tab must change."""
    session_id = str(payload.get("session_id") or "")
    if not session_id:
        return
    event = str(payload.get("hook_event_name") or "")
    # git can take seconds on a loaded machine; holding the lock through it made parallel hooks time out.
    peek = read_status(agent, session_id)
    git_cwd = str(payload.get("cwd") or peek.get("cwd") or os.getcwd())
    git = git_info(git_cwd) if event in GIT_EVENTS or git_cwd != peek.get("cwd") or not peek.get("color") else None
    with locked(_key(agent, session_id)):
        old = read_status(agent, session_id)
        tracking_path = WORK_DIR / "events" / f"{_key(agent, session_id)}.json"
        tracking = _read_json(tracking_path)
        # Ephemeral threads (Claude's Codex plugin) never write a rollout, so a missing one is rechecked, not trusted.
        if agent == "codex" and tracking.get("source") is None:
            tracking["source"] = codex_source(payload, session_id)
        if agent == "codex" and tracking.get("source") != "cli":
            status_path(agent, session_id).unlink(missing_ok=True)
            _write_json(tracking_path, tracking)
            return
        change = transition(old, payload, tracking)
        if change is None:
            return
        state, message = change
        record = dict(old)
        if not pid_alive(old.get("pid")):
            owner = process_owner()
            if owner is None:
                return
            pid, _tty, daemon = owner
            if agent == "codex" and daemon:
                if not codex_tuis():
                    return
            elif os.environ.get("TERM_PROGRAM", "").casefold() != "ghostty":
                return
            record.update(pid=pid, ghostty_terminal_id=None)
        cwd = str(payload.get("cwd") or old.get("cwd") or os.getcwd())
        if event in GIT_EVENTS or cwd != old.get("cwd") or not old.get("color"):
            repo, branch, in_repo = git if git and cwd == git_cwd else git_info(cwd)
            # A scratch dir outside any repo keeps the session's last repo and color.
            if in_repo or not old.get("color"):
                record.update(repo=repo, branch=branch or None, color=color_of(repo, branch, cwd))
        record.update(agent=agent, session_id=session_id, state=state, message=message, cwd=cwd,
                      updated_at=now_iso())
        record["title"] = old.get("title") or record["repo"]
        if agent == "codex" and record["title"] == record["repo"]:
            record["title"] = codex_thread_name(session_id) or record["title"]
        write_status(record)
        _write_json(tracking_path, tracking)
    if (event in RETITLE_EVENTS or state != old.get("state") or not record.get("ghostty_terminal_id")
            or record.get("color") != old.get("color")):
        spawn_worker(agent, session_id, event)


def spawn_worker(agent: str, session_id: str, event: str) -> None:
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "apply", agent, session_id, event],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True)


def locate(record: dict, event: str) -> tuple[int | None, str | None]:
    """(agent pid, tty) for a session: its Codex TUI when the evidence singles one out, else the recorded pid."""
    pid = record.get("pid")
    if record["agent"] == "codex":
        tuis = codex_tuis()
        own = next((t for t in tuis if t["pid"] == pid), None)
        if own is None:
            claimed = {r.get("pid") for r in all_status()
                       if r.get("agent") == "codex" and r.get("session_id") != record["session_id"]
                       and r.get("ghostty_terminal_id") and r.get("state") != "done" and pid_alive(r.get("pid"))}
            own = pick_codex_tui(record["session_id"], event, record.get("cwd") or "", tuis, claimed)
        return (own["pid"], own["tty"]) if own else (None, None)
    return pid, ghostty_tabs.tty_of(pid) if isinstance(pid, int) else None


def codex_terminal_by_name(session_id: str) -> str | None:
    """The one terminal whose Codex-written title (`<spinner> <thread name> | <dir>`) names this thread."""
    name = codex_thread_name(session_id)
    if not name:
        return None
    hits = [t.id for t in ghostty_tabs.terminals() if agent_title(t.title).rpartition(" | ")[0] == name]
    return hits[0] if len(hits) == 1 else None


def label_path(agent: str, session_id: str) -> Path:
    return WORK_DIR / "labels" / f"{_key(agent, session_id)}.json"


def session_on(terminal_id: str) -> dict | None:
    """The most recently updated session shown in a terminal."""
    found = [r for r in all_status() if r.get("ghostty_terminal_id") == terminal_id]
    return max(found, key=lambda r: r.get("updated_at") or "") if found else None


def show(terminal_id: str) -> None:
    """Recompose one tab's title from its newest session, its label and milestone, and the agent's own title."""
    with locked(f"tab-{terminal_id}"):
        terminal = ghostty_tabs.find(terminal_id)
        record = session_on(terminal_id)
        if terminal is None or record is None:
            return
        agent, session_id = record["agent"], record["session_id"]
        title = agent_title(terminal.title) if agent == "claude" else codex_thread_name(session_id)
        if title and title != record.get("title") and record.get("state") != "done":
            with locked(_key(agent, session_id)):
                fresh = read_status(agent, session_id)
                if fresh.get("ghostty_terminal_id") == terminal_id:
                    fresh["title"] = record["title"] = title
                    write_status(fresh)
        labels = _read_json(label_path(agent, session_id))
        base = labels.get("label") or record.get("title") or record.get("repo") or agent
        if labels.get("milestone"):
            base = f"{base} · {labels['milestone']}"
        wanted = compose(record.get("state") or "idle", record.get("color"), base)
        shown = terminal.tab_title.removeprefix(BELL)
        if wanted != shown:
            ghostty_tabs.set_tab_title(terminal_id, wanted)


def prune() -> None:
    """Delete what sessions dead for a day left behind: the sidebar already hides them, nothing else reads them."""
    cutoff = time.time() - PRUNE_AFTER_SECONDS
    kept_terminals = set()
    for path in STATUS_DIR.glob("*.json"):
        with contextlib.suppress(OSError):
            record = _read_json(path)
            if pid_alive(record.get("pid")) or path.stat().st_mtime > cutoff:
                kept_terminals.add(record.get("ghostty_terminal_id"))
                continue
            for stale in (path, WORK_DIR / "labels" / path.name, WORK_DIR / "events" / path.name,
                          WORK_DIR / "locks" / f"{path.stem}.lock"):
                stale.unlink(missing_ok=True)
    stale_files = [lock for lock in (WORK_DIR / "locks").glob("tab-*.lock") if lock.stem[4:] not in kept_terminals]
    stale_files += list(STATUS_DIR.glob(".*.tmp"))
    for path in stale_files:
        with contextlib.suppress(OSError):
            if path.stat().st_mtime < cutoff:
                path.unlink()


def apply(agent: str, session_id: str, event: str) -> None:
    """Worker: resolve the session's terminal if needed, then retitle its tab."""
    if event == "SessionStart":
        prune()
    record = read_status(agent, session_id)
    if not record:
        return
    terminal_id = record.get("ghostty_terminal_id")
    if not terminal_id:
        pid, tty = locate(record, event)
        if pid and pid != record.get("pid"):
            with locked(_key(agent, session_id)):
                record = read_status(agent, session_id)
                record["pid"] = pid
                write_status(record)
        # Codex redraws its spinner title faster than a tty probe can be read back, so its own title goes first.
        terminal_id = codex_terminal_by_name(session_id) if agent == "codex" else None
        if not terminal_id and tty:
            terminal_id = ghostty_tabs.terminals_for_ttys([tty]).get(tty)
        if not terminal_id:
            return
        with locked(_key(agent, session_id)):
            record = read_status(agent, session_id)
            record["ghostty_terminal_id"] = terminal_id
            write_status(record)
        before = ghostty_tabs.find(terminal_id)
        adopted = foreign_override(before) if before else ""
        if adopted and not label_path(agent, session_id).exists():
            _write_json(label_path(agent, session_id), {"label": adopted, "milestone": None})
    show(terminal_id)


def show_progress(terminal_id: str, label: str, milestone: str) -> bool:
    """Record a tab's label and milestone and retitle it; False when no session is known there."""
    record = session_on(terminal_id)
    if record is None:
        return False
    _write_json(label_path(record["agent"], record["session_id"]), {"label": label, "milestone": milestone or None})
    show(terminal_id)
    return True


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[0] == "apply":
        with contextlib.suppress(Exception):
            apply(argv[1], argv[2], argv[3])
        return 0
    if len(argv) in (3, 4) and argv[0] == "label":
        return 0 if show_progress(argv[1], argv[2], argv[3] if len(argv) == 4 else "") else 1
    print("usage: terminal_status.py label <ghostty-terminal-id> <label> [milestone]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
