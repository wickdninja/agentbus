#!/bin/bash
# bash tests/run_all.sh [--keep-going] [--skip-heavy | --only-heavy] [FILE...]
# Runs tests/test_*.sh in name order (or the given files), each capped at 600 s by tests/run_capped.py (run with
# $PYTHON, default python3; no `timeout` binary needed): a file that outlives the cap has its whole process group
# killed and fails with rc 124. RUN_ALL_TIMEOUT=SECONDS changes the cap; the two heavy files get three times it.
# PYTHON (and AGENTBUS_CMD / AGENTBUS_BIN) pass through to every file.
# Per file: `PASS tests/test_x.sh (4s)`, `FAIL tests/test_x.sh (rc 1)` with the last 40 lines of its output, or
# `SKIP tests/test_x.sh (reason)` when the file exits 77 (it needs something this build does not have). The run
# stops at the first FAIL (--keep-going continues). AGENTBUS_NO_SKIP=1 turns a SKIP into a FAIL (CI sets it); only a known platform skip (skip_platform KEY, KEY in PLATFORM_SKIPS) stays a skip then.
# The last line is `ALL TESTS PASSED (N files)` or `(N files, M skipped)`, or `FAILED: tests/test_x.sh ...`; exit 0 or 1.
#
# Isolation: every file runs with a poisoned caller environment (AGENTBUS_DB, AGENTBUS_AGENT, HOME, CODEX_HOME,
# CLAUDE_CONFIG_DIR, XDG_CACHE_HOME and XDG_STATE_HOME point into a scratch folder, and so does TMPDIR). After each file the scratch folder must hold no bus,
# no ~/.agentbus, no Codex or Claude Code config, no update cache or bus list and nothing in TMPDIR,
# and every file of the checkout (tracked, untracked, ignored) must have the checksum it had before; otherwise that file
# fails with `FAIL tests/test_x.sh (isolation: ...)`.
# --skip-heavy leaves out the two files that run other tests again (mutations, the eval harness); CI runs them once
# in their own job with --only-heavy.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$(pwd)
HEAVY=(tests/test_mutations.sh tests/test_eval_harness.sh)
keep=0; heavy=all
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-going) keep=1 ;;
    --skip-heavy) heavy=skip ;;
    --only-heavy) heavy=only ;;
    --) shift; break ;;
    *) break ;;
  esac
  shift
done
if [ $# -gt 0 ]; then candidates=("$@"); else candidates=(tests/test_*.sh); fi
is_heavy() { local h; for h in "${HEAVY[@]}"; do [ "$1" = "$h" ] && return 0; done; return 1; }
files=()
for f in "${candidates[@]}"; do
  if is_heavy "$f"; then [ "$heavy" = skip ] && continue
  else [ "$heavy" = only ] && continue; fi
  files+=("$f")
done
cap="${RUN_ALL_TIMEOUT:-600}"
case "$cap" in ''|*[!0-9]*) echo "RUN_ALL_TIMEOUT must be a whole number of seconds, not '$cap'"; exit 1 ;; esac
# The cap is always enforced, by our own helper: GitHub's macOS runners have no timeout or gtimeout.
capped=("${PYTHON:-python3}" -I "$ROOT/tests/run_capped.py")
"${capped[@]}" 5 true || { echo "tests/run_capped.py does not run under ${PYTHON:-python3}"; exit 1; }
out=$(mktemp) || exit 1
# A short path (/tmp/ab.XXXXXX/t): sockets (AF_UNIX) and the wrap tests need short temp paths, and a long TMPDIR such as
# macOS's /var/folders/... would eat the budget. test_isolation.sh pins the length.
iso=$(mktemp -d /tmp/ab.XXXXXX 2>/dev/null || mktemp -d) || exit 1
mkdir "$iso/h" "$iso/t"
trap 'rm -rf "$out" "$iso"' EXIT
# PLATFORM_SKIPS: the only skips AGENTBUS_NO_SKIP=1 lets through. A file says `skip_platform KEY "detail"` and its SKIP
# line reads `platform: KEY (detail)`; KEY must be one of these, because only these cannot be fixed by merging a change.
PLATFORM_SKIPS=(not-macos no-sandbox-exec)
platform_skip() {  # 0 when the SKIP reason is exactly `platform: <known key>` with an optional (detail)
  local k
  for k in "${PLATFORM_SKIPS[@]}"; do
    case "$1" in "platform: $k"|"platform: $k ("*")") return 0 ;; esac
  done
  return 1
}
# tree: the checkout's state as a listing with a checksum of every file (tracked, untracked and ignored), so an edit to an
# already modified file shows. Inside its own git work tree the list comes from git; a tree with no .git of its own
# (an sdist, a copy inside another repo) is walked with find. Either way the check cannot turn itself off.
tree() {
  local top
  top=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$ROOT" && pwd -P)" ]; then
    (cd "$ROOT" && git ls-files -z --cached --others | sort -z | xargs -0 cksum 2>/dev/null)
  else
    (cd "$ROOT" && find . -type f -not -path './.git/*' -print0 | sort -z | xargs -0 cksum 2>/dev/null)
  fi
}
# Syntax first: a sourced lib or a test file bash cannot parse fails the run before anything runs. Sourcing a broken
# lib.sh does not stop a test (bash runs the lines before the error and carries on), so the run could pass on nothing.
syntax_bad=()
for f in tests/lib.sh tests/workflow_lib.sh ${files[@]+"${files[@]}"}; do
  [ -f "$f" ] || continue
  if ! err=$(bash -n "$f" 2>&1); then
    echo "FAIL $f (syntax: $(printf '%s' "$err" | head -n 1))"
    syntax_bad+=("$f")
  fi
done
if [ ${#syntax_bad[@]} -gt 0 ]; then echo "FAILED: ${syntax_bad[*]}"; exit 1; fi
failed=(); rows=(); n=0; skipped=0
pre=$(tree)
for f in ${files[@]+"${files[@]}"}; do
  n=$((n+1))
  start=$SECONDS
  rc=0
  # The heavy files run other tests (a baseline and a mutated run per mutation): three times the cap.
  t=("${capped[@]}" "$cap")
  if is_heavy "$f"; then t=("${capped[@]}" "$((cap*3))"); fi
  env AGENTBUS_DB="$iso/caller.db" AGENTBUS_AGENT=caller HOME="$iso/h" TMPDIR="$iso/t" PYTHONDONTWRITEBYTECODE=1 \
    CODEX_HOME="$iso/cx" CLAUDE_CONFIG_DIR="$iso/cc" XDG_CACHE_HOME="$iso/h/.cache" XDG_STATE_HOME="$iso/h/.local/state" \
    "${t[@]}" bash "$f" >"$out" 2>&1 </dev/null || rc=$?
  secs=$((SECONDS-start))
  # Isolation, per file, so the file that leaked is the one named: the poisoned caller environment must come back
  # untouched, TMPDIR empty and the checkout as it was.
  leaks=()
  ls "$iso"/caller.db* >/dev/null 2>&1 && leaks+=("it wrote the caller's AGENTBUS_DB")
  [ ! -e "$iso/h/.agentbus" ] || leaks+=("it wrote the caller's ~/.agentbus")
  [ ! -e "$iso/cx" ] || leaks+=("it wrote the caller's CODEX_HOME")
  [ ! -e "$iso/cc" ] || leaks+=("it wrote the caller's CLAUDE_CONFIG_DIR")
  # agentbus update's release cache and its list of known bus folders, at the XDG paths and at the macOS ones under HOME
  for u in .cache/agentbus .local/state/agentbus "Library/Caches/agentbus" "Library/Application Support/agentbus"; do
    [ ! -e "$iso/h/$u" ] || leaks+=("it wrote the caller's update cache or bus list ($u)")
  done
  left=$(ls -A "$iso/t" | head -n 5 | tr '\n' ' ')
  [ -z "$left" ] || leaks+=("it left files in TMPDIR: ${left% }")
  post=$(tree)
  [ "$post" = "$pre" ] || leaks+=("it changed the checkout: $(diff <(echo "$pre") <(echo "$post") | grep '^[<>]' | awk '{print $NF}' | sort -u | head -n 5 | tr '\n' ' ')")
  pre=$post
  rm -rf "$iso"/caller.db* "$iso/h/.agentbus" "$iso/h/.cache" "$iso/h/.local" "$iso/h/Library" "$iso/cx" "$iso/cc" "$iso/t"
  mkdir "$iso/t"
  result=pass
  if [ ${#leaks[@]} -gt 0 ]; then
    echo "FAIL $f (isolation: $(printf '%s; ' "${leaks[@]}" | sed 's/; $//'))"
    failed+=("$f"); result="fail (isolation)"; rc=1
  elif [ "$rc" = 77 ]; then
    reason=$(grep -a '^SKIP' "$out" | sed 's/^SKIP:* *//' | paste -sd';' - | sed 's/;/; /g')
    bad=""
    if [ "${AGENTBUS_NO_SKIP:-}" = 1 ]; then
      # every SKIP line, not just the first, must be a known platform skip
      while IFS= read -r line; do platform_skip "$line" || bad="$bad${bad:+; }$line"; done < <(grep -a '^SKIP' "$out" | sed 's/^SKIP:* *//')
      [ -n "$bad" ] || [ -n "$reason" ] || bad="no reason given"
    fi
    if [ -n "$bad" ]; then
      echo "FAIL $f (skipped, and AGENTBUS_NO_SKIP=1 allows only known platform skips: $bad)"
      failed+=("$f"); result="fail (skipped)"; rc=1
    else
      echo "SKIP $f (${reason:-no reason given})"
      skipped=$((skipped+1)); result=skip; rc=0
    fi
  elif [ "$rc" = 0 ]; then
    echo "PASS $f (${secs}s)"
  else
    echo "FAIL $f (rc $rc)"
    tail -n 40 "$out"
    failed+=("$f"); result="fail ($rc)"
  fi
  rows+=("| $f | $result | $secs |")
  [ "$rc" = 0 ] || [ "$keep" = 1 ] || break
done
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "| file | result | seconds |"; echo "| --- | --- | --- |"; printf '%s\n' ${rows[@]+"${rows[@]}"}; } >>"$GITHUB_STEP_SUMMARY"
fi
if [ ${#failed[@]} -gt 0 ]; then echo "FAILED: ${failed[*]}"; exit 1; fi
if [ "$skipped" -gt 0 ]; then echo "ALL TESTS PASSED ($n files, $skipped skipped)"; else echo "ALL TESTS PASSED ($n files)"; fi
