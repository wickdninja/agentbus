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
[ "$rc" = 0 ] && [ "$out" = "agent invocations: 72 (16 cells x 3 attempts)" ] || fail "dry run: rc $rc: $out"
rc=0; out=$(env -u EVAL_STUB_DIR "${EVAL[@]}" --cell claude skill resume 2>&1) || rc=$?
[ "$rc" = 3 ] && grep -q '^agent invocations: 3 ' <<<"$out" && grep -q -- '--go' <<<"$out" || fail "a real run without --go: rc $rc: $out"
ok "dry run counts 72; no --go means no run"

echo "TEST 2: every scenario passes for both agents' formats with a well-behaved stand-in"
run_eval --arm skill --attempts 1
[ "$rc" = 0 ] || { cat "$T/out"; fail "a good stand-in failed a cell (rc $rc)"; }
[ "$(tail -n 1 "$T/out")" = "eval complete: 8 of 8 cells pass" ] || fail "last line: $(tail -n 1 "$T/out")"
grep -q '^worktrees: pass (1 of 1 attempts)$' "$T/out" || fail "no worktrees line: $(cat "$T/out")"
grep -q '^resume: pass (1 of 1 attempts)$' "$T/out" || fail "no resume line: $(cat "$T/out")"
ok "8 of 8 cells pass"

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
bad side-bus claude worktrees "second bus was made: wts"
bad side-bus codex worktrees "second bus was made: wts"
ok "edit before inbox, a missing done message, an edit through a conflict and a second bus made for the worktrees each fail"

echo "TEST 4: the hooks arm runs once setup exists, and is reported as unsupported until then"
if "${AB[@]}" setup --help >/dev/null 2>&1; then
  run_eval --cell claude hooks resume --attempts 1
  grep -q '^resume: pass (1 of 1 attempts)$' "$T/out" || { cat "$T/out"; fail "hooks arm did not run"; }
else
  run_eval --cell claude hooks resume --attempts 1
  grep -q 'unsupported' "$T/out" && [ "$(tail -n 1 "$T/out")" = "eval complete: 0 of 1 cells pass" ] || { cat "$T/out"; fail "hooks arm not reported unsupported"; }
fi
ok "hooks arm handled"
echo "TEST 5: nothing the harness gives an agent names the project copy; the tool under test is on the agent's PATH"
! grep -qF '.agentbus/bin/agentbus' "$(cd "$TESTS_DIR/.." && pwd)/scripts/agent-eval/run.py" || fail "scripts/agent-eval/run.py tells an agent to run the project copy"
ok "the stub agents above reached the bus through agentbus on PATH"
echo "TEST 6: with AGENTBUS_CMD unset, the agentbus on PATH is found before the harness's own agentbus shim goes first on PATH"
# Bug it catches: the shim was `exec agentbus "$@"` placed first on PATH, so it ran itself until the setup step timed out.
mkdir -p "$T/abbin"; printf '#!/bin/sh\nexec %s "$@"\n' "$AGENTBUS_CMD" >"$T/abbin/agentbus"; chmod 755 "$T/abbin/agentbus"
rc=0; env -u AGENTBUS_CMD PATH="/usr/bin:/bin" EVAL_STUB_DIR="$STUB" "${EVAL[@]}" --cell claude skill handoff --attempts 1 --out "$T/nopath" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -qF "agentbus is not on PATH" "$T/out" && ! grep -q "timed out" "$T/out" || { cat "$T/out"; fail "with no agentbus on PATH and no AGENTBUS_CMD the harness did not refuse plainly (rc $rc)"; }
rc=0; env -u AGENTBUS_CMD PATH="$T/abbin:$PATH" EVAL_STUB_DIR="$STUB" "${EVAL[@]}" --cell claude skill handoff --attempts 1 --out "$T/onpath" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && [ "$(tail -n 1 "$T/out")" = "eval complete: 1 of 1 cells pass" ] || { cat "$T/out"; fail "with AGENTBUS_CMD unset the harness did not run the agentbus on PATH (rc $rc)"; }
ok "a bare agentbus is resolved on PATH first; none on PATH is a plain refusal"
echo "All eval harness tests passed"
