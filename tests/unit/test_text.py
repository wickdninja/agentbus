"""Text that reaches a terminal: clean, wrapping, widths. Every test's docstring names the bug it catches."""
import random
import unittest

from load_agentbus import ab, patched

_ALPHABET = "abc  中é-/́"


def strip_indents(rows):
    return "".join(r[len(ab.INDENT):] if i else r for i, r in enumerate(rows))


class Clean(unittest.TestCase):
    def test_controls_become_visible(self):
        """Bug: an ESC or a newline from a lane reaches the terminal raw and drives it or forges a line."""
        self.assertEqual(ab.clean("a\x1b[2Jb"), "a\\x1b[2Jb")
        self.assertEqual(ab.clean("a\nb"), "a\\x0ab")
        self.assertEqual(ab.clean("\x7f"), "\\x7f")

    def test_invisible_format_characters_become_visible(self):
        """Bug: a right-to-left override or a zero-width character hides or reorders what a reader sees."""
        self.assertEqual(ab.clean("‮"), "\\u202e")
        self.assertEqual(ab.clean("​"), "\\u200b")
        self.assertEqual(ab.clean("\U000e0001"), "\\U000e0001")

    def test_characters_the_categories_miss_are_escaped(self):
        """Bug: the ignorable list loses an entry, and a Hangul filler or Braille blank renders as nothing."""
        for c in ("͏", "ᅟ", "឴", "᠋", "⠀", "ㅤ", "️", "ﾠ"):
            self.assertEqual(ab.clean(c), "\\u%04x" % ord(c))

    def test_surrogates_and_private_use_are_escaped(self):
        """Bug: a lone surrogate from bad bytes crashes the writer, or a private-use glyph hides text."""
        self.assertEqual(ab.clean("\ud800"), "\\ud800")
        self.assertEqual(ab.clean(""), "\\ue000")

    def test_head_mark_cannot_be_forged(self):
        """Bug: a NUL survives clean, and lane text passes for a line agentbus wrote (HEAD starts a row at column 0)."""
        self.assertNotIn(ab.HEAD, ab.clean("x" + ab.HEAD + "y"))

    def test_a_literal_backslash_is_doubled(self):
        """Bug: text a lane wrote as \\x1b reads the same as a real escape."""
        self.assertEqual(ab.clean("\\x1b"), "\\\\x1b")
        self.assertEqual(ab.clean("\\x1b", backslash=False), "\\x1b")

    def test_newlines_survive_only_when_asked(self):
        """Bug: newlines=True lets other controls through, or a message body loses its lines."""
        self.assertEqual(ab.clean("a\nb\rc", newlines=True), "a\nb\\x0dc")

    def test_blank_run_limit_is_nine(self):
        """Bug: a long blank run pushes text to column 0 of a row that looks empty, forging a header."""
        self.assertEqual(ab.clean(" " * 8), " " * 8)
        self.assertEqual(ab.clean("a" + " " * 9 + "b"), "a" + "\\x20" * 9 + "b")
        self.assertEqual(ab.clean("  　" * 3), "\\xa0\\x20\\u3000" * 3)

    def test_text_around_a_blank_run_is_still_cleaned(self):
        """Bug: only the blank run is handled, and the ESC beside it goes through."""
        self.assertEqual(ab.clean("\x1b" + " " * 9 + "\x1b"), "\\x1b" + "\\x20" * 9 + "\\x1b")

    def test_none_and_non_text(self):
        """Bug: a NULL column raises in the output path instead of printing nothing."""
        self.assertEqual(ab.clean(None), "")
        self.assertEqual(ab.clean(42), "42")

    def test_ordinary_text_is_untouched(self):
        """Bug: an over-eager rule escapes accents, CJK or emoji, and messages turn to noise."""
        text = "café 中文 \U0001f600 ~!@#"
        self.assertEqual(ab.clean(text), text)


class Widths(unittest.TestCase):
    def test_char_width_never_undercounts(self):
        """Bug: a wide character counts 1, the row runs past the edge, and the terminal wraps it to column 0."""
        self.assertEqual([ab.char_width(c) for c in " ~"], [1, 1])
        self.assertEqual([ab.char_width(c) for c in "é中〮\U0001f600\x7f"], [2] * 5)

    def test_cell_width(self):
        """Bug: the live view counts combining marks or wide characters wrongly, and columns drift."""
        self.assertEqual(ab.cell_width("a"), 1)
        self.assertEqual(ab.cell_width("中"), 2)
        self.assertEqual(ab.cell_width("́"), 0)
        self.assertEqual(ab.cell_width("\u2014"), 1)
        self.assertEqual(ab.text_width("a中́"), 3)

    def test_cell_width_on_a_stdout_that_cannot_encode(self):
        """Bug: on an ascii stdout a wide character is drawn as ? (1 column) but counted 2, and columns drift."""
        with patched("_WATCH_ENCODING", "ascii"):
            self.assertEqual(ab.cell_width("中"), 1)
            self.assertEqual(ab.cell_width("́"), 1)
            self.assertEqual(ab.cell_width("a"), 1)


class WrapLine(unittest.TestCase):
    def test_no_width_means_no_wrapping(self):
        """Bug: output to a pipe is cut into rows."""
        self.assertEqual(ab.wrap_line("x" * 500, None), "x" * 500)

    def test_a_line_that_fits_is_one_row(self):
        """Bug: an off-by-one breaks a line of exactly the width."""
        self.assertEqual(ab.wrap_line("x" * 20, 20), "x" * 20)
        self.assertEqual(ab.wrap_line("x" * 21, 20).split("\n"), ["x" * 20, ab.INDENT + "x"])

    def test_breaks_after_the_last_space(self):
        """Bug: a path that fits on a row is cut mid-word, and the copied command fails."""
        self.assertEqual(ab.wrap_line("aaaa bbbb cccc", 10).split("\n"), ["aaaa bbbb ", ab.INDENT + "cccc"])

    def test_a_row_indent_is_not_a_break_point(self):
        """Bug: an indented line breaks at its own indent, leaving a row of two spaces and nothing else."""
        self.assertEqual(ab.wrap_line("  " + "x" * 30, 20).split("\n")[0], "  " + "x" * 18)

    def test_a_wide_character_moves_whole(self):
        """Bug: a 2-column character starts in the last column and the terminal wraps it to column 0."""
        rows = ab.wrap_line("x" * 19 + "中", 20).split("\n")
        self.assertEqual(rows, ["x" * 19, ab.INDENT + "中"])

    def test_every_row_fits_and_nothing_is_lost(self):
        """Bug: any wrapping change that drops a character, or lets a row pass the width, on mixed text."""
        rng = random.Random(1)
        for _ in range(300):
            text = "".join(rng.choice(_ALPHABET) for _ in range(rng.randrange(1, 120)))
            width = rng.randrange(ab.MIN_WIDTH, 60)
            rows = ab.wrap_line(text, width).split("\n")
            self.assertEqual(strip_indents(rows), text, (text, width))
            for i, row in enumerate(rows):
                self.assertLessEqual(sum(ab.char_width(c) for c in row), width, (text, width))
                if i:
                    self.assertTrue(row.startswith(ab.INDENT), (text, width))


class WrapOutput(unittest.TestCase):
    def test_only_marked_lines_start_a_row(self):
        """Bug: an unmarked line (lane text) starts at column 0, where it reads as a message header."""
        self.assertEqual(ab.wrap_output(ab.HEAD + "#1 header\n#2 forged", 80), "#1 header\n  #2 forged")

    def test_a_mark_inside_a_line_is_removed(self):
        """Bug: the NUL mark reaches the terminal."""
        self.assertEqual(ab.wrap_output(ab.HEAD + "a" + ab.HEAD + "b", 80), "ab")

    def test_empty_lines_stay_empty(self):
        """Bug: blank separator lines gain trailing spaces."""
        self.assertEqual(ab.wrap_output("a\n\nb", 80), "  a\n\n  b")

    def test_an_indented_line_is_not_indented_twice(self):
        """Bug: nested output drifts right on every pass."""
        self.assertEqual(ab.wrap_output("  a", 80), "  a")


class Col0(unittest.TestCase):
    def test_leading_header_characters_are_escaped(self):
        """Bug: a field that starts a row with # or = reads as a message header or section."""
        self.assertEqual(ab.col0("#9 x"), "\\x239 x")
        self.assertEqual(ab.col0("== x"), "\\x3d= x")

    def test_everything_else_is_left_alone(self):
        """Bug: a # inside a value is escaped, or a non-text value raises."""
        self.assertEqual(ab.col0("a#b"), "a#b")
        self.assertEqual(ab.col0(""), "")
        self.assertIsNone(ab.col0(None))


class ShellWord(unittest.TestCase):
    def setUp(self):
        self.home = "/home/a b"
        self.names = patched("home_names", lambda: [self.home])
        self.names.__enter__()
        self.addCleanup(self.names.__exit__, None, None, None)

    def test_home_stays_outside_the_quotes(self):
        """Bug: '~/x' in quotes names a folder called ~ when pasted."""
        self.assertEqual(ab.shell_word(self.home + "/my repo"), "~/'my repo'")
        self.assertEqual(ab.shell_word(self.home + "/repo"), "~/repo")
        self.assertEqual(ab.shell_word(self.home), "~")

    def test_a_path_outside_home_is_quoted_whole(self):
        """Bug: a path with a space or a semicolon runs as a second command when pasted."""
        self.assertEqual(ab.shell_word("/tmp/a; rm b"), "'/tmp/a; rm b'")
        self.assertEqual(ab.shell_word("/tmp/a"), "/tmp/a")

    def test_a_sibling_of_home_is_not_shortened(self):
        """Bug: /home/a bc passes the prefix test and is shown as a path under home."""
        self.assertEqual(ab.shell_word(self.home + "c/x"), "'" + self.home + "c/x'")


class Fit(unittest.TestCase):
    def test_exact_width_every_way(self):
        """Bug: a cut or a pad comes out a column short or long, and the live view's columns shift."""
        for text in ("", "abc", "x" * 50, "中" * 20, "a中" * 20, "é" * 20):
            for n in range(1, 30):
                self.assertEqual(ab.text_width(ab.fit(text, n)), n, (text, n))
                self.assertEqual(ab.text_width(ab.fit_left(text, n)), n, (text, n))

    def test_cut_ends_and_starts_with_the_ellipsis(self):
        """Bug: a cut loses its mark, or fit_left keeps the start of a path instead of the end."""
        self.assertEqual(ab.fit("abcdef", 4), "abc…")
        self.assertEqual(ab.fit_left("abcdef", 4), "…def")

    def test_lines_fold_and_controls_stay_escaped(self):
        """Bug: a newline splits a row of the live view, or an ESC reaches it."""
        self.assertEqual(ab.fit("a  b\nc", 8), "a b\\x0ac")
        self.assertEqual(ab.fit("\x1b", 4), "\\x1b")

    def test_none_is_blank(self):
        """Bug: a NULL column shows as the word None."""
        self.assertEqual(ab.fit(None, 3), "   ")


if __name__ == "__main__":
    unittest.main()
