#!/bin/bash
set -euo pipefail
# The once-a-day release notice (plan 13, Design 2): a detached check, a cache, one stderr line for a person at a
# terminal. Every case runs a fake install against tests/fixtures/release_server.py (HTTPS on 127.0.0.1, a test-only CA
# file), at a pseudo-terminal where a person would be. Each negative sits beside a positive control and asserts text.
. "$(dirname "$0")/update_lib.sh"
T=$(mktemp -d); trap 'stop_servers; rm -rf "$T"' EXIT
mkdir "$T/srv"; start_server "$T/srv"
export CLAUDE_CONFIG_DIR="$T/cc"   # plugin lookup stays inside the test

# tty_run ARGS: one command at a terminal; prints the terminal text.
tty_run() { abtty -- "$@"; }
notice_in() { grep -qF -- "$NOTICE_RE" <<<"$1"; }
setup_case() { new_case "$@"; new_bus "$CWD"; reset_reqs; }

echo "TEST 1: a stale cache at a terminal: the attempt is recorded, one request is made, the next run prints the exact notice"
setup_case t1 uv 0.2.0
rel_latest 0.3.0
out=$(tty_run buses)
notice_in "$out" && fail "the first run printed a notice before any answer existed: $out"
[ "$(cache_get checked_at)" != "" ] || fail "no attempt was recorded in the cache"
wait_cache
[ "$(reqs)" = 1 ] || fail "wanted exactly one request, got $(reqs)"
[ "$(cache_get ok)" = True ] && [ "$(cache_get stable)" = 0.3.0 ] || fail "cache after the check: $(cat "$(cache_path)/release-check.json")"
out=$(tty_run buses)
grep -qxF "agentbus: a new release is available: 0.2.0 -> 0.3.0. Run: agentbus update" <<<"$out" || fail "the notice is not the exact line: $out"
out=$(tty_run buses)
notice_in "$out" && fail "a third run printed the notice again within a day: $out"
[ "$(reqs)" = 1 ] || fail "later runs asked again: $(reqs)"
ok "one attempt, one request, the exact notice once, then silence"

echo "TEST 2: a slow server does not hold the command, and nothing is asked again within a day"
setup_case t2 uv
answer "{\"wait_for\": \"$SERVER/go\", \"body\": \"{\\\"tag_name\\\": \\\"v0.3.0\\\"}\"}"
rm -f "$SERVER/go"
out=$(tty_run buses)   # returns while the server is still holding its answer: the check is detached
[ ! -e "$SERVER/go" ] && [ "$(cache_get ok)" = "" ] || fail "the command waited for the server: $out"
tty_run buses >/dev/null
: >"$SERVER/go"
wait_cache
[ "$(reqs)" = 1 ] || fail "a second run within a day made another request: $(reqs)"
ok "run 1 ends before the server answers, run 2 sends nothing"

echo "TEST 3: answers that cannot be used give no notice and are cached as failures; the controls notify"
check_bad() {  # NAME ANSWER REASON
  setup_case "bad-$1"; answer "$2"
  tty_run buses >/dev/null; wait_cache
  [ "$(cache_get ok)" = False ] && [ "$(cache_get reason)" = "$3" ] || fail "$1: cache says ok=$(cache_get ok) reason=$(cache_get reason), wanted False $3"
  out=$(tty_run buses); notice_in "$out" && fail "$1: a notice came from an unusable answer: $out"
  [ "$(reqs)" = 1 ] || fail "$1: asked more than once: $(reqs)"
}
check_bad http500 '{"status": 500}' http
check_bad redirect '{"status": 302, "location": "/trap"}' redirect
[ "$(grep -c '"/trap"' "$SERVER/requests.log" || true)" = 0 ] || fail "the redirect target was fetched"
check_bad wrongtype '{"type": "text/html", "body": "{\"tag_name\": \"v0.3.0\"}"}' malformed
check_bad huge '{"repeat": ["x", 2097152]}' too_large
check_bad badjson '{"body": "{not json"}' malformed
check_bad deep '{"repeat": ["[", 200000]}' malformed
check_bad epoch '{"body": "{\"tag_name\": \"v1!9.0.0\"}"}' malformed
check_bad notag '{"body": "{\"tag_name\": \"nightly\"}"}' malformed
setup_case t3-ok; answer '{"type": "application/json; charset=utf-8", "body": "{\"tag_name\": \"v0.3.0\"}"}'
tty_run buses >/dev/null; wait_cache
out=$(tty_run buses); notice_in "$out" || fail "a charset parameter on the type must still notify: $out"
ok "500, redirect (target untouched), wrong type, 2 MiB, bad JSON, deep JSON and an epoch tag are silent; charset=utf-8 notifies"

echo "TEST 4: only a newer final release notifies a final install; a missing release is not an error"
setup_case t4a; rel_latest 0.3.0rc1; tty_run buses >/dev/null; wait_cache
[ "$(cache_get ok)" = True ] && [ "$(cache_get stable)" = "" ] || fail "rc-only answer: $(cat "$(cache_path)/release-check.json")"
out=$(tty_run buses); notice_in "$out" && fail "a release candidate was announced to a final install: $out"
setup_case t4b; rel_latest 0.1.0; tty_run buses >/dev/null; wait_cache
out=$(tty_run buses); notice_in "$out" && fail "a lower release was announced: $out"
[ "$(cache_get ok)" = True ] || fail "lower-only answer is a good answer"
setup_case t4c; answer '{"status": 404}'; tty_run buses >/dev/null; wait_cache
[ "$(cache_get ok)" = True ] && [ "$(cache_get stable)" = "" ] || fail "404 (no release yet): $(cat "$(cache_path)/release-check.json")"
out=$(tty_run buses); notice_in "$out" && fail "a notice with no release: $out"
ok "rc-only, lower-only and 404 give no notice (ok true, no stable)"

echo "TEST 5: a cache dated in the future is checked again; planted versions are re-guarded"
setup_case t5a; rel_latest 0.3.0
cache_put "{\"v\":1,\"checked_at\":$(( $(now) + 200000 )),\"ok\":true,\"reason\":null,\"retry_after\":null,\"stable\":null,\"pre\":null,\"notified\":null}"
tty_run buses >/dev/null
w=0; while [ "$(reqs)" = 0 ]; do sleep 0.1; w=$((w+1)); [ $w -lt 100 ] || fail "a future checked_at was trusted"; done
setup_case t5b
cache_put "{\"v\":1,\"checked_at\":$(now),\"ok\":true,\"reason\":null,\"retry_after\":null,\"stable\":\"1!9.0\",\"pre\":null,\"notified\":null}"
out=$(tty_run buses); notice_in "$out" && fail "a planted 1!9.0 was announced: $out"
setup_case t5c
cache_put "{\"v\":1,\"checked_at\":$(now),\"ok\":true,\"reason\":null,\"retry_after\":null,\"stable\":\"9.0.0\",\"pre\":null,\"notified\":null}"
out=$(tty_run buses); notice_in "$out" && grep -qF "0.2.0 -> 9.0.0" <<<"$out" || fail "the planted 9.0.0 (control) did not notify: $out"
[ "$(reqs)" = 0 ] || fail "a fresh cache made a request"
ok "future checked_at re-checks; 1!9.0 is silent; 9.0.0 notifies"

echo "TEST 6: a release candidate hears of the next candidate, then the final"
setup_case t6a uv 0.2.0rc1; rel_list 0.2.0rc2 0.1.0; tty_run buses >/dev/null; wait_cache
out=$(tty_run buses); grep -qF "0.2.0rc1 -> 0.2.0rc2" <<<"$out" || fail "rc1 did not hear of rc2: $out"
grep -qF 'per_page=20' "$SERVER/requests.log" || fail "an rc install must ask the list endpoint: $(cat "$SERVER/requests.log")"
setup_case t6b uv 0.2.0rc1; rel_list 0.2.0 0.2.0rc2; tty_run buses >/dev/null; wait_cache
out=$(tty_run buses); grep -qF "0.2.0rc1 -> 0.2.0." <<<"$out" || fail "rc1 did not hear of the final: $out"
ok "rc1 -> rc2, then rc1 -> 0.2.0"

echo "TEST 7: what is sent: one GET with Accept and User-Agent agentbus, never a cookie or a token"
setup_case t7; rel_latest 0.3.0
GH_TOKEN=ghp_notasecret GITHUB_TOKEN=ghp_notasecret2 tty_run buses >/dev/null; wait_cache
"$PY" - "$SERVER/requests.log" <<'PY' || fail "the request carried more than the plan allows"
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1])]
assert len(lines) == 1, lines
h = {k.lower(): v for k, v in lines[0]["headers"].items()}
assert lines[0]["path"] == "/releases/latest", lines[0]["path"]
assert h["user-agent"] == "agentbus", h
assert h["accept"] == "application/vnd.github+json", h
assert not {"authorization", "cookie", "x-github-token"} & set(h), h
assert set(h) <= {"host", "accept", "user-agent", "accept-encoding", "connection"}, sorted(h)
PY
ok "path, Accept and User-Agent exactly; no Authorization or Cookie even with GH_TOKEN and GITHUB_TOKEN set"

echo "TEST 8: the cache is 0600 in a 0700 folder, and a symlink in its place is refused"
setup_case t8; rel_latest 0.3.0; tty_run buses >/dev/null; wait_cache
[ "$(mode "$(cache_path)")" = 700 ] && [ "$(mode "$(cache_path)/release-check.json")" = 600 ] || fail "modes: $(mode "$(cache_path)") $(mode "$(cache_path)/release-check.json")"
setup_case t8b; rel_latest 0.3.0
mkdir -p "$(cache_path)"; chmod 700 "$(cache_path)"; printf 'precious\n' >"$C/target"; ln -s "$C/target" "$(cache_path)/release-check.json"
tty_run buses >/dev/null; sleep 1
[ "$(cat "$C/target")" = precious ] || fail "the symlink was written through"
[ "$(reqs)" = 0 ] || fail "a request was made though the cache could not be written"
ok "modes 0700/0600; a symlinked cache is neither read nor written, and nothing is sent"

echo "TEST 9: a cache folder that cannot be written starts no check; a writable one (control) does"
setup_case t9; rel_latest 0.3.0
mkdir -p "$(cache_path)"; chmod 500 "$(cache_path)"
tty_run buses >/dev/null; sleep 1
[ "$(reqs)" = 0 ] || fail "a read-only cache folder still sent a request"
chmod 700 "$(cache_path)"
tty_run buses >/dev/null; wait_cache
[ "$(reqs)" = 1 ] || fail "the writable control sent $(reqs) requests"
ok "0500 sends nothing; 0700 sends one"

echo "TEST 10: --as, AGENTBUS_AGENT and DO_NOT_TRACK=0 do not make an agent session or turn the check off"
for how in "--as x" "AGENTBUS_AGENT=x" "DO_NOT_TRACK=0"; do
  setup_case "t10-${how// /_}"; rel_latest 0.3.0
  run_how() {
    if [ "$how" = "--as x" ]; then (cd "$CWD" && "$PY" "$TESTS_DIR/pty_run.py" -- "$ENTRY" --as x buses)
    else (cd "$CWD" && env "$how" "$PY" "$TESTS_DIR/pty_run.py" -- "$ENTRY" buses); fi
  }
  run_how >/dev/null; wait_cache
  out=$(run_how)
  notice_in "$out" || fail "$how: no notice: $out"
done
ok "each still checks and notifies"

echo "TEST 11: ten eligible runs at once make exactly one request"
setup_case t11; rel_latest 0.3.0
pids=()
for i in 1 2 3 4 5 6 7 8 9 10; do tty_run buses >/dev/null & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
wait_cache; sleep 1
[ "$(reqs)" = 1 ] || fail "ten concurrent runs made $(reqs) requests"
ok "one request"

all_passed "All update notice tests passed"
