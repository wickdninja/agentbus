#!/usr/bin/env bash
# watch v2 golden frames (issue #7): the approved text of every watch state, pinned. The goldens in
# tests/golden/watch/ come from docs/design/watch_v2_mock.py and the fixture beside them; PENDING lists
# the goldens bin/agentbus does not reproduce yet (06 empties it); behaviour.json lists the behaviour
# cases (revision 2), of which the mock runs its own here.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
G="$TESTS_DIR/golden/watch"
[ -f "$G/fixture.json" ] || fail "no fixture: $G/fixture.json"

echo "TEST 1: the fixture parses and names a golden for every file, and a file for every golden"
python3 - "$G" <<'PY' || fail "fixture or golden inventory"
import json, pathlib, sys
g = pathlib.Path(sys.argv[1])
fx = json.load(open(g / "fixture.json", encoding="utf-8"))
s = fx["snapshots"]["sample"]
got = (len(s["agents"]), len(s["claims"]), len(s["context"]), len(s["messages"]))
assert got == (3, 2, 2, 9), f"sample bus is {got}, want 3 agents, 2 claims, 2 facts, 9 messages"
assert s["counts"] == {"agents": 3, "messages": 9, "claims": 2}, s["counts"]
names = []
for e in fx["goldens"]:
    for k in ("name", "cols", "rows", "t_now", "where", "view"):
        assert k in e, (e.get("name"), "lacks", k)
    for k in ("mode", "focus", "sel", "paused", "filter", "error", "stale"):
        assert k in e["view"], (e["name"], "view lacks", k)
    assert e["t_now"].endswith("Z") and not e["where"].startswith("/"), e["name"]
    assert e["name"].split("-emoji")[0].endswith(f"-{e['cols']}x{e['rows']}"), e["name"]
    names.append(e["name"])
assert len(names) == len(set(names)), "duplicate golden names"
files = {p.stem for p in g.glob("*.txt")}
assert set(names) == files, ("entries without a file", sorted(set(names) - files), "files without an entry", sorted(files - set(names)))
print(len(names), "goldens")
PY
ok "the fixture has 3 agents, 2 claims, 2 facts, 9 messages, and every golden file has a fixture entry with t_now, where, cols, rows and view, and every entry has a golden file"

echo "TEST 2: every golden has its declared height, keeps the spare column and is one physical row per line"
python3 - "$G" "$TESTS_DIR" <<'PY' || fail "golden geometry"
import json, pathlib, sys
g, tests = pathlib.Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, tests)
from term_oracle import rows as phys, width
fx = json.load(open(g / "fixture.json", encoding="utf-8"))
for e in fx["goldens"]:
    text = (g / (e["name"] + ".txt")).read_text(encoding="utf-8")
    assert text.endswith("\n"), e["name"]
    lines = text[:-1].split("\n")
    assert len(lines) == e["rows"], (e["name"], len(lines), "rows, want", e["rows"])
    for i, line in enumerate(lines, 1):
        w = sum(width(c) for c in line)
        assert w <= e["cols"], (e["name"], i, w, "wider than", e["cols"])
        assert w <= e["cols"] - 1, (e["name"], i, "uses the last column, which stays free")
        assert len(phys(line, e["cols"])) == 1, (e["name"], i, "wraps")
        assert line == line.rstrip(), (e["name"], i, "trailing space")
        assert not any(ord(c) < 0x20 or 0x7f <= ord(c) < 0xa0 for c in line), (e["name"], i, "control character")
        assert line == "" or line.startswith((" ", ">", "*", "▌", "|", "/", "Agents", "Claims", "Facts", "Messages",
                                              "Thread", "History", "Mentioned in", "Move", "Look closer", "Marks",
                                              "Words", "Kinds", "Roles", "watch needs")) or line[0] in "👥🔒📌💬🧵📜🔗", \
            (e["name"], i, "a row starts with text agentbus did not write", line[:20])
        if e.get("ascii"):
            assert all(ord(c) < 128 for c in line), (e["name"], i, "an ASCII-mode row has a non-ASCII character", line)
PY
ok "every golden frame has its declared height and no row wider than its width; every golden row is one physical row on the terminal oracle; ASCII goldens are pure ASCII"

echo "TEST 3: no em-dash in the goldens, the fixture, the design doc, its addendum or its HTML"
python3 - "$G" "$ROOT" <<'PY' || fail "em-dash"
import pathlib, sys
g, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
paths = [p for p in g.iterdir() if p.is_file()] + [root / "docs/design/watch-v2-build-addendum.md",
                                                     root / "docs/design/watch-v2.md", root / "docs/design/watch-v2.html",
                                                     root / "docs/design/watch_v2_mock.py", root / "scripts/check_frames.py"]
for p in paths:
    assert chr(0x2014) not in p.read_text(encoding="utf-8"), p
PY
ok "goldens contain no em-dash"

echo "TEST 4: the goldens, fixture, doc frames and HTML are exactly what the design mock draws"
python3 "$ROOT/docs/design/watch_v2_mock.py" --check >"$T/mock.out" 2>&1 || { cat "$T/mock.out"; fail "generated design artifacts are out of date (run python3 docs/design/watch_v2_mock.py)"; }
ok "no golden was edited by hand"

echo "TEST 5: PENDING names exactly the goldens bin/agentbus does not reproduce"
HOME="$T/h1" "$PY" "$G/render.py" "$BIN" "$G/fixture.json" >"$T/r1.json" || fail "render adapter failed"
python3 - "$G" "$T/r1.json" <<'PY' || fail "PENDING is wrong"
import json, pathlib, sys
g = pathlib.Path(sys.argv[1])
got = json.load(open(sys.argv[2], encoding="utf-8"))
missing = {n for n, t in got.items() if t is None or t != (g / (n + ".txt")).read_text(encoding="utf-8")}
pending = {l.strip() for l in (g / "PENDING").read_text(encoding="utf-8").splitlines()
           if l.strip() and not l.startswith("#")}
assert pending == missing, ("now reproduced, remove from PENDING", sorted(pending - missing),
                            "not reproduced, add to PENDING", sorted(missing - pending))
print(len(got) - len(missing), "reproduced,", len(missing), "pending")
PY
ok "PENDING names exactly the goldens the current renderer does not reproduce"

echo "TEST 6: a frame depends on the entry's t_now and where, never on HOME or the wall clock"
HOME="$T/h2" "$PY" "$G/render.py" "$BIN" "$G/fixture.json" --shift-clock >"$T/r2.json" || fail "render adapter failed"
cmp -s "$T/r1.json" "$T/r2.json" || fail "rendering changed with HOME and the clock"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(v for v in d.values()), "nothing rendered"' "$T/r1.json" \
  || fail "the determinism check rendered nothing"
ok "rendering a golden twice with HOME and the wall clock changed gives the same bytes"

echo "TEST 7: scripts/check_frames.py passes the design doc and rejects a too-wide and a too-tall frame"
out=$(python3 "$ROOT/scripts/check_frames.py" "$ROOT/docs/design/watch-v2.md") || { echo "$out"; fail "design doc frames"; }
[ "$(tail -1 <<<"$out")" = "all frames within width" ] || fail "check_frames last line: $out"
if python3 "$ROOT/scripts/check_frames.py" "$G/check_frames_bad.md" >"$T/bad.out"; then fail "check_frames passed a bad frame"; fi
grep -q "too-wide row is" "$T/bad.out" && grep -q "too-tall has 3 rows" "$T/bad.out" || { cat "$T/bad.out"; fail "check_frames missed a bad frame"; }
ok "check_frames accepts the design doc and fails a too-wide and a too-tall frame"

echo "TEST 8: the behaviour cases the design mock can run pass (pause rollover, 40x16 selection, kind:ask, busy frame, ...)"
python3 - "$G" <<'PY' || fail "behaviour.json"
import json, pathlib, sys
cases = json.load(open(pathlib.Path(sys.argv[1]) / "behaviour.json", encoding="utf-8"))["cases"]
names = {c["name"] for c in cases}
for want in ("pause-rollover", "selection-never-hidden", "kind-codes", "busy-q-under-250ms"):
    assert want in names, ("behaviour.json lacks the falsifying case", want)
assert all(c["runs"] in ("mock", "06") and c["checks"] for c in cases), "a case without runs or checks"
PY
python3 "$ROOT/docs/design/watch_v2_mock.py" --behaviour >"$T/beh.out" 2>&1 || { cat "$T/beh.out"; fail "a behaviour case failed"; }
tail -1 "$T/beh.out" | grep -q "behaviour cases passed" || { cat "$T/beh.out"; fail "behaviour run did not finish"; }
ok "$(tail -1 "$T/beh.out")"

echo "All watch golden tests passed"
