"""Drive Ghostty tabs through its AppleScript dictionary (Ghostty 1.3+): the counterpart of the iTerm2 Python API.

Ghostty exposes no per-shell session ID and no process ID per terminal, so a
process is tied to its terminal through its tty: each tty briefly gets a unique
OSC 2 title, one AppleScript call reads which terminal shows which title, and
every probed terminal gets its previous title back. Screen contents come from
Ghostty's `write_screen_file:copy` action, which puts the path of a screen dump
on the clipboard; the clipboard is restored and the dump deleted right after.
"""

from __future__ import annotations

import contextlib
import fcntl
import os
import secrets
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import diagnostics

OSASCRIPT_TIMEOUT_SECONDS = 20
PROBE_ROUNDS = 3
PROBE_POLLS = 5
PROBE_POLL_SECONDS = 0.1
# Outlasts a full failed probe: PROBE_ROUNDS * PROBE_POLLS + 2 listings at ~2 s each under load.
PROBE_LOCK_WAIT_SECONDS = 45
FIELD = "\x1f"
ROW = "\x1e"


class GhosttyError(RuntimeError):
    pass


def in_ghostty() -> bool:
    return os.environ.get("TERM_PROGRAM", "").casefold() == "ghostty"


def osascript(script: str, *args: str) -> str:
    """Arguments reach the script as `argv`, never spliced into its source."""
    started = time.monotonic()
    diagnostics.emit("ghostty.call_start")
    try:
        out = subprocess.run(["osascript", "-", *args], input=script, capture_output=True, text=True,
                             timeout=OSASCRIPT_TIMEOUT_SECONDS, check=False)
    except subprocess.TimeoutExpired as exc:
        diagnostics.emit("ghostty.call_error", reason="timeout", elapsed_ms=(time.monotonic() - started) * 1000)
        raise GhosttyError("Ghostty AppleScript call timed out") from exc
    except OSError as exc:
        diagnostics.emit("ghostty.call_error", error_type=type(exc).__name__, elapsed_ms=(time.monotonic() - started) * 1000)
        raise
    if out.returncode != 0:
        diagnostics.emit("ghostty.call_error", reason="nonzero_exit", returncode=out.returncode,
                         elapsed_ms=(time.monotonic() - started) * 1000)
        raise GhosttyError(f"Ghostty AppleScript failed: {out.stderr.strip()[:200]}")
    diagnostics.emit("ghostty.call_end", returncode=out.returncode, elapsed_ms=(time.monotonic() - started) * 1000)
    return out.stdout.rstrip("\n")


@dataclass
class Terminal:
    id: str
    tab_id: str
    window_id: str
    title: str
    tab_title: str
    cwd: str
    frontmost: bool

    @property
    def title_override(self) -> str:
        """A tab title differing from its terminal's title was set on the tab (`set_tab_title`)."""
        return self.tab_title if self.tab_title != self.title else ""


LIST_SCRIPT = """
on run argv
  set fs to character id 31
  set rs to character id 30
  set out to ""
  tell application "Ghostty"
    set frontId to ""
    try
      set frontId to id of focused terminal of selected tab of front window
    end try
    repeat with wi from 1 to count of windows
      set w to window wi
      repeat with ti from 1 to count of tabs of w
        set t to tab ti of w
        repeat with si from 1 to count of terminals of t
          set s to terminal si of t
          set out to out & (id of s) & fs & (id of t) & fs & (id of w) & fs & (name of s) & fs & (name of t) & fs & (working directory of s) & fs & ((id of s) is frontId) & rs
        end repeat
      end repeat
    end repeat
  end tell
  return out
end run
"""

# Reads each property for every terminal in one Apple event instead of one event per terminal.
LAYOUT_CHANGED = "layout-changed"
# The per-terminal fallback is slower and fails outright when a tab closes mid-loop, so the bulk query is retried first.
LAYOUT_ATTEMPTS = 3
BULK_LIST_SCRIPT = """
on run argv
  set fs to character id 31
  set rs to character id 30
  tell application "Ghostty"
    set frontId to ""
    try
      set frontId to id of focused terminal of selected tab of front window
    end try
    set wids to id of every window
    set tids to id of every tab of every window
    set sids to id of every terminal of every tab of every window
    set tnames to name of every tab of every window
    set snames to name of every terminal of every tab of every window
    set sdirs to working directory of every terminal of every tab of every window
    set widsAfter to id of every window
    set tidsAfter to id of every tab of every window
    set sidsAfter to id of every terminal of every tab of every window
  end tell
  if wids is not widsAfter or tids is not tidsAfter or sids is not sidsAfter then return "layout-changed"
  set out to ""
  repeat with wi from 1 to count of wids
    repeat with ti from 1 to count of item wi of tids
      repeat with si from 1 to count of item ti of item wi of sids
        set s to item si of item ti of item wi of sids
        set out to out & s & fs & (item ti of item wi of tids) & fs & (item wi of wids) & fs & (item si of item ti of item wi of snames) & fs & (item ti of item wi of tnames) & fs & (item si of item ti of item wi of sdirs) & fs & (s is frontId) & rs
      end repeat
    end repeat
  end repeat
  return out
end run
"""


def terminals() -> list[Terminal]:
    started = time.monotonic()
    found = []
    for _ in range(LAYOUT_ATTEMPTS):
        out = osascript(BULK_LIST_SCRIPT)
        if out != LAYOUT_CHANGED:
            break
        diagnostics.emit("ghostty.list_retry", reason="layout_changed")
    else:
        diagnostics.emit("ghostty.list_fallback", reason="layout_changed")
        out = osascript(LIST_SCRIPT)
    for row in out.split(ROW):
        parts = row.split(FIELD)
        if len(parts) == 7:
            found.append(Terminal(*parts[:6], frontmost=parts[6] == "true"))
    diagnostics.emit("ghostty.list", row_count=len(found), elapsed_ms=(time.monotonic() - started) * 1000)
    return found


def find(terminal_id: str) -> Terminal | None:
    return next((t for t in terminals() if t.id == terminal_id), None)


def windows() -> list[tuple[str, int]]:
    counts: dict[str, set[str]] = {}
    for t in terminals():
        counts.setdefault(t.window_id, set()).add(t.tab_id)
    return [(window, len(tabs)) for window, tabs in counts.items()]


NEW_TAB_SCRIPT = """
on run argv
  set {targetWindow, startDir, startInput, startProgram} to argv
  tell application "Ghostty"
    set wasFront to frontmost
    set priorWindowId to ""
    try
      set priorWindowId to id of front window
    end try
    set cfg to new surface configuration
    if startDir is not "" then set initial working directory of cfg to startDir
    if startInput is not "" then set initial input of cfg to startInput & linefeed
    if startProgram is not "" then set command of cfg to startProgram
    if targetWindow is "" then
      set w to new window with configuration cfg
      set created to (id of w) & character id 31 & (id of focused terminal of selected tab of w)
    else
      set tw to window id targetWindow
      set priorTabId to id of selected tab of tw
      set t to new tab in tw with configuration cfg
      set created to (id of tw) & character id 31 & (id of focused terminal of t)
      select tab (tab id priorTabId of tw)
    end if
    if wasFront and priorWindowId is not "" then activate window (window id priorWindowId)
    return created
  end tell
end run
"""


def new_tab(window_id: str | None, command: str = "", cwd: str = "", program: str = "") -> tuple[str, str]:
    """Open a tab (a new window when window_id is None) in the background; returns (window, terminal).

    COMMAND is typed into the tab's shell, which outlives it; PROGRAM runs in place of the shell.
    Ghostty selects a tab it creates, so the window's previous tab and the front window are put
    back right after: keystrokes typed meanwhile would otherwise land in the new tab.
    """
    window, _, terminal = osascript(NEW_TAB_SCRIPT, window_id or "", cwd, command, program).partition(FIELD)
    if not terminal:
        raise GhosttyError("new tab returned no terminal")
    return window, terminal


def set_tab_title(terminal_id: str, title: str) -> None:
    osascript('on run argv\ntell application "Ghostty" to perform action ("set_tab_title:" & item 2 of argv) '
              'on (terminal id (item 1 of argv))\nend run', terminal_id, title)


def type_text(terminal_id: str, text: str, submit: bool, delay: float = 0.3) -> None:
    """`input text` pastes, so a trailing newline would not submit; Return is sent as a key press."""
    script = ('on run argv\ntell application "Ghostty"\nset s to terminal id (item 1 of argv)\n'
              'if item 2 of argv is not "" then input text (item 2 of argv) to s\n'
              'if item 3 of argv is "1" then\ndelay (item 4 of argv as real)\nsend key "enter" to s\nend if\n'
              'end tell\nend run')
    osascript(script, terminal_id, text, "1" if submit else "0", str(delay))


SCREEN_SCRIPT = """
on run argv
  tell application "Ghostty"
    set saved to missing value
    try
      set saved to the clipboard
    end try
    set priorText to ""
    try
      set priorText to (the clipboard as text)
    end try
    perform action "write_screen_file:copy,plain" on (terminal id (item 1 of argv))
    set dumped to ""
    repeat 40 times
      try
        set dumped to (the clipboard as text)
      end try
      if dumped is not priorText and dumped ends with ".txt" then exit repeat
      delay 0.05
    end repeat
    if saved is not missing value then set the clipboard to saved
    return dumped
  end tell
end run
"""


def screen_lines(terminal_id: str) -> list[str]:
    raw = osascript(SCREEN_SCRIPT, terminal_id).strip()
    path = Path(raw)
    if not raw.endswith(".txt") or not path.is_file():
        raise GhosttyError(f"no screen dump for terminal {terminal_id}")
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    finally:
        path.unlink(missing_ok=True)
        with contextlib.suppress(OSError):
            path.parent.rmdir()
    return [line.rstrip() for line in text.splitlines()]


def tty_of(pid: int) -> str | None:
    out = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)], capture_output=True, text=True, check=False).stdout
    tty = out.strip()
    return None if not tty or tty.startswith("?") else f"/dev/{tty}"


def own_tty() -> str | None:
    """The tty of the nearest ancestor that has one: hook and tool subprocesses run without a terminal."""
    pid = os.getppid()
    for _ in range(40):
        if pid <= 1:
            return None
        tty = tty_of(pid)
        if tty:
            return tty
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True,
                             check=False).stdout.strip()
        if not out.isdigit():
            return None
        pid = int(out)
    return None


def _write_title(tty: str, title: str) -> bool:
    try:
        with open(tty, "w", encoding="utf-8") as fh:
            fh.write(f"\033]2;{title}\007")
        return True
    except OSError:
        return False


def terminals_for_ttys(ttys: list[str], cached: Callable[[], str | None] | None = None) -> dict[str, str]:
    """Serialize title probes so concurrent callers never save another caller's nonce as a title.

    CACHED, asked once the lock is held, returns a terminal another caller resolved while this one
    waited, "" when another caller's probe of it just missed, or None to probe; a single tty then
    skips a second probe.
    """
    if not ttys:
        return {}
    path = f"/tmp/ghostty-title-probe-{os.getuid()}.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        started = time.monotonic()
        diagnostics.emit("probe.lock_wait")
        deadline = started + PROBE_LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                diagnostics.emit("probe.lock_acquired", elapsed_ms=(time.monotonic() - started) * 1000)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    diagnostics.emit("probe.lock_timeout", elapsed_ms=(time.monotonic() - started) * 1000)
                    raise GhosttyError("another terminal title probe is in progress")
                time.sleep(0.05)
        if cached is not None and len(set(ttys)) == 1:
            terminal_id = cached()
            if terminal_id is not None:
                diagnostics.emit("probe.skipped", reason="resolved_while_waiting" if terminal_id else "missed_while_waiting")
                return {ttys[0]: terminal_id} if terminal_id else {}
        return _probe_ttys(ttys)


def _probe_ttys(ttys: list[str]) -> dict[str, str]:
    """Map each tty to the Ghostty terminal showing it, by a one-off OSC 2 title per tty.

    A program that sets its own title (Claude's spinner, Codex at startup) can overwrite a probe
    title before it is read, so titles are polled and unmatched ttys are probed again.
    """
    diagnostics.emit("probe.start", row_count=len(ttys))
    pending = sorted(set(ttys))
    if not pending:
        return {}
    before = {t.id: t.title for t in terminals() if not t.title.startswith("tty-probe-")}
    found: dict[str, str] = {}
    nonces = {}
    try:
        for _ in range(PROBE_ROUNDS):
            for tty in pending:
                nonce = f"tty-probe-{secrets.token_hex(6)}"
                if _write_title(tty, nonce):
                    nonces[nonce] = tty
            if not nonces:
                break
            for _ in range(PROBE_POLLS):
                time.sleep(PROBE_POLL_SECONDS)
                for t in terminals():
                    if t.title in nonces:
                        found.setdefault(nonces[t.title], t.id)
                    elif not t.title.startswith("tty-probe-"):
                        before[t.id] = t.title
                if all(tty in found for tty in nonces.values()):
                    break
            pending = sorted({tty for tty in nonces.values() if tty not in found})
            if not pending:
                break
    finally:
        with contextlib.suppress(GhosttyError):
            for t in terminals():
                if t.title in nonces and t.id in before:
                    _write_title(nonces[t.title], before[t.id])
    diagnostics.emit("probe.end", row_count=len(found), matched=bool(found))
    return found


def terminals_for_pids(pids: list[int]) -> dict[int, str]:
    ttys = {pid: tty_of(pid) for pid in pids}
    by_tty = terminals_for_ttys([tty for tty in ttys.values() if tty])
    return {pid: by_tty[tty] for pid, tty in ttys.items() if tty in by_tty}


def own_terminal() -> str | None:
    tty = own_tty()
    return terminals_for_ttys([tty]).get(tty) if tty else None
