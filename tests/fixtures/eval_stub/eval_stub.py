"""A stand-in for the `claude` and `codex` commands, so tests/test_eval_harness.sh can run scripts/agent-eval.sh
with no agent and no tokens. It does the scenario's work for real (bus commands through agentbus on PATH,
file edits in the project) and prints the event stream the real harness would: Claude Code stream-json or
`codex exec --json` lines. EVAL_ROLE and EVAL_SCENARIO say who it plays. EVAL_STUB_MISBEHAVE changes one habit:
  edit-first   the agent edits before it reads its inbox (handoff and resume)
  no-done      the agent never posts done (handoff)
  ignore-conflict   bob edits lib/ after his claim was refused, without waiting for alice (conflict)
  side-bus     the lead makes a second bus in the folder of worktrees and posts there (worktrees)
"""
import json
import os
import subprocess
import sys
import time

fmt = sys.argv[1]
role, scenario = os.environ["EVAL_ROLE"], os.environ["EVAL_SCENARIO"]
bad = os.environ.get("EVAL_STUB_MISBEHAVE", "")
BUS = "agentbus"  # the tool under test, on the PATH the harness gives the agent; never the project copy
n = [0]


def emit(obj):
    print(json.dumps(obj), flush=True)


SIDE = [None]  # the bus database a misbehaving lead points AGENTBUS_DB at


def bus(*args):
    cmd = "%s --as %s %s" % (BUS, role, " ".join(args))
    if SIDE[0]:
        cmd = "AGENTBUS_DB=%s %s" % (SIDE[0], cmd)
    return run(cmd)


def run(cmd):
    n[0] += 1
    if fmt == "claude":
        emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t%d" % n[0], "name": "Bash", "input": {"command": cmd}}]}})
    else:
        emit({"type": "item.started", "item": {"id": "i%d" % n[0], "type": "command_execution", "command": "bash -lc '%s'" % cmd, "status": "in_progress"}})
    p = subprocess.run(["sh", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if fmt == "claude":
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t%d" % n[0], "is_error": p.returncode != 0, "content": p.stdout}]}})
    else:
        emit({"type": "item.completed", "item": {"id": "i%d" % n[0], "type": "command_execution", "command": "bash -lc '%s'" % cmd,
                                                  "aggregated_output": p.stdout, "exit_code": p.returncode, "status": "completed" if p.returncode == 0 else "failed"}})
    return p


def edit(path, text, append=False):
    n[0] += 1
    if fmt == "claude":
        emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t%d" % n[0], "name": "Write", "input": {"file_path": os.path.abspath(path)}}]}})
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a" if append else "w") as f:
        f.write(text)
    if fmt == "claude":
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t%d" % n[0], "content": "ok"}]}})
    else:
        emit({"type": "item.completed", "item": {"id": "i%d" % n[0], "type": "file_change", "changes": [{"path": os.path.abspath(path), "kind": "update"}], "status": "completed"}})


def finish(text):
    if fmt == "claude":
        emit({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
        emit({"type": "result", "result": text})
    else:
        emit({"type": "item.completed", "item": {"id": "m", "type": "agent_message", "text": text}})


def held_by_other(resource):
    return resource in subprocess.run(["sh", "-c", "%s claims" % BUS], stdout=subprocess.PIPE, text=True).stdout


if scenario == "handoff" and role == "alice":
    bus("join")
    bus("post", "'Add GET /health to app.py returning (200, \"ok\"); check: python3 -m unittest tests/test_health.py'", "--to bob", "--kind handoff")
    bus("leave")
    finish("Handed the health route to bob.")
elif scenario == "handoff" and role == "bob":
    bus("join")
    if bad != "edit-first":
        bus("inbox")
    bus("claim", "app.py", "--purpose health")
    edit("app.py", 'def handle(path):\n    if path == "/health":\n        return 200, "ok"\n    return 404, "not found"\n')
    if bad == "edit-first":
        bus("inbox")
    bus("release", "app.py")
    if bad != "no-done":
        bus("post", "'health route done'", "--to alice", "--kind done")
    bus("leave")
    finish("Added the health route.")
elif scenario == "conflict":
    other_first = role == "bob"
    sync = os.environ["EVAL_SYNC_DIR"]  # alice and bob hand each other signals through files, never through sleeps
    os.makedirs(sync, exist_ok=True)

    def signal(name):
        open(os.path.join(sync, name), "w").close()

    def wait_for(name):
        for _ in range(600):
            if os.path.exists(os.path.join(sync, name)):
                return
            time.sleep(0.05)
        sys.exit("never saw signal " + name)

    bus("join")
    if other_first:
        wait_for("alice-claimed")
        bus("claim", "lib/")  # refused while alice holds it
        signal("bob-refused")
        for _ in range(300 if bad != "ignore-conflict" else 0):
            if not held_by_other("lib/"):
                break
            time.sleep(0.1)
        if bad != "ignore-conflict":
            bus("claim", "lib/")
    else:
        bus("claim", "lib/")
        signal("alice-claimed")
        wait_for("bob-refused")  # bob has tried for lib/ and been refused while alice still holds it
    name = "alpha" if role == "alice" else "beta"
    edit("lib/%s.py" % name, 'def %s():\n    return "%s"\n' % (name, name))
    edit("lib/__init__.py", "from .%s import %s\n" % (name, name), append=True)
    bus("release", "lib/")
    bus("leave")
    finish("Added lib/%s.py." % name)
elif scenario == "resume":
    bus("join")
    if bad != "edit-first":
        bus("status")
        bus("inbox")
    bus("claim", "src/export.py")
    edit("src/export.py", 'def export_invoices(rows):\n    return "".join("%s,%s\\n" % r for r in rows)\n')
    if bad == "edit-first":
        bus("status")
        bus("inbox")
    bus("post", "'export done'", "--kind done")
    bus("leave")
    finish("Continuing the goal to ship the invoice export: export_invoices is done and its test passes.")
elif scenario == "worktrees":
    wts = os.path.join(os.path.dirname(os.getcwd()), "wts")   # the lanes' folder sits beside the project
    if bad == "side-bus":
        run("agentbus init %s --second-bus" % wts)
        SIDE[0] = os.path.join(wts, ".agentbus", "bus.db")
    bus("join")
    bus("post", "'lane-a: add src/a.py; check: python3 -c \"import src.a\"'", "--to lane-a", "--kind handoff")
    bus("post", "'lane-b: add src/b.py; check: python3 -c \"import src.b\"'", "--to lane-b", "--kind handoff")
    bus("leave")
    finish("Told lane-a and lane-b their files.")
