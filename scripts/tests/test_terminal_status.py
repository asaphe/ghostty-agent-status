import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ghostty_tabs as g
import terminal_status as s

def bash_color(key):
    """The same hue arithmetic in bash with POSIX cksum, so a shell script can derive the same color."""
    script = ('HASH=$(printf "%s" "$1" | cksum | awk "{print \\$1}"); HUE=$(( HASH % 360 )); SECTOR=$(( HUE / 60 ));'
              'FRAC=$(( (HUE % 60) * 255 / 60 )); case $SECTOR in 0) R=255;G=$FRAC;B=0;; 1) R=$((255-FRAC));G=255;B=0;;'
              '2) R=0;G=255;B=$FRAC;; 3) R=0;G=$((255-FRAC));B=255;; 4) R=$FRAC;G=0;B=255;; 5) R=255;G=0;B=$((255-FRAC));; esac;'
              'printf "#%02x%02x%02x" $R $G $B')
    return subprocess.run(["bash", "-c", script, "-", key], capture_output=True, text=True, check=True).stdout


class ColorTests(unittest.TestCase):
    KEYS = ("dotfiles:feature-x", "api:main", "web:fix-123-login", "x", "ü:ß", "")

    def test_cksum_matches_posix_cksum(self):
        for key in self.KEYS:
            out = subprocess.run(["cksum"], input=key.encode(), capture_output=True, check=True).stdout.split()[0]
            self.assertEqual(s.cksum(key.encode()), int(out), key)

    def test_color_matches_the_shell_formula(self):
        for key in self.KEYS[:4]:
            repo, branch = key.split(":") if ":" in key else (key, "")
            self.assertEqual(s.color_of(repo, branch, "/cwd"), bash_color(f"{repo}:{branch or '/cwd'}"), key)

    def test_glyph_is_the_nearest_hue(self):
        self.assertEqual(s.color_glyph("#0005ff"), "🟦")
        self.assertEqual(s.color_glyph("#ff001a"), "🟥")
        self.assertEqual(s.color_glyph("#00ff33"), "🟩")
        self.assertEqual(s.color_glyph("#99ff00"), "🟨")
        self.assertEqual(s.color_glyph("#ff6600"), "🟧")
        self.assertEqual(s.color_glyph(None), "")


class StateTests(unittest.TestCase):
    def test_codex_question_tools_wait_for_input(self):
        for name in ("request_user_input", "functions.request_user_input"):
            self.assertEqual(s.state_for({"hook_event_name": "PreToolUse", "tool_name": name,
                                         "tool_input": {"questions": [{"question": "Choose?"}]}}),
                             ("waiting", "Choose?"))

    def test_background_question_completion_restores_main_state(self):
        tracking = {}
        old = {"state": "idle"}
        self.assertEqual(s.transition(old, {"hook_event_name": "Stop"}, tracking), ("idle", None))
        question = {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "agent_id": "child",
                    "tool_use_id": "question-1"}
        self.assertEqual(s.transition(old, question, tracking)[0], "waiting")
        self.assertEqual(s.transition({"state": "waiting"}, {**question, "hook_event_name": "PostToolUse"}, tracking),
                         ("idle", None))

    def test_first_background_wait_preserves_existing_working_state(self):
        tracking = {}
        payload = {"hook_event_name": "PermissionRequest", "agent_id": "child", "tool_use_id": "p1"}
        s.transition({"state": "working"}, payload, tracking)
        self.assertEqual(s.transition({"state": "waiting"}, {**payload, "hook_event_name": "PostToolUse"}, tracking),
                         ("working", None))

    def test_unrelated_activity_does_not_clear_another_agents_wait(self):
        tracking = {}
        s.transition({}, {"hook_event_name": "UserPromptSubmit"}, tracking)
        s.transition({}, {"hook_event_name": "PermissionRequest", "agent_id": "child", "tool_use_id": "p1"}, tracking)
        self.assertEqual(s.transition({"state": "waiting"}, {"hook_event_name": "PostToolUse", "tool_use_id": "other"}, tracking)[0], "waiting")
        self.assertEqual(s.transition({"state": "waiting"}, {"hook_event_name": "SubagentStop", "agent_id": "child"}, tracking), ("working", None))

    def test_late_tool_events_cannot_revive_ended_session(self):
        for event in ("PreToolUse", "PostToolUse", "PermissionRequest", "Stop"):
            self.assertIsNone(s.transition({"state": "done"}, {"hook_event_name": event}, {}))

    def test_notification_wait_clears_on_tool_completion(self):
        tracking = {}
        s.transition({}, {"hook_event_name": "UserPromptSubmit"}, tracking)
        s.transition({}, {"hook_event_name": "Notification", "notification_type": "permission_prompt"}, tracking)
        self.assertEqual(s.transition({"state": "waiting"}, {"hook_event_name": "PostToolUse", "tool_name": "Bash"}, tracking), ("working", None))

    def test_notification_does_not_duplicate_owned_permission(self):
        tracking = {}
        payload = {"hook_event_name": "PermissionRequest", "agent_id": "child", "tool_use_id": "p1"}
        s.transition({"state": "working"}, payload, tracking)
        s.transition({"state": "waiting"}, {"hook_event_name": "Notification", "notification_type": "permission_prompt"}, tracking)
        self.assertEqual(s.transition({"state": "waiting"}, {**payload, "hook_event_name": "PostToolUse"}, tracking), ("working", None))

    def test_permission_without_tool_id_clears_when_result_has_id(self):
        tracking = {}
        s.transition({"state": "working"}, {"hook_event_name": "PermissionRequest", "tool_name": "Bash"}, tracking)
        self.assertEqual(s.transition({"state": "waiting"}, {"hook_event_name": "PostToolUse", "tool_name": "Bash",
                                                              "tool_use_id": "call-123"}, tracking), ("working", None))

    def test_parallel_prompts_for_one_tool_clear_separately(self):
        tracking = {}
        first = {"hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "a"}}
        second = {**first, "tool_input": {"command": "b"}}
        s.transition({"state": "working"}, first, tracking)
        s.transition({"state": "waiting"}, second, tracking)
        done = {**first, "hook_event_name": "PostToolUse", "tool_use_id": "call-a"}
        self.assertEqual(s.transition({"state": "waiting"}, done, tracking)[0], "waiting")
        self.assertEqual(s.transition({"state": "waiting"}, {**done, "tool_input": {"command": "b"}}, tracking)[0], "working")

    def test_stop_reports_running_background_tasks(self):
        tasks = [{"id": "a", "type": "subagent", "status": "running"}, {"id": "b", "type": "shell", "status": "completed"}]
        self.assertEqual(s.state_for({"hook_event_name": "Stop", "background_tasks": tasks}),
                         ("idle", "1 background task running"))

    def test_codex_thread_without_a_tab_gets_no_status_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            rollout = Path(tmp) / "rollout.jsonl"
            rollout.write_text(json.dumps({"type": "session_meta", "payload": {"source": "exec"}}) + "\n")
            status = Path(tmp) / "status"
            status.mkdir()
            (status / "codex-T1.json").write_text("{}")
            with patch.object(s, "STATUS_DIR", status), patch.object(s, "WORK_DIR", Path(tmp) / "work"):
                s.update("codex", {"session_id": "T1", "hook_event_name": "UserPromptSubmit",
                                   "transcript_path": str(rollout)})
            self.assertFalse((status / "codex-T1.json").exists())

    def test_codex_thread_without_a_rollout_waits_for_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            status, work = Path(tmp) / "status", Path(tmp) / "work"
            payload = {"session_id": "T1", "hook_event_name": "UserPromptSubmit", "cwd": tmp}
            with patch.object(s, "STATUS_DIR", status), patch.object(s, "WORK_DIR", work), \
                    patch.object(s, "CODEX_HOME", Path(tmp) / "codex"), \
                    patch.object(s, "process_owner", return_value=(42, None, True)), \
                    patch.object(s, "codex_tuis", return_value=[{"pid": 7}]), \
                    patch.object(s, "git_info", return_value=("repo", "main", True)), \
                    patch.object(s, "spawn_worker"):
                s.update("codex", payload)
                self.assertFalse((status / "codex-T1.json").exists())
                rollout = Path(tmp) / "rollout.jsonl"
                rollout.write_text(json.dumps({"type": "session_meta", "payload": {"source": "cli"}}) + "\n")
                s.update("codex", {**payload, "transcript_path": str(rollout)})
                self.assertTrue((status / "codex-T1.json").exists())

    def test_events_map_to_states(self):
        cases = [
            ({"hook_event_name": "SessionStart"}, ("idle", None)),
            ({"hook_event_name": "UserPromptSubmit"}, ("working", None)),
            ({"hook_event_name": "PreToolUse", "tool_name": "Bash"}, ("working", None)),
            ({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
              "tool_input": {"questions": [{"question": "Which?"}]}}, ("waiting", "Which?")),
            ({"hook_event_name": "PermissionRequest", "tool_name": "Bash"}, ("waiting", "permission: Bash")),
            ({"hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "m"},
             ("waiting", "m")),
            ({"hook_event_name": "Notification", "notification_type": "idle_prompt"}, ("idle", None)),
            ({"hook_event_name": "Notification", "notification_type": "auth_success"}, None),
            ({"hook_event_name": "Stop"}, ("idle", None)),
            ({"hook_event_name": "StopFailure"}, ("idle", "turn failed")),
            ({"hook_event_name": "SessionEnd"}, ("done", None)),
            ({"hook_event_name": "PreCompact"}, None),
            ({"hook_event_name": "SubagentStop", "agent_id": "a1"}, None),
            ({"hook_event_name": "PreToolUse", "tool_name": "Bash", "agent_id": "a1"}, None),
            ({"hook_event_name": "PostToolUse", "tool_name": "Bash", "agent_id": "a1"}, None),
            ({"hook_event_name": "PermissionRequest", "tool_name": "Bash", "agent_id": "a1"}, ("waiting", "permission: Bash")),
        ]
        for payload, expected in cases:
            self.assertEqual(s.state_for(payload), expected, payload)


class TitleTests(unittest.TestCase):
    def test_compose_and_unprefix_round_trip(self):
        title = s.compose("waiting", "#0005ff", "DEV-1 work · milestone")
        self.assertEqual(title, "✋🟦 DEV-1 work · milestone")
        self.assertEqual(s.unprefixed(title), "DEV-1 work · milestone")
        self.assertEqual(s.unprefixed("🔔 " + title), "DEV-1 work · milestone")
        self.assertEqual(s.unprefixed("Plain label"), "Plain label")

    def test_agent_title_drops_the_spinner_only(self):
        self.assertEqual(s.agent_title("◑ Ghostty tab status · [cfg]"), "Ghostty tab status · [cfg]")
        self.assertEqual(s.agent_title("[cfg] DEV-1"), "[cfg] DEV-1")
        self.assertEqual(s.agent_title("tty-probe-abc123"), "")

    def test_foreign_override_ignores_ours_the_bell_and_a_spinner_tick(self):
        def term(title, tab_title):
            return g.Terminal("T", "tab", "w", title, tab_title, "/", False)

        self.assertEqual(s.foreign_override(term("◐ x", "◑ x")), "")
        self.assertEqual(s.foreign_override(term("✳ x", "🔔 ✳ x")), "")
        self.assertEqual(s.foreign_override(term("◐ x", "⏳🟦 x")), "")
        self.assertEqual(s.foreign_override(term("⠙ .dotfiles", "DEV-1 label")), "DEV-1 label")

    def test_daemon_detection_needs_the_executable_not_a_mention(self):
        self.assertTrue(s.is_codex_app_server("/x/bin/codex app-server --listen unix:// --managed-daemon"))
        self.assertFalse(s.is_codex_app_server("claude --name x -- Codex hooks run in an app-server daemon"))

    def test_a_codex_tab_is_found_by_the_thread_name_in_its_own_title(self):
        def term(tid, title):
            return g.Terminal(tid, "tab", "w", title, title, "/", False)

        listing = [term("T1", "⠴ Verify finalization | feature-123-long-branch-na..."),
                   term("T2", "⠹ Other thread | backend"), term("T3", "✳ Verify finalization · [api]")]
        with patch.object(s.ghostty_tabs, "terminals", return_value=listing), \
                patch.object(s, "codex_thread_name", return_value="Verify finalization"):
            self.assertEqual(s.codex_terminal_by_name("t"), "T1")
        with patch.object(s.ghostty_tabs, "terminals", return_value=listing + [term("T4", "Verify finalization | x")]), \
                patch.object(s, "codex_thread_name", return_value="Verify finalization"):
            self.assertIsNone(s.codex_terminal_by_name("t"))
        with patch.object(s, "codex_thread_name", return_value=None):
            self.assertIsNone(s.codex_terminal_by_name("t"))


class CodexPickTests(unittest.TestCase):
    def tui(self, pid, cwd="/repo", resumed=None):
        return {"pid": pid, "tty": f"/dev/ttys{pid:03d}", "cwd": cwd, "resumed": resumed}

    def pick(self, tuis, event="PreToolUse", claimed=(), typed=()):
        ages = {f"/dev/ttys{pid:03d}": 1.0 for pid in typed}
        with patch.object(s, "tty_input_age", side_effect=lambda tty: ages.get(tty, 999.0)):
            found = s.pick_codex_tui("thread-1", event, "/repo", tuis, set(claimed))
        return found and found["pid"]

    def test_a_resumed_thread_wins(self):
        self.assertEqual(self.pick([self.tui(1), self.tui(2, resumed="thread-1")]), 2)

    def test_the_only_tty_that_took_input_wins_on_a_prompt(self):
        self.assertEqual(self.pick([self.tui(1), self.tui(2)], "UserPromptSubmit", typed=[2]), 2)
        self.assertIsNone(self.pick([self.tui(1), self.tui(2)], "UserPromptSubmit", typed=[1, 2]))

    def test_input_is_not_evidence_for_tool_events(self):
        self.assertIsNone(self.pick([self.tui(1), self.tui(2)], "PreToolUse", typed=[2]))

    def test_the_only_unclaimed_tui_in_the_directory(self):
        self.assertEqual(self.pick([self.tui(1), self.tui(2)], claimed=[1]), 2)
        self.assertEqual(self.pick([self.tui(1), self.tui(2, cwd="/elsewhere")]), 1)
        self.assertIsNone(self.pick([self.tui(1), self.tui(2)]))


class StatusFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        for name, value in (("STATUS_DIR", root / "status"), ("WORK_DIR", root / "work")):
            patcher = patch.object(s, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.spawned = []
        patcher = patch.object(s, "spawn_worker", side_effect=lambda *a: self.spawned.append(a))
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_hook(self, event, env="ghostty", owner=None, cwd=None):
        owner = owner or (os.getpid(), "/dev/ttys001", False)
        payload = {"session_id": "sid-1", "hook_event_name": event, "cwd": cwd or str(Path(__file__).parent)}
        with patch.dict(os.environ, {"TERM_PROGRAM": env}), patch.object(s, "process_owner", return_value=owner):
            s.update("claude", payload)
        return s.read_status("claude", "sid-1")

    def test_writes_exactly_the_contract_fields_atomically(self):
        record = self.run_hook("UserPromptSubmit")
        self.assertEqual(list(record), ["agent", "session_id", "state", "title", "cwd", "repo", "branch", "color",
                                        "ghostty_terminal_id", "pid", "updated_at", "message"])
        self.assertEqual((record["agent"], record["state"], record["pid"]), ("claude", "working", os.getpid()))
        self.assertRegex(record["color"], r"^#[0-9a-f]{6}$")
        self.assertRegex(record["updated_at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertEqual([p.name for p in s.STATUS_DIR.iterdir()], ["claude-sid-1.json"])

    def test_outside_ghostty_nothing_is_written(self):
        self.assertEqual(self.run_hook("UserPromptSubmit", env="iTerm.app"), {})
        self.assertEqual(self.spawned, [])

    def test_session_end_is_done_and_kept(self):
        self.run_hook("UserPromptSubmit")
        self.assertEqual(self.run_hook("SessionEnd")["state"], "done")

    def test_a_scratch_dir_outside_any_repo_keeps_the_color(self):
        color = self.run_hook("UserPromptSubmit")["color"]
        with tempfile.TemporaryDirectory() as scratch:
            record = self.run_hook("Stop", cwd=scratch)
        self.assertEqual((record["color"], record["cwd"]), (color, scratch))

    def test_unchanged_state_on_a_tool_event_skips_the_worker(self):
        self.run_hook("UserPromptSubmit")
        record = s.read_status("claude", "sid-1")
        record["ghostty_terminal_id"] = "T1"
        s.write_status(record)
        self.spawned.clear()
        self.run_hook("PreToolUse")
        self.assertEqual(self.spawned, [])
        self.run_hook("PermissionRequest")
        self.assertEqual(len(self.spawned), 1)
        self.assertEqual(json.loads(s.status_path("claude", "sid-1").read_text())["state"], "waiting")

    def test_an_unresolved_codex_row_is_titled_by_its_thread_name(self):
        payload = {"session_id": "sid-1", "hook_event_name": "UserPromptSubmit", "cwd": str(Path(__file__).parent)}
        with patch.object(s, "process_owner", return_value=(os.getpid(), None, True)), \
                patch.object(s, "codex_tuis", return_value=[{"pid": 1}]), \
                patch.object(s, "codex_source", return_value="cli"), \
                patch.object(s, "codex_thread_name", return_value="Named thread"):
            s.update("codex", payload)
        self.assertEqual(s.read_status("codex", "sid-1")["title"], "Named thread")

    def test_a_codex_pid_is_kept_when_the_tab_probe_misses(self):
        self.run_hook("UserPromptSubmit")
        record = s.read_status("claude", "sid-1")
        record["agent"] = "codex"
        s.write_status(record)
        with patch.object(s, "locate", return_value=(4242, "/dev/ttys042")), \
                patch.object(s.ghostty_tabs, "terminals_for_ttys", return_value={}):
            s.apply("codex", "sid-1", "UserPromptSubmit")
        record = s.read_status("codex", "sid-1")
        self.assertEqual((record["pid"], record["ghostty_terminal_id"]), (4242, None))
        with patch.object(s, "locate", return_value=(4242, "/dev/ttys042")), \
                patch.object(s.ghostty_tabs, "terminals_for_ttys", return_value={"/dev/ttys042": "T9"}), \
                patch.object(s.ghostty_tabs, "find", return_value=None), patch.object(s, "show"):
            s.apply("codex", "sid-1", "PreToolUse")
        self.assertEqual(s.read_status("codex", "sid-1")["ghostty_terminal_id"], "T9")

    def test_prune_removes_only_what_a_day_dead_session_left(self):
        old = __import__("time").time() - s.PRUNE_AFTER_SECONDS - 60
        files = {}
        for sid, pid in (("dead-old", 999999), ("dead-new", 999999), ("alive-old", os.getpid())):
            s.write_status({"agent": "claude", "session_id": sid, "pid": pid, "ghostty_terminal_id": f"T-{sid}"})
            label = s.label_path("claude", sid)
            s._write_json(label, {"label": sid})
            with s.locked(f"claude-{sid}"):
                pass
            files[sid] = (s.status_path("claude", sid), label, s.WORK_DIR / "locks" / f"claude-{sid}.lock")
        for name in ("tab-T-dead-old", "tab-T-alive-old"):
            with s.locked(name):
                pass
        for path in [*files["dead-old"], *files["alive-old"], *(s.WORK_DIR / "locks").glob("tab-*.lock")]:
            os.utime(path, (old, old))
        s.prune()
        self.assertFalse(any(p.exists() for p in files["dead-old"]))
        self.assertTrue(all(p.exists() for p in files["dead-new"] + files["alive-old"]))
        self.assertFalse((s.WORK_DIR / "locks" / "tab-T-dead-old.lock").exists())
        self.assertTrue((s.WORK_DIR / "locks" / "tab-T-alive-old.lock").exists())


if __name__ == "__main__":
    unittest.main()
