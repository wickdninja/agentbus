#!/bin/bash
# bash scripts/verify_installed.sh [--allow-skip] [--quick] CMD LABEL
# Proves an INSTALLED agentbus works, not the checkout's source: CMD is the installed command (for example
# `agentbus`, or `/path/to/venv/bin/agentbus`; split on whitespace). Runs from a fresh temp directory
# outside the checkout with PYTHONPATH unset and AGENTBUS_CMD=CMD, so tests/lib.sh and
# tests/agentbus_cmd.py launch CMD and nothing else. On a failure it prints `FAIL step: <name>` and exits 1.
# A step that cannot run (a piece of the tree is missing) prints `SKIP step: ...` and makes the script
# fail, unless --allow-skip says that is expected (a branch that lacks another stream's pieces); the
# success line then names how many were skipped. --quick leaves out the nested test files (a slow part,
# for tests/test_package.sh to stay inside the suite's time slot); CI and releases never use it, and the
# success line says (quick). The last line on success is
# `installed command verified: LABEL`.
set -u
ALLOW=0; QUICK=0
while [ $# -gt 2 ]; do
  case "$1" in --allow-skip) ALLOW=1 ;; --quick) QUICK=1 ;; *) break ;; esac
  shift
done
CMD="${1:?usage: verify_installed.sh CMD LABEL}"; LABEL="${2:?usage: verify_installed.sh CMD LABEL}"
# A bare command name becomes an absolute path first: tests/lib.sh defines a shell function named
# agentbus, which would call itself forever (a segfault) if AGENTBUS_CMD were just `agentbus`.
read -r -a _words <<<"$CMD"
case "${_words[0]}" in
  */*) ;;
  *) _abs=$(type -P "${_words[0]}") || { echo "FAIL: ${_words[0]} is not on PATH"; exit 1; }
     CMD="$_abs ${_words[*]:1}"; CMD="${CMD% }" ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# CODEX_HOME and CLAUDE_CONFIG_DIR too: the setup step and the nested tests run `setup`, which writes there.
unset PYTHONPATH AGENTBUS_DB AGENTBUS_AGENT AGENTBUS_BIN CODEX_HOME CLAUDE_CONFIG_DIR
export AGENTBUS_CMD="$CMD"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T" || exit 1
read -r -a AB <<<"$CMD"
STEP=""
step() { STEP="$1"; }
bad() { echo "FAIL step: $STEP"; [ $# -gt 0 ] && echo "$*"; exit 1; }
good() { echo "ok   $STEP"; }
SKIPPED=0
skip() { echo "SKIP step: $STEP ($1)"; SKIPPED=$((SKIPPED + 1)); }

VERSION=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$ROOT/bin/agentbus")
[ -n "$VERSION" ] || { STEP="read __version__"; bad "no __version__ in $ROOT/bin/agentbus"; }

step "--version equals __version__"
got=$("${AB[@]}" --version 2>&1) || bad "exit $?: $got"
[ "$got" = "agentbus $VERSION" ] || bad "got '$got', wanted 'agentbus $VERSION'"
good

step "--json with a bad command prints a bad_input error and exits 2"
rc=0; err=$("${AB[@]}" --json lgo 2>&1 >/dev/null) || rc=$?
[ "$rc" = 2 ] || bad "exit $rc, wanted 2 (usage)"
grep -q '"code": *"bad_input"' <<<"$err" || bad "stderr was: $err"
good

step "a crash prints an internal JSON error and exits 4"
if grep -q 'AGENTBUS_TEST_CRASH' "$ROOT/bin/agentbus"; then
  rc=0; err=$(AGENTBUS_TEST_CRASH=1 "${AB[@]}" --json status 2>&1 >/dev/null) || rc=$?
  [ "$rc" = 4 ] && grep -q '"code": *"internal"' <<<"$err" || bad "exit $rc (wanted 4), stderr was: $err"
  good
else
  skip "this tree has no AGENTBUS_TEST_CRASH yet"
fi

step "skill prints skills/agentbus/SKILL.md"
"${AB[@]}" skill >"$T/skill.out" 2>"$T/skill.err" || bad "$(cat "$T/skill.err")"
cmp -s "$T/skill.out" "$ROOT/skills/agentbus/SKILL.md" || bad "differs from skills/agentbus/SKILL.md (is the embedded copy current?)"
good

step "examples/two-agent-handoff.sh"
AGENTBUS="$CMD" bash "$ROOT/examples/two-agent-handoff.sh" >"$T/example.out" 2>&1 || { tail -n 20 "$T/example.out"; bad; }
good

for t in test_example test_json test_dx test_workflow_first_run; do
  [ "$QUICK" = 1 ] && { echo "quick tests/$t.sh not run (--quick)"; continue; }
  step "tests/$t.sh through the installed command"
  [ -f "$ROOT/tests/$t.sh" ] || { skip "tests/$t.sh is not in this tree"; continue; }
  bash "$ROOT/tests/$t.sh" >"$T/$t.out" 2>&1 || { tail -n 30 "$T/$t.out"; bad; }
  good
done

step "setup claude and setup codex write the skill and the block"
"${AB[@]}" setup claude >"$T/setup1.out" 2>&1 || { cat "$T/setup1.out"; bad; }
cmp -s "$T/skill.out" "$HOME/.claude/skills/agentbus/SKILL.md" || bad "the installed skill differs from agentbus skill"
"${AB[@]}" setup codex >"$T/setup2.out" 2>&1 || { cat "$T/setup2.out"; bad; }
grep -q '^<!-- agentbus:begin -->$' "$HOME/.codex/AGENTS.md" || bad "no agentbus block in AGENTS.md"
good

if [ "$SKIPPED" -gt 0 ] && [ "$ALLOW" = 0 ]; then
  echo "FAIL: $SKIPPED step(s) were skipped; run with --allow-skip only while the missing pieces are unmerged"
  exit 1
fi
SUFFIX=""
[ "$QUICK" = 1 ] && SUFFIX=" (quick)"
if [ "$SKIPPED" -gt 0 ]; then echo "installed command verified: $LABEL$SUFFIX ($SKIPPED steps skipped)"; else echo "installed command verified: $LABEL$SUFFIX"; fi
