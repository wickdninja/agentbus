#!/bin/bash
set -euo pipefail
# A refusal or an error says so on the first and the last line of its output in text mode (issue 86 A3): 72.6% of
# agent calls pipe (`| tail`, `| head`), a pipe's exit status is the last command's, and a lane edited a file after a
# refusal it could not see. --json errors are unchanged: one JSON object on stderr.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/bus.db"
agentbus --as a join >/dev/null
agentbus --as b join >/dev/null
agentbus --as a claim src/ --purpose "the parser" >/dev/null

# both W FIRST LAST CMD...: run CMD at COLUMNS=W with stderr into the pipe; the first line starts FIRST and the last is LAST.
both() {
  local w=$1 first=$2 last=$3; shift 3
  local out rc=0
  out=$(COLUMNS=$w agentbus "$@" 2>&1) && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "$* succeeded"
  case "$(printf '%s\n' "$out" | head -n 1)" in "$first"*) ;; *) fail "the first line of '$*' at $w columns does not start '$first':
$out" ;; esac
  [ "$(printf '%s\n' "$out" | tail -n 1)" = "$last" ] || fail "the last line of '$*' at $w columns is not '$last':
$out"
}

echo "TEST: a wrapped refusal names itself on its first and last line"
both 60 "agentbus: refused: src/x.py overlaps src/" "agentbus: refused (claim_conflict, exit 1)" --as b claim src/x.py
both 60 "agentbus: refused: ghost is not on the roster" "agentbus: refused (not_on_roster, exit 1)" --as ghost claim src/y.py --purpose "a purpose long enough to wrap the line"
ok "claim_conflict and not_on_roster at 60 columns: refused first and last"

echo "TEST: a wrapped error names itself on its first and last line"
both 50 "agentbus: error: argument --kind" "agentbus: error (bad_input, exit 2)" --as b post x --kind
both 60 "agentbus: error: unknown command 'lgo'" "agentbus: error (bad_input, exit 2)" lgo
ok "usage errors and an unknown command at 50 and 60 columns: error first and last"

echo "TEST: an unwrapped refusal is one line that says refused"
out=$(agentbus --as b claim src/x.py 2>&1) && fail "the claim succeeded" || true
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "an unwrapped refusal is not one line: $out"
case "$out" in "agentbus: refused: src/x.py overlaps src/"*) ;; *) fail "an unwrapped refusal does not start refused: $out" ;; esac
ok "one line, refused first"

echo "TEST: --json errors are unchanged"
err=$(COLUMNS=60 agentbus --json --as b claim src/x.py 2>&1 >/dev/null) && fail "the claim succeeded" || true
[ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] || fail "a JSON error is not one line: $err"
printf '%s' "$err" | python3 -c 'import json,sys; e=json.load(sys.stdin)["error"]; assert e["code"] == "claim_conflict" and not e["message"].startswith("refused"), e' \
  || fail "the JSON error changed: $err"
ok "the JSON error is the one object it was"
