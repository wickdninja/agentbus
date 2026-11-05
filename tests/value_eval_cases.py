"""Unit cases for the value eval, run by tests/test_value_eval.sh: each grader and analysis step on fixtures it must pass and
fixtures it must fail. No model, no agent. Run with the scripts folder as argv[1]."""
import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import analyze  # noqa: E402
import grade  # noqa: E402
import tasks  # noqa: E402

checks = 0


def check(cond, what):
    global checks
    checks += 1
    if not cond:
        print("FAIL:", what)
        sys.exit(1)


def tree(d, files):
    for rel, text in files.items():
        path = os.path.join(d, rel)
        if text is None:
            if os.path.exists(path):
                os.remove(path)
            continue
        os.makedirs(os.path.dirname(path) or d, exist_ok=True)
        with open(path, "w") as f:
            f.write(text)


def solved(task, seed, *extra):
    d = tempfile.mkdtemp()
    t = tasks.build(task, seed)
    tree(d, t.files)
    for files in extra:
        tree(d, files)
    return d, grade.run_hidden(d, task, seed)


def test_hidden_both_ways():
    for task in tasks.TASKS:
        for seed in (1, 2, 3):
            d, base = solved(task, seed)
            shutil.rmtree(d)
            check(not any(base.values()), "%s seed %d: a hidden test passes on the unsolved repo: %s" % (task, seed, base))
            d, ref = solved(task, seed, tasks.reference(task, seed))
            shutil.rmtree(d)
            check(set(ref) == set(tasks.build(task, seed).features), "%s: hidden tests and features differ: %s" % (task, sorted(ref)))
            check(all(ref.values()), "%s seed %d: the reference fails: %s" % (task, seed, ref))
            for name, (change, must_fail) in tasks.mutants(task, seed).items():
                d, got = solved(task, seed, tasks.reference(task, seed), change)
                shutil.rmtree(d)
                for f in must_fail:
                    check(not got[f], "%s seed %d: mutant %s passes %s" % (task, seed, name, f))


def test_seeds():
    for task in tasks.TASKS:
        a, b = tasks.build(task, 7), tasks.build(task, 7)
        check(a.files == b.files and a.tickets == b.tickets, "%s: one seed gave two repos" % task)
        check(tasks.hidden_tests(task, 7) == tasks.hidden_tests(task, 7), "%s: one seed gave two hidden suites" % task)
        check(any(tasks.build(task, s).files != a.files or tasks.build(task, s).tickets != a.tickets for s in (8, 9, 10)), "%s: the seed changes nothing" % task)


def test_prompts_differ_only_in_the_channel():
    for name in tasks.TASKS:
        t = tasks.build(name, 3)
        for role in t.tickets:
            bare = tasks.prompt(t, role, "none", "claude")
            check("agentbus" not in bare.lower() and "COORDINATION" not in bare and "SendMessage" not in bare, "%s: none names a channel" % name)
            for cond in ("ledger", "agentbus", "builtin"):
                block = tasks.channel_block(cond, role, "bob" if role == "alice" else "alice", "claude")
                got = tasks.prompt(t, role, cond, "claude")
                check(got.replace(block + "\n\n", "") == bare, "%s %s: the text differs beyond the channel block" % (name, cond))
    check("agentbus" not in tasks.LEDGER_SKILL.lower(), "the ledger skill names the tool")
    for section in ("## Start", "## Before shared work", "## Communicate", "## Finish the session", "## Boundaries"):
        check(section in tasks.LEDGER_SKILL and section in tasks.PEER_SKILL, "a channel skill lacks %s" % section)


def test_lost_features():
    markers = {"tax": ("p.py", "tax"), "disc": ("p.py", "saved")}
    snaps = [{"p.py": "saved"}, {"p.py": "saved tax"}, {"p.py": "tax"}]
    check(grade.lost_features(snaps, {"p.py": "tax"}, markers) == ["disc"], "a feature that vanished was not reported")
    check(grade.lost_features(snaps, {"p.py": "saved tax"}, markers) == [], "a kept feature was reported lost")
    check(grade.lost_features([{"p.py": ""}], {"p.py": ""}, markers) == [], "a feature never written was reported lost")


def test_edit_metrics():
    e = lambda a, p: {"ts": 0, "agent": a, "path": p}  # noqa: E731
    got = grade.edit_metrics([e("a", "x"), e("b", "x"), e("a", "x"), e("a", "y"), e("a", "y")])
    check(got["paths_edited_by_both"] == ["x"] and got["interleaved_switches"] == 2 and got["rework_events"] == 3, "edit metrics: %s" % got)
    got = grade.edit_metrics([e("a", "x"), e("b", "y")])
    check(got["paths_edited_by_both"] == [] and got["interleaved_switches"] == 0 and got["rework_events"] == 0, "clean split: %s" % got)


def test_duplicates():
    base = {"a.py": "def old():\n    pass\n"}
    final = {"a.py": "def f():\n    pass\n", "b.py": "def f():\n    pass\n", "c.py": "def g():\n    pass\n"}
    check(grade.duplicates(final, base) == ["f"], "a function in two changed files is duplicate work")
    check(grade.duplicates(final, base, ("f",)) == [], "a name the task asks for everywhere is not")
    check(grade.duplicates({"a.py": "def old():\n    pass\n", "b.py": "def old():\n    pass\n"}, {"a.py": "def old():\n    pass\n"}) == [], "an untouched file counted as changed")


def claude_lines(*objs):
    return [{"ts": i, "line": json.dumps(o)} for i, o in enumerate(objs)]


def test_cost_claude():
    use = {"input_tokens": 1, "cache_creation_input_tokens": 2, "cache_read_input_tokens": 3, "output_tokens": 4}
    tool = {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "agentbus --as a post hi"}}
    lines = claude_lines({"type": "system", "subtype": "init", "model": "m1"},
                         {"type": "assistant", "message": {"id": "a", "usage": use, "content": [tool]}},
                         {"type": "assistant", "message": {"id": "a", "usage": use, "content": []}},   # one message, streamed in two events
                         {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "posted #1"}]}},
                         {"type": "result", "total_cost_usd": 0.5})
    got = grade.cost_of(lines, "claude", "agentbus")
    check(got["usage"] == {"input": 1, "cache_write": 2, "cache_read": 3, "output": 4}, "one message counted twice: %s" % got["usage"])
    check(got["complete"] and got["cost_usd"] == 0.5 and got["model"] == "m1" and got["tool_calls"] == 1, "cost fields: %s" % got)
    check(got["channel_calls"] == 1 and got["channel_writes"] == 1 and got["channel_bytes_back"] > 0, "a bus call is channel cost: %s" % got)
    check(grade.cost_of(lines, "claude", "ledger")["channel_calls"] == 0, "a bus call counted in a ledger run")
    check(not grade.cost_of(lines[:-1], "claude", "agentbus")["complete"], "a killed session must read as incomplete")
    truth = dict(use, output_tokens=40)
    lines2 = lines[:-1] + claude_lines({"type": "result", "total_cost_usd": 0.5, "usage": truth})
    check(grade.cost_of(lines2, "claude", "agentbus")["usage"]["output"] == 40, "the result event's totals must beat the undercounting message events")
    check(grade.cost_of(lines[:-1], "claude", "agentbus")["usage"]["output"] == 4, "a killed session's tokens must still count")


def test_cost_codex():
    lines = claude_lines({"type": "item.completed", "item": {"id": "1", "type": "command_execution", "command": "cat COORDINATION.md", "aggregated_output": "abc"}},
                         {"type": "item.completed", "item": {"id": "2", "type": "command_execution", "command": "ls", "aggregated_output": "x"}},
                         {"type": "turn.completed", "usage": {"input_tokens": 100, "cached_input_tokens": 60, "output_tokens": 5}})
    got = grade.cost_of(lines, "codex", "ledger")
    check(got["usage"] == {"input": 40, "cache_write": 0, "cache_read": 60, "output": 5}, "codex usage: %s" % got["usage"])
    check(got["tool_calls"] == 2 and got["channel_calls"] == 1 and got["channel_bytes_back"] == 3, "codex channel cost: %s" % got)


def test_tool_counter():
    t = {"type": "assistant", "message": {"content": [{"type": "tool_use"}, {"type": "tool_use"}, {"type": "text"}]}}
    check(grade.tool_calls_in_line(json.dumps(t), "claude") == 2, "two tool calls in one message")
    check(grade.tool_calls_in_line(json.dumps({"type": "item.started", "item": {"type": "command_execution"}}), "codex") == 1, "codex start")
    check(grade.tool_calls_in_line(json.dumps({"type": "item.completed", "item": {"type": "command_execution"}}), "codex") == 0, "codex end must not count twice")
    check(grade.tool_calls_in_line("not json", "claude") == 0, "a bad line")


def test_check_claude_init():
    tools = ["Bash", "Read"]
    good = {"type": "system", "subtype": "init", "tools": tools, "skills": ["deep-research"], "plugins": [{"name": "x", "path": "builtin"}], "mcp_servers": []}
    run = lambda init, cond="none", more=(): grade.check_claude_init(claude_lines(init, *more), cond, tools)  # noqa: E731
    check(run(good) == [], "a clean none run: %s" % run(good))
    hook = {"type": "system", "subtype": "hook_started"}
    check(any("hook" in x for x in run(good, "none", [hook])), "a hook in a none run")
    check(any("no hook" in x for x in run(dict(good, skills=["agentbus"]), "agentbus")), "an agentbus run with no hook")
    check(run(dict(good, skills=["agentbus"]), "agentbus", [hook]) == [], "a clean agentbus run")
    check(any("skill" in x for x in run(dict(good, skills=["agentbus"]))), "the bus skill in a none run")
    check(any("skill" in x for x in run(good, "ledger")), "a ledger run missing its skill")
    check(any("plugins" in x for x in run(dict(good, plugins=[{"name": "p", "path": "/x"}]))), "a user plugin")
    check(any("MCP" in x for x in run(dict(good, mcp_servers=[{"name": "s"}]))), "an MCP server")
    check(any("tools" in x for x in run(dict(good, tools=tools + ["SendMessage"]))), "a hidden channel tool")
    check(grade.check_claude_init([], "none", tools) == ["no init event"], "no init")


def test_infra():
    no_tool = claude_lines({"type": "result", "result": "Not logged in"})
    check(grade.infra_failure(no_tool, "claude", 1, False, None), "a sign-in failure is infra")
    tooled = claude_lines({"type": "assistant", "message": {"content": [{"type": "tool_use"}]}})
    check(grade.infra_failure(tooled, "claude", 1, False, None) is None, "a crash after work started stays in")
    check(grade.infra_failure(no_tool, "claude", 1, False, "time_cap") is None, "a timeout stays in")
    check(grade.infra_failure(no_tool, "claude", 1, True, None) is None, "the task's own kill stays in")
    check(grade.infra_failure(claude_lines({"type": "result", "result": "done"}), "claude", 0, False, None) is None, "an idle agent stays in: it did nothing, and that counts")


def test_stats():
    lo, hi = analyze.wilson(8, 10)
    check(abs(lo - 0.490) < 0.002 and abs(hi - 0.943) < 0.002, "wilson 8 of 10: %s %s" % (lo, hi))
    check(analyze.wilson(0, 0) == (0.0, 1.0), "no data is no information")
    check(analyze.verdict(0.20, 0.05, 0.35) == "value over a flat file", "value")
    check(analyze.verdict(0.08, 0.01, 0.15).startswith("real but small"), "small")
    check(analyze.verdict(-0.05, -0.2, 0.10).startswith("no meaningful value"), "null")
    check(analyze.verdict(0.05, -0.1, 0.2).startswith("inconclusive"), "inconclusive")
    check(analyze.verdict(0.30, -0.02, 0.6).startswith("inconclusive"), "a big estimate with a wide interval is not a win")
    r = random.Random(4)
    blocks = {s: [r.gauss(0.2, 0.3) for _ in range(4)] for s in range(40)}
    point, lo, hi = analyze.bootstrap_mean_diff(blocks, resamples=2000)
    check(lo < 0.2 < hi and hi - lo < 0.2, "the interval covers a known effect: %s %s %s" % (point, lo, hi))
    blocks = {s: [r.gauss(0.0, 0.3) for _ in range(4)] for s in range(40)}
    _, lo, hi = analyze.bootstrap_mean_diff(blocks, resamples=2000)
    check(lo < 0 < hi, "the interval covers a null: %s %s" % (lo, hi))
    rows = [{"seed": s, "condition": c, "v": v} for s in range(30) for c, v in (("a", 150.0), ("b", 100.0))]
    point, lo, hi = analyze.bootstrap_ratio(rows, "a", "b", lambda x: x["v"], resamples=500)
    check(math.isclose(point, 1.5) and math.isclose(lo, 1.5) and math.isclose(hi, 1.5), "ratio")


def test_pairing():
    row = lambda seed, task, cond, ok: {"seed": seed, "task": task, "condition": cond, "pairing": "cc", "ok": ok}  # noqa: E731
    rows = [row(1, "overlap", "agentbus", 1), row(1, "overlap", "ledger", 0), row(2, "overlap", "agentbus", 1)]  # seed 2 has no ledger run
    got = analyze.pair_blocks(rows, "agentbus", "ledger", ("overlap",), "cc", lambda r: r["ok"])
    check(got == {1: [1]}, "only true pairs count: %s" % got)


def test_blind_grade_opens_only_blind_files():
    """Graded twice, with and then without every file that knows the condition: the result must not change."""
    d = tempfile.mkdtemp()
    task = tasks.build("control", 1)
    final = os.path.join(d, "r1", "final")
    tree(final, task.files)
    tree(final, tasks.reference("control", 1))
    run = os.path.join(d, "r1")
    grade.write_json(os.path.join(run, "run.json"), {"id": "r1", "task": "control", "seed": 1, "agents": {"alice": {"stop": None}}, "seconds": 1, "load": {"max": 1}, "kill": {}})
    grade.write_json(os.path.join(run, "edits.json"), [])
    open(os.path.join(run, "snaps.jsonl"), "w").close()
    with_files = {n: "condition agentbus" for n in ("cost.json", "trace-alice.jsonl", "prompt-alice.txt")}
    tree(run, with_files)
    tree(d, {"manifest.jsonl": "garbage that would crash a reader\n"})
    first = grade.blind_grade(run)
    check(first["pass"], "the reference graded as a fail: %s" % first)
    for n in with_files:
        os.remove(os.path.join(run, n))
    os.remove(os.path.join(d, "manifest.jsonl"))
    check(grade.blind_grade(run) == first, "the grade depends on a file that knows the condition")
    shutil.rmtree(d)


for name, fn in sorted(globals().items()):
    if name.startswith("test_"):
        fn()
print("value eval cases: %d checks passed" % checks)
