#!/usr/bin/env bash
# ctxbench Stage 1 (docs/evals/ctxbench-protocol.md), part 2: the cap adapter (CAP), P7 sessions capped and uncapped
# (F6), the generator's choice rules (GEN), reader-time and stored-time checks (TIME) and the report (REPORT), all in
# scripts/ctxbench/registered.py. Part 1 is tests/test_ctxbench_fixture.sh. No study numbers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"

echo "TEST 1: CAP, F6, GEN, TIME, REPORT"
o=$("$PY" "$TESTS_DIR/../scripts/ctxbench/fixture_sufficiency.py" --group rules --cli "${AB[*]}" 2>&1) || { printf '%s\n' "$o"; fail "fixture_sufficiency.py --group rules failed"; }
printf '%s\n' "$o"
grep -qx "ctxbench sufficiency fixture (rules): all checks passed" <<<"$o" || fail "the rules fixtures did not finish"
ok "cap adapter, P7 sessions, choice rules, time checks and report behave as registered"

echo "All ctxbench rules tests passed"
