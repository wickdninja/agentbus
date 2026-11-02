#!/bin/bash
set -euo pipefail
# scripts/agent-eval.sh end to end with a stand-in agent (tests/fixtures/eval_stub) instead of Claude Code and
# Codex: no tokens. Proves the harness builds the project and bus, captures both harnesses' event formats,
# reads the bus by SQL, runs the functional checks, grades, and prints the documented lines; and that a
# misbehaving agent fails its cell. The real harness command lines are checked by the baseline run, not here.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_CMD="$(printf '%q ' "${AB[@]}")"
EVAL=(bash "$ROOT/scripts/agent-eval.sh")
STUB="$ROOT/tests/fixtures/eval_stub"
# eval ARGS...: runs the harness with the stand-in agent; stdout to $T/out, status in $rc.
run_eval() { rc=0; env EVAL_STUB_DIR="$STUB" "${EVAL[@]}" "$@" --out "$T/o$RANDOM" >"$T/out" 2>&1 || rc=$?; }

echo "TEST 1: the invocation count is printed first, and a real run needs --go"
rc=0; out=$(env -u EVAL_STUB_DIR "${EVAL[@]}" --dry-run --all) || rc=$?
[ "$rc" = 0 ] && [ "$out" = "agent invocations: 60 (12 cells x 3 attempts)" ] || fail "dry run: rc $rc: $out"
rc=0; out=$(env -u EVAL_STUB_DIR "${EVAL[@]}" --cell claude skill resume 2>&1) || rc=$?
[ "$rc" = 3 ] && grep -q '^agent invocations: 3 ' <<<"$out" && grep -q -- '--go' <<<"$out" || fail "a real run without --go: rc $rc: $out"
ok "dry run counts 60; no --go means no run"

echo "TEST 2: every scenario passes for both agents' formats with a well-behaved stand-in"
run_eval --arm skill --attempts 1
[ "$rc" = 0 ] || { cat "$T/out"; fail "a good stand-in failed a cell (rc $rc)"; }
[ "$(tail -n 1 "$T/out")" = "eval complete: 6 of 6 cells pass" ] || fail "last line: $(tail -n 1 "$T/out")"
grep -q '^resume: pass (1 of 1 attempts)$' "$T/out" || fail "no resume line: $(cat "$T/out")"
ok "6 of 6 cells pass"

echo "TEST 3: a misbehaving agent fails its cell, for the right reason"
bad() { # MISBEHAVE AGENT SCENARIO WANTED-REASON
  rc=0; env EVAL_STUB_MISBEHAVE="$1" EVAL_STUB_DIR="$STUB" "${EVAL[@]}" --cell "$2" skill "$3" --attempts 1 --out "$T/bad$RANDOM" >"$T/out" 2>&1 || rc=$?
  [ "$rc" = 1 ] || { cat "$T/out"; fail "$1: the cell did not fail (rc $rc)"; }
  grep -q -- "$4" "$T/out" || { cat "$T/out"; fail "$1: failed for another reason (wanted: $4)"; }
  [ "$(tail -n 1 "$T/out")" = "eval complete: 0 of 1 cells pass" ] || fail "$1: last line: $(tail -n 1 "$T/out")"
}
bad edit-first claude handoff "bob edited before its first inbox"
bad no-done codex handoff "no done message from bob"
bad edit-first claude resume "edited before inbox"
bad ignore-conflict codex conflict "while alice held a claim"
ok "edit before inbox, a missing done message and an edit through a conflict each fail"

echo "TEST 4: the hooks arm runs once setup exists, and is reported as unsupported until then"
if "${AB[@]}" setup --help >/dev/null 2>&1; then
  run_eval --cell claude hooks resume --attempts 1
  grep -q '^resume: pass (1 of 1 attempts)$' "$T/out" || { cat "$T/out"; fail "hooks arm did not run"; }
else
  run_eval --cell claude hooks resume --attempts 1
  grep -q 'unsupported' "$T/out" && [ "$(tail -n 1 "$T/out")" = "eval complete: 0 of 1 cells pass" ] || { cat "$T/out"; fail "hooks arm not reported unsupported"; }
fi
ok "hooks arm handled"
echo "All eval harness tests passed"
