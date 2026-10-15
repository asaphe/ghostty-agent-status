import sys
import tempfile
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

    def test_one_bulk_query_lists_terminals(self):
        raw = g.FIELD.join(["T1", "tab1", "w1", "zsh", "zsh", "/", "false"]) + g.ROW
        with patch.object(g, "osascript", return_value=raw) as call:
            self.assertEqual([t.id for t in g.terminals()], ["T1"])
        self.assertEqual([c.args[0] for c in call.call_args_list], [g.BULK_LIST_SCRIPT])

    def test_a_layout_change_during_the_bulk_query_retries_it(self):
        raw = g.FIELD.join(["T1", "tab1", "w1", "zsh", "zsh", "/", "false"]) + g.ROW
        with patch.object(g, "osascript", side_effect=[g.LAYOUT_CHANGED, raw]) as call:
            self.assertEqual([t.id for t in g.terminals()], ["T1"])
        self.assertEqual([c.args[0] for c in call.call_args_list], [g.BULK_LIST_SCRIPT, g.BULK_LIST_SCRIPT])

    def test_a_layout_that_keeps_changing_falls_back_to_the_per_terminal_listing(self):
        raw = g.FIELD.join(["T1", "tab1", "w1", "zsh", "zsh", "/", "false"]) + g.ROW
        with patch.object(g, "osascript", side_effect=[g.LAYOUT_CHANGED] * g.LAYOUT_ATTEMPTS + [raw]) as call:
            self.assertEqual([t.id for t in g.terminals()], ["T1"])
        self.assertEqual([c.args[0] for c in call.call_args_list],
                         [g.BULK_LIST_SCRIPT] * g.LAYOUT_ATTEMPTS + [g.LIST_SCRIPT])

    def test_a_failed_bulk_query_falls_back_but_a_timed_out_one_does_not(self):
        raw = g.FIELD.join(["T1", "tab1", "w1", "zsh", "zsh", "/", "false"]) + g.ROW
        with patch.object(g, "osascript", side_effect=[g.GhosttyError("bulk failed"), raw]) as call:
            self.assertEqual([t.id for t in g.terminals()], ["T1"])
        self.assertEqual([c.args[0] for c in call.call_args_list], [g.BULK_LIST_SCRIPT, g.LIST_SCRIPT])
        with patch.object(g, "osascript", side_effect=[g.GhosttyTimeout("timed out"), raw]) as call:
            with self.assertRaises(g.GhosttyTimeout):
                g.terminals()
        self.assertEqual(call.call_count, 1)


class TtyProbeTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        original_open = g.os.open
        patch.object(g.os, "open", side_effect=lambda path, flags, mode=0o777:
                     original_open(str(Path(scratch.name) / "probe.lock") if str(path).startswith("/tmp/ghostty-title-probe-")
                                   else path, flags, mode)).start()
        self.titles = {"/dev/ttys001": "claude", "/dev/ttys002": "codex"}
        self.ids = {"/dev/ttys001": "T1", "/dev/ttys002": "T2"}
        self.writes = []
        patch.object(g.time, "sleep").start()
        self.addCleanup(patch.stopall)

    def listing(self):
        return [term(self.ids[tty], title) for tty, title in self.titles.items()]

    def test_probe_lock_timeout_is_traced_before_any_title_write(self):
        with patch.object(g.fcntl, "flock", side_effect=BlockingIOError), \
                patch.object(g.time, "monotonic", side_effect=[0, 46, 46]), \
                patch.object(g.diagnostics, "emit") as emit, patch.object(g, "_probe_ttys") as probe:
            with self.assertRaises(g.GhosttyError):
                g.terminals_for_ttys(["/dev/ttys001"])
        probe.assert_not_called()
        self.assertEqual([c.args[0] for c in emit.call_args_list], ["probe.lock_wait", "probe.lock_timeout"])
        self.assertEqual(emit.call_args_list[-1].kwargs["elapsed_ms"], 46000)

    def test_probe_lock_acquisition_is_traced_without_changing_result(self):
        with patch.object(g.diagnostics, "emit") as emit, patch.object(g, "_probe_ttys", return_value={"tty": "T1"}):
            self.assertEqual(g.terminals_for_ttys(["tty"]), {"tty": "T1"})
        self.assertEqual([c.args[0] for c in emit.call_args_list], ["probe.lock_wait", "probe.lock_acquired"])

    def test_a_terminal_resolved_while_waiting_for_the_lock_skips_the_probe(self):
        with patch.object(g, "_probe_ttys") as probe:
            self.assertEqual(g.terminals_for_ttys(["/dev/ttys001"], cached=lambda: "T1"), {"/dev/ttys001": "T1"})
        probe.assert_not_called()

    def test_a_probe_that_just_missed_while_waiting_is_not_repeated(self):
        with patch.object(g, "_probe_ttys") as probe:
            self.assertEqual(g.terminals_for_ttys(["/dev/ttys001"], cached=lambda: ""), {})
        probe.assert_not_called()

    def test_an_unresolved_cache_still_probes(self):
        with patch.object(g, "_probe_ttys", return_value={"/dev/ttys001": "T1"}) as probe:
            self.assertEqual(g.terminals_for_ttys(["/dev/ttys001"], cached=lambda: None), {"/dev/ttys001": "T1"})
        probe.assert_called_once_with(["/dev/ttys001"])

    def test_a_multi_tty_probe_ignores_the_cache(self):
        with patch.object(g, "_probe_ttys", return_value={}) as probe:
            g.terminals_for_ttys(["/dev/ttys001", "/dev/ttys002"], cached=lambda: "T1")
        probe.assert_called_once()

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
