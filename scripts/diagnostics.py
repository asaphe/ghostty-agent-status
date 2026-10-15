from __future__ import annotations

import argparse
import contextlib
import contextvars
import fcntl
import hashlib
import json
import os
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path

LIMIT = 2 * 1024 * 1024
CONTEXT = contextvars.ContextVar("status_diagnostics", default={})
STATES = {"working", "waiting", "idle", "done", "background", "unknown"}
HOOKS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
         "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStop", "SessionEnd"}
MARKERS = {"question_visible", "answer_submitted", "stale_seen", "correct_seen"}
IDENTITIES = {"session_id", "actor_id", "call_id", "terminal_id", "call_key", "request_id", "tool_name"}
NUMBERS = {"elapsed_ms", "pending_count", "returncode", "record_count", "row_count", "evidence_ms",
           "reported_ms", "source_ms", "bytes", "offset", "skipped_count"}
FLAGS = {"changed", "matched", "available", "tool_input_present", "tool_use_id_present"}
TOKENS = {"reason", "error_type", "operation", "row_type", "event_type", "phase", "marker"}


def state_root() -> Path:
    return Path(os.environ.get("GHOSTTY_AGENT_STATUS_DIR") or Path.home() / ".local/state/ghostty-agent-status")


def root() -> Path:
    return Path(os.environ["GHOSTTY_AGENT_STATUS_DIAGNOSTICS_DIR"]) if os.environ.get("GHOSTTY_AGENT_STATUS_DIAGNOSTICS_DIR") else state_root() / "diagnostics"


def enabled() -> bool:
    value = os.environ.get("GHOSTTY_AGENT_STATUS_DIAGNOSTICS")
    return value == "1" if value is not None else (root() / "enabled").is_file()


def fingerprint(value) -> str | None:
    return hashlib.sha256(str(value).encode()).hexdigest()[:16] if value is not None else None


def clean(fields: dict) -> dict:
    result = {}
    for key, value in fields.items():
        if key in IDENTITIES:
            result[key] = fingerprint(value)
        elif key == "pending_keys" and isinstance(value, (list, tuple)):
            result[key] = [fingerprint(v) for v in value[:128]]
        elif key in NUMBERS and isinstance(value, (int, float)) and not isinstance(value, bool):
            result[key] = value
        elif key in FLAGS and isinstance(value, bool):
            result[key] = value
        elif key in {"state", "old_state", "hook_state", "evidence_state", "observed_state"} and isinstance(value, str) and value in STATES:
            result[key] = value
        elif key == "hook_event" and isinstance(value, str) and value in HOOKS:
            result[key] = value
        elif key in TOKENS and isinstance(value, str) and len(value) <= 64 and value.replace("_", "").isalnum():
            result[key] = value
    return result


_source_id = None
_entrypoint_id = None
_dropped = 0


def source_id() -> str:
    global _source_id
    if _source_id is None:
        digest = hashlib.sha256()
        for name in ("diagnostics.py", "diagnostic_dispatch.py", "terminal_status.py", "ghostty_tabs.py", "ghostty-status.py"):
            digest.update(Path(__file__).with_name(name).read_bytes())
        _source_id = digest.hexdigest()[:16]
    return _source_id


def entrypoint_id() -> str:
    global _entrypoint_id
    if _entrypoint_id is None:
        try:
            _entrypoint_id = hashlib.sha256(Path(sys.argv[0]).read_bytes()).hexdigest()[:16]
        except OSError:
            _entrypoint_id = "unavailable"
    return _entrypoint_id


def emit(stage: str, *, producer: str = "python", **fields) -> None:
    global _dropped
    try:
        if not enabled():
            return
        context = CONTEXT.get()
        row = {"schema": 1, "timestamp_ms": time.time_ns() / 1_000_000, "pid": os.getpid(),
               "producer": producer, "source_id": source_id(), "stage": stage,
               "entrypoint_id": entrypoint_id(), "dropped_before": _dropped, **context, **clean(fields)}
        directory = root()
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(directory, 0o700)
        lock_fd = os.open(directory / f"{producer}.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(lock_fd, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            path = directory / f"{producer}.jsonl"
            if path.exists() and path.stat().st_size >= LIMIT:
                os.replace(path, directory / f"{producer}.jsonl.1")
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as out:
                os.fchmod(out.fileno(), 0o600)
                out.write(json.dumps(row, ensure_ascii=True, allow_nan=False) + "\n")
            _dropped = 0
    except Exception:
        _dropped += 1


@contextlib.contextmanager
def scope(agent: str, session_id=None, trace_id=None):
    token = CONTEXT.set({"agent": agent if agent in {"claude", "codex", "terminal"} else "terminal",
                         "session_id": fingerprint(session_id), "trace_id": trace_id or uuid.uuid4().hex})
    try:
        yield
    finally:
        CONTEXT.reset(token)


@contextlib.contextmanager
def span(stage: str, **fields):
    start = time.monotonic()
    emit(stage + ".start", **fields)
    try:
        yield
    except Exception as exc:
        emit(stage + ".error", error_type=type(exc).__name__, elapsed_ms=(time.monotonic() - start) * 1000)
        raise
    finally:
        emit(stage + ".end", elapsed_ms=(time.monotonic() - start) * 1000)


def read_rows():
    rows = []
    for path in root().glob("*.jsonl*"):
        with path.open(encoding="utf-8") as source:
            for line in source:
                try:
                    row = json.loads(line)
                    if isinstance(row, dict) and row.get("schema") == 1:
                        rows.append(row)
                except ValueError:
                    continue
    return sorted(rows, key=lambda r: r.get("timestamp_ms", 0))


def observe(agent: str, session: str, seconds: float) -> int:
    base = state_root()
    status = base / "status" / f"{agent}-{session}.json"
    home = Path.home()
    transcript_root = (Path(os.environ.get("CODEX_HOME") or home / ".codex") / "sessions" if agent == "codex"
                       else Path(os.environ.get("CLAUDE_CONFIG_DIR") or home / ".claude") / "projects")
    paths = list(transcript_root.rglob(f"*{session}.jsonl"))
    if len(paths) != 1:
        print("Need exactly one transcript for this session; no content was captured.", file=sys.stderr)
        return 2
    transcript = paths[0]
    offset = max(0, transcript.stat().st_size - 65536)
    partial = b""
    initial = True
    discarding = False
    previous = None
    deadline = time.monotonic() + seconds
    with scope(agent, session):
        emit("observer.start", producer="observer", offset=offset)
        while time.monotonic() < deadline:
            try:
                data = json.loads(status.read_text(encoding="utf-8"))
                if not isinstance(data, dict):
                    raise ValueError("invalid status object")
                signature = (data.get("state"), data.get("updated_at"), data.get("ghostty_terminal_id"))
                if signature != previous:
                    emit("observer.status", producer="observer", state=data.get("state"),
                         terminal_id=data.get("ghostty_terminal_id"), source_ms=date_ms(data.get("updated_at")))
                    previous = signature
            except (OSError, ValueError):
                emit("observer.gap", producer="observer", reason="status_unavailable")
            try:
                with transcript.open("rb") as source:
                    if os.fstat(source.fileno()).st_size < offset:
                        emit("observer.gap", producer="observer", reason="transcript_truncated", offset=offset)
                        offset, partial, initial, discarding = 0, b"", True, False
                    source.seek(offset)
                    chunk = source.read(1_048_576)
                    offset += len(chunk)
                baseline = initial
                lines = (partial + chunk).split(b"\n")
                partial = lines.pop()
                if discarding:
                    if lines:
                        lines.pop(0)
                        discarding = False
                    else:
                        partial = b""
                if len(partial) > 1_048_576:
                    partial = b""
                    discarding = True
                    emit("observer.gap", producer="observer", reason="oversized_transcript_row")
                if initial and offset - len(chunk) > 0 and lines:
                    lines.pop(0)
                initial = False
                for line in lines:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        emit("observer.gap", producer="observer", reason="malformed_transcript_row")
                        continue
                    for event in transcript_events(row, agent):
                        emit("observer.transcript", producer="observer", reason="baseline_tail" if baseline else "live_append", **event)
            except (OSError, ValueError):
                emit("observer.gap", producer="observer", reason="transcript_unavailable")
            time.sleep(0.1)
        emit("observer.end", producer="observer")
    print("Capture finished. Use report with --agent and --session to inspect it.")
    return 0


def sample(agent: str, session: str) -> int:
    import ghostty_tabs
    import terminal_status

    with scope(agent, session):
        started = time.monotonic()
        try:
            record = terminal_status.read_status(agent, session)
            if not record:
                emit("observer.sample_error", producer="observer", reason="record_missing")
                return 2
            terminal = ghostty_tabs.find(record.get("ghostty_terminal_id"))
            if terminal is None:
                emit("observer.sample_error", producer="observer", reason="terminal_unresolved")
                return 2
            shown = terminal.tab_title.removeprefix(terminal_status.BELL)
            observed = next((state for state, glyph in terminal_status.STATE_GLYPH.items() if shown.startswith(glyph)), "unknown")
            emit("observer.tab", producer="observer", state=record.get("state"), observed_state=observed,
                 terminal_id=terminal.id, source_ms=date_ms(record.get("updated_at")),
                 elapsed_ms=(time.monotonic() - started) * 1000)
            print(json.dumps({"hook_state": record.get("state"), "tab_state": observed}))
            return 0
        except Exception as exc:
            emit("observer.sample_error", producer="observer", error_type=type(exc).__name__,
                 elapsed_ms=(time.monotonic() - started) * 1000)
            print("Ghostty sample failed; inspect observer.sample_error.", file=sys.stderr)
            return 2


def date_ms(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000
    except (AttributeError, ValueError, TypeError):
        return None


def transcript_fields(row: dict, agent: str) -> dict:
    if not isinstance(row, dict):
        return {}
    kind = row.get("type")
    if agent == "claude" and kind == "system" and row.get("subtype") == "turn_duration":
        return {"event_type": "turn_duration", "source_ms": date_ms(row.get("timestamp"))}
    data = row.get("payload") if agent == "codex" else row.get("message")
    data = data if isinstance(data, dict) else {}
    event = data.get("type") if agent == "codex" else kind
    known = {"task_started", "task_complete", "turn_aborted", "user_message", "function_call",
             "custom_tool_call", "function_call_output", "custom_tool_call_output", "message", "user", "assistant"}
    if not isinstance(event, str) or event not in known or (agent == "claude" and row.get("isSidechain") is True):
        return {}
    result = {"event_type": event, "source_ms": date_ms(row.get("timestamp"))}
    if agent == "codex":
        result.update(call_id=data.get("call_id"), tool_name=data.get("name"))
        if data.get("phase") in {"commentary", "final_answer"}:
            result["phase"] = data["phase"]
    else:
        blocks = data.get("content")
        if isinstance(blocks, list):
            for block in blocks:
                if not isinstance(block, dict):
                    continue
                if block.get("type") in {"tool_use", "tool_result"}:
                    result.update(event_type=block["type"], call_id=block.get("id") or block.get("tool_use_id"),
                                  tool_name=block.get("name"))
                    break
    return result


def transcript_events(row: dict, agent: str) -> list[dict]:
    fields = transcript_fields(row, agent)
    if not fields:
        return []
    if agent != "claude":
        return [fields]
    if fields["event_type"] == "turn_duration":
        return [fields]
    events = [{"event_type": row["type"], "source_ms": fields.get("source_ms")}]
    message = row.get("message") or {}
    blocks = message.get("content") if isinstance(message, dict) else None
    for block in blocks if isinstance(blocks, list) else []:
        if isinstance(block, dict) and block.get("type") in {"tool_use", "tool_result"}:
            events.append({"event_type": block["type"], "source_ms": fields.get("source_ms"),
                           "call_id": block.get("id") or block.get("tool_use_id"), "tool_name": block.get("name")})
    return events


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Opt-in, content-free status diagnostics. No hooks are installed or replayed.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("enable")
    sub.add_parser("disable")
    report = sub.add_parser("report")
    report.add_argument("--agent", choices=("claude", "codex"))
    report.add_argument("--session")
    report.add_argument("--tail", type=int, default=80)
    marker = sub.add_parser("mark")
    marker.add_argument("agent", choices=("claude", "codex"))
    marker.add_argument("session")
    marker.add_argument("marker", choices=sorted(MARKERS))
    watch = sub.add_parser("watch")
    watch.add_argument("agent", choices=("claude", "codex"))
    watch.add_argument("session")
    watch.add_argument("--seconds", type=float, default=120)
    snapshot = sub.add_parser("sample")
    snapshot.add_argument("agent", choices=("claude", "codex"))
    snapshot.add_argument("session")
    route = sub.add_parser("route")
    route.add_argument("agent", choices=("claude", "codex"))
    route.add_argument("session")
    route.add_argument("--source", required=True)
    route.add_argument("--output", required=True)
    unroute = sub.add_parser("unroute")
    unroute.add_argument("agent", choices=("claude", "codex"))
    unroute.add_argument("session")
    args = parser.parse_args(argv)
    if args.command == "enable":
        root().mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(root(), 0o700)
        fd = os.open(root() / "enabled", os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        print("Diagnostics enabled. Only instrumented copies produce traces.")
    elif args.command == "disable":
        (root() / "enabled").unlink(missing_ok=True)
        print("Diagnostics disabled by marker; an explicit environment override takes precedence.")
    elif args.command in {"mark", "watch", "sample"}:
        if not enabled():
            parser.error("diagnostics are disabled")
        if not args.session or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in args.session):
            parser.error("session must contain only letters, digits, underscores and hyphens")
        if args.command == "watch":
            if not 1 <= args.seconds <= 600:
                parser.error("--seconds must be between 1 and 600")
            return observe(args.agent, args.session, args.seconds)
        if args.command == "sample":
            return sample(args.agent, args.session)
        with scope(args.agent, args.session):
            emit("capture.marker", producer="observer", marker=args.marker)
        print("Marker attempted; verify it in report (diagnostics are best effort).")
    elif args.command in {"route", "unroute"}:
        from diagnostic_dispatch import set_route
        set_route(args.agent, args.session, args.source if args.command == "route" else None,
                  args.output if args.command == "route" else None)
        print("Session diagnostic route registered." if args.command == "route" else "Session diagnostic route removed.")
    else:
        if not 1 <= args.tail <= 10000:
            parser.error("--tail must be between 1 and 10000")
        rows = [r for r in read_rows() if (not args.agent or r.get("agent") == args.agent)
                and (not args.session or r.get("session_id") == fingerprint(args.session))]
        print(json.dumps({"enabled": enabled(), "row_count": len(rows),
                          "sources": sorted({(r.get("producer", ""), r.get("source_id", "")) for r in rows}),
                          "coverage": {name: any(r.get("stage") == stage for r in rows) for name, stage in
                                       (("hook", "hook.received"), ("worker", "worker.apply.start"),
                                        ("sidebar", "sidebar.row"), ("transcript_observer", "observer.transcript"))},
                          "rows": rows[-args.tail:]}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
