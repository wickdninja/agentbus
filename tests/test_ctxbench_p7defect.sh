#!/usr/bin/env bash
# ctxbench Stage 1 runner: a stored time one second off after a P7 window replay (docs/evals/ctxbench-protocol.md, "Defects") is a replay defect,
# never a scored row. Faults are injected through stage1.FAULT, a hook in the code. No study numbers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
ROOT="$TESTS_DIR/.."
echo "TEST 1: P7 timing slip"
env -u AGENTBUS_DB -u AGENTBUS_AGENT -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u CLAUDE_PID -u CLAUDECODE \
  "$PY" - "$ROOT" "$T" "${AB[*]}" <<'PY' || fail "defect handling check failed"
import json, os, sys
root, tmp, cli = sys.argv[1], sys.argv[2], sys.argv[3].split()
sys.path.insert(0, root + "/scripts/ctxbench")
import registered as R, stage1

def check(c, m):
    if not c:
        raise SystemExit("FAIL: " + m)

def rows(r):
    return [json.loads(x) for x in r["text"].splitlines()]

os.makedirs(tmp + "/b")
# P7: a stored time one second off after a window replay is a defect on every attempt, never a wrong row
import sqlite3
p7 = {"probes": ["P7"], "instances": 1, "oracle_file": None}
def slip(point, ctx):
    if point == "advanced":
        con = sqlite3.connect(ctx["copy"] + "/bus.db")
        con.execute("UPDATE log SET ts='2026-11-19T09:00:01Z' WHERE id=(SELECT MAX(id) FROM log)")
        con.commit(); con.close()
stage1.FAULT = slip
try:
    r = stage1.run_unit(p7, cli, tmp + "/b", 9901, 3, 10, "busy")
finally:
    stage1.FAULT = None
rs = rows(r)
check(r["excluded"] and all(x["type"] == "defect" for x in rs), f"a timing slip became a scored row: {[x['type'] for x in rs]}")
check("not a simulated time" in rs[0]["defect"] or "stamped" in rs[0]["defect"], rs[0]["defect"])
print("ok")
PY
ok "a timing slip in a P7 window is a replay defect, never a wrong row"

echo "All ctxbench P7 defect tests passed"
