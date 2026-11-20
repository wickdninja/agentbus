#!/usr/bin/env bash
# ctxbench oracle (docs/evals/ctxbench-protocol.md, Oracle): the independent oracle against hand-derived fixtures only.
# No CLI and no registered parser runs here; the oracle is written from the definitions D1 to D8 alone.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$TESTS_DIR/.."
PYTHONDONTWRITEBYTECODE=1 "$PY" scripts/ctxbench/oracle_fixtures.py || fail "the oracle failed its hand-derived fixtures"
ok "the oracle passes every hand-derived fixture"
echo "All ctxbench oracle tests passed"
