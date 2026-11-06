"""The process state an exit reads: committed, retryable, the ack failure and the hook exits. Today these are module
globals; a later holder object keeps these tests as they are, so every state is set through `patched` and every
check goes through the public surface (Diag, immediate, exit_now, hook_run). Every test's docstring names the bug
it catches."""
import contextlib
import io
import json
import os
import sqlite3
import sys
import threading
import unittest
from unittest import mock

from load_agentbus import ab, patched


class Stop(Exception):
    """Stands in for os._exit in a test, carrying the status it was called with."""

    def __init__(self, status):
        super().__init__(status)
        self.status = status


def no_exit(status):
    raise Stop(status)


@contextlib.contextmanager
def state(wrote=False, rows=False, token=False, json_errors=False):
    """The four flags an error reads, set for one block and put back after it."""
    with contextlib.ExitStack() as stack:
        for name, value in (("_WROTE", wrote), ("_WROTE_ROWS", rows), ("_HAS_TOKEN", token), ("_JSON_ERRORS", json_errors),
                            ("_IN_COMMIT", None), ("_CHANGED", [])):
            stack.enter_context(patched(name, value))
        yield


def error_json(code, **fields):
    with patched("_JSON_ERRORS", True):
        return json.loads(str(ab.Diag("msg", code, **fields)))["error"]


def human(code, msg="it broke", **fields):
    """The human text of an error, on one line (the wrap can break it anywhere between words)."""
    return " ".join(str(ab.Diag(msg, code, **fields)).split())


class Retryable(unittest.TestCase):
    def test_a_retryable_code_stays_retryable_when_nothing_was_saved(self):
        """Bug: retryable is false for every code, and a caller never repeats a busy command."""
        with state():
            self.assertIs(ab.Diag("x", "busy").retryable, True)

    def test_rows_saved_make_a_repeat_unsafe(self):
        """Bug: a command that saved rows still says retryable true, and a repeated write duplicates itself."""
        with state(wrote=True, rows=True):
            self.assertIs(ab.Diag("x", "busy").retryable, False)

    def test_a_stored_request_id_makes_a_repeat_safe_again(self):
        """Bug: post and join with --request-id are told not to repeat, though the bus replays the first result."""
        with state(wrote=True, rows=True, token=True):
            self.assertIs(ab.Diag("x", "busy").retryable, True)

    def test_files_changed_alone_stay_retryable(self):
        """Bug: init or setup, which only changed files, count as saved rows and refuse a plain rerun."""
        with state(wrote=True, rows=False):
            self.assertIs(ab.Diag("x", "interrupted").retryable, True)

    def test_a_token_never_makes_a_non_retryable_code_retryable(self):
        """Bug: the token rule is `or` over the whole value, and claim_conflict becomes retryable."""
        with state(token=True):
            self.assertIs(ab.Diag("x", "claim_conflict").retryable, False)

    def test_an_unknown_code_is_the_internal_error(self):
        """Bug: a mistyped code raises KeyError inside the error path and hides the real failure."""
        with state():
            d = ab.Diag("x", "no_such_code")
            self.assertIs(d.retryable, False)
            self.assertEqual(d.status, ab.CONTRACT["errors"]["internal"]["exit"])

    def test_json_reports_the_same_value(self):
        """Bug: the JSON error computes retryable on its own and disagrees with Diag.retryable."""
        with state(wrote=True, rows=True):
            self.assertIs(error_json("busy")["retryable"], False)
        with state():
            self.assertIs(error_json("busy")["retryable"], True)


class Committed(unittest.TestCase):
    def test_json_committed_follows_the_flag(self):
        """Bug: committed is a constant, and a caller cannot tell a saved write from one that never ran."""
        with state():
            self.assertIs(error_json("bad_input")["committed"], False)
        with state(wrote=True):
            self.assertIs(error_json("bad_input")["committed"], True)

    def test_file_changed_marks_committed_but_not_rows(self):
        """Bug: a file change sets the rows flag too, and init becomes non-retryable; or it sets neither and
        an interrupted init says committed false."""
        with state():
            ab.file_changed("/x/VERSION")
            self.assertIs(ab._WROTE, True)
            self.assertIs(ab._WROTE_ROWS, False)
            self.assertEqual(ab._CHANGED, ["/x/VERSION"])
            self.assertIs(error_json("interrupted")["committed"], True)
            self.assertIs(error_json("interrupted")["retryable"], True)

    def test_human_text_says_the_change_was_saved(self):
        """Bug: a human reader of a failed write is never told it had already been saved."""
        with state(wrote=True):
            self.assertIn("The command's change was saved before this.", human("bus_unavailable"))
        with state():
            self.assertNotIn("saved before this", human("bus_unavailable"))

    def test_the_saved_sentence_does_not_double_the_full_stop(self):
        """Bug: the sentence is glued on, and a message that ends in a full stop reads `..`."""
        with state(wrote=True):
            text = human("bus_unavailable", msg="the disk is full.")
            self.assertIn("the disk is full. The command's change", text)
            self.assertNotIn("..", text)

    def test_output_and_ack_failures_never_say_the_change_was_lost_or_saved(self):
        """Bug: stdout failing after a good write is reported as `saved before this`, which reads as the cause."""
        for code in ("output_failed", "ack_failed"):
            with state(wrote=True):
                self.assertNotIn("saved before this", human(code))

    def test_an_unknown_outcome_is_not_called_saved(self):
        """Bug: the watchdog's `may be saved` stop is worded as a sure save."""
        with state(wrote=True):
            self.assertNotIn("saved before this", human("bus_unavailable", outcome_unknown=True))


def memory_bus():
    con = sqlite3.connect(":memory:", isolation_level=None)
    con.execute("CREATE TABLE t(x)")
    return con


class Commit(unittest.TestCase):
    def test_a_recorded_write_marks_rows_and_files_committed(self):
        """Bug: a command's own commit is not noted, so the failure after it says committed false."""
        with state():
            con = memory_bus()
            with ab.immediate(con):
                con.execute("INSERT INTO t VALUES(1)")
            self.assertIs(ab._WROTE, True)
            self.assertIs(ab._WROTE_ROWS, True)
            self.assertIsNone(ab._IN_COMMIT)

    def test_a_write_that_changed_nothing_is_not_committed(self):
        """Bug: any BEGIN IMMEDIATE counts as a write, and a read-only command says committed true."""
        with state():
            with ab.immediate(memory_bus()):
                pass
            self.assertIs(ab._WROTE, False)
            self.assertIs(ab._WROTE_ROWS, False)

    def test_an_unrecorded_write_is_not_the_commands_own(self):
        """Bug: the last-seen refresh or an open's setup counts as the command's change (record=False)."""
        with state():
            con = memory_bus()
            with ab.immediate(con, record=False):
                con.execute("INSERT INTO t VALUES(1)")
            self.assertEqual(con.execute("SELECT COUNT(*) FROM t").fetchone()[0], 1)
            self.assertIs(ab._WROTE, False)
            self.assertIs(ab._WROTE_ROWS, False)

    def test_a_failed_write_rolls_back_and_is_not_committed(self):
        """Bug: the flag is set before the COMMIT, and a rolled-back write is reported as saved."""
        with state():
            con = memory_bus()
            with self.assertRaises(ValueError):
                with ab.immediate(con):
                    con.execute("INSERT INTO t VALUES(1)")
                    raise ValueError("boom")
            self.assertEqual(con.execute("SELECT COUNT(*) FROM t").fetchone()[0], 0)
            self.assertIs(ab._WROTE, False)
            self.assertIs(ab._WROTE_ROWS, False)

    def test_the_commit_window_is_visible_to_the_watchdog(self):
        """Bug: _IN_COMMIT is never set, and a stop during the commit cannot say its outcome is unknown. Own
        writes read "own", any other "setup", and a commit with no pending rows leaves it None."""
        seen = []
        with state(), patched("_test_stall_commit", lambda: seen.append(ab._IN_COMMIT)):
            for record, pending in ((True, True), (False, True), (True, False)):
                con = memory_bus()
                con.execute("BEGIN IMMEDIATE")
                ab._commit(con, pending, record)
            self.assertEqual(seen, ["own", "setup"])  # no pending rows: no stall point, no window
            self.assertIsNone(ab._IN_COMMIT)

    def test_a_commit_that_raises_closes_the_window(self):
        """Bug: _IN_COMMIT stays set after a failed COMMIT, and every later stop claims an unknown outcome."""
        def stall():
            raise RuntimeError("stalled")
        with state(), patched("_test_stall_commit", stall):
            con = memory_bus()
            con.execute("BEGIN IMMEDIATE")
            with self.assertRaises(RuntimeError):
                ab._commit(con, True, True)
            self.assertIsNone(ab._IN_COMMIT)
            self.assertIs(ab._WROTE, False)


class Ack(unittest.TestCase):
    def test_ack_failed_is_a_bus_error_that_can_be_repeated(self):
        """Bug: the ack failure exits 1, or is not retryable, and an agent drops messages it was never told it
        could read again."""
        c = ab.CONTRACT["errors"]["ack_failed"]
        self.assertEqual((c["exit"], c["retryable"]), (3, True))
        with state():
            e = error_json("ack_failed", delivered=True)
            self.assertIs(e["retryable"], True)
            self.assertIs(e["delivered"], True)
            self.assertIs(e["committed"], False)

    def test_the_ack_test_hook_fails_only_at_its_own_point(self):
        """Bug: AGENTBUS_TEST_FAIL=ack also fires at another point, or never fires, and the failure-phase tests
        pass without exercising the mark-read step."""
        with mock.patch.dict(os.environ, {"AGENTBUS_TEST_FAIL": "ack"}):
            with self.assertRaises(sqlite3.OperationalError):
                ab._test_fail("ack")
            ab._test_fail("open")
            ab._test_fail("emit")
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("AGENTBUS_TEST_FAIL", None)
            ab._test_fail("ack")

    def test_reason_reads_a_diag_and_a_plain_exit(self):
        """Bug: the notice built from a failed ack prints the repr of a Diag instead of its message."""
        self.assertEqual(ab.reason(SystemExit(ab.Diag("bus moved", "bus_unavailable"))), "bus moved")
        self.assertEqual(ab.reason(SystemExit("plain")), "plain")

    def test_die_raises_the_diag_with_its_fields(self):
        """Bug: die() loses delivered=True, and the JSON error cannot tell the reader the messages arrived."""
        with self.assertRaises(SystemExit) as caught:
            ab.die("could not mark read", "ack_failed", delivered=True)
        d = caught.exception.code
        self.assertEqual((d.code, d.status, d.fields), ("ack_failed", 3, {"delivered": True}))


class ExitNow(unittest.TestCase):
    def run_exit(self, writer, grace=None):
        with patched("_write_fd", writer), mock.patch.object(ab.os, "_exit", no_exit):
            with self.assertRaises(Stop) as caught:
                ab.exit_now("the bus is gone", "bus_unavailable", grace=grace)
        return caught.exception.status

    def test_the_status_is_the_codes_and_the_message_is_written(self):
        """Bug: the watchdog exits 0 or 1 for every code, or exits without writing why."""
        written = []
        with state():
            status = self.run_exit(lambda fd, data: written.append((fd, data)))
        self.assertEqual(status, ab.CONTRACT["errors"]["bus_unavailable"]["exit"])
        self.assertEqual(written[0][0], 2)
        self.assertIn(b"the bus is gone", written[0][1])

    def test_a_blocked_stderr_cannot_hold_the_exit(self):
        """Bug: the write is joined with no limit, and a full pipe nobody reads keeps the lock holder alive."""
        release = threading.Event()
        self.addCleanup(release.set)
        with state():
            status = self.run_exit(lambda fd, data: release.wait(30), grace=0.05)
        self.assertEqual(status, 3)

    def test_fields_reach_the_json_error(self):
        """Bug: outcome_unknown, set by the watchdog, is dropped on the way to the exit message."""
        written = []
        with state(json_errors=True):
            with patched("_write_fd", lambda fd, data: written.append(data)), mock.patch.object(ab.os, "_exit", no_exit):
                with self.assertRaises(Stop):
                    ab.exit_now("stopped", "bus_unavailable", outcome_unknown=True)
        self.assertIs(json.loads(written[0])["error"]["outcome_unknown"], True)


class HookExit(unittest.TestCase):
    def test_hook_exit_is_always_success_and_silent(self):
        """Bug: a hook's watchdog exits with the bus's failing status, and the harness shows a hook error."""
        wrote = []
        with mock.patch.object(ab.os, "_exit", no_exit), mock.patch.object(sys, "stderr", io.StringIO()) as err:
            for code in ("busy", "bus_unavailable", "internal"):
                with self.assertRaises(Stop) as caught:
                    ab.hook_exit_now("anything", code)
                wrote.append(caught.exception.status)
            self.assertEqual(err.getvalue(), "")
        self.assertEqual(wrote, [0, 0, 0])

    def payload(self, **extra):
        data = json.dumps({"session_id": "s1", **extra}).encode()
        stdin = io.TextIOWrapper(io.BytesIO(data))
        return mock.patch.object(sys, "stdin", stdin)

    def run_hook(self, argv, handlers, stdin=None):
        """hook_run with fake handlers; returns (stdout text, the exit_now the handler saw)."""
        seen = []
        wrapped = {event: (lambda payload, h=h: (seen.append(ab.exit_now), h(payload))[1]) for event, h in handlers.items()}
        out = io.StringIO()
        old_state = dict(ab.HOOK_STATE)
        self.addCleanup(lambda: (ab.HOOK_STATE.clear(), ab.HOOK_STATE.update(old_state)))
        with patched("exit_now", ab.exit_now), patched("_HOOK_GUARD", None), patched("HOOK_HANDLERS", wrapped):
            try:
                with (stdin or self.payload()), contextlib.redirect_stdout(out):
                    ab.hook_run(argv)
            finally:
                if ab._HOOK_GUARD is not None:
                    ab._HOOK_GUARD.cancel()  # the whole-hook timer would os._exit this process
        return out.getvalue(), seen

    def test_a_running_hook_swaps_in_the_silent_exit(self):
        """Bug: a hook keeps exit_now, and the hold watchdog ends it with status 3 inside the user's session."""
        out, seen = self.run_hook(["claude", "Stop"], {"Stop": lambda payload: None})
        self.assertEqual(seen, [ab.hook_exit_now])

    def test_the_swap_is_not_made_for_a_hook_that_never_runs(self):
        """Bug: an unknown dialect or event swaps exit_now before it returns, so the next normal command in the
        same process exits 0 on a failure."""
        called = []
        for argv in (["nope", "Stop"], ["claude", "Nope"], ["codex", "SessionEnd"], []):
            out, seen = self.run_hook(argv, {"Stop": lambda p: called.append(1)})
            self.assertEqual((out, seen), ("", []))
        self.assertEqual(called, [])

    def test_a_missing_payload_prints_nothing_and_runs_no_handler(self):
        """Bug: a hook run with no JSON on stdin calls its handler on None and prints a traceback."""
        empty = mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(b"not json")))
        out, seen = self.run_hook(["claude", "Stop"], {"Stop": lambda payload: ("late", None)}, stdin=empty)
        self.assertEqual((out, seen), ("", []))

    def test_context_and_notice_become_one_json_line(self):
        """Bug: the handler's answer is printed with a space or on two lines, and the harness cannot parse it."""
        out, _ = self.run_hook(["claude", "SessionStart"], {"SessionStart": lambda payload: ("ctx", "hello")})
        self.assertEqual(out.count("\n"), 1)
        self.assertEqual(json.loads(out), {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "ctx"},
                                           "systemMessage": "hello"})
        self.assertNotIn(" ", out.strip().replace("ctx", "").replace("hello", ""))

    def test_a_notice_is_shown_once_per_session(self):
        """Bug: a HookNotice is printed on every prompt, or never, because hook_notice_once is not consulted."""
        def raises(payload):
            raise ab.HookNotice("no_bus", ("/b", 1, 2))
        for first, shown in ((True, True), (False, False)):
            with patched("hook_notice_once", lambda sid, bus, code, first=first: first), \
                    patched("HOOK_NOTICES", {"no_bus": "no bus here"}):
                out, _ = self.run_hook(["claude", "UserPromptSubmit"], {"UserPromptSubmit": raises})
            self.assertEqual(bool(out), shown)
            if shown:
                self.assertEqual(json.loads(out), {"systemMessage": "no bus here"})

    def test_the_early_command_always_exits_zero(self):
        """Bug: an exception in a hook, or a closed stdout, becomes a failing status in the user's session."""
        def boom(argv):
            raise RuntimeError("handler bug")
        for hook in (boom, lambda argv: None):
            with patched("hook_run", hook), mock.patch.object(ab.os, "_exit", no_exit), \
                    mock.patch.dict(os.environ, {"AGENTBUS_HOOKS": "on"}), mock.patch.object(sys, "stderr", io.StringIO()) as err:
                with self.assertRaises(Stop) as caught:
                    ab.cmd_hook_early(["claude", "Stop"])
                self.assertEqual(caught.exception.status, 0)
                self.assertEqual(err.getvalue(), "")  # no traceback unless AGENTBUS_HOOK_DEBUG=1

    def test_the_off_switch_skips_the_hook(self):
        """Bug: AGENTBUS_HOOKS=off still runs the handler."""
        ran = []
        with patched("hook_run", ran.append), mock.patch.object(ab.os, "_exit", no_exit), \
                mock.patch.dict(os.environ, {"AGENTBUS_HOOKS": "off"}):
            with self.assertRaises(Stop):
                ab.cmd_hook_early(["claude", "Stop"])
        self.assertEqual(ran, [])


if __name__ == "__main__":
    unittest.main()
