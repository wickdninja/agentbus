#!/bin/bash
set -euo pipefail
# Mutation checks: every entry in tests/mutations.json breaks one behaviour of bin/agentbus on
# purpose (scripts/mutate.py) and the named test file must fail against the broken copy. Also checks
# the harness itself: a stale pattern fails loudly, a mutation that survives fails the run, a test
# that is not there yet is skipped with a printed line, and a harmless change survives a real test
# (so a kill means the behaviour broke, not the shadow tree). Ends: All mutations killed (N).
. "$(dirname "$0")/lib.sh"
ROOT="$TESTS_DIR/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
M="$PY $ROOT/scripts/mutate.py"
VER=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$ROOT/bin/agentbus")   # the line most entries below mutate
[ -n "$VER" ] || fail "no __version__ line in bin/agentbus"
# Test files the harness runs. Each passes on the real bin/agentbus; ones that "see the mutation" fail when the copy
# they are handed carries the marker (so a kill proves AGENTBUS_BIN is the mutated copy).
printf '#!/bin/bash\nexit 0\n' > "$T/passes.sh"
printf '#!/bin/bash\nif grep -q MUTATION-MARKER "$AGENTBUS_BIN"; then echo "FAIL: marker seen"; exit 1; fi\n' > "$T/marker.sh"
printf '#!/bin/bash\nif grep -q MUTATION-MARKER "$AGENTBUS_BIN"; then echo "FAIL: marker seen"; exit 1; fi\n' > "$T/other.sh"
printf '#!/bin/bash\nif grep -q MUTATION-MARKER "$AGENTBUS_BIN"; then exit 127; fi\n' > "$T/nofail.sh"
printf '#!/bin/bash\nif grep -q MUTATION-MARKER "$AGENTBUS_BIN"; then sleep 30; fi\n' > "$T/slow.sh"
printf '#!/bin/bash\necho "FAIL: always"; exit 1\n' > "$T/broken.sh"
printf '#!/bin/bash\necho "SKIP: needs a thing"; exit 77\n' > "$T/skips.sh"   # skip-ok: throwaway test file
# entry NAME RUN FIND COUNT EXPECT [REPLACE]: a one-entry mutations file at $T/m.json.
entry() {
  "$PY" - "$T/m.json" "$1" "$2" "$3" "$4" "$5" "${6:-__version__ = \"$VER\"  # MUTATION-MARKER}" <<'PY'
import json, sys
path, name, run, find, count, expect, replace = sys.argv[1:8]
json.dump([{"name": name, "file": "bin/agentbus", "find": find, "replace": replace, "count": int(count), "run": run, "expect": expect}], open(path, "w"))
PY
}
F="^__version__ = \"$VER\"\$"
status() { local rc=0; MUTATE_TIMEOUT="${MUTATE_TIMEOUT:-60}" $M --mutations "$T/m.json" "$1" >"$T/out" 2>&1 || rc=$?; echo "$rc"; }

echo "TEST 1: a test that passes unmutated and fails on the broken copy, for the stated reason, kills the mutation"
entry "kill" "$T/marker.sh" "$F" 1 "marker seen"
[ "$(status kill)" = 0 ] && grep -q '^KILLED kill: .*FAIL: marker seen' "$T/out" || fail "a failing test did not kill: $(cat "$T/out")"
ok "killed, and AGENTBUS_BIN names the mutated copy"

echo "TEST 2: a mutation that survives fails the run"
entry "survive" "$T/passes.sh" "$F" 1 "x"
[ "$(status survive)" = 1 ] && grep -q '^SURVIVED survive' "$T/out" || fail "a passing test was not reported as a survivor: $(cat "$T/out")"
ok "survivor exits 1"

echo "TEST 3: a test that fails for another reason, crashes, or times out is not a kill"
entry "wrong" "$T/other.sh" "$F" 1 "a different reason"
[ "$(status wrong)" = 1 ] && grep -q '^WRONG wrong: .*failed for another reason' "$T/out" || fail "wrong reason counted as a kill: $(cat "$T/out")"
entry "crash" "$T/nofail.sh" "$F" 1 "x"
[ "$(status crash)" = 2 ] && grep -q '^CRASHED crash: .*exited 127 with no FAIL line' "$T/out" || fail "a crash (exit 127, no FAIL line) counted as a kill: $(cat "$T/out")"
entry "slow" "$T/slow.sh" "$F" 1 "x"
[ "$(MUTATE_TIMEOUT=2 status slow)" = 1 ] && grep -q '^TIMEOUT slow: ' "$T/out" && ! grep -q '^KILLED' "$T/out" || fail "a timeout counted as a kill: $(cat "$T/out")"
ok "WRONG, CRASHED and TIMEOUT are their own statuses and not kills"

echo "TEST 4: a test that fails before any mutation is BROKEN, never a kill (a missing interpreter looks like a kill otherwise)"
entry "broken" "$T/broken.sh" "$F" 1 "always"
[ "$(status broken)" = 2 ] && grep -q '^BROKEN broken: .*fails before any mutation' "$T/out" || fail "a baseline failure counted as a kill: $(cat "$T/out")"
entry "noint" "tests/test_init.sh" "$F" 1 "init failed" "__version__ = \"$VER\"  # a comment"
rc=0; PYTHON=/nonexistent/python3 $M --mutations "$T/m.json" noint >"$T/out" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q '^BROKEN noint' "$T/out" && ! grep -q '^KILLED' "$T/out" || fail "a comment-only mutation under a missing interpreter was a kill (rc $rc): $(cat "$T/out")"
entry "skips" "$T/skips.sh" "$F" 1 "x"
[ "$(status skips)" = 2 ] && grep -q '^SKIP skips: .*skips unmutated (needs a thing)' "$T/out" && grep -q 'nothing ran' "$T/out" || fail "a skipping baseline was not reported: $(cat "$T/out")"
ok "broken and skipped baselines handled"

echo "TEST 5: a mutation whose pattern no longer matches fails the run instead of passing silently"
entry "stale-none" "$T/marker.sh" '^this line does not exist$' 1 "x"
[ "$(status stale-none)" = 2 ] && grep -q '^STALE stale-none: pattern matched 0 times' "$T/out" || fail "no match was not stale: $(cat "$T/out")"
entry "stale-count" "$T/marker.sh" "$F" 2 "x"
[ "$(status stale-count)" = 2 ] && grep -q '^STALE stale-count: pattern matched 1 times' "$T/out" || fail "wrong count was not stale: $(cat "$T/out")"
entry "stale-same" "$T/marker.sh" "$F" 1 "x" "__version__ = \"$VER\""
[ "$(status stale-same)" = 2 ] && grep -q '^STALE stale-same: the replacement changes nothing' "$T/out" || fail "a no-op replacement was not stale: $(cat "$T/out")"
entry "stale-regex" "$T/marker.sh" '(' 1 "x"
[ "$(status stale-regex)" = 2 ] || fail "a bad regex was not stale"
ok "stale mutations exit 2"

echo "TEST 5b: an entry with an empty expect is refused (it would accept any failure as a kill)"
entry "no-expect" "$T/marker.sh" "$F" 1 " "
[ "$(status no-expect)" = 2 ] && grep -q 'has an empty expect' "$T/out" || fail "an empty expect was accepted: $(cat "$T/out")"
ok "empty expect refused"

echo "TEST 6: an unknown name is a usage error; a test file that does not exist yet is skipped with a line"
entry "known" "$T/marker.sh" "$F" 1 "x"
[ "$(status nope)" = 2 ] || fail "unknown name did not exit 2"
entry "later" "$T/does-not-exist.sh" "$F" 1 "x"
"$PY" - "$T/m.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[0]["after"] = "ws99"; json.dump(d, open(sys.argv[1], "w"))
PY
[ "$(status later)" = 2 ] && grep -q "^SKIP later: .*does-not-exist.sh does not exist yet (after ws99)" "$T/out" && grep -q 'nothing ran' "$T/out" || fail "a missing test file was not skipped and reported: $(cat "$T/out")"
ok "unknown name and not-yet-existing test handled"

echo "TEST 7: a harmless change survives a real test (the shadow tree runs the real suite)"
"$PY" - "$T/m.json" "$F" "$VER" <<'PY'
import json, sys
json.dump([{"name": "harmless", "file": "bin/agentbus", "find": sys.argv[2], "replace": '__version__ = "%s"  # harmless' % sys.argv[3], "count": 1, "run": "tests/test_init.sh", "expect": "x"}], open(sys.argv[1], "w"))
PY
[ "$(status harmless)" = 1 ] && grep -q '^SURVIVED harmless' "$T/out" || fail "a harmless change did not survive tests/test_init.sh: $(cat "$T/out")"
ok "tests/test_init.sh passes on a copy with a comment added"

echo "TEST 7a: a test file that only fails while another runs beside it is run again alone before it is BROKEN, and a file that always fails still is"
LOCK="$T/lockdir"
for n in 1 2; do
  printf '#!/bin/bash\nif grep -q MUTATION-MARKER "$AGENTBUS_BIN"; then echo "FAIL: marker seen"; exit 1; fi\nmkdir "%s" 2>/dev/null || { echo "FAIL: contended"; exit 1; }\nsleep 3; rmdir "%s"\n' "$LOCK" "$LOCK" >"$T/contend$n.sh"
done
"$PY" - "$T/m3.json" "$T/contend1.sh" "$T/contend2.sh" "$F" "$VER" <<'PY'
import json, sys
path, c1, c2, find, ver = sys.argv[1:6]
rep = '__version__ = "%s"  # MUTATION-MARKER' % ver
json.dump([{"name": "contend-one", "file": "bin/agentbus", "find": find, "replace": rep, "count": 1, "run": c1, "expect": "marker seen"},
           {"name": "contend-two", "file": "bin/agentbus", "find": find, "replace": rep, "count": 1, "run": c2, "expect": "marker seen"}], open(path, "w"))
PY
rc=0; MUTATE_TIMEOUT=60 $M --mutations "$T/m3.json" -j 2 --all >"$T/contend.out" 2>"$T/contend.err" || rc=$?
[ "$rc" = 0 ] && grep -q '^KILLED contend-one' "$T/contend.out" && grep -q '^KILLED contend-two' "$T/contend.out" || fail "a baseline starved by a file beside it made its entries BROKEN (rc $rc): $(cat "$T/contend.out")"
grep -q '^NOTE .*contend[12].sh: failed beside other files .*contended.*; run alone: ok' "$T/contend.err" || fail "the re-run alone was not reported: $(cat "$T/contend.err")"
entry "still-broken" "$T/broken.sh" "$F" 1 "always"
rc=0; MUTATE_TIMEOUT=60 $M --mutations "$T/m.json" -j 2 --all >"$T/out" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q '^BROKEN still-broken: .*fails before any mutation' "$T/out" || fail "a file that always fails was not BROKEN after its re-run (rc $rc): $(cat "$T/out")"
ok "contention is retried alone; a real failure stays BROKEN"

echo "TEST 7b: two mutations run at once with -j 2 and still print in file order, one killed and one survived"
# The first entry's test sleeps before it fails, so it finishes after the second: the lines must stay in file order.
printf '#!/bin/bash\nif grep -q MUTATION-MARKER "$AGENTBUS_BIN"; then sleep 3; echo "FAIL: marker seen"; exit 1; fi\n' > "$T/slowkill.sh"
"$PY" - "$T/m2.json" "$T/slowkill.sh" "$T/passes.sh" "$F" "$VER" <<'PY'
import json, sys
path, slow, fast, find, ver = sys.argv[1:6]
rep = '__version__ = "%s"  # MUTATION-MARKER' % ver
json.dump([{"name": "first-killed", "file": "bin/agentbus", "find": find, "replace": rep, "count": 1, "run": slow, "expect": "marker seen"},
           {"name": "second-survives", "file": "bin/agentbus", "find": find, "replace": rep, "count": 1, "run": fast, "expect": "x"}], open(path, "w"))
PY
rc=0; MUTATE_TIMEOUT=60 AGENTBUS_MUTATION_JOBS=1 $M --mutations "$T/m2.json" -j 2 --all >"$T/par.out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "-j 2 with a survivor did not exit 1 (rc $rc): $(cat "$T/par.out")"
[ "$(cut -d: -f1 "$T/par.out" | head -n 2 | tr '\n' ' ')" = "KILLED first-killed SURVIVED second-survives " ] || fail "-j 2 lines are not in file order with their verdicts: $(cat "$T/par.out")"
[ "$(tail -n 1 "$T/par.out")" = "1 killed, 1 survived, 0 wrong reason, 0 timed out, 0 crashed, 0 stale, 0 broken, 0 skipped" ] || fail "the -j 2 summary line changed: $(cat "$T/par.out")"
rc=0; $M --mutations "$T/m2.json" -j 0 --all >"$T/par.out" 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "-j 0 was accepted"
rc=0; AGENTBUS_MUTATION_JOBS=abc $M --mutations "$T/m2.json" --all >"$T/par.out" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q 'AGENTBUS_MUTATION_JOBS must be' "$T/par.out" || fail "a bad AGENTBUS_MUTATION_JOBS was accepted: $(cat "$T/par.out")"
ok "-j 2: file order, same summary line; bad job counts refused"

echo "TEST 7c: every test the harness runs, baseline and mutated, starts outside the checkout"
# A checkout sits under a folder that may hold a real bus; a command a test runs before its own cd would find it.
CHK=$(cd "$ROOT" && pwd -P)
printf '#!/bin/bash\ncase "$(pwd -P)" in "%s"|"%s"/*) echo "FAIL: cwd is under the checkout: $(pwd -P)"; exit 1;; esac\nif grep -q MUTATION-MARKER "$AGENTBUS_BIN"; then echo "FAIL: marker seen"; exit 1; fi\n' "$CHK" "$CHK" > "$T/cwd.sh"
entry "cwd" "$T/cwd.sh" "$F" 1 "marker seen"
[ "$(status cwd)" = 0 ] && grep -q '^KILLED cwd: .*FAIL: marker seen' "$T/out" || fail "a baseline or mutated run started under the checkout: $(cat "$T/out")"
ok "baseline and mutated runs both start outside the checkout"

echo "TEST 7d: --shard I/N: disjoint shards, together every entry, the file's order inside each, only the baselines a shard needs"
"$PY" - "$T" "$ROOT" "$M" <<'PY' || fail "shard"
import json, subprocess, sys
T, root, mutate = sys.argv[1], sys.argv[2], sys.argv[3].split()
def entry(name, run):
    return {"name": name, "file": "bin/agentbus", "find": "x", "replace": "y", "count": 1, "run": run, "expect": "x"}
# nine entries over five test files of different sizes, interleaved so the file order is not the group order
plan = [("a1", "t/a"), ("b1", "t/b"), ("a2", "t/a"), ("c1", "t/c"), ("a3", "t/a"), ("d1", "t/d"), ("b2", "t/b"), ("a4", "t/a"), ("e1", "t/e")]
json.dump([entry(*x) for x in plan], open(T + "/shards.json", "w"))
def names(mfile, *extra):
    r = subprocess.run(mutate + ["--mutations", mfile, "--list"] + list(extra), capture_output=True, text=True)
    assert r.returncode == 0, r
    return r.stdout.splitlines()
everything = names(T + "/shards.json")
assert everything == [x[0] for x in plan], everything
for mfile, whole in ((T + "/shards.json", everything), (root + "/tests/mutations.json", names(root + "/tests/mutations.json"))):
    for n in (1, 2, 3, 4, 5, 6, 9, 12):
        parts = [names(mfile, "--shard", "%d/%d" % (i, n)) for i in range(1, n + 1)]
        flat = [x for part in parts for x in part]
        assert len(flat) == len(set(flat)), ("a shard overlaps another", n)
        assert sorted(flat) == sorted(whole), ("the shards miss or add an entry", n)
        for part in parts:
            assert part == [x for x in whole if x in set(part)], ("a shard is out of file order", n, part)
        again = [names(mfile, "--shard", "%d/%d" % (i, n)) for i in range(1, n + 1)]
        assert again == parts, ("the split is not deterministic", n)
# whole files stay together
by = {}
for n_, run in plan:
    by[n_] = run
for i in range(1, 4):
    runs = [by[x] for x in names(T + "/shards.json", "--shard", "%d/3" % i)]
    for other in range(1, 4):
        if other != i:
            assert not set(runs) & {by[x] for x in names(T + "/shards.json", "--shard", "%d/3" % other)}, "a test file is split over two shards"
for bad in ("0/3", "4/3", "1/0", "x", "1", "1/", "/3", "-1/3", "1/3/5"):
    r = subprocess.run(mutate + ["--mutations", T + "/shards.json", "--list", "--shard", bad], capture_output=True, text=True)
    assert r.returncode == 2 and "--shard needs I/N" in r.stderr, (bad, r)
r = subprocess.run(mutate + ["--mutations", T + "/shards.json", "a1", "--shard", "1/2"], capture_output=True, text=True)
assert r.returncode == 2 and "goes with --all or --list" in r.stderr, r
PY
# A shard runs only its own test files, once each: two files that each log their runs, one entry apiece.
for x in one two; do printf '#!/bin/bash\necho %s >> "%s/runs.log"\nif grep -q MUTATION-MARKER "$AGENTBUS_BIN"; then echo "FAIL: marker seen"; exit 1; fi\n' "$x" "$T" > "$T/$x.sh"; done
"$PY" - "$T" "$F" "$VER" <<'PY'
import json, sys
T, find, ver = sys.argv[1:4]
rep = '__version__ = "%s"  # MUTATION-MARKER' % ver
json.dump([{"name": n, "file": "bin/agentbus", "find": find, "replace": rep, "count": 1, "run": T + "/" + n + ".sh", "expect": "marker seen"} for n in ("one", "two")], open(T + "/m4.json", "w"))
PY
for i in 1 2; do
  : > "$T/runs.log"; rc=0; MUTATE_TIMEOUT=60 $M --mutations "$T/m4.json" --all --shard "$i/2" >"$T/sh.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] && grep -q '^1 killed, 0 survived' "$T/sh.out" || fail "shard $i/2 did not kill its one entry: $(cat "$T/sh.out")"
  [ "$(sort "$T/runs.log" | uniq -c | wc -l | tr -d ' ')" = 1 ] && [ "$(wc -l < "$T/runs.log" | tr -d ' ')" = 2 ] || fail "shard $i/2 ran a test file it does not own, or more than a baseline and a mutated run: $(cat "$T/runs.log")"
done
ok "shards are disjoint, complete, in file order, deterministic, keep a test file whole, and run only their own baselines"

echo "TEST 8: every mutation in tests/mutations.json is killed${AGENTBUS_MUTATION_SHARD:+ (shard $AGENTBUS_MUTATION_SHARD)}"
# AGENTBUS_MUTATION_SHARD=I/N runs one shard of the entries (CI); without it every entry runs.
rc=0; MUTATE_TIMEOUT=400 $M --all ${AGENTBUS_MUTATION_SHARD:+--shard "$AGENTBUS_MUTATION_SHARD"} >"$T/all.out" 2>&1 || rc=$?
cat "$T/all.out"
[ "$rc" = 0 ] || fail "a mutation survived, was killed for another reason, crashed, timed out or went stale (exit $rc)"
n=$(grep -c '^KILLED ' "$T/all.out")
[ "$n" -ge 1 ] || fail "no mutation ran"
[ "$(grep -c '^SURVIVED \|^STALE \|^WRONG \|^CRASHED \|^TIMEOUT \|^BROKEN ' "$T/all.out")" = 0 ] || fail "a mutation was not a clean kill"
# A skipped entry is an untested mutation: say so, and let run_all count this file as skipped.
while IFS= read -r line; do skip_part "${line#SKIP }"; done < <(grep '^SKIP ' "$T/all.out")
all_passed "All mutations killed ($n)"
