"""A stand-in for Claude Code and Codex in the value eval: no tokens. It plays the reference solution from scripts/value-eval/tasks.py
and speaks each harness's stream format, so the whole runner, the isolation checks and the graders run in CI.

VALUE_STUB_MODE picks a behaviour: good (default), clobber (bob overwrites alice's file with the base), lazy (does nothing),
hang (never exits), spam (tool calls forever), hook-leak (reports a hook firing), plugin-leak (reports a user plugin),
env-dump (writes its environment's names to VALUE_STUB_ENV_OUT and plays good), auth-fail (a sign-in error and no tool call),
conflict (each role writes its own VERSION), leak-token, auth-refresh, auth-report (Codex sign-in faults and a report on the copy), codex-hooks, codex-skill, codex-state
(a planted hook or skill, and the state Codex makes for itself), usage-limit (a plan limit, after VALUE_STUB_LIMIT_AFTER tool calls), auth-expired (the sign-in expired: in the stream, or with VALUE_STUB_AUTH_STDERR=1 on stderr only), no-hooks, hook-fail (hook outcomes), settings-report (hook install), break-link (bob replaces his ledger link), settings-write (touches the file VALUE_STUB_REAL_SETTINGS names), bus-in-none (makes a .agentbus folder),
live-steal and live-wait (livehold: alice claims src/rates.py and keeps working; bob takes her claim while she is alive, or waits for her release),
say-only (abandoned, finished: bob writes OPEN.md and finishes nothing), give-up (alice stops before her first item is in).
"""
import json
import os
import subprocess
import sys
import time

harness, argv = sys.argv[1], sys.argv[2:]
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["VALUE_SCRIPTS"])
import tasks  # noqa: E402

role, task_name, seed = os.environ["VALUE_ROLE"], os.environ["VALUE_TASK"], int(os.environ["VALUE_SEED"])
condition, mode = os.environ["VALUE_CONDITION"], os.environ.get("VALUE_STUB_MODE", "good")
if os.environ.get("VALUE_STUB_ONLY_ROLE") not in (None, role):
    mode = "good"
tool_id = [0]


def emit(obj):
    print(json.dumps(obj), flush=True)


def init():
    if os.environ.get("VALUE_STUB_SLOW_INIT") == role:   # this agent says nothing for a while, so a halt can land first
        time.sleep(3)
    if harness != "claude":
        emit({"type": "thread.started"})
        return
    tools = argv[argv.index("--tools") + 1].split(",")
    skills = {"ledger": ["ledger"], "agentbus": ["agentbus"], "builtin": ["peer-messages"]}.get(condition, [])
    plugins = [{"name": "cc-plugin-privacy", "path": "builtin"}]
    if mode == "plugin-leak":
        plugins.append({"name": "agentbus", "path": "/home/user/plugin"})
    emit({"type": "system", "subtype": "init", "model": "stub-model", "tools": tools, "skills": skills, "plugins": plugins, "mcp_servers": []})
    if (condition in ("agentbus", "ledger") and mode != "no-hooks") or mode == "hook-leak":
        emit({"type": "system", "subtype": "hook_started", "hook_name": "SessionStart:startup", "hook_event": "SessionStart"})
        emit({"type": "system", "subtype": "hook_response", "hook_event": "SessionStart", "exit_code": "1" if mode == "hook-fail" else "0",
              "outcome": "error" if mode == "hook-fail" else "success", "stdout": "" if mode == "hook-fail" else "{}"})


def bash(command):
    tool_id[0] += 1
    i = "t%d" % tool_id[0]
    if harness == "claude":
        emit({"type": "assistant", "message": {"id": "m" + i, "usage": {"input_tokens": 10, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 1000, "output_tokens": 20},
                                               "content": [{"type": "tool_use", "id": i, "name": "Bash", "input": {"command": command}}]}})
    else:
        emit({"type": "item.started", "item": {"id": i, "type": "command_execution", "command": command}})
    p = subprocess.run(["/bin/sh", "-c", command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if harness == "claude":
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": p.stdout, "is_error": p.returncode != 0}]}})
    else:
        emit({"type": "item.completed", "item": {"id": i, "type": "command_execution", "command": command, "exit_code": p.returncode, "aggregated_output": p.stdout}})


def tool(name, payload):
    tool_id[0] += 1
    i = "t%d" % tool_id[0]
    emit({"type": "assistant", "message": {"id": "m" + i, "usage": {"input_tokens": 1, "output_tokens": 2}, "content": [{"type": "tool_use", "id": i, "name": name, "input": payload}]}})
    emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": "ok"}]}})


def write(rel, text):
    tool_id[0] += 1
    i = "t%d" % tool_id[0]
    if text is None:
        return
    d = os.path.dirname(rel)
    if d:
        os.makedirs(d, exist_ok=True)
    if harness == "claude":
        emit({"type": "assistant", "message": {"id": "m" + i, "usage": {"input_tokens": 10, "output_tokens": 20}, "content": [{"type": "tool_use", "id": i, "name": "Write", "input": {"file_path": os.path.abspath(rel), "content": text}}]}})
    with open(rel, "w") as f:
        f.write(text)
    if harness == "claude":
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": "written"}]}})
    else:
        emit({"type": "item.completed", "item": {"id": i, "type": "file_change", "status": "completed", "changes": [{"path": os.path.abspath(rel), "kind": "add"}]}})


def channel(text):
    if condition == "ledger":
        bash("printf '%%s\\n' '%s NOTE: %s' >> COORDINATION.md" % (role, text))
    elif condition == "agentbus":
        bash("agentbus --as %s join && agentbus --as %s post '%s' && agentbus --as %s leave" % (role, role, text, role))
    elif condition == "builtin":
        tool("ListAgents", {})
        tool("SendMessage", {"to": "peer", "message": text})


def finish():
    if harness == "claude":
        emit({"type": "result", "subtype": "success", "is_error": False, "total_cost_usd": 0.01, "result": "done"})
    else:
        emit({"type": "turn.completed", "usage": {"input_tokens": 500, "cached_input_tokens": 400, "output_tokens": 50}})


if mode == "auth-fail":
    emit({"type": "result", "subtype": "error", "is_error": True, "result": "Not logged in: authentication required"})
    sys.exit(1)
init()
if mode == "env-dump":
    with open(os.environ["VALUE_STUB_ENV_OUT"], "a") as f:
        f.write("\n".join(sorted(os.environ)) + "\n")
if mode == "settings-write":
    with open(os.environ["VALUE_STUB_REAL_SETTINGS"], "a") as f:
        f.write("\n")
if mode == "bus-in-none":
    os.makedirs(".agentbus")
if harness == "codex" and os.environ.get("VALUE_STUB_QUOTA_FILE"):
    counter = os.environ["VALUE_STUB_QUOTA_FILE"]
    used = (int(open(counter).read()) if os.path.exists(counter) else 50) + 30
    open(counter, "w").write(str(used))
    os.makedirs(os.path.join(os.environ["CODEX_HOME"], "sessions"), exist_ok=True)
    with open(os.path.join(os.environ["CODEX_HOME"], "sessions", "rollout-stub.jsonl"), "w") as f:
        f.write(json.dumps({"payload": {"rate_limits": {"limit_id": "codex", "primary": {"used_percent": used, "resets_at": 1}}}}) + "\n")
if harness == "codex" and condition in ("agentbus", "ledger") and mode != "no-hooks":
    os.makedirs(os.path.join(os.environ["CODEX_HOME"], "sessions"), exist_ok=True)
    with open(os.path.join(os.environ["CODEX_HOME"], "sessions", "rollout-hooks.jsonl"), "w") as f:
        f.write(json.dumps({"payload": {"text": "agentbus: you are on this folder's bus as x" if condition == "agentbus" else "ledger: COORDINATION.md has 0 entries"}}) + "\n")
if harness == "codex" and os.environ.get("VALUE_STUB_ROLLOUT"):
    os.makedirs(os.path.join(os.environ["CODEX_HOME"], "sessions"), exist_ok=True)
    with open(os.path.join(os.environ["CODEX_HOME"], "sessions", "rollout-tokens.jsonl"), "w") as f:
        f.write(json.dumps({"payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 1000, "cached_input_tokens": 900, "output_tokens": 50}}}}) + "\n")
if harness == "codex" and mode == "leak-token":
    print(json.dumps(json.load(open(os.path.join(os.environ["CODEX_HOME"], "auth.json")))), flush=True)
if harness == "codex" and mode == "codex-hooks":
    with open(os.path.join(os.environ["CODEX_HOME"], "hooks.json"), "w") as f:
        f.write("{}")
if harness == "codex" and mode == "codex-skill":
    os.makedirs(os.path.join(os.environ["CODEX_HOME"], "skills", "agentbus"))
if harness == "codex" and mode == "codex-state":
    os.makedirs(os.path.join(os.environ["CODEX_HOME"], "skills", ".system"))
    open(os.path.join(os.environ["CODEX_HOME"], "state_9.sqlite"), "w").close()
    open(os.path.join(os.environ["CODEX_HOME"], "thread-writer-locks"), "w").close()
if harness == "codex" and mode == "auth-refresh":
    with open(os.path.join(os.environ["CODEX_HOME"], "auth.json"), "a") as f:
        f.write(" ")
if harness == "codex" and mode == "auth-report":
    auth = os.path.join(os.environ["CODEX_HOME"], "auth.json")
    with open(os.environ["VALUE_STUB_ENV_OUT"], "w") as f:
        f.write("%s %o\n" % (os.path.islink(auth), os.stat(auth).st_mode & 0o777))
if mode == "settings-report":
    hooks = json.load(open(".claude/settings.json"))["hooks"] if os.path.exists(".claude/settings.json") else {}
    home = sorted(os.listdir(os.environ["CODEX_HOME"])) if harness == "codex" else []
    with open(os.environ["VALUE_STUB_ENV_OUT"], "a") as f:
        f.write(json.dumps({"role": role, "harness": harness, "events": sorted(hooks), "ledger_hook": "ledger_hook.py" in json.dumps(hooks),
                            "name": os.environ.get("LEDGER_NAME"), "codex_home": home, "argv_trust": "--dangerously-bypass-hook-trust" in argv}) + "\n")
if mode == "break-link" and role == "bob":
    os.remove("COORDINATION.md")
    open("COORDINATION.md", "w").write("10:00 bob NOTE: my own copy\n")
if mode == "usage-limit" and os.environ.get("VALUE_STUB_LIMIT_ROLE", role) == role:
    for _ in range(int(os.environ.get("VALUE_STUB_LIMIT_AFTER", "0"))):
        bash("true")
    if os.environ.get("VALUE_STUB_LIMIT_STDERR"):   # the limit only on stderr, after the tool calls
        sys.stderr.write("You've hit your weekly limit \u00b7 resets Nov 8 at 5am\n")
        finish()
        sys.exit(0)
    emit({"type": "assistant", "message": {"id": "lim", "model": "<synthetic>", "content": [{"type": "text", "text": "You've hit your weekly limit \u00b7 resets Nov 8 at 5am"}]}})
    emit({"type": "result", "subtype": "success", "is_error": True, "result": "You've hit your weekly limit"})
    sys.exit(1)
if mode == "auth-expired" and os.environ.get("VALUE_STUB_LIMIT_ROLE", role) == role:
    if os.environ.get("VALUE_STUB_AUTH_STDERR"):
        sys.stderr.write("Please run /login\n")
        sys.exit(1)
    emit({"type": "assistant", "message": {"id": "exp", "model": "<synthetic>", "content": [{"type": "text", "text": "Failed to authenticate: OAuth session expired and could not be refreshed"}]}})
    emit({"type": "result", "subtype": "success", "is_error": True, "result": "Failed to authenticate: OAuth session expired and could not be refreshed"})
    sys.exit(1)
if mode == "hang":
    time.sleep(3600)
if mode == "spam":
    while True:
        bash("true")
if mode == "lazy":
    finish()
    sys.exit(0)



def live(mode):
    """livehold with real claims, on the bus or the ledger: alice holds src/rates.py across two edits; bob takes it from her while she
    is alive (live-steal) or waits until she lets it go (live-wait). Both end with every hidden test passing."""
    bus = condition == "agentbus"
    note = lambda kind, text: bash("printf '\\n%%s %s %s: %s\\n' \"$(date +%%H:%%M:%%S)\" >> COORDINATION.md" % (role, kind, text))  # noqa: E731
    if role == "alice":
        bash("agentbus --as alice join && agentbus --as alice claim src/rates.py --purpose steps") if bus else note("CLAIM", "src/rates.py (steps)")
        mine = tasks.livehold_alice_reference(seed)["src/rates.py"]
        write("src/rates.py", mine)
        time.sleep(3)
        write("src/rates.py", mine)
        time.sleep(3)
        bash("agentbus --as alice leave") if bus else note("RELEASE", "src/rates.py")
        return
    bash("agentbus --as bob join") if bus else note("JOIN", "promo codes")
    if mode == "live-steal":
        time.sleep(4)
        bash("agentbus --as bob claim src/rates.py --from alice --purpose promo") if bus else note("CLAIM", "src/rates.py (promo)")
    else:
        bash("until ! agentbus claims | grep -q alice; do sleep 0.3; done; agentbus --as bob claim src/rates.py --purpose promo" if bus else
             "until grep -q 'alice RELEASE' COORDINATION.md; do sleep 0.3; done")
        if not bus:
            note("CLAIM", "src/rates.py (promo)")
    for rel, text in tasks.reference(task_name, seed).items():
        write(rel, text)
    bash("agentbus --as bob leave") if bus else note("RELEASE", "src/rates.py")


def handover():
    """abandoned and finished: alice promises her three items in the channel and does them in order (the runner kills her in abandoned
    once the first passes); bob reads what is still undone off the tree, names it in OPEN.md and finishes it, unless he only says it."""
    mine = tasks.abandoned_ids(seed)[0]
    stamp = "\"$(date +%H:%M:%S)\""
    if role == "alice":
        for i, r in enumerate(tasks.ITEM_ROLES, 1):   # the bus is fresh, so her three todos are messages 1 to 3
            if condition == "ledger":
                bash("printf '\\n%%s alice TODO alice-%d: %s\\n' %s >> COORDINATION.md" % (i, mine[r], stamp))
            elif condition == "agentbus":
                bash("agentbus --as alice join >/dev/null; agentbus --as alice post '%s' --kind todo" % mine[r])
        if mode == "give-up":   # alice stops before her first item is in: the kill never fires
            return
        for i, r in enumerate(tasks.ITEM_ROLES, 1):
            spec = "%s/%s.md" % (tasks.SPEC_DIR, mine[r])
            waited = time.time()
            while not os.path.exists(spec) and time.time() - waited < 30:   # the runner hands her each spec once the one before is in
                time.sleep(0.2)
            bash("cat %s" % spec)
            for rel, text in tasks.abandoned_item_reference(seed, r).items():
                write(rel, text)
            if task_name == "abandoned":
                if os.environ.get("VALUE_STUB_LATE_FILE"):   # a command still running when she dies, in a session of its own
                    subprocess.Popen(["/bin/sh", "-c", "sleep 4; echo late > %s" % os.environ["VALUE_STUB_LATE_FILE"]], start_new_session=True)
                time.sleep(10)   # the kill lands here, between the first item and the second
            elif condition == "ledger":
                bash("printf '\\n%%s alice DONE alice-%d: in\\n' %s >> COORDINATION.md" % (i, stamp))
            elif condition == "agentbus":
                bash("agentbus --as alice post 'in' --kind done --reply-to %d" % i)
        return
    import grade
    left = [r for r in tasks.ITEM_ROLES if r not in grade.items_done(os.getcwd(), task_name, seed)]
    write("OPEN.md", "".join("%s\n" % mine[r] for r in left))
    if mode != "say-only":
        for r in left:
            for rel, text in tasks.abandoned_item_reference(seed, r).items():
                write(rel, text)
    channel("done")


if task_name in tasks.FOLLOWUP_TODO:
    handover()
    finish()
    sys.exit(0)
if task_name == "livehold" and mode in ("live-steal", "live-wait"):
    live(mode)
    finish()
    sys.exit(0)
channel("starting")
ref = tasks.reference(task_name, seed)
if task_name == "livehold" and role == "alice":
    ref = tasks.livehold_alice_reference(seed)
task = tasks.build(task_name, seed)
if task_name == "recovery" and role == "alice":
    wanted = sorted(k for k in ref if k.startswith("src/") and not k.endswith("__init__.py"))[:3]
    for rel in wanted:
        write(rel, ref[rel])
    time.sleep(60)       # the runner's kill is what ends this session
elif mode == "conflict":
    write("VERSION", "9.%s.0\n" % ("1" if role == "alice" else "2"))
elif mode == "clobber" and role == "bob":
    time.sleep(float(os.environ.get("VALUE_STUB_CLOBBER_AFTER", "1.5")))
    path = [k for k in task.files if k.endswith("pipeline.py")][0]
    write(path, task.files[path])
elif mode == "clobber":
    for rel, text in ref.items():
        write(rel, text)
    time.sleep(0.5)
else:
    for rel, text in ref.items():
        write(rel, text)
channel("done")
finish()
