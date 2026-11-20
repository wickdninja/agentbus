#!/usr/bin/env bash
# ctxbench Stage 1 (docs/evals/ctxbench-protocol.md), B-M1: the simulator (scripts/ctxbench/sim.py) and the runner
# (scripts/ctxbench/stage1.py). Checks determinism, the event-count rule, monotonic times, the checkpoint guard, the mix
# coverage and the parameter table against the document, the runner's refusals, and a tiny end-to-end run on a
# development seed with the real oracle. No study numbers, and nothing here compares arms.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
ROOT="$TESTS_DIR/.."
CB="$ROOT/scripts/ctxbench"

echo "TEST 1: simulator rules"
"$PY" - "$ROOT" <<'PY' || fail "simulator rule check failed"
import re, sys
root = sys.argv[1]
sys.path.insert(0, root + "/scripts/ctxbench")
import registered as R, sim

def check(c, m):
    if not c:
        raise SystemExit("FAIL: " + m)

# the parameter table in registered.py is the document's
doc = open(root + "/docs/evals/ctxbench-protocol.md").read()
def row(label):
    m = re.search(r"^\| " + re.escape(label) + r" \| (.*) \|$", doc, re.M)
    return [x.strip() for x in m.group(1).split("|")]
order = ["sparse", "busy", "handoff-heavy"]
for i, mix in enumerate(order):
    p = R.PARAMS[mix]
    check(float(row("mean seconds between events")[i]) == p["mean"], "mean " + mix)
    check(int(row("work items (the first k lines of `data/items.txt`)")[i]) == p["items"], "items " + mix)
    check(float(row("broadcast share of messages")[i]) == p["broadcast"], "broadcast " + mix)
    check(tuple(float(x) for x in row("claim sort shares: renewal / takeover / new")[i].split(" / ")) == p["claim"], "claim " + mix)
    check(float(row("long-body share")[i]) == p["long"], "long " + mix)
check(re.search(r"sparse 0\.002, busy 0\.004, handoff-heavy 0\.008", doc), "crash row moved")
check([R.PARAMS[m]["crash"] for m in order] == [0.002, 0.004, 0.008], "crash probabilities")
check(sim.SEEDS == [int(x) for x in re.findall(r"\d{4}", doc.split("## Seeds")[1].split("M = 10")[0])], "seed list")

for mix in order:
    for n, e, seed in ((5, 50, 9901), (8, 1000, 9902)):
        a = sim.build_history(seed, n, e, mix)
        b = sim.build_history(seed, n, e, mix)
        check(a.events == b.events and a.times == b.times, f"not deterministic {seed} {n} {e} {mix}")
        check(a.events != sim.build_history(seed + 1, n, e, mix).events, "seed ignored")
        counted = a.counted()
        check(len(counted) == e + 20 == a.total, f"{mix} E+20 counted events, got {len(counted)}")
        check([ev[2] for ev in counted[:n + 1]] == ["join"] * n + ["goal"], "start is N joins then the goal")
        check([ev[1] for ev in counted[:n]] == ["lead"] + [R.name_at(i) for i in range(n - 1)], "start names")
        check(counted[n][1] == "lead" and all(ev[0] == sim.START for ev in counted[:n + 1]), "start time and goal setter")
        ts = [ev[0] for ev in a.events]
        check(ts == sorted(ts), "times went backwards")
        check(all(ev[0] == a.times[k] for k in range(1, a.total + 1) for ev in a.events[a.step_end[k - 1]:a.step_end[k]]
                  if ev[2] != "inbox") , "step_end and times disagree")
        check(not any(ev[2] in ("leave",) and ev[1] == "lead" for ev in a.events), "lead left")
        # inbox reads are not counted: E counts joins, goal, messages, claims, releases, facts and leaves
        kinds = {"join", "leave", "goal", "post", "claim", "release", "fact"}
        check({ev[2] for ev in counted} <= kinds, "a counted event of another kind")

# every type of the mix appears in a long history; takeovers, renewals and replies to closed or left owners too
for mix in order:
    h = sim.build_history(9901, 8, 5000, mix)
    seen = {ev[3]["kind"] for ev in h.events if ev[2] == "post"} | {ev[2] for ev in h.events}
    miss = [w for w in R.MIXES[mix] if w not in seen and w not in ("claim", "release", "fact", "join", "leave")]
    check(not miss, f"{mix}: types never drawn {miss}")
    for a in ("claim", "release", "fact", "leave"):
        check(a in seen, f"{mix}: no {a}")
    joins = [ev for ev in h.events if ev[2] == "join"]
    check(len(joins) > 8 and len({ev[1] for ev in joins}) == len(joins), f"{mix}: joins after the start, names never reused")
    claims = [ev for ev in h.events if ev[2] == "claim"]
    check(any(ev[3].get("frm") for ev in claims), f"{mix}: no takeover")
    held = {}
    renewed = 0
    for ev in h.events:
        if ev[2] == "claim" and not ev[3].get("frm") and held.get(ev[3]["res"]) == ev[1]:
            renewed += 1
        if ev[2] == "claim":
            held[ev[3]["res"]] = ev[1]
    check(renewed > 0, f"{mix}: no renewal")
    check(any(ev[3].get("kind") == "done" and ev[3].get("reply_to") is None for ev in h.events if ev[2] == "post"), "no done without reply_to")
    check(all(len(ev[3]["body"]) > 0 for ev in h.events if ev[2] == "post"), "empty body")

# the checkpoint guard and the P7 construction hold on every drawn instance
for mix in order:
    h = sim.build_history(9902, 8, 1000, mix)
    for probe in sim.PROBES:
        for i in range(10):
            spec = sim.draw_instance(h, 9902, probe, i)
            if spec is None:
                continue
            if probe == "P7":
                c = spec["c"]
                check(h.lo <= c <= h.hi and spec["refreshes"] == [c, c + 10, c + 20], "P7 refresh steps")
                check(spec["me"] in h.snaps[c].live and spec["me"] in h.snaps[c + 20].live, "P7 me not live over the window")
                check(not any(ev[2] == "leave" and ev[1] == spec["me"] for ev in h.events[h.step_end[c]:h.step_end[c + 20]]), "P7 me left in the window")
                ts = spec["times"]
                check(ts == sorted(ts), "P7 refresh times backwards")
                for k in spec["refreshes"]:
                    s = h.snaps[k]
                    check(R.guard_ok(s.time, [x for _, _, x in s.live_claims(s.time)]), "P7 guard")
            else:
                s = h.snaps[spec["c"]]
                now = spec["now"]
                check(h.lo <= spec["c"] <= h.hi and spec["me"] in s.live, "checkpoint index or me")
                check(R.parse_ts(h.times[spec["c"]]) < R.parse_ts(now) <= R.parse_ts(h.times[spec["c"]]) + R.timedelta(seconds=300), "now outside c + 1..300 s")
                for _, _, x in s.live_claims(h.times[spec["c"]]):
                    check(not (now < x <= R.iso(R.parse_ts(now) + R.GUARD)), f"guard broken: claim expiring {x}, now {now}")
print("ok")
PY
ok "determinism, E+20 counted events, start, monotonic times, mix coverage, 120 s guard, P7 window, parameter table"

echo "TEST 2: the runner refuses"
STAGE="$CB/stage1.py"
envx() { env -u AGENTBUS_DB -u AGENTBUS_AGENT -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u CLAUDE_PID -u CLAUDECODE "$@"; }
if o=$(envx "$PY" "$STAGE" --seeds 4127 --cells 5:50:busy --out "$T/x.jsonl" 2>&1); then fail "a counted seed ran without --counted"; fi
grep -q "counted seeds" <<<"$o" || fail "no clear refusal for a counted seed: $o"
if o=$(envx "$PY" "$STAGE" --dev --cells 5:50:busy --oracle-file "$T/none.py" --out "$T/x.jsonl" 2>&1); then fail "ran without an oracle"; fi
grep -q "oracle .* does not exist" <<<"$o" || fail "no clear refusal for a missing oracle: $o"
if o=$(envx ANTHROPIC_API_KEY=x "$PY" "$STAGE" --dev --cells 5:50:busy --out "$T/x.jsonl" 2>&1); then fail "ran with a model credential set"; fi
grep -q "ANTHROPIC_API_KEY" <<<"$o" || fail "no refusal naming the credential: $o"
grep -q "=x" <<<"$o" && fail "a refusal printed a value"
[ ! -e "$T/x.jsonl" ] || fail "a refused run wrote a results file"
ok "counted seeds need --counted; a missing oracle and a configured credential are refused"

if o=$(envx "$PY" "$STAGE" --seeds 4127 --counted --cells 5:20:busy --out "$T/x.jsonl" 2>&1); then fail "a counted seed ran an off-grid cell"; fi
echo "$o" | grep -q "not in the grid" || fail "the off-grid refusal for a counted seed did not say why: $o"
echo "TEST 3: tiny end-to-end run (dev seed, E=30, N=5, real oracle)"
envx "$PY" "$STAGE" --seeds 9901 --cells 5:30:busy --probes P1,P7 --instances 1 --cli "${AB[*]}" --out "$T/r.jsonl" > "$T/run.out" 2>&1 || { cat "$T/run.out"; fail "stage1.py failed"; }
"$PY" - "$T/r.jsonl" <<'PY' || fail "results file check failed"
import json, sys
rows = [json.loads(x) for x in open(sys.argv[1])]
env = rows[0]
assert env["type"] == "environment" and env["os"] and env["python"] and set(env["tools"]) == {"awk", "grep", "sed", "cut", "tail"}, env
assert len(env["sha256"]) >= 8 and env["commit"], env
inst = [r for r in rows if r["type"] == "instance"]
assert not [r for r in rows if r["type"] == "defect"], "replay defects"
assert {(r["probe"], r["arm"]) for r in inst} == {(p, a) for p in ("P1", "P7")
        for a in ("bus-default", "bus-complete", "ledger-raw", "ledger-awk")}, "missing probe/arm rows"
for r in inst:
    assert isinstance(r["bytes"], int) and r["bytes"] >= 0 and r["bytes_capped"] <= r["bytes"] + 100 and r["calls"] >= 1, r
    assert r["outcome"] in ("ok", "cannot", "wrong") and r["outcome_capped"] in ("ok", "cannot", "wrong"), r
rep = json.load(open(sys.argv[1].replace(".jsonl", ".report.json")))
assert {c["probe"] for c in rep} == {"P1", "P7"} and all("uncapped" in c and "capped" in c for c in rep)
PY
ok "results file holds the environment row and one row per arm and probe; the report is written"

echo "All ctxbench simulator tests passed"
