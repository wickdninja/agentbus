#!/bin/bash
set -euo pipefail
# Workflow: a planner, a worker and a reviewer share one bus from goal to leave. Proves the whole
# handoff story end to end: addressed delivery (recipient, reply_to), the exact claim conflict text,
# a question and its answer, release and reclaim, a fact written twice with both authors in its
# history, done, leave, and an empty roster and claim list at the end. Every step's exit status,
# stdout and stderr are checked, and the stored rows are read back with SQL. Runs on the source
# script, on a mutation copy (AGENTBUS_BIN) and on an installed command (AGENTBUS_CMD).
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/workflow_lib.sh"
wf_setup
BUSLINE="<REPO>/.agentbus/bus.db"

echo "STEP 1: three agents join; the goal reaches the ones who join after it is set"
say "joined as planner on $BUSLINE" agentbus --as planner join --tool claude --role planner
say "goal: ship the health route" agentbus --as planner goal "ship the health route"
say "joined as worker on $BUSLINE
goal (planner, <ago>): ship the health route" agentbus --as worker join --tool codex --role worker
say "joined as reviewer on $BUSLINE
goal (planner, <ago>): ship the health route" agentbus --as reviewer join --tool claude --role reviewer
is_equal "roster rows" "planner|claude|planner
reviewer|claude|reviewer
worker|codex|worker" "$(sql "SELECT name, tool, role FROM agents ORDER BY name")"
ok "joined, goal shown to later joiners"

echo "STEP 2: a handoff is addressed to the worker and only the worker's inbox shows it"
jcall post --as planner post "implement /health in app/api" --to worker --kind handoff --topic health | jis "the handoff post reply" 'r["id"] == 1'
say "inbox empty" agentbus --as reviewer inbox
is_equal "handoff row" "1|planner|worker|handoff|health|implement /health in app/api|~" \
  "$(sql "SELECT id, sender, recipient, kind, topic, body, reply_to FROM messages")"
jcall inbox --as worker inbox | jis "the worker's JSON inbox lacks the addressed handoff" \
  '[(m["id"], m["sender"], m["recipient"], m["kind"], m["topic"], m["reply_to"], m["body"]) for m in r["items"]] == [(1, "planner", "worker", "handoff", "health", None, "implement /health in app/api")]'
say "inbox empty" agentbus --as worker inbox
is_equal "worker cursor moved past the handoff" "worker|1" "$(sql "SELECT agent, last_read_id FROM cursors WHERE agent='worker'")"
ok "handoff delivered once, to the right agent"

echo "STEP 3: the worker claims a folder; the reviewer is refused with the exact conflict text"
jcall claim --as worker claim app/api --purpose "health route" | jis "the claim reply" 'r["resource"] == "app/api" and r["agent"] == "worker" and r["purpose"] == "health route"'
refuse 1 "agentbus: app/api/health.py overlaps app/api, claimed by worker since <TS> until <TS> (purpose: \"health route\"). In a shared checkout, leave it until worker answers or releases it; ask: agentbus --as reviewer post QUESTION --to worker --kind question. On a separate branch, post what you are touching; the merge decides. worker was last seen <ago>. If your user or a handoff gave you worker's work, take it: agentbus --as reviewer claim app/api --from worker" \
  agentbus --as reviewer claim app/api/health.py --purpose "review"
is_equal "only the worker holds a claim" "app/api|worker|health route" "$(sql "SELECT resource, agent, purpose FROM claims")"
ok "claim conflict refused with the documented text"

echo "STEP 4: a question and its answer carry reply_to"
say "posted #2 to planner [question]" agentbus --as worker post "which status code on failure?" --to planner --kind question --reply-to 1
say "#2 worker -> planner [question] re #1 · <time>
  which status code on failure?" agentbus --as planner inbox
say "posted #3 to worker [answer]" agentbus --as planner post "503" --to worker --kind answer --reply-to 2
say "#3 planner -> worker [answer] re #2 · <time>
  503" agentbus --as worker inbox
is_equal "question and answer rows" "2|worker|planner|question|~|which status code on failure?|1
3|planner|worker|answer|~|503|2" "$(sql "SELECT id, sender, recipient, kind, topic, body, reply_to FROM messages WHERE id>1 ORDER BY id")"
ok "question and answer linked and addressed"

echo "STEP 5: a fact is written, then updated by someone else; a fresh reader sees both authors"
jcall "ctx set" --as worker ctx set health.status "503 on failure" | jis "ctx set reply" 'r["key"] == "health.status" and r["updated_by"] == "worker"'
jcall "ctx set" --as planner ctx set health.status "503 on db failure" | jis "ctx set reply" 'r["value"] == "503 on db failure" and r["updated_by"] == "planner"'
say "  503 on db failure" agentbus ctx get health.status
say "  <TS> worker: 503 on failure
  <TS> planner: 503 on db failure" agentbus ctx history health.status
jcall "ctx history" ctx history health.status | jis "ctx history reply" '[(h["updated_by"], h["value"]) for h in r["items"]] == [("worker", "503 on failure"), ("planner", "503 on db failure")]'
is_equal "fact history rows" "health.status|worker|503 on failure
health.status|planner|503 on db failure" "$(sql "SELECT key, updated_by, value FROM context_history WHERE key='health.status' ORDER BY id")"
is_equal "fact current value" "health.status|503 on db failure|planner" "$(sql "SELECT key, value, updated_by FROM context WHERE key='health.status'")"
ok "fact value and both history entries visible to a reader with no identity"

echo "STEP 6: release, reclaim by the reviewer, done, leave"
jcall release --as worker release app/api | jis "release reply" 'r["released"] == ["app/api"]'
say "claimed app/api/health.py <left>" agentbus --as reviewer claim app/api/health.py --purpose "review"
is_equal "the reviewer holds the file" "app/api/health.py|reviewer|review" "$(sql "SELECT resource, agent, purpose FROM claims")"
jcall post --as worker post "done: /health" --kind done --reply-to 1 | jis "done post reply" 'r["id"] == 4'
say "#4 worker -> everyone [done] re #1 · <time>
  done: /health" agentbus --as reviewer inbox
jcall leave --as worker leave | jis "worker leave reply" 'r["left"] == "worker" and r["released_count"] == 0'
jcall release --as reviewer release app/api/health.py | jis "reviewer release reply" 'r["released"] == ["app/api/health.py"]'
jcall leave --as reviewer leave | jis "reviewer leave reply" 'r["left"] == "reviewer"'
jcall inbox --as planner inbox | jis "the planner's JSON inbox lacks the broadcast done" \
  '[(x["id"], x["recipient"], x["kind"], x["reply_to"]) for x in r["items"]] == [(4, "*", "done", 1)]'
jcall leave --as planner leave | jis "planner leave reply" 'r["left"] == "planner"'
ok "release, reclaim, done and leave"

echo "STEP 7: the end state is empty"
is_equal "no agents" "0" "$(sql "SELECT COUNT(*) FROM agents")"
is_equal "no claims" "0" "$(sql "SELECT COUNT(*) FROM claims")"
is_equal "all four messages kept" "4" "$(sql "SELECT COUNT(*) FROM messages")"
say "  no agents. Join with: agentbus --as NAME join" agentbus who
jcall who who | jis "who after everyone left" 'r["items"] == [] and r["has_more"] is False'
say "  no claims" agentbus claims
jcall claims claims | jis "claims at the end" 'r["items"] == [] and r["has_more"] is False'
jcall read read | jis "read at the end" '[m["id"] for m in r["items"]] == [1, 2, 3, 4]'
jcall status status | jis "status at the end" 'r["goal"]["goal"] == "ship the health route"'
ok "roster and claims empty, messages kept"
echo "STEP 8: every --json reply this story got validates against \`schema --json\` (ws07's schema command)"
if agentbus schema --json >"$T/schema.json" 2>/dev/null; then
  python3 - "$T/schema.json" "$T/replies/index" "$TESTS_DIR" <<'PY' || fail "a --json reply does not match its schema"
import json, sys
schema_path, index, tests_dir = sys.argv[1:4]
sys.path.insert(0, tests_dir)
from schema_check import validate
doc = json.load(open(schema_path))
bad, seen = [], 0
for line in open(index):
    key, path = line.rstrip("\n").split("|", 1)
    seen += 1
    errors = validate(json.load(open(path)), doc["commands"][key]["result"], doc["objects"])
    if errors:
        bad.append("%s (%s): %s" % (key, path.rsplit("/", 1)[-1], errors[:3]))
if not seen:
    bad.append("the story recorded no --json reply")
if bad:
    print("\n".join(bad)); sys.exit(1)
PY
  ok "the story's own --json replies match schema --json"
else
  fail "agentbus schema --json failed"
fi
all_passed "All workflow handoff tests passed"
