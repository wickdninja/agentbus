#!/bin/bash
set -euo pipefail
# The hold watchdog ends a command at 8 s, but it cannot know what a COMMIT it interrupted did: the WAL frames may
# be written, and then the write is saved. Bug it catches (issue #19): the stop said "a write still in progress was
# not saved" and committed false when it fired during the COMMIT, so a caller repeated a write that had landed.
# AGENTBUS_TEST_STALL_COMMIT=<seconds> sleeps just before the COMMIT of a write (a stand-in for a stalled fsync);
# AGENTBUS_TEST_DEADLINE=0 makes the hold 2 s so the watchdog fires inside it.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
trap 'rm -rf "$T"' EXIT
export AGENTBUS_DB="$T/bus.db"
agentbus --as a join --tool t >/dev/null

# stopped ENVVAR=SECONDS ARGS...: run a command that stalls past the hold; leaves stderr in $T/e and the status in $RC.
stopped() {
  local stall=$1; shift; RC=0
  env "$stall" AGENTBUS_TEST_DEADLINE=0 "${AB[@]}" "$@" >"$T/o" 2>"$T/e" || RC=$?
}
field() { python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; print(json.dumps(e.get(sys.argv[2], "ABSENT")))' "$T/e" "$1"; }

echo "TEST 1: stopped while committing a write, the outcome is unknown and counted as possibly saved"
stopped AGENTBUS_TEST_STALL_COMMIT=30 --json --as a post "stalled in the commit"
[ "$RC" = 3 ] || fail "exit code $RC, wanted 3: $(cat "$T/e")"
[ "$(field code)" = '"bus_unavailable"' ] || fail "code: $(cat "$T/e")"
[ "$(field committed)" = true ] || fail "committed is not true: $(cat "$T/e")"
[ "$(field outcome_unknown)" = true ] || fail "outcome_unknown is not true: $(cat "$T/e")"
[ "$(field retryable)" = false ] || fail "retryable is not false: $(cat "$T/e")"
msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["error"]["message"])' "$T/e")
grep -q "may or may not have been saved" <<<"$msg" || fail "message does not say the write may have been saved: $msg"
grep -q "request-id" <<<"$msg" && grep -qi "check" <<<"$msg" || fail "message does not say to check, or to repeat only with the request id: $msg"
! grep -q "was not saved" <<<"$msg" || fail "message still says the write was not saved: $msg"
[ ! -s "$T/o" ] || fail "stdout is not empty: $(cat "$T/o")"
ok "exit 3, committed true, outcome_unknown true, retryable false, and the message says to check or use --request-id"

echo "TEST 2: the same stop in human output does not claim the change was saved"
stopped AGENTBUS_TEST_STALL_COMMIT=30 --as a post "stalled in the commit, human"
[ "$RC" = 3 ] || fail "exit code $RC, wanted 3: $(cat "$T/e")"
tr -d '\n' <"$T/e" | sed 's/  */ /g' | grep -q "may or may not have been saved" || fail "human message: $(cat "$T/e")"
! grep -q "was saved before this" "$T/e" || fail "human message says the change was saved: $(cat "$T/e")"
ok "human output says may or may not, never 'saved before this'"

echo "TEST 3: a stall outside any commit keeps today's result"
stopped AGENTBUS_TEST_SLOW=30 --json who
[ "$RC" = 3 ] || fail "exit code $RC, wanted 3: $(cat "$T/e")"
[ "$(field committed)" = false ] || fail "committed is not false: $(cat "$T/e")"
[ "$(field outcome_unknown)" = '"ABSENT"' ] || fail "outcome_unknown is present outside a commit: $(cat "$T/e")"
python3 -c 'import json,sys; sys.exit(0 if "a write still in progress was not saved" in json.load(open(sys.argv[1]))["error"]["message"] else 1)' "$T/e" || fail "message lost 'was not saved': $(cat "$T/e")"
ok "a read stalled in Python: committed false, no outcome_unknown, 'was not saved'"

echo "TEST 4: a stall after the write was committed says committed, with no outcome_unknown"
stopped AGENTBUS_TEST_SLOW=30 --json --as a post "stalled after the commit"
[ "$RC" = 3 ] || fail "exit code $RC, wanted 3: $(cat "$T/e")"
[ "$(field committed)" = true ] || fail "committed is not true: $(cat "$T/e")"
[ "$(field outcome_unknown)" = '"ABSENT"' ] || fail "outcome_unknown is present after the commit finished: $(cat "$T/e")"
[ "$(agentbus --json read | python3 -c 'import json,sys; print(sum(r["body"]=="stalled after the commit" for r in json.load(sys.stdin)["items"]))')" = 1 ] || fail "the committed write is not on the bus"
ok "after the commit: committed true, nothing unknown, and the write is on the bus"

echo "TEST 5: a stop during a commit that is not the command's own change is unknown but not committed"
# who --as a only refreshes last_seen: that commit is setup, not the command's write
stopped AGENTBUS_TEST_STALL_COMMIT=30 --json --as a who
[ "$RC" = 3 ] || fail "exit code $RC, wanted 3: $(cat "$T/e")"
[ "$(field outcome_unknown)" = true ] || fail "outcome_unknown is not true: $(cat "$T/e")"
[ "$(field committed)" = false ] || fail "committed is not false for a refresh of last_seen: $(cat "$T/e")"
ok "last_seen refresh: outcome_unknown true, committed false"

echo "TEST 6: a command with nothing to commit is not affected by the hook"
stopped AGENTBUS_TEST_STALL_COMMIT=30 --json who
[ "$RC" = 0 ] || fail "a read with no name was stopped by the commit stall hook (rc $RC): $(cat "$T/e")"
ok "nothing to commit, nothing stalled"
all_passed "All hold-stall tests passed"
