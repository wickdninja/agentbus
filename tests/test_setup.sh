#!/bin/bash
set -euo pipefail
# agentbus setup claude|codex: the skill for Claude Code, the AGENTS.md block for Codex. Everything runs
# in a temp HOME; no test touches a real config folder. Output lines are asserted with grep -F.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR CODEX_HOME AGENTBUS_TEST_SETUP_FAIL AGENTBUS_TEST_SETUP_JSON
# The tests below are about the skill piece and the engine; the hooks piece has its own section at the end.
export AGENTBUS_TEST_SETUP_NO_HOOKS=1
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
has "done. Start a new Claude Code session to load them."
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
echo "TEST: an edit made elsewhere after install survives uninstall; an AGENTS.md that held only our block is deleted with it; a stale block is updated in place"
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
[ ! -e "$HOME/.codex/AGENTS.md" ] || fail "a file that held only our block must be removed with it, not left empty"
reset; mkdir -p "$HOME/.codex"; : >"$HOME/.codex/AGENTS.md"
run_setup codex >/dev/null; run_setup codex --uninstall >/dev/null
[ ! -e "$HOME/.codex/AGENTS.md" ] || fail "an AGENTS.md that held nothing but our block was left behind empty"
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
echo "TEST: hooks: setup claude adds five tagged entries with the recorded absolute path, keeps existing hooks and keys, and a second run changes nothing"
unset AGENTBUS_TEST_SETUP_NO_HOOKS AGENTBUS_TEST_SETUP_JSON
reset
mkdir -p "$HOME/.claude"; S="$HOME/.claude/settings.json"
"$PY" -I - "$S" <<'PY'
import json, sys
json.dump({"theme": "dark", "env": {"A": "1"},
           "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}],
                     "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo post"}]}]}},
          open(sys.argv[1], "w"), indent=2)
PY
cp "$S" "$T/s.orig"
run_setup claude
[ "$RC" = 0 ] || fail "hooks install: exit $RC: $OUT"
has "  + ~/.claude/skills/agentbus/SKILL.md   installed, $SIZE bytes"
grep -qF "  + ~/.claude/settings.json   added 5 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop, SessionEnd); the file as it was is saved as settings.json.agentbus-" <<<"$OUT" || { echo "$OUT" >&2; fail "hooks install line"; }
has "done. Start a new Claude Code session to load them."
"$PY" -I - "$S" "$T/s.orig" <<'PY' || fail "settings.json lacks five tagged entries, or lost an existing hook or key"
import json, os, shlex, subprocess, sys
now = json.load(open(sys.argv[1])); orig = json.load(open(sys.argv[2]))
hooks = now.pop("hooks")
assert now == {k: v for k, v in orig.items() if k != "hooks"}, now
assert hooks["PostToolUse"] == orig["hooks"]["PostToolUse"], hooks["PostToolUse"]
assert hooks["Stop"][0] == orig["hooks"]["Stop"][0] and len(hooks["Stop"]) == 2, hooks["Stop"]
want = {"SessionStart": "startup|resume|clear|compact|fork", "UserPromptSubmit": None, "PreToolUse": "Edit|Write|MultiEdit|NotebookEdit", "Stop": None, "SessionEnd": None}
assert sorted(hooks) == sorted(set(want) | {"PostToolUse"}), sorted(hooks)
for event, matcher in want.items():
    groups = [g for g in hooks[event] if any(h["command"].endswith(" # agentbus:managed") for h in g["hooks"])]
    assert len(groups) == 1 and groups[0].get("matcher") == matcher and len(groups[0]["hooks"]) == 1, (event, groups)
    h = groups[0]["hooks"][0]
    assert h["type"] == "command" and h["timeout"] == (2 if event == "SessionEnd" else 5), h
    words = shlex.split(h["command"])
    tool = words[:words.index("hook")]
    assert os.path.isabs(tool[0]) or os.path.isabs(tool[-1]), tool
    assert h["command"].endswith(f" hook claude {event} 2>/dev/null || true # agentbus:managed"), h["command"]
    assert h["command"].startswith("'"), h["command"]  # the executable is quoted, never looked up on PATH
    ran = subprocess.run([*tool, "--version"], capture_output=True, text=True, cwd="/")
    assert ran.returncode == 0 and ran.stdout.startswith("agentbus "), (tool, ran)
assert not any(e.startswith("Subagent") for e in hooks), sorted(hooks)
PY
h1=$(hash_tree "$HOME")
run_setup claude
has "  = ~/.claude/settings.json   unchanged"
[ "$(hash_tree "$HOME")" = "$h1" ] || fail "a second hooks run changed a file"
ok "five tagged entries with the recorded executable, existing hooks and keys kept, a rerun changes nothing"

echo
echo "TEST: hooks: the registered command needs no PATH (absolute interpreter), and exits 0 when its executable is gone"
mkdir -p "$W/hproj"; (cd "$W/hproj" && git init -q && "${AB[@]}" init . >/dev/null && "${AB[@]}" who >/dev/null)
printf '{"session_id":"aaaaaaaa-0000-4000-8000-000000000001","cwd":"%s","source":"startup"}' "$W/hproj" >"$T/hp.json"
cmd=$("$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$S")
RC=0; got=$(cd "$W/hproj" && env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH=/nonexistent /bin/sh -c "$cmd" <"$T/hp.json" 2>&1) || RC=$?
[ "$RC" = 0 ] && grep -qF "you are on this folder's bus as claude-" <<<"$got" || fail "the registered command with an empty PATH: exit $RC, output: $got"
gone=$("$PY" -I -c 'import re,sys; print(re.sub(r"^.*? hook claude", "/nonexistent/agentbus hook claude", sys.argv[1]))' "$cmd")
RC=0; got=$(cd "$W/hproj" && env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin /bin/sh -c "$gone" <"$T/hp.json" 2>&1) || RC=$?
[ "$RC" = 0 ] && [ -z "$got" ] || fail "the registered command with its executable gone: exit $RC, output: $got"
ok "no PATH lookup: the recorded interpreter and tool answer; || true keeps a missing executable at exit 0"

echo
echo "TEST: hooks: uninstall gives parsed-JSON equality with the original plus a user edit made in between"
"$PY" -I - "$S" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["model"] = "opus"; d["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "echo late"}]})
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
run_setup claude --uninstall
[ "$RC" = 0 ] || fail "hooks uninstall: exit $RC: $OUT"
"$PY" -I - "$S" "$T/s.orig" <<'PY' || fail "uninstall did not leave the original plus the user's edit"
import json, sys
now = json.load(open(sys.argv[1])); orig = json.load(open(sys.argv[2]))
orig["model"] = "opus"; orig["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "echo late"}]})
assert now == orig, (now, orig)
PY
ok "tagged entries gone, everything else (including the edit) kept"

echo
echo "TEST: hooks: an invalid settings.json is refused and left byte-identical"
printf '{ not json' >"$S"; cp "$S" "$T/s.bad"
run_setup claude
[ "$RC" = 1 ] && grep -qF "is not valid JSON; not changed." <<<"$OUT" || fail "invalid settings.json: exit $RC: $OUT"
cmp -s "$S" "$T/s.bad" || fail "invalid settings.json was changed"
[ ! -e "$HOME/.claude/skills/agentbus" ] || fail "the skill was written although the hooks file was refused"
ok "refused, nothing written"

echo
echo "TEST: hooks: an installed agentbus plugin provides the hooks, so only the skill is added"
reset
mkdir -p "$HOME/.claude/plugins"
"$PY" -I - "$HOME/.claude/plugins/installed_plugins.json" "$TESTS_DIR/fixtures/claude_hooks/installed_plugins.json" agentbus@agentbus <<'PY'
import json, sys
d = json.load(open(sys.argv[2])); entry = next(iter(d["plugins"].values()))
d["plugins"] = {sys.argv[3]: entry}
json.dump(d, open(sys.argv[1], "w"))
PY
run_setup claude
[ "$RC" = 0 ] || fail "plugin present: exit $RC: $OUT"
has "  = hooks   provided by the agentbus plugin; not added"
has "  + ~/.claude/skills/agentbus/SKILL.md   installed, $SIZE bytes"
[ ! -e "$HOME/.claude/settings.json" ] || fail "hooks were added although the plugin provides them"
# a plugin Claude Code has switched off provides nothing; one of another name is not agentbus
printf '{"enabledPlugins": {"agentbus@agentbus": false}}' >"$HOME/.claude/settings.json"
run_setup claude; grep -qF "  + ~/.claude/settings.json   added 5 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "a disabled plugin still counted"; }
reset; mkdir -p "$HOME/.claude/plugins"; cp "$TESTS_DIR/fixtures/claude_hooks/installed_plugins.json" "$HOME/.claude/plugins/installed_plugins.json"
run_setup claude; grep -qF "added 5 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "another plugin's id counted as agentbus"; }
reset; mkdir -p "$HOME/.claude/plugins"; printf 'not json' >"$HOME/.claude/plugins/installed_plugins.json"
run_setup claude; grep -qF "added 5 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "an unreadable plugin record stopped setup"; }
ok "installed and enabled: skill only; disabled, another name or unreadable: hooks added"

echo
echo "TEST: hooks: check reports the entry, the recorded executable and a plugin duplicate"
reset; run_setup claude >/dev/null
rows() { "$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$S" <<'PY'
import json, runpy, shlex, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_check")
# check runs inside the tool, whose argv[0] is the executable setup recorded
sys.argv[0] = shlex.split(json.load(open(sys.argv[2]))["hooks"]["Stop"][0]["hooks"][0]["command"])[0]
for r in m["ClaudeHooksPiece"]().check("user"):
    print(r[0], r[1])
PY
}
got=$(rows); [ "$got" = "$(printf 'claude_hooks ok\nclaude_hooks_tool ok')" ] || fail "check after install: $got"
"$PY" -I - "$S" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for groups in d["hooks"].values():
    for g in groups:
        for h in g["hooks"]:
            h["command"] = re.sub(r"^('[^']*' ?)+(?= hook)", "'/nonexistent/agentbus'", h["command"])
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
got=$(rows); grep -qx "claude_hooks_tool problem" <<<"$got" || fail "check with a missing executable: $got"
run_setup claude >/dev/null; mkdir -p "$HOME/.claude/plugins"
"$PY" -I - "$HOME/.claude/plugins/installed_plugins.json" "$TESTS_DIR/fixtures/claude_hooks/installed_plugins.json" agentbus@agentbus <<'PY'
import json, sys
d = json.load(open(sys.argv[2])); entry = next(iter(d["plugins"].values()))
d["plugins"] = {sys.argv[3]: entry}
json.dump(d, open(sys.argv[1], "w"))
PY
got=$(rows); grep -qx "claude_hooks_duplicate problem" <<<"$got" || fail "check with the plugin and setup hooks both present: $got"
ok "check: ok after install; a missing executable and a plugin duplicate are problems"

echo
echo "TEST: hooks: --scope project writes ./.claude/settings.json under the current directory only"
reset; run_setup claude --scope project
[ "$RC" = 0 ] && [ -f "$W/.claude/settings.json" ] && [ ! -e "$HOME/.claude/settings.json" ] || fail "project hooks: exit $RC, $OUT"
grep -qF "  + .claude/settings.json" <<<"$OUT" || grep -qF "settings.json   added 5 hooks" <<<"$OUT" || fail "project hooks line: $OUT"
ok "project scope: the settings file is under the work folder"

echo
echo "TEST: hooks: check never runs what settings.json names (a project's settings file can be a clone's)"
reset; mkdir -p "$W/.claude"
cat >"$T/canary.sh" <<SH
#!/bin/sh
touch "$T/CANARY"
SH
chmod +x "$T/canary.sh"
"$PY" -I - "$W/.claude/settings.json" "$T/canary.sh" <<'PY'
import json, sys
json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": f"{sys.argv[2]} hook claude Stop # agentbus:managed"}]}]}}, open(sys.argv[1], "w"))
PY
got=$(cd "$W" && "$PY" -I - "${AGENTBUS_BIN:-$BIN}" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_check")
for r in m["ClaudeHooksPiece"]().check("project"):
    print(r[0], r[1])
PY
)
[ ! -e "$T/CANARY" ] || fail "check ran the command a settings file named"
grep -qx "claude_hooks_tool problem" <<<"$got" || fail "check of a hostile settings file: $got"
ok "the executable is looked at, never started"

echo
echo "TEST: hooks: setup asks claude plugin list --json first (every scope), and the plugin files only when there is no answer"
mkdir -p "$T/stub"
cat >"$T/stub/claude" <<'SH'
#!/bin/sh
[ "$1 $2 $3" = "plugin list --json" ] || exit 64
[ -z "$STUB_EXIT" ] || exit "$STUB_EXIT"
cat "$STUB_LIST"
SH
chmod +x "$T/stub/claude"
export AGENTBUS_CLAUDE_BIN="$T/stub/claude"
stub() { printf '%s' "$1" >"$T/stub.list"; export STUB_LIST="$T/stub.list"; }
reset; stub '[{"id":"agentbus@agentbus","version":"0.2.0","scope":"project","enabled":true,"projectEnabled":true}]'
run_setup claude; has "  = hooks   provided by the agentbus plugin; not added"
[ ! -e "$HOME/.claude/settings.json" ] || fail "a project-scope plugin install did not stop setup adding its own hooks"
reset; stub '[{"id":"agentbus@agentbus","scope":"user","enabled":false}]'
run_setup claude; grep -qF "added 5 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "claude listed a disabled plugin and it still counted"; }
reset; stub '[{"id":"other@market","scope":"user","enabled":true}]'
run_setup claude; grep -qF "added 5 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "another plugin counted as agentbus"; }
# the answer is claude's even when the plugin files disagree
reset; stub '[]'; mkdir -p "$HOME/.claude/plugins"
"$PY" -I - "$HOME/.claude/plugins/installed_plugins.json" "$TESTS_DIR/fixtures/claude_hooks/installed_plugins.json" agentbus@agentbus <<'PY'
import json, sys
d = json.load(open(sys.argv[2])); entry = next(iter(d["plugins"].values()))
d["plugins"] = {sys.argv[3]: entry}
json.dump(d, open(sys.argv[1], "w"))
PY
run_setup claude; grep -qF "added 5 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "the plugin files overruled claude's own list"; }
# no usable answer (claude fails, or prints something else): the files decide
STUB_EXIT=3 run_setup claude; grep -qF "provided by the agentbus plugin" <<<"$OUT" || { echo "$OUT" >&2; fail "a failing claude did not fall back to the plugin files"; }
stub 'not json'; reset; mkdir -p "$HOME/.claude/plugins"; printf 'not json' >"$HOME/.claude/plugins/installed_plugins.json"
run_setup claude; grep -qF "added 5 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "nonsense from claude and from the files stopped setup"; }
# the files, project scope: installed, and switched on by the project's own settings
export AGENTBUS_CLAUDE_BIN=/nonexistent/claude
reset; mkdir -p "$HOME/.claude/plugins" "$W/.claude"
"$PY" -I - "$HOME/.claude/plugins/installed_plugins.json" "$TESTS_DIR/fixtures/claude_hooks/installed_plugins.json" agentbus@agentbus <<'PY'
import json, sys
d = json.load(open(sys.argv[2])); entry = dict(next(iter(d["plugins"].values()))[0], scope="project")
d["plugins"] = {sys.argv[3]: [entry]}
json.dump(d, open(sys.argv[1], "w"))
PY
run_setup claude; grep -qF "added 5 hooks" <<<"$OUT" || { echo "$OUT" >&2; fail "a project-scope install nobody switched on counted"; }
printf '{"enabledPlugins": {"agentbus@agentbus": true}}' >"$W/.claude/settings.json"
run_setup claude; grep -qF "provided by the agentbus plugin" <<<"$OUT" || { echo "$OUT" >&2; fail "a project-scope install switched on by the project was missed"; }
ok "claude's list first (project, disabled, other name, overruling the files); the files only without an answer"

echo
echo "TEST: hooks: setup records an absolute interpreter, so the registered command does not search PATH"
reset; run_setup claude >/dev/null
"$PY" -I - "$HOME/.claude/settings.json" <<'PY' || fail "a recorded command does not start with an absolute interpreter and script"
import json, os, shlex, sys
for groups in json.load(open(sys.argv[1]))["hooks"].values():
    for g in groups:
        words = shlex.split(g["hooks"][0]["command"])
        tool = words[:words.index("hook")]
        assert all(os.path.isabs(w) and os.path.exists(w) for w in tool), tool
PY
ok "absolute paths only"

echo
echo "TEST: hooks: setup starts claude only from a trusted place and from the home folder; check starts nothing"
reset; git -C "$W" init -q; export AGENTBUS_CLAUDE_BIN=
mkdir -p "$W/node_modules/.bin" "$T/ok" "$T/gw"
mkclaude() { printf '#!/bin/sh\necho "$PWD $*" >>"%s"\necho '"'"'[{"id":"agentbus@agentbus","enabled":true}]'"'"'\n' "$T/claude.log" >"$1"; chmod 755 "$1"; }
mkclaude "$W/node_modules/.bin/claude"; mkclaude "$T/ok/claude"; mkclaude "$T/gw/claude"
ran() { [ -s "$T/claude.log" ]; }
tried() {  # tried PATH LABEL: setup with that PATH; the log says whether a claude was started
  rm -f "$T/claude.log"; PATH="$1" run_setup claude
  [ "$RC" = 0 ] || fail "$2: setup exit $RC: $OUT"
}
tried "$W/node_modules/.bin:$PATH" "a claude inside the repo"
! ran || fail "setup started a claude that lives inside the working directory's repo"
grep -qF "added 5 hooks" <<<"$OUT" || fail "without a trusted claude the plugin files were not used"
reset; git -C "$W" init -q; mkdir -p "$W/node_modules/.bin"; mkclaude "$W/node_modules/.bin/claude"
(cd "$W" && rm -f "$T/claude.log" && PATH="node_modules/.bin:$PATH" "${AB[@]}" setup claude >/dev/null 2>&1) || fail "setup with a relative PATH entry failed"
! ran || fail "setup started a claude found through a relative PATH entry"
rm -rf "$W/.git"; reset; mkdir -p "$W/node_modules/.bin"; mkclaude "$W/node_modules/.bin/claude"
tried "$W/node_modules/.bin:$PATH" "a claude under the working directory, no repository"
! ran || fail "setup started a claude that lives under the working directory"
chmod 775 "$T/gw/claude"; reset
tried "$T/gw:$PATH" "a group-writable claude"
! ran || fail "setup started a group-writable claude"
mkdir -p "$T/gwdir"; mkclaude "$T/gwdir/claude"; chmod 775 "$T/gwdir"; reset
tried "$T/gwdir:$PATH" "a claude in a group-writable folder"
! ran || fail "setup started a claude in a group-writable folder"
reset
tried "$T/ok:$PATH" "a trusted claude"
ran || fail "setup did not start a trusted claude"
"$PY" -I - "$T/claude.log" "$HOME" <<'PY' || fail "claude was not started from the home folder with plugin list --json"
import os, sys
line = open(sys.argv[1]).read().strip()
cwd, args = line.split(" ", 1)
assert os.path.realpath(cwd) == os.path.realpath(sys.argv[2]) and args == "plugin list --json", line
PY
grep -qF "provided by the agentbus plugin" <<<"$OUT" || fail "a trusted claude's answer was not used"
# check reads files only
rm -f "$T/claude.log"; reset; run_setup claude >/dev/null
(cd "$W" && PATH="$T/ok:$PATH" "$PY" -I - "${AGENTBUS_BIN:-$BIN}" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_check")
m["ClaudeHooksPiece"]().check("user"); m["ClaudeHooksPiece"]().check("project")
PY
)
! ran || fail "check started claude"
export AGENTBUS_CLAUDE_BIN=/nonexistent/claude
ok "claude: absolute PATH entries only, outside the project and its buses, not writable by others, run from HOME; check never starts it"

echo
echo "TEST: hooks: a claude under any project root below HOME, or tracked in its work tree's index, is not started"
export AGENTBUS_CLAUDE_BIN=
setup_in() {  # setup_in CWD PATH: setup claude from CWD with that PATH; the log says whether a claude was started
  rm -f "$T/claude.log"; RC=0; OUT=$(cd "$1" && PATH="$2" "${AB[@]}" setup claude 2>&1) || RC=$?
  [ "$RC" = 0 ] || fail "setup in $1: exit $RC: $OUT"
}
reset; mkdir -p "$HOME/tarball/sub" "$HOME/tarball/node_modules/.bin"; mkclaude "$HOME/tarball/node_modules/.bin/claude"
setup_in "$HOME/tarball/sub" "$HOME/tarball/node_modules/.bin:$PATH"
! ran || fail "setup started a claude under an ancestor project root of the working directory (no git repository)"
reset; mkdir -p "$HOME/proj" "$HOME/.local/bin"; mkclaude "$HOME/.local/bin/claude"
setup_in "$HOME/proj" "$HOME/.local/bin:$PATH"
ran || fail "setup refused a claude in the home folder's own bin, outside the project and not in a repository"
gitq() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
# a dotfiles home: an untracked claude is fine, one the home's index lists is not (from the project or from HOME itself)
reset; git -C "$HOME" init -q; mkdir -p "$HOME/bin" "$HOME/proj"; mkclaude "$HOME/bin/claude"
setup_in "$HOME/proj" "$HOME/bin:$PATH"
ran || fail "setup refused an untracked claude in a dotfiles home"
gitq "$HOME" add -f bin/claude
setup_in "$HOME/proj" "$HOME/bin:$PATH"
! ran || fail "setup started a claude tracked in the index of a home folder that is a git repository"
setup_in "$HOME" "$HOME/bin:$PATH"
! ran || fail "setup run from a git home folder started a claude its index lists"
# a work tree elsewhere (Homebrew's prefix is one): Caskroom/ and node_modules/ are untracked there
WT="$T/wt"; rm -rf "$WT"; mkdir -p "$WT/Caskroom/claude/1.0" "$WT/bin"; git -C "$WT" init -q
printf 'readme\n' >"$WT/README"; gitq "$WT" add README      # the index lists something, just not the claude
mkclaude "$WT/Caskroom/claude/1.0/claude"; ln -s ../Caskroom/claude/1.0/claude "$WT/bin/claude"
reset
setup_in "$W" "$WT/bin:$PATH"
ran || fail "setup refused a claude that is untracked in an unrelated work tree (symlinked from its bin)"
grep -qF "provided by the agentbus plugin" <<<"$OUT" || fail "an untracked work-tree claude's answer was not used"
gitq "$WT" add -f Caskroom/claude/1.0/claude
setup_in "$W" "$WT/bin:$PATH"
! ran || fail "setup started a claude tracked in the index of its work tree"
gitq "$WT" update-index --force-remove Caskroom/claude/1.0/claude; gitq "$WT" add -f bin/claude
mkdir -p "$T/outbin"; ln -sf "$WT/bin/claude" "$T/outbin/claude"     # the PATH entry is outside the work tree; the tracked link is a hop on the way in
setup_in "$W" "$T/outbin:$PATH"
! ran || fail "setup started a claude reached through a tracked symlink hop"
gitq "$WT" update-index --force-remove bin/claude
setup_in "$W" "$WT/bin:$PATH"
ran || fail "setup refused the work-tree claude after nothing was tracked any more"
printf 'garbage, not an index' >"$WT/.git/index"
setup_in "$W" "$WT/bin:$PATH"
! ran || fail "setup started a claude in a work tree whose index is a corrupt index (it must count as tracked)"
export AGENTBUS_CLAUDE_BIN=/nonexistent/claude
ok "no claude under the working directory's ancestors below HOME or tracked in its work tree's index (itself, a symlink hop, or an unreadable index); untracked ones (Caskroom, node_modules, a dotfiles home) are trusted"

echo
echo "TEST: hooks: the enclosing work tree, other spellings of a folder, and a tracked directory link all keep a claude from starting"
export AGENTBUS_CLAUDE_BIN=
# a repository outside HOME: the working directory is a subfolder, the claude sits in the repository's node_modules (untracked)
reset; OP="$T/outproj"; rm -rf "$OP"; mkdir -p "$OP/sub" "$OP/node_modules/.bin"; git -C "$OP" init -q; mkclaude "$OP/node_modules/.bin/claude"
setup_in "$OP/sub" "$OP/node_modules/.bin:$PATH"
! ran || fail "setup started a claude inside the work tree enclosing the working directory (a repository outside HOME)"
# nested work trees outside HOME: the outer one's untracked tools/ is refused too, not only the innermost tree's files
reset; rm -rf "$T/outer"; mkdir -p "$T/outer/inner/src" "$T/outer/tools"; git -C "$T/outer" init -q; git -C "$T/outer/inner" init -q; mkclaude "$T/outer/tools/claude"
setup_in "$T/outer/inner/src" "$T/outer/tools:$PATH"
! ran || fail "setup started a claude under the outer one of two nested work trees"
# a folder named .agentbus in any case, anywhere
reset; mkdir -p "$T/pj3/.AGENTBUS/bin"; mkclaude "$T/pj3/.AGENTBUS/bin/claude"
setup_in "$W" "$T/pj3/.AGENTBUS/bin:$PATH"
! ran || fail "setup started a claude inside a folder named .AGENTBUS"
# another spelling of the working directory's repository, where the file system treats the spellings alike
mkdir -p "$T/CaseProbe"
if [ -d "$T/caseprobe" ]; then
  reset; CP="$T/capsproj"; rm -rf "$CP"; mkdir -p "$CP/sub" "$CP/node_modules/.bin"; git -C "$CP" init -q; mkclaude "$CP/node_modules/.bin/claude"
  setup_in "$CP/sub" "$T/CAPSPROJ/node_modules/.bin:$PATH"
  ! ran || fail "setup started a claude reached through another spelling of the repository's path"
  echo "checked another spelling of a path (case-insensitive file system)"
else
  echo "case-sensitive file system: another spelling of a path names another folder here; the identity comparison is the same code as the plain case above"
fi
# a directory link that the index lists: tools -> real; real/claude itself is untracked
reset; WT2="$T/wt2"; rm -rf "$WT2"; mkdir -p "$WT2/real"; git -C "$WT2" init -q; mkclaude "$WT2/real/claude"; ln -s real "$WT2/tools"
gitq "$WT2" add tools
setup_in "$W" "$WT2/tools:$PATH"
! ran || fail "setup started a claude reached through a tracked directory link"
gitq "$WT2" update-index --force-remove tools
setup_in "$W" "$WT2/tools:$PATH"
ran || fail "setup refused a claude behind a directory link that nothing tracks"
export AGENTBUS_CLAUDE_BIN=/nonexistent/claude
ok "enclosing work tree, .AGENTBUS, another spelling and a tracked directory link are refused; an untracked directory link is fine"

echo
echo "TEST: codex hooks: setup codex adds the block and four tagged hooks, keeps existing hooks and keys, and a second run changes nothing"
# Setup starts the user's login shell once to look at what it prints: every test here names a quiet one (the check test
# makes noisy and hanging ones).
mkdir -p "$T/shells"; printf '#!/bin/sh\nexit 0\n' >"$T/shells/quiet"; chmod +x "$T/shells/quiet"; export SHELL="$T/shells/quiet"
# trust_line SCOPE_TEXT: the line setup prints, with the tool word read from the hooks file setup wrote.
trust_line() {
  "$PY" -I - "$1" "${2:-}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
cmd = next(h["command"] for g in doc["hooks"]["Stop"] for h in g["hooks"] if h["command"].endswith("# agentbus:managed"))
line = "Codex ignores hooks until you trust them: start codex, type /hooks, and approve the 4 entries whose command starts " + cmd[:cmd.index(" hook codex")] + " hook codex and ends # agentbus:managed."
print(line + (" Codex loads project hooks only for a project you have trusted." if sys.argv[2] == "project" else ""))
PY
}
reset
mkdir -p "$HOME/.codex"; CH="$HOME/.codex/hooks.json"
"$PY" -I - "$CH" <<'PY'
import json, sys
json.dump({"note": "mine", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}],
                                     "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo post"}]}]}},
          open(sys.argv[1], "w"), indent=2)
PY
cp "$CH" "$T/ch.orig"
run_setup codex
[ "$RC" = 0 ] || fail "codex hooks install: exit $RC: $OUT"
has "agentbus setup codex (user)"
has "  + ~/.codex/AGENTS.md   added the agentbus block ($BLOCK_LINES lines)"
grep -qF "  + ~/.codex/hooks.json   added 4 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop); the file as it was is saved as hooks.json.agentbus-" <<<"$OUT" || { echo "$OUT" >&2; fail "codex hooks install line"; }
has "done. $(trust_line "$CH")"
has "next: cd your-repo && agentbus init ."
"$PY" -I - "$CH" "$T/ch.orig" <<'PY' || fail "hooks.json lacks four tagged entries, or lost an existing hook or key"
import json, os, shlex, sys
now = json.load(open(sys.argv[1])); orig = json.load(open(sys.argv[2]))
hooks = now.pop("hooks")
assert now == {k: v for k, v in orig.items() if k != "hooks"}, now
assert hooks["PostToolUse"] == orig["hooks"]["PostToolUse"], hooks["PostToolUse"]
assert hooks["Stop"][0] == orig["hooks"]["Stop"][0] and len(hooks["Stop"]) == 2, hooks["Stop"]
want = {"SessionStart": None, "UserPromptSubmit": None, "PreToolUse": "apply_patch|Edit|Write", "Stop": None}
assert sorted(hooks) == sorted(set(want) | {"PostToolUse"}), sorted(hooks)
for event, matcher in want.items():
    groups = [g for g in hooks[event] if any(h["command"].endswith(" # agentbus:managed") for h in g["hooks"])]
    assert len(groups) == 1 and groups[0].get("matcher") == matcher and len(groups[0]["hooks"]) == 1, (event, groups)
    h = groups[0]["hooks"][0]
    assert h["type"] == "command" and h["timeout"] == 5, h
    words = shlex.split(h["command"])
    tool = words[:words.index("hook")]
    assert os.path.isabs(tool[0]) or os.path.isabs(tool[-1]), tool
    assert h["command"].endswith(f" hook codex {event} 2>/dev/null || true # agentbus:managed"), h["command"]
PY
[ "$(mode "$CH")" = 644 ] || fail "an existing hooks.json changed mode: $(mode "$CH")"
h1=$(hash_tree "$HOME")
run_setup codex
has "  = ~/.codex/AGENTS.md   unchanged"
has "  = ~/.codex/hooks.json   unchanged"
has "done. Nothing to change."
has "Reminder: $(trust_line "$CH")"
[ "$(hash_tree "$HOME")" = "$h1" ] || fail "a second codex hooks run changed a file"
ok "AGENTS.md block plus four tagged hooks, existing hooks and keys kept, a rerun changes nothing"

echo
echo "TEST: codex hooks: a dry run writes nothing, a fresh install makes a private hooks.json, and the trust line is printed verbatim"
reset
h0=$(hash_tree "$HOME")
run_setup codex --dry-run
[ "$RC" = 0 ] || fail "codex dry run: exit $RC: $OUT"
has "  + would add 4 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop) to ~/.codex/hooks.json"
has "dry run: nothing was written."
[ "$(hash_tree "$HOME")" = "$h0" ] || fail "a codex dry run wrote"
run_setup codex
[ "$RC" = 0 ] || fail "codex fresh install: exit $RC: $OUT"
has "  + ~/.codex/hooks.json   added 4 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop)"
grep -qxF "done. $(trust_line "$HOME/.codex/hooks.json")" <<<"$OUT" || { echo "$OUT" >&2; fail "trust line"; }
[ "$(mode "$HOME/.codex/hooks.json")" = 600 ] && [ "$(mode "$HOME/.codex")" = 700 ] || fail "fresh hooks.json modes"
[ -z "$(ls "$HOME/.codex" | grep -F .bak || true)" ] || fail "a fresh install made a backup"
run_setup codex --json
"$PY" -I - "$OUT" <<'PY' || fail "codex --json lacks the hooks change"
import json, sys
d = json.loads(sys.argv[1])
assert d["target"] == "codex" and [c["action"] for c in d["changes"]] == ["unchanged", "unchanged", "unchanged"], d
PY
ok "dry run: nothing written; fresh install 0600 in 0700; trust line exact; --json lists both files and the shell check"

echo
echo "TEST: codex hooks: uninstall gives parsed-JSON equality with the original plus an edit made after install"
reset; mkdir -p "$HOME/.codex"; CH="$HOME/.codex/hooks.json"
printf '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}, "z": 1}\n' >"$CH"; cp "$CH" "$T/ch.orig"
run_setup codex >/dev/null
"$PY" -I - "$CH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["model"] = "x"; d["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "echo late"}]})
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
run_setup codex --uninstall
[ "$RC" = 0 ] || fail "codex hooks uninstall: exit $RC: $OUT"
has "  - ~/.codex/hooks.json   removed the agentbus hooks; the file as it was is saved as $(ls "$HOME/.codex" | grep '^hooks.json.agentbus-' | tail -1)"
lacks "trust"
"$PY" -I - "$CH" "$T/ch.orig" <<'PY' || fail "codex uninstall did not leave the original plus the user's edit"
import json, sys
now = json.load(open(sys.argv[1])); orig = json.load(open(sys.argv[2]))
orig["model"] = "x"; orig["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "echo late"}]})
assert now == orig, (now, orig)
PY
grep -q 'agentbus' "$HOME/.codex/AGENTS.md" && fail "the AGENTS.md block is still there after uninstall"
reset; run_setup codex >/dev/null; run_setup codex --uninstall >/dev/null
[ ! -e "$HOME/.codex/hooks.json" ] && [ -z "$(ls "$HOME/.codex" | grep -F .bak || true)" ] || fail "uninstalling from a file we made left a file or a backup behind"
ok "tagged entries gone, everything else (including the edit) kept"

echo
echo "TEST: codex hooks: an invalid hooks.json is refused and nothing is written; AGENTS.md past 32 KiB is refused with its message"
reset; mkdir -p "$HOME/.codex"; printf '{ not json' >"$HOME/.codex/hooks.json"; cp "$HOME/.codex/hooks.json" "$T/ch.bad"
run_setup codex
[ "$RC" = 1 ] && grep -qF "is not valid JSON; not changed." <<<"$OUT" || fail "invalid hooks.json: exit $RC: $OUT"
cmp -s "$HOME/.codex/hooks.json" "$T/ch.bad" || fail "invalid hooks.json was changed"
[ ! -e "$HOME/.codex/AGENTS.md" ] || fail "the AGENTS.md block was written although hooks.json was refused"
reset; mkdir -p "$HOME/.codex"
"$PY" -c 'import sys; sys.stdout.write("x" * 32700 + "\n")' >"$HOME/.codex/AGENTS.md"; cp "$HOME/.codex/AGENTS.md" "$T/big.orig"
run_setup codex
[ "$RC" = 1 ] && grep -qF "AGENTS.md would exceed 32 KiB; shorten it or use --scope project" <<<"$OUT" || fail "oversize AGENTS.md: exit $RC: $OUT"
cmp -s "$HOME/.codex/AGENTS.md" "$T/big.orig" || fail "an oversize AGENTS.md was changed"
[ ! -e "$HOME/.codex/hooks.json" ] || fail "hooks.json was written although AGENTS.md was refused"
"$PY" -c 'import sys; sys.stdout.write("x" * 32000 + "\n")' >"$HOME/.codex/AGENTS.md"
run_setup codex; [ "$RC" = 0 ] || fail "an AGENTS.md that stays under 32 KiB was refused: $RC $OUT"
run_setup codex --uninstall; [ "$RC" = 0 ] || fail "uninstall from a big AGENTS.md was refused: $RC $OUT"
ok "invalid JSON and an oversize AGENTS.md are refused up front; under the cap installs and uninstalls"

echo
echo "TEST: codex hooks: an AGENTS.override.md that is not empty is reported, because Codex reads it instead of AGENTS.md"
reset; mkdir -p "$HOME/.codex"; printf 'rules\n' >"$HOME/.codex/AGENTS.override.md"
run_setup codex
[ "$RC" = 0 ] || fail "override: exit $RC: $OUT"
has "  ! ~/.codex/AGENTS.override.md   is not empty, so Codex reads it instead of AGENTS.md and ignores the agentbus block; empty or remove it"
: >"$HOME/.codex/AGENTS.override.md"; run_setup codex
lacks "AGENTS.override.md"
ok "a non-empty override file is named; an empty one is not"

echo
echo "TEST: codex hooks: --scope project writes ./AGENTS.md and ./.codex/hooks.json under the current directory only"
reset; h0=$(hash_tree "$HOME")
run_setup codex --scope project
[ "$RC" = 0 ] && [ -f "$W/AGENTS.md" ] && [ -f "$W/.codex/hooks.json" ] && [ "$h0" = "$(hash_tree "$HOME")" ] || fail "project hooks: exit $RC, $OUT"
grep -qF ".codex/hooks.json   added 4 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop)" <<<"$OUT" || fail "project hooks line: $OUT"
ok "project scope: both files are under the work folder"

echo
echo "TEST: codex hooks: check reads text only, vouches only for hooks that run this agentbus (every entry), and says trust cannot be checked"
reset; run_setup codex >/dev/null
rows() { "$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$HOME/.codex/hooks.json" "$1" <<'PY'
import json, runpy, shlex, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_check")
# the running tool is the one setup recorded: this interpreter and this file
for r in m["CodexHooksPiece"]().check(sys.argv[3]):
    print(r[0], r[1], r[2] if r[0] in ("codex_trust", "codex_hooks_tool") else "")
PY
}
# set_tool EVENT TOOLWORD: point one event's agentbus entry at another executable (EVENT "all": every entry)
set_tool() {
  "$PY" -I - "$HOME/.codex/hooks.json" "$1" "$2" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for event, groups in d["hooks"].items():
    for g in groups:
        for h in g["hooks"]:
            if sys.argv[2] in ("all", event):
                h["command"] = re.sub(r"^.*? hook codex", sys.argv[3] + " hook codex", h["command"])
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
}
got=$(cd "$W" && rows user)
grep -qx "codex_hooks ok " <<<"$got" && grep -q "^codex_hooks_tool ok the hooks run " <<<"$got" && grep -qx "codex_trust ok Codex trust cannot be checked from outside Codex; type /hooks to confirm" <<<"$got" || fail "check after install: $got"
! grep -q login_shell <<<"$got" || fail "check reports the login shell, which only setup looks at"
(cd "$W" && "${AB[@]}" setup codex --scope project >/dev/null)
got=$(cd "$W" && rows user); grep -qx "codex_hooks_duplicate problem " <<<"$got" || fail "check with user and project hooks both present: $got"
rm -rf "$W/.codex"
# a hooks file can be a project's: check looks at the executable it names and never starts it
mkdir -p "$T/planted"; printf '#!/bin/sh\ntouch "%s"\n' "$T/canary-check" >"$T/planted/agentbus"; chmod +x "$T/planted/agentbus"
# one forged entry among genuine ones is not vouched for: every tagged command is checked, not only the first
run_setup codex --uninstall >/dev/null; run_setup codex >/dev/null
set_tool Stop "'$T/planted/agentbus'"
got=$(cd "$W" && rows user)
grep -q "^codex_hooks_tool stale 1 of 4 hook commands run $T/planted/agentbus, not this agentbus" <<<"$got" || fail "check with one forged entry among four: $got"
run_setup codex --uninstall >/dev/null; run_setup codex >/dev/null
set_tool all "'$T/planted/agentbus'"
got=$(cd "$W" && rows user)
[ ! -e "$T/canary-check" ] || fail "check started the executable a hooks file names"
grep -q "^codex_hooks_tool stale 4 of 4 hook commands run $T/planted/agentbus, not this agentbus" <<<"$got" || fail "check with a planted agentbus executable (a readable file named agentbus is not this agentbus): $got"
set_tool all "'/nonexistent/agentbus'"
got=$(cd "$W" && rows user); grep -q "^codex_hooks_tool problem the hooks run /nonexistent/agentbus, which is not an agentbus executable" <<<"$got" || fail "check with a missing executable: $got"
ok "check: ok after install with the trust row; a planted, forged-in-one-entry or missing executable and a doubled install are problems; nothing the file names is started"

echo
echo "TEST: setup help says what setup installs for both targets, and that Codex needs /hooks"
help=$("${AB[@]}" setup --help | tr -s ' \n' '  ')
grep -qF "the skill and hooks for Claude Code, the AGENTS.md block and hooks for Codex" <<<"$help" || fail "setup help does not mention the hooks: $help"
grep -qF "claude (skill and hooks) or codex (AGENTS.md block and hooks, then /hooks in Codex to trust them)" <<<"$help" || fail "setup target help does not mention the hooks: $help"
grep -qF "Codex runs the hooks only after you approve them with /hooks" <<<"$help" || fail "setup help does not mention the trust step: $help"
schema_out=$("${AB[@]}" --json schema)   # not piped into grep -q: under pipefail an early grep exit can fail the writer
grep -qF "Install the skill and hooks for Claude Code, or the AGENTS.md block and hooks for Codex" <<<"$schema_out" || fail "the setup entry of schema does not mention the hooks"
ok "setup --help and schema name the hooks and the trust step"

echo
echo "TEST: a project's .codex or .claude that is a link is refused, in a dry run and an uninstall too, and nothing is written through it"
PW=$(cd "$W" && pwd -P)
for target in codex claude; do
  dir=".$target"
  for mode in "" "--dry-run" "--uninstall"; do
    reset; mkdir -p "$T/out"; rm -rf "$T/out"/*; mkdir -p "$T/out"; ln -s "$T/out" "$W/$dir"
    run_setup "$target" --scope project $mode
    [ "$RC" = 1 ] && grep -qF "$PW/$dir is a link, so setup would write outside this project; not changed." <<<"$OUT" || fail "a linked $dir ($mode): exit $RC: $OUT"
    [ -z "$(ls -A "$T/out")" ] || fail "setup $target $mode wrote through a linked $dir: $(ls -A "$T/out")"
  done
  # a relative link, and a link to the user's own config folder
  reset; mkdir -p "$T/out" "$HOME/.$target"; ln -s ../out "$W/$dir" 2>/dev/null || true; h0=$(hash_tree "$HOME")
  rm -f "$W/$dir"; ln -s "$HOME/.$target" "$W/$dir"
  run_setup "$target" --scope project
  [ "$RC" = 1 ] && [ "$h0" = "$(hash_tree "$HOME")" ] || fail "a $dir linked to the user's ~/.$target was written through: exit $RC: $OUT"
  # a link further down: .claude real, skills a link (claude); a real folder is fine
  reset; run_setup "$target" --scope project; [ "$RC" = 0 ] || fail "a real $dir was refused: $RC $OUT"
done
# the skill piece guards it on its own: with the plugin providing the hooks, the hooks piece plans nothing
reset; mkdir -p "$HOME/.claude/plugins" "$T/out"; rm -rf "$T/out"/*
printf '{"plugins":{"agentbus@agentbus":[{"scope":"user"}]}}' >"$HOME/.claude/plugins/installed_plugins.json"; ln -s "$T/out" "$W/.claude"
run_setup claude --scope project
[ "$RC" = 1 ] && [ -z "$(ls -A "$T/out")" ] || fail "a linked .claude was written through when the plugin provides the hooks: exit $RC: $OUT"
ok "a linked .codex or .claude is refused by name for install, dry run and uninstall; a link to ~/.codex or ~/.claude is not followed; a real folder works"

echo
echo "TEST: setup codex looks at the login shell once; a read-only check never starts it"
printf '#!/bin/sh\nprintf "%%s" "$AGENTBUS_SHELL_PROBE" >"%s"\nexit 0\n' "$T/probe.env" >"$T/shells/spy"; chmod +x "$T/shells/spy"
printf '#!/bin/sh\necho "welcome back, fortune of the day"\nexit 0\n' >"$T/shells/noisy"; chmod +x "$T/shells/noisy"
export SHELL="$T/shells/spy"; reset; rm -f "$T/probe.env"
run_setup codex --dry-run
has "  = would start your login shell $T/shells/spy once (as \$SHELL -lc) to check that it prints nothing at startup"
[ ! -e "$T/probe.env" ] || fail "a dry run started the login shell"
run_setup codex
has "  = $T/shells/spy   prints nothing at startup (started once as \$SHELL -lc)"
[ "$(cat "$T/probe.env")" = 1 ] || fail "the login shell was not told it is being probed (AGENTBUS_SHELL_PROBE=1): $(cat "$T/probe.env" 2>&1)"
rm -f "$T/probe.env"; "$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$HOME/.codex/hooks.json" <<'PY' >/dev/null
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_check")
m["CodexHooksPiece"]().check("user")
PY
[ ! -e "$T/probe.env" ] || fail "check started the user's login shell"
export SHELL="$T/shells/noisy"; reset
run_setup codex
[ "$RC" = 0 ] && has "  ! $T/shells/noisy   printed 33 bytes at startup, which Codex puts in front of each hook's output and breaks it; make the profile print nothing unless it runs in a terminal (for example [ -t 1 ])" || fail "setup with a login shell that prints: $RC $OUT"
lacks fortune
run_setup codex --json; "$PY" -I - "$OUT" "$T/shells/noisy" <<'PY' || fail "--json does not report the noisy login shell as skipped"
import json, sys
c = json.loads(sys.argv[1])["changes"][-1]
assert c["path"] == sys.argv[2] and c["action"] == "skipped" and "33" in c["detail"], c
PY
# a profile that leaves a process running, and one that never finishes: setup does not hang, reports unknown, leaves nothing
printf '#!/bin/sh\nsleep 300 &\necho $! >"%s"\nexit 0\n' "$T/sleeper.pid" >"$T/shells/sleeper"; chmod +x "$T/shells/sleeper"
export SHELL="$T/shells/sleeper"; reset; rm -f "$T/sleeper.pid"
t0=$(date +%s); run_setup codex; t1=$(date +%s)
[ "$RC" = 0 ] && [ $((t1 - t0)) -lt 8 ] && has "  = $T/shells/sleeper   prints nothing at startup (started once as \$SHELL -lc)" || fail "a profile that leaves a process running: exit $RC after $((t1 - t0)) s: $OUT"
orphan() { for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$(cat "$1")" 2>/dev/null || return 1; sleep 0.3; done; return 0; }
! orphan "$T/sleeper.pid" || { kill "$(cat "$T/sleeper.pid")" 2>/dev/null || true; fail "the login shell's background process outlived setup"; }
printf '#!/bin/sh\nsleep 300 &\necho $! >"%s"\nwait\n' "$T/hang.pid" >"$T/shells/hang"; chmod +x "$T/shells/hang"
export SHELL="$T/shells/hang"; reset; rm -f "$T/hang.pid"
AGENTBUS_TEST_SHELL_PROBE=2 run_setup codex --json
"$PY" -I - "$OUT" <<'PY' || fail "a login shell that never finishes was reported as fine"
import json, sys
c = json.loads(sys.argv[1])["changes"][-1]
assert c["action"] == "skipped" and "could not tell" in c["detail"], c
PY
! orphan "$T/hang.pid" || { kill "$(cat "$T/hang.pid")" 2>/dev/null || true; fail "a login shell that never finished left a process running"; }
AGENTBUS_TEST_SHELL_PROBE=2 run_setup codex; grep -qF "did not finish within 2 s as \$SHELL -lc, so setup cannot tell whether it prints at startup" <<<"$OUT" || fail "the timeout line: $OUT"
export SHELL="$T/shells/quiet"
ok "dry run does not start it; setup starts it once with AGENTBUS_SHELL_PROBE=1; a noisy one is reported by size, a hanging or backgrounding one is bounded and killed; check never starts it"

echo
echo "TEST: setup codex says when the login shell is not POSIX, and does not start it"
for sh in fish nu xonsh elvish; do
  printf '#!/bin/sh\ntouch "%s"\n' "$T/canary-$sh" >"$T/shells/$sh"; chmod +x "$T/shells/$sh"
  export SHELL="$T/shells/$sh"; reset
  run_setup codex
  [ "$RC" = 0 ] && has "  ! $T/shells/$sh   is not a POSIX shell, but Codex runs each hook command through \$SHELL -lc and the command setup wrote needs sh, bash or zsh. Start Codex as: SHELL=/bin/sh codex" || fail "a $sh login shell: exit $RC: $OUT"
  [ ! -e "$T/canary-$sh" ] || fail "setup started a $sh login shell"
done
export SHELL="$T/shells/quiet"
ok "fish, nu, xonsh and elvish get the POSIX-shell note and are not started"

echo
echo "TEST: the trust step is in every codex result: project scope says the project must be trusted; a rerun reminds; output is not wrapped in a pipe"
reset; run_setup codex --scope project
[ "$RC" = 0 ] && has "done. $(trust_line "$W/.codex/hooks.json" project)" || fail "project trust line: $RC $OUT"
run_setup codex --scope project; has "Reminder: $(trust_line "$W/.codex/hooks.json" project)"
reset
out=$(cd "$W" && env -u COLUMNS "${AB[@]}" setup codex --dry-run | cat)
grep -qxF "  + would add 4 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop) to ~/.codex/hooks.json" <<<"$out" || { echo "$out" >&2; fail "setup output was wrapped in a pipe"; }
ok "project trust note, rerun reminder, and one line per change when stdout is not a terminal"

echo
echo "All setup tests passed"
