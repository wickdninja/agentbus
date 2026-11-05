#!/bin/bash
set -euo pipefail
# Workflow: `agentbus setup` into a HOME that already has someone's settings, a custom skill and a Codex
# AGENTS.md. Walks the whole life of an install: dry run, install, rerun, a user's own edit outside the
# managed text, a tool change (a managed file edited by hand is replaced and its old bytes saved), a file
# agentbus did not write (refused, untouched), the old `ln -s` skill link (replaced, its target untouched),
# and uninstall. Proves custom files are untouched or refused, replaced files are backed up, parsed JSON
# equals the original, and an unchanged rerun writes nothing (content and inode: every write here replaces the file, so an unchanged inode means no write). Runs once `setup` exists.
# Runs on the source script, a mutation copy (AGENTBUS_BIN) and an installed command (AGENTBUS_CMD).
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/workflow_lib.sh"
wf_setup
if ! agentbus setup --help >/dev/null 2>&1; then
  skip_test "agentbus setup does not exist in this build"
fi
C="$HOME/.claude"; X="$HOME/.codex"
SKILL="$C/skills/agentbus/SKILL.md"
bytes=$(agentbus skill | wc -c | tr -d ' ')
bytes=$(python3 -c 'import sys; print(format(int(sys.argv[1]), ","))' "$bytes")
# snapshot FILE...: size, mode and sha256 of each, to prove a file was not touched.
snapshot() { python3 - "$@" <<'PY'
import hashlib, os, sys
for p in sys.argv[1:]:
    st = os.lstat(p)
    print(p, st.st_size, oct(st.st_mode & 0o7777), hashlib.sha256(open(p, "rb").read()).hexdigest())
PY
}
# The hooks piece saves settings.json as it was before every change (settings.json.agentbus-<UTC stamp>.bak): the stamp is not part of the transcript.
eval "$(declare -f norm | sed '1s/^norm /norm_base /')"
# The trust line names the installed tool by absolute path, which differs per machine; setup also looks at the login shell once.
export SHELL=/bin/sh
norm() { norm_base | sed -E -e 's/\.agentbus-[0-9]{8}T[0-9]{6}\.[0-9]{6}Z\.bak/.agentbus-<stamp>.bak/g' -e 's/command starts .* hook codex and ends/command starts TOOL hook codex and ends/'; }
# settings_ok: settings.json keeps the user's keys and carries the five tagged hook entries (or, with "bare", only the user's keys).
settings_ok() { python3 - "$C/settings.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d.pop("hooks", None)
assert d == {"theme": "dark", "permissions": {"allow": ["Bash(ls)"]}}, d
if sys.argv[2] == "hooks":
    assert sorted(hooks) == ["PreToolUse", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"], hooks
    assert all(g["hooks"][0]["command"].endswith("# agentbus:managed") for gs in hooks.values() for g in gs), hooks
else:
    assert hooks is None, hooks
PY
}
inode() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$1"; }
files_under() { find "$HOME/.claude" "$HOME/.codex" -type f -o -type l 2>/dev/null | sort; }

echo "STEP 1: a HOME that already has settings, a custom skill and an AGENTS.md"
mkdir -p "$C/skills/other" "$X"
printf '{\n  "theme": "dark",\n  "permissions": {\n    "allow": ["Bash(ls)"]\n  }\n}\n' > "$C/settings.json"
printf -- '---\nname: other\ndescription: mine\n---\nhello\n' > "$C/skills/other/SKILL.md"
printf '# My notes\n\nbe nice\n' > "$X/AGENTS.md"
cp "$X/AGENTS.md" "$T/agents.orig"
MINE=$(snapshot "$C/skills/other/SKILL.md")
BEFORE=$(files_under)
ok "fixture written"

echo "STEP 2: a dry run says what it would do and writes nothing"
say "agentbus setup claude (user)
  + would install ~/.claude/skills/agentbus/SKILL.md ($bytes bytes)
  + would add 5 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop, SessionEnd) to ~/.claude/settings.json; the file as it was is saved as settings.json.agentbus-<date and time>.bak
dry run: nothing was written." agentbus setup claude --dry-run
is_equal "no file appeared" "$BEFORE" "$(files_under)"
ok "dry run wrote nothing"

echo "STEP 3: install leaves the user's own files alone"
say "agentbus setup claude (user)
  + ~/.claude/skills/agentbus/SKILL.md   installed, $bytes bytes
  + ~/.claude/settings.json   added 5 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop, SessionEnd); the file as it was is saved as settings.json.agentbus-<stamp>.bak
done. Start a new Claude Code session to load them.
next: cd your-repo && agentbus init ." agentbus setup claude
cmp -s "$SKILL" <(agentbus skill) || fail "the installed skill is not what \`agentbus skill\` prints"
is_equal "the custom skill is byte-identical" "$MINE" "$(snapshot "$C/skills/other/SKILL.md")"
settings_ok hooks || fail "settings.json lost the user's keys or lacks the five hook entries"
[ "$(mode "$SKILL")" = 600 ] || fail "the installed skill is mode $(mode "$SKILL"), want 600"
ok "skill and hooks installed, user keys and files untouched"

echo "STEP 4: an unchanged rerun reports unchanged and writes nothing"
I1=$(inode "$SKILL"); S1=$(snapshot "$SKILL")
out=$(agentbus setup claude)
grep -qxF "  = ~/.claude/skills/agentbus/SKILL.md   unchanged" <<<"$out" && ! grep -q 'installed\|updated' <<<"$out" || fail "rerun: $out"
is_equal "bytes equal after a rerun" "$S1" "$(snapshot "$SKILL")"
is_equal "same file (inode) after a rerun: nothing was rewritten" "$I1" "$(inode "$SKILL")"
ok "rerun wrote nothing"

echo "STEP 5: the Codex block is added after the user's text, and the user's later edit outside it survives a rerun"
say "agentbus setup codex (user)
  + ~/.codex/AGENTS.md   added the agentbus block (4 lines)
  + ~/.codex/hooks.json   added 4 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop)
  = /bin/sh   prints nothing at startup (started once as \$SHELL -lc)
done. Codex ignores hooks until you trust them: start codex, open its Hooks need review screen (or type /hooks), and approve the 4 entries whose command starts TOOL hook codex and ends # agentbus:managed.
next: cd your-repo && agentbus init ." agentbus setup codex
head -c "$(wc -c <"$T/agents.orig")" "$X/AGENTS.md" | cmp -s - "$T/agents.orig" || fail "the user's AGENTS.md text was changed"
[ "$(grep -c '^<!-- agentbus:begin -->$' "$X/AGENTS.md")" = 1 ] && [ "$(grep -c '^<!-- agentbus:end -->$' "$X/AGENTS.md")" = 1 ] || fail "markers: $(cat "$X/AGENTS.md")"
printf '\n## my later note\nkeep me\n' >> "$X/AGENTS.md"
out=$(agentbus setup codex)
grep -qxF "  = ~/.codex/AGENTS.md   unchanged" <<<"$out" || fail "codex rerun: $out"
grep -qx 'keep me' "$X/AGENTS.md" || fail "the user's later note was lost"
ok "codex block added once, outside text preserved"

echo "STEP 6: a managed file edited by hand is replaced and the edit saved beside it"
python3 - "$SKILL" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
lines.insert(3, "MY OWN LINE")
open(sys.argv[1], "w").write("\n".join(lines))
PY
out=$(agentbus setup claude)
cmp -s "$SKILL" <(agentbus skill) || fail "the edited skill was not replaced: $out"
# the saved copy is SKILL.md.agentbus-<UTC time>.bak (ws02: a new name per save, never overwriting an older one)
baks=$(cd "$(dirname "$SKILL")" && ls SKILL.md.agentbus-*.bak 2>/dev/null || true)
[ "$(printf '%s\n' "$baks" | grep -c .)" = 1 ] || fail "wanted one SKILL.md.agentbus-*.bak, found: $baks"
grep -qx 'MY OWN LINE' "$(dirname "$SKILL")/$baks" || fail "the user's edit was not saved in $baks"
grep -qF "your edited copy is saved as $baks" <<<"$out" || fail "the run did not name the saved copy: $out"
ok "replaced, edit kept in SKILL.md.agentbus-<time>.bak"

echo "STEP 7: a file agentbus did not write is refused and left alone"
rm -f "$(dirname "$SKILL")"/SKILL.md.agentbus-*.bak; printf 'custom skill text\n' > "$SKILL"
CUSTOM=$(snapshot "$SKILL")
rc=0; out=$(agentbus setup claude) || rc=$?
[ "$rc" = 1 ] || fail "refusal exited $rc, want 1"
grep -qxF "  ! ~/.claude/skills/agentbus/SKILL.md exists and was not written by agentbus; not changed. Move it aside, or run: agentbus setup claude --scope project" <<<"$out" || fail "refusal text: $out"
is_equal "the refused file is untouched" "$CUSTOM" "$(snapshot "$SKILL")"
j=$(agentbus --json setup claude 2>/dev/null) || true   # a refusal exits 1 and still prints its result
python3 -c '
import json, sys
r = json.loads(sys.argv[1])
assert r["target"] == "claude" and [c["action"] for c in r["changes"]] == ["refused"], r' "$j" || fail "--json refusal: $j"
ok "refused with the documented line, exit 1, file untouched"

echo "STEP 8: the old README symlink is replaced, never its target"
rm -rf "$C/skills/agentbus"
mkdir -p "$R/oldclone/skill"; printf -- '---\nname: agentbus\n---\nthe old skill\n' > "$R/oldclone/skill/SKILL.md"
OLD=$(snapshot "$R/oldclone/skill/SKILL.md")
ln -s "$R/oldclone/skill" "$C/skills/agentbus"
say "agentbus setup claude (user)
  ~ ~/.claude/skills/agentbus   replaced the link to <REPO>/oldclone/skill (the old install line)
  + ~/.claude/skills/agentbus/SKILL.md   installed, $bytes bytes
  = ~/.claude/settings.json   unchanged
done. Start a new Claude Code session to load them.
next: cd your-repo && agentbus init ." agentbus setup claude
[ ! -L "$C/skills/agentbus" ] && [ -d "$C/skills/agentbus" ] || fail "the skill link was not replaced by a directory"
is_equal "the old clone's skill is untouched" "$OLD" "$(snapshot "$R/oldclone/skill/SKILL.md")"
ok "link replaced, target untouched"

echo "STEP 9: uninstall removes only what agentbus added"
out=$(agentbus setup claude --uninstall)
grep -qxF "  - removed ~/.claude/skills/agentbus/" <<<"$out" || fail "uninstall: $out"
[ ! -e "$C/skills/agentbus" ] || fail "the skill directory is still there"
is_equal "the custom skill after uninstall" "$MINE" "$(snapshot "$C/skills/other/SKILL.md")"
settings_ok bare || fail "uninstall left a hook entry or changed the user's keys"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1])) == {"theme": "dark", "permissions": {"allow": ["Bash(ls)"]}}' "$C/settings.json" || fail "settings.json parsed differently"
out=$(agentbus setup codex --uninstall)
grep -qxF "  - ~/.codex/AGENTS.md   removed the agentbus block" <<<"$out" || fail "codex uninstall: $out"
! grep -q 'agentbus:' "$X/AGENTS.md" || fail "a marker is still in AGENTS.md"
head -c "$(wc -c <"$T/agents.orig")" "$X/AGENTS.md" | cmp -s - "$T/agents.orig" || fail "the original AGENTS.md text changed"
grep -qx 'keep me' "$X/AGENTS.md" || fail "the user's later note was lost on uninstall"
ok "uninstall removed the skill and the block; the user's files and later edits remain"
echo "All workflow setup cycle tests passed"
