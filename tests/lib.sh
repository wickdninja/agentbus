# Shared helpers, sourced by every tests/test_*.sh.
# The CLI runs under $PYTHON (default python3), against throwaway files only: a caller's exported
# bus settings are dropped so a test can never write into a real bus.
# Refuse to run at all when the caller's bus is the program bus (exit 99), before it is dropped.
case "${AGENTBUS_DB:-}" in
  "$HOME"/.agentbus-program/*|~/.agentbus-program/*) echo "tests/lib.sh: AGENTBUS_DB points into ~/.agentbus-program/; refusing to run" >&2; exit 99 ;;
esac
unset AGENTBUS_DB AGENTBUS_AGENT
# Nor may a test reach the caller's real Claude Code or Codex config: setup honours both variables, so a caller
# who exported either would get its skill or AGENTS.md block written there. A test that wants one sets it itself.
unset CODEX_HOME CLAUDE_CONFIG_DIR
# Nor may the caller's agent or CI signals decide what a test sees: update's release notice is silent for an agent
# session (CLAUDECODE, a Codex shell's marker, no terminal) and in CI, and off with the switches below, so a test that
# wants one sets it itself (CI stays: tests/test_package.sh reads it; the update tests unset it in tests/update_lib.sh). CODEX_MARKER_VARS is bin/agentbus's list of the variables a Codex shell carries.
CODEX_MARKER_VARS="CODEX_THREAD_ID CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED"
unset AGENTBUS_AGENT_SESSION CLAUDECODE BUILD_NUMBER RUN_ID NO_UPDATE_NOTIFIER DO_NOT_TRACK AGENTBUS_NO_UPDATE_CHECK AGENTBUS_NO_UPDATE_NOTICE GH_TOKEN GITHUB_TOKEN
for _v in $CODEX_MARKER_VARS; do unset "$_v"; done
# The update cache and the list of known bus folders follow HOME, which every test sets to its own folder: a caller's
# (or tests/run_all.sh's) XDG_CACHE_HOME / XDG_STATE_HOME must not send them somewhere else. run_all.sh pins both under
# its scratch HOME and fails a file that leaves a cache or bus list there, i.e. one that never set a HOME of its own.
unset XDG_CACHE_HOME XDG_STATE_HOME
# Setup asks `claude plugin list --json` whether the plugin is installed. A test never starts the real claude: this names
# no executable (setup then reads the plugin files), and a test that wants an answer points it at a stub it wrote.
export AGENTBUS_CLAUDE_BIN=/nonexistent/claude
# Human output is hard-wrapped to COLUMNS (else the terminal, else 80). Tests that grep long human
# lines run unwrapped, whatever terminal started them; tests/test_wrap.sh sets COLUMNS per call.
export COLUMNS=4096
PY="${PYTHON:-python3}"
# tests/term_oracle.py: the emulated terminal (libc wcwidth) the output tests render through.
export TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
# Every temp file or folder a test makes lives under one folder that is removed when the test ends, whatever the test
# did with its own trap: TMPDIR points there, a bare `mktemp` / `mktemp -d` honours it on macOS too (BSD mktemp
# ignores TMPDIR without a template), and a test's `trap '...' EXIT` also removes it. tests/run_all.sh then fails
# any file that still leaves something behind (paths stay short: socket and wrap tests have length limits) (a python tempfile in a child that bypasses this, a hard-coded path).
# (macOS's own TMPDIR ends in "/": without the strip a test's paths hold "//" and never equal a resolved path)
TESTS_TMPROOT=${TMPDIR:-/tmp}; TESTS_TMPROOT=$(command mktemp -d "${TESTS_TMPROOT%/}/t.XXXXXX") || exit 1
export TMPDIR="$TESTS_TMPROOT"
mktemp() {
  local a template=""
  for a in "$@"; do case "$a" in -*) ;; *) template=$a ;; esac; done
  if [ -z "$template" ]; then command mktemp "$@" "$TMPDIR/m.XXXXXXXX"; else command mktemp "$@"; fi
}
trap() {
  if [ $# -ge 2 ] && [ "${!#}" = EXIT ]; then builtin trap "${1}; rm -rf \"$TESTS_TMPROOT\"" EXIT; else builtin trap "$@"; fi
}
builtin trap 'rm -rf "$TESTS_TMPROOT"' EXIT
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/agentbus"
# AB: the one way a test launches the CLI (tests/agentbus_cmd.py is its Python twin). AGENTBUS_CMD is an
# installed command (split on whitespace), AGENTBUS_BIN a copy of the script (a mutation copy) run
# under $PY, else the checkout's bin/agentbus under $PY. Every test launch uses "${AB[@]}".
if [ -n "${AGENTBUS_CMD:-}" ]; then
  read -r -a AB <<<"$AGENTBUS_CMD"
  # A bare name (AGENTBUS_CMD=agentbus) would call the agentbus() function below forever: use the file on PATH.
  case "${AB[0]}" in */*) ;; *) AB[0]=$(type -P "${AB[0]}" || echo "${AB[0]}") ;; esac
elif [ -n "${AGENTBUS_BIN:-}" ]; then AB=("$PY" "$AGENTBUS_BIN")
else AB=("$PY" "$BIN"); fi
agentbus() { "${AB[@]}" "$@"; }
ok() { echo "PASS: $1"; }
# skip_test REASON: this whole file cannot run here (a command or fixture it needs is not in this build). Exits 77:
# tests/run_all.sh prints SKIP, counts it apart from passes, and AGENTBUS_NO_SKIP=1 (CI) turns it into a failure.
skip_test() { echo "SKIP: $1"; exit 77; }
# skip_platform KEY [DETAIL]: the same, for a file that only makes sense on another OS. KEY must be one of run_all.sh's
# PLATFORM_SKIPS (not-macos, no-sandbox-exec): only those stay skips under AGENTBUS_NO_SKIP=1, because no change to the
# code under test can make the file run here. The SKIP line reads `platform: KEY (DETAIL)`.
skip_platform() { skip_test "platform: $1${2:+ ($2)}"; }
# skip_part REASON: one section of the file cannot run here; the rest still does. all_passed LINE ends the file:
# it prints LINE and exits 77 instead of 0 when any section was skipped, so a skip is never counted as a pass.
SKIPPED_PARTS=0
skip_part() { echo "SKIP: $1"; SKIPPED_PARTS=$((SKIPPED_PARTS+1)); }
all_passed() { echo "$1"; [ "$SKIPPED_PARTS" = 0 ] || exit 77; exit 0; }
fail() { echo "FAIL: $1"; exit 1; }
mode() { python3 -c 'import os,sys; print(oct(os.lstat(sys.argv[1]).st_mode & 0o7777)[2:])' "$1"; }
# njson cmd...: the length of the JSON array (or the items of the listing envelope) cmd prints; cmd's own failure fails the caller.
njson() { local o; o=$("$@") || fail "command failed: $*"; printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["items"] if isinstance(d, dict) and "items" in d else d))'; }
# outof cmd...: cmd's stdout, failing the test if cmd fails (so a grep on it never runs on nothing).
outof() { local o; o=$("$@") || fail "command failed: $*"; printf '%s\n' "$o"; }
# wait_for FILE: until FILE exists (a test pause point was reached), at most 20 s.
wait_for() { local w=0; while [ ! -e "$1" ]; do sleep 0.05; w=$((w+1)); [ $w -lt 400 ] || fail "never reached: $1"; done; }
# Every wait on a process or a marker below ends at a deadline and fails naming what it waited for, so a stall
# fails in seconds with a reason, never at run_all's 600 s cap (issue #17). The deadline is a backstop for a
# machine too loaded to finish, never the thing a test waits on: the wait ends as soon as the event happens.
# kill_tree PID: PID and its children (a function run with & leaves its command as a child), by PID only.
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill "$c" 2>/dev/null || true; done; kill "$1" 2>/dev/null || true; }
# wait_exit PID SECONDS WHAT: until the background job PID has exited, then its status is in WAIT_RC. At the deadline
# the job is killed and the test fails: "WHAT: still running after N s".
wait_exit() {
  local pid=$1 limit=$2 what=$3 end=$((SECONDS + $2))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$end" ]; then kill_tree "$pid"; fail "$what: still running after $limit s"; fi
    sleep 0.05
  done
  WAIT_RC=0; wait "$pid" || WAIT_RC=$?
}
# wait_marker FILE PID SECONDS WHAT [STDERR_FILE]: until FILE exists (a test pause point was reached). Fails at once,
# with the job's stderr, when the job PID exits first (it can never get there), and at the deadline otherwise.
wait_marker() {
  local file=$1 pid=$2 limit=$3 what=$4 errf=${5:-/dev/null} end=$((SECONDS + $3))
  while [ ! -e "$file" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      WAIT_RC=0; wait "$pid" || WAIT_RC=$?
      [ -e "$file" ] && return 0   # it got there and then finished
      fail "$what: the command exited (rc $WAIT_RC) before getting there: $(cat "$errf" 2>/dev/null)"
    fi
    if [ "$SECONDS" -ge "$end" ]; then kill_tree "$pid"; fail "$what: not reached after $limit s"; fi
    sleep 0.05
  done
}
# plant_big_messages DB TO N [SENDER]: N messages to TO, 3 KB each, inserted straight into the bus (fast). A listing cuts a
# body at 2 KB, so N of them are about N * 2.1 KB of output; a test that needs output to outlast a reader's buffer plants
# enough to pass the pipe (64 KB on Linux, up to 1 MB if it grew) AND the first block a reader may take before it leaves
# (uutils head and BSD head read 64 KB at once, which made a 126 KB output fit "in the pipe" on CI): N = 600 is 1.2 MB.
plant_big_messages() {
  python3 - "$1" "$2" "$3" "${4:-a}" <<'PYPLANT'
import sqlite3, sys
db, to, n, sender = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
c = sqlite3.connect(db)
c.executemany("INSERT INTO messages(ts,sender,recipient,kind,body) VALUES(?,?,?,?,?)",
              [("2026-01-01T00:00:00Z", sender, to, "note", "m%d " % i + "x" * 3000) for i in range(n)])
c.commit(); c.close()
PYPLANT
}
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
