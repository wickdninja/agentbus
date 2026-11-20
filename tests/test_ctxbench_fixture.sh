#!/usr/bin/env bash
# ctxbench sufficiency fixture (docs/evals/ctxbench-protocol.md): two histories that differ only in when bob left must
# give alice's takeable todos {1} and {1,2}. Every registered Bus-complete and Ledger-raw P4 procedure must derive them
# from its own returned text; Bus-default must return the same text for both (the documented gap). No study numbers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"

echo "TEST 1: the N1 two-history fixture"
o=$("$PY" "$TESTS_DIR/../scripts/ctxbench/fixture_sufficiency.py" --cli "${AB[*]}" 2>&1) || { printf '%s\n' "$o"; fail "fixture_sufficiency.py failed"; }
printf '%s\n' "$o"
grep -qx "ctxbench sufficiency fixture: all checks passed" <<<"$o" || fail "the fixture did not finish"
ok "registered P4 procedures distinguish the histories from their text alone; Bus-default cannot"

echo "All ctxbench fixture tests passed"
