#!/bin/bash
set -euo pipefail
# The global conformance gate. Every MUST, MUST NOT, SHALL and REQUIRED of docs/protocol.md carries an id (tests/test_docs.sh);
# this file fails when such an id has neither a mutation in tests/mutations.json naming it in "must" nor a line in
# tests/conformance-manual.txt, when an entry or a manual line names an id the spec does not define, when an entry's "run"
# file does not exist, and when an id is in both lists. A test that kills a mutation for the id is what "covered" means:
# the mutations themselves are run by tests/test_mutations.sh and scripts/mutate.py.
# The checker is the embedded script below. The self-tests run it on scratch copies of the spec and the lists, each broken
# one way, so a gate that stopped checking one of the five things fails here (tests/mutations.json guts it five ways).
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ROOT="$TESTS_DIR/.."
SPEC="$ROOT/docs/protocol.md"; MUTS="$TESTS_DIR/mutations.json"; MANUAL="$TESTS_DIR/conformance-manual.txt"

cat > "$T/check.py" <<'PY'
import json, os, re, sys

spec_path, muts_path, manual_path, root = sys.argv[1:5]
KEYWORD = re.compile(r"\b(MUST|SHALL|REQUIRED)\b")        # MUST NOT and SHALL NOT contain these
DEF = re.compile(r"^- \*\*(P-[A-Z]+-[0-9]+)\*\*")

defined, musts = set(), set()
lines = open(spec_path, encoding="utf-8").read().splitlines()
for i, line in enumerate(lines):
    m = DEF.match(line)
    if not m:
        continue
    block = [line]
    for nxt in lines[i + 1:]:
        if not nxt.strip() or nxt.startswith("- ") or nxt.startswith("#"):
            break
        block.append(nxt)
    defined.add(m.group(1))
    if KEYWORD.search(" ".join(block)):
        musts.add(m.group(1))

problems = []
covered = {}
for e in json.load(open(muts_path, encoding="utf-8")):
    for rid in e.get("must", []):
        if rid not in defined:
            problems.append("mutation %r names %s, which docs/protocol.md does not define" % (e["name"], rid))
        covered.setdefault(rid, []).append(e["name"])
    if e.get("must") and not os.path.isfile(os.path.join(root, e["run"])):
        problems.append("mutation %r runs %s, which does not exist" % (e["name"], e["run"]))

manual = {}
for n, raw in enumerate(open(manual_path, encoding="utf-8").read().splitlines(), 1):
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    rid, bar, reason = (x.strip() for x in raw.partition("|"))
    if not bar or not reason:
        problems.append("%s line %d: write `P-AREA-n | the reason it cannot be mutated`" % (os.path.basename(manual_path), n))
    if rid not in defined:
        problems.append("%s line %d names %s, which docs/protocol.md does not define" % (os.path.basename(manual_path), n, rid))
    manual[rid] = reason

for rid in sorted(set(manual) & set(covered)):
    problems.append("%s is in both the manual list and mutation %r: an id is one or the other" % (rid, covered[rid][0]))
for rid in sorted(musts):
    if rid not in covered and rid not in manual:
        problems.append("%s is a MUST with no mutation naming it in \"must\" and no line in the manual list" % rid)

automated = len(musts & set(covered))
manual_n = len(musts & set(manual))
if problems:
    for p in problems:
        print("FAIL: " + p)
    sys.exit(1)
print("conformance: %d MUST ids, %d automated by mutations, %d manual" % (len(musts), automated, manual_n))
PY
check() { "$PY" "$T/check.py" "$@"; }

echo "TEST 1: every MUST of docs/protocol.md is covered by a mutation or listed as manual with a reason"
out=$(check "$SPEC" "$MUTS" "$MANUAL" "$ROOT" 2>&1) || fail "the conformance gate failed on the real spec: $out"
echo "$out"
case "$out" in conformance:*automated*manual) ;; *) fail "the gate printed no count of automated and manual ids: $out" ;; esac
ok "$out"

# scratch COPY: fresh copies of the three files to break
S="$T/s"
scratch() { rm -rf "$S"; mkdir -p "$S"; cp "$SPEC" "$S/protocol.md"; cp "$MUTS" "$S/mutations.json"; cp "$MANUAL" "$S/manual.txt"; }
# broken WHAT: the gate must fail on the scratch copies and say WHAT.
broken() {
  local what=$1 o rc=0
  o=$(check "$S/protocol.md" "$S/mutations.json" "$S/manual.txt" "$ROOT" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "the gate passed with $what"
  case "$o" in *"$2"*) ;; *) fail "the gate failed with $what but did not name $2: $o" ;; esac
}
# edit_muts PYTHON: change the scratch mutation list.
edit_muts() { "$PY" - "$S/mutations.json" "$1" <<'PY'
import json, sys
path, code = sys.argv[1:3]
m = json.load(open(path))
exec(code)
json.dump(m, open(path, "w"))
PY
}

echo "TEST 2: a MUST, MUST NOT, SHALL or REQUIRED id with no mutation and no manual line fails the gate"
for kw in "MUST" "MUST NOT" "SHALL" "SHALL NOT" "REQUIRED"; do
  scratch
  printf '\n- **P-ZZ-1** The fixture %s be covered by something.\n' "$kw" >> "$S/protocol.md"
  broken "an uncovered requirement with $kw" "P-ZZ-1 is a MUST with no mutation"
done
scratch
printf '\n- **P-ZZ-2** The fixture SHOULD be covered by something.\n- **P-ZZ-3** The fixture MAY be\n  covered by something.\n' >> "$S/protocol.md"
check "$S/protocol.md" "$S/mutations.json" "$S/manual.txt" "$ROOT" >/dev/null 2>&1 || fail "a SHOULD or a MAY id failed the gate: only MUST, MUST NOT, SHALL and REQUIRED need cover"
scratch
printf '\n- **P-ZZ-4** The fixture is described over\n  two lines and only the second says it MUST be covered.\n' >> "$S/protocol.md"
broken "an uncovered requirement whose MUST is on a continuation line" "P-ZZ-4 is a MUST with no mutation"
scratch
"$PY" - "$S/mutations.json" "$S/manual.txt" <<'PY'
import json, sys
path, manual = sys.argv[1:3]
m = json.load(open(path))
for e in m:
    if "P-ID-11" in e.get("must", []):
        e["must"] = [x for x in e["must"] if x != "P-ID-11"]
json.dump(m, open(path, "w"))
PY
broken "the mutations of P-ID-11 untagged" "P-ID-11 is a MUST with no mutation"
ok "uncovered ids named, SHOULD and MAY ignored, a continuation line read"

echo "TEST 3: a mutation or a manual line naming an id the spec does not define fails the gate"
scratch
edit_muts 'm[0]["must"] = ["P-NOPE-9"]'
broken "a mutation naming an undefined id" "P-NOPE-9, which docs/protocol.md does not define"
scratch
printf 'P-NOPE-8 | a reason\n' >> "$S/manual.txt"
broken "a manual line naming an undefined id" "P-NOPE-8, which docs/protocol.md does not define"
scratch
printf 'P-ID-11\n' >> "$S/manual.txt"
broken "a manual line with no reason" "write \`P-AREA-n | the reason it cannot be mutated\`"
ok "undefined ids named"

echo "TEST 4: a mutation whose run file does not exist fails the gate"
scratch
edit_muts 'e = [x for x in m if x.get("must")][0]; e["run"] = "tests/test_no_such_file.sh"'
broken "a mutation running a file that is not there" "tests/test_no_such_file.sh, which does not exist"
ok "missing run file named"

echo "TEST 5: an id in both the manual list and a mutation fails the gate"
scratch
printf 'P-ID-11 | listed by mistake\n' >> "$S/manual.txt"
broken "an id in both lists" "P-ID-11 is in both the manual list and mutation"
ok "an id is one or the other"

echo "All conformance gate tests passed"
