#!/bin/bash
set -euo pipefail
# A stall in tests/test_lock_hold.sh fails in seconds and names the step; it never waits for run_all's 600 s cap
# (issue #17: TEST 1 once hung to the cap on a loaded machine and said nothing).
# Bug it catches: TEST 1 waited on its stdin command with a bare `wait` and opened its FIFO writer in a way that
# blocks until a reader exists, so one command that never finished (or never started) hung the file silently.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
CAP="$PY -I $TESTS_DIR/run_capped.py"

# A stand-in for agentbus: the command under TEST 1's pause point reaches its stdin read, then never reads or
# ends (as a process stuck in the kernel would); every other command is the real one.
cat > "$T/stuck.sh" <<'EOF'
#!/bin/bash
case "${AGENTBUS_TEST_PAUSE:-}" in
  before-stdin-read=*)
    d=${AGENTBUS_TEST_PAUSE#*=}
    : > "$d/before-stdin-read.reached"
    exec sleep 300 ;;
esac
exec $STUCK_REAL "$@"
EOF
# one that dies before it reads anything
cat > "$T/dies.sh" <<'EOF'
#!/bin/bash
case "${AGENTBUS_TEST_PAUSE:-}" in
  before-stdin-read=*) echo "boom from the stand-in" >&2; exit 3 ;;
esac
exec $STUCK_REAL "$@"
EOF
chmod +x "$T/stuck.sh" "$T/dies.sh"
export STUCK_REAL="${AB[*]}"

run_hold() {   # run_hold STAND_IN: test_lock_hold.sh with the stand-in as the agentbus; output in $T/out, status in $RC, seconds in $SECS
  local start=$SECONDS; RC=0
  AGENTBUS_CMD="$1" HOLD_TEST_WAIT_S=3 $CAP 90 bash "$TESTS_DIR/test_lock_hold.sh" >"$T/out" 2>&1 </dev/null || RC=$?
  SECS=$((SECONDS - start))
}

echo "TEST 1: a command that never finishes fails TEST 1 in seconds, naming the step"
run_hold "$T/stuck.sh"
[ "$RC" != 124 ] || fail "test_lock_hold.sh hung to the cap with a command that never finishes"
[ "$RC" = 1 ] || fail "expected the test to fail (rc 1), got rc $RC: $(tail -n 5 "$T/out")"
grep -qF "FAIL: post - after its input arrived: still running after 3 s" "$T/out" || fail "the stall was not named: $(tail -n 5 "$T/out")"
[ "$SECS" -lt 60 ] || fail "the stall took $SECS s to fail"
ok "stalled in $SECS s: $(grep -F 'FAIL:' "$T/out")"

echo "TEST 2: a command that dies before its stdin read fails TEST 1 at once, with its error"
run_hold "$T/dies.sh"
[ "$RC" != 124 ] || fail "test_lock_hold.sh hung to the cap with a command that died before its stdin read"
[ "$RC" = 1 ] || fail "expected the test to fail (rc 1), got rc $RC: $(tail -n 5 "$T/out")"
grep -qF "the command exited (rc 3) before getting there: boom from the stand-in" "$T/out" || fail "the early exit was not named: $(tail -n 5 "$T/out")"
[ "$SECS" -lt 30 ] || fail "the early exit took $SECS s to fail"
ok "died early, failed in $SECS s: $(grep -F 'FAIL:' "$T/out")"
