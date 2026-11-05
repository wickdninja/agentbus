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
import tasks  # noqa: E402

TEXT_SUFFIXES = (".py", ".md", ".txt", ".feed", ".json", ".toml", ".cfg", "")
HIDDEN_TIMEOUT = 120


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
             "stops": stops, "seconds": run["seconds"], "load": run["load"]}
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
                    calls.append([b.get("name", ""), json.dumps(b.get("input") or {}), ""])
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


def cost_of(lines, harness, condition):
    """Tokens, tool calls and what the channel itself took. A killed agent has no final summary, so tokens are summed from
    each message; `complete` says whether the stream ended with its own totals."""
    usage = {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0}
    cost_usd, complete, model = None, False, None
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
                complete, cost_usd = True, obj.get("total_cost_usd")
        elif obj.get("type") == "turn.completed":
            u = obj.get("usage") or {}
            usage["input"] += u.get("input_tokens", 0) - u.get("cached_input_tokens", 0)
            usage["cache_read"] += u.get("cached_input_tokens", 0)
            usage["output"] += u.get("output_tokens", 0)
            complete = True
    for u in per_message.values():
        usage["input"] += u.get("input_tokens", 0)
        usage["cache_write"] += u.get("cache_creation_input_tokens", 0)
        usage["cache_read"] += u.get("cache_read_input_tokens", 0)
        usage["output"] += u.get("output_tokens", 0)
    calls = _calls(lines, harness)
    channel = [c for c in calls if c[0] in ("ListAgents", "SendMessage") or _is_channel(c[1], condition)]
    if condition == "builtin":
        channel = [c for c in calls if c[0] in ("ListAgents", "SendMessage")]
    return {"model": model, "usage": usage, "cost_usd": cost_usd, "complete": complete, "tool_calls": len(calls),
            "channel_calls": len(channel), "channel_bytes_back": sum(len(c[2]) for c in channel),
            "channel_writes": sum(1 for c in channel if re.search(r"post|claim|ctx set|>>|SendMessage|\"message\"", c[0] + c[1]))}


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
    if condition != "agentbus" and hook_events:
        bad.append("%d hook events in a %s run" % (hook_events, condition))
    if condition == "agentbus" and not hook_events:
        bad.append("no hook fired in an agentbus run")
    return bad


def infra_failure(lines, harness, rc, killed_by_task, stop_reason):
    """A run may be replaced only for one of these (docs/evals/value-protocol.md, Dropping runs). None is a real run, whatever
    its outcome. Timeouts and tool caps are real runs."""
    if killed_by_task or stop_reason:
        return None
    if not any(tool_calls_in_line(w["line"], harness) for w in lines):
        text = " ".join(w["line"] for w in lines)[-2000:]
        if rc != 0 or re.search(r"authentication|not logged in|overloaded|rate.?limit|usage limit|api error|hit your", text, re.I):
            return "no tool call and rc %s" % rc
    return None


def main(argv):
    out = argv[0]
    graded = 0
    for name in sorted(os.listdir(out)):
        run_dir = os.path.join(out, name)
        if os.path.isfile(os.path.join(run_dir, "run.json")):
            write_json(os.path.join(run_dir, "grade.json"), blind_grade(run_dir))
            graded += 1
    print("graded %d runs" % graded)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
