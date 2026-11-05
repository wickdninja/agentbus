#!/usr/bin/env bash
# The fast layer: tests/unit/test_*.py, plain unittest, on pure logic in the bytes that ship (bin/agentbus, or the copy
# AGENTBUS_BIN names). `bash tests/test_unit.sh`, or one file: `bash tests/test_unit.sh test_text`. Each test's
# docstring names the bug it catches.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
"$PY" -m unittest discover -s "$TESTS_DIR/unit" -p "${1:-test_*}.py" -t "$TESTS_DIR/unit" -b
all_passed "ALL UNIT TESTS PASSED"
