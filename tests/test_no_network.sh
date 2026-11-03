#!/bin/bash
set -euo pipefail
# The release check is silent where it must be (plan 13, Design 2): no attempt, no child, no request. A canary
# sitecustomize.py sits in the fake install's site-packages, so the detached `-I` check child loads it too: it leaves a
# LOAD marker whenever a python of that install starts, and a TRIPPED file when anything calls socket.getaddrinfo or
# socket.connect (then raises, so no real name lookup or connection is ever made). First a control: an eligible run at a
# terminal trips it in the child. Then each case that must stay silent runs with the load marker present (the canary
# could have tripped) and asserts no trip, no attempt in the cache, and so no child.
. "$(dirname "$0")/update_lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/cc"
unset AGENTBUS_TEST_RELEASES_URL AGENTBUS_TEST_CA_FILE
export https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9   # even a canary that failed would reach nothing

setup_canary() {  # after new_case
  export CANARY_LOAD="$C/canary.load" CANARY_TRIP="$C/canary.trip"
  rm -f "$CANARY_LOAD" "$CANARY_TRIP"
  cat >"$SITE/sitecustomize.py" <<'EOF'
import os, socket
open(os.environ["CANARY_LOAD"], "a").write("loaded\n")
def _trip(*a, **k):
    open(os.environ["CANARY_TRIP"], "a").write("tripped\n")
    raise OSError("canary: no network in tests")
socket.getaddrinfo = _trip
socket.socket.connect = _trip
EOF
}
tty_run() { abtty -- "$@"; }
silent() {  # NAME: after a run, the canary loaded (or the case never started a python of the install), and nothing was sent
  sleep 0.7
  [ ! -e "$CANARY_TRIP" ] || fail "$1: the canary tripped (a request was attempted)"
  [ ! -e "$(cache_path)/release-check.json" ] || fail "$1: an attempt was recorded: $(cat "$(cache_path)/release-check.json")"
}
tripped() { local w=0; while [ ! -e "$CANARY_TRIP" ]; do sleep 0.1; w=$((w+1)); [ $w -lt 100 ] || return 1; done; }

echo "TEST 1: control: an eligible run at a terminal trips the canary in the check child"
new_case ctl uv; setup_canary; new_bus "$CWD"
tty_run buses >/dev/null
tripped || fail "the eligible control never reached the network layer: the canary proves nothing"
wait_cache   # the child ends by writing its answer; leave nothing running when the folder is removed
[ -e "$CANARY_LOAD" ] || fail "the canary was not loaded"
ok "the canary trips"

echo "TEST 2: no attempt, no child and no request in each case that must be silent"
new_case q uv; setup_canary; new_bus "$CWD"
quiet() {  # NAME ENV-ASSIGNMENT-or-"" ARGS...  (at a terminal unless the name says otherwise)
  local name=$1 envs=$2; shift 2
  rm -rf "$(cache_path)" "$CANARY_TRIP"; : >"$CANARY_LOAD"; rm -f "$CANARY_LOAD"
  if [ -n "$envs" ]; then (cd "$CWD" && env "$envs" "$PY" "$TESTS_DIR/pty_run.py" -- "$ENTRY" "$@") >/dev/null || true
  else tty_run "$@" >/dev/null || true; fi
  [ -e "$CANARY_LOAD" ] || fail "$name: no python of the install started, so the canary proves nothing"
  silent "$name"
}
quiet "--json" "" buses --json
quiet "CI=1" "CI=1" buses
quiet "BUILD_NUMBER=1" "BUILD_NUMBER=1" buses
quiet "RUN_ID=1" "RUN_ID=1" buses
quiet "CLAUDECODE=1" "CLAUDECODE=1" buses
for v in $CODEX_MARKER_VARS; do quiet "$v=1" "$v=1" buses; done
quiet "AGENTBUS_NO_UPDATE_CHECK=1" "AGENTBUS_NO_UPDATE_CHECK=1" buses
quiet "DO_NOT_TRACK=1" "DO_NOT_TRACK=1" buses
quiet "NO_UPDATE_NOTIFIER=1" "NO_UPDATE_NOTIFIER=1" buses
quiet "NO_UPDATE_NOTIFIER=0" "NO_UPDATE_NOTIFIER=0" buses
quiet "NO_UPDATE_NOTIFIER set empty" "NO_UPDATE_NOTIFIER=" buses
quiet "AGENTBUS_NO_UPDATE_NOTICE=1" "AGENTBUS_NO_UPDATE_NOTICE=1" buses
# a stream that is not a terminal: each of the three in turn
for pipe in in out err; do
  rm -rf "$(cache_path)" "$CANARY_TRIP"; rm -f "$CANARY_LOAD"
  keep=$(printf '%s\n' in out err | grep -vx "$pipe" | paste -sd, -)
  (cd "$CWD" && "$PY" "$TESTS_DIR/pty_run.py" --tty "$keep" -- "$ENTRY" buses) >/dev/null || true
  [ -e "$CANARY_LOAD" ] || fail "piped $pipe: the canary was not loaded"
  silent "piped $pipe"
done
for cmd in "watch --once" "schema" "skill"; do quiet "$cmd" "" $cmd; done
ok "--json, CI, BUILD_NUMBER, RUN_ID, CLAUDECODE, each Codex marker, each switch, each non-terminal stream and the quiet commands send nothing"

echo "TEST 3: a project copy, a clone and a fork never check"
new_case other uv; setup_canary; new_bus "$CWD"
rm -rf "$(cache_path)"; rm -f "$CANARY_LOAD"
(cd "$CWD" && "$PY" "$TESTS_DIR/pty_run.py" -- "$PREFIX/bin/python" "$CWD/.agentbus/bin/agentbus" buses) >/dev/null || true
[ -e "$CANARY_LOAD" ] || fail "project copy: no canary load"; silent "project copy"
mkdir -p "$C/clone/bin" "$C/clone/.git"; sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$UPDATE_SRC" >"$C/clone/bin/agentbus"; : >"$C/clone/pyproject.toml"
rm -rf "$(cache_path)"; rm -f "$CANARY_LOAD"
(cd "$CWD" && "$PY" "$TESTS_DIR/pty_run.py" -- "$PREFIX/bin/python" "$C/clone/bin/agentbus" buses) >/dev/null || true
[ -e "$CANARY_LOAD" ] || fail "clone: no canary load"; silent "clone"
new_case fork uv 0.2.0 "https://github.com/someone/agentbus"; setup_canary; new_bus "$CWD"
rm -rf "$(cache_path)"; rm -f "$CANARY_LOAD"
tty_run buses >/dev/null
[ -e "$CANARY_LOAD" ] || fail "fork: no canary load"; silent "fork"
ok "silent"

all_passed "All no-network tests passed"
