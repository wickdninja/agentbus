#!/bin/bash
set -euo pipefail
# agentbus setup while a folder on its way is swapped for a link (issue #27). Each case stops setup at a test pause, moves
# the real folder aside, puts a link to a victim folder in its place and lets setup go on: the victim must not change.
# Everything runs in a temp HOME; no test touches a real config folder.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
unset CLAUDE_CONFIG_DIR CODEX_HOME AGENTBUS_TEST_SETUP_FAIL AGENTBUS_TEST_SETUP_JSON
export AGENTBUS_TEST_SETUP_NO_HOOKS=1   # the skill piece alone, unless a case asks for the hooks
W="$T/work"; V="$T/victim"; P="$T/pause"; A="$T/aside"
HELD=setup-dir-held   # the walk is done and setup holds the folder: the moment right before the write, rename or unlink

reset() { rm -rf "$HOME" "$W" "$V" "$P" "$A"; mkdir -p "$HOME" "$W" "$V" "$P"; }
run() { RC=0; OUT=$(cd "$W" && "${AB[@]}" setup "$@" 2>&1) || RC=$?; }
# hash_tree DIR: one hash over every path, file content and link target.
hash_tree() { "$PY" -I - "$1" <<'PY'
import hashlib, os, sys
h = hashlib.sha256()
for d, dirs, files in os.walk(sys.argv[1]):
    dirs.sort()
    for n in sorted(files + dirs):
        p = os.path.join(d, n)
        h.update(p.encode())
        if os.path.islink(p): h.update(os.readlink(p).encode())
        elif os.path.isfile(p): h.update(open(p, 'rb').read())
print(h.hexdigest())
PY
}
# swap_at POINT FOLDER ARGS...: run `setup ARGS`, stop it at POINT, swap FOLDER for a link to the victim, let it finish.
swap_at() {
  local point=$1 folder=$2 job; shift 2
  VICTIM=$(hash_tree "$V")
  (set +e; cd "$W"; AGENTBUS_TEST_PAUSE="$point=$P" "${AB[@]}" setup "$@" >"$T/out" 2>&1; echo $? >"$T/rc") &
  job=$!
  wait_for "$P/$point.reached"
  if [ -e "$folder" ]; then mv "$folder" "$A"; fi
  ln -s "$V" "$folder"
  : >"$P/$point.go"; wait "$job" || true
  RC=$(cat "$T/rc"); OUT=$(cat "$T/out")
}
victim_same() { [ "$VICTIM" = "$(hash_tree "$V")" ] || { find "$V" -print >&2; fail "$1"; }; }

echo "TEST: install: a folder swapped between the check and the rename does not move the write, and setup says so"
reset; mkdir -p "$V/skills/agentbus"
swap_at "$HELD" "$W/.claude" claude --scope project
victim_same "install wrote through a folder swapped in at the gap"
[ "$RC" = 1 ] && grep -qF "$W/.claude is a link, and became one while setup changed" <<<"$OUT" || fail "install: a swap at the gap was not reported: exit $RC: $OUT"
[ -f "$A/skills/agentbus/SKILL.md" ] || fail "install: the write did not stay in the folder setup held"
ok "the file stays in the folder setup held; the link is named"

echo "TEST: backup: the copy of an edited file is not written through a swapped folder"
reset; run claude --scope project; [ "$RC" = 0 ] || fail "backup: install: exit $RC: $OUT"
SK="$W/.claude/skills/agentbus/SKILL.md"
printf 'MY EDIT\n%s' "$(cat "$SK")" >"$SK"; cp -R "$W/.claude/." "$V/"
swap_at "$HELD" "$W/.claude" claude --scope project
victim_same "a backup went through a folder swapped in at the gap"
[ "$RC" = 1 ] || fail "backup: a swap at the gap: exit $RC: $OUT"
ls "$A/skills/agentbus/"*.bak >/dev/null 2>&1 || fail "backup: the copy did not stay in the folder setup held"
grep -q 'MY EDIT' "$A/skills/agentbus/SKILL.md" || fail "backup: the edited file was replaced after the swap"
ok "the backup stays in the folder setup held and the edited file stands"

echo "TEST: refresh: rewritten hooks do not go through a swapped folder"
reset; AGENTBUS_TEST_SETUP_NO_HOOKS= run claude --scope project; [ "$RC" = 0 ] || fail "refresh: install: exit $RC: $OUT"
"$PY" -I - "$W/.claude/settings.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); assert " hook " in s
open(p, "w").write(s.replace(" hook ", "  hook "))
PY
cp -R "$W/.claude/." "$V/"
AGENTBUS_TEST_SETUP_NO_HOOKS= swap_at "$HELD" "$W/.claude" claude --scope project --refresh
victim_same "a refresh went through a folder swapped in at the gap"
[ "$RC" = 1 ] || fail "refresh: a swap at the gap: exit $RC: $OUT"
ok "a refresh changes nothing through the link"

echo "TEST: uninstall: a file is not removed through a swapped folder"
reset; run claude --scope project; [ "$RC" = 0 ] || fail "uninstall: install: exit $RC: $OUT"
cp -R "$W/.claude/." "$V/"
swap_at "$HELD" "$W/.claude" claude --scope project --uninstall
victim_same "uninstall removed a file through a folder swapped in at the gap"
[ "$RC" = 1 ] && [ ! -e "$A/skills/agentbus/SKILL.md" ] || fail "uninstall: a swap at the gap: exit $RC: $OUT"
ok "the removal happens in the folder setup held"

echo "TEST: the old install link: replacing it does not remove an entry through a swapped folder"
reset; mkdir -p "$T/clone/skill" "$W/.claude/skills" "$V/skills"
printf -- '---\nname: agentbus\n---\n' >"$T/clone/skill/SKILL.md"
ln -s "$T/clone/skill" "$W/.claude/skills/agentbus"; ln -s "$T/clone/skill" "$V/skills/agentbus"
swap_at "$HELD" "$W/.claude" claude --scope project
victim_same "replacing the old link removed an entry through a folder swapped in at the gap"
[ "$RC" = 1 ] || fail "old link: a swap at the gap: exit $RC: $OUT"
ok "the old link is replaced only in the folder setup held"

echo "TEST: user scope: a link planted where setup was about to make a folder is refused"
reset; mkdir -p "$HOME/.claude/skills"
swap_at setup-before-write "$HOME/.claude/skills/agentbus" claude
victim_same "user scope: a link planted after planning was followed"
[ "$RC" = 1 ] && grep -qF "$HOME/.claude/skills/agentbus is a link, and was not one when setup started" <<<"$OUT" || fail "user scope: a planted link: exit $RC: $OUT"
ok "a link that was not there when setup looked is refused by name"

echo "TEST: user scope: the config folder swapped after planning: setup stays in the folder it looked at"
reset; run codex; [ "$RC" = 0 ] || fail "config folder: install: exit $RC: $OUT"
cp -R "$HOME/.codex/." "$V/"
swap_at setup-before-write "$HOME/.codex" codex --uninstall
victim_same "user scope: a removal followed a config folder swapped after planning"
[ ! -e "$A/AGENTS.md" ] || fail "user scope: the block was not removed from the folder setup looked at: exit $RC: $OUT"
ok "the link is not followed; the folder held at planning is the one changed"

echo "TEST: a link that is already there when setup looks is the user's choice and still works"
reset; mkdir -p "$T/real"; ln -s "$T/real" "$HOME/.claude"
run claude; [ "$RC" = 0 ] && [ -f "$T/real/skills/agentbus/SKILL.md" ] || fail "install through the user's linked config folder: exit $RC: $OUT"
run claude --uninstall; [ "$RC" = 0 ] && [ ! -e "$T/real/skills/agentbus" ] || fail "uninstall through the user's linked config folder: exit $RC: $OUT"
[ -L "$HOME/.claude" ] || fail "the user's link was replaced"
rm -rf "$T/real"
ok "a linked ~/.claude installs and uninstalls"

all_passed "All setup race tests passed"
