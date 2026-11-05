"""What a claim names, and which claims conflict. Every test's docstring names the bug it catches."""
import sqlite3
import types
import unittest

from load_agentbus import ab, diag


class NormResource(unittest.TestCase):
    def test_paths_take_one_stored_form(self):
        """Bug: ./a//b.py and a/b.py are stored apart, so two lanes hold the same file with no conflict."""
        for given, want in (("./a//b.py", "a/b.py"), ("a/./b", "a/b"), ("a/b/../c", "a/c"), ("a", "a"), ("src/", "src/"), ("src//", "src/"), ("./src/.", "src")):
            self.assertEqual(ab.norm_resource(given), want, given)

    def test_a_resource_with_a_scheme_is_not_a_path(self):
        """Bug: area:db/../x is rewritten as if it were a path, and no longer equals what another lane claimed."""
        for name in ("area:db/../x", "db:main", "a.b:c"):
            self.assertEqual(ab.norm_resource(name), name)

    def test_paths_that_leave_the_bus_are_refused(self):
        """Bug: a claim on /etc/x or ../x means a different file in each worktree."""
        for bad, why in (("/etc/x", "absolute"), ("../x", "climbs"), ("a/../../x", "climbs"), ("..", "climbs"), (".", "inside"), ("", "inside"), ("a/..", "inside")):
            d = diag(self, ab.norm_resource, bad)
            self.assertEqual(d.code, "bad_input", bad)
            self.assertIn(why, d.msg, bad)
            self.assertEqual(d.next, "agentbus --as NAME claim src/app/ --purpose WHY", bad)

    def test_the_hint_keeps_the_callers_bus(self):
        """Bug: the suggested command drops --up N and claims on the wrong bus."""
        d = diag(self, ab.norm_resource, "/x", True, types.SimpleNamespace(up=2))
        self.assertEqual(d.next, "agentbus --up 2 --as NAME claim src/app/ --purpose WHY")

    def test_length_limit_is_a_clear_error(self):
        """Bug: an extracted module misses its `die` import, and this path raises NameError where the shipped file exits bad_input."""
        self.assertEqual(ab.norm_resource("x" * ab.RESOURCE_MAX), "x" * ab.RESOURCE_MAX)
        d = diag(self, ab.norm_resource, "x" * (ab.RESOURCE_MAX + 1))
        self.assertEqual(d.code, "bad_input")

    def test_not_strict_never_exits(self):
        """Bug: a row planted directly stops every bus open with an exit, instead of staying for `claims` to show."""
        for bad in ("/etc/x", "../x", ".", "x" * (ab.RESOURCE_MAX + 1)):
            self.assertEqual(ab.norm_resource(bad, strict=False), bad)
        self.assertEqual(ab.norm_resource("./a//b", strict=False), "a/b")


class IsPath(unittest.TestCase):
    def test_scheme_only_at_the_start(self):
        """Bug: a file with a colon in its name stops being a path, and a folder claim misses it."""
        self.assertFalse(ab.is_path("area:x"))
        self.assertTrue(ab.is_path("src/a:b"))
        self.assertTrue(ab.is_path(":x"))
        self.assertTrue(ab.is_path("1a:b"))


class Overlaps(unittest.TestCase):
    def test_conflicts(self):
        """Bug: a folder claim does not cover the files in it, so two lanes edit one file."""
        for x, y in (("a", "a"), ("src", "src/x.py"), ("src/", "src/x.py"), ("src/a/b", "src/"), ("./src", "src/"), ("area:x", "area:x")):
            self.assertTrue(ab.overlaps(x, y), (x, y))
            self.assertTrue(ab.overlaps(y, x), (y, x))

    def test_no_conflict(self):
        """Bug: a prefix match makes src/ab conflict with src/a, or a scheme name acts as a folder."""
        for x, y in (("src/a", "src/ab"), ("src", "src2/x"), ("area:x", "area:x/y"), ("area:x", "x"), ("a/b", "a/c")):
            self.assertFalse(ab.overlaps(x, y), (x, y))
            self.assertFalse(ab.overlaps(y, x), (y, x))


class OverlapFilters(unittest.TestCase):
    STORED = ("a", "a/", "a/b", "a/b/", "a/b/c.py", "a/bc", "a/b-c", "a-b", "a0", "a.b", "z/y", "z", "area:a", "area:a/b", "db:main")

    def matching(self, con, res):
        found = set()
        for sql, params in ab.overlap_filters(res):
            found.update(r[0] for r in con.execute(f"SELECT resource FROM claims WHERE {sql}", params))
        return found

    def setUp(self):
        self.con = sqlite3.connect(":memory:")
        self.addCleanup(self.con.close)
        self.con.execute("CREATE TABLE claims(resource TEXT PRIMARY KEY)")
        self.con.executemany("INSERT INTO claims VALUES(?)", [(r,) for r in self.STORED])

    def test_sql_agrees_with_overlaps_on_every_pair(self):
        """Bug: the indexed SQL and overlaps() drift apart, so a claim passes the check and conflicts later."""
        for res in self.STORED + ("a/b/c.py/d", "nothing", "a/b/c", "area:zzz"):
            want = {s for s in self.STORED if ab.overlaps(res, s)}
            self.assertEqual(self.matching(self.con, res), want, res)

    def test_a_very_deep_path_stays_under_the_parameter_limit(self):
        """Bug: a deep path sends more parameters than SQLite 3.31 and older allow, and the claim fails."""
        deep = "/".join(["d"] * 500)
        filters = ab.overlap_filters(deep)
        self.assertGreater(len(filters), 2)
        self.assertLessEqual(max(len(params) for _, params in filters), 999)
        self.con.execute("INSERT INTO claims VALUES(?)", ("/".join(["d"] * 300),))
        self.assertIn("/".join(["d"] * 300), self.matching(self.con, deep))


if __name__ == "__main__":
    unittest.main()
