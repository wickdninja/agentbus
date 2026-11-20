#!/usr/bin/env bash
# ctxbench sufficiency fixtures (docs/evals/ctxbench-protocol.md): F1 (when bob left decides P4), F2 (an anchored P5),
# F3 (claims, questions, todos) and bus-ledger message parity after a takeover. Every arm's registered procedure and
# parser must derive the hand-derived answer, or the registered miss, from its own text. No study numbers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"

echo "TEST 1: fixtures F1 to F3 and message parity, four arms"
o=$("$PY" "$TESTS_DIR/../scripts/ctxbench/fixture_sufficiency.py" --cli "${AB[*]}" 2>&1) || { printf '%s\n' "$o"; fail "fixture_sufficiency.py failed"; }
printf '%s\n' "$o"
grep -qx "ctxbench sufficiency fixture: all checks passed" <<<"$o" || fail "the fixture did not finish"
ok "every registered procedure and parser derives its fixture answers from its own text"

echo "All ctxbench fixture tests passed"
