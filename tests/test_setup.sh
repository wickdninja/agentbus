#!/bin/bash
set -euo pipefail
# agentbus setup claude|codex: the skill for Claude Code, the AGENTS.md block for Codex. Everything runs
# in a temp HOME; no test touches a real config folder. Output lines are asserted with grep -F.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR CODEX_HOME AGENTBUS_TEST_SETUP_FAIL AGENTBUS_TEST_SETUP_JSON
W="$T/work"; mkdir -p "$W"
# Every fixed FAIL text in this file belongs to one assertion, so a FAIL line (and a mutation's expect in
# tests/mutations.json) points at exactly one place. Bug it catches: three asserts all failed with "update line".
dups=$(grep -oE '(^|[^_a-z])fail "[^"$]*"' "${BASH_SOURCE[0]}" | sed 's/^[^f]*//' | sort | uniq -d)
[ -z "$dups" ] || fail "FAIL texts used by more than one assertion: $dups"
ROOT="$(cd "$(dirname "$BIN")/.." && pwd)"
SKILL_DIR="$HOME/.claude/skills/agentbus"

# run_setup ARGS...: OUT is stdout+stderr, RC the exit status, from the work directory.
run_setup() { RC=0; OUT=$(cd "$W" && "${AB[@]}" setup "$@" 2>&1) || RC=$?; }
# hash_tree DIR: one hash over every path, file content, link target and mode (no mtimes).
hash_tree() { "$PY" -I - "$1" <<'PY'
import hashlib, os, sys
h = hashlib.sha256()
for d, dirs, files in os.walk(sys.argv[1]):
    dirs.sort()
    for n in sorted(files + dirs):
        p = os.path.join(d, n)
        st = os.lstat(p)
        h.update(p.encode()); h.update(oct(st.st_mode).encode())
        if os.path.islink(p): h.update(os.readlink(p).encode())
        elif os.path.isfile(p): h.update(open(p, 'rb').read())
print(h.hexdigest())
PY
}
has() { grep -qxF -- "$1" <<<"$OUT" || { echo "output was:" >&2; echo "$OUT" >&2; fail "missing line: $1"; }; }
lacks() { ! grep -qF -- "$1" <<<"$OUT" || { echo "output was:" >&2; echo "$OUT" >&2; fail "unexpected: $1"; }; }
reset() { rm -rf "$HOME" "$W"; mkdir -p "$HOME" "$W"; }
SKILL_BYTES=$(agentbus skill | wc -c | tr -d ' ')
SIZE=$("$PY" -c "print(f'{$SKILL_BYTES:,}')")
BLOCK_LINES=4

echo "TEST: setup claude installs the skill and prints the documented lines"
run_setup claude
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
has "agentbus setup claude (user)"
has "  + ~/.claude/skills/agentbus/SKILL.md   installed, $SIZE bytes"
has "done. Start a new Claude Code session to load it."
has "next: cd your-repo && agentbus init ."
agentbus skill | cmp -s - "$SKILL_DIR/SKILL.md" || fail "the installed file is not what agentbus skill prints"
[ "$(mode "$SKILL_DIR/SKILL.md")" = 600 ] || fail "SKILL.md mode $(mode "$SKILL_DIR/SKILL.md")"
[ "$(mode "$SKILL_DIR")" = 700 ] || fail "skill folder mode $(mode "$SKILL_DIR")"
[ "$(mode "$HOME/.claude")" = 700 ] || fail ".claude mode $(mode "$HOME/.claude")"
ok "installed, 0600 file in 0700 folders"

echo
echo "TEST: a second run prints 'unchanged' for every line and leaves bytes and mtimes equal"
before=$("$PY" -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_mtime_ns, s.st_size)' "$SKILL_DIR/SKILL.md"); h1=$(hash_tree "$HOME")
sleep 0.05
run_setup claude
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
has "  = ~/.claude/skills/agentbus/SKILL.md   unchanged"
lacks "installed"
after=$("$PY" -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_mtime_ns, s.st_size)' "$SKILL_DIR/SKILL.md")
[ "$before" = "$after" ] || fail "mtime or size changed: $before -> $after"
[ "$h1" = "$(hash_tree "$HOME")" ] || fail "the tree changed on a second run"
ok "idempotent"

echo
echo "TEST: --dry-run writes nothing (tree hash equal) and prints 'would' lines identical in paths to the real run"
reset
h0=$(hash_tree "$HOME")
run_setup claude --dry-run
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
has "  + would install ~/.claude/skills/agentbus/SKILL.md ($SIZE bytes)"
[ "$(tail -n 1 <<<"$OUT")" = "dry run: nothing was written." ] || fail "last line: $(tail -n 1 <<<"$OUT")"
[ "$h0" = "$(hash_tree "$HOME")" ] || fail "--dry-run wrote something"
[ ! -e "$HOME/.claude" ] || fail "--dry-run created ~/.claude"
dry_paths=$(grep -o '~/[^ ]*' <<<"$OUT" | sort -u)
run_setup claude
real_paths=$(grep -o '~/[^ ]*' <<<"$OUT" | sort -u)
[ "$dry_paths" = "$real_paths" ] || fail "paths differ: dry [$dry_paths] real [$real_paths]"
ok "dry run writes nothing and names the same paths"

echo
echo "TEST: --uninstall removes the skill directory and leaves other files in ~/.claude alone"
echo keep >"$HOME/.claude/keep.txt"; mkdir -p "$HOME/.claude/skills/other"; echo x >"$HOME/.claude/skills/other/SKILL.md"
run_setup claude --uninstall
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
has "  - removed ~/.claude/skills/agentbus/"
[ ! -e "$SKILL_DIR" ] || fail "the skill folder is still there"
[ "$(cat "$HOME/.claude/keep.txt")" = keep ] && [ -f "$HOME/.claude/skills/other/SKILL.md" ] || fail "other files were touched"
run_setup claude --uninstall
[ "$RC" = 0 ] || fail "a second uninstall exited $RC"
has "  = ~/.claude/skills/agentbus/SKILL.md   not installed"
ok "uninstall removes only the skill"

echo
echo "TEST: a custom SKILL.md without the marker is refused and left byte-identical; nothing else is written (preflight)"
reset
mkdir -p "$SKILL_DIR"; printf '# my own skill\n' >"$SKILL_DIR/SKILL.md"
export AGENTBUS_TEST_SETUP_JSON="$T/hooks.json"
h0=$(hash_tree "$HOME")
run_setup claude
[ "$RC" = 1 ] || fail "exit $RC, wanted 1: $OUT"
has "  ! ~/.claude/skills/agentbus/SKILL.md exists and was not written by agentbus; not changed. Move it aside, or run: agentbus setup claude --scope project"
[ "$(cat "$SKILL_DIR/SKILL.md")" = "# my own skill" ] || fail "the custom skill changed"
[ "$h0" = "$(hash_tree "$HOME")" ] || fail "something was written beside a custom skill"
[ ! -e "$T/hooks.json" ] || fail "a later piece wrote despite the refusal"
unset AGENTBUS_TEST_SETUP_JSON
ok "refused; byte-identical; the second piece wrote nothing"

echo
echo "TEST: a marked SKILL.md the user edited is saved as SKILL.md.agentbus-<stamp>.bak before every update (each edit survives); uninstall leaves an edited file in place and says so"
reset
run_setup claude >/dev/null
"$PY" - "$SKILL_DIR/SKILL.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, 'w').write(s.replace('<!-- agentbus:managed -->', 'My own rule.\n\n<!-- agentbus:managed -->'))
PY
cp "$SKILL_DIR/SKILL.md" "$T/edited1"
run_setup claude --uninstall
[ "$RC" = 0 ] || fail "uninstall of an edited file exited $RC"
has "  ! ~/.claude/skills/agentbus/SKILL.md   modified; not removed"
cmp -s "$T/edited1" "$SKILL_DIR/SKILL.md" || fail "uninstall changed an edited file"
run_setup claude
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
grep -qE "updated, $SIZE bytes; your edited copy is saved as SKILL\.md\.agentbus-[0-9]{8}T[0-9]{6}\.[0-9]{6}Z(-[0-9]+)?\.bak" <<<"$OUT" || { echo "$OUT" >&2; fail "update line: the edited SKILL.md was not saved as a .bak"; }
bak1=$(ls "$SKILL_DIR"/SKILL.md.agentbus-*.bak); [ "$(wc -l <<<"$bak1" | tr -d ' ')" = 1 ] || fail "expected one backup, got: $bak1"
cmp -s "$T/edited1" "$bak1" || fail "the backup is not the edited file"
agentbus skill | cmp -s - "$SKILL_DIR/SKILL.md" || fail "the update did not install the current skill"
# A second edit must survive too (the old rule kept one backup and silently deleted this one).
printf 'EDIT-TWO second edit\n<!-- agentbus:managed -->\n' >>"$SKILL_DIR/SKILL.md"; cp "$SKILL_DIR/SKILL.md" "$T/edited2"
run_setup claude >/dev/null
[ "$(ls "$SKILL_DIR"/SKILL.md.agentbus-*.bak | wc -l | tr -d ' ')" = 2 ] || fail "the second edit got no backup: $(ls "$SKILL_DIR")"
grep -lF 'EDIT-TWO' "$SKILL_DIR"/SKILL.md.agentbus-*.bak >/dev/null || fail "EDIT-TWO was lost"
cmp -s "$T/edited1" "$bak1" || fail "the first backup changed"
for b in "$SKILL_DIR"/SKILL.md.agentbus-*.bak; do cmp -s "$T/edited2" "$b" && found2=1; done; [ "${found2:-}" = 1 ] || fail "no backup is the second edited file"
agentbus skill | cmp -s - "$SKILL_DIR/SKILL.md" || fail "the second update did not install the current skill"
ok "every edited copy is backed up with its own name; uninstall keeps an edited file"

echo
echo "TEST: the old install line's symlink is replaced, the old target is printed, the target is untouched; an unrelated symlink is refused"
reset
mkdir -p "$T/clone/skill" "$HOME/.claude/skills"
printf -- '---\nname: agentbus\n---\nold\n' >"$T/clone/skill/SKILL.md"
ln -s "$T/clone/skill" "$SKILL_DIR"
h_clone=$(hash_tree "$T/clone")
run_setup claude
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
has "  ~ ~/.claude/skills/agentbus   replaced the link to $T/clone/skill (the old install line)"
has "  + ~/.claude/skills/agentbus/SKILL.md   installed, $SIZE bytes"
[ ! -L "$SKILL_DIR" ] && [ -d "$SKILL_DIR" ] || fail "the link was not replaced by a real folder"
[ "$h_clone" = "$(hash_tree "$T/clone")" ] || fail "the link's target was modified"
rm -rf "$SKILL_DIR"; ln -s "$T/gone/skill" "$SKILL_DIR"
run_setup claude
[ "$RC" = 0 ] || fail "dangling link: exit $RC: $OUT"
has "  ~ ~/.claude/skills/agentbus   replaced the link to $T/gone/skill (the old install line)"
rm -rf "$SKILL_DIR"; mkdir -p "$T/unrelated"; echo precious >"$T/unrelated/notes.txt"; ln -s "$T/unrelated" "$SKILL_DIR"
run_setup claude
[ "$RC" = 1 ] || fail "unrelated link: exit $RC, wanted 1: $OUT"
has "  ! ~/.claude/skills/agentbus is a symlink to something that is not an agentbus skill; not changed. Remove it or run: agentbus setup claude --scope project"
[ "$(readlink "$SKILL_DIR")" = "$T/unrelated" ] && [ "$(cat "$T/unrelated/notes.txt")" = precious ] || fail "the unrelated link or its target changed"
ok "old links migrate; unrelated links are refused"

echo
echo "TEST: a symlinked ~/.claude/skills is followed; a symlinked SKILL.md is refused with the path named and nothing written"
reset
mkdir -p "$HOME/.claude" "$T/realskills"; ln -s "$T/realskills" "$HOME/.claude/skills"
run_setup claude
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
[ -f "$T/realskills/agentbus/SKILL.md" ] || fail "not installed through the linked skills folder"
reset
mkdir -p "$SKILL_DIR"; echo secret >"$T/elsewhere"; ln -s "$T/elsewhere" "$SKILL_DIR/SKILL.md"
h0=$(hash_tree "$HOME")
run_setup claude
[ "$RC" = 1 ] || fail "exit $RC, wanted 1: $OUT"
has "  ! ~/.claude/skills/agentbus/SKILL.md is a symlink; not changed. Remove it or run: agentbus setup claude --scope project"
[ "$(cat "$T/elsewhere")" = secret ] && [ "$h0" = "$(hash_tree "$HOME")" ] || fail "something was written through the planted link"
ok "linked parent followed; linked SKILL.md refused"

echo
echo "TEST: CLAUDE_CONFIG_DIR relocates the skill; ~/.claude is not touched"
reset
CLAUDE_CONFIG_DIR="$T/cfg" run_setup claude
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
[ -f "$T/cfg/skills/agentbus/SKILL.md" ] && [ ! -e "$HOME/.claude" ] || fail "CLAUDE_CONFIG_DIR was not honoured"
grep -qF "installed, $SIZE bytes" <<<"$OUT" || fail "no install line: $OUT"
ok "CLAUDE_CONFIG_DIR honoured"

echo
echo "TEST: setup codex adds the marked block to an existing AGENTS.md without changing the text around it; an unmodified uninstall restores the original bytes"
reset
mkdir -p "$HOME/.codex"
printf '# My rules\n\nBe kind.\n' >"$HOME/.codex/AGENTS.md"; cp "$HOME/.codex/AGENTS.md" "$T/agents.orig"
run_setup codex
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
has "agentbus setup codex (user)"
has "  + ~/.codex/AGENTS.md   added the agentbus block ($BLOCK_LINES lines)"
has "done. Start a new Codex session to load it."
head -c "$(wc -c <"$T/agents.orig")" "$HOME/.codex/AGENTS.md" | cmp -s - "$T/agents.orig" || fail "the text before the block changed"
[ "$(grep -c 'agentbus:begin' "$HOME/.codex/AGENTS.md")" = 1 ] && [ "$(grep -c 'agentbus:end' "$HOME/.codex/AGENTS.md")" = 1 ] || fail "markers"
agentbus skill --agents-md >"$T/block"
"$PY" -I - "$HOME/.codex/AGENTS.md" "$T/block" <<'PY'
import sys
t = open(sys.argv[1]).read(); b = open(sys.argv[2]).read()
assert t.endswith('\n\n<!-- agentbus:begin -->\n' + b + '<!-- agentbus:end -->\n'), repr(t)
PY
run_setup codex
has "  = ~/.codex/AGENTS.md   unchanged"
run_setup codex --uninstall
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
cmp -s "$T/agents.orig" "$HOME/.codex/AGENTS.md" || fail "an unmodified round trip did not restore the original bytes"
printf 'no trailing newline' >"$HOME/.codex/AGENTS.md"; cp "$HOME/.codex/AGENTS.md" "$T/agents.orig"
run_setup codex >/dev/null; run_setup codex --uninstall >/dev/null
cmp -s "$T/agents.orig" "$HOME/.codex/AGENTS.md" || fail "a file without a trailing newline did not round-trip"
ok "block added and removed; original bytes restored"

echo
echo "TEST: an edit made elsewhere after install survives uninstall; an empty or absent AGENTS.md ends up empty, not deleted; a stale block is updated in place"
reset
mkdir -p "$HOME/.codex"; printf 'top\n' >"$HOME/.codex/AGENTS.md"
run_setup codex >/dev/null
printf 'first line by me\n%s' "$(cat "$HOME/.codex/AGENTS.md")" >"$HOME/.codex/AGENTS.md"; printf '\nlast line by me\n' >>"$HOME/.codex/AGENTS.md"
run_setup codex --uninstall >/dev/null
grep -qx 'first line by me' "$HOME/.codex/AGENTS.md" && grep -qx 'last line by me' "$HOME/.codex/AGENTS.md" && grep -qx top "$HOME/.codex/AGENTS.md" || fail "an edit was lost"
grep -q 'agentbus' "$HOME/.codex/AGENTS.md" && fail "the block is still there"
reset
run_setup codex >/dev/null; [ -f "$HOME/.codex/AGENTS.md" ] || fail "AGENTS.md not created"
run_setup codex --uninstall >/dev/null
[ -f "$HOME/.codex/AGENTS.md" ] && [ ! -s "$HOME/.codex/AGENTS.md" ] || fail "a file that held only our block must be left empty"
reset; mkdir -p "$HOME/.codex"; : >"$HOME/.codex/AGENTS.md"
run_setup codex >/dev/null; run_setup codex --uninstall >/dev/null
[ -f "$HOME/.codex/AGENTS.md" ] && [ ! -s "$HOME/.codex/AGENTS.md" ] || fail "an empty file did not round-trip"
reset; run_setup codex >/dev/null
sed -i.orig 's/^## agentbus$/## agentbus (old)/' "$HOME/.codex/AGENTS.md"; rm "$HOME/.codex/AGENTS.md.orig"
run_setup codex
grep -qF "~/.codex/AGENTS.md   updated the agentbus block ($BLOCK_LINES lines)" <<<"$OUT" || { echo "$OUT" >&2; fail "update line: a stale block was not updated in place"; }
agentbus skill --agents-md | cmp -s - <(sed -n '/agentbus:begin/,/agentbus:end/p' "$HOME/.codex/AGENTS.md" | sed '1d;$d') || fail "the stale block was not refreshed"
ok "edits elsewhere survive; empty files stay; stale block updated in place"

echo
echo "TEST: duplicate, unbalanced or reversed markers are refused and the file is left alone"
for bad in '<!-- agentbus:begin -->\nx\n<!-- agentbus:end -->\n<!-- agentbus:begin -->\nx\n<!-- agentbus:end -->\n' \
           '<!-- agentbus:begin -->\nx\n' '<!-- agentbus:end -->\n' '<!-- agentbus:end -->\nx\n<!-- agentbus:begin -->\n'; do
  reset; mkdir -p "$HOME/.codex"; printf "$bad" >"$HOME/.codex/AGENTS.md"; cp "$HOME/.codex/AGENTS.md" "$T/bad.orig"
  for flag in "" "--uninstall"; do
    run_setup codex $flag
    [ "$RC" = 1 ] || fail "markers [$bad] $flag: exit $RC: $OUT"
    has "  ! ~/.codex/AGENTS.md has damaged agentbus markers; not changed."
    cmp -s "$T/bad.orig" "$HOME/.codex/AGENTS.md" || fail "a damaged file was changed"
  done
done
ok "damaged markers refused"

echo
echo "TEST: json_entries: key order, indent and trailing newline are kept; user edits survive uninstall; each change saves the previous file as <name>.agentbus-<stamp>.bak and none is restored; unparsable JSON is refused unchanged"
reset
J="$T/hooks.json"; export AGENTBUS_TEST_SETUP_JSON="$J"
"$PY" - "$J" <<'PY'
import sys
open(sys.argv[1], 'w').write('{\n    "zeta": 1,\n    "hooks": {\n        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo mine"}]}]\n    },\n    "alpha": [1, 2]\n}\n')
PY
cp "$J" "$T/j.orig"
run_setup claude
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
grep -qF "$J   added 1 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "json install line"; }
"$PY" -I - "$J" <<'PY'
import json, sys
t = open(sys.argv[1]).read()
d = json.loads(t)
assert list(d) == ['zeta', 'hooks', 'alpha'], list(d)
assert t.endswith('}\n') and '\n    "zeta"' in t, repr(t[:40])
assert list(d['hooks']) == ['PreToolUse', 'SessionStart'], list(d['hooks'])
assert d['hooks']['PreToolUse'][0]['hooks'][0]['command'] == 'echo mine'
assert d['hooks']['SessionStart'][0]['hooks'][0]['command'].endswith('# agentbus:managed')
PY
jbaks() { ls "$J".agentbus-*.bak 2>/dev/null | sort; }
[ "$(jbaks | wc -l | tr -d ' ')" = 1 ] && cmp -s "$T/j.orig" "$(jbaks | head -n 1)" || fail "the first modification did not save the original: $(jbaks)"
run_setup claude; grep -qF "$J   unchanged" <<<"$OUT" || fail "second json run not unchanged: $OUT"
"$PY" - "$J" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d['added_by_user'] = {'k': 'v'}
d['hooks']['PreToolUse'].append({'matcher': 'Edit', 'hooks': [{'type': 'command', 'command': 'echo late'}]})
open(p, 'w').write(json.dumps(d, indent=4) + '\n')
PY
cp "$J" "$T/j.edited"
run_setup claude --uninstall
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
"$PY" -I - "$J" "$T/j.orig" <<'PY'
import json, sys
now = json.load(open(sys.argv[1])); orig = json.load(open(sys.argv[2]))
orig['added_by_user'] = {'k': 'v'}
orig['hooks']['PreToolUse'].append({'matcher': 'Edit', 'hooks': [{'type': 'command', 'command': 'echo late'}]})
assert now == orig, (now, orig)
PY
[ "$(jbaks | wc -l | tr -d ' ')" = 2 ] || fail "the uninstall must save the file as it was: $(jbaks)"
cmp -s "$T/j.orig" "$(jbaks | head -n 1)" || fail "the first backup changed or was restored"
cmp -s "$T/j.edited" "$(jbaks | tail -n 1)" || fail "the second backup is not the file as the user left it"
printf '{ not json' >"$J"; cp "$J" "$T/j.bad"
run_setup claude; [ "$RC" = 1 ] || fail "unparsable JSON: exit $RC: $OUT"
grep -qF "$J is not valid JSON; not changed." <<<"$OUT" || { echo "$OUT" >&2; fail "refusal text"; }
cmp -s "$T/j.bad" "$J" || fail "unparsable JSON was rewritten"
[ ! -e "$SKILL_DIR/SKILL.md" ] || fail "the skill was written although the JSON piece refused"
"$PY" -c "print('[' * 200000)" >"$J"; cp "$J" "$T/j.deep"
run_setup claude; [ "$RC" = 1 ] && grep -qF "is not valid JSON; not changed." <<<"$OUT" && ! grep -q Traceback <<<"$OUT" || fail "deeply nested JSON: exit $RC: $(head -c 300 <<<"$OUT")"
cmp -s "$T/j.deep" "$J" || fail "deeply nested JSON was rewritten"
# A tab-indented file with no trailing newline keeps both; a new file is created and left as {} after uninstall.
printf '{\n\t"a": 1\n}' >"$J"
run_setup claude >/dev/null
"$PY" -I - "$J" <<'PY'
import sys
t = open(sys.argv[1]).read()
assert '\n\t"a"' in t and not t.endswith('\n'), repr(t)
PY
rm -f "$J" "$J".agentbus-*.bak; run_setup claude >/dev/null; run_setup claude --uninstall >/dev/null
[ "$(tr -d ' \n' <"$J")" = "{}" ] || fail "uninstall of a file we created left: $(cat "$J")"
unset AGENTBUS_TEST_SETUP_JSON
ok "json_entries keeps shape, keeps user edits, never restores the backup, refuses bad JSON"

echo
echo "TEST: a failure injected at piece 2 reports it, keeps piece 1, and a rerun finishes with the rest unchanged"
reset
export AGENTBUS_TEST_SETUP_JSON="$T/hooks2.json"
AGENTBUS_TEST_SETUP_FAIL=2 run_setup claude
[ "$RC" = 1 ] || fail "exit $RC, wanted 1: $OUT"
has "  + ~/.claude/skills/agentbus/SKILL.md   installed, $SIZE bytes"
grep -qF "could not be written (injected failure); stopped. Written before this: ~/.claude/skills/agentbus/SKILL.md. Fix that and run again: agentbus setup claude" <<<"$OUT" || { echo "$OUT" >&2; fail "failure line"; }
[ -f "$SKILL_DIR/SKILL.md" ] && [ ! -e "$T/hooks2.json" ] || fail "piece 1 must stay and piece 2 must not exist"
run_setup claude
[ "$RC" = 0 ] || fail "rerun exit $RC: $OUT"
has "  = ~/.claude/skills/agentbus/SKILL.md   unchanged"
[ -f "$T/hooks2.json" ] || fail "the rerun did not finish piece 2"
unset AGENTBUS_TEST_SETUP_JSON
reset
AGENTBUS_TEST_SETUP_FAIL=1 run_setup claude
[ "$RC" = 1 ] && grep -qF "Written before this: nothing." <<<"$OUT" && [ ! -e "$SKILL_DIR" ] || fail "failure at piece 1: $RC $OUT"
unset AGENTBUS_TEST_SETUP_JSON
ok "stops at the failure, says exactly what was written, keeps piece 1, rerun is idempotent"

echo
echo "TEST: setup from a project copy is refused"
reset
mkdir -p "$T/proj/.agentbus/bin"; cp "$BIN" "$T/proj/.agentbus/bin/agentbus"
RC=0; OUT=$(cd "$W" && "$PY" "$T/proj/.agentbus/bin/agentbus" setup claude 2>&1) || RC=$?
# bad_input (exit 2), as upgrade from a project copy is: the wrong executable for the command, not a refusal of it
[ "$RC" = 2 ] && grep -qF "not a project copy" <<<"$OUT" || fail "exit $RC: $OUT"
! grep -qi 'hook' <<<"$OUT" || fail "the refusal mentions hooks, and this release ships none: $OUT"
[ ! -e "$HOME/.claude" ] || fail "a project copy wrote user config"
ok "project copies cannot run setup"

echo
echo "TEST: --scope project writes under the current directory only"
reset
h0=$(hash_tree "$HOME")
run_setup claude --scope project
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
has "agentbus setup claude (project)"
[ -f "$W/.claude/skills/agentbus/SKILL.md" ] || fail "not installed under ./.claude"
run_setup codex --scope project
[ -f "$W/AGENTS.md" ] || fail "no ./AGENTS.md"
[ "$h0" = "$(hash_tree "$HOME")" ] || fail "project scope touched HOME"
ok "project scope stays in the current directory"

echo
echo "TEST: --json parses and lists every change"
reset
run_setup claude --json --dry-run
"$PY" -I - "$OUT" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {'target', 'scope', 'dry_run', 'changes'}, d
assert d['target'] == 'claude' and d['scope'] == 'user' and d['dry_run'] is True, d
(c,) = d['changes']
assert set(c) == {'path', 'action', 'detail'} and c['path'].endswith('/.claude/skills/agentbus/SKILL.md') and c['action'] == 'installed', c
PY
[ ! -e "$HOME/.claude" ] || fail "--json --dry-run wrote"
run_setup claude --json
"$PY" -I - "$OUT" "$SKILL_BYTES" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d['dry_run'] is False and d['changes'][0]['detail'] == f'{sys.argv[2]} bytes', d
PY
mkdir -p "$HOME/.codex"; printf 'x\n<!-- agentbus:begin -->\n' >"$HOME/.codex/AGENTS.md"
RC=0; OUT=$(cd "$W" && "${AB[@]}" setup codex --json 2>"$T/jerr0") || RC=$?   # the result on stdout, the error on stderr
[ "$RC" = 1 ] && "$PY" -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["changes"][0]["action"]=="refused", d' "$OUT" || fail "json refusal: $RC $OUT"
grep -qF '"code": "items_failed"' "$T/jerr0" || fail "json refusal: no items_failed error: $(cat "$T/jerr0")"
ok "--json is one object with every change, including refusals"

echo
echo "TEST: exit codes: 0 success, 1 refusal, 2 unknown target; --help names the targets and --dry-run"
run_setup nope; [ "$RC" = 2 ] || fail "unknown target exited $RC: $OUT"
run_setup; [ "$RC" = 2 ] || fail "no target exited $RC: $OUT"
run_setup --help
[ "$RC" = 0 ] && grep -qF 'claude,codex' <<<"$OUT" && grep -qF -- '--dry-run' <<<"$OUT" && grep -qF -- '--uninstall' <<<"$OUT" || fail "help: $OUT"
ok "exit codes and help"

echo
echo "TEST: an edited agentbus block in AGENTS.md is backed up (whole file) before an update, and not removed by uninstall"
reset; mkdir -p "$HOME/.codex"; printf 'top\n' >"$HOME/.codex/AGENTS.md"
run_setup codex >/dev/null
sed -i.orig 's/^Join: /MY EDIT. Join: /' "$HOME/.codex/AGENTS.md"; rm "$HOME/.codex/AGENTS.md.orig"; cp "$HOME/.codex/AGENTS.md" "$T/agents.edited"
run_setup codex --uninstall
[ "$RC" = 0 ] || fail "uninstall of an edited block exited $RC: $OUT"
has "  ! ~/.codex/AGENTS.md   the agentbus block was edited; not removed"
cmp -s "$T/agents.edited" "$HOME/.codex/AGENTS.md" || fail "uninstall changed a file with an edited block"
run_setup codex
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
grep -qE "updated the agentbus block \($BLOCK_LINES lines\); your edited copy is saved as AGENTS\.md\.agentbus-[0-9]{8}T[0-9]{6}\.[0-9]{6}Z(-[0-9]+)?\.bak" <<<"$OUT" || { echo "$OUT" >&2; fail "update line: the edited block was not saved as a .bak"; }
bak=$(ls "$HOME/.codex"/AGENTS.md.agentbus-*.bak); cmp -s "$T/agents.edited" "$bak" || fail "the backup is not the whole edited file"
agentbus skill --agents-md | cmp -s - <(sed -n '/agentbus:begin/,/agentbus:end/p' "$HOME/.codex/AGENTS.md" | sed '1d;$d') || fail "the edited block was not refreshed"
grep -q 'MY EDIT' "$HOME/.codex/AGENTS.md" && fail "the edit is still in the block"
ok "edited blocks are backed up before replacement and never removed silently"

echo
echo "TEST: CODEX_HOME is honoured by install, dry-run, JSON and uninstall; ~/.codex is not touched"
reset
export CODEX_HOME="$T/codex-elsewhere"
run_setup codex
[ "$RC" = 0 ] || fail "exit $RC: $OUT"
has "  + $CODEX_HOME/AGENTS.md   added the agentbus block ($BLOCK_LINES lines)"
[ -f "$CODEX_HOME/AGENTS.md" ] && [ ! -e "$HOME/.codex" ] || fail "CODEX_HOME was not honoured"
run_setup codex --dry-run --json
"$PY" -I - "$OUT" "$CODEX_HOME/AGENTS.md" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); assert d['changes'][0]['path'] == sys.argv[2] and d['changes'][0]['action'] == 'unchanged', d
PY
run_setup codex --uninstall; [ "$RC" = 0 ] && [ ! -s "$CODEX_HOME/AGENTS.md" ] && [ ! -e "$HOME/.codex" ] || fail "uninstall under CODEX_HOME: $RC $OUT"
CODEX_HOME="$T/ch-project" run_setup codex --scope project
[ -f "$W/AGENTS.md" ] && [ ! -e "$T/ch-project" ] || fail "--scope project must ignore CODEX_HOME"
unset CODEX_HOME
ok "CODEX_HOME honoured for user scope only"

echo
echo "TEST: a CRLF AGENTS.md gets a CRLF block, updates and uninstalls cleanly; markers are recognised with either line ending"
reset; mkdir -p "$HOME/.codex"
printf 'line one\r\nline two\r\n' >"$HOME/.codex/AGENTS.md"; cp "$HOME/.codex/AGENTS.md" "$T/crlf.orig"
run_setup codex; [ "$RC" = 0 ] || fail "exit $RC: $OUT"
"$PY" -I - "$HOME/.codex/AGENTS.md" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
assert b.count(b'\n') == b.count(b'\r\n') and b'\r\n' in b, 'mixed line endings'
PY
run_setup codex; has "  = ~/.codex/AGENTS.md   unchanged"
sed -i.orig 's/^## agentbus/## agentbus (old)/' "$HOME/.codex/AGENTS.md"; rm "$HOME/.codex/AGENTS.md.orig"
run_setup codex; [ "$RC" = 0 ] && lacks "damaged" || fail "CRLF update: $RC $OUT"
run_setup codex --uninstall; [ "$RC" = 0 ] || fail "CRLF uninstall: $RC $OUT"
ls "$HOME/.codex"/AGENTS.md.agentbus-*.bak >/dev/null 2>&1 && rm -f "$HOME/.codex"/AGENTS.md.agentbus-*.bak
cmp -s "$T/crlf.orig" "$HOME/.codex/AGENTS.md" || fail "CRLF round trip did not restore the original bytes"
ok "CRLF files keep one line ending and round-trip"

echo
echo "TEST: markers inside a fenced code block are not the managed block"
reset; mkdir -p "$HOME/.codex"
printf '# Notes\n\nExample of what agentbus adds:\n\n```markdown\n<!-- agentbus:begin -->\nmy example\n<!-- agentbus:end -->\n```\n' >"$HOME/.codex/AGENTS.md"; cp "$HOME/.codex/AGENTS.md" "$T/fence.orig"
run_setup codex; [ "$RC" = 0 ] || fail "fenced example: exit $RC: $OUT"
has "  + ~/.codex/AGENTS.md   added the agentbus block ($BLOCK_LINES lines)"
head -c "$(wc -c <"$T/fence.orig")" "$HOME/.codex/AGENTS.md" | cmp -s - "$T/fence.orig" || fail "the user's fenced example changed"
run_setup codex; has "  = ~/.codex/AGENTS.md   unchanged"
run_setup codex --uninstall
cmp -s "$T/fence.orig" "$HOME/.codex/AGENTS.md" || fail "uninstall touched the fenced example"
printf 'text\n\n```\nunclosed fence\n' >"$HOME/.codex/AGENTS.md"; cp "$HOME/.codex/AGENTS.md" "$T/fence2.orig"
run_setup codex; [ "$RC" = 1 ] || fail "unclosed fence: exit $RC: $OUT"
has "  ! ~/.codex/AGENTS.md has an unclosed code fence; not changed."
cmp -s "$T/fence2.orig" "$HOME/.codex/AGENTS.md" || fail "unclosed-fence file changed"
ok "fenced markers are ignored; an unclosed fence is refused"

echo
echo "TEST: --dry-run --json reports dry_run true on a refusal too"
reset; mkdir -p "$SKILL_DIR"; printf '# mine\n' >"$SKILL_DIR/SKILL.md"
RC=0; OUT=$(cd "$W" && "${AB[@]}" setup claude --dry-run --json 2>"$T/jerr1") || RC=$?   # the result on stdout, the error on stderr
[ "$RC" = 1 ] && "$PY" -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["dry_run"] is True and d["changes"][0]["action"]=="refused", d' "$OUT" || fail "dry-run refusal json: $RC $OUT"
grep -qF '"code": "items_failed"' "$T/jerr1" || fail "dry-run refusal json: no items_failed error: $(cat "$T/jerr1")"
ok "dry_run is true in a dry-run refusal"

echo
echo "TEST: --dry-run changes no byte under HOME for install, update, migration, uninstall and codex"
reset
mkdir -p "$T/clone/skill" "$HOME/.claude/skills"; printf -- '---\nname: agentbus\n---\n' >"$T/clone/skill/SKILL.md"; ln -s "$T/clone/skill" "$SKILL_DIR"
mkdir -p "$HOME/.codex"; printf 'mine\n' >"$HOME/.codex/AGENTS.md"
h0=$(hash_tree "$HOME")
for args in "claude --dry-run" "claude --dry-run --uninstall" "codex --dry-run" "codex --dry-run --uninstall" "claude --dry-run --scope project"; do
  run_setup $args; [ "$RC" = 0 ] || fail "$args: exit $RC: $OUT"
  [ "$h0" = "$(hash_tree "$HOME")" ] || fail "$args changed HOME"
done
[ -z "$(ls -A "$W")" ] || fail "--dry-run --scope project wrote in the work directory: $(ls -A "$W")"
run_setup claude --dry-run
has "  ~ would replace the link ~/.claude/skills/agentbus to $T/clone/skill (the old install line)" 
run_setup claude; run_setup codex >/dev/null
printf 'MY EDIT\n<!-- agentbus:managed -->\n' >>"$SKILL_DIR/SKILL.md"; sed -i.orig 's/^Join: /EDIT Join: /' "$HOME/.codex/AGENTS.md"; rm "$HOME/.codex/AGENTS.md.orig"
h1=$(hash_tree "$HOME")
for args in "claude --dry-run" "codex --dry-run" "claude --dry-run --uninstall" "codex --dry-run --uninstall"; do
  run_setup $args; [ "$RC" = 0 ] || fail "$args (edited): exit $RC: $OUT"
  [ "$h1" = "$(hash_tree "$HOME")" ] || fail "$args (edited) changed HOME"
done
ok "no dry run changes any byte under HOME"

echo
echo "TEST: a file that changed after planning is refused, not overwritten"
reset; mkdir -p "$HOME/.codex"; printf 'before\n' >"$HOME/.codex/AGENTS.md"
P="$T/pause"; mkdir -p "$P"
(set +e; cd "$W"; AGENTBUS_TEST_PAUSE="setup-before-write=$P" "${AB[@]}" setup codex >"$T/race.out" 2>&1; echo $? >"$T/race.rc") &
RACE=$!
wait_for "$P/setup-before-write.reached"
printf 'before\nadded by the user meanwhile\n' >"$HOME/.codex/AGENTS.md"
: >"$P/setup-before-write.go"; wait "$RACE" || true
[ "$(cat "$T/race.rc")" = 1 ] || fail "exit $(cat "$T/race.rc"): $(cat "$T/race.out")"
grep -qF "changed while setup ran" "$T/race.out" || fail "message: $(cat "$T/race.out")"
[ "$(cat "$HOME/.codex/AGENTS.md")" = $'before\nadded by the user meanwhile' ] || fail "the user's edit was overwritten"
ok "a concurrent edit wins; setup stops"

echo
echo "TEST: the hooks JSON engine refuses numbers it cannot keep, duplicate keys and NaN"
reset; J="$T/guard.json"; export AGENTBUS_TEST_SETUP_JSON="$J"
for bad in '{"a": 1e400}' '{"a": 0.1}' '{"a": 1, "a": 2}' '{"a": NaN}' '{"a": [1.5e3]}'; do
  printf '%s\n' "$bad" >"$J"; cp "$J" "$T/guard.orig"
  run_setup claude; [ "$RC" = 1 ] || fail "$bad: exit $RC: $OUT"
  grep -qF "$J" <<<"$OUT" && grep -qF "not changed." <<<"$OUT" || fail "$bad: $OUT"
  cmp -s "$T/guard.orig" "$J" || fail "$bad: the file changed"
done
unset AGENTBUS_TEST_SETUP_JSON
ok "ambiguous JSON is refused unchanged"

echo
echo "TEST: edits made in the same second each get their own backup, named with microseconds so they sort in order"
reset; run_setup claude >/dev/null
for n in 1 2 3; do printf "EDIT-$n\n<!-- agentbus:managed -->\n" >>"$SKILL_DIR/SKILL.md"; run_setup claude >/dev/null; done
baks=$(ls "$SKILL_DIR"/SKILL.md.agentbus-*.bak); [ "$(wc -l <<<"$baks" | tr -d ' ')" = 3 ] || fail "three edits, backups: $baks"
grep -qE '/SKILL\.md\.agentbus-[0-9]{8}T[0-9]{6}\.[0-9]{6}Z(-[0-9]+)?\.bak$' <<<"$baks" || fail "backup names: $baks"
n=0; for b in $(sort <<<"$baks"); do n=$((n+1)); grep -qF "EDIT-$n" "$b" || fail "backup $n (in name order) lacks EDIT-$n: $b"; done
ok "three quick edits, three backups, in order"

echo
echo "TEST: markers that are indented (an indented code block, a fenced example inside a list item) are the user's text, not the managed block"
reset; mkdir -p "$HOME/.codex"
printf '# Notes\n\nAn example:\n\n    <!-- agentbus:begin -->\n    my example\n    <!-- agentbus:end -->\n\n- item with a fence:\n\n   ```markdown\n   <!-- agentbus:begin -->\n   nested example\n   <!-- agentbus:end -->\n   ```\n\n- another item\n' >"$HOME/.codex/AGENTS.md"
cp "$HOME/.codex/AGENTS.md" "$T/indented.orig"
run_setup codex; [ "$RC" = 0 ] || fail "indented examples: exit $RC: $OUT"
has "  + ~/.codex/AGENTS.md   added the agentbus block ($BLOCK_LINES lines)"
head -c "$(wc -c <"$T/indented.orig")" "$HOME/.codex/AGENTS.md" | cmp -s - "$T/indented.orig" || fail "the user's indented examples changed"
run_setup codex; has "  = ~/.codex/AGENTS.md   unchanged"
run_setup codex --uninstall; [ "$RC" = 0 ] || fail "uninstall: $RC $OUT"
cmp -s "$T/indented.orig" "$HOME/.codex/AGENTS.md" || fail "uninstall touched the indented examples"
ok "only a marker at column 0 outside a fence counts"

echo
echo "TEST: a backup written by a change that then fails is named in 'Written before this'"
reset; run_setup claude >/dev/null
printf 'MY EDIT\n<!-- agentbus:managed -->\n' >>"$SKILL_DIR/SKILL.md"
AGENTBUS_TEST_SETUP_FAIL_AT=after-backup run_setup claude
[ "$RC" = 1 ] || fail "exit $RC: $OUT"
bak=$(ls "$SKILL_DIR"/SKILL.md.agentbus-*.bak); [ -n "$bak" ] || fail "no backup was written"
grep -qF "Written before this: ~/.claude/skills/agentbus/SKILL.md.agentbus-" <<<"$OUT" && grep -qF "$(basename "$bak")" <<<"$OUT" || { echo "$OUT" >&2; fail "the backup is not named"; }
grep -q 'MY EDIT' "$SKILL_DIR/SKILL.md" || fail "the edited file must be untouched when the write failed after the backup"
ok "the error names the backup"

echo
echo "TEST: a config folder that is a dangling link is refused in planning, in a dry run and a real run alike"
reset; ln -s "$T/nowhere" "$T/dangling"
for mode in "--dry-run" ""; do
  CODEX_HOME="$T/dangling" run_setup codex $mode
  [ "$RC" = 1 ] || fail "dangling CODEX_HOME $mode: exit $RC: $OUT"
  grep -qF "cannot be created: $T/dangling is not a folder" <<<"$OUT" || { echo "$OUT" >&2; fail "message for $mode"; }
  CLAUDE_CONFIG_DIR="$T/dangling" run_setup claude $mode
  [ "$RC" = 1 ] && grep -qF "cannot be created: $T/dangling is not a folder" <<<"$OUT" || fail "dangling CLAUDE_CONFIG_DIR $mode: $RC $OUT"
done
[ -L "$T/dangling" ] && [ ! -e "$T/nowhere" ] || fail "the link or its target changed"
ok "a dangling link is a clear refusal, never a half-failed write"

echo
echo "TEST: --json failures: an items_failed error on stderr with the failed files, committed true once a file was written, and the backup named"
# Bugs it catches: a setup failure exited 1 with no error object (nothing to branch on), said committed false (or
# nothing) after it had written files, and the JSON report left out the backup the failing change had saved.
jsetup() { RC=0; (cd "$W" && "${AB[@]}" --json setup "$@" >"$T/jout" 2>"$T/jerr") || RC=$?; }
jcheck() {  # jcheck COMMITTED PYTHON-EXPR: exit 1, the result on stdout, one items_failed error on stderr; o and e hold them
  "$PY" -I - "$T/jout" "$T/jerr" "$1" "$2" <<'PY' || { cat "$T/jout" "$T/jerr" >&2; fail "setup --json failure: $2"; }
import json, sys
o = json.load(open(sys.argv[1])); lines = open(sys.argv[2]).read().splitlines()
assert len(lines) == 1, lines
e = json.loads(lines[0])["error"]
assert e["code"] == "items_failed" and e["retryable"] is False and e["failed"], e
assert e["committed"] is (sys.argv[3] == "true"), e
assert eval(sys.argv[4]), (o, e)
PY
}
reset; run_setup claude >/dev/null
printf 'MY EDIT\n<!-- agentbus:managed -->\n' >>"$SKILL_DIR/SKILL.md"
AGENTBUS_TEST_SETUP_FAIL_AT=after-backup jsetup claude
[ "$RC" = 1 ] || fail "after-backup --json: exit $RC"
bak=$(ls "$SKILL_DIR"/SKILL.md.agentbus-*.bak)
jcheck true "o['changes'][-1]['action'] == 'refused' and o['changes'][-1]['backup'] == '$bak' and e['failed'][0]['backup'] == '$bak'"
reset
export AGENTBUS_TEST_SETUP_JSON="$T/hooks3.json"
AGENTBUS_TEST_SETUP_FAIL=2 jsetup claude; [ "$RC" = 1 ] || fail "piece 2 --json: exit $RC"
jcheck true "o['changes'][0]['action'] == 'installed' and e['failed'][0]['path'] == '$T/hooks3.json'"
reset
AGENTBUS_TEST_SETUP_FAIL=1 jsetup claude; [ "$RC" = 1 ] || fail "piece 1 --json: exit $RC"
jcheck false "'backup' not in e['failed'][0]"
unset AGENTBUS_TEST_SETUP_JSON
reset; ln -s "$T/nowhere" "$T/dangling2"
CODEX_HOME="$T/dangling2" jsetup codex; [ "$RC" = 1 ] || fail "refusal --json: exit $RC"
jcheck false "[c['action'] for c in o['changes']] == ['refused'] and e['failed'] == o['changes']"
ok "setup --json failures exit 1 with items_failed, the failed files, committed as written, and the backup"

echo
echo "TEST: Ctrl-C after setup wrote a file: committed true, still retryable (setup is safe to repeat), the files and the rerun named"
# Bugs it catches: once a file was written the error said retryable false, so an agent following the contract would not
# rerun a command declared safe to repeat; and it named no command that finishes the job.
reset
"$PY" -I - "$T" "$W" "$SKILL_DIR/SKILL.md" "${AB[@]}" <<'PY' || fail "Ctrl-C after a setup write"
import json, os, signal, subprocess, sys, time
T, W, skill, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
pause = os.path.join(T, "pause-setup"); os.makedirs(pause)
env = dict(os.environ, AGENTBUS_TEST_SETUP_JSON=os.path.join(T, "hooks-intr.json"),
           AGENTBUS_TEST_PAUSE="setup-before-write-entries=" + pause)
for js in (True, False):
    for n in os.listdir(pause):
        os.unlink(os.path.join(pause, n))
    if os.path.exists(skill):
        os.unlink(skill)
    p = subprocess.Popen([*cmd, *(["--json"] if js else []), "setup", "claude"], cwd=W, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    end = time.time() + 30
    while not os.path.exists(os.path.join(pause, "setup-before-write-entries.reached")):
        assert time.time() < end and p.poll() is None, ("never reached", p.communicate())
        time.sleep(0.02)
    p.send_signal(signal.SIGINT)
    out, err = p.communicate(timeout=30)
    assert p.returncode == 130 and os.path.isfile(skill), (p.returncode, out, err)
    assert "Run: agentbus setup claude to finish" in err and skill in err, err
    if js:
        e = json.loads(err)["error"]
        assert e["code"] == "interrupted" and e["committed"] is True and e["retryable"] is True, e
        assert e["rerun"] == "agentbus setup claude" and skill in e["changed"], e
    else:
        assert "The command's change was saved before this." in err and "Traceback" not in err, err
PY
AGENTBUS_TEST_SETUP_JSON="$T/hooks-intr.json" run_setup claude; [ "$RC" = 0 ] && [ -f "$T/hooks-intr.json" ] || fail "the rerun did not finish an interrupted setup: $RC $OUT"
ok "an interrupted setup says committed, stays retryable, names the files and the rerun, and the rerun finishes it"

echo
echo "All setup tests passed"
