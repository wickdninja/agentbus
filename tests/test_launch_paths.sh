#!/bin/bash
set -euo pipefail
# Every test launches the CLI through "${AB[@]}" (tests/lib.sh) or agentbus_argv() (tests/agentbus_cmd.py),
# so AGENTBUS_CMD (an installed command) and AGENTBUS_BIN (a mutation copy) reach every test. A direct
# `"$PY" "$BIN"` or `[py, bin_` launch quietly tests the source script instead; this fails on one.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# direct_launches FILE...: the lines that launch the CLI without the helpers.
direct_launches() {
  grep -n -E '"\$\{?PY\}?" +"?\$\{?BIN\}?"?|\$\{?PY\}? +\$\{?BIN\}?|python3? +"?\$\{?BIN\}?"?|\[py, |\[sys\.executable, *(bin_|BIN)' "$@" || true
}
# The detector itself: each shape below must be caught, the helper forms must not.
printf '%s\n' '"$PY" "$BIN" who' 'x=$($PY $BIN who)' 'python3 "$BIN" who' 'subprocess.run([py, bin_, "who"])' '"${AB[@]}" who' > "$T/probe"
[ "$(direct_launches "$T/probe" | wc -l | tr -d ' ')" = 4 ] || fail "the launch detector missed a shape: $(direct_launches "$T/probe")"
found=""
for f in "$TESTS_DIR"/*.sh "$TESTS_DIR"/*.py; do
  case "$(basename "$f")" in lib.sh|agentbus_cmd.py|test_launch_paths.sh) continue ;; esac
  found="$found$(direct_launches "$f" | sed "s|^|$(basename "$f"):|")"
done
[ -z "$found" ] || { printf '%s\n' "$found" >&2; fail "direct CLI launches; use \"\${AB[@]}\" or agentbus_argv()"; }
# The helpers agree: AGENTBUS_CMD wins, then AGENTBUS_BIN under $PYTHON, else $PYTHON and the checkout.
argv_of() { "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); from agentbus_cmd import agentbus_argv; print(*agentbus_argv())' "$TESTS_DIR"; }
got=$(env -u AGENTBUS_BIN AGENTBUS_CMD='/x/agentbus --flag' bash -c "$(declare -f argv_of); PY=$PY TESTS_DIR=$TESTS_DIR argv_of")
[ "$got" = "/x/agentbus --flag" ] || fail "agentbus_argv ignored AGENTBUS_CMD: $got"
got=$(env -u AGENTBUS_CMD PYTHON=pyx AGENTBUS_BIN=/m/agentbus bash -c "$(declare -f argv_of); PY=$PY TESTS_DIR=$TESTS_DIR argv_of")
[ "$got" = "pyx /m/agentbus" ] || fail "agentbus_argv ignored AGENTBUS_BIN: $got"
for v in "AGENTBUS_CMD=/x/agentbus --flag" "AGENTBUS_BIN=/m/agentbus"; do
  got=$(env "$v" bash -c '. "$1/lib.sh"; printf "%s|" "${AB[@]}"' _ "$TESTS_DIR")
  case "$v" in
    AGENTBUS_CMD*) [ "$got" = "/x/agentbus|--flag|" ] || fail "AB ignored AGENTBUS_CMD: $got" ;;
    *) [ "$got" = "$PY|/m/agentbus|" ] || fail "AB ignored AGENTBUS_BIN: $got" ;;
  esac
done
rc=0; AGENTBUS_DB="$HOME/.agentbus-program/.agentbus/bus.db" bash -c '. "$1/lib.sh"' _ "$TESTS_DIR" >/dev/null 2>&1 || rc=$?
[ "$rc" = 99 ] || fail "lib.sh did not exit 99 for a bus under ~/.agentbus-program/ (rc $rc)"
ok "no direct CLI launches in tests; AB and agentbus_argv() honour AGENTBUS_CMD and AGENTBUS_BIN; lib.sh refuses the program bus"
echo "All launch path tests passed"
