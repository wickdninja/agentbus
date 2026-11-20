#!/usr/bin/env bash
# ctxbench Stage 1 runner: replay defects (docs/evals/ctxbench-protocol.md, "Defects"). A defect reruns every arm of the
# whole (seed, cell) on a fresh folder; a seed-cell that still has one after the retries is excluded and listed, never
# partly reported. Faults are injected through stage1.FAULT, a
# hook in the code (the CLI has no flag for it). No study numbers.
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

# instance 1's bus-complete read hits a replay defect on every attempt: the whole seed-cell is excluded
seen = []
def always(point, ctx):
    seen.append((ctx["attempt"], ctx["instance"], ctx["arm"]))
    if point == "probe" and ctx["instance"] == 1 and ctx["arm"] == "bus-complete":
        raise R.ReplayDefect("injected")
r = run(always)
check(r["excluded"] and r["acc"] == {}, f"an excluded seed-cell kept report data {r['acc']}")
kinds = [x["type"] for x in rows(r)]
check(kinds == ["defect"] * 3, f"an excluded seed-cell wrote instance rows: {kinds}")
check([x["attempt"] for x in rows(r)] == [1, 2, 3] and rows(r)[-1]["outcome"] == "excluded", "defect rows")
check(all((a, 0, arm) in seen for a in (1, 2, 3) for arm in R.ARMS), "every arm of instance 0 must rerun on every attempt")
check(not any(x["type"] == "instance" for x in rows(r)), "instance 0 survived in a partly reported seed-cell")

print("ok")
PY
ok "a defect reruns every arm of the whole seed-cell; three defects exclude it entirely"

echo "All ctxbench defect tests passed"
