import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

INSTALLER = Path(__file__).resolve().parents[2] / "codex" / "install.py"


class CodexInstallTests(unittest.TestCase):
    def run_installer(self, home, *args):
        env = {**os.environ, "CODEX_HOME": str(home)}
        return subprocess.run([sys.executable, str(INSTALLER), *args], env=env, capture_output=True, text=True, check=True)

    def test_install_is_idempotent_keeps_other_hooks_and_uninstalls_cleanly(self):
        with tempfile.TemporaryDirectory() as home:
            path = Path(home) / "hooks.json"
            original = {"hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "other-hook"}]}]}}
            path.write_text(json.dumps(original))
            self.assertIn("8 event(s) added", self.run_installer(home).stdout)
            self.assertIn("0 event(s) added", self.run_installer(home).stdout)
            stop = [h["command"] for g in json.loads(path.read_text())["hooks"]["Stop"] for h in g["hooks"]]
            self.assertEqual(stop[0], "other-hook")
            self.assertTrue(stop[1].endswith('ghostty-status.py" codex'))
            self.assertEqual(len(list(Path(home).glob("hooks.json.bak-*"))), 1)
            self.run_installer(home, "--uninstall")
            self.assertEqual(json.loads(path.read_text()), original)

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as home:
            self.run_installer(home, "--dry-run")
            self.assertFalse((Path(home) / "hooks.json").exists())


if __name__ == "__main__":
    unittest.main()
