#!/bin/bash
set -euo pipefail
# Isolation: no test may write the caller's bus, the caller's home, or the checkout. tests/run_all.sh proves it
# once, around the normal run (it runs every file with AGENTBUS_DB, AGENTBUS_AGENT and HOME pointed into a scratch
# folder, then checks the folder and `git status --ignored` of the checkout). This file proves that check catches
# each kind of leak and lets a clean test through. Bug it replaces: rerunning the whole suite inside one test,
# which took 450 to 900 s and went red under load.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
RUNNER="$ROOT/tests/run_all.sh"
T=$(mktemp -d)
trap 'rm -rf "$T" "$ROOT/.isolation-probe"' EXIT
mkdir "$T/tests"
# leak NAME BODY: a throwaway test file with the given body.
leak() { printf '#!/bin/bash\n%s\n' "$2" > "$T/tests/test_$1.sh"; }
# run FILE...: the runner on throwaway files; output in $T/out, status in $rc.
run() { rc=0; env -u AGENTBUS_NO_SKIP bash "$RUNNER" "$@" >"$T/out" 2>&1 || rc=$?; }

echo "TEST 1: a test that writes the caller's AGENTBUS_DB fails, and the line names it"
leak db 'touch "$AGENTBUS_DB"'
run "$T/tests/test_db.sh"
[ "$rc" = 1 ] && grep -q "^FAIL $T/tests/test_db.sh (isolation: it wrote the caller's AGENTBUS_DB" "$T/out" && [ "$(tail -n 1 "$T/out")" = "FAILED: $T/tests/test_db.sh" ] \
  || fail "a write to the caller's AGENTBUS_DB passed (rc $rc): $(cat "$T/out")"
ok "caller's bus write caught"

echo "TEST 2: a test that writes the caller's ~/.agentbus fails"
leak home 'mkdir -p "$HOME/.agentbus"'
run "$T/tests/test_home.sh"
[ "$rc" = 1 ] && grep -q "^FAIL $T/tests/test_home.sh (isolation: it wrote the caller's ~/.agentbus" "$T/out" || fail "a write to ~/.agentbus passed (rc $rc): $(cat "$T/out")"
ok "caller's home write caught"

echo "TEST 2b: a test that writes the caller's CODEX_HOME or CLAUDE_CONFIG_DIR fails, and the line names it"
for v in CODEX_HOME CLAUDE_CONFIG_DIR; do
  leak cfg "mkdir -p \"\$$v\""
  run "$T/tests/test_cfg.sh"
  [ "$rc" = 1 ] && grep -q "^FAIL $T/tests/test_cfg.sh (isolation: it wrote the caller's $v" "$T/out" || fail "a write to the caller's $v passed (rc $rc): $(cat "$T/out")"
done
ok "caller's Codex and Claude Code config writes caught"

echo "TEST 3: a test that changes the checkout fails, ignored files included"
leak tree "touch '$ROOT/.isolation-probe'"
run "$T/tests/test_tree.sh"
[ "$rc" = 1 ] && grep -q "^FAIL $T/tests/test_tree.sh (isolation: it changed the checkout: .*isolation-probe" "$T/out" || fail "a new file in the checkout passed (rc $rc): $(cat "$T/out")"
rm -f "$ROOT/.isolation-probe"
ok "checkout change caught"

echo "TEST 3b: a test that leaves files in TMPDIR fails, and only that file is named"
# (python's tempfile honours TMPDIR everywhere; a bare `mktemp -d` on macOS does not, so it is not used here)
leak tmp 'python3 -c "import tempfile; tempfile.mkdtemp(prefix=\"left-behind-\")"'
leak zclean 'true'
rc=0; env -u AGENTBUS_NO_SKIP bash "$RUNNER" --keep-going "$T/tests/test_tmp.sh" "$T/tests/test_zclean.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q "^FAIL $T/tests/test_tmp.sh (isolation: it left files in TMPDIR: left-behind-" "$T/out" && grep -q "^PASS $T/tests/test_zclean.sh" "$T/out" \
  && [ "$(tail -n 1 "$T/out")" = "FAILED: $T/tests/test_tmp.sh" ] || fail "a TMPDIR leftover was not pinned on its file (rc $rc): $(cat "$T/out")"
ok "TMPDIR leftover caught and attributed"

echo "TEST 3c: with no git of its own the checkout check still runs: no .git at all, and a copy inside another repo"
mkdir -p "$T/nogit/tests"; cp "$RUNNER" "$T/nogit/tests/run_all.sh"; cp "$TESTS_DIR/run_capped.py" "$T/nogit/tests/"; echo keep > "$T/nogit/tests/data.txt"
printf '#!/bin/bash\necho changed > "%s/tests/data.txt"\n' "$T/nogit" > "$T/nogit/tests/test_leak.sh"
rc=0; env -u AGENTBUS_NO_SKIP bash "$T/nogit/tests/run_all.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q "test_leak.sh (isolation: it changed the checkout" "$T/out" || fail "a change in a tree without git passed (rc $rc): $(cat "$T/out")"
g() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
mkdir -p "$T/parent/child/tests"; git -C "$T/parent" init -q
cp "$RUNNER" "$TESTS_DIR/run_capped.py" "$T/parent/child/tests/"; echo keep > "$T/parent/child/tests/data.txt"
g "$T/parent" add .; g "$T/parent" commit -q -m init
printf '#!/bin/bash\necho more >> "%s/tests/data.txt"\n' "$T/parent/child" > "$T/parent/child/tests/test_leak.sh"
rc=0; env -u AGENTBUS_NO_SKIP bash "$T/parent/child/tests/run_all.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q "test_leak.sh (isolation: it changed the checkout" "$T/out" || fail "a change in a copy inside another repo passed (rc $rc): $(cat "$T/out")"
echo dirty >> "$T/parent/child/tests/data.txt"   # now data.txt is already modified: a second edit must still show
rc=0; env -u AGENTBUS_NO_SKIP bash "$T/parent/child/tests/run_all.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q "test_leak.sh (isolation: it changed the checkout" "$T/out" || fail "editing an already modified file passed (rc $rc): $(cat "$T/out")"
printf '#!/bin/bash\ntrue\n' > "$T/nogit/tests/test_leak.sh"
rc=0; env -u AGENTBUS_NO_SKIP bash "$T/nogit/tests/run_all.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "a clean tree without git failed (rc $rc): $(cat "$T/out")"
ok "checkout check works without git, inside another repo, and on a file that was already modified"

echo "TEST 3f: a syntax error in tests/lib.sh, tests/workflow_lib.sh or a test file fails the run before any file runs"
# Bug it catches: a broken lib.sh was sourced, bash carried on past the error, and the run printed ALL TESTS PASSED.
for broken in lib.sh workflow_lib.sh test_ok.sh; do
  rm -rf "$T/syn"; mkdir -p "$T/syn/tests"; cp "$RUNNER" "$TESTS_DIR/run_capped.py" "$TESTS_DIR/lib.sh" "$TESTS_DIR/workflow_lib.sh" "$T/syn/tests/"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib.sh"\nok fine\n' > "$T/syn/tests/test_ok.sh"
  printf '\nif then fi (\n' >> "$T/syn/tests/$broken"
  rc=0; env -u AGENTBUS_NO_SKIP bash "$T/syn/tests/run_all.sh" >"$T/out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q "^FAIL tests/$broken (syntax: " "$T/out" && [ "$(tail -n 1 "$T/out")" = "FAILED: tests/$broken" ] \
    && ! grep -q '^PASS' "$T/out" || fail "a syntax error in $broken did not fail the run first (rc $rc): $(cat "$T/out")"
done
ok "a syntax error in either lib or a test file fails the run, naming the file, before anything runs"

echo "TEST 3d: test_docs.sh works in a copy of the tree with no .git (it lists files itself there)"
mkdir "$T/copy"; (cd "$ROOT" && tar -c --exclude=.git --exclude=__pycache__ .) | tar -x -C "$T/copy"
[ ! -e "$T/copy/.git" ] || fail "the copy has a .git"
rc=0; env -u AGENTBUS_NO_SKIP bash "$RUNNER" "$T/copy/tests/test_docs.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "test_docs.sh failed in a tree without .git (rc $rc): $(cat "$T/out")"
ok "test_docs.sh runs without git"

echo "TEST 3e: the private TMPDIR and HOME stay short (socket paths and the wrap tests have length limits)"
# Measured as the real path, because macOS /tmp is /private/tmp. The brain's clones live under long paths: nothing here may grow with them.
leak len 'p=$(cd "$TMPDIR" && pwd -P); h=$(cd "$HOME" && pwd -P)
[ ${#p} -le 26 ] || { echo "TMPDIR is ${#p} characters: $p"; exit 1; }
[ ${#h} -le 26 ] || { echo "HOME is ${#h} characters: $h"; exit 1; }
. "'"$TESTS_DIR"'/lib.sh"
d=$(mktemp -d); d=$(cd "$d" && pwd -P)
[ ${#d} -le 44 ] || { echo "a test temp dir is ${#d} characters: $d"; exit 1; }
sock="$d/s.sock"; python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$sock" || exit 1'
run "$T/tests/test_len.sh"
[ "$rc" = 0 ] || fail "paths under the runner are too long (rc $rc): $(cat "$T/out")"
ok "TMPDIR and HOME stay under 27 characters, a lib.sh temp dir under 45, and a socket binds there"

echo "TEST 4: a clean test passes and really does run with the poisoned caller environment"
leak clean '[ "$AGENTBUS_AGENT" = caller ] && [ -n "$AGENTBUS_DB" ] && [ "$HOME" != "'"$HOME"'" ] || { echo "env not poisoned: $AGENTBUS_AGENT $AGENTBUS_DB $HOME"; exit 1; }'
run "$T/tests/test_clean.sh"
[ "$rc" = 0 ] && [ "$(tail -n 1 "$T/out")" = "ALL TESTS PASSED (1 files)" ] || fail "a clean test failed (rc $rc): $(cat "$T/out")"
ok "clean test passes under the poisoned environment"

echo "TEST 5: a real test file ignores the caller's bus settings (one fast file, run the same way)"
env AGENTBUS_DB="$T/caller.db" AGENTBUS_AGENT=caller bash "$TESTS_DIR/test_goal.sh" >"$T/goal.out" 2>&1 || { cat "$T/goal.out"; fail "test_goal.sh failed under a caller's bus env"; }
[ ! -e "$T/caller.db" ] || fail "test_goal.sh wrote the caller's AGENTBUS_DB"
ok "test_goal.sh leaves the caller's bus alone"
echo "TEST 6: the gates that run a real setup leave a caller's exported CODEX_HOME and CLAUDE_CONFIG_DIR byte-identical"
# Bug it catches: lib.sh, workflow_lib.sh and verify_installed.sh replaced HOME but passed both variables through, so
# setup wrote the agentbus block into the caller's real AGENTS.md and the skill into their real Claude Code config.
S="$T/sentinel"; mkdir -p "$S/codex" "$S/claude/skills/mine"
printf 'my own codex rules\n' > "$S/codex/AGENTS.md"; printf 'my own skill\n' > "$S/claude/skills/mine/SKILL.md"
snap() { (cd "$S" && find . -print0 | sort -z | xargs -0 ls -ld | awk '{print $1, $5, $NF}'; find . -type f -print0 | sort -z | xargs -0 cksum); }
snap > "$T/sentinel.before"
for t in test_workflow_first_run test_workflow_setup_cycle; do
  env CODEX_HOME="$S/codex" CLAUDE_CONFIG_DIR="$S/claude" bash "$TESTS_DIR/$t.sh" >"$T/$t.out" 2>&1 || { tail -n 20 "$T/$t.out"; fail "$t.sh failed with the caller's config variables set"; }
done
env CODEX_HOME="$S/codex" CLAUDE_CONFIG_DIR="$S/claude" bash "$ROOT/scripts/verify_installed.sh" --quick "${AB[*]}" probe >"$T/vi.out" 2>&1 \
  || { tail -n 20 "$T/vi.out"; fail "verify_installed.sh failed with the caller's config variables set"; }
snap > "$T/sentinel.after"
cmp -s "$T/sentinel.before" "$T/sentinel.after" || fail "a gate wrote the caller's config: $(diff "$T/sentinel.before" "$T/sentinel.after")"
ok "workflow tests and verify_installed.sh leave the caller's CODEX_HOME and CLAUDE_CONFIG_DIR as they were"
echo "All isolation tests passed"
