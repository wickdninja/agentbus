#!/bin/bash
set -euo pipefail
# Workflow: a worker disappears while holding claims. Proves the recovery story end to end: its
# expired claim is listed as expired and another agent takes the path; a claim held by a name that
# is no longer on the roster is released by the next overlapping claim and the result says so; the
# dead name cannot be re-joined while it looks alive unless --takeover is passed; and nothing it was
# sent is lost. Stored rows are read back with SQL after each step. Runs on the source script, a
# mutation copy (AGENTBUS_BIN) and an installed command (AGENTBUS_CMD).
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/workflow_lib.sh"
wf_setup
BUSLINE="<REPO>/.agentbus/bus.db"
# claims_state: "resource agent state" per claim, from the JSON listing.
claims_state() {
  agentbus --json claims | python3 -c '
import json, sys
for c in json.load(sys.stdin)["items"]:
    print(c["resource"], c["agent"], c["state"])'
}

echo "STEP 1: a boss and two workers; the workers take paths, the boss hands work to w1"
say "joined as boss on $BUSLINE" agentbus --as boss join --tool claude --role lead
say "joined as w1 on $BUSLINE" agentbus --as w1 join --tool codex --role worker
say "joined as w2 on $BUSLINE" agentbus --as w2 join --tool codex --role worker
say "claimed src/a.py <left>" agentbus --as w1 claim src/a.py --purpose "edit a"
say "claimed lib/ <left>" agentbus --as w1 claim lib/ --purpose "edit lib"
say "claimed docs/x.md <left>" agentbus --as w2 claim docs/x.md --purpose "docs"
say "posted #1 to w1 [handoff]" agentbus --as boss post "please finish b" --to w1 --kind handoff
refuse 1 "agentbus: src/a.py is claimed by w1 until <TS> (purpose: \"edit a\"). Do not edit it yet. Ask w1: agentbus --as boss post QUESTION --to w1 --kind question, or choose another resource. w1 was last seen <ago>." \
  agentbus --as boss claim src/a.py
ok "w1 holds src/a.py and the boss is refused while the claim is live"

echo "STEP 2: w1 disappears; its claim on src/a.py runs out"
sql_write "UPDATE claims SET expires_at='2020-01-01T00:00:00Z' WHERE resource='src/a.py'"
is_equal "the listing says expired" "docs/x.md w2 held
lib/ w1 held
src/a.py w1 expired" "$(claims_state)"
say "claimed src/a.py <left>" agentbus --as boss claim src/a.py --purpose "take over a"
is_equal "the boss holds src/a.py now" "src/a.py|boss|take over a" "$(sql "SELECT resource, agent, purpose FROM claims WHERE resource='src/a.py'")"
ok "an expired claim is reported as expired and does not block"

echo "STEP 3: w2's roster entry goes away while its claim is still live; the next overlapping claim releases it"
sql_write "DELETE FROM agents WHERE name='w2'"
agentbus --json --as boss claim docs | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["resource"] == "docs" and r["agent"] == "boss", r
assert r["auto_released"] == [{"resource": "docs/x.md", "agent": "w2"}], r
assert r["auto_released_count"] == 1, r' || fail "the claim result does not list the auto-release of docs/x.md from w2"
is_equal "w2's claim is gone, the boss holds docs" "docs boss" "$(sql "SELECT resource, agent FROM claims WHERE resource LIKE 'docs%'" | tr '|' ' ')"
is_equal "the release is in the log" "docs/x.md auto-released from w2 (not on roster)" \
  "$(sql "SELECT detail FROM log WHERE action='claim' AND detail LIKE '%auto-released%'")"
ok "auto-release listed in the claim result and the log"

echo "STEP 4: w1 comes back: a live-looking name needs --takeover, and its mail is still there"
refuse 1 "agentbus: w1 was active <ago> ago and may be another live session. Pick your own name (run: agentbus --as w1-2 join), or pass --takeover only if that session is you." \
  agentbus --as w1 join --tool codex
is_equal "w1 is still on the roster after the refusal" "w1" "$(sql "SELECT name FROM agents WHERE name='w1'")"
say "joined as w1 on $BUSLINE" agentbus --as w1 join --tool codex --takeover
say "#1 boss -> w1 [handoff] · <time>
  please finish b" agentbus --as w1 inbox
is_equal "w1 still holds lib/ and the boss holds the rest" "docs boss held
lib/ w1 held
src/a.py boss held" "$(claims_state)"
is_equal "no message was lost" "1" "$(sql "SELECT COUNT(*) FROM messages")"
ok "the returning name gets its unread handoff and keeps its live claim"

echo "STEP 5: leaving releases what is held"
say "left as w1, released 1 claim
  lib/" agentbus --as w1 leave
is_equal "w1 holds nothing" "0" "$(sql "SELECT COUNT(*) FROM claims WHERE agent='w1'")"
ok "leave releases the live claim"
echo "All workflow crash recovery tests passed"
