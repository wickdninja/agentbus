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
# AGENTBUS_CMD can be a bare command name: lib.sh defines a shell function agentbus(), and a bare `agentbus`
# in AB would call that function forever. AB[0] must resolve to the file on PATH.
mkdir "$T/bare"; printf '#!/bin/sh\necho "bare agentbus ran: $*"\n' > "$T/bare/agentbus"; chmod 755 "$T/bare/agentbus"
got=$(env PATH="$T/bare:$PATH" AGENTBUS_CMD=agentbus bash -c '. "$1/lib.sh"; agentbus who' _ "$TESTS_DIR" 2>&1 | head -n 3) || true
[ "$got" = "bare agentbus ran: who" ] || fail "AGENTBUS_CMD=agentbus (a bare name) did not run the command on PATH: $got"
# lib.sh keeps every temp file a test makes under one folder and removes it at exit, even when the test's own trap does not.
root=$(bash -c '. "$1/lib.sh"; trap "true" EXIT; d=$(mktemp -d); touch "$d/x"; f=$(mktemp); case "$d" in "$TMPDIR"/*) ;; *) echo "mktemp -d ignored TMPDIR: $d" >&2; exit 1 ;; esac; echo "$TESTS_TMPROOT"' _ "$TESTS_DIR") || fail "lib.sh temp handling failed"
[ -n "$root" ] && [ ! -e "$root" ] || fail "lib.sh left its temp folder behind: $root"
# Every test file ends by saying it passed: an `All ... tests passed` line, or an ok line. (run_all.sh does not
# depend on it; a person reading the end of a run does.)
for f in "$TESTS_DIR"/test_*.sh; do
  last=$(grep -v '^[[:space:]]*$' "$f" | tail -n 1)
  case "$last" in
    'echo "All '*' passed'*|'echo "All mutations killed'*|'all_passed "All '*|'ok "'*) ;;
    *) fail "$(basename "$f") does not end with an All ... passed line or an ok line: $last" ;;
  esac
done
ok "no direct CLI launches in tests; AB and agentbus_argv() honour AGENTBUS_CMD and AGENTBUS_BIN; lib.sh refuses the program bus"
echo "All launch path tests passed"
