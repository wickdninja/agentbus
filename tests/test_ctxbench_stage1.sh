#!/usr/bin/env bash
# ctxbench Stage 1 runner: capped call counts, no arm comparisons for development seeds, duplicate units, unique
# scratch folders, and the counted report's shape. No study numbers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
ROOT="$TESTS_DIR/.."
STAGE="$ROOT/scripts/ctxbench/stage1.py"
envx() { env -u AGENTBUS_DB -u AGENTBUS_AGENT -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u CLAUDE_PID -u CLAUDECODE "$@"; }

echo "TEST 1: duplicate units are refused at parse time"
for a in "--seeds 9901,9901 --cells 5:20:busy" "--seeds 9901 --cells 5:20:busy,5:20:busy"; do
  if o=$(envx "$PY" "$STAGE" $a --out "$T/x.jsonl" 2>&1); then fail "duplicates ran: $a"; fi
  grep -q "duplicate" <<<"$o" || fail "no duplicate refusal for $a: $o"
done
[ ! -e "$T/x.jsonl" ] || fail "a refused run wrote a results file"
ok "duplicate seeds and duplicate cells are refused"

echo "TEST 2: capped calls, scratch folders, the report, and a development run's outputs"
envx "$PY" - "$ROOT" "$T" "${AB[*]}" <<'PY' || fail "stage1 check failed"
import json, os, sys, types
root, tmp, cli = sys.argv[1], sys.argv[2], sys.argv[3].split()
sys.path.insert(0, root + "/scripts/ctxbench")
import registered as R, stage1

def check(c, m):
    if not c:
        raise SystemExit("FAIL: " + m)

# unique scratch folders: the same unit twice at once never shares a folder
os.makedirs(tmp + "/b")
a, b = stage1.scratch_dir(tmp + "/b", 9901, 5, 50, "busy"), stage1.scratch_dir(tmp + "/b", 9901, 5, 50, "busy")
check(a != b and os.path.isdir(a) and os.path.isdir(b), "scratch folders collide")

# capped calls: a P5 listing over the cap whose newest body was cut makes two calls uncapped and one capped
LONG = " ".join(["The cache layer needs another pass under load before we turn the flag on for everyone."] * 25)
T = lambda m: f"2026-11-19T09:{m}:00Z"  # noqa: E731
ev = [(T("00"), n, "join", {}) for n in ("lead", "alice")]
for i in range(14):
    ev.append((T("%02d" % (1 + i)), "lead", "post", {"kind": "decision", "to": "*", "body": LONG + f"\nSubject: s{i}", "topic": "decision", "reply_to": None}))
run = R.Runner(cli, tmp + "/r")
bus = tmp + "/bus"
R.build_bus(run, bus, ev)
hist = types.SimpleNamespace()
cell = stage1.Cell(run, tmp + "/c", hist, {})
cell.snaps[len(ev)] = bus
spec = {"probe": "P5", "instance": 0, "c": len(ev), "me": "alice", "now": T("30"), "inputs": {}}
row = stage1.measure_probe(cell, spec, "bus-complete", (14, "s13"))
check(row["calls"] == 2 and row["calls_capped"] == 1, f"calls {row['calls']} capped {row['calls_capped']}")
check(row["bytes_capped"] < row["bytes"] and row["outcome_capped"] == "cannot" and row["outcome"] == "ok", f"capped P5 row {row}")

# the counted report has the comparisons; a development run writes none (see test 3)
acc = {(5, 50, "busy", "P1"): {"arms": {arm: {1: [(10, 10, "ok", "ok")], 2: [(30, 30, "ok", "ok")]} for arm in R.ARMS}}}
rep = stage1.build_report(acc)
check("ratios" in rep[0]["uncapped"] and "bytes" in rep[0]["capped"], "the counted report lost its comparisons")
print("ok")
PY
ok "capped P5 records fewer calls; scratch folders are unique; the counted report keeps its comparisons"

echo "TEST 3: a development run writes the results and a defects-only summary, no comparison"
envx "$PY" "$STAGE" --seeds 9901 --cells 2:10:busy --probes P1 --instances 1 --cli "${AB[*]}" --out "$T/d.jsonl" > "$T/d.out" 2>&1 || { cat "$T/d.out"; fail "dev run failed"; }
[ ! -e "$T/d.report.json" ] || fail "a development run wrote the comparative report"
"$PY" - "$T/d.defects.json" "$T/d.out" <<'PY' || fail "the development summary holds more than defects and disagreements"
import json, sys
s = json.load(open(sys.argv[1]))
assert set(s) == {"defect_rows", "excluded_seed_cells", "oracle_parser_disagreements", "defects_cleared_by_rerun", "defects_total"}, sorted(s)
text = open(sys.argv[1]).read() + open(sys.argv[2]).read()
for word in ("ratio", "median", "quartile", "per_seed", "derivable", "bytes"):
    assert word not in text, word
PY
ok "no report file; the summary has defects and disagreements only"

echo "All ctxbench stage1 tests passed"
