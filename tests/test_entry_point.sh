#!/usr/bin/env bash
# One entry point: the installed command (pyproject's script) and bin/agentbus both run cli(), so an
# unexpected error under --json is the same JSON error either way, never a traceback.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
ROOT="$(cd "$(dirname "$BIN")/.." && pwd)"
MOD="${AGENTBUS_BIN:-$BIN}"

echo "TEST 1: pyproject's entry point is agentbus:cli and bin/agentbus defines cli"
grep -qxF 'agentbus = "agentbus:cli"' "$ROOT/pyproject.toml" || fail "pyproject.toml does not install agentbus:cli"
grep -q '^def cli():' "$MOD" || fail "bin/agentbus defines no cli()"
grep -qx '    cli()' "$MOD" || fail "bin/agentbus's __main__ block does not call cli()"
ok "pyproject installs agentbus:cli, which bin/agentbus defines and runs"

# check_crash FILE RC: the stderr of a crashed --json command is exactly one internal JSON error.
check_crash() {
  "$PY" - "$1" "$2" <<'PY' || fail "crash output: $(cat "$1")"
import json, sys
text, rc = open(sys.argv[1]).read(), int(sys.argv[2])
assert rc == 4, rc  # internal: the contract's exit for a bug
assert "Traceback" not in text, text
e = json.loads(text)["error"]
assert e["code"] == "internal" and e["message"] == "test crash", e
PY
}

echo "TEST 2: an unexpected error under --json is a JSON internal error through the installed entry point"
# The wheel ships bin/agentbus as the module agentbus.py and its script calls agentbus.cli().
mkdir -p "$T/site"; cp "$MOD" "$T/site/agentbus.py"
rc=0; AGENTBUS_TEST_CRASH=1 AGENTBUS_DB="$T/bus.db" "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); sys.argv = ["agentbus", "--json", "who"]; import agentbus; sys.exit(agentbus.cli())' "$T/site" 2>"$T/err" >/dev/null || rc=$?
check_crash "$T/err" "$rc"
ok "agentbus.cli() turns a crash into {\"error\":{\"code\":\"internal\",...}}"

echo "TEST 2b: the installed entry point applies the contract: an unknown command under --json exits 2 with bad_input"
rc=0; AGENTBUS_DB="$T/bus.db" "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); sys.argv = ["agentbus", "--json", "no-such-command"]; import agentbus; sys.exit(agentbus.cli())' "$T/site" 2>"$T/err" >"$T/out" || rc=$?
"$PY" - "$T/err" "$rc" <<'PY' || fail "unknown command through cli(): rc $rc, $(cat "$T/err")"
import json, sys
text, rc = open(sys.argv[1]).read(), int(sys.argv[2])
assert rc == 2, rc
e = json.loads(text)["error"]
assert e["code"] == "bad_input" and e["retryable"] is False and e["committed"] is False, e
PY
[ ! -s "$T/out" ] || fail "an unknown command printed on stdout: $(cat "$T/out")"
ok "agentbus.cli() exits 2 with a JSON bad_input error for an unknown command"

echo "TEST 3: the same through the command this suite runs, and a crash without --json still shows the traceback"
rc=0; AGENTBUS_TEST_CRASH=1 AGENTBUS_DB="$T/bus.db" "${AB[@]}" --json who 2>"$T/err" >/dev/null || rc=$?
check_crash "$T/err" "$rc"
[ ! -e "$T/bus.db" ] || fail "the crash hook ran after the bus was opened"
rc=0; AGENTBUS_TEST_CRASH=1 AGENTBUS_DB="$T/bus.db" "${AB[@]}" who 2>"$T/err" >/dev/null || rc=$?
[ "$rc" = 4 ] && grep -q 'RuntimeError: test crash' "$T/err" || fail "a crash without --json: rc $rc, $(cat "$T/err")"
ok "the CLI gives the same JSON error; human mode keeps the traceback for a bug report"

echo "All entry point tests passed"
