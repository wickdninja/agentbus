"""The git index reader, on real index files git writes here and on bytes built by hand. It runs inside a hook on a
file a lane can plant, so every malformed input must end in ValueError. Every test's docstring names the bug it catches."""
import hashlib
import os
import random
import shutil
import struct
import subprocess
import tempfile
import unittest

from load_agentbus import ab

GIT_ENV = {"PATH": os.environ.get("PATH", ""), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
           "HOME": os.devnull, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
VERSIONS = ((2, False), (3, True), (4, False))  # git writes version 3 only when an entry needs the extended flags
PATHS = ["a.txt", "dir/b.txt", "dir/linker.c", "dir/sdir", "dir/sub/c.txt", "z" * 300, "y/" + "w" * 4100, "café.txt"]


def git(repo, *args, stdin=None):
    return subprocess.run(("git", "-C", repo) + args, env=GIT_ENV, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def real_index(top, version, fmt="sha1", intent=False):
    """The bytes of an index git itself wrote: PATHS at modes that all occur in the wild, in format `version`."""
    repo = tempfile.mkdtemp(dir=top)
    git(repo, "init", "-q", "--object-format=" + fmt)
    blob = git(repo, "hash-object", "-w", "--stdin", stdin=b"").decode().strip()
    rows = "".join(f"{mode} {blob}\t{path}\n" for mode, path in zip(("100644", "100755", "120000", "160000") * 3, PATHS))
    git(repo, "update-index", "--add", "--index-info", stdin=rows.encode())
    if intent:
        with open(os.path.join(repo, "planned.txt"), "w"):
            pass
        git(repo, "add", "-N", "planned.txt")
    git(repo, "update-index", f"--index-version={version}")
    with open(os.path.join(repo, ".git", "index"), "rb") as f:
        data = f.read()
    names = git(repo, "ls-files", "-z").split(b"\0")[:-1]
    return data, names


def entry(name, size=20, mode=0o100644, extended=None):
    """One version 2 or 3 entry, padded the way git pads it. extended: the two extra flag bytes (version 3 only)."""
    flags = min(len(name), 0xFFF) | (0x4000 if extended is not None else 0)
    head = bytes(24) + struct.pack(">I", mode) + bytes(12) + bytes(size) + struct.pack(">H", flags)
    head += struct.pack(">H", extended) if extended is not None else b""
    body = head + name
    return body + b"\0" * (8 - len(body) % 8)


def index(entries, version=2, ext=b"", size=20, count=None):
    """Index bytes with a right checksum: header, entries, extensions, trailer."""
    body = b"DIRC" + struct.pack(">II", version, len(entries) if count is None else count) + b"".join(entries) + ext
    return body + (hashlib.sha1(body) if size == 20 else hashlib.sha256(body)).digest()


def extension(sig, body):
    return sig + struct.pack(">I", len(body)) + body


class RealIndexes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.top = tempfile.mkdtemp()
        cls.addClassCleanup(shutil.rmtree, cls.top, ignore_errors=True)

    def test_versions_2_3_and_4_read_what_git_wrote(self):
        """Bug: a change to the name-length or prefix-compression walk misreads a real index, so the hook guards the wrong paths."""
        for version, intent in VERSIONS:
            data, names = real_index(self.top, version, intent=intent)
            self.assertEqual(data[4:8], struct.pack(">I", version))
            self.assertEqual(ab.hook_index_walk(data, 20), (names, None, False), version)
            self.assertEqual(ab.hook_index_reads(data)[0][0], names, version)

    def test_parse_and_walk_agree_and_parse_keeps_modes(self):
        """Bug: the fast walk and the full parse drift apart, or a mode is read from the wrong offset (a symlink passes for a file)."""
        for version, intent in VERSIONS:
            data, names = real_index(self.top, version, intent=intent)
            parsed, link = ab.hook_index_parse(data, 20)
            self.assertEqual([n for n, _ in parsed], names, version)
            self.assertIsNone(link)
            self.assertEqual({m for _, m in parsed}, {0o100644, 0o100755, 0o120000, 0o160000}, version)

    def test_intent_to_add_uses_the_extended_flags(self):
        """Bug: the 2 extra flag bytes of an intent-to-add entry are missed, and every later name is garbage."""
        for version in (3, 4):
            data, names = real_index(self.top, version, intent=True)
            self.assertIn(b"planned.txt", names)
            self.assertEqual(ab.hook_index_walk(data, 20)[0], names, version)

    def test_sha256_repositories(self):
        """Bug: a sha256 repo's 32-byte ids shift every field, and its index reads as damaged."""
        data, names = real_index(self.top, 2, fmt="sha256")
        self.assertEqual(ab.hook_index_walk(data, 32)[0], names)
        self.assertEqual(ab.hook_index_reads(data)[0][3], 32)
        self.assertEqual(ab.hook_index_reads(data, (32, 20))[0][3], 32)


class Extensions(unittest.TestCase):
    def test_link_gives_the_shared_index(self):
        """Bug: a split index is read as whole, and paths in the shared index go unseen."""
        data = index([entry(b"a")], ext=extension(b"link", b"\xab" * 20 + b"bitmaps"))
        self.assertEqual(ab.hook_index_walk(data, 20)[1], "ab" * 20)
        self.assertEqual(ab.hook_index_parse(data, 20)[1], "ab" * 20)

    def test_sdir_marks_a_sparse_index(self):
        """Bug: a sparse index is read as complete, and folders collapsed in it go unseen."""
        self.assertTrue(ab.hook_index_walk(index([entry(b"a")], ext=extension(b"sdir", b"")), 20)[2])

    def test_unknown_extensions_are_stepped_over(self):
        """Bug: an extension git adds tomorrow (TREE, REUC, EOIE) fails the read, or hides a link after it."""
        ext = extension(b"TREE", b"x" * 9) + extension(b"link", b"\x01" * 20) + extension(b"FSMN", b"")
        self.assertEqual(ab.hook_index_walk(index([entry(b"a")], ext=ext), 20)[1], "01" * 20)

    def test_a_path_called_link_is_not_an_extension(self):
        """Bug: the reader searches the bytes for link or sdir, and a file name flips the result."""
        self.assertEqual(ab.hook_index_walk(index([entry(b"link"), entry(b"sdir")]), 20), ([b"link", b"sdir"], None, False))


class Refused(unittest.TestCase):
    GOOD = index([entry(b"a"), entry(b"dir/b")], ext=extension(b"TREE", b"xyz"))

    def refused(self, data, size=20):
        for fn in (ab.hook_index_walk, ab.hook_index_parse):
            with self.assertRaises(ValueError, msg=fn.__name__):
                fn(data, size)

    def test_wrong_signature_or_version(self):
        """Bug: any file is read as an index, or a future version is walked with the wrong layout."""
        self.refused(b"XIRC" + self.GOOD[4:])
        for version in (0, 1, 5):
            self.refused(index([entry(b"a")], version=version))

    def test_a_count_the_file_cannot_hold(self):
        """Bug: a planted count of 4 billion is not refused up front, and the hook walks the file to find out."""
        for fn in (ab.hook_index_walk, ab.hook_index_parse):
            with self.assertRaisesRegex(ValueError, "version"):
                fn(index([entry(b"a")], count=2 ** 32 - 1), 20)

    def test_a_count_past_the_entries(self):
        """Bug: a count a little too high reads the extensions as entries."""
        self.refused(index([entry(b"a")] * 2, count=3))

    def test_extension_past_the_end(self):
        """Bug: a planted length reads past the entries into the checksum, or beyond."""
        self.refused(index([entry(b"a")], ext=b"TREE" + struct.pack(">I", 1000) + b"x"))

    def test_trailing_bytes(self):
        """Bug: bytes after the last extension are ignored, and two layouts both read as valid."""
        self.refused(index([entry(b"a")], ext=b"abc"))

    def test_empty_and_short_files(self):
        """Bug: a short file raises struct.error or IndexError, which the hook does not catch."""
        for data in (b"", b"D", b"DIRC", self.GOOD[:12]):
            self.refused(data)

    def test_every_truncation_ends_in_value_error_or_a_result(self):
        """Bug: some cut point raises something else, and a planted index crashes the hook."""
        for k in range(len(self.GOOD)):
            for fn in (ab.hook_index_walk, ab.hook_index_parse):
                try:
                    fn(self.GOOD[:k], 20)
                except ValueError:
                    pass

    def test_random_damage_ends_in_value_error_or_a_result(self):
        """Bug: a damaged field reaches an unguarded read: struct.error, IndexError, or a very long loop."""
        rng = random.Random(2)
        versions = [index([entry(b"a"), entry(b"dir/b")], version=v) for v in (2, 3)]
        for _ in range(3000):
            data = bytearray(rng.choice(versions))
            for _ in range(rng.randrange(1, 5)):
                data[rng.randrange(len(data))] = rng.randrange(256)
            for fn in (ab.hook_index_walk, ab.hook_index_parse):
                try:
                    fn(bytes(data), 20)
                except ValueError:
                    pass


class Checksum(unittest.TestCase):
    def test_a_bad_checksum_is_refused(self):
        """Bug: a damaged index is trusted because its layout happens to parse."""
        data = bytearray(index([entry(b"a")]))
        data[-1] ^= 1
        with self.assertRaises(ValueError):
            ab.hook_index_reads(bytes(data))

    def test_all_zero_trailer_means_no_checksum(self):
        """Bug: index.skipHash repositories read as damaged."""
        data = index([entry(b"a")])[:-20] + bytes(20)
        self.assertEqual(ab.hook_index_reads(data)[0][0], [b"a"])

    def test_short_files(self):
        """Bug: a file shorter than its trailer passes the zero-trailer rule."""
        self.assertFalse(ab.hook_checksum_ok(bytes(20), 20))


if __name__ == "__main__":
    unittest.main()
