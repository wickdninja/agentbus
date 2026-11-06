"""Setup piece plans: what `setup` would do to a file, decided from the file's bytes and never written here. A plan
reads files a clone or a lane can plant, so a link, a damaged marker or a hand edit must end in a refusal or a skip,
never an overwrite. Every test's docstring names the bug it catches."""
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

from load_agentbus import ab, patched

TAG = ab.MANAGED_TAG


def hook(cmd="agentbus hook claude Stop"):
    return {"type": "command", "timeout": 5, "command": f"{cmd} 2>/dev/null || true {TAG}"}


def tree(root):
    """Every path under root with its size, so a test can prove a plan wrote nothing."""
    out = []
    for base, dirs, files in os.walk(root):
        out += [(os.path.join(base, n), os.path.islink(os.path.join(base, n)) or os.path.getsize(os.path.join(base, n))) for n in sorted(dirs + files)]
    return sorted(out)


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.assertIsNone(ab._SETUP_SCOPE)  # planning only: nothing pinned, nothing written

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def write(self, name, data):
        with open(self.path(name), "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode())
        return self.path(name)

    def plan(self, piece, scope="user", uninstall=False):
        before = tree(self.root)
        changes = piece.plan(scope, uninstall)
        self.assertEqual(tree(self.root), before, "a plan wrote something")
        return changes


class JsonEntries(Base):
    def piece(self, name="hooks.json", entries=None):
        want = entries if entries is not None else [("Stop", None, hook()), ("PreToolUse", "Edit|Write", hook("agentbus hook claude PreToolUse"))]
        return ab.JsonEntriesPiece("claude_hooks", lambda scope: self.path(name), lambda scope: want)

    def one(self, piece, **kw):
        changes = self.plan(piece, **kw)
        self.assertEqual(len(changes), 1)
        return changes[0]

    def test_a_new_file_is_installed(self):
        """Bug: a missing file is `unchanged`, and setup reports success having planned nothing."""
        c = self.one(self.piece())
        self.assertEqual((c.action, c.detail), ("installed", "2 hooks"))
        self.assertIsNotNone(c.write)
        self.assertFalse(c.edited)

    def test_a_current_file_is_unchanged(self):
        """Bug: setup rewrites a file already right, taking a backup every run."""
        p = self.piece()
        self.write("hooks.json", json.dumps(p.merge({}, p.entries_for("user")), indent=2) + "\n")
        c = self.one(p)
        self.assertEqual((c.action, c.write), ("unchanged", None))

    def test_a_changed_entry_is_an_update_with_a_backup(self):
        """Bug: an older command is overwritten with no copy of the file as it was."""
        old = self.piece(entries=[("Stop", None, hook("/old/agentbus hook claude Stop"))])
        self.write("hooks.json", json.dumps(old.merge({}, old.entries_for("user"))))
        c = self.one(self.piece())
        self.assertEqual(c.action, "updated")
        self.assertIn(".agentbus-<date and time>.bak", c.backup_hint)

    def test_a_users_own_hooks_are_kept(self):
        """Bug: the merge replaces the whole event, and a user's own Stop hook is deleted."""
        mine = {"type": "command", "command": "my-script"}
        doc = {"model": "x", "hooks": {"Stop": [{"hooks": [mine]}]}}
        got = self.piece().merge(doc, self.piece().entries_for("user"))
        self.assertEqual(got["model"], "x")
        self.assertEqual(got["hooks"]["Stop"][0], {"hooks": [mine]})
        self.assertEqual(len(got["hooks"]["Stop"]), 2)
        self.assertEqual(doc["hooks"]["Stop"], [{"hooks": [mine]}], "the input document was changed")

    def test_uninstall_removes_only_tagged_hooks(self):
        """Bug: uninstall removes a user's hook that sits in the same group as ours."""
        mine = {"type": "command", "command": "my-script"}
        doc = {"hooks": {"Stop": [{"hooks": [mine, hook()]}, {"hooks": [hook()]}], "Other": [{"hooks": [mine]}]}}
        got = self.piece().merge(doc, [])
        self.assertEqual(got, {"hooks": {"Stop": [{"hooks": [mine]}], "Other": [{"hooks": [mine]}]}})

    def test_a_tag_must_end_the_command(self):
        """Bug: a user's command that merely mentions the tag is treated as ours and removed."""
        self.assertTrue(ab.JsonEntriesPiece.tagged(hook()))
        self.assertTrue(ab.JsonEntriesPiece.tagged({"command": "x " + TAG + "  \n"}))
        for h in ({"command": TAG + " but more"}, {"command": "x"}, {"command": 5}, {}, None, "x", []):
            self.assertFalse(ab.JsonEntriesPiece.tagged(h), h)

    def test_duplicates_collapse_to_one_group(self):
        """Bug: running setup twice by hand stacks two copies of every hook, and each runs twice."""
        doc = {"hooks": {"Stop": [{"hooks": [hook()]}, {"hooks": [hook()]}]}}
        got = self.piece().merge(doc, [("Stop", None, hook())])
        self.assertEqual(len(got["hooks"]["Stop"]), 1)

    def test_uninstall_of_a_file_that_is_all_ours_can_delete_it(self):
        """Bug: remove_empty is ignored and an empty hooks.json is left, or the file goes though a user key remains."""
        p = self.piece()
        p.remove_empty = True
        self.write("hooks.json", json.dumps(p.merge({}, p.entries_for("user"))))
        c = self.one(p, uninstall=True)
        self.assertEqual(c.action, "removed")
        self.assertIn("and the file", c.line)
        self.write("hooks.json", json.dumps(p.merge({"keep": 1}, p.entries_for("user"))))
        c = self.one(p, uninstall=True)
        self.assertNotIn("and the file", c.line)

    def test_uninstall_without_a_file_or_entries_is_a_no_op(self):
        """Bug: uninstall of nothing creates the file or reports a removal."""
        self.assertEqual(self.one(self.piece(), uninstall=True).action, "unchanged")
        self.write("hooks.json", "{}")
        self.assertEqual(self.one(self.piece(), uninstall=True).action, "unchanged")

    def test_refusals(self):
        """Bug: a file setup cannot understand is overwritten: not JSON, a list, duplicate keys, a float, NaN, a wrong
        hooks shape, invalid UTF-8, a link, a folder in the way."""
        cases = {"not json": "{", "a list": "[]", "duplicate key": '{"a": 1, "a": 2}', "float": '{"a": 1.5}', "nan": '{"a": NaN}',
                 "hooks is a list": '{"hooks": []}', "event is not a list": '{"hooks": {"Stop": {}}}', "utf8": b"\xff\xfe",
                 "deep": "[" * 100000}
        for name, data in cases.items():
            self.write("hooks.json", data)
            c = self.one(self.piece())
            self.assertEqual(c.action, "refused", name)
            self.assertIsNone(c.write, name)
            self.assertTrue(c.line.endswith("not changed."), name)
        os.unlink(self.path("hooks.json"))
        os.symlink(self.write("real.json", "{}"), self.path("hooks.json"))
        self.assertEqual(self.one(self.piece()).action, "refused")
        os.unlink(self.path("hooks.json"))
        os.mkdir(self.path("hooks.json"))
        self.assertEqual(self.one(self.piece()).action, "refused")

    def test_a_parent_that_cannot_hold_the_file_is_refused(self):
        """Bug: setup tries to create a folder under a file or a dangling link and dies half way."""
        self.write("blocked", "x")
        os.symlink(self.path("gone"), self.path("dangling"))
        for parent in ("blocked", "dangling"):
            piece = ab.JsonEntriesPiece("p", lambda s, parent=parent: self.path(parent, "hooks.json"), lambda s: [("Stop", None, hook())])
            c = self.one(piece)
            self.assertEqual((c.action, c.write), ("refused", None), parent)
            self.assertTrue(c.line.endswith("not changed."), parent)
        self.assertIn("is not a folder", c.line)

    def test_indent_and_final_newline_are_kept(self):
        """Bug: setup reformats the user's file, so every setup is a diff of the whole thing."""
        self.write("hooks.json", '{\n\t"model": "x"}')
        body = []
        piece = self.piece()
        c = self.one(piece)
        with mock.patch.object(ab, "setup_guard"), mock.patch.object(ab, "setup_backup_write", lambda p, r: "b"), \
                mock.patch.object(ab, "setup_test_fail"), mock.patch.object(ab, "setup_write", lambda p, d, m: body.append(d)):
            c.write()
        text = body[0].decode()
        self.assertTrue(text.startswith('{\n\t"model"'), text)
        self.assertFalse(text.endswith("\n"))

    def test_the_write_checks_the_file_is_still_what_was_planned(self):
        """Bug: the plan's write runs with no guard, and a file changed after planning is overwritten."""
        self.write("hooks.json", "{}")
        c = self.one(self.piece())
        seen = []
        with mock.patch.object(ab, "setup_guard", lambda p, raw, point: seen.append((p, raw, point))), \
                mock.patch.object(ab, "setup_backup_write", lambda p, r: "b"), mock.patch.object(ab, "setup_test_fail"), \
                mock.patch.object(ab, "setup_write", lambda *a: None):
            c.write()
        self.assertEqual(seen, [(self.path("hooks.json"), b"{}", "setup-before-write-entries")])

    def test_project_scope_refuses_a_linked_folder(self):
        """Bug: a clone's .claude that is a link makes setup write wherever the clone pointed it."""
        outside = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, outside, True)
        old = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, old)
        os.symlink(outside, self.path(".claude"))
        piece = ab.JsonEntriesPiece("p", lambda s: os.path.join(os.getcwd(), ".claude", "settings.json"), lambda s: [("Stop", None, hook())])
        c = piece.plan("project")[0]
        self.assertEqual(c.action, "refused")
        self.assertEqual(os.listdir(outside), [])

    def test_check_names_the_state(self):
        """Bug: doctor reports a stale hook file as ok, or a missing one as a problem."""
        p = self.piece()
        self.assertEqual(p.check("user")[0][1], "missing")
        self.write("hooks.json", "{")
        self.assertEqual(p.check("user")[0][1], "problem")
        self.write("hooks.json", json.dumps(p.merge({}, [("Stop", None, hook("/old/agentbus hook claude Stop"))])))
        self.assertEqual(p.check("user")[0][1], "stale")
        self.write("hooks.json", json.dumps(p.merge({}, p.entries_for("user"))))
        self.assertEqual(p.check("user")[0][1], "ok")


def block(text="Use agentbus.\n"):
    return f"{ab.AGENTS_BEGIN}\n{text}{ab.AGENTS_END}\n"


class TextBlock(Base):
    TEXT = "Use agentbus.\n"

    def piece(self):
        p = ab.TextBlockPiece("codex", "AGENTS.md", self.TEXT)
        p.path = lambda scope: self.path("AGENTS.md")
        return p

    def one(self, **kw):
        changes = self.plan(self.piece(), **kw)
        self.assertEqual(len(changes), 1)
        return changes[0]

    def planned_text(self, change, old=None):
        """The file text the change would write."""
        out = []
        with mock.patch.object(ab, "setup_guard"), mock.patch.object(ab, "setup_backup_write", lambda p, r: "b"), \
                mock.patch.object(ab, "setup_test_fail"), mock.patch.object(ab, "setup_write", lambda p, d, m: out.append(d.decode())):
            change.write()
        return out[0]

    def test_a_new_file_gets_the_block(self):
        """Bug: setup writes no markers, and the next run cannot find its own block."""
        c = self.one()
        self.assertEqual((c.action, self.planned_text(c)), ("installed", block()))

    def test_the_block_is_appended_after_the_users_text(self):
        """Bug: the user's AGENTS.md is replaced, or the block is glued to its last line."""
        self.write("AGENTS.md", "# Mine\nrule\n")
        self.assertEqual(self.planned_text(self.one()), "# Mine\nrule\n\n" + block())

    def test_a_current_block_is_unchanged(self):
        """Bug: setup rewrites an up to date file and takes a backup every run."""
        self.write("AGENTS.md", "top\n" + block() + "bottom\n")
        c = self.one()
        self.assertEqual((c.action, c.write), ("unchanged", None))

    def test_an_old_shipped_block_is_updated_without_a_backup(self):
        """Bug: a text an earlier release shipped counts as a user edit and is backed up on every upgrade."""
        old = "Old text.\n"
        self.write("AGENTS.md", "top\n" + block(old) + "bottom\n")
        with patched("AGENTS_SHA256_HISTORY", (ab.sha256_hex(old.encode()),)):
            c = self.one()
        self.assertEqual((c.action, c.edited), ("updated", False))
        self.assertEqual(self.planned_text(c), "top\n" + block() + "bottom\n")

    def test_the_users_line_endings_are_kept(self):
        """Bug: a CRLF file gets LF lines mixed in."""
        self.write("AGENTS.md", b"top\r\n" + block("Old.\n").replace("\n", "\r\n").encode() + b"end\r\n")
        text = self.planned_text(self.one())
        self.assertEqual(text, "top\r\n" + block().replace("\n", "\r\n") + "end\r\n")

    def test_markers_inside_a_fence_are_the_users_text(self):
        """Bug: an example block in a code fence is taken as ours, and updated or removed."""
        fenced = f"```\n{block()}```\n"
        self.write("AGENTS.md", fenced)
        c = self.one()
        self.assertEqual(c.action, "installed")
        self.assertTrue(self.planned_text(c).startswith(fenced))
        self.assertEqual(self.one(uninstall=True).action, "unchanged")

    def test_an_indented_marker_is_not_ours(self):
        """Bug: an indented example in a list item is replaced."""
        self.write("AGENTS.md", f"  {ab.AGENTS_BEGIN}\n  {ab.AGENTS_END}\n")
        self.assertEqual(self.one(uninstall=True).action, "unchanged")

    def test_damaged_markers_are_refused(self):
        """Bug: one marker, two blocks or the end before the begin are guessed at, and text between is lost."""
        for data in (ab.AGENTS_BEGIN + "\nx\n", ab.AGENTS_END + "\n", block() + block(), ab.AGENTS_END + "\n" + ab.AGENTS_BEGIN + "\n"):
            self.write("AGENTS.md", data)
            c = self.one()
            self.assertEqual(c.action, "refused", data)
            self.assertIn("damaged", c.line)

    def test_an_unclosed_fence_blocks_an_append(self):
        """Bug: the block is appended inside the user's open code fence, where it renders as code and never loads."""
        self.write("AGENTS.md", "```\nunclosed\n")
        c = self.one()
        self.assertEqual(c.action, "refused")
        self.assertIn("unclosed code fence", c.line)

    def test_uninstall_removes_an_unedited_block_and_its_separator(self):
        """Bug: uninstall leaves a blank line behind each time, and a file grows by one line per cycle."""
        self.write("AGENTS.md", "# Mine\n\n" + block())
        self.assertEqual(self.planned_text(self.one(uninstall=True)), "# Mine\n")

    def test_uninstall_keeps_an_edited_block(self):
        """Bug: a block the user edited is deleted with their work in it."""
        self.write("AGENTS.md", block("My own words.\n"))
        c = self.one(uninstall=True)
        self.assertEqual((c.action, c.write), ("skipped", None))
        self.assertIn("edited", c.line)

    def test_an_edited_block_is_backed_up_before_an_update(self):
        """Bug: an update overwrites a hand-edited block with no copy of the file."""
        self.write("AGENTS.md", block("My own words.\n"))
        c = self.one()
        self.assertEqual((c.action, c.edited), ("updated", True))
        self.assertIn("your edited copy is saved as", c.line)

    def test_refusals(self):
        """Bug: a link, a folder, a fifo or text that is not UTF-8 is read through or overwritten."""
        os.symlink(self.write("real.md", "x"), self.path("AGENTS.md"))
        self.assertEqual(self.one().action, "refused")
        os.unlink(self.path("AGENTS.md"))
        os.mkdir(self.path("AGENTS.md"))
        self.assertEqual(self.one().action, "refused")
        os.rmdir(self.path("AGENTS.md"))
        self.write("AGENTS.md", b"\xff\xfe")
        self.assertIn("UTF-8", self.one().line)

    def test_scan_finds_markers_by_line_outside_fences(self):
        """Bug: scan counts a marker in prose, in a tilde fence or after a longer closing fence."""
        text = f"a\n~~~\n{ab.AGENTS_BEGIN}\n~~~\n{ab.AGENTS_BEGIN}\nx\n{ab.AGENTS_END}\n````\n{ab.AGENTS_END}\n```\n{ab.AGENTS_END}\n````\n"
        lines, begins, ends, open_fence = ab.TextBlockPiece.scan(text)
        self.assertEqual((begins, ends, open_fence), ([4], [6], False))
        self.assertEqual("".join(lines), text)
        self.assertTrue(ab.TextBlockPiece.scan("```\nx\n")[3])
        self.assertTrue(ab.TextBlockPiece.scan("````\n```\n")[3])
        self.assertFalse(ab.TextBlockPiece.scan("```a`b\nx\n")[3])  # a backtick fence's info string has no backtick


class SkillFile(Base):
    def setUp(self):
        super().setUp()
        patch = mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": self.root})
        patch.start()
        self.addCleanup(patch.stop)
        self.skill = self.path("skills", "agentbus", "SKILL.md")

    def one(self, **kw):
        changes = self.plan(ab.SkillFilePiece(), **kw)
        self.assertEqual(len(changes), 1)
        return changes[0]

    def put(self, data):
        os.makedirs(os.path.dirname(self.skill), exist_ok=True)
        with open(self.skill, "wb") as f:
            f.write(data)

    def test_the_skill_is_installed_where_claude_reads_it(self):
        """Bug: the skill lands outside <config>/skills/agentbus, and Claude Code never loads it."""
        c = self.one()
        self.assertEqual((c.action, c.path), ("installed", self.skill))

    def test_the_current_text_is_unchanged(self):
        """Bug: an up to date skill is rewritten every run."""
        self.put(ab.SKILL_TEXT.encode())
        self.assertEqual(self.one().action, "unchanged")

    def test_a_file_agentbus_did_not_write_is_refused(self):
        """Bug: a user's own SKILL.md is overwritten because it sits at our path."""
        self.put(b"my own skill\n")
        c = self.one()
        self.assertEqual(c.action, "refused")
        self.assertIn("was not written by agentbus", c.line)
        self.assertEqual(self.one(uninstall=True).action, "skipped")

    def test_an_edited_skill_is_backed_up_and_not_removed(self):
        """Bug: a hand-edited skill is replaced without a copy, or deleted by uninstall."""
        self.put(ab.SKILL_TEXT.encode().replace(b"agentbus", b"agentbus!", 1))
        c = self.one()
        self.assertEqual(c.action, "updated")
        self.assertTrue(c.edited)
        self.assertEqual(self.one(uninstall=True).action, "skipped")

    def test_uninstall_removes_the_current_skill_and_its_folder(self):
        """Bug: uninstall leaves an empty skills/agentbus folder, or removes a folder that holds other files."""
        self.put(ab.SKILL_TEXT.encode())
        self.assertEqual(self.one(uninstall=True).action, "removed")
        self.assertTrue(self.one(uninstall=True).path.endswith(os.sep))
        with open(os.path.join(os.path.dirname(self.skill), "notes.txt"), "w"):
            pass
        self.assertEqual(self.one(uninstall=True).path, self.skill)

    def test_uninstall_when_not_installed_says_so(self):
        """Bug: uninstall of nothing creates a folder or reports a removal."""
        self.assertEqual(self.one(uninstall=True).action, "unchanged")

    def test_a_symlinked_skill_file_is_refused(self):
        """Bug: setup writes through a link and overwrites whatever it points at."""
        os.makedirs(os.path.dirname(self.skill))
        target = self.path("elsewhere.md")
        with open(target, "w"):
            pass
        os.symlink(target, self.skill)
        self.assertEqual(self.one().action, "refused")

    def test_a_folder_that_is_a_file_is_refused(self):
        """Bug: setup tries to make a folder where a file sits."""
        os.makedirs(self.path("skills"))
        with open(self.path("skills", "agentbus"), "w"):
            pass
        self.assertEqual(self.one().action, "refused")

    def test_a_link_to_something_else_is_refused(self):
        """Bug: a symlinked skill folder that is not ours is replaced."""
        os.makedirs(self.path("skills"))
        other = self.path("other")
        os.mkdir(other)
        os.symlink(other, self.path("skills", "agentbus"))
        c = self.one()
        self.assertEqual(c.action, "refused")
        self.assertIn("not an agentbus skill", c.line)

    def test_a_dangling_old_install_link_is_replaced(self):
        """Bug: the link the old README line left behind blocks every later setup."""
        os.makedirs(self.path("skills"))
        os.symlink(self.path("gone", "skill"), self.path("skills", "agentbus"))
        changes = self.plan(ab.SkillFilePiece())
        self.assertEqual([c.action for c in changes], ["replaced_link", "installed"])

    def test_check_names_the_state(self):
        """Bug: doctor calls a stale skill ok."""
        p = ab.SkillFilePiece()
        self.assertEqual(p.check("user")[0][1], "missing")
        self.put(b"mine\n")
        self.assertEqual(p.check("user")[0][1], "problem")
        self.put(ab.SKILL_TEXT.encode().replace(b"agentbus", b"agentbus!", 1))
        self.assertEqual(p.check("user")[0][1], "stale")
        self.put(ab.SKILL_TEXT.encode())
        self.assertEqual(p.check("user")[0][1], "ok")


if __name__ == "__main__":
    unittest.main()
