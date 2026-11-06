"""The release lookup's pure parts: version order and shape, the GitHub answer, SHA256SUMS and the cache entry. They
take text that comes from the network or a file another process wrote, so each must refuse junk and never raise.
Every test's docstring names the bug it catches."""
import json
import math
import unittest

from load_agentbus import ab


def release(*tags, drafts=(), assets=None):
    """A GitHub releases list as bytes, newest first."""
    rows = [{"tag_name": t, "assets": [{"name": n} for n in (assets or {}).get(t, [])]} for t in tags]
    rows += [{"tag_name": t, "draft": True} for t in drafts]
    return json.dumps(rows).encode()


class ReleaseKey(unittest.TestCase):
    ORDER = ["1.0.dev1", "1.0a1", "1.0b2", "1.0rc1", "1.0rc2", "1.0", "1.0.post1", "1.0.1", "1.1", "2.0", "10.0"]

    def test_pep440_order(self):
        """Bug: versions compare as text, and 10.0 sorts below 2.0, or a release candidate above its release."""
        keys = [ab.release_key(v) for v in self.ORDER]
        self.assertNotIn(None, keys)
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(len(set(keys)), len(keys))

    def test_missing_parts_are_zero(self):
        """Bug: 1.0 and 1.0.0 are different releases, and update offers 1.0.0 as newer than 1.0."""
        self.assertEqual(ab.release_key("1.0"), ab.release_key("1.0.0"))
        self.assertEqual(ab.release_key("1.0"), ab.release_key("1.0.0.0"))

    def test_not_a_release_is_none(self):
        """Bug: a commit hash or junk gets a key, and compares as a version."""
        for v in (None, "", "abc1234", "v1.0", "1", "1.0.0.0.0", "1.0-rc1", "1.0 ", "01234567.1", "1.0+", "1.0.dev", "1.0rc"):
            self.assertIsNone(ab.release_key(v), v)

    def test_local_version_suffix_does_not_change_the_order(self):
        """Bug: `+dirty` or a local tag is parsed as a different release and sorts apart from its base."""
        self.assertEqual(ab.release_key("1.2.3+g1a2b3c"), ab.release_key("1.2.3"))

    def test_candidate_flag_for_a_running_build(self):
        """Bug: the pre-release test reads the wrong slot of the key, and a final release hears of candidates."""
        for v, pre in (("1.0rc1", True), ("1.0a1", True), ("1.0.dev1", True), ("1.0", False), ("1.0.post1", False)):
            with self.subTest(v):
                with_version = ab.release_key(v)
                self.assertEqual(with_version[1][0] != 1, pre)


class Guarded(unittest.TestCase):
    def test_accepts_only_the_tag_shape(self):
        """Bug: the guard lets a version through that is later shown, cached or put into an argument list."""
        for v in ("0.3.0", "1.2.3", "10.20.30", "9999.9999.9999", "1.2.3rc4", "1.2.3rc0"):
            self.assertEqual(ab.guarded(v), v)

    def test_refuses_everything_else(self):
        """Bug: a leading zero, a fourth part, a flag-looking value or a line break passes the guard."""
        for v in (None, 5, b"1.2.3", "", "1.2", "1.2.3.4", "01.2.3", "1.2.3rc", "1.2.3rc01", "1.2.3a1", "v1.2.3", "-1.2.3",
                  "1.2.3\n", " 1.2.3", "1.2.3 ", "10000.0.0", "1.2.3-rc1", "1.2.3; rm", "../1.2.3"):
            self.assertIsNone(ab.guarded(v), repr(v))

    def test_newer_than_the_running_version(self):
        """Bug: release_newer is true for the running version or for an unguarded string."""
        mine = ab.__version__
        self.assertFalse(ab.release_newer(mine))
        self.assertFalse(ab.release_newer("0.0.1"))
        self.assertTrue(ab.release_newer("9999.0.0"))
        self.assertFalse(ab.release_newer("9999.0.0.1"))
        self.assertFalse(ab.release_newer(None))


class ParseReleaseBody(unittest.TestCase):
    def test_latest_stable(self):
        """Bug: the single-release answer is read as a list, or the leading v stays in the version."""
        body = json.dumps({"tag_name": "v1.4.0", "assets": [{"name": "a.whl"}, {"name": "SHA256SUMS"}]}).encode()
        got = ab.parse_release_body(body, False)
        self.assertEqual((got["ok"], got["stable"], got["pre"]), (True, "1.4.0", None))
        self.assertEqual(got["assets"], {"1.4.0": ["a.whl", "SHA256SUMS"]})

    def test_a_candidate_goes_to_pre(self):
        """Bug: a release candidate is offered as the stable release."""
        got = ab.parse_release_body(json.dumps({"tag_name": "v1.4.0rc1"}).encode(), False)
        self.assertEqual((got["stable"], got["pre"]), (None, "1.4.0rc1"))

    def test_malformed_is_a_failure_not_a_raise(self):
        """Bug: junk from the network raises into the caller, or is taken as no release."""
        for body, pre in ((b"not json", False), (b"\xff\xfe", False), (b"[]", False), (b'{"tag_name": 5}', False),
                          (b'{"tag_name": "1.2.3"}', False), (b'{"tag_name": "v1.2"}', False), (b'{"tag_name": "v1.2.3\\n"}', False),
                          (b"{}", True), (b'"x"', True), (b"[" * 100000, False), (b"[" * 100000, True)):
            got = ab.parse_release_body(body, pre)
            self.assertEqual((got["ok"], got["reason"]), (False, "malformed"), (body[:20], pre))

    def test_the_list_keeps_the_highest_final_and_candidate(self):
        """Bug: the first row wins instead of the highest, or drafts and unguarded tags are counted."""
        body = release("v1.0.0", "v1.10.0", "v1.9.0", "v2.0.0rc1", "v1.11.0rc2", "junk", "v1.2", drafts=("v99.0.0",))
        got = ab.parse_release_body(body, True)
        self.assertEqual((got["ok"], got["stable"], got["pre"]), (True, "1.10.0", "2.0.0rc1"))
        self.assertNotIn("99.0.0", got["assets"])
        self.assertEqual(sorted(got["assets"]), ["1.0.0", "1.10.0", "1.11.0rc2", "1.9.0", "2.0.0rc1"])

    def test_an_empty_list_is_found_with_nothing(self):
        """Bug: a repo with no release yet is reported as a failed lookup."""
        got = ab.parse_release_body(b"[]", True)
        self.assertEqual((got["ok"], got["stable"], got["pre"]), (True, None, None))

    def test_only_the_first_hundred_releases_are_read(self):
        """Bug: a repo with thousands of releases makes the lookup read them all."""
        body = release(*(f"v1.{i}.0" for i in range(150)))
        self.assertEqual(len(ab.parse_release_body(body, True)["assets"]), 100)

    def test_asset_names_are_bounded_and_typed(self):
        """Bug: hostile asset lists are trusted: non-text names, more than 50, or a non-list."""
        rows = [{"tag_name": "v1.0.0", "assets": [{"name": f"f{i}"} for i in range(80)] + [{"name": 5}, "x", None]},
                {"tag_name": "v1.1.0", "assets": "no"}, {"tag_name": "v1.2.0"}]
        got = ab.parse_release_body(json.dumps(rows).encode(), True)["assets"]
        self.assertEqual(len(got["1.0.0"]), 50)
        self.assertTrue(all(isinstance(n, str) for n in got["1.0.0"]))
        self.assertEqual((got["1.1.0"], got["1.2.0"]), ([], []))


class NewestRelease(unittest.TestCase):
    def test_final_only_unless_the_install_is_a_candidate(self):
        """Bug: a final install is told about a release candidate."""
        entry = {"stable": "1.0.0", "pre": "1.1.0rc1"}
        self.assertEqual(ab.newest_release(entry, False), "1.0.0")
        self.assertEqual(ab.newest_release(entry, True), "1.1.0rc1")

    def test_a_candidate_install_still_prefers_a_newer_final(self):
        """Bug: max over the strings instead of the keys, so 1.9.0 beats 1.10.0."""
        self.assertEqual(ab.newest_release({"stable": "1.10.0", "pre": "1.9.0rc1"}, True), "1.10.0")

    def test_nothing_known_is_none(self):
        """Bug: max() of an empty list raises."""
        self.assertIsNone(ab.newest_release({}, True))
        self.assertIsNone(ab.newest_release({"stable": None, "pre": None}, False))


HASH = "a" * 64
OTHER = "b" * 64


class ParseSums(unittest.TestCase):
    def test_finds_the_named_file(self):
        """Bug: the hash of the first line is returned whatever the name."""
        text = f"{OTHER}  other.whl\n{HASH.upper()} *agentbus-1.0.0-py3-none-any.whl\n"
        self.assertEqual(ab.parse_sums(text, "agentbus-1.0.0-py3-none-any.whl"), HASH)

    def test_the_answer_is_lowercase(self):
        """Bug: an uppercase hash fails the comparison with hashlib's lowercase digest."""
        self.assertEqual(ab.parse_sums(f"{HASH.upper()}  f\n", "f"), HASH)

    def test_two_lines_for_one_name_is_a_refusal(self):
        """Bug: a second, hostile line for the same file wins, or the first does, instead of neither."""
        self.assertIsNone(ab.parse_sums(f"{HASH}  f\n{OTHER}  f\n", "f"))

    def test_no_line_is_a_refusal(self):
        """Bug: a missing entry reads as a pass."""
        self.assertIsNone(ab.parse_sums(f"{HASH}  g\n", "f"))
        self.assertIsNone(ab.parse_sums("", "f"))

    def test_malformed_lines_are_ignored(self):
        """Bug: a short hash, a 65-digit hash, one space, a path with a slash or a tab is accepted."""
        for line in (f"{HASH[:63]}  f", f"{HASH}a  f", f"{HASH} f", f"{HASH}\tf", f"{HASH}  dir/f", f"{HASH}  f x", f" {HASH}  f",
                     f"{HASH}  f ", f"{HASH}  "):
            self.assertIsNone(ab.parse_sums(line + "\n", "f"), repr(line))

    def test_a_name_must_match_whole(self):
        """Bug: a prefix or suffix match, so evil-f or f.sig stands in for f."""
        self.assertIsNone(ab.parse_sums(f"{HASH}  f.sig\n{HASH}  xf\n", "f"))

    def test_names_are_bounded(self):
        """Bug: an overlong name in the file is matched against."""
        name = "n" * 201
        self.assertIsNone(ab.parse_sums(f"{HASH}  {name}\n", name))


def entry(**over):
    base = {"v": 1, "checked_at": 100.0, "ok": True, "reason": None, "retry_after": None, "stable": "1.2.3", "pre": None, "notified": None}
    base.update(over)
    return base


class ValidCache(unittest.TestCase):
    def test_a_good_entry_comes_back_whole(self):
        """Bug: a field is dropped on the way through, and the next read forgets what was notified."""
        e = entry(ok=False, reason="offline", retry_after=30, pre="1.3.0rc1", notified={"version": "1.2.3", "at": 5, "junk": 1})
        self.assertEqual(ab.valid_cache(e), {"v": 1, "checked_at": 100.0, "ok": False, "reason": "offline", "retry_after": 30,
                                             "stable": "1.2.3", "pre": "1.3.0rc1", "notified": {"version": "1.2.3", "at": 5}})

    def test_not_an_entry_is_none(self):
        """Bug: the wrong version, a non-object or a bad time is trusted, and checked_at arithmetic raises later."""
        for o in (None, [], "x", 5, {}, entry(v=2), entry(v=None), entry(checked_at="1"), entry(checked_at=True),
                  entry(checked_at=math.inf), entry(checked_at=math.nan), entry(ok="yes"), entry(ok=1)):
            self.assertIsNone(ab.valid_cache(o), repr(o))

    def test_ok_may_be_unknown(self):
        """Bug: ok None (never looked) is refused, and a fresh cache looks corrupt."""
        self.assertIsNone(ab.valid_cache(entry(ok=None))["ok"])

    def test_versions_are_guarded_again(self):
        """Bug: a cache file another process wrote puts an unguarded version into a message or an argument list."""
        got = ab.valid_cache(entry(stable="1.2.3\n--evil", pre="x", notified={"version": "junk", "at": 1}))
        self.assertEqual((got["stable"], got["pre"], got["notified"]), (None, None, None))

    def test_unknown_reason_is_dropped(self):
        """Bug: a free-text reason from the file is shown to the person."""
        self.assertIsNone(ab.valid_cache(entry(reason="the sky fell"))["reason"])
        for r in ab.REASONS:
            self.assertEqual(ab.valid_cache(entry(reason=r))["reason"], r)

    def test_retry_after_must_be_a_non_negative_number(self):
        """Bug: a negative or text retry_after makes the next check due forever, or crash."""
        for bad in (-1, "5", True, math.inf, None):
            self.assertIsNone(ab.valid_cache(entry(retry_after=bad))["retry_after"], repr(bad))
        self.assertEqual(ab.valid_cache(entry(retry_after=0))["retry_after"], 0)

    def test_notified_needs_both_fields(self):
        """Bug: a half entry is kept, and the notice repeats or raises on the missing field."""
        for n in ({"version": "1.2.3"}, {"at": 1}, {"version": "1.2.3", "at": "1"}, [], "x"):
            self.assertIsNone(ab.valid_cache(entry(notified=n))["notified"], repr(n))

    def test_when_a_check_is_due(self):
        """Bug: a cache dated in the future, or one a day old, is treated as fresh forever."""
        now = ab.time.time()
        self.assertTrue(ab.release_due(None))
        self.assertFalse(ab.release_due({"checked_at": now - 10}))
        self.assertTrue(ab.release_due({"checked_at": now - ab.CHECK_INTERVAL_S - 10}))
        self.assertTrue(ab.release_due({"checked_at": now + 3600}))


class RateLimit(unittest.TestCase):
    def test_retry_after_then_reset_then_default(self):
        """Bug: the wait is unbounded, negative, or ignores the header GitHub actually sends."""
        self.assertEqual(ab._rate_limit_wait({"Retry-After": "120"}), 120)
        self.assertEqual(ab._rate_limit_wait({"Retry-After": "999999"}), 86400)
        self.assertEqual(ab._rate_limit_wait({"Retry-After": "-5"}), 0)
        self.assertEqual(ab._rate_limit_wait({"Retry-After": "soon"}), 3600)
        self.assertEqual(ab._rate_limit_wait({}), 3600)
        reset = ab._rate_limit_wait({"X-RateLimit-Reset": str(int(ab.time.time()) + 100)})
        self.assertTrue(95 <= reset <= 100, reset)
        self.assertEqual(ab._rate_limit_wait({"X-RateLimit-Reset": "1"}), 0)


if __name__ == "__main__":
    unittest.main()
