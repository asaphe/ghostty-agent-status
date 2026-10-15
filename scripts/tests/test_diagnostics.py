import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagnostics as d
import terminal_status as s
import ghostty_tabs as g


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        env = patch.dict(os.environ, {"GHOSTTY_AGENT_STATUS_DIR": str(self.base),
                                     "GHOSTTY_AGENT_STATUS_DIAGNOSTICS": "0", "GHOSTTY_AGENT_STATUS_DIAGNOSTICS_DIR": ""})
        env.start()
        self.addCleanup(env.stop)

    def activate(self):
        os.environ["GHOSTTY_AGENT_STATUS_DIAGNOSTICS"] = "1"

    def test_disabled_has_no_files_and_marker_can_toggle_without_restart(self):
        d.emit("test.disabled")
        self.assertFalse(d.root().exists())
        os.environ.pop("GHOSTTY_AGENT_STATUS_DIAGNOSTICS")
        d.main(["enable"])
        self.assertTrue(d.enabled())
        d.main(["disable"])
        self.assertFalse(d.enabled())

    def test_content_is_excluded_and_identity_is_consistent(self):
        self.activate()
        secret = "private prompt /Users/private command bearer-secret"
        with d.scope("codex", "session-1", "a" * 32):
            d.emit("hook.received", tool_name=secret, call_key=secret, actor_id="child",
                   pending_keys=[secret], state="waiting", command=secret, message=secret,
                   title=secret, cwd=secret, tool_input={"command": secret})
        text = (d.root() / "python.jsonl").read_text()
        self.assertNotIn(secret, text)
        row = json.loads(text)
        self.assertEqual(row["session_id"], d.fingerprint("session-1"))
        self.assertEqual(row["pending_keys"], [row["call_key"]])
        self.assertEqual(row["agent"], "codex")
        self.assertEqual(row["trace_id"], "a" * 32)
        self.assertEqual((d.root().stat().st_mode & 0o777), 0o700)
        self.assertEqual(((d.root() / "python.jsonl").stat().st_mode & 0o777), 0o600)

    def test_failure_span_records_category_and_preserves_exception(self):
        self.activate()
        with d.scope("claude", "session-1"):
            with self.assertRaisesRegex(ValueError, "private"):
                with d.span("hook.update"):
                    raise ValueError("private error content")
        rows = d.read_rows()
        self.assertEqual([r["stage"] for r in rows], ["hook.update.start", "hook.update.error", "hook.update.end"])
        self.assertEqual(rows[1]["error_type"], "ValueError")
        self.assertNotIn("private", json.dumps(rows))

    def test_rotation_is_bounded_and_symlink_target_is_untouched(self):
        self.activate()
        with patch.object(d, "LIMIT", 1):
            for i in range(4):
                d.emit("test.rotate", row_count=i)
        self.assertEqual(len(list(d.root().glob("python.jsonl*"))), 2)
        self.assertEqual([r["row_count"] for r in d.read_rows()], [2, 3])
        target = self.base / "untouched"
        target.write_text("original")
        (d.root() / "python.jsonl").unlink()
        (d.root() / "python.jsonl").symlink_to(target)
        d.emit("test.symlink")
        self.assertEqual(target.read_text(), "original")

    def test_trace_write_failure_cannot_break_status_operation(self):
        self.activate()
        with patch.object(d.os, "open", side_effect=OSError("private path")):
            d.emit("test.write_failure")
            with d.span("test.span"):
                pass
        self.assertEqual(d.read_rows(), [])
        d.emit("test.recovered")
        self.assertGreaterEqual(d.read_rows()[0]["dropped_before"], 1)

    def test_hook_and_worker_share_trace_without_payload_or_state_changes(self):
        self.activate()
        with patch.object(s, "_update") as update:
            s.update("claude", {"session_id": "sid", "hook_event_name": "UserPromptSubmit",
                                "tool_input": {"command": "private-command"}})
        update.assert_called_once()
        hook = d.read_rows()[0]
        with patch.dict(os.environ, {"GHOSTTY_AGENT_STATUS_TRACE_ID": hook["trace_id"]}), patch.object(s, "_apply") as apply:
            s.apply("claude", "sid", "UserPromptSubmit")
        apply.assert_called_once_with("claude", "sid", "UserPromptSubmit")
        worker = next(r for r in d.read_rows() if r["stage"] == "worker.apply.start")
        self.assertEqual(hook["trace_id"], worker["trace_id"])
        self.assertEqual(hook["session_id"], worker["session_id"])
        self.assertNotIn("private-command", json.dumps(d.read_rows()))

    def test_ghostty_failure_records_timing_without_script_or_stderr(self):
        self.activate()
        import subprocess
        result = subprocess.CompletedProcess([], 1, "", "private error and path")
        with patch.object(g.subprocess, "run", return_value=result):
            with self.assertRaises(g.GhosttyError):
                g.osascript("private script")
        rows = d.read_rows()
        self.assertEqual(rows[-1]["reason"], "nonzero_exit")
        self.assertGreaterEqual(rows[-1]["elapsed_ms"], 0)
        self.assertNotIn("private", json.dumps(rows))

    def test_transcript_metadata_excludes_answers_and_distinguishes_agents(self):
        codex = {"timestamp": "2026-10-14T08:00:00.125Z", "type": "response_item",
                 "payload": {"type": "function_call_output", "call_id": "call-1", "output": "private answer"}}
        claude = {"timestamp": "2026-10-14T08:00:00.125Z", "type": "user",
                  "message": {"content": [{"type": "tool_result", "tool_use_id": "call-1", "content": "private answer"}]}}
        self.assertEqual(d.transcript_fields(codex, "codex")["event_type"], "function_call_output")
        fields = d.transcript_fields(claude, "claude")
        self.assertEqual(fields["event_type"], "tool_result")
        self.assertEqual(fields["source_ms"], d.date_ms(codex["timestamp"]))
        self.assertNotIn("private answer", json.dumps(fields))
        self.assertEqual(d.transcript_fields({**claude, "isSidechain": True}, "claude"), {})
        claude["message"]["content"].append({"type": "tool_result", "tool_use_id": "call-2", "content": "second private answer"})
        self.assertEqual([r.get("call_id") for r in d.transcript_events(claude, "claude")], [None, "call-1", "call-2"])
        self.assertEqual(d.transcript_fields({"payload": {"type": {}}}, "codex"), {})
        end = {"type": "system", "subtype": "turn_duration", "timestamp": claude["timestamp"]}
        self.assertEqual(d.transcript_events(end, "claude")[0]["event_type"], "turn_duration")

    def test_sample_reads_tab_glyph_without_changing_it(self):
        self.activate()
        terminal = g.Terminal("T", "tab", "window", "private title", "✋🟩 private title", "/private/path", False)
        with patch.object(s, "read_status", return_value={"state": "working", "ghostty_terminal_id": "T"}), \
                patch.object(g, "find", return_value=terminal), patch.object(g, "set_tab_title") as write:
            self.assertEqual(d.sample("codex", "sid"), 0)
        write.assert_not_called()
        row = next(r for r in d.read_rows() if r["stage"] == "observer.tab")
        self.assertEqual((row["state"], row["observed_state"]), ("working", "waiting"))
        self.assertNotIn("private", json.dumps(d.read_rows()))

    def test_watch_captures_existing_evidence_and_reports_missing_transcript(self):
        self.activate()
        codex = self.base / "codex"
        (codex / "sessions").mkdir(parents=True)
        (codex / "sessions/rollout-sid.jsonl").write_text(json.dumps({"timestamp": "2026-10-14T08:00:00Z",
            "type": "event_msg", "payload": {"type": "user_message", "message": "private prompt"}}) + "\n")
        (self.base / "status").mkdir()
        (self.base / "status/codex-sid.json").write_text(json.dumps({"state": "waiting", "updated_at": "2026-10-14T08:00:00Z"}))
        with patch.dict(os.environ, {"CODEX_HOME": str(codex)}):
            self.assertEqual(d.observe("codex", "sid", 0.01), 0)
            self.assertEqual(d.observe("codex", "missing", 0.01), 2)
        rows = d.read_rows()
        self.assertIn("observer.transcript", [r["stage"] for r in rows])
        self.assertNotIn("private prompt", json.dumps(rows))

    def test_watch_still_reads_transcript_without_status_and_handles_partial_append(self):
        self.activate()
        codex = self.base / "codex"
        (codex / "sessions").mkdir(parents=True)
        transcript = codex / "sessions/rollout-sid.jsonl"
        transcript.write_text("")
        row = json.dumps({"timestamp": "2026-10-14T08:00:00Z", "type": "event_msg", "payload": {"type": "task_complete"}})
        chunks = iter([row[:40], row[40:] + "\n", ""])
        def append(_):
            with transcript.open("a") as out:
                out.write(next(chunks))
        with patch.dict(os.environ, {"CODEX_HOME": str(codex)}), \
                patch.object(d.time, "monotonic", side_effect=[0, 0, 0.1, 0.2, 0.3]), \
                patch.object(d.time, "sleep", side_effect=append):
            self.assertEqual(d.observe("codex", "sid", 0.25), 0)
        events = [r for r in d.read_rows() if r["stage"] == "observer.transcript"]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["event_type"], "task_complete")
        self.assertEqual(events[0]["reason"], "live_append")


if __name__ == "__main__":
    unittest.main()
