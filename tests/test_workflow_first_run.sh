#!/bin/bash
set -euo pipefail
# Workflow: a new user with an empty HOME. Checks the command answers --version, `init` installs a
# bus copy, the README's hand-off block runs unchanged against that copy and its printed result is
# the README's printed result, the stored rows tell the same story, and `watch --once` shows it.
# `setup claude` runs too once the command exists. Runs on the source script, a mutation copy
# (AGENTBUS_BIN) and an installed command (AGENTBUS_CMD); the bus copy runs under $PYTHON.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/workflow_lib.sh"
wf_setup
# The bus copy starts with `#!/usr/bin/env python3`: put the interpreter under test first on PATH.
mkdir "$T/shim"; ln -s "$(command -v "$PY")" "$T/shim/python3"

echo "STEP 1: the command reports its version"
got=$(agentbus --version)
grep -Eq '^agentbus [0-9]+\.[0-9]+\.[0-9]+' <<<"$got" || fail "--version printed: $got"
ok "version: $got"

echo "STEP 2: init put a runnable copy in the repo"
[ -x "$R/.agentbus/bin/agentbus" ] || fail "no executable bus copy after init"
copy_version=$(PATH="$T/shim:$PATH" "$R/.agentbus/bin/agentbus" --version)
is_equal "the bus copy and the command are the same version" "$got" "$copy_version"
ok "bus copy runs"

echo "STEP 3: the README hand-off block runs as written and prints what the README shows"
python3 - "$TESTS_DIR/../README.md" "$T/block.sh" "$T/readme.expected" <<'PY'
import re, sys
readme, block_out, expect_out = sys.argv[1:4]
text = open(readme, encoding="utf-8").read()
# The first bash block after the hand-off heading, and the text block that follows it.
m = re.search(r"(?:Hand off some work|Try it)[^\n]*\n+```bash\n(.*?)```\n+```text\n(.*?)```", text, re.S)
assert m, "README has no hand-off block followed by its printed result"
open(block_out, "w").write("set -e\n" + m.group(1))
open(expect_out, "w").write(m.group(2))
PY
(cd "$R" && PATH="$T/shim:$PATH" bash "$T/block.sh" >"$T/block.out" 2>"$T/block.err") || { cat "$T/block.err" >&2; fail "the README block failed"; }
[ ! -s "$T/block.err" ] || { cat "$T/block.err" >&2; fail "the README block wrote to stderr"; }
want=$(norm <"$T/readme.expected" | sed -e 's/· [0-9][0-9]:[0-9][0-9]/· <time>/')
n=$(printf '%s\n' "$want" | wc -l | tr -d ' ')
got=$(norm <"$T/block.out" | tail -n "$n")
is_equal "the last lines the block prints are the README's" "$want" "$got"
# And nothing else: the whole transcript of the block, every line.
is_equal "the block's whole output" "joined as claude on <REPO>/.agentbus/bus.db
joined as codex on <REPO>/.agentbus/bus.db
goal: auth on the new token API
posted #1 to codex [handoff]
#1 claude -> codex [handoff] · <time>
  auth refactor is yours
claimed src/auth/ until <TS>
released src/auth/
posted #2 to claude [done]
#2 codex -> claude [done] re #1 · <time>
  done, tests green" "$(norm <"$T/block.out")"
ok "README output matches"

echo "STEP 4: the stored rows tell the same story"
is_equal "messages" "1|claude|codex|handoff|~
2|codex|claude|done|1" "$(sql "SELECT id, sender, recipient, kind, reply_to FROM messages ORDER BY id")"
is_equal "goal" "auth on the new token API" "$(sql "SELECT value FROM context WHERE key='goal'")"
is_equal "the claim was released" "0" "$(sql "SELECT COUNT(*) FROM claims")"
is_equal "both agents are on the roster" "claude
codex" "$(sql "SELECT name FROM agents ORDER BY name")"
is_equal "both inboxes were read" "claude|2
codex|1" "$(sql "SELECT agent, last_read_id FROM cursors ORDER BY agent")"
ok "bus state"

echo "STEP 5: a person can watch it"
w=$(COLUMNS=100 agentbus watch --once)
grep -q '^ agentbus .* 2 agents · 0 claims · 2 messages$' <<<"$w" || fail "watch header: $(sed -n 1p <<<"$w")"
grep -q '^Agents  2$' <<<"$w" && grep -q '^Messages  2$' <<<"$w" || fail "watch counts: $w"
grep -q 'handoff.*auth refactor is yours' <<<"$w" || fail "watch lacks the handoff: $w"
ok "watch --once shows two agents and two messages"

echo "STEP 6: setup claude puts the skill in HOME (runs once the command exists)"
if agentbus setup --help >/dev/null 2>&1; then
  say "agentbus setup claude (user)
  + ~/.claude/skills/agentbus/SKILL.md   installed, $(agentbus skill | wc -c | sed 's/^ *//' | python3 -c 'import sys; print(format(int(sys.stdin.read()), ","))') bytes
done. Start a new Claude Code session to load it.
next: cd your-repo && agentbus init ." agentbus setup claude
  [ -f "$HOME/.claude/skills/agentbus/SKILL.md" ] || fail "setup claude wrote no skill into HOME"
  second=$(agentbus setup claude)
  grep -qxF "  = ~/.claude/skills/agentbus/SKILL.md   unchanged" <<<"$second" && ! grep -q 'installed' <<<"$second" || fail "a second setup run was not a no-op: $second"
  ok "setup claude installed the skill and a second run changed nothing"
else
  skip_part "agentbus setup does not exist in this build"
fi
all_passed "All workflow first run tests passed"
