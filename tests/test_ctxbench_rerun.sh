#!/usr/bin/env bash
# ctxbench Stage 1 runner: a replay defect that a rerun cleared (docs/evals/ctxbench-protocol.md, "Defects") is still
# counted, and the rerun reports the whole seed-cell. Faults are injected through stage1.FAULT, a hook in the code. No study numbers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
ROOT="$TESTS_DIR/.."
echo "TEST 1: fault injection"
env -u AGENTBUS_DB -u AGENTBUS_AGENT -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u CLAUDE_PID -u CLAUDECODE \
  "$PY" - "$ROOT" "$T" "${AB[*]}" <<'PY' || fail "defect handling check failed"
import json, os, sys
root, tmp, cli = sys.argv[1], sys.argv[2], sys.argv[3].split()
sys.path.insert(0, root + "/scripts/ctxbench")
import registered as R, stage1

def check(c, m):
    if not c:
        raise SystemExit("FAIL: " + m)

settings = {"probes": ["P1"], "instances": 2, "oracle_file": None}
unit = (9901, 2, 10, "busy")
os.makedirs(tmp + "/b")

def run(fault):
    stage1.FAULT = fault
    try:
        return stage1.run_unit(settings, cli, tmp + "/b", *unit)
    finally:
        stage1.FAULT = None

def rows(r):
    return [json.loads(x) for x in r["text"].splitlines()]

# a defect on the first attempt only: the rerun covers every arm, the cell is reported whole, the defect is counted
def once(point, ctx):
    if point == "probe" and ctx["attempt"] == 1 and ctx["instance"] == 1 and ctx["arm"] == "bus-complete":
        raise R.ReplayDefect("injected once")
r = run(once)
rs = rows(r)
check(not r["excluded"] and len(r["defects"]) == 1 and rs[0]["type"] == "defect" and rs[0]["outcome"] == "rerun", "a cleared defect was not reported")
inst = [x for x in rs if x["type"] == "instance"]
check(len(inst) == 2 * 4 and {x["arm"] for x in inst} == set(R.ARMS), "the rerun did not report every instance and arm")
s = stage1.merge_results([r], open(os.devnull, "w"), {})
check(s["defects_total"] == 1 and s["defects_cleared_by_rerun"] == 1 and s["excluded_seed_cells"] == [], f"summary {s}")
clean = run(None)
check([x for x in rows(clean) if x["type"] == "instance"] == inst, "a rerun changed the instance rows")
print("ok")
PY
ok "a cleared defect is counted and the rerun reports every instance and arm"

echo "All ctxbench rerun tests passed"
