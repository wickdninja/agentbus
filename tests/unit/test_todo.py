"""The todo kind: what closes one, the query that lists the open ones, the kind wiring, and the hook's bounded count. The
100,000-message fixture runs every query under the hook's SQL budget (an interrupt, as in production), never against a
printed time. Every test's docstring names the bug it catches."""
import sqlite3
import time
import unittest

from load_agentbus import ab, patched

HOOK_SQL_BUDGET_S = 0.5  # open_bus(hold=HOOK_HOLD_S): hold 1.0 less the grace, the query budget a hook has


def connect():
    con = sqlite3.connect(":memory:")
    con.row_factory = sqlite3.Row
    con.executescript(ab.SCHEMA)
    return con


def budgeted(con, seconds=HOOK_SQL_BUDGET_S):
    """Stop any statement that runs past `seconds`, the way Bus._progress does (sqlite3.OperationalError: interrupted)."""
    end = time.monotonic() + seconds
    con.set_progress_handler(lambda: 1 if time.monotonic() > end else 0, 1000)


def big_bus(n=100_000):
    """n messages: notes, 6,000 questions (2,000 answered), 5,000 todos (4,000 closed, 1,000 open)."""
    con = connect()
    rows = []
    for i in range(1, n + 1):
        kind = "note"
        if i % 20 == 1:
            kind = "todo"
        elif i % 16 == 3:
            kind = "question"
        # recipients mix everyone and named agents (some on the roster, some not), so the name-dependent paths run
        to = ("*", "b", "c", "gone")[(i // 3) % 4]
        if kind == "note" and i % 10 == 5:
            kind = "handoff"  # unread handoffs to named agents: the pending-between-others path
        rows.append((i, "2026-11-01T00:00:00Z", "a" if i % 3 else "c", to, kind, "b"))
    con.executemany("INSERT INTO messages(id,ts,sender,recipient,kind,body) VALUES(?,?,?,?,?,?)", rows)
    con.executemany("INSERT INTO agents(name,joined_at,last_seen) VALUES(?,?,?)", [(x, "2026-11-01T00:00:00Z", "2026-11-01T00:00:00Z") for x in "abc"])
    con.execute("INSERT INTO cursors(agent,last_read_id) VALUES('b', 10)")
    # 4,000 claims on the roster's names: half expired, half live
    con.executemany("INSERT INTO claims(resource,agent,purpose,claimed_at,expires_at) VALUES(?,?,?,?,?)",
                    [("res/%d" % k, "abc"[k % 3], "work %d" % k, "2026-11-01T00:00:00Z",
                      "2000-01-01T00:00:00Z" if k % 2 else "2999-01-01T00:00:00Z") for k in range(4000)])
    todos = [r[0] for r in rows if r[4] == "todo"]
    questions = [r[0] for r in rows if r[4] == "question"]
    notes = [r[0] for r in rows if r[4] == "note"]
    closers = [("done" if k % 2 else "dropped", t) for k, t in enumerate(todos[: int(len(todos) * 0.8)])]
    answers = [("answer", q) for q in questions[: len(questions) // 3]]
    # the closing rows are the last notes: a closer sits after what it closes, as on a real bus
    con.executemany("UPDATE messages SET kind=?, reply_to=? WHERE id=?",
                    [(kind, target, notes[-1 - i]) for i, (kind, target) in enumerate(closers + answers)])
    con.commit()
    return con


class Closure(unittest.TestCase):
    def test_only_done_and_dropped_close_a_todo(self):
        """Bug: the closing kinds grow (a note, an answer) and a refusal or a side question hides unfinished work."""
        self.assertEqual(ab.TODO_CLOSERS, ("done", "dropped"))

    def test_open_todos_are_those_with_no_direct_closer(self):
        """Bug: a reply of another kind, a reply to a reply, or a done with no reply_to closes the todo."""
        con = connect()
        add = lambda kind, reply=None: con.execute("INSERT INTO messages(ts,sender,recipient,kind,body,reply_to) VALUES('t','a','*',?,'b',?)",
                                                    (kind, reply)).lastrowid
        t1, t2, t3, t4 = add("todo"), add("todo"), add("todo"), add("todo")
        add("done", t1)                         # closes t1
        add("dropped", t2)                      # closes t2
        note = add("note", t3)
        add("done", note)                       # a done below a note below t3: ancestry, closes nothing
        add("done")                             # no reply_to: closes nothing
        add("answer", t4)                       # another kind: closes nothing
        got = [r[0] for r in con.execute(f"SELECT m.id FROM messages m WHERE {ab.open_todo_where('m.')} ORDER BY m.id")]
        self.assertEqual(got, [t3, t4])

    def test_a_question_is_closed_only_by_a_direct_answer(self):
        """Bug (#63): an answer to a clarifying question closes the question above it."""
        con = connect()
        add = lambda kind, reply=None: con.execute("INSERT INTO messages(ts,sender,recipient,kind,body,reply_to) VALUES('t','a','b',?,'b',?)",
                                                    (kind, reply)).lastrowid
        q1 = add("question")
        q2 = add("question", q1)
        add("answer", q2)
        self.assertEqual([r["id"] for r in ab._brief_open_questions(con, "b", 10)[0]], [q1])


class Budget(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.con = big_bus()

    def test_no_query_scans_the_table_once_per_row(self):
        """Bug: a correlated NOT EXISTS on reply_to (no index) re-scans 100,000 rows for each of 5,000 todos; the plan must
        have no correlated subquery, so the cost does not multiply by the number of todos or questions."""
        for name, sql in (("todos", f"SELECT m.id FROM messages m WHERE {ab.open_todo_where('m.')}"),
                          ("questions", f"SELECT q.id FROM messages q WHERE {ab.open_question_where('q.')}")):
            plan = " | ".join(str(r[3]) for r in self.con.execute("EXPLAIN QUERY PLAN " + sql))
            self.assertNotIn("CORRELATED", plan, name + ": " + plan)

    def test_every_query_finishes_inside_the_hook_sql_budget(self):
        """Bug: the old open-question walk was interrupted at 0.501 s on this size, so a hook that used it lost its whole
        message. Each query path runs under the 0.5 s budget as an interrupt, on a bus with named recipients, a roster,
        unread handoffs and 4,000 claims (2,000 expired); one that is too slow raises here."""
        con = self.con
        budgeted(con)
        try:
            self.assertEqual(ab.hook_open_todos(con), 1000)
            items, more = ab._brief_open_todos(con, 5)
            self.assertEqual((len(items), more), (5, 995))
            q, qmore = ab._brief_open_questions(con, "b", 5)
            self.assertEqual(len(q), 5)
            others, omore = ab._brief_pending_others(con, "zed", 5)
            self.assertEqual((len(others), omore > 0), (5, True), "the pending path did not run on named recipients")
            expired, emore = ab._brief_expired_claims(con, 5)
            self.assertEqual((len(expired), emore), (5, 1995), "the expired-claims path did not run on real claim rows")
        finally:
            con.set_progress_handler(None, 0)

    def test_the_hook_count_agrees_with_the_list(self):
        """Bug: the hook's count and brief's list use two rules, and SessionStart says 3 while brief shows 5."""
        total = ab._brief_open_todos(self.con, -1)[0]
        self.assertEqual(len(total), ab.hook_open_todos(self.con))


class HookCount(unittest.TestCase):
    def test_over_budget_is_none_not_an_exception(self):
        """Bug: an interrupted count raises, the hook dies silently, and SessionStart's whole message (name, unread, goal)
        is lost. Over budget the count is None and the line says run brief."""
        con = big_bus(5000)
        con.set_progress_handler(lambda: 1, 1)
        try:
            try:
                count = ab.hook_open_todos(con)
            except sqlite3.Error as e:
                self.fail("hook_open_todos raised %r when over budget" % (e,))
            self.assertIsNone(count)
        finally:
            con.set_progress_handler(None, 0)

    def test_the_line_names_the_count_or_says_run_brief(self):
        """Bug: nothing open prints a clause on every session; an unknown count prints 0."""
        self.assertEqual(ab.hook_todo_text(0), "")
        self.assertEqual(ab.hook_todo_text(1), ", 1 open todo")
        self.assertEqual(ab.hook_todo_text(12), ", 12 open todos")
        self.assertEqual(ab.hook_todo_text(None), ", open todos: run brief")


class KindWiring(unittest.TestCase):
    def test_every_kind_is_wired_everywhere(self):
        """Bug: a new kind missing from one table raises KeyError in a watch frame, a help page or a hook count."""
        for table in ("KIND_MEANINGS", "KIND_CODE", "KIND_EMOJI", "HOOK_KIND_PLURAL"):
            missing = [k for k in ab.KINDS if k not in getattr(ab, table)]
            self.assertEqual(missing, [], table)
        self.assertIn("todo", ab.KINDS)
        self.assertIn("dropped", ab.KINDS)

    def test_kind_codes_and_emoji_are_distinct(self):
        """Bug: two kinds share a short code, and kind:CODE in watch matches both."""
        codes = [ab.KIND_CODE[k] for k in ab.KINDS]
        self.assertEqual(len(set(codes)), len(codes))
        emoji = [ab.KIND_EMOJI[k] for k in ab.KINDS]
        self.assertEqual(len(set(emoji)), len(emoji))

    def test_a_hook_count_of_every_kind_prints(self):
        """Bug: hook_kind_parts raises KeyError for a kind outside its plural table (the unread note vanishes)."""
        counts = {k: 2 for k in ab.KINDS}
        text = ab.hook_kind_parts(counts)
        self.assertIn("2 todos", text)


if __name__ == "__main__":
    unittest.main()
