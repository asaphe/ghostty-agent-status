import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagnostic_dispatch as dispatch
import terminal_status


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = Path(__file__).resolve().parents[1]
        env = patch.dict(os.environ, {"GHOSTTY_AGENT_STATUS_DIR": self.tmp.name,
                                     "GHOSTTY_AGENT_STATUS_DIAGNOSTICS": "0",
                                     "GHOSTTY_AGENT_STATUS_DIAGNOSTIC_SOURCE": ""})
        env.start()
        self.addCleanup(env.stop)

    def test_routes_are_exact_and_can_be_removed(self):
        sid, other = str(uuid.uuid4()), str(uuid.uuid4())
        dispatch.set_route("codex", sid, str(self.source), self.tmp.name)
        self.assertEqual(dispatch.route_for("codex", sid)["source"], str(self.source))
        self.assertIsNone(dispatch.route_for("codex", other))
        self.assertIsNone(dispatch.route_for("claude", sid))
        self.assertEqual(dispatch.registry().stat().st_mode & 0o777, 0o600)
        dispatch.set_route("codex", sid, None, None)
        self.assertIsNone(dispatch.route_for("codex", sid))

    def test_missing_corrupt_or_incomplete_route_uses_original_source(self):
        sid = str(uuid.uuid4())
        self.assertIsNone(dispatch.route_for("codex", sid))
        dispatch.registry().parent.mkdir(parents=True)
        dispatch.registry().write_text("broken")
        self.assertIsNone(dispatch.route_for("codex", sid))
        dispatch.registry().write_text(json.dumps({f"codex-{sid}": {"source": self.tmp.name, "output": self.tmp.name}}))
        self.assertIsNone(dispatch.route_for("codex", sid))
        self.assertIsNone(dispatch.route_for("codex", "invalid"))

    def test_dispatch_is_opt_in_and_does_not_consume_input_before_exec(self):
        spec = importlib.util.spec_from_file_location("diagnostic_hook_test", self.source / "ghostty-status.py")
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        target = Path(self.tmp.name) / "ghostty-status.py"
        target.write_text("temporary target")
        payload = {"session_id": str(uuid.uuid4()), "hook_event_name": "Stop"}
        stdin = io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode()))
        with patch.dict(os.environ, {"GHOSTTY_AGENT_STATUS_DIAGNOSTIC_SOURCE": self.tmp.name}), \
                patch.object(sys, "argv", [str(self.source / "ghostty-status.py"), "codex"]), \
                patch.object(sys, "stdin", stdin), patch.object(os, "execv") as execute, \
                patch.object(terminal_status, "update") as update:
            self.assertEqual(hook.main(), 0)
            execute.assert_not_called()
            update.assert_called_once_with("codex", payload)
        with patch.dict(os.environ, {"GHOSTTY_AGENT_STATUS_DIAGNOSTICS": "1", "GHOSTTY_AGENT_STATUS_DIAGNOSTIC_SOURCE": self.tmp.name}), \
                patch.object(sys, "argv", [str(self.source / "ghostty-status.py"), "codex"]), \
                patch.object(sys, "stdin") as stdin, patch.object(os, "execv") as execute:
            self.assertEqual(hook.main(), 0)
            execute.assert_called_once_with(sys.executable, [sys.executable, str(target), "codex"])
            stdin.buffer.read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
