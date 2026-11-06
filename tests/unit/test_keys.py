"""Terminal input to key names. The bytes come from a terminal, a paste or a hostile pipe, so a split, unknown or
overlong sequence must never turn into keys the person did not press. Every test's docstring names the bug it catches."""
import random
import unittest

from load_agentbus import ab

ARROWS = {b"\x1b[A": "Up", b"\x1b[B": "Down", b"\x1b[C": "Right", b"\x1b[D": "Left", b"\x1b[H": "Home", b"\x1b[F": "End",
          b"\x1b[Z": "S-Tab", b"\x1bOA": "Up", b"\x1bOB": "Down", b"\x1bOC": "Right", b"\x1bOD": "Left", b"\x1bOH": "Home",
          b"\x1bOF": "End", b"\x1b[5~": "PgUp", b"\x1b[6~": "PgDn", b"\x1b[1~": "Home", b"\x1b[4~": "End",
          b"\x1b[7~": "Home", b"\x1b[8~": "End"}


class Decode(unittest.TestCase):
    def test_named_keys(self):
        """Bug: an arrow, Home, End or page key is read as the escape bytes, and `[A` lands in the filter."""
        for raw, name in ARROWS.items():
            self.assertEqual(ab.decode_keys(raw), [name], raw)

    def test_control_characters(self):
        """Bug: Enter, Tab, Backspace or a Ctrl key is dropped or typed as text."""
        self.assertEqual(ab.decode_keys(b"\r\n\t\x7f\x08\x03\x15\x04"), ["Enter", "Enter", "Tab", "Backspace", "Backspace", "C-c", "C-u", "C-d"])

    def test_printable_text_is_itself(self):
        """Bug: plain and multi-byte characters are split into bytes, or a space is lost."""
        self.assertEqual(ab.decode_keys("a z é中😀".encode()), ["a", " ", "z", " ", "é", "中", "😀"])

    def test_other_control_characters_are_dropped(self):
        """Bug: NUL, bell or a stray control byte reaches the filter text."""
        self.assertEqual(ab.decode_keys(b"a\x00\x07\x1fb"), ["a", "b"])

    def test_unprintable_unicode_is_dropped(self):
        """Bug: a right-to-left override typed or pasted into the filter reaches the screen."""
        self.assertEqual(ab.decode_keys("a‮b​".encode()), ["a", "b"])

    def test_invalid_utf8_is_dropped_one_byte_at_a_time(self):
        """Bug: a bad lead byte swallows the characters after it, or raises."""
        self.assertEqual(ab.decode_keys(b"\xff\xfeab"), ["a", "b"])
        self.assertEqual(ab.decode_keys(b"\xc3\x28b"), ["(", "b"])

    def test_unknown_sequences_are_dropped_whole(self):
        """Bug: an unknown escape sequence is typed into the filter as separate keys."""
        for raw in (b"\x1b[99X", b"\x1b[Q", b"\x1b[2~", b"\x1bOQ", b"\x1b[20;5~"):
            self.assertEqual(ab.decode_keys(raw + b"x"), ["x"], raw)

    def test_alt_key_is_dropped_whole(self):
        """Bug: Alt+b is read as Esc then b, and a mere Alt chord runs the Esc action."""
        self.assertEqual(ab.decode_keys(b"\x1bb"), [])
        self.assertEqual(ab.decode_keys(b"\x1bbx"), ["x"])

    def test_double_escape_is_a_key_then_the_rest(self):
        """Bug: ESC ESC is swallowed as one unknown sequence, and Esc Esc does not leave a mode."""
        self.assertEqual(ab.decode_keys(b"\x1b\x1b"), ["Esc", "Esc"])
        self.assertEqual(ab.decode_keys(b"\x1b\x1b[A"), ["Esc", "Up"])

    def test_cursor_position_report(self):
        """Bug: the start-up probe's answer is typed into the filter."""
        self.assertEqual(ab.decode_keys(b"\x1b[24;80R"), ["CPR 24;80"])
        self.assertEqual(ab.decode_keys(b"\x1b[24R"), [])
        self.assertEqual(ab.decode_keys(b"\x1b[1;2;3R"), [])

    def test_the_modifier_parameter_picks_the_tilde_key_by_its_first_number(self):
        """Bug: a modified PgUp (`ESC [ 5 ; 2 ~`) is dropped, or read as the wrong key."""
        self.assertEqual(ab.decode_keys(b"\x1b[5;2~"), ["PgUp"])

    def test_an_overlong_sequence_is_dropped_whole(self):
        """Bug: a sequence that never ends holds the decoder forever, or its tail is typed as text."""
        long = b"\x1b[" + b"1;" * ab.CSI_MAX
        d = ab.KeyDecoder()
        self.assertEqual(d.feed(long), [])
        self.assertFalse(d.pending())
        self.assertEqual(d.feed(b"ok"), ["o", "k"])

    def test_a_malformed_sequence_drops_what_was_read(self):
        """Bug: a control byte inside a sequence is skipped and the rest is read as the final byte."""
        self.assertEqual(ab.decode_keys(b"\x1b[1\x01A"), ["A"])


class Split(unittest.TestCase):
    def test_a_sequence_split_across_reads_is_one_key(self):
        """Bug: the first half of an arrow arrives alone and is typed as Esc and `[`."""
        for raw, name in ARROWS.items():
            for cut in range(1, len(raw)):
                d = ab.KeyDecoder()
                got = d.feed(raw[:cut]) + d.feed(raw[cut:])
                self.assertEqual(got, [name], (raw, cut))
                self.assertFalse(d.pending())

    def test_a_character_split_across_reads_is_one_key(self):
        """Bug: a multi-byte character in two reads becomes two dropped bytes."""
        raw = "😀".encode()
        for cut in range(1, 4):
            d = ab.KeyDecoder()
            self.assertEqual(d.feed(raw[:cut]) + d.feed(raw[cut:]), ["😀"])

    def test_any_chunking_gives_the_same_keys(self):
        """Bug: decoding depends on where the reads fell, so a slow terminal types different keys."""
        rng = random.Random(7)
        pieces = list(ARROWS) + [b"a", "é".encode(), b"\r", b"\x1b[24;80R", b"\x1b[99X", b"\x1bb", b"\x1b\x1b", b"\xff", b"\x1b[5;2~"]
        for _ in range(200):
            raw = b"".join(rng.choice(pieces) for _ in range(rng.randint(1, 8))) + b"."
            whole = ab.decode_keys(raw)
            d, got, i = ab.KeyDecoder(), [], 0
            while i < len(raw):
                j = i + rng.randint(1, 4)
                got += d.feed(raw[i:j])
                i = j
            self.assertEqual(got + d.flush(), whole, raw)

    def test_a_lone_escape_waits_then_flushes_to_esc(self):
        """Bug: a lone ESC is reported at once, so every arrow's first byte is an Esc keypress."""
        d = ab.KeyDecoder()
        self.assertEqual(d.feed(b"\x1b"), [])
        self.assertTrue(d.pending())
        self.assertEqual(d.flush(), ["Esc"])
        self.assertFalse(d.pending())

    def test_flush_drops_a_partial_sequence_without_a_key(self):
        """Bug: flush turns half an arrow into Esc."""
        d = ab.KeyDecoder()
        d.feed(b"\x1b[")
        self.assertEqual(d.flush(), [])
        self.assertFalse(d.pending())
        d.feed("é".encode()[:1])
        self.assertEqual(d.flush(), [])

    def test_flush_with_nothing_held_is_empty(self):
        """Bug: flush on an empty decoder reports Esc and closes a view on every idle tick."""
        self.assertEqual(ab.KeyDecoder().flush(), [])

    def test_random_bytes_never_raise_or_leak_controls(self):
        """Bug: hostile input raises out of the key loop, or an escape byte reaches a key name."""
        rng = random.Random(1)
        for _ in range(500):
            raw = bytes(rng.randrange(256) for _ in range(rng.randint(0, 60)))
            for key in ab.decode_keys(raw):
                self.assertTrue(key.startswith("CPR ") or key.isprintable() or key in ARROWS.values() or key in
                                {"Enter", "Tab", "Backspace", "Esc", "C-c", "C-u", "C-d", "S-Tab", "PgUp", "PgDn", "Home", "End",
                                 "Up", "Down", "Left", "Right"}, (raw, key))

    def test_utf8_lead_lengths(self):
        """Bug: the lead-byte table is off by one, and a three-byte character is cut short or read as four."""
        self.assertEqual([ab._utf8_len(b) for b in (0x7f, 0x80, 0xc1, 0xc2, 0xdf, 0xe0, 0xef, 0xf0, 0xf4, 0xf5)],
                         [0, 0, 0, 2, 2, 3, 3, 4, 4, 0])


if __name__ == "__main__":
    unittest.main()
