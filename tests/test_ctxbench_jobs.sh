#!/usr/bin/env bash
# ctxbench Stage 1 runner, --jobs: cells run in parallel processes and the results are merged in a fixed order, so a
# parallel run's results file and report are byte-identical to a serial run's. Tiny run on two development seeds.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
STAGE="$TESTS_DIR/../scripts/ctxbench/stage1.py"
envx() { env -u AGENTBUS_DB -u AGENTBUS_AGENT -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u CLAUDE_PID -u CLAUDECODE "$@"; }

echo "TEST 1: serial and --jobs 2 give byte-identical results"
a=(--seeds 9901,9902 --cells 5:50:busy --probes P1 --instances 1 --cli "${AB[*]}")
envx "$PY" "$STAGE" "${a[@]}" --out "$T/serial.jsonl" > "$T/s.out" 2>&1 || { cat "$T/s.out"; fail "serial run failed"; }
envx "$PY" "$STAGE" "${a[@]}" --jobs 2 --out "$T/par.jsonl" > "$T/p.out" 2>&1 || { cat "$T/p.out"; fail "--jobs 2 run failed"; }
[ "$(grep -c '"type": "instance"' "$T/serial.jsonl")" = 8 ] || fail "the serial run did not write 2 seeds x 1 probe x 4 arms rows"
cmp "$T/serial.jsonl" "$T/par.jsonl" || fail "the --jobs 2 results file differs from the serial one"
cmp "$T/serial.report.json" "$T/par.report.json" || fail "the --jobs 2 report differs from the serial one"
ok "serial and --jobs 2 results and reports are byte-identical"

echo "All ctxbench jobs tests passed"
