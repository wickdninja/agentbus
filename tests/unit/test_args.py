"""Names and argument parsing helpers. Every test's docstring names the bug it catches."""
import argparse
import contextlib
import io
import types
import unittest

from load_agentbus import ab, diag


class Integer(unittest.TestCase):
    def test_accepts(self):
        """Bug: a plain, signed, padded or zero-led number is refused."""
        for text, want in (("0", 0), ("7", 7), ("+7", 7), ("-7", -7), (" 7 ", 7), ("007", 7), ("0" * 50 + "1", 1)):
            self.assertEqual(ab.integer(text), want, text)

    def test_the_sqlite_range_is_exact(self):
        """Bug: a value past 64 bits reaches a query and raises OverflowError instead of a usage error."""
        self.assertEqual(ab.integer(str(2 ** 63 - 1)), 2 ** 63 - 1)
        self.assertEqual(ab.integer(str(-(2 ** 63))), -(2 ** 63))
        for text in (str(2 ** 63), str(-(2 ** 63) - 1), "9" * 19):
            with self.assertRaises(argparse.ArgumentTypeError):
                ab.integer(text)

    def test_a_very_long_number_is_a_usage_error(self):
        """Bug: Python 3.11+ raises ValueError on huge digit strings, a traceback instead of a usage error."""
        with self.assertRaises(argparse.ArgumentTypeError):
            ab.integer("9" * 100000)

    def test_refuses_what_is_not_an_integer(self):
        """Bug: 1.5, 0x10 or an empty value is accepted or raises something else."""
        for text in ("", " ", "abc", "1.5", "0x10", "1e3", "--1", "1 2"):
            with self.assertRaises(argparse.ArgumentTypeError):
                ab.integer(text)


class Bounded(unittest.TestCase):
    def test_bus_level(self):
        """Bug: --up -1 selects a bus from the wrong end of the list."""
        self.assertEqual(ab.bus_level("0"), 0)
        with self.assertRaises(argparse.ArgumentTypeError):
            ab.bus_level("-1")

    def test_limit_count(self):
        """Bug: --limit -2 becomes a second way to say all."""
        self.assertEqual(ab.limit_count("-1"), -1)
        self.assertEqual(ab.limit_count("0"), 0)
        with self.assertRaises(argparse.ArgumentTypeError):
            ab.limit_count("-2")

    def test_interval(self):
        """Bug: nan or inf gets past the bounds and watch spins or sleeps forever."""
        self.assertEqual(ab.interval("0.2"), 0.2)
        self.assertEqual(ab.interval("60"), 60.0)
        for text in ("0.1", "60.1", "nan", "inf", "-inf", "fast", ""):
            with self.assertRaises(argparse.ArgumentTypeError):
                ab.interval(text)


class OneName(unittest.TestCase):
    def parser(self):
        p = argparse.ArgumentParser()
        p.add_argument("--to", action=ab.OneName)
        return p

    def test_one_is_kept(self):
        """Bug: the flag loses its value, or the namespace forgets --to was given."""
        a = self.parser().parse_args(["--to", "x"])
        self.assertEqual((a.to, a.to_given), ("x", True))

    def test_a_second_is_refused(self):
        """Bug: `--to a --to b` silently posts only to b."""
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            self.parser().parse_args(["--to", "a", "--to", "b"])
        self.assertIn("takes one name (got a and b)", err.getvalue())


class Names(unittest.TestCase):
    def test_valid(self):
        """Bug: a name join accepts today is refused after a regex change."""
        for name in ("a", "A-1", "x.y_z", "9", "-", "x" * 40):
            self.assertTrue(ab.HOOK_NAME_RE.fullmatch(name), name)

    def test_invalid(self):
        """Bug: a name with a space, a slash, a newline or an accent reaches a hook's printed command."""
        for name in ("", "x" * 41, "a b", "a/b", "a\n", "café", "a;b", "$(x)", "١"):
            self.assertIsNone(ab.HOOK_NAME_RE.fullmatch(name), name)

    def test_refusal_says_what_to_run(self):
        """Bug: the error for a bad name suggests a join that would itself be refused."""
        d = diag(self, ab.refuse_invalid_name, "a b")
        self.assertEqual((d.code, d.next), ("bad_input", "agentbus --as NAME join"))
        self.assertEqual(d.fields, {"field": "name"})
        self.assertTrue(ab.HOOK_NAME_RE.fullmatch(d.next.split()[2]))

    def test_refusal_keeps_up(self):
        """Bug: the suggested join lands on another bus."""
        self.assertEqual(diag(self, ab.refuse_invalid_name, "a b", types.SimpleNamespace(up=1)).next, "agentbus --up 1 --as NAME join")


class NextCommand(unittest.TestCase):
    def test_words_are_quoted(self):
        """Bug: a suggested command with a space in a value breaks when pasted, or runs part of it."""
        a = types.SimpleNamespace(as_="a b", up=0)
        self.assertEqual(ab.next_command(a, "post", "x;y"), "agentbus --as 'a b' post 'x;y'")

    def test_as_can_be_left_out(self):
        """Bug: a command that needs no name is shown with one, or None is printed."""
        self.assertEqual(ab.next_command(types.SimpleNamespace(as_="a", up=0), "who", as_=False), "agentbus who")
        self.assertEqual(ab.next_command(None, "who"), "agentbus who")


class OrList(unittest.TestCase):
    def test_lists(self):
        """Bug: `did you mean` reads `a, or b` or loses a name."""
        self.assertEqual(ab.or_list(["a"]), "a")
        self.assertEqual(ab.or_list(["a", "b"]), "a or b")
        self.assertEqual(ab.or_list(["a", "b", "c"]), "a, b or c")


if __name__ == "__main__":
    unittest.main()
