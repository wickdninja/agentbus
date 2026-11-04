#!/bin/bash
set -euo pipefail
# Workflow: a workspace bus with a repo bus inside it. Proves each bus keeps its own claims and
# messages, `buses` lists the chain from the nearest bus outward, --up 1 reaches the workspace bus
# from inside the repo, a linked git worktree of the repo (inside or outside the workspace) shares
# the repo's bus, and AGENTBUS_DB overrides discovery. The stored rows of both buses are read back
# with SQL. Runs on the source script, a mutation copy (AGENTBUS_BIN) and an installed command
# (AGENTBUS_CMD).
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/workflow_lib.sh"
wf_setup      # R is the workspace, with its own bus
WS_DB="$DB"
mkrepo "$R/app"
echo "STEP 1: init in the repo inside the workspace names the outer bus"
got=$(agentbus init "$R/app" | norm | sed "s#^next: install agentbus so your agents have it on PATH (see the README), then agentbus#next: agentbus#")   # a clone says to install it first: tests/test_init.sh pins each
is_equal "init output after the version line" "added .agentbus/ to <REPO>/app/.git/info/exclude (local only; the repo stays clean)
optional: add \`.agentbus/\` to .gitignore to share that rule
outer bus: <REPO>
next: cd <REPO>/app
next: agentbus --as YOUR_NAME join
next: agentbus setup claude (teaches Claude Code the protocol)
next: agentbus setup codex (teaches Codex the protocol)" "$(sed 1d <<<"$got")"
grep -Eq '^installed agentbus .+ into <REPO>/app/\.agentbus/$' <<<"$(sed -n 1p <<<"$got")" || fail "first init line: $(sed -n 1p <<<"$got")"
APP_DB="$R/app/.agentbus/bus.db"
mkdir -p "$R/app/src"; cd "$R/app/src"
say "  0  <REPO>/app  bus.db exists  copy <copy>
  1  <REPO>  bus.db exists  copy <copy>" agentbus buses
ok "chain listed nearest first; init made each bus's database"

echo "STEP 2: the same name joins both buses; claims and messages stay on the bus they were made on"
say "joined as a on <REPO>/app/.agentbus/bus.db" agentbus --as a join
say "joined as a on <REPO>/.agentbus/bus.db" agentbus --up 1 --as a join
say "claimed x.txt <left>" agentbus --as a claim x.txt
say "claimed y.txt <left>" agentbus --up 1 --as a claim y.txt
say "posted #1 to everyone [note]" agentbus --as a post "repo news"
say "posted #1 to everyone [note]" agentbus --up 1 --as a post "workspace news"
is_equal "repo bus rows" "x.txt|a" "$(sql -d "$APP_DB" "SELECT resource, agent FROM claims")"
is_equal "workspace bus rows" "y.txt|a" "$(sql -d "$WS_DB" "SELECT resource, agent FROM claims")"
is_equal "repo bus messages" "repo news" "$(sql -d "$APP_DB" "SELECT body FROM messages")"
is_equal "workspace bus messages" "workspace news" "$(sql -d "$WS_DB" "SELECT body FROM messages")"
agentbus --json claims | python3 -c '
import json, sys
assert [c["resource"] for c in json.load(sys.stdin)["items"]] == ["x.txt"]' || fail "default listing is not the repo bus"
agentbus --json --up 1 claims | python3 -c '
import json, sys
assert [c["resource"] for c in json.load(sys.stdin)["items"]] == ["y.txt"]' || fail "--up 1 listing is not the workspace bus"
say "#1 a -> everyone [note] · <time>
  workspace news" agentbus --up 1 read
# A missing outer bus is "bus unavailable": exit 3 (see `agentbus schema --json`, exit_codes).
refuse 3 "agentbus: no bus at --up 2; no such outer bus. See: agentbus buses" agentbus --up 2 who
ok "claims and messages never cross buses"

echo "STEP 3: a linked worktree of the repo, inside and outside the workspace, shares the repo's bus"
git -C "$R/app" worktree add -q "$R/wt-in" -b wt-in
git -C "$R/app" worktree add -q "$T/wt-out" -b wt-out
for W in "$R/wt-in" "$T/wt-out"; do
  cd "$W"
  say "  a  seen <ago>" agentbus who
  say "  a  seen <ago>" agentbus --up 1 who
  say "  0  <REPO>/app  bus.db exists  copy <copy>
  1  <REPO>  bus.db exists  copy <copy>" agentbus buses
  say "claimed from-$(basename "$W").txt <left>" agentbus --as a claim "from-$(basename "$W").txt"
done
is_equal "worktree claims landed on the repo bus" "from-wt-in.txt
from-wt-out.txt
x.txt" "$(sql -d "$APP_DB" "SELECT resource FROM claims ORDER BY resource")"
is_equal "the workspace bus did not change" "y.txt" "$(sql -d "$WS_DB" "SELECT resource FROM claims")"
ok "worktrees find the repo bus and its outer bus"

echo "STEP 4: AGENTBUS_DB overrides discovery"
cd "$T/wt-out"
env AGENTBUS_DB="$WS_DB" "${AB[@]}" --json claims | python3 -c '
import json, sys
assert [c["resource"] for c in json.load(sys.stdin)["items"]] == ["y.txt"]' || fail "AGENTBUS_DB did not select the workspace bus"
ok "AGENTBUS_DB wins over the folder the command runs in"
echo "All workflow nested buses tests passed"
