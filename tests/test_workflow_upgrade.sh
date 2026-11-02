#!/bin/bash
set -euo pipefail
# Workflow: the rollout. A bus made by the v0.1.0 copy holds data and unread messages; the current
# tool upgrades its copy; the agents carry on. Proves the data survives an upgrade (every table's
# row count, the unread messages, the claims and the fact history), the copy is replaced and runs,
# a second upgrade changes nothing, and `upgrade --all` reports each bus once that exists. The
# v0.1.0 copy is tests/fixtures/legacy/agentbus-0.1.0; without it the file exits 77 (skipped). Runs on the source script, a mutation copy (AGENTBUS_BIN) and an installed
# command (AGENTBUS_CMD).
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/workflow_lib.sh"
wf_setup
mkdir "$T/shim"; ln -s "$(command -v "$PY")" "$T/shim/python3"
LEGACY="$T/legacy-agentbus-0.1.0"
legacy_copy "$LEGACY" || skip_test "tests/fixtures/legacy/agentbus-0.1.0 is not in this tree"
# lbus: the bus copy in the repo, under the interpreter being tested.
lbus() { PATH="$T/shim:$PATH" "$R/.agentbus/bin/agentbus" "$@"; }

echo "STEP 1: a v0.1.0 bus with a goal, messages, claims and facts"
rm -rf "$R/.agentbus"
"$PY" "$LEGACY" init "$R" >/dev/null
is_equal "the copy is v0.1.0" "0.1.0" "$(cat "$R/.agentbus/VERSION")"
lbus --as planner join --tool claude --role planner >/dev/null
lbus --as worker join --tool codex --role worker >/dev/null
lbus --as planner goal "ship it" >/dev/null
lbus --as planner post "do the first part" --to worker --kind handoff >/dev/null
lbus --as worker inbox >/dev/null
lbus --as planner post "then the second part" --to worker --kind handoff --topic part2 >/dev/null
lbus --as planner post "and tell me when done" --to worker --kind note >/dev/null
lbus --as worker post "ack" --to planner --kind answer --reply-to 1 >/dev/null
lbus --as worker claim src/a.py --purpose "part one" >/dev/null
lbus --as planner ctx set stage one >/dev/null
lbus --as planner ctx set stage two >/dev/null
TABLES="agents messages cursors context context_history claims log"
counts() { for t in $TABLES; do printf '%s=%s\n' "$t" "$(sql "SELECT COUNT(*) FROM $t")"; done; }
BEFORE=$(counts)
is_equal "rows before" "agents=2
messages=4
cursors=2
context=2
context_history=3
claims=1
log=$(sql "SELECT COUNT(*) FROM log")" "$BEFORE"
ok "v0.1.0 bus has data and 2 unread messages for the worker"

echo "STEP 2: the current tool upgrades the copy"
mkrepo "$T/fresh"; "${AB[@]}" init "$T/fresh" >/dev/null
NEW_VERSION=$(cat "$T/fresh/.agentbus/VERSION")
[ "$NEW_VERSION" != 0.1.0 ] || [ "$(agentbus --version)" = "agentbus 0.1.0" ] || fail "a fresh init wrote the old version"
got=$(agentbus upgrade "$R" | norm)
grep -Eq '^<REPO>: 0\.1\.0 -> .+$' <<<"$got" || fail "upgrade printed: $got"
is_equal "VERSION equals a fresh init's" "$NEW_VERSION" "$(cat "$R/.agentbus/VERSION")"
cmp -s "$R/.agentbus/bin/agentbus" "$T/fresh/.agentbus/bin/agentbus" || fail "the upgraded copy differs from a fresh init's copy"
! cmp -s "$R/.agentbus/bin/agentbus" "$LEGACY" || fail "the copy is still the v0.1.0 script"
ok "the copy was replaced: $(sed -n 1p <<<"$got" | norm)"

echo "STEP 3: nothing was lost"
is_equal "row counts" "$BEFORE" "$(counts)"
say "#2 planner -> worker [handoff] (part2) · <time>
  then the second part
#3 planner -> worker [note] · <time>
  and tell me when done" lbus --as worker inbox
say "#4 worker -> planner [answer] re #1 · <time>
  ack" lbus --as planner inbox
say "  src/a.py  worker  <left>  part one" lbus claims
is_equal "fact history" "stage|planner|one
stage|planner|two" "$(sql "SELECT key, updated_by, value FROM context_history WHERE key='stage' ORDER BY id")"
ok "counts equal, unread kept, claim and history intact"

echo "STEP 4: the agents carry on, and a second upgrade changes nothing"
say "posted #5 to planner [done]" lbus --as worker post "done" --to planner --kind done --reply-to 2
say "claimed src/b.py until <TS>" lbus --as worker claim src/b.py
agentbus upgrade "$R" >/dev/null
is_equal "VERSION unchanged by a second upgrade" "$NEW_VERSION" "$(cat "$R/.agentbus/VERSION")"
is_equal "messages after the second upgrade" "5" "$(sql "SELECT COUNT(*) FROM messages")"
ok "bus keeps working on the new copy"

echo "STEP 5: upgrade --all reports each bus (runs once the flag exists)"
if agentbus upgrade --help 2>&1 | grep -q -- '--all'; then
  P="$T/parent"; mkdir "$P"
  for n in one two; do mkrepo "$P/$n"; "$PY" "$LEGACY" init "$P/$n" >/dev/null; (cd "$P/$n" && PATH="$T/shim:$PATH" "$P/$n/.agentbus/bin/agentbus" --as a join >/dev/null); done
  got=$(agentbus upgrade --all "$P" | norm)
  for n in one two; do grep -q "$n" <<<"$got" || fail "upgrade --all did not report $n: $got"; done
  for n in one two; do ! [ "$(cat "$P/$n/.agentbus/VERSION")" = 0.1.0 ] || fail "$n was not upgraded"; done
  ok "upgrade --all reported and upgraded both buses"
else
  skip_part "upgrade --all does not exist in this build"
fi
all_passed "All workflow upgrade tests passed"
