# Shared helpers, sourced by every tests/test_*.sh.
# The CLI runs under $PYTHON (default python3), against throwaway files only: a caller's exported
# bus settings are dropped so a test can never write into a real bus.
# Refuse to run at all when the caller's bus is the program bus (exit 99), before it is dropped.
case "${AGENTBUS_DB:-}" in
  "$HOME"/.agentbus-program/*|~/.agentbus-program/*) echo "tests/lib.sh: AGENTBUS_DB points into ~/.agentbus-program/; refusing to run" >&2; exit 99 ;;
esac
unset AGENTBUS_DB AGENTBUS_AGENT
# Human output is hard-wrapped to COLUMNS (else the terminal, else 80). Tests that grep long human
# lines run unwrapped, whatever terminal started them; tests/test_wrap.sh sets COLUMNS per call.
export COLUMNS=4096
PY="${PYTHON:-python3}"
# tests/term_oracle.py: the emulated terminal (libc wcwidth) the output tests render through.
export TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/agentbus"
# AB: the one way a test launches the CLI (tests/agentbus_cmd.py is its Python twin). AGENTBUS_CMD is an
# installed command (split on whitespace), AGENTBUS_BIN a copy of the script (a mutation copy) run
# under $PY, else the checkout's bin/agentbus under $PY. Every test launch uses "${AB[@]}".
if [ -n "${AGENTBUS_CMD:-}" ]; then read -r -a AB <<<"$AGENTBUS_CMD"
elif [ -n "${AGENTBUS_BIN:-}" ]; then AB=("$PY" "$AGENTBUS_BIN")
else AB=("$PY" "$BIN"); fi
agentbus() { "${AB[@]}" "$@"; }
ok() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }
mode() { python3 -c 'import os,sys; print(oct(os.lstat(sys.argv[1]).st_mode & 0o7777)[2:])' "$1"; }
# njson cmd...: the length of the JSON array cmd prints; cmd's own failure fails the caller.
njson() { local o; o=$("$@") || fail "command failed: $*"; printf '%s' "$o" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
# outof cmd...: cmd's stdout, failing the test if cmd fails (so a grep on it never runs on nothing).
outof() { local o; o=$("$@") || fail "command failed: $*"; printf '%s\n' "$o"; }
# wait_for FILE: until FILE exists (a test pause point was reached), at most 20 s.
wait_for() { local w=0; while [ ! -e "$1" ]; do sleep 0.05; w=$((w+1)); [ $w -lt 400 ] || fail "never reached: $1"; done; }
mkrepo() { mkdir -p "$1"; git -C "$1" init -q; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }

# expect_fail "text stderr must contain" cmd args...
# Passes only when cmd exits non-zero, its stderr contains the text, and it is not a traceback.
expect_fail() {
  local want="$1"; shift
  local errf; errf=$(mktemp)
  if "$@" >/dev/null 2>"$errf"; then
    rm -f "$errf"; fail "expected failure but succeeded: $*"
  fi
  if grep -q 'Traceback' "$errf"; then
    cat "$errf" >&2; rm -f "$errf"; fail "traceback from: $*"
  fi
  if ! grep -qF -- "$want" "$errf"; then
    echo "stderr was:" >&2; cat "$errf" >&2; rm -f "$errf"; fail "stderr lacks '$want' from: $*"
  fi
  rm -f "$errf"
}

# json_ok cmd args...: stdout must be exactly one JSON value; prints it. Strict: NaN, Infinity and
# -Infinity are not JSON (Python's json accepts them by default), so they fail it.
json_strict='import json,sys
def bad(c): raise ValueError("not JSON: " + c)
json.load(sys.stdin, parse_constant=bad)'
json_ok() {
  local o; o=$("$@") || fail "command failed: $*"
  printf '%s' "$o" | python3 -c "$json_strict" || fail "not one JSON value: $*"
  printf '%s\n' "$o"
}
