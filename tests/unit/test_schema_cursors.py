"""Table shapes and paging cursors: the comparison that catches a rebuilt table, and the opaque cursors the id walks
hand out. A cursor comes back from a caller, so it is parsed as hostile. Every test's docstring names the bug it
catches."""
import os
import sqlite3
import unittest
from types import SimpleNamespace
from unittest import mock

from load_agentbus import ab, diag


def args(cmd="read", action=None, topic=None, key=None, as_=None, up=0):
    return SimpleNamespace(cmd=cmd, action=action, topic=topic, key=key, as_=as_, up=up)


class SqlTokens(unittest.TestCase):
    def test_spacing_case_and_comments_do_not_matter(self):
        """Bug: a reformatted but identical table definition is reported as a different table."""
        a = ab.sql_tokens("CREATE TABLE t(a INTEGER PRIMARY KEY,  b TEXT) -- note\n")
        b = ab.sql_tokens("create table T ( A integer primary key , B text )/* c */")
        self.assertEqual(a, b)
        self.assertEqual(a[:3], ("create", "table", "t"))

    def test_quoting_of_an_identifier_does_not_matter(self):
        """Bug: "a", `a`, [a] and a are four different columns."""
        forms = ('CREATE TABLE t("a" TEXT)', "CREATE TABLE t(`a` TEXT)", "CREATE TABLE t([a] TEXT)", "CREATE TABLE t(a TEXT)")
        self.assertEqual(len({ab.sql_tokens(s) for s in forms}), 1)

    def test_a_doubled_quote_is_one_quote(self):
        """Bug: an escaped quote inside an identifier splits the token and shifts every later position."""
        self.assertIn('a"b', ab.sql_tokens('CREATE TABLE t("a""b" TEXT)'))

    def test_string_literals_keep_their_case(self):
        """Bug: a default of 'Open' and one of 'open' compare equal, hiding a changed default."""
        self.assertNotEqual(ab.sql_tokens("x DEFAULT 'Open'"), ab.sql_tokens("x DEFAULT 'open'"))
        self.assertIn("'Open'", ab.sql_tokens("x DEFAULT 'Open'"))

    def test_clauses_the_pragmas_miss_are_visible(self):
        """Bug: CHECK, COLLATE and ON CONFLICT vanish from the tokens, so a lane's rebuilt table passes."""
        base = ab.sql_tokens("CREATE TABLE t(a TEXT UNIQUE)")
        for sql in ("CREATE TABLE t(a TEXT UNIQUE ON CONFLICT REPLACE)", "CREATE TABLE t(a TEXT UNIQUE CHECK(a<>''))",
                    "CREATE TABLE t(a TEXT COLLATE NOCASE UNIQUE)", "CREATE TABLE t(a TEXT UNIQUE) WITHOUT ROWID"):
            self.assertNotEqual(ab.sql_tokens(sql), base, sql)

    def test_an_unterminated_comment_or_string_does_not_raise_or_hang(self):
        """Bug: planted text in sqlite_master with an open comment crashes the schema check."""
        for sql in ("a /* never closed", "a 'never closed", 'a "never closed', "a [never closed", None, "", 5):
            self.assertIsInstance(ab.sql_tokens(sql), tuple)

    def test_a_comment_cannot_hide_a_clause(self):
        """Bug: a `--` comment eats the rest of the statement, instead of the rest of its line."""
        self.assertIn("check", ab.sql_tokens("a TEXT -- x\nCHECK(a)"))


def shape(sql, indexes=()):
    con = sqlite3.connect(":memory:")
    con.execute(sql)
    for i in indexes:
        con.execute(i)
    return ab.table_shape(con, "t")


class ShapeDifference(unittest.TestCase):
    BASE = "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER DEFAULT 0)"

    def diff(self, other, base=None, have_idx=(), want_idx=()):
        return ab.shape_difference(shape(other, have_idx), shape(base or self.BASE, want_idx))

    def test_equal_shapes_have_no_difference(self):
        """Bug: the same table, spaced differently, is reported as changed and every bus is refused."""
        self.assertIsNone(self.diff("create table t (id integer primary key,name text not null,\n n integer default 0)"))

    def test_a_missing_column(self):
        """Bug: a dropped column is described as a type change, or not at all."""
        self.assertEqual(self.diff("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL)"), "no column n")

    def test_an_extra_column(self):
        """Bug: a column a lane added is not reported."""
        self.assertEqual(self.diff(self.BASE[:-1] + ", z TEXT)"), "extra column z")

    def test_columns_in_another_order(self):
        """Bug: reordered columns pass, and positional INSERTs write the wrong fields."""
        got = self.diff("CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER DEFAULT 0, name TEXT NOT NULL)")
        self.assertEqual(got, "columns in the order (id, n, name), not (id, name, n)")

    def test_a_changed_column_says_which_field(self):
        """Bug: a dropped NOT NULL or a changed default is reported without the column or the field."""
        self.assertEqual(self.diff("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, n INTEGER DEFAULT 0)"),
                         "column name has notnull 0, not 1")
        self.assertEqual(self.diff("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER DEFAULT 1)"),
                         "column n has default '1', not '0'")
        self.assertEqual(self.diff("CREATE TABLE t(id INTEGER PRIMARY KEY, name BLOB NOT NULL, n INTEGER DEFAULT 0)"),
                         "column name has type 'BLOB', not 'TEXT'")

    def test_an_extra_unique_constraint(self):
        """Bug: SQLite's automatic indexes are not compared, so UNIQUE on a column slips in."""
        got = self.diff("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, n INTEGER DEFAULT 0)")
        self.assertTrue(got.startswith("extra unique index"), got)

    def test_a_missing_unique_constraint(self):
        """Bug: a dropped UNIQUE is not noticed, and duplicate rows are accepted."""
        base = "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)"
        got = self.diff("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL)", base=base)
        self.assertTrue(got.startswith("no unique index"), got)

    def test_named_indexes_are_left_to_their_own_check(self):
        """Bug: a missing named index is reported here as a table difference, and twice."""
        self.assertIsNone(self.diff(self.BASE, want_idx=("CREATE INDEX i ON t(name)",)))

    def test_a_foreign_key_with_a_cascade(self):
        """Bug: `REFERENCES ... ON DELETE CASCADE` added to a table makes a leave delete messages."""
        con = sqlite3.connect(":memory:")
        con.execute("CREATE TABLE p(name TEXT PRIMARY KEY)")
        con.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, who TEXT REFERENCES p(name) ON DELETE CASCADE)")
        have = ab.table_shape(con, "t")
        con.execute("DROP TABLE t")
        con.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, who TEXT REFERENCES p(name))")
        want = ab.table_shape(con, "t")
        got = ab.shape_difference(have, want)
        self.assertIn("on delete CASCADE", got)
        self.assertIn("on delete NO ACTION", got)

    def test_a_check_clause_is_found_in_the_definition(self):
        """Bug: only pragmas are compared, and a CHECK that rejects valid rows passes."""
        got = self.diff("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER DEFAULT 0 CHECK(n>=0))")
        self.assertIn("its definition has", got)
        self.assertIn("check", got)

    def test_table_shape_of_a_missing_table_is_none(self):
        """Bug: a missing table raises, and the schema check dies on an empty bus instead of reporting it."""
        self.assertIsNone(ab.table_shape(sqlite3.connect(":memory:"), "nothing"))

    def test_a_table_name_cannot_break_out_of_the_pragma(self):
        """Bug: the name is pasted into PRAGMA text unquoted, and a table named with a quote runs other SQL."""
        con = sqlite3.connect(":memory:")
        con.execute('CREATE TABLE "a""b"(x)')
        self.assertEqual(ab.table_shape(con, 'a"b')["columns"][0][0], "x")

    def test_the_real_schema_matches_itself(self):
        """Bug: create_schema builds something its own reference shape rejects."""
        con = sqlite3.connect(":memory:")
        ab.create_schema(con)
        ref = ab.reference_shapes()
        self.assertEqual(set(ref), set(ab.TABLES))
        for t in ab.TABLES:
            self.assertIsNone(ab.shape_difference(ab.table_shape(con, t), ref[t]), t)


class Cursors(unittest.TestCase):
    def test_round_trip_for_each_walk(self):
        """Bug: a cursor made for one id walk decodes to another row, or the row id is lost."""
        for a in (args("read", topic="t"), args("inbox", as_="bob"), args("ctx", "history", key="k"), args("log", "show")):
            text = ab.make_cursor(a, 4021)
            self.assertRegex(text, r"^v1\.[rihl]\.[0-9a-f]{6}\.4021$")
            self.assertEqual(ab.read_cursor(a, text, "--before"), 4021)

    def test_the_format_is_pinned(self):
        """Bug: the format changes silently, and cursors saved by a script from the last release stop working."""
        self.assertEqual(ab.make_cursor_text({"c": "read", "f": "3fa9c1", "id": 7}), "v1.r.3fa9c1.7")
        self.assertEqual(ab.CURSOR_CODES, {"read": "r", "inbox": "i", "ctx history": "h", "log show": "l"})
        self.assertEqual(ab.read_cursor(args("read", topic=None), ab.make_cursor_text({"c": "read", "f": ab._filter_hash({"topic": None}), "id": 7}), "--before"), 7)

    def refused(self, a, text):
        d = diag(self, ab.read_cursor, a, text, "--before")
        self.assertEqual((d.code, d.status), ("bad_input", 2))
        return d

    def test_another_command_is_refused(self):
        """Bug: a read cursor is accepted by inbox and walks the wrong table."""
        text = ab.make_cursor(args("read"), 5)
        self.assertIn("another command", self.refused(args("inbox", as_="bob"), text).msg)
        self.assertIn("another command", self.refused(args("log", "show"), text).msg)

    def test_other_filters_are_refused(self):
        """Bug: a cursor for topic a pages through topic b, skipping or repeating rows."""
        text = ab.make_cursor(args("read", topic="a"), 5)
        self.assertIn("other filters", self.refused(args("read", topic="b"), text).msg)
        self.assertIn("other filters", self.refused(args("read", topic=None), text).msg)
        inbox = ab.make_cursor(args("inbox", as_="bob"), 5)
        self.assertIn("other filters", self.refused(args("inbox", as_="amy"), inbox).msg)

    def test_the_inbox_cursor_follows_the_environment_name(self):
        """Bug: the name comes only from --as, and a cursor made under AGENTBUS_AGENT is refused next page."""
        with mock.patch.dict(os.environ, {"AGENTBUS_AGENT": "bob"}):
            text = ab.make_cursor(args("inbox"), 9)
            self.assertEqual(ab.read_cursor(args("inbox", as_="bob"), text, "--after"), 9)

    def test_not_a_cursor_is_refused(self):
        """Bug: anything is parsed as a row id: a plain number, a negative, a leading zero, trailing text, a huge id."""
        a = args("read", topic="a")
        good = ab.make_cursor(a, 5)
        head = good.rsplit(".", 1)[0]
        for text in ("", "5", "-5", good + "x", good + "\n", " " + good, head + ".05", head + ".-1", head + ".", head + ".5.6",
                     head + "." + str(ab.MAX_ID + 1), "v2." + good[3:], "V1." + good[3:], good.upper(), "v1.r.3FA9C1.5",
                     "v1.rr." + good.split(".", 2)[2], head + "." + "9" * 30):
            self.assertIn("not a cursor", self.refused(a, text).msg, repr(text))

    def test_the_largest_id_is_accepted(self):
        """Bug: the bound is off by one, and the last row of a very large bus cannot be paged to."""
        a = args("read", topic="a")
        self.assertEqual(ab.read_cursor(a, ab.make_cursor(a, ab.MAX_ID), "--before"), ab.MAX_ID)

    def test_the_refusal_names_the_flag_and_a_command_to_run(self):
        """Bug: the error says only `bad cursor`, and an agent has nothing to run to get a good one."""
        d = self.refused(args("inbox", as_="bob"), "nope")
        self.assertIn("--before", d.msg)
        self.assertEqual(d.next, "agentbus --as NAME --json inbox --peek")  # a name is not known yet: the hint says NAME
        self.assertIn(d.next, d.msg)

    def test_next_command_quotes_and_orders_its_words(self):
        """Bug: a name with a space or a quote becomes two shell words in the command we tell the reader to paste."""
        self.assertEqual(ab.next_command(args(as_="bob", up=2), "--json", "read"), "agentbus --as bob --up 2 --json read")
        self.assertEqual(ab.next_command(args(as_="o'brien x"), "read"), "agentbus --as 'o'\"'\"'brien x' read")
        self.assertEqual(ab.next_command(args(as_="bob"), "read", as_=False), "agentbus read")

    def test_page_size_never_returns_zero(self):
        """Bug: --limit 0 or all is repeated as 0 in the next-page command, and the next page is empty."""
        self.assertEqual(ab.page_size(SimpleNamespace(limit=7)), 7)
        self.assertEqual(ab.page_size(SimpleNamespace(limit=0)), ab.LISTING_LIMIT)
        self.assertEqual(ab.page_size(SimpleNamespace(limit=-1)), ab.LISTING_LIMIT)

    def test_envelope_says_whether_more_exists(self):
        """Bug: has_more is the count, not a boolean, or next is dropped."""
        self.assertEqual(ab.envelope([1], more=3, cursor="c"), {"items": [1], "has_more": True, "next": "c"})
        self.assertEqual(ab.envelope([], more=0), {"items": [], "has_more": False, "next": None})


class StoredCursors(unittest.TestCase):
    def bus(self):
        con = sqlite3.connect(":memory:")
        ab.create_schema(con)
        return con

    def test_a_new_name_sees_old_direct_mail_but_not_old_broadcasts(self):
        """Bug: a new agent is shown every broadcast since the bus began, or loses its direct mail."""
        con = self.bus()
        for i in range(3):
            con.execute("INSERT INTO messages(sender, recipient, kind, body, ts) VALUES('a', '*', 'note', ?, 'now')", (str(i),))
        ab.ensure_cursor(con, "new")
        self.assertEqual(con.execute("SELECT last_read_id, bcast_from FROM cursors WHERE agent='new'").fetchone(), (0, 3))

    def test_ensure_cursor_never_moves_an_existing_cursor(self):
        """Bug: INSERT OR REPLACE, and a second join forgets what was read."""
        con = self.bus()
        con.execute("INSERT INTO cursors(agent, last_read_id, bcast_from) VALUES('a', 9, 4)")
        ab.ensure_cursor(con, "a")
        self.assertEqual(con.execute("SELECT last_read_id, bcast_from FROM cursors WHERE agent='a'").fetchone(), (9, 4))

    def test_hook_cursor_without_a_row_does_not_write(self):
        """Bug: a read-only hook creates the cursor, or reports 0 for the broadcast bound and shows old broadcasts."""
        con = self.bus()
        con.execute("INSERT INTO messages(sender, recipient, kind, body, ts) VALUES('a', '*', 'note', 'x', 'now')")
        self.assertEqual(ab.hook_cursor(con, "ghost"), (0, 1))
        self.assertEqual(con.execute("SELECT COUNT(*) FROM cursors").fetchone()[0], 0)
        con.execute("INSERT INTO cursors(agent, last_read_id, bcast_from) VALUES('ghost', 3, 2)")
        self.assertEqual(ab.hook_cursor(con, "ghost"), (3, 2))

    def test_kind_counts_fold_unknown_kinds_into_other(self):
        """Bug: a kind a lane planted becomes a key of its own, or raises, and the hook text lists it."""
        counts, newest = ab.hook_kind_counts([("note", 2, 5), ("alert", 1, 9), ("evil\x1b", 4, 7), (None, 1, 3), (5, 1, 2), ("note", 3, 1)])
        self.assertEqual(counts, {"note": 5, "alert": 1, "other": 6})
        self.assertEqual(newest, 9)
        self.assertEqual(ab.hook_kind_counts([]), ({}, 0))


if __name__ == "__main__":
    unittest.main()
