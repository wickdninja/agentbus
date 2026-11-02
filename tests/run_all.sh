#!/bin/bash
# bash tests/run_all.sh [--keep-going] [FILE...]
# Runs tests/test_*.sh in name order (or the given files), each under `timeout 600` where available.
# PYTHON (and AGENTBUS_CMD / AGENTBUS_BIN) pass through to every file. Per file: `PASS tests/test_x.sh (4s)`
# or `FAIL tests/test_x.sh (rc 1)` with the last 40 lines of its output, then it stops (--keep-going
# continues). The last line is `ALL TESTS PASSED (N files)` or `FAILED: tests/test_x.sh ...`; exit 0 or 1.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
keep=0
if [ "${1:-}" = "--keep-going" ]; then keep=1; shift; fi
if [ $# -gt 0 ]; then files=("$@"); else files=(tests/test_*.sh); fi
tmo=()
if command -v timeout >/dev/null 2>&1; then tmo=(timeout 600)
elif command -v gtimeout >/dev/null 2>&1; then tmo=(gtimeout 600); fi
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT
failed=(); rows=(); n=0
for f in "${files[@]}"; do
  n=$((n+1))
  start=$SECONDS
  rc=0
  ${tmo[@]+"${tmo[@]}"} bash "$f" >"$out" 2>&1 </dev/null || rc=$?
  secs=$((SECONDS-start))
  if [ "$rc" = 0 ]; then
    echo "PASS $f (${secs}s)"
  else
    echo "FAIL $f (rc $rc)"
    tail -n 40 "$out"
    failed+=("$f")
  fi
  rows+=("| $f | $([ "$rc" = 0 ] && echo pass || echo "fail ($rc)") | $secs |")
  [ "$rc" = 0 ] || [ "$keep" = 1 ] || break
done
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "| file | result | seconds |"; echo "| --- | --- | --- |"; printf '%s\n' "${rows[@]}"; } >>"$GITHUB_STEP_SUMMARY"
fi
if [ ${#failed[@]} -gt 0 ]; then echo "FAILED: ${failed[*]}"; exit 1; fi
echo "ALL TESTS PASSED ($n files)"
