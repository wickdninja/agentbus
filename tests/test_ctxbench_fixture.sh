#!/usr/bin/env bash
# ctxbench Stage 1 (docs/evals/ctxbench-protocol.md): every registered procedure, adapter, parser, generator rule, time
# check and report function in scripts/ctxbench/registered.py against hand-derived fixtures, and the committed data
# files against the hashes the protocol registers. No study numbers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
ROOT="$TESTS_DIR/.."

echo "TEST 1: fixtures F1 to F6, CAP, GEN, TIME, PARITY, REPORT, four arms"
o=$("$PY" "$ROOT/scripts/ctxbench/fixture_sufficiency.py" --cli "${AB[*]}" 2>&1) || { printf '%s\n' "$o"; fail "fixture_sufficiency.py failed"; }
printf '%s\n' "$o"
grep -qx "ctxbench sufficiency fixture: all checks passed" <<<"$o" || fail "the fixture did not finish"
ok "every registered procedure and parser derives its fixture answers from its own text"

echo "TEST 2: the data files are the registered ones"
"$PY" "$ROOT/scripts/ctxbench/gen_corpus.py" --check || fail "data/corpus.txt is not gen_corpus.py's output"
"$PY" - "$ROOT" <<'PY' || fail "a data file's sha256 differs from docs/evals/ctxbench-protocol.md"
import hashlib, re, sys
root = sys.argv[1]
doc = open(f"{root}/docs/evals/ctxbench-protocol.md").read()
rows = re.findall(r"^\| `(scripts/ctxbench/[^`]+)` \| `([0-9a-f]{64})` \|$", doc, re.M)
assert len(rows) == 4, rows
for path, want in rows:
    got = hashlib.sha256(open(f"{root}/{path}", "rb").read()).hexdigest()
    assert got == want, f"{path}: {got} != {want}"
PY
ok "corpus regenerates byte for byte; every registered hash matches"

echo "All ctxbench fixture tests passed"
