#!/bin/bash
set -euo pipefail
# agentbus setup TARGET --refresh (what `agentbus update` runs after a new release): bring up to date what setup
# installed, add nothing, and keep anything the user edited. Runs in a temp HOME; no real config folder is touched.
# Targets: claude (the skill and the hooks in settings.json) and codex (the AGENTS.md block).
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR CODEX_HOME AGENTBUS_TEST_SETUP_FAIL AGENTBUS_TEST_SETUP_JSON AGENTBUS_TEST_SETUP_NO_HOOKS
W="$T/work"; mkdir -p "$W"
SK="$HOME/.claude/skills/agentbus/SKILL.md"; SET="$HOME/.claude/settings.json"; AG="$HOME/.codex/AGENTS.md"
run() { RC=0; OUT=$(cd "$W" && "${AB[@]}" "$@" 2>&1) || RC=$?; }
tree_sum() { find "$HOME" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum <"$f")"; done | cksum; }
reset() { rm -rf "$HOME" "$W"; mkdir -p "$HOME" "$W"; }
has() { grep -qxF -- "$1" <<<"$OUT" || { echo "output was:" >&2; echo "$OUT" >&2; fail "$2"; }; }
# an older tool: this checkout with a text it once shipped in its hash history, so that text counts as unedited
OLD_SKILL=$'old skill text\n\n<!-- agentbus:managed -->\n'
OLD_BLOCK=$'older block\n'
HIST="$T/hist"; mkdir -p "$HIST"
"$PY" - "$BIN" "$HIST/agentbus" "$OLD_SKILL" "$OLD_BLOCK" <<'PY'
import hashlib, sys
src, dst, skill, block = sys.argv[1:]
s = open(src).read()
h = lambda t: hashlib.sha256(t.encode()).hexdigest()
s = s.replace("SKILL_SHA256_HISTORY = (\n", 'SKILL_SHA256_HISTORY = (\n    "%s",\n' % h(skill), 1)
s = s.replace("AGENTS_SHA256_HISTORY = (\n", 'AGENTS_SHA256_HISTORY = (\n    "%s",\n' % h(block), 1)
open(dst, "w").write(s)
PY
HT=("$PY" "$HIST/agentbus")   # the tool that knows the old texts
runh() { RC=0; OUT=$(cd "$W" && "${HT[@]}" "$@" 2>&1) || RC=$?; }

echo "TEST 1: nothing installed: --refresh adds nothing, writes nothing, exits 0 (claude and codex)"
reset
for t in claude codex; do
  before=$(tree_sum); run setup "$t" --refresh
  [ "$RC" = 0 ] || fail "refresh of nothing exited $RC for $t: $OUT"
  [ "$(tree_sum)" = "$before" ] && [ -z "$(ls -A "$HOME")" ] || fail "refresh of nothing wrote something for $t"
  has "done. Nothing to change." "refresh of nothing did not say there was nothing to change for $t"
done
grep -qF "not installed" <<<"$OUT" || fail "the codex line does not say not installed: $OUT"
ok "nothing is added"

echo "TEST 2: everything current: nothing is rewritten, the second run is the same"
reset; run setup claude >/dev/null; run setup codex >/dev/null
before=$(tree_sum)
for t in claude codex; do
  run setup "$t" --refresh --json
  [ "$RC" = 0 ] && "$PY" -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["changes"] and all(c["action"] == "unchanged" for c in d["changes"]), d' "$OUT" || fail "current $t: refresh changed something or exited $RC: $OUT"
done
[ "$(tree_sum)" = "$before" ] || fail "a refresh of current files changed the tree"
ok "all unchanged"

echo "TEST 3: an older, unedited skill and block are updated in place, with no backup; text outside the block stays"
reset; mkdir -p "$(dirname "$SK")" "$(dirname "$AG")"
printf '%s' "$OLD_SKILL" >"$SK"
printf 'my notes\n\n<!-- agentbus:begin -->\n%s<!-- agentbus:end -->\n\nmore of mine\n' "$OLD_BLOCK" >"$AG"
run setup claude --refresh --dry-run
[ "$(cat "$SK")" = "$(printf '%s' "$OLD_SKILL")" ] || fail "a dry-run refresh wrote the skill"
runh setup claude --refresh
[ "$RC" = 0 ] && [ "$(cat "$SK")" = "$("${AB[@]}" skill)" ] || fail "an older unedited skill was not brought up to date (rc $RC): $OUT"
runh setup codex --refresh
[ "$RC" = 0 ] && grep -qF "my notes" "$AG" && grep -qF "more of mine" "$AG" && ! grep -qF "older block" "$AG" || fail "the older block was not replaced inside its markers (rc $RC): $OUT"
[ -z "$(ls "$(dirname "$SK")" | grep -v '^SKILL.md$')" ] && [ -z "$(ls "$(dirname "$AG")" | grep -v '^AGENTS.md$')" ] || fail "a refresh of unedited text saved a backup"
ok "updated in place, nothing saved beside it"

echo "TEST 4: an edited skill and an edited block are kept exactly, named, with no backup and exit 0 (setup without --refresh replaces them)"
reset; mkdir -p "$(dirname "$SK")" "$(dirname "$AG")"
printf 'my own skill text\n\n<!-- agentbus:managed -->\n' >"$SK"
printf 'mine\n<!-- agentbus:begin -->\nmy edited block\n<!-- agentbus:end -->\n' >"$AG"
sk=$(cat "$SK"); ag=$(cat "$AG")
run setup claude --refresh
[ "$RC" = 0 ] || fail "an edited skill made refresh exit $RC: $OUT"
has "  = ~/.claude/skills/agentbus/SKILL.md   kept (edited). To replace it: agentbus setup claude" "the kept skill line is not the exact text"
run setup codex --refresh
[ "$RC" = 0 ] || fail "an edited block made refresh exit $RC: $OUT"
has "  = ~/.codex/AGENTS.md   kept (edited). To replace it: agentbus setup codex" "the kept block line is not the exact text"
[ "$(cat "$SK")" = "$sk" ] && [ "$(cat "$AG")" = "$ag" ] || fail "an edited piece was rewritten by refresh"
[ "$(ls "$(dirname "$SK")")" = SKILL.md ] && [ "$(ls "$(dirname "$AG")")" = AGENTS.md ] || fail "refresh saved a backup of an edit it kept"
run setup claude; [ "$(cat "$SK")" != "$sk" ] && ls "$(dirname "$SK")" | grep -q bak || fail "the control failed: plain setup should replace an edited skill and save a .bak"
ok "kept; plain setup (control) still replaces with a .bak"

echo "TEST 5: a skill agentbus did not write, a link and an unreadable block are kept, not refused (plain setup refuses them)"
reset; mkdir -p "$(dirname "$SK")"; printf 'someone else wrote this\n' >"$SK"
run setup claude; [ "$RC" = 1 ] || fail "the control failed: plain setup should refuse a skill agentbus did not write (rc $RC)"
run setup claude --refresh
[ "$RC" = 0 ] && grep -qF "kept (" <<<"$OUT" && [ "$(cat "$SK")" = "someone else wrote this" ] || fail "a foreign skill file was not kept by refresh (rc $RC): $OUT"
reset; mkdir -p "$HOME/.claude/skills" "$T/target"; ln -s "$T/target" "$HOME/.claude/skills/agentbus"
run setup claude --refresh
[ "$RC" = 0 ] && [ -L "$HOME/.claude/skills/agentbus" ] || fail "a skill folder that is a link was changed or refused by refresh (rc $RC): $OUT"
ok "kept, exit 0"

echo "TEST 6: hooks tagged agentbus:managed are brought up to date; your own hooks and settings stay; no hooks are added where there are none"
reset; run setup claude >/dev/null
"$PY" -I - "$SET" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
assert d["hooks"], d
for groups in d["hooks"].values():
    for g in groups:
        for h in g["hooks"]:
            h["command"] = h["command"].replace(" hook claude ", " hook claude STALE ", 1)
d["hooks"].setdefault("SessionStart", []).append({"hooks": [{"type": "command", "command": "echo mine"}]})
d["theme"] = "dark"
json.dump(d, open(p, "w"), indent=2)
PY
run setup claude --refresh
[ "$RC" = 0 ] || fail "refresh of stale hooks exited $RC: $OUT"
"$PY" -I - "$SET" <<'PY' || fail "refresh did not repair the tagged hooks, or touched what is the user's"
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for gs in d["hooks"].values() for g in gs for h in g["hooks"]]
assert not any("STALE" in c for c in cmds), cmds
assert any(c == "echo mine" for c in cmds) and d["theme"] == "dark", d
assert sum(c.rstrip().endswith("# agentbus:managed") for c in cmds) >= 1, cmds
PY
reset; run setup claude >/dev/null; "$PY" -I -c 'import json,sys; json.dump({"theme": "light"}, open(sys.argv[1], "w"))' "$SET"
run setup claude --refresh
[ "$("$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1])))' "$SET")" = "{'theme': 'light'}" ] || fail "refresh added hooks to a settings file that had none of ours: $OUT"
ok "tagged hooks repaired; user entries kept; none added"

echo "TEST 7: the project scope refreshes the project's own files, and --refresh with --uninstall is a usage error"
reset; mkdir -p "$W/.claude/skills/agentbus"; printf '%s' "$OLD_SKILL" >"$W/.claude/skills/agentbus/SKILL.md"
runh setup claude --scope project --refresh
[ "$RC" = 0 ] && [ "$(cat "$W/.claude/skills/agentbus/SKILL.md")" = "$("${AB[@]}" skill)" ] || fail "the project skill was not refreshed (rc $RC): $OUT"
[ ! -e "$HOME/.claude" ] || fail "a project refresh wrote the user's config"
run setup claude --refresh --uninstall; [ "$RC" = 2 ] || fail "--refresh --uninstall exited $RC, wanted 2: $OUT"
ok "project scope; usage error"

all_passed "All setup refresh tests passed"
