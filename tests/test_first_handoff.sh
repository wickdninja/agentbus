#!/bin/bash
# examples/first-handoff without a model: the generated project, the hidden check, the prompts, and the transcript grader that decides a run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
EX="$(cd "$(dirname "$BIN")/.." && pwd)/examples/first-handoff"
[ -f "$EX/scenario.py" ] || fail "examples/first-handoff is missing"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$PY" -I - "$EX" "$T" <<'PY' || fail "first-handoff scenario"
import importlib.util, os, re, subprocess, sys, textwrap
ex, tmp = sys.argv[1:3]
sys.path.insert(0, ex)
sys.dont_write_bytecode = True
import scenario
spec = importlib.util.spec_from_file_location("drive", os.path.join(ex, "drive.py"))
drive = importlib.util.module_from_spec(spec); spec.loader.exec_module(drive)

def project(name):
    dest = os.path.join(tmp, name)
    r = subprocess.run([sys.executable, "-I", os.path.join(ex, "make_project.py"), dest], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.strip() == dest, r
    return dest

def write_parse(dest, source):
    open(os.path.join(dest, "feed", "parse.py"), "w").write(source)

def parser(unit_factor, date_fmt, missing):
    return textwrap.dedent('''\
        import datetime
        def parse_line(line):
            f = line.split("|")
            if len(f) != 4:
                raise ValueError("fields")
            return {"id": f[0], "weight_kg": int(f[1]) * %r,
                    "shipped": datetime.datetime.strptime(f[2], %r).date().isoformat(),
                    "zone": None if f[3] == %r else f[3]}
        ''') % (unit_factor, date_fmt, missing)

# the project holds none of the answers, for any seed, and the stub fails the check
stub = project("stub")
files = {}
for d, _, names in os.walk(stub):
    for n in names:
        files[os.path.relpath(os.path.join(d, n), stub)] = open(os.path.join(d, n)).read()
assert sorted(files) == sorted(scenario.FILES), sorted(files)
distinct = set()
for seed in range(1, 41):
    f = scenario.facts(seed)
    distinct.add((f["weight_unit"], f["date_name"], f["missing"]))
    for rel, text in files.items():
        for s in scenario.secret_strings(f):
            assert not re.search(r"\b%s\b" % re.escape(s), text, re.I), (seed, rel, s)
    bob = scenario.prompt("bob", "agentbus", seed) + scenario.prompt("bob", "ledger", seed)
    for s in (f["weight_unit"], f["date_name"]):
        assert s not in bob, ("bob's prompt holds an answer", seed, s)
        assert s in scenario.prompt("alice", "ledger", seed) and s in scenario.prompt("alice", "agentbus", seed), (seed, s)
    ok, detail = scenario.check(stub, seed)
    assert not ok and detail["error"] and "NotImplementedError" in detail["error"], detail
assert len(distinct) >= 20, len(distinct)

# only the channel sentence differs between conditions
for role in ("alice", "bob"):
    a, b = scenario.prompt(role, "agentbus", 3), scenario.prompt(role, "ledger", 3)
    assert a != b and a.replace("agentbus", "X").count("\n\n") == b.replace("COORDINATION.md", "X").count("\n\n")
    pa, pb = a.split("\n\n"), b.split("\n\n")
    assert [p for p, q in zip(pa, pb) if p != q] == [pa[-2]] and len(pa) == len(pb), role

# the check: the right parser passes; a wrong guess at any one answer fails, and the detail says which part held
for seed in range(1, 21):
    f = scenario.facts(seed)
    good = project("good%d" % seed)
    write_parse(good, parser(f["weight_factor"], f["date_fmt"], f["missing"]))
    ok, detail = scenario.check(good, seed)
    assert ok and detail["weight"] == detail["date"] == detail["zone"] == detail["of"], (seed, detail)
    other_unit = next(factor for _, factor in scenario.WEIGHT_UNITS if factor != f["weight_factor"])
    other_date = next(fmt for _, fmt in scenario.DATE_FORMATS if fmt != f["date_fmt"])
    other_mark = next(m for m in scenario.MISSING_MARKERS if m != f["missing"])
    for label, args, field in (("unit", (other_unit, f["date_fmt"], f["missing"]), "weight"),
                               ("date", (f["weight_factor"], other_date, f["missing"]), "date"),
                               ("marker", (f["weight_factor"], f["date_fmt"], other_mark), "zone")):
        bad = project("bad-%s-%d" % (label, seed))
        write_parse(bad, parser(*args))
        ok, detail = scenario.check(bad, seed)
        assert not ok and detail[field] < detail["of"], (seed, label, detail)
    assert not any(n == "__pycache__" for _, ds, _ in os.walk(good) for n in ds), "the check left bytecode in the project"

# the CLIs: exit codes and the one-line verdict
good = project("cli-good")
f = scenario.facts(7)
write_parse(good, parser(f["weight_factor"], f["date_fmt"], f["missing"]))
r = subprocess.run([sys.executable, "-I", os.path.join(ex, "check.py"), good, "7"], capture_output=True, text=True)
assert r.returncode == 0 and r.stdout.startswith("pass "), r
r = subprocess.run([sys.executable, "-I", os.path.join(ex, "check.py"), good, "8"], capture_output=True, text=True)
assert r.returncode in (0, 1) and r.stdout.split()[0] in ("pass", "fail"), r   # seed 8 may share seed 7's answers; either verdict is honest
r = subprocess.run([sys.executable, "-I", os.path.join(ex, "check.py")], capture_output=True, text=True)
assert r.returncode == 2, r
r = subprocess.run([sys.executable, "-I", os.path.join(ex, "make_project.py"), good], capture_output=True, text=True)
assert r.returncode == 2 and "not empty" in r.stderr, r

# alice's ticket is solvable from her file alone, and bob's visible tests cannot tell a guess from the answer
alice = project("alice")
open(os.path.join(alice, "feed", "report.py"), "w").write(textwrap.dedent('''\
    def format_summary(parcels):
        n = len(parcels)
        return "%d parcel%s, %.2f kg total, %d without a zone" % (n, "" if n == 1 else "s", sum(p["weight_kg"] for p in parcels), sum(1 for p in parcels if p["zone"] is None))
    '''))
env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
r = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_report.py"], cwd=alice, capture_output=True, text=True, env=env)
assert r.returncode == 0, r.stderr
guess = project("guess")
write_parse(guess, parser(0.001, "%d%m%y", "ZZ"))
r = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_parse.py"], cwd=guess, capture_output=True, text=True, env=env)
assert r.returncode == 0, r.stderr

# the transcript grader. Steps are what codex's --json run reports: commands with output, and patches.
def cmd(n, c, out=""): return {"n": n, "t": float(n), "kind": "command", "cmd": c, "out": out, "rc": 0}
def patch(n, path): return {"n": n, "t": float(n), "kind": "patch", "cmd": "patch " + path, "out": "", "paths": [path], "rc": None}
msg = "Weights are whole numbers of tenths of a kilogram. Dates are written as DDMMYY, digits only, no separators. No zone is marked ZZ."
wrapped = "  " + "\n  ".join(textwrap.wrap(msg, 40))      # the CLI wraps and indents; whitespace must not matter
def seq(*steps): return [dict(s, n=i, t=float(i)) for i, s in enumerate(steps)]
read = cmd(0, "agentbus --as bob inbox", "#1 alice -> bob [handoff]\n" + wrapped + "\n")
g = drive.grade_b(seq(cmd(0, "ls"), read, patch(0, "/tmp/x/proj/feed/parse.py")), [msg], ["claude-config"])
assert g["read_step"] == 1 and g["write_step"] == 2 and g["read_before_write"] and not g["side_channel_steps"], g
g = drive.grade_b(seq(cmd(0, "ls"), patch(0, "/tmp/x/proj/feed/parse.py"), read), [msg], [])
assert g["write_step"] == 1 and g["read_step"] == 2 and not g["read_before_write"], g          # wrote first, read after
g = drive.grade_b([cmd(0, "cat docs/spec.md feed/parse.py 2>&1"), cmd(1, "python3 -m unittest 2>&1 | tail -3", "OK"), patch(2, "/p/feed/parse.py")], [msg], [])
assert g["read_step"] is None and g["write_step"] == 2 and not g["read_before_write"], g      # 2>&1 is not a write
g = drive.grade_b(seq(read, cmd(0, "cat > feed/parse.py <<'EOF'\nx\nEOF")), [msg], [])
assert g["write_step"] == 1 and g["read_before_write"], g
# a ledger or bus entry that only NAMES the file is not a write to it (the first live run counted these as writes)
named = "printf '\\\\n%s bob JOIN: implementing feed/parse.py\\\\n' \"$(date +%H:%M:%S)\" >> COORDINATION.md"
g = drive.grade_b(seq(read, cmd(0, named), cmd(0, "agentbus --as bob post 'writing feed/parse.py now' --kind note"), cmd(0, "cat feed/parse.py > /dev/null"), patch(0, "/p/feed/parse.py")), [msg], [])
assert g["write_step"] == 4 and g["read_before_write"], g
for c in ("python3 - <<'PY'\nopen('feed/parse.py', 'w').write('x')\nPY", "python3 -c \"from pathlib import Path; Path('feed/parse.py').write_text('x')\"",
          "tee feed/parse.py <<'EOF'\nx\nEOF", "cp /tmp/new.py feed/parse.py", "apply_patch <<'EOF'\n*** Begin Patch\n*** Update File: feed/parse.py\n*** End Patch\nEOF"):
    assert drive.writes_parse(cmd(0, c)), c
for c in ("cat feed/parse.py", "python3 -m unittest 2>&1 | tail", "git diff -- feed/parse.py", "rg parse_line feed/parse.py tests > /dev/null"):
    assert not drive.writes_parse(cmd(0, c)), c
g = drive.grade_b(seq(cmd(0, "sed -i 's/a/b/' feed/parse.py"), read), [msg], [])
assert g["write_step"] == 0 and not g["read_before_write"], g
g = drive.grade_b([cmd(0, "cat ../claude-config/projects/x.jsonl", msg), patch(1, "/p/feed/parse.py")], [msg], ["claude-config"])
assert g["side_channel_steps"] == [0], g                                                    # reading alice's own transcript is flagged
g = drive.grade_b([cmd(0, "agentbus --as bob inbox", "inbox empty"), patch(1, "/p/feed/parse.py")], [msg], [])
assert g["read_step"] is None, g                                                           # an empty inbox is not a read of her message
assert drive.nospace(" a\n b ") == "ab"
# the ledger parser keeps alice's multi-line entries and drops join and claim lines
os.makedirs(os.path.join(tmp, "led"))
open(os.path.join(tmp, "led", "COORDINATION.md"), "w").write("\n10:00:00 alice JOIN: starting\n\n10:00:09 alice HANDOFF to bob: line one\nline two\n\n10:01:00 bob JOIN: here\n")
texts, entries = drive.alice_texts_ledger(os.path.join(tmp, "led"))
assert texts == ["10:00:09 alice HANDOFF to bob: line one\nline two"] and len(entries) == 3, (texts, entries)
# summaries of the two transcript shapes
c = drive.claude_summary([(0, {"type": "system", "subtype": "hook_response"}),
                          (1, {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]}}),
                          (2, {"type": "result", "subtype": "success", "is_error": False, "num_turns": 4, "total_cost_usd": 0.1,
                               "usage": {"input_tokens": 3, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 7, "output_tokens": 9}})])
assert c == {"commands": 1, "hook_events": 1, "num_turns": 4, "cost_usd": 0.1, "tokens": {"input": 3, "cache_read": 5, "cache_write": 7, "output": 9}, "result_error": None}, c
steps = drive.codex_steps([(1.04, {"type": "item.completed", "item": {"type": "command_execution", "command": "/bin/zsh -lc 'ls'", "aggregated_output": "a\n", "exit_code": 0}}),
                           (2.0, {"type": "item.started", "item": {"type": "file_change", "changes": [{"path": "/p/feed/parse.py", "kind": "update"}]}}),
                           (3.0, {"type": "item.completed", "item": {"type": "file_change", "changes": [{"path": "/p/feed/parse.py", "kind": "update"}]}})])
assert [s["kind"] for s in steps] == ["command", "patch"] and steps[0]["t"] == 1.0 and drive.writes_parse(steps[1]) and not drive.writes_parse(steps[0]), steps
assert drive.codex_tokens([(0, {"type": "turn.completed", "usage": {"input_tokens": 10, "cached_input_tokens": 4, "output_tokens": 2}})]) == {"input": 10, "cached_input": 4, "output": 2}
PY
ok "first-handoff: no answers in the project or in bob's prompt, the check tells right from each wrong guess, the grader orders read and write"
# no em-dash and no personal path in anything the example ships
if grep -rn -e $'\xe2\x80\x94' -e '/Users/' "$EX" >/dev/null; then fail "an em-dash or a personal path in examples/first-handoff"; fi
ok "first-handoff: no em-dash, no personal path"
