import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ghostty_tabs as g


def term(tid, title, tab_title=None):
    return g.Terminal(tid, f"tab-{tid}", "w1", title, title if tab_title is None else tab_title, "/tmp", False)


class ListingTests(unittest.TestCase):
    def test_rows_parse_and_a_differing_tab_title_is_an_override(self):
        raw = g.FIELD.join(["T1", "tab1", "w1", "✳ claude", "PR 12 gate", "/tmp", "true"]) + g.ROW
        raw += g.FIELD.join(["T2", "tab2", "w1", "zsh", "zsh", "/", "false"]) + g.ROW
        with patch.object(g, "osascript", return_value=raw):
            first, second = g.terminals()
        self.assertEqual((first.id, first.frontmost, first.title_override), ("T1", True, "PR 12 gate"))
        self.assertEqual((second.frontmost, second.title_override), (False, ""))


class TtyProbeTests(unittest.TestCase):
    def setUp(self):
        self.titles = {"/dev/ttys001": "claude", "/dev/ttys002": "codex"}
        self.ids = {"/dev/ttys001": "T1", "/dev/ttys002": "T2"}
        self.writes = []
        patch.object(g.time, "sleep").start()
        self.addCleanup(patch.stopall)

    def listing(self):
        return [term(self.ids[tty], title) for tty, title in self.titles.items()]

    def test_title_overwritten_before_the_read_is_probed_again(self):
        def write(tty, title):
            self.writes.append((tty, title))
            # the program on ttys002 retitles itself right after the first probe only
            overwritten = tty == "/dev/ttys002" and sum(t == tty for t, _ in self.writes) == 1
            self.titles[tty] = "Reply READY" if overwritten else title
            return True

        with patch.object(g, "_write_title", side_effect=write), patch.object(g, "terminals", side_effect=self.listing):
            found = g.terminals_for_ttys(["/dev/ttys001", "/dev/ttys002"])
        self.assertEqual(found, {"/dev/ttys001": "T1", "/dev/ttys002": "T2"})
        self.assertEqual(self.writes[-2:], [("/dev/ttys001", "claude"), ("/dev/ttys002", "Reply READY")])

    def test_cleanup_preserves_a_new_agent_title(self):
        calls = 0
        def listing():
            nonlocal calls
            calls += 1
            if calls == 3:
                self.titles["/dev/ttys001"] = "New live title"
            return self.listing()
        def write(tty, title):
            self.writes.append((tty, title))
            self.titles[tty] = title
            return True
        with patch.object(g, "_write_title", side_effect=write), patch.object(g, "terminals", side_effect=listing):
            self.assertEqual(g.terminals_for_ttys(["/dev/ttys001"]), {"/dev/ttys001": "T1"})
        self.assertEqual(self.titles["/dev/ttys001"], "New live title")

    def test_cleanup_runs_after_lookup_error(self):
        calls = 0
        def listing():
            nonlocal calls
            calls += 1
            if calls == 2:
                raise g.GhosttyError("temporary failure")
            return self.listing()
        def write(tty, title):
            self.titles[tty] = title
            return True
        with patch.object(g, "_write_title", side_effect=write), patch.object(g, "terminals", side_effect=listing):
            with self.assertRaises(g.GhosttyError):
                g.terminals_for_ttys(["/dev/ttys001"])
        self.assertEqual(self.titles["/dev/ttys001"], "claude")

    def test_unwritable_tty_is_skipped_and_never_matched(self):
        def write(tty, title):
            if tty == "/dev/ttys002":
                return False
            self.titles[tty] = title
            return True

        with patch.object(g, "_write_title", side_effect=write), patch.object(g, "terminals", side_effect=self.listing):
            self.assertEqual(g.terminals_for_ttys(["/dev/ttys001", "/dev/ttys002"]), {"/dev/ttys001": "T1"})

    def test_a_tty_no_terminal_shows_gives_up_after_the_rounds(self):
        with patch.object(g, "_write_title", return_value=True) as write, \
                patch.object(g, "terminals", side_effect=self.listing):
            self.assertEqual(g.terminals_for_ttys(["/dev/ttys009"]), {})
        self.assertEqual(write.call_count, g.PROBE_ROUNDS)


if __name__ == "__main__":
    unittest.main()
