#!/usr/bin/env bash
# The CLI's discoverable surface, pinned byte for byte: `--help`, every `<cmd> --help` (hidden commands and
# subcommands too), `schema --json`, the bash, zsh and fish completion scripts, the command list in the order the
# parser registers it, and the final CONTRACT table. The goldens are tests/golden/cli/; any byte change fails with a diff.
# A deliberate change: `bash tests/test_cli_surface.sh --update` rewrites the goldens (under Python 3.9 to 3.11, then
# again under 3.12 or later, see below), then review `git diff`.
# The version is written as @VERSION@, so a release bump changes no golden.
# Captures run with no COLUMNS (help lays out at its 80-column default), a throwaway HOME and cwd, and no update
# check, so nothing about the caller's terminal or machine reaches the bytes.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
G="$TESTS_DIR/golden/cli"
update=0
case "${1:-}" in
  --update) update=1 ;;
  "") ;;
  *) echo "usage: bash tests/test_cli_surface.sh [--update]"; exit 2 ;;
esac
MOD="${AGENTBUS_BIN:-$BIN}"
mkdir -p "$T/h" "$T/cwd" "$T/out"

# cli ARGS...: the CLI's stdout, run the same way every time. Fails on a non-zero exit or any stderr.
cli() {
  local err="$T/err" rc=0
  (cd "$T/cwd" && env -u COLUMNS -u LINES HOME="$T/h" PYTHONIOENCODING=utf-8 AGENTBUS_NO_UPDATE_CHECK=1 \
    AGENTBUS_NO_UPDATE_NOTICE=1 "${AB[@]}" "$@") 2>"$err" || rc=$?
  [ "$rc" = 0 ] || fail "agentbus $* exited $rc: $(head -c 400 "$err")"
  [ ! -s "$err" ] || fail "agentbus $* wrote to stderr: $(head -c 400 "$err")"
}

echo "TEST 1: capture the surface"
version=$(cli --version) || exit 1
version=${version#agentbus }
case "$version" in [0-9]*.[0-9]*) ;; *) fail "unexpected --version output: $version" ;; esac
# Every command the parser knows, hidden ones included, as space-separated words in registration order.
"$PY" - "$MOD" >"$T/out/commands.txt" <<'PY' || fail "could not walk the parser in $MOD"
import argparse, runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_cli_surface")
def walk(parser, path):
    sp = next((x for x in parser._actions if isinstance(x, argparse._SubParsersAction)), None)
    for name, child in (sp.choices.items() if sp else ()):
        print(" ".join(path + [name]))
        walk(child, path + [name])
walk(m["build_parser"](), [])
PY
[ -s "$T/out/commands.txt" ] || fail "the parser walk found no commands"
# The final CONTRACT after every import-time addition, key order kept: a registration moved earlier changes it.
"$PY" - "$MOD" >"$T/out/contract.json" <<'PY' || fail "could not dump CONTRACT from $MOD"
import json, runpy, sys
print(json.dumps(runpy.run_path(sys.argv[1], run_name="agentbus_cli_surface")["CONTRACT"], indent=1, ensure_ascii=False))
PY
cli --help >"$T/out/help.txt"
while IFS= read -r words; do
  read -r -a w <<<"$words"
  cli "${w[@]}" --help >"$T/out/help-$(printf '%s' "$words" | tr ' ' '-').txt"
done <"$T/out/commands.txt"
cli schema --json >"$T/out/schema.json"
for s in bash zsh fish; do cli completion "$s" >"$T/out/completion-$s.txt"; done
# The version, wherever it shows, as @VERSION@ (written with python: sed -i differs between BSD and GNU).
"$PY" - "$T/out" "$version" <<'PY'
import pathlib, sys
for p in pathlib.Path(sys.argv[1]).iterdir():
    b = p.read_bytes()
    p.write_bytes(b.replace(sys.argv[2].encode(), b"@VERSION@"))
PY
n=$(ls "$T/out" | wc -l | tr -d ' ')
ok "captured $n files ($(wc -l <"$T/out/commands.txt" | tr -d ' ') commands)"

# Python 3.12 changed what argparse reports for some positionals, so schema.json differs from 3.12 on. The
# goldens in tests/golden/cli/ are those of Python 3.9 to 3.11; tests/golden/cli/py3.12/ holds only the files whose
# bytes differ on 3.12 and later. --update writes the set for the Python it runs under: run it on both sides.
O="$G/py3.12"
new_py=0; "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' && new_py=1

if [ "$update" = 1 ]; then
  mkdir -p "$G"
  if [ "$new_py" = 0 ]; then
    find "$G" -maxdepth 1 -type f -delete
    cp "$T/out"/* "$G"/
    echo "wrote $n goldens to tests/golden/cli/. Now run it under Python 3.12 or later, then review: git diff --stat -- tests/golden/cli"
  else
    [ -f "$G/help.txt" ] || fail "no base goldens: run --update under Python 3.9 to 3.11 first"
    rm -rf "$O"; mkdir "$O"
    for f in "$T/out"/*; do cmp -s "$f" "$G/$(basename "$f")" || cp "$f" "$O/"; done
    rmdir "$O" 2>/dev/null || true  # nothing differs: leave no empty directory behind
    echo "wrote $(ls "$O" 2>/dev/null | wc -l | tr -d ' ') goldens that differ on Python 3.12+ to tests/golden/cli/py3.12/. Review: git diff --stat -- tests/golden/cli"
  fi
  exit 0
fi

echo "TEST 2: every file is byte-equal to its golden, and no golden is missing or extra"
[ -f "$G/help.txt" ] || fail "no goldens in tests/golden/cli/. Run: bash tests/test_cli_surface.sh --update"
mkdir "$T/want"
find "$G" -maxdepth 1 -type f -exec cp {} "$T/want/" \;
if [ "$new_py" = 1 ] && [ -d "$O" ]; then find "$O" -maxdepth 1 -type f -exec cp {} "$T/want/" \;; fi
if ! diff -rq "$T/want" "$T/out" >"$T/changed" 2>&1; then
  sed -e "s#$T/out#now#g" -e "s#$T/want#golden#g" "$T/changed" | head -n 20
  # schema.json is one line: show its difference as indented JSON, the rest as it is.
  if ! cmp -s "$T/want/schema.json" "$T/out/schema.json"; then
    diff <("$PY" -m json.tool "$T/want/schema.json" 2>&1) <("$PY" -m json.tool "$T/out/schema.json" 2>&1) | head -n 30 | cut -c 1-160 || true
  fi
  diff -r -x schema.json "$T/want" "$T/out" 2>&1 | head -n 40 | cut -c 1-160 || true
  fail "the CLI surface changed (above: < golden, > now). If the change is meant: bash tests/test_cli_surface.sh --update, then review git diff"
fi
ok "$n files byte-equal to the goldens$([ "$new_py" = 1 ] && echo ' (with the Python 3.12+ set)')"

echo "TEST 3: the check fails on a one-byte change and on a missing file (negative control)"
cp -R "$T/out" "$T/bad"
printf ' ' >>"$T/bad/help.txt"
if diff -rq "$T/want" "$T/bad" >/dev/null 2>&1; then fail "a one-byte change to help.txt went unnoticed"; fi
rm "$T/bad/schema.json"
if diff -rq "$T/want" "$T/bad" >/dev/null 2>&1; then fail "a missing golden went unnoticed"; fi
ok "a changed byte and a missing file both fail"

all_passed "All CLI surface tests passed"
