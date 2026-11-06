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


def test_lanes_cannot_see_each_other_through_one_tree():
    """Pilot: in one shared tree a README note or a polled file is a channel, so `none` passed facts and interface every time."""
    for name in ("interface", "facts"):
        t = tasks.build(name, 1)
        check(t.workspace == "worktrees" and t.schedule == [["alice", "bob"]], "%s must run as concurrent lanes" % name)
        check(all("plain git merge" in x for x in t.tickets.values()), "%s must state the merge rule" % name)
    check("after you" not in tasks.build("facts", 1).tickets["alice"], "alice is told bob needs her decision")


def test_overlap_runs_in_worktrees():
    check(tasks.build("overlap", 1).workspace == "worktrees" and tasks.build("overlap-shared", 1).workspace == "shared", "workspaces")
    check("overlap-shared" not in tasks.TASKS, "the retired task must stay out of the matrix")
    check(tasks.hidden_tests("overlap-shared", 1) == tasks.hidden_tests("overlap", 1), "the fixture must grade the same way")


def test_recovery_queue_gates_the_next_module():
    """A session can learn only one module ahead, and no reading of the files gets it further: each module opens with the output of
    the port before it. Pilot pass 2 read an encoded queue straight off the disk, so plain encoding is not enough."""
    t = tasks.build("recovery", 2)
    p = tasks._recovery_params(2)
    ref = tasks.reference("recovery", 2)
    d = tempfile.mkdtemp()
    tree(d, t.files)
    nxt = lambda: subprocess.run([sys.executable, "-B", "tools/migrate.py", "next"], cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True).stdout  # noqa: E731
    check("next module: %s" % p["mods"][0] in nxt(), "the first module: %s" % nxt())
    check(not any(k.startswith("legacy/") for k in t.files), "legacy source sits in the repo")
    check("FACTOR" not in t.files["tools/queue.json"] and "old_" not in t.files["tools/queue.json"], "the queue is readable on disk")
    tree(d, {"src/%s.py" % p["mods"][0]: "def run(values):\n    return [0 for v in values]\n"})
    check("will not open" in nxt(), "a wrong port opened the next module: %s" % nxt())
    for i, m in enumerate(p["mods"][:4]):
        tree(d, {"src/%s.py" % m: ref["src/%s.py" % m]})
        check("next module: %s" % p["mods"][i + 1] in nxt(), "the queue did not move past %s: %s" % (m, nxt()))
    tree(d, {"src/__init__.py": ref["src/__init__.py"]})
    check("next module: %s" % p["mods"][5] in nxt(), "skipping the retired module must open the last: %s" % nxt())
    check("FACTOR = %d" % p["factors"][5] in nxt(), "the last module shows the old factor, which is the trap: %s" % nxt())
    tree(d, ref)
    check("queue empty" in nxt(), "a finished queue: %s" % nxt())
    shutil.rmtree(d)


def test_no_channel_has_an_instruction_the_skill_lacks():
    """Ruling of 2026-11-05: the ledger and peer texts carry no writing advice the shipped skill does not."""
    for text in (tasks.LEDGER_SKILL, tasks.PEER_SKILL):
        check("Write what the reader needs" not in text, "a channel text has an instruction the skill lacks")
    for text in (tasks.LEDGER_SKILL, tasks.PEER_SKILL):
        check("If you are waiting" not in text and "timeout" not in text and "sleep" not in text, "a channel text tells agents how to wait")
    check("## Communicate" in tasks.LEDGER_SKILL and "## Communicate" in tasks.PEER_SKILL, "the rest of the text must stay")


def test_secret_leaks():
    d = tempfile.mkdtemp()
    auth = os.path.join(d, "auth.json")
    secret = "tok_" + "x" * 40
    grade.write_json(auth, {"auth_mode": "chatgpt", "last_refresh": "2026-11-03T02:15:49.433251Z", "tokens": {"access_token": secret, "account_id": "short"}})
    clean, dirty = os.path.join(d, "clean.txt"), os.path.join(d, "dirty.txt")
    open(clean, "w").write("nothing here but 2026-11-03T02:15:49.433251Z\n")
    open(dirty, "w").write("argv: --token %s\n" % secret)
    check(grade.secret_leaks(auth, [clean]) == [], "a clean file reported as a leak")
    check(grade.secret_leaks(auth, [clean, dirty]) == ["dirty.txt"], "a token in a trace was not found")
    shutil.rmtree(d)


def test_codex_quota():
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "sessions", "2026"))
    path = os.path.join(d, "sessions", "2026", "rollout-a.jsonl")
    lines = [{"payload": {"rate_limits": {"limit_id": "premium", "primary": None}}},
             {"payload": {"rate_limits": {"limit_id": "codex", "primary": {"used_percent": 51.0, "resets_at": 9}}}},
             {"payload": {"rate_limits": {"limit_id": "codex", "primary": {"used_percent": 52.0, "resets_at": 9}}}}, {"payload": {}}]
    open(path, "w").write("\n".join(json.dumps(x) for x in lines) + "\nnot json\n")
    check(grade.codex_quota(d) == {"used_percent": 52.0, "resets_at": 9}, "the last codex bucket reading: %s" % grade.codex_quota(d))
    check(grade.codex_quota(os.path.join(d, "none")) is None, "no rollouts means no reading")
    shutil.rmtree(d)


def test_killed_codex_tokens_come_from_the_rollout():
    """Codex reports usage at turn end, so a killed session's stream says 0: a pilot run recorded 0 for a session that used 100,000."""
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "sessions"))
    usage = {"input_tokens": 101148, "cached_input_tokens": 94720, "output_tokens": 928}
    rows = [{"payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 5, "cached_input_tokens": 1, "output_tokens": 1}}}},
            {"payload": {"type": "token_count", "info": {"total_token_usage": usage}}}, {"payload": {"type": "token_count", "info": None}}]
    open(os.path.join(d, "sessions", "rollout-x.jsonl"), "w").write("\n".join(json.dumps(x) for x in rows) + "\n")
    check(grade.codex_rollout_usage(d) == {"input": 6428, "cache_write": 0, "cache_read": 94720, "output": 928}, "rollout totals: %s" % grade.codex_rollout_usage(d))
    check(grade.codex_rollout_usage(os.path.join(d, "none")) is None, "no rollout means no reading")
    shutil.rmtree(d)


def test_budget_stop():
    over = analyze.over_budget
    check(over(50, 92, 100, 300, 40), "spent alone past the budget halts")
    check(over(50, 70, 30, 300, 40), "20 points in 30 of 300 runs projects 200")
    check(not over(50, 53, 30, 300, 40), "3 points in 30 of 300 projects 30")
    check(not over(50, 51, 2, 300, 40), "too few runs to project: one rounded point is noise")
    check(not over(50, 10, 40, 300, 40), "a reset window reads as nothing spent")
    check(not over(None, None, 40, 300, 40), "no reading yet")


def test_tool_pin():
    """Runs test the release: any other bin/agentbus is refused."""
    import run
    d = tempfile.mkdtemp()
    git = ["git", "-c", "user.name=e", "-c", "user.email=e@example.com"]
    tree(d, {"bin/agentbus": "released\n"})
    for argv in (["git", "init", "-q"], git + ["add", "."], git + ["commit", "-q", "-m", "x"]):
        subprocess.run(argv, cwd=d, check=True)
    check(run.tool_is_release(d, "HEAD"), "the release must match itself")
    tree(d, {"bin/agentbus": "patched\n"})
    check(not run.tool_is_release(d, "HEAD"), "a patched tool passed as the release")
    check(not run.tool_is_release(d, "no-such-ref"), "an unknown release passed")
    shutil.rmtree(d)


def test_ledger_text_covers_what_the_skill_covers():
    """Item 8: each instruction the agentbus skill gives has its ledger counterpart."""
    text = tasks.LEDGER_SKILL
    for needle, what in (("relative to the repo root", "how to spell a path"), ("git ls-files", "exact spelling"),
                         ("Read the whole file", "reading all of it"), ("latest FACT", "which fact wins"),
                         ("<<'EOF'", "multi-line entries by heredoc"), ("blank line", "entry separator"),
                         ("Hooks:", "what the hooks do"), ("never replace reading", "hooks do not replace reading"),
                         ("JOIN entries", "who is here"), ("Claim new files before creating them", "new files"),
                         ("covers everything in it", "folder claims"), ("release your claims", "finish")):
        check(needle in text, "the ledger text lacks %s (%r)" % (what, needle))


def test_ledger_parser():
    import ledger_hook as lh
    text = ("# notes\n\n10:01:00 alice JOIN: porting\n\n10:02:00 alice CLAIM: src/ (porting)\n\n"
            "10:03:00 alice HANDOFF to bob: state\nline two\nline three\n\n"
            "10:04:00 alice FACT delimiter: ;\n10:05:00 bob FACT delimiter: |\n10:06:00 bob CLAIM: VERSION, CHANGELOG.md (bump)\n"
            "10:07:00 bob RELEASE: CHANGELOG.md\n10:08:00 alice QUESTION to bob: which?\n")
    entries = lh.parse(text)
    check([e["kind"] for e in entries] == ["JOIN", "CLAIM", "HANDOFF", "FACT", "FACT", "CLAIM", "RELEASE", "QUESTION"], [e["kind"] for e in entries])
    check(entries[2]["to"] == "bob" and entries[2]["text"] == "state\nline two\nline three", "a multi-line entry: %r" % entries[2]["text"])
    check(lh.facts(entries) == {"delimiter": "|"}, "the latest FACT must win: %s" % lh.facts(entries))
    check(lh.open_claims(entries) == {("alice", "src"): "porting", ("bob", "VERSION"): "bump"}, "open claims: %s" % lh.open_claims(entries))
    check(lh.covers("src", "src/a.py") and not lh.covers("src", "srcx/a.py"), "folder cover")


def _hook(event, payload, name, cwd, tmp):
    p = subprocess.run([sys.executable, "-B", os.path.join(os.path.abspath(sys.argv[1]), "ledger_hook.py"), "claude", event], input=json.dumps(payload),
                       cwd=cwd, env={"LEDGER_NAME": name, "TMPDIR": tmp, "PATH": "/usr/bin:/bin"}, stdout=subprocess.PIPE, universal_newlines=True)
    return json.loads(p.stdout)["hookSpecificOutput"]["additionalContext"] if p.stdout.strip() else None


def test_ledger_hook():
    d, tmp = tempfile.mkdtemp(), tempfile.mkdtemp()
    tree(d, {"COORDINATION.md": "10:01 bob CLAIM: pkg/a.py (tax)\n\n10:02 bob QUESTION to alice: API?\n10:03 bob NOTE: hi\n", "pkg/a.py": "", "sub/x": ""})
    got = _hook("SessionStart", {"cwd": os.path.join(d, "sub"), "session_id": "s1"}, "alice", d, tmp)
    check("has 3 entries, 1 addressed to alice" in got and "QUESTION to alice: API?" in got, "session start: %s" % got)
    warn = _hook("PreToolUse", {"cwd": d, "session_id": "s1", "tool_input": {"file_path": os.path.join(d, "pkg/a.py")}}, "alice", d, tmp)
    check(warn and "claimed by bob" in warn and "(tax)" in warn, "no warning on another's claim: %s" % warn)
    check(_hook("PreToolUse", {"cwd": d, "session_id": "s1", "tool_input": {"file_path": os.path.join(d, "pkg/a.py")}}, "bob", d, tmp) is None, "the holder was warned")
    payload = {"cwd": d, "session_id": "s1", "tool_input": {"file_path": "pkg/b.py"}}
    first = _hook("PreToolUse", payload, "alice", d, tmp)
    check(first and "has no CLAIM" in first, "no nudge on an unclaimed path: %s" % first)
    check(_hook("PreToolUse", payload, "alice", d, tmp) is None, "the nudge repeated")
    patch = {"cwd": d, "session_id": "s2", "tool_input": {"command": "*** Begin Patch\n*** Update File: pkg/a.py\n@@\n*** End Patch"}}
    check("claimed by bob" in (_hook("PreToolUse", patch, "alice", d, tmp) or ""), "a Codex patch path was not seen")
    check(_hook("PreToolUse", {"cwd": d, "session_id": "s3", "tool_input": {"file_path": "COORDINATION.md"}}, "alice", d, tmp) is None, "the ledger itself was nudged")
    empty = tempfile.mkdtemp()
    check("no COORDINATION.md here yet" in _hook("SessionStart", {"cwd": empty}, "alice", empty, tmp), "a missing ledger")
    for x in (d, tmp, empty):
        shutil.rmtree(x)


def test_hook_rules_per_condition():
    tools = ["Bash", "Read"]
    init = {"type": "system", "subtype": "init", "tools": tools, "skills": ["ledger"], "plugins": [], "mcp_servers": []}
    started = {"type": "system", "subtype": "hook_started"}
    failed = {"type": "system", "subtype": "hook_response", "hook_event": "PreToolUse", "exit_code": "1", "outcome": "error", "stdout": ""}
    empty_start = {"type": "system", "subtype": "hook_response", "hook_event": "SessionStart", "exit_code": "0", "outcome": "success", "stdout": ""}
    good = {"type": "system", "subtype": "hook_response", "hook_event": "SessionStart", "exit_code": "0", "outcome": "success", "stdout": "{}"}
    check(grade.check_claude_init(claude_lines(init, started), "ledger", tools) == [], "hooks must be allowed in a ledger run")
    check(any("hook" in x for x in grade.check_claude_init(claude_lines(dict(init, skills=[]), started), "none", tools)), "a hook in none")
    check(grade.check_claude_init(claude_lines(dict(init, skills=["agentbus"])), "agentbus", tools) == [], "missing hooks are infra, not isolation")
    check(grade.hook_report(claude_lines(init, started, good)) == {"started": 1, "failed": 0}, "a clean hook")
    check(grade.hook_report(claude_lines(init, started, failed, empty_start)) == {"started": 1, "failed": 2}, "a failed and a silent SessionStart hook")
    check(grade.hook_infra(claude_lines(init), "ledger") and grade.hook_infra(claude_lines(init), "agentbus"), "settings that did not load are infra")
    check(not grade.hook_infra(claude_lines(init, started, failed), "agentbus"), "a hook that ran and failed is an outcome")
    check(not grade.hook_infra(claude_lines(init), "none"), "none has no hooks to load")


def test_channel_counting():
    def call(name, payload):
        return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": name + str(len(payload)), "name": name, "input": payload}]}}
    bus = claude_lines(call("Skill", {"skill": "agentbus"}), call("Bash", {"command": "agentbus --as a inbox"}),
                       call("Bash", {"command": "agentbus --as a claim src --purpose x && agentbus --as a post hi"}),
                       call("Bash", {"command": "echo 'nothing about a claim here'"}))
    got = grade.cost_of(bus, "claude", "agentbus")
    check(got["channel_calls"] == 2 and got["channel_writes"] == 1, "a Skill call or a stray word counted: %s" % got)
    led = claude_lines(call("Skill", {"skill": "ledger"}), call("Bash", {"command": "cat COORDINATION.md | grep claim"}),
                       call("Bash", {"command": "printf '%s\\n' x >> COORDINATION.md"}), call("Read", {"file_path": "/w/COORDINATION.md"}))
    got = grade.cost_of(led, "claude", "ledger")
    check(got["channel_calls"] == 3 and got["channel_writes"] == 1, "ledger counting: %s" % got)


def test_channel_paths():
    for path in ("../proj/COORDINATION.md", "COORDINATION.md", "a/.claude/x", "pkg/__pycache__/m.pyc", ".agentbus/bus.db", "sub/AGENTS.md"):
        check(grade.is_channel_path(path), "%s must count as a channel path" % path)
    for path in ("pkg/a.py", "docs/COORDINATION.txt", "claude/x.py"):
        check(not grade.is_channel_path(path), "%s is project work" % path)


def test_protocol_steps():
    def bash(c):
        return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": c[:9] + str(len(c)), "name": "Bash", "input": {"command": c}}]}}
    edit = {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "e1", "name": "Write", "input": {"file_path": "/w/pkg/a.py"}}]}}
    good = claude_lines(bash("cat COORDINATION.md"), bash("printf x >> COORDINATION.md # CLAIM: pkg/a.py"), edit,
                        bash("printf x >> COORDINATION.md # RELEASE: pkg/a.py"), bash("printf x >> COORDINATION.md # DONE: ok"))
    check(grade.protocol_steps(good, "claude", "ledger") == {"read_first": True, "claim_first": True, "released": True, "finished": True},
          "a compliant ledger session: %s" % grade.protocol_steps(good, "claude", "ledger"))
    bad = claude_lines(edit, bash("printf x >> COORDINATION.md # DONE: ok"))
    check(grade.protocol_steps(bad, "claude", "ledger") == {"read_first": False, "claim_first": False, "released": False, "finished": True}, "an edit first")
    bus = claude_lines(bash("agentbus --as a join; agentbus --as a brief"), bash("agentbus --as a claim pkg/a.py"), edit,
                       bash("agentbus --as a post 'r' --kind done"), bash("agentbus --as a leave"))
    check(grade.protocol_steps(bus, "claude", "agentbus") == {"read_first": True, "claim_first": True, "released": True, "finished": True},
          "a compliant bus session: %s" % grade.protocol_steps(bus, "claude", "agentbus"))


def test_holm_and_verdicts():
    adj = analyze.holm({"P1": 0.01, "P2": 0.04, "P3": 0.03})
    check(all(math.isclose(adj[k], v) for k, v in {"P1": 0.03, "P3": 0.06, "P2": 0.06}.items()), "holm: %s" % adj)
    check(analyze.holm({"P1": 0.5}) == {"P1": 0.5}, "one hypothesis")
    check(analyze.boot_p([0.1, 0.2, -0.1, 0.3], 0.0, "above") == (1 + 1) / 5, "one-sided p above zero")
    check(analyze.boot_p([1.1, 1.3, 1.2, 1.4], 1.25, "below") == (1 + 2) / 5, "one-sided p below the margin")
    check(analyze.verdict(-0.20, -0.35, -0.05, False) == "flat file better", "an interval wholly below zero")
    check(analyze.verdict(0.20, 0.05, 0.35, False).startswith("inconclusive"), "a Holm miss is not a win, whatever the raw interval says")
    check(analyze.verdict(0.20, 0.05, 0.35, True) == "value over a flat file", "value")
    check(analyze.verdict(0.08, 0.01, 0.12, True).startswith("real but small"), "small")
    check(analyze.flat_file_better(p3_within=False, pass_verdict="value over a flat file", ledger_cheaper=False), "P3 failing alone decides")
    check(analyze.flat_file_better(True, "no meaningful value over a flat file", True), "a match on pass rate at lower cost")
    check(not analyze.flat_file_better(True, "no meaningful value over a flat file", False), "a match at no lower cost")
    check(not analyze.flat_file_better(True, "inconclusive: no evidence of value", True), "an inconclusive pass rate is not a match")
    check(analyze.flat_file_better(True, "flat file better", False), "flat file better on pass rate")


def test_p3_counts_every_token():
    rows = []
    for s in range(12):
        rows.append({"seed": s, "condition": "agentbus", "cost": {"a": {"usage": {"input": 10, "cache_write": 0, "cache_read": 990, "output": 0}}}})
        rows.append({"seed": s, "condition": "ledger", "cost": {"a": {"usage": {"input": 10, "cache_write": 0, "cache_read": 490, "output": 0}}}})
    point, _lo, _hi, _draws = analyze.p3(rows, resamples=200)
    check(math.isclose(point, 2.0), "P3 must be on total tokens as registered: %s" % point)


def test_usage_limit_detection():
    hit = json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "You've hit your weekly limit \u00b7 resets Nov 8 at 5am"}]}})
    api = json.dumps({"type": "result", "is_error": True, "result": "api_error usage_limit_reached"})
    check(grade.usage_limited(hit) and grade.usage_limited(api), "a usage limit went unseen")
    for quiet in ('{"type": "assistant", "message": {"content": [{"type": "text", "text": "the claim limit is 2h"}]}}', "not json", ""):
        check(not grade.usage_limited(quiet), "a false usage limit: %r" % quiet)


def test_dropped_summary():
    rows = [{"id": "r%d" % i, "infra": {"alice": "no tool call and rc 1"}, "isolation": []} for i in range(30)] + [{"id": "rx", "infra": {"bob": "usage limit"}, "isolation": []}]
    text = analyze.dropped_summary(rows)
    check(text.splitlines()[0] == "dropped under the protocol's rule: 31", text)
    check("30 runs: no tool call and rc 1" in text and "1 run: usage limit" in text and "r17" not in text, "the summary lists ids or misses a reason: %s" % text)


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


def test_script_edits():
    script = "python3 - <<'E'\\np='pkg/a.py'\\ns=open(p).read()\\nopen(p,'w').write(s)\\nE"
    read_only = "cat pkg/a.py; python3 -c 'print(1)'"
    line = lambda c: {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": c}}]}}  # noqa: E731
    known = {"pkg/a.py", "pkg/b.py"}
    check(grade.script_edits(claude_lines(line(script)), "claude", known) == [(0, "pkg/a.py")], "a scripted edit went unseen")
    check(grade.script_edits(claude_lines(line(read_only)), "claude", known) == [], "a read counted as an edit")
    codex = {"type": "item.started", "item": {"type": "command_execution", "command": script}}
    check(grade.script_edits(claude_lines(codex), "codex", known) == [(0, "pkg/a.py")], "a Codex scripted edit went unseen")


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
    check(grade.hook_infra(claude_lines(dict(good, skills=["agentbus"])), "agentbus"), "an agentbus run with no hook")   # infrastructure since the 2026-11-05 ruling
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
