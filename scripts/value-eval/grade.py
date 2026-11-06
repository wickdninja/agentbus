#!/usr/bin/env python3
"""Value eval graders. Two kinds, kept apart on purpose (docs/evals/value-protocol.md, Blinding):

blind_grade reads a run folder's final tree, snapshots and edit list, and never the manifest, a trace or the cost file.
Those are the only files it opens, so it cannot see the condition; the channel's files were removed before they got here.

The rest (cost_of, tool_calls_in_line, check_claude_init, infra_failure) read raw streams, so they know the condition.
They count, and never decide a pass.

python3 scripts/value-eval/grade.py OUT writes grade.json into each run folder under OUT.
"""
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.append(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "agent-eval"))  # last: it has a run.py too
import normalize  # noqa: E402
import tasks  # noqa: E402

CHANNEL_PATHS = (".agentbus", "COORDINATION.md", ".claude", "AGENTS.md", ".git", "__pycache__", "CLAUDE.md")
HOOKED = ("agentbus", "ledger")    # conditions whose harness hooks are part of the channel
BUS_WRITES = {"post", "claim", "release", "goal", "join", "leave"}
LEDGER_WRITE = re.compile(r"""(?:>>|\btee\s+-a)\s*['"]?(?:[^\s'";&|]*/)?COORDINATION\.md""")
LEDGER_READ = re.compile(r"\b(?:cat|grep|egrep|tail|head|sed|awk|less|more|wc|nl)\b[^;&|\n]*COORDINATION\.md")
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
TEXT_SUFFIXES = (".py", ".md", ".txt", ".feed", ".json", ".toml", ".cfg", "")
HIDDEN_TIMEOUT = 120
SCRIPT_WRITE = re.compile(r"\.write\(|\.write_text\(|\.write_bytes\(|\.writelines\(")


def write_json(path, value):
    with open(path, "w") as f:
        json.dump(value, f, indent=1, sort_keys=True)


def read_tree(root, skip):
    """{relative path: text} for the small text files of a tree, leaving out any top-level or nested name in skip."""
    found = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in skip]
        for name in files:
            if name in skip or os.path.splitext(name)[1] not in TEXT_SUFFIXES:
                continue
            path = os.path.join(d, name)
            try:
                with open(path, errors="replace") as f:
                    found[os.path.relpath(path, root)] = f.read(200000)
            except OSError:
                pass
    return found


def is_channel_path(path):
    """True for a path inside or naming a channel file: any part of it, not just the first, so a ledger reached through a worktree's
    link (../proj/COORDINATION.md) is the ledger and never project work."""
    return any(part in CHANNEL_PATHS for part in path.replace("\\", "/").split("/"))


# ---- blind ----------------------------------------------------------------------------------------------------------

def run_hidden(final, task, seed):
    """Copy the final tree to a temp folder, add the hidden tests, and run each feature in its own process."""
    work = tempfile.mkdtemp(prefix="value-grade-")
    try:
        tree = os.path.join(work, "t")
        shutil.copytree(final, tree)
        hidden = tasks.hidden_tests(task, seed)
        for name, text in hidden.items():
            with open(os.path.join(tree, name), "w") as f:
                f.write(text)
        out = {}
        for name in hidden:
            try:
                p = subprocess.run([sys.executable, "-B", "-m", "unittest", name[:-3]], cwd=tree, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, universal_newlines=True, timeout=HIDDEN_TIMEOUT)
                out[name[len("hidden_"):-3]] = p.returncode == 0
            except subprocess.TimeoutExpired:
                out[name[len("hidden_"):-3]] = False
        return out
    finally:
        shutil.rmtree(work, ignore_errors=True)


def snapshots(path):
    """Yield the tree as it stood at each snapshot, replaying the deltas."""
    state = {}
    if not os.path.exists(path):
        return
    for line in open(path):
        delta = json.loads(line)
        state.update(delta["changed"])
        for gone in delta["gone"]:
            state.pop(gone, None)
        yield dict(state)


def lost_features(snaps, final_files, markers):
    """A feature's marker was in the tree at some point and is not at the end: somebody's work was overwritten."""
    lost = []
    for feature, (path, pattern) in sorted(markers.items()):
        rx = re.compile(pattern)
        if rx.search(final_files.get(path, "")):
            continue
        if any(rx.search(s.get(path, "")) for s in snaps):
            lost.append(feature)
    return lost


def edit_metrics(edits):
    """edits: [{"ts", "agent", "path"}] in time order. Overlap, interleaving and rework, all from the tool trace."""
    by_path = {}
    for e in edits:
        by_path.setdefault(e["path"], []).append(e["agent"])
    shared = sorted(p for p, who in by_path.items() if len(set(who)) > 1)
    switches = sum(sum(1 for a, b in zip(who, who[1:]) if a != b) for who in by_path.values())
    return {"edit_events": len(edits), "paths_edited": len(by_path), "rework_events": len(edits) - len(by_path),
            "paths_edited_by_both": shared, "interleaved_switches": switches}


def defined_functions(text):
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []
    return [n.name for n in tree.body if isinstance(n, ast.FunctionDef) and not n.name.startswith("test")]


def duplicates(final_files, base_files, expected=()):
    """Function names defined at top level in more than one changed or new module, apart from names the task asks for everywhere."""
    where = {}
    for path, text in final_files.items():
        if path.endswith(".py") and not path.startswith("tests/") and base_files.get(path) != text:
            for name in defined_functions(text):
                where.setdefault(name, set()).add(path)
    return sorted(n for n, paths in where.items() if len(paths) > 1 and n not in expected)


def blind_grade(run_dir):
    with open(os.path.join(run_dir, "run.json")) as f:
        run = json.load(f)
    task = tasks.build(run["task"], run["seed"])
    final = os.path.join(run_dir, "final")
    final_files = read_tree(final, ())
    features = run_hidden(final, run["task"], run["seed"])
    with open(os.path.join(run_dir, "edits.json")) as f:
        edits = json.load(f)
    snaps = list(snapshots(os.path.join(run_dir, "snaps.jsonl")))
    stops = sorted({a["stop"] for a in run["agents"].values() if a["stop"] and a["stop"] != "task_kill"})
    grade = {"id": run["id"], "features": features, "pass": bool(features) and all(features.get(f) for f in task.features),
             "lost_features": lost_features(snaps, final_files, task.markers), "duplicates": duplicates(final_files, task.files, task.same_name),
             "stops": stops, "seconds": run["seconds"], "load": run["load"], "merge_conflicts": (run.get("merge") or {}).get("conflicts")}
    grade.update(edit_metrics(edits))
    if task.kill:
        grade["kill_fired"] = bool(run["kill"].get("fired"))
        grade["killed_with"] = run["kill"].get("files", [])
    return grade


# ---- not blind: raw streams -----------------------------------------------------------------------------------------

def _obj(line):
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return {}
    return obj if isinstance(obj, dict) else {}


def tool_calls_in_line(line, harness):
    """Tool calls that start on one raw stream line. The runner counts with this to enforce its cap."""
    obj = _obj(line)
    if harness == "claude":
        content = (obj.get("message") or {}).get("content") if obj.get("type") == "assistant" else None
        return sum(1 for b in content if isinstance(b, dict) and b.get("type") == "tool_use") if isinstance(content, list) else 0
    item = obj.get("item") or {}
    return 1 if obj.get("type") == "item.started" and item.get("type") in ("command_execution", "file_change") else 0


def _is_channel(text, condition):
    if condition == "ledger":
        return "COORDINATION.md" in text
    if condition == "agentbus":
        return bool(re.search(r"(?:^|[\s;&|(`'\"/])agentbus(?=[\s'\"]|$)", text))
    return False


def _calls(lines, harness):
    """[(tool name, input as text, result as text)] for each tool call in a stream."""
    calls, by_id = [], {}
    for wrapped in lines:
        obj = _obj(wrapped["line"])
        if harness == "claude":
            content = (obj.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    by_id[b.get("id")] = len(calls)
                    inp = b.get("input") or {}
                    text = inp.get("command", "") if b.get("name") == "Bash" else json.dumps(inp)
                    calls.append([b.get("name", ""), text, ""])
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in by_id:
                    calls[by_id[b["tool_use_id"]]][2] = json.dumps(b.get("content"))
        elif obj.get("type") == "item.completed":
            item = obj.get("item") or {}
            if item.get("type") == "command_execution":
                command = item.get("command", "")
                calls.append(["Bash", " ".join(command) if isinstance(command, list) else command, item.get("aggregated_output", "")])
            elif item.get("type") == "file_change":
                calls.append(["file_change", json.dumps(item.get("changes")), ""])
    return calls


def script_edits(lines, harness, known_paths):
    """[(ts, path)] for edits made by a script. Agents edit through `python3 - <<E` with the path in a variable, which
    normalize.py cannot see: one pilot run showed no edit at all to the file both agents had changed. A call that writes and
    names a repo path counts as an edit of that path."""
    found = []
    for wrapped in lines:
        obj = _obj(wrapped["line"])
        commands = []
        if harness == "claude" and obj.get("type") == "assistant":
            content = (obj.get("message") or {}).get("content")
            commands = [(b.get("input") or {}).get("command", "") for b in content if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash"] if isinstance(content, list) else []
        elif harness == "codex" and obj.get("type") == "item.started" and (obj.get("item") or {}).get("type") == "command_execution":
            command = obj["item"].get("command", "")
            commands = [" ".join(command) if isinstance(command, list) else command]
        for command in commands:
            if SCRIPT_WRITE.search(command):
                found += [(wrapped["ts"], path) for path in sorted(known_paths) if path in command]
    return found


def secret_leaks(auth_path, paths):
    """Names of the files in `paths` holding a credential from auth_path. Compares in memory and never prints a value."""
    with open(auth_path) as f:
        tokens = (json.load(f).get("tokens") or {})
    secrets = [v for v in tokens.values() if isinstance(v, str) and len(v) >= 20]
    found = []
    for path in paths:
        try:
            with open(path, errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        if any(v in text for v in secrets):
            found.append(os.path.basename(path))
    return found


def codex_quota(codex_home):
    """The newest subscription-bucket reading in a CODEX_HOME's rollouts: {"used_percent", "resets_at"} or None. A direct run's
    usage lands in that scratch folder and nowhere else, so the runner reads it itself."""
    newest, when = None, -1.0
    for d, _dirs, files in os.walk(os.path.join(codex_home, "sessions")):
        for name in files:
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            path = os.path.join(d, name)
            mtime = os.path.getmtime(path)
            for line in open(path, errors="replace"):
                payload = _obj(line).get("payload")
                limits = payload.get("rate_limits") if isinstance(payload, dict) else None
                primary = (limits or {}).get("primary") if isinstance(limits, dict) else None
                if limits and limits.get("limit_id") == "codex" and primary and mtime >= when:
                    newest, when = {"used_percent": primary.get("used_percent"), "resets_at": primary.get("resets_at")}, mtime
    return newest


def codex_rollout_usage(codex_home):
    """The newest running totals in a CODEX_HOME's rollouts, shaped like cost_of's usage, or None. Codex's stream reports usage only
    at turn end, so a killed session's stream says 0 while its rollout holds what it spent up to its last completed model call."""
    usage = None
    for d, _dirs, files in os.walk(os.path.join(codex_home, "sessions")):
        for name in files:
            if name.startswith("rollout-") and name.endswith(".jsonl"):
                for line in open(os.path.join(d, name), errors="replace"):
                    payload = _obj(line).get("payload")
                    info = payload.get("info") if isinstance(payload, dict) and payload.get("type") == "token_count" else None
                    total = (info or {}).get("total_token_usage")
                    if total:
                        usage = {"input": total.get("input_tokens", 0) - total.get("cached_input_tokens", 0), "cache_write": 0,
                                 "cache_read": total.get("cached_input_tokens", 0), "output": total.get("output_tokens", 0)}
    return usage


def cost_of(lines, harness, condition):
    """Tokens, tool calls and what the channel itself took. Claude's per-message usage carries only the first streamed fragment of
    the output (575 against a true 3,277 in one run), so the result event's totals win. A killed session has no result event: its
    tokens are summed from messages, which makes them a lower bound, and `complete` is False."""
    usage = {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0}
    cost_usd, complete, model, totals = None, False, None, None
    per_message = {}
    for wrapped in lines:
        obj = _obj(wrapped["line"])
        if harness == "claude":
            if obj.get("type") == "system" and obj.get("subtype") == "init":
                model = obj.get("model")
            message = obj.get("message") or {}
            if obj.get("type") == "assistant" and message.get("usage"):
                per_message[message.get("id")] = message["usage"]
            if obj.get("type") == "result":
                complete, cost_usd, totals = True, obj.get("total_cost_usd"), obj.get("usage")
        elif obj.get("type") == "turn.completed":
            u = obj.get("usage") or {}
            usage["input"] += u.get("input_tokens", 0) - u.get("cached_input_tokens", 0)
            usage["cache_read"] += u.get("cached_input_tokens", 0)
            usage["output"] += u.get("output_tokens", 0)
            complete = True
    for u in [totals] if totals else per_message.values():
        usage["input"] += u.get("input_tokens", 0)
        usage["cache_write"] += u.get("cache_creation_input_tokens", 0)
        usage["cache_read"] += u.get("cache_read_input_tokens", 0)
        usage["output"] += u.get("output_tokens", 0)
    calls = _calls(lines, harness)
    channel = [c for c in calls if is_channel_call(c[0], c[1], condition)]
    return {"model": model, "usage": usage, "cost_usd": cost_usd, "complete": complete, "tool_calls": len(calls),
            "channel_calls": len(channel), "channel_bytes_back": sum(len(c[2]) for c in channel),
            "channel_writes": sum(1 for c in channel if is_channel_write(c[0], c[1], condition)),
            "hooks": hook_report(lines) if harness == "claude" else None, "protocol": protocol_steps(lines, harness, condition)}


def is_channel_call(name, text, condition):
    """A call that uses the channel. Loading a skill is not one, in any condition."""
    if name == "Skill":
        return False
    if condition == "builtin":
        return name in ("ListAgents", "SendMessage")
    return _is_channel(text, condition)


def is_channel_write(name, text, condition):
    """A call that writes to the channel: a real write subcommand of the bus, an append to the ledger, a sent message."""
    if condition == "agentbus":
        return any(verb in BUS_WRITES or (verb == "ctx" and arg == "set") for verb, arg in normalize.bus_commands(text))
    if condition == "ledger":
        return bool(LEDGER_WRITE.search(text)) or (name in EDIT_TOOLS and "COORDINATION.md" in text)
    return name == "SendMessage"


def protocol_steps(lines, harness, condition):
    """Did the session follow the protocol it was given? The same four steps for every channel: read it before the first edit,
    claim before the first edit, release, and finish with a done or handoff. A manipulation check, read from the trace."""
    steps, edited, claimed_first, read_first = {"read": False, "claim": False, "release": False, "finish": False}, False, None, None
    for name, text, _result in _calls(lines, harness):
        is_edit = (name in EDIT_TOOLS and not is_channel_path(text)) or (name == "file_change" and not is_channel_path(text)) or (
            name == "Bash" and any(not is_channel_path(p) and not p.startswith("/dev/") for p in normalize.written_paths(text)))
        if condition == "ledger":
            write = is_channel_write(name, text, condition)
            steps["read"] |= bool(LEDGER_READ.search(text)) or (name == "Read" and "COORDINATION.md" in text)
            steps["claim"] |= write and "CLAIM:" in text
            steps["release"] |= write and "RELEASE:" in text
            steps["finish"] |= write and ("DONE:" in text or "HANDOFF" in text)
        elif condition == "agentbus":
            verbs = [v for v, _a in normalize.bus_commands(text)] if name == "Bash" else []
            steps["read"] |= any(v in ("inbox", "brief", "status", "read") for v in verbs)
            steps["claim"] |= "claim" in verbs
            steps["release"] |= "release" in verbs or "leave" in verbs
            steps["finish"] |= "post" in verbs and bool(re.search(r"--kind[= ]+['\"]?(?:done|handoff)", text))
        elif condition == "builtin":
            steps["read"] |= name == "ListAgents"
            steps["claim"] |= name == "SendMessage"
            steps["release"] = True
            steps["finish"] |= name == "SendMessage" and ("DONE" in text or "HANDOFF" in text)
        if is_edit and not edited:
            edited, read_first, claimed_first = True, steps["read"], steps["claim"]
    return {"read_first": steps["read"] if read_first is None else read_first, "claim_first": True if claimed_first is None else claimed_first,
            "released": steps["release"], "finished": steps["finish"]}


def hook_report(lines):
    """{"started", "failed"} for a Claude session's hooks. A hook fails when it exits non-zero or errors, or when a SessionStart hook,
    which always has something to say, prints nothing."""
    started = failed = 0
    for wrapped in lines:
        obj = _obj(wrapped["line"])
        if obj.get("type") != "system":
            continue
        if obj.get("subtype") == "hook_started":
            started += 1
        elif obj.get("subtype") == "hook_response":
            bad = str(obj.get("exit_code", "0")) != "0" or obj.get("outcome") not in (None, "success")
            silent = obj.get("hook_event") == "SessionStart" and not (obj.get("stdout") or obj.get("output") or "").strip()
            failed += 1 if bad or silent else 0
    return {"started": started, "failed": failed}


def hook_infra(lines, condition):
    """True when a condition's hooks never loaded: no hook started at all. That is infrastructure. A hook that ran is an outcome."""
    return condition in HOOKED and hook_report(lines)["started"] == 0


def codex_hooks_loaded(codex_home, condition):
    """A Codex session's SessionStart hook text in its own session log, since Codex's stream does not report hooks."""
    marker = {"agentbus": re.compile(r"on this folder's bus as"), "ledger": re.compile(r"ledger: (?:COORDINATION\.md has|there is no COORDINATION\.md)")}[condition]
    for d, _dirs, files in os.walk(os.path.join(codex_home, "sessions")):
        for name in files:
            if name.startswith("rollout-") and marker.search(open(os.path.join(d, name), errors="replace").read()):
                return True
    return False


def check_claude_init(lines, condition, tools):
    """Everything wrong with what a Claude session loaded. Empty is clean. Tools come back from the stream, so this tests what
    the session really had, not what we asked for."""
    bad, init, hook_events = [], None, 0
    for wrapped in lines:
        obj = _obj(wrapped["line"])
        if obj.get("type") == "system":
            if obj.get("subtype") == "init" and init is None:
                init = obj
            elif "hook" in str(obj.get("subtype")):
                hook_events += 1
    if init is None:
        return ["no init event"]
    if init.get("mcp_servers"):
        bad.append("MCP servers loaded: %s" % init["mcp_servers"])
    outside = [p.get("name") for p in init.get("plugins") or [] if p.get("path") != "builtin"]
    if outside:
        bad.append("plugins loaded: %s" % outside)
    if set(init.get("tools") or []) != set(tools):
        bad.append("tools were %s, wanted %s" % (sorted(init.get("tools") or []), sorted(tools)))
    skills = set(init.get("skills") or [])
    own = {"ledger": "ledger", "agentbus": "agentbus", "builtin": "peer-messages"}
    for condition_name, skill in own.items():
        if condition_name != condition and skill in skills:
            bad.append("the %s skill loaded in a %s run" % (skill, condition))
    if condition in own and own[condition] not in skills:
        bad.append("the %s skill did not load" % own[condition])
    if condition not in HOOKED and hook_events:
        bad.append("%d hook events in a %s run" % (hook_events, condition))
    return bad


USAGE_LIMIT = re.compile(r"You've hit your (?:\w+ )?limit|usage_limit_reached")


def usage_limited(line):
    """True when a raw stream line is the provider saying the plan's usage limit is reached. Agent text that merely talks about a
    limit does not match: the phrases are the provider's own."""
    return bool(line) and bool(USAGE_LIMIT.search(line))


AUTH_FAILURE = re.compile(r"Failed to authenticate|OAuth session expired|Login expired|Please run /login")


def auth_failed(line):
    """True when a line is the launcher or provider saying the sign-in is gone (the plan's sign-in expired, not its usage). Only the
    provider's own voice counts: an error result, a synthetic assistant message, or a line that is not stream JSON (stderr). A tool
    result or the model's own text that quotes the phrase does not."""
    if not line or not AUTH_FAILURE.search(line):
        return False
    try:
        event = json.loads(line)
    except ValueError:
        return True
    if not isinstance(event, dict):
        return False
    if event.get("type") == "result":
        return bool(event.get("is_error")) and bool(AUTH_FAILURE.search(str(event.get("result", ""))))
    message = event.get("message")
    if event.get("type") == "assistant" and isinstance(message, dict) and message.get("model") == "<synthetic>":
        return bool(AUTH_FAILURE.search(json.dumps(message.get("content"))))
    return False


def infra_failure(lines, harness, rc, killed_by_task, stop_reason, stderr_lines=()):
    """A run may be replaced only for one of these (docs/evals/value-protocol.md, Dropping runs). None is a real run, whatever
    its outcome. Timeouts and tool caps are real runs. A sign-in failure in the provider's own voice (stream or stderr) is
    infrastructure whether or not the agent had made tool calls: it is the plan's sign-in, not the agent's work."""
    if killed_by_task or stop_reason:
        return None
    if any(auth_failed(w["line"]) for w in lines) or any(auth_failed(line) for line in stderr_lines):
        return "authentication failed"
    if not any(tool_calls_in_line(w["line"], harness) for w in lines):
        text = " ".join(w["line"] for w in lines)[-2000:]
        if rc != 0 or re.search(r"authentication|not logged in|overloaded|rate.?limit|usage limit|api error|hit your", text, re.I):
            return "no tool call and rc %s" % rc
    return None


def regrade_infra(out, write=False):
    """The current infrastructure rule applied to the manifest rows of runs already made: a row with no infrastructure failure whose
    agent's own stream or stderr carries a sign-in failure gets one. Rows already flagged, and every other row, are untouched; the
    run folders are only read. Returns {run id: {role: reason}} for the rows that change; write=True saves the manifest."""
    path = os.path.join(out, "manifest.jsonl")
    with open(path) as f:
        rows = [json.loads(line) for line in f]
    changed = {}
    for row in rows:
        if row["infra"] or row["isolation"]:
            continue
        with open(os.path.join(out, row["id"], "run.json")) as f:
            agents = json.load(f)["agents"]
        for role, a in sorted(agents.items()):
            with open(os.path.join(out, row["id"], "trace-%s.jsonl" % role), errors="replace") as f:
                lines = [json.loads(line) for line in f]
            err_path = os.path.join(out, row["id"], "stderr-%s.txt" % role)
            with open(err_path, errors="replace") as f:
                stderr_lines = [line.rstrip("\n") for line in f] if os.path.exists(err_path) else []
            why = infra_failure(lines, a["harness"], a["rc"], a["stop"] == "task_kill", a["stop"], stderr_lines)
            if why:
                row["infra"][role] = why
                changed.setdefault(row["id"], {})[role] = why
    if write and changed:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
        os.replace(tmp, path)
    return changed


def main(argv):
    """grade.py OUT grades every run folder. grade.py OUT --infra then applies the current infrastructure rule to the manifest."""
    out = argv[0]
    graded = 0
    for name in sorted(os.listdir(out)):
        run_dir = os.path.join(out, name)
        if os.path.isfile(os.path.join(run_dir, "run.json")):
            write_json(os.path.join(run_dir, "grade.json"), blind_grade(run_dir))
            graded += 1
    print("graded %d runs" % graded)
    if "--infra" in argv[1:]:
        changed = regrade_infra(out, write=True)
        for rid, why in sorted(changed.items()):
            print("infrastructure: %s %s" % (rid, why))
        print("regraded the manifest: %d runs now infrastructure" % len(changed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
