#!/usr/bin/env python3
"""Value eval runner: does agentbus add anything over a flat file? Protocol: docs/evals/value-protocol.md.

One run builds a seeded repo in mktemp, installs one condition's channel, runs the task's agents to a schedule under
time and tool caps, then keeps the traces, the final tree and snapshots in --out. Nothing here grades: grade.py does,
blind to condition, from what this collected.

A real agent never sees the caller's environment or config. Claude is the first-party binary, started by --claude-launcher (a command
that gives it a throwaway config folder and an existing sign-in, and runs `claude` from PATH), through a shim that swaps in a temp HOME
and an allowlisted environment. Every run ends in isolation checks, and one failure stops the batch.
"""
import argparse
import glob
import hashlib
import json
import os
import random
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "scripts", "agent-eval"))
import analyze  # noqa: E402
import grade  # noqa: E402
import normalize  # noqa: E402
import tasks  # noqa: E402

PAIRINGS = ("cc", "cx")
BASE_TOOLS = ["Bash", "Read", "Edit", "Write", "Skill"]
BUILTIN_TOOLS = ["ListAgents", "SendMessage", "ToolSearch"]
CLAUDE_MODEL, CODEX_MODEL = "sonnet", "gpt-6.1-sol"
TIME_CAP, TOOL_CAP, SNAP_EVERY = 2400, 80, 5
CODEX_PLANTED = {"auth.json", "hooks.json", "AGENTS.md", "config.toml"}   # all a scratch CODEX_HOME may hold before launch; Codex adds its own state after
TOOL_RELEASE = "02fcfc5"     # follow-up fix1 tests v0.3.0 (the counted run tested 642009c): runs refuse any other bin/agentbus
TOOL_SHA256 = "c6f3e9a88e5661380ea06c2365d19aaa7ee2eb338f705560d3677c8cea0f8808"   # sha256 of 02fcfc5:bin/agentbus, checked as well
# Follow-up abandoned tests the todo build, which is not released: (commit on main, sha256 of its bin/agentbus). This one constant is
# the pin; a change to it is its own commit, logged in the protocol, and the parity test then checks the ledger text against its skill.
TODO_TOOL = ("975ba7a", "a74008d1c02c61e971e31b095a66cd856ff0c0f1f43a3faed2c1a15d92b6cdb1")
CODEX_BUDGET = 40            # usage points; the batch halts when projected use passes this
CHANNEL_PATHS = grade.CHANNEL_PATHS
CODEX_FEATURE_PINS = ("multi_agent", "plugins", "apps", "browser_use", "computer_use")
GIT = ["git", "-c", "user.name=eval", "-c", "user.email=eval@example.com"]


class IsolationError(Exception):
    pass


class Refused(Exception):
    pass


def log(msg):
    print(msg, flush=True)


def forbidden_roots():
    roots = [ROOT, os.path.join(os.path.expanduser("~"), "src")]
    extra = os.environ.get("VALUE_FORBIDDEN_ROOT")
    return [os.path.realpath(r) for r in roots + ([extra] if extra else [])]


def assert_outside(path):
    """Nothing a run does may happen under ~/src or the checkout: a stray bus or git command there is the known accident."""
    real = os.path.realpath(path)
    for bad in forbidden_roots():
        if real == bad or real.startswith(bad + os.sep):
            raise Refused("%s is inside %s; a run lives in mktemp. Set TMPDIR elsewhere." % (real, bad))
    return real


def sha_file(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def bus_roster(db):
    if not db or not os.path.exists(db):
        return None
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        return sorted(r[0] for r in con.execute("SELECT name FROM agents"))
    finally:
        con.close()


def tool_is_release(root, release, path=None):
    """True when the tool at path (the checkout's bin/agentbus by default) is byte for byte the release's bin/agentbus."""
    path = path or os.path.join(root, "bin", "agentbus")
    p = subprocess.run(["git", "-C", root, "show", "%s:bin/agentbus" % release], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode == 0 and os.path.isfile(path) and p.stdout == open(path, "rb").read()


def tool_pinned(root, release, sha256, path=None):
    """The release's bytes and the pinned hash, both: a tag moved later cannot change what a run tested."""
    return tool_is_release(root, release, path) and sha_file(path or os.path.join(root, "bin", "agentbus")) == sha256


# The registered configuration of a study, fixed for its real runs: the build under test, the Codex budget in points and the Claude
# usage stop in percent. Real runs refuse any flag that would change one, and an output folder keeps the first values in study.json,
# so a resumed batch must match them and goes on counting its budgets from where the batch started.
STUDIES = {"todo": {"pin": TODO_TOOL, "codex_budget": 15, "claude_usage_stop": 90.0}}


def check_study(out, key):
    """The study record in out: written by the first run, then every later run must match it. Returns the record."""
    path = os.path.join(out, "study.json")
    want = {"study": key, "pin": list(STUDIES[key]["pin"]), "codex_budget": STUDIES[key]["codex_budget"],
            "claude_usage_stop": STUDIES[key]["claude_usage_stop"]}
    if not os.path.exists(path):
        grade.write_json(path, dict(want, codex_start=None, claude_start=None))
        return dict(want, codex_start=None, claude_start=None)
    with open(path) as f:
        rec = json.load(f)
    differ = sorted(k for k in want if rec.get(k) != want[k])
    if differ:
        raise Refused("%s was started with another %s; a resumed batch must keep the study's configuration" % (out, ", ".join(differ)))
    return rec


def note_study(out, rec, field, value):
    """Keep the first budget reading of the batch, across resumes."""
    if rec is not None and rec.get(field) is None and value is not None:
        rec[field] = value
        grade.write_json(os.path.join(out, "study.json"), rec)


def pins_for(task_objs):
    """(release, sha256) the batch's tasks run with: the todo build for follow-up abandoned, v0.3.0 otherwise. One batch, one pin."""
    kinds = {t.channel_text for t in task_objs}
    if len(kinds) > 1:
        raise Refused("this batch mixes tasks that test different builds of the tool (%s); run them as separate batches" % ", ".join(sorted(kinds)))
    return TODO_TOOL if kinds == {"todo"} else (TOOL_RELEASE, TOOL_SHA256)


def descendants(pid):
    """Every process below pid, from one `ps` listing: children, their children, and so on."""
    p = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid="], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
    below = {}
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            below.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, todo = [], [pid]
    while todo:
        for child in below.get(todo.pop(), []):
            if child not in found and child != os.getpid():
                found.append(child)
                todo.append(child)
    return found


WATCH_INTERVAL = 0.5   # seconds between the item watch's looks, fixed whatever a check takes


def next_tick(t0, now, interval):
    """The first tick of the schedule t0, t0 + interval, ... that is after now."""
    return t0 + interval * (int((now - t0) // interval) + 1)


def harness_of(pairing, role, seed):
    """cc: both Claude. cx: which harness plays which role alternates by seed."""
    if pairing == "cc":
        return "claude"
    first = "claude" if seed % 2 == 0 else "codex"
    other = "codex" if first == "claude" else "claude"
    return first if role == "alice" else other


def allowed_tools(condition):
    return BASE_TOOLS + (BUILTIN_TOOLS if condition == "builtin" else [])


def claude_settings(root, condition):
    """Passed with --settings: sandbox on, no way out of it, and no auto-memory, which would be a side channel."""
    settings = {"autoMemoryEnabled": False,
                "sandbox": {"enabled": True, "allowUnsandboxedCommands": False, "autoAllowBashIfSandboxed": True,
                            "filesystem": {"allowWrite": [root]}}}
    if condition == "builtin":
        settings["crossSessionInbound"] = "accept"
    return settings


def claude_args(prompt, role, model, root, condition):
    return ["-p", prompt, "--model", model, "--name", role, "--output-format", "stream-json", "--verbose", "--include-hook-events",
            "--permission-mode", "bypassPermissions", "--settings", json.dumps(claude_settings(root, condition)),
            "--tools", ",".join(allowed_tools(condition))]


def codex_args(prompt, workdir, model, condition, shared_dir=None):
    argv = ["exec", "--json", "--skip-git-repo-check", "--color", "never", "-C", workdir, "-m", model, "-s", "workspace-write",
            "-c", 'model_reasoning_effort="medium"', "-c", "sandbox_workspace_write.exclude_slash_tmp=true"]
    for feature in CODEX_FEATURE_PINS:
        argv += ["-c", "features.%s=false" % feature]
    if shared_dir:
        argv += ["--add-dir", shared_dir]   # a worktree lane still has to reach the bus or the ledger in the main checkout
    if condition in grade.HOOKED:
        argv.append("--dangerously-bypass-hook-trust")  # hooks in a scratch CODEX_HOME, as scripts/e2e_codex.sh runs them
    return argv + [prompt]


class Agent:
    def __init__(self, role, harness):
        self.role, self.harness = role, harness
        self.proc, self.lines, self.tool_calls = None, [], 0
        self.started = self.ended = None
        self.stop_reason, self.killed_by_task = None, False
        self.reader = self.timer = None


class Run:
    def __init__(self, task_name, seed, condition, pairing, args, replaces=None):
        if condition == "builtin" and pairing != "cc":
            raise Refused("builtin is Claude only: it has no cx cell")
        self.task_name, self.seed, self.condition, self.pairing, self.args = task_name, seed, condition, pairing, args
        self.replaces, self.usage_hit, self.halt_reason, self.live = replaces, False, None, []
        self.id = "r" + hashlib.sha256(os.urandom(16)).hexdigest()[:12]   # opaque: graders see only this
        self.task = tasks.build(task_name, seed)
        self.root = assert_outside(tempfile.mkdtemp(prefix="value-run-"))
        self.proj = os.path.join(self.root, "proj")
        self.home = os.path.join(self.root, "home")
        self.tmp = os.path.join(self.root, "tmp")
        self.shim = os.path.join(self.root, "shim")
        self.ab = os.path.join(self.root, "ab")
        self.codex_home = os.path.join(self.root, "codex-home")
        self.out = os.path.join(args.out, self.id)
        for d in (self.proj, self.home, self.tmp, self.shim, self.ab, self.codex_home, self.out):
            os.makedirs(d)
        self.stub = os.environ.get("VALUE_STUB_DIR")
        self.harnesses = {r: harness_of(pairing, r, seed) for stage in self.task.schedule for r in stage}
        self.stop_threads = threading.Event()
        self.snaps = open(os.path.join(self.out, "snaps.jsonl"), "w")
        self.seen = {}
        self.loads, self.kill, self.merge, self.late, self.handover = [], {"fired": False}, None, None, None
        self.watch, self.excluded, self.released = None, None, []
        self.channel_dir = os.path.join(self.out, "channel")
        os.makedirs(self.channel_dir)
        self.worktrees = self.task.workspace == "worktrees"
        self.auth_sha = None
        self.codex_at_launch = set()
        self.real_home = os.environ["HOME"]
        self.real_state = {"settings_sha": sha_file(os.path.join(self.real_home, ".claude", "settings.json")),
                           "bus": bus_roster(os.environ.get("VALUE_REAL_BUS"))}

    # ---- setup ------------------------------------------------------------------------------------------------------

    def path_var(self):
        """No agentbus on PATH unless this condition has it: `none` must not find the tool by accident."""
        return os.pathsep.join(([self.ab] if self.condition == "agentbus" else []) + ["/usr/bin", "/bin"])

    def workdir(self, role):
        return os.path.join(self.root, "proj-" + role) if self.worktrees else self.proj

    def base_env(self):
        env = {"HOME": self.home, "PATH": self.path_var(), "TMPDIR": self.tmp, "LANG": "en_US.UTF-8", "TERM": "dumb",
               "USER": os.environ.get("USER", "eval"), "AGENTBUS_NO_UPDATE_CHECK": "1", "PYTHONDONTWRITEBYTECODE": "1",
               "XDG_CACHE_HOME": os.path.join(self.tmp, "xdg-cache"), "XDG_STATE_HOME": os.path.join(self.tmp, "xdg-state"),
               "XDG_CONFIG_HOME": os.path.join(self.tmp, "xdg-config")}
        if self.stub:
            env.update({"VALUE_TASK": self.task_name, "VALUE_SEED": str(self.seed), "VALUE_CONDITION": self.condition,
                        "VALUE_SCRIPTS": HERE})
            env.update({k: v for k, v in os.environ.items() if k.startswith("VALUE_STUB_")})
        return env

    def sh(self, argv, env=None, cwd=None):
        p = subprocess.run(argv, cwd=cwd or self.proj, env=env or self.base_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=120)
        if p.returncode != 0:
            raise RuntimeError("setup step failed: %s\n%s" % (" ".join(argv), p.stdout[-500:]))
        return p.stdout

    def write(self, rel, text):
        path = os.path.join(self.proj, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def build(self):
        assert_outside(self.proj)
        for rel, text in self.task.files.items():
            self.write(rel, text)
        with open(os.path.join(self.home, ".gitconfig"), "w") as f:
            f.write("[user]\n\tname = eval\n\temail = eval@example.com\n")
        self.sh(["git", "init", "-q"])
        self.sh(GIT + ["add", "."])
        self.sh(GIT + ["commit", "-q", "-m", "project"])
        with open(os.path.join(self.proj, ".git", "info", "exclude"), "a") as f:
            f.write("\n__pycache__/\n.claude/\nAGENTS.md\nCOORDINATION.md\n")
        self.install_channel()
        if self.worktrees:
            self.make_worktrees()
        if not self.stub:
            self.write_claude_shim()
            if "codex" in self.harnesses.values():
                self.write_codex_shim()
        self.install_codex_auth()

    def write_codex_shim(self):
        """codex is a node script outside the allowlisted PATH. The agent keeps that PATH: only this launch names node and codex."""
        js = os.path.realpath(shutil.which(self.args.codex_bin))
        node = os.path.realpath(shutil.which("node"))
        path = os.path.join(self.shim, "codex")
        with open(path, "w") as f:
            f.write('#!/bin/sh\nexec %s %s "$@"\n' % (shlex.quote(node), shlex.quote(js)))
        os.chmod(path, 0o755)

    def install_codex_auth(self):
        """A private copy, never a link: a token refresh must not write through to the real sign-in."""
        source = self.args.codex_auth
        if "codex" in self.harnesses.values() and source:
            auth = os.path.join(self.codex_home, "auth.json")
            fd = os.open(auth, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f, open(source, "rb") as src:
                f.write(src.read())
            self.auth_sha = {"source": sha_file(source), "copy": sha_file(auth)}
        self.codex_at_launch = set(os.listdir(self.codex_home))

    def make_worktrees(self):
        """One linked worktree per agent. The bus is found through git; the ledger is one file, linked into each worktree, so
        every channel keeps its same instructions."""
        if self.condition == "ledger":
            open(os.path.join(self.proj, "COORDINATION.md"), "w").close()
        for role in self.harnesses:
            path = self.workdir(role)
            self.sh(["git", "worktree", "add", "-q", path, "-b", "lane-" + role])
            if os.path.isdir(os.path.join(self.proj, ".claude")):
                shutil.copytree(os.path.join(self.proj, ".claude"), os.path.join(path, ".claude"))
            if os.path.exists(os.path.join(self.proj, "AGENTS.md")):
                shutil.copy(os.path.join(self.proj, "AGENTS.md"), path)
            if self.condition == "ledger":
                os.symlink(os.path.join(self.proj, "COORDINATION.md"), os.path.join(path, "COORDINATION.md"))

    def merge_lanes(self):
        """What a lead does at the end: commit each lane and merge them in order. A conflict stays in the tree as markers, so the
        hidden tests see it. The result is recorded, never repaired."""
        env = self.base_env()
        run = lambda argv, cwd: subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=120)  # noqa: E731
        for role in ("alice", "bob"):
            run(GIT + ["add", "-A"], self.workdir(role))
            run(GIT + ["commit", "-q", "--allow-empty", "-m", "lane " + role], self.workdir(role))
        first = run(GIT + ["merge", "-q", "--no-edit", "lane-alice"], self.proj)
        second = run(GIT + ["merge", "-q", "--no-edit", "lane-bob"], self.proj)
        conflicts = [x for x in run(["git", "diff", "--name-only", "--diff-filter=U"], self.proj).stdout.split("\n") if x]
        self.merge = {"conflicts": conflicts, "clean": first.returncode == 0 and second.returncode == 0}

    def install_channel(self):
        codex = "codex" in self.harnesses.values()
        if self.condition == "ledger":
            sha = getattr(self.args, "skill_sha", None)
            self.write(".claude/skills/ledger/SKILL.md", tasks.ledger_skill(self.task, sha))
            self.install_ledger_hooks(codex)
            if codex:
                self.write("AGENTS.md", tasks.ledger_agents_block(self.task, sha))
        elif self.condition == "builtin":
            self.write(".claude/skills/peer-messages/SKILL.md", tasks.PEER_SKILL)
        elif self.condition == "agentbus":
            cmd = shlex.split(os.environ.get("AGENTBUS_CMD") or "%s %s" % (shlex.quote(sys.executable), shlex.quote(tool_path(self.args))))
            shim = os.path.join(self.ab, "agentbus")
            with open(shim, "w") as f:
                f.write('#!/bin/sh\nexec %s "$@"\n' % " ".join(shlex.quote(c) for c in cmd))
            os.chmod(shim, 0o755)
            env = dict(self.base_env(), AGENTBUS_CLAUDE_BIN="/nonexistent/claude")
            self.sh([shim, "init", self.proj], env=env)
            self.sh([shim, "setup", "claude", "--scope", "project"], env=env)
            if codex:
                self.sh([shim, "setup", "codex"], env=dict(env, CODEX_HOME=self.codex_home))

    def install_ledger_hooks(self, codex):
        """The ledger's hooks, on the events agentbus setup uses, with the same timeout and the same never-fail wrapper."""
        folder = os.path.join(self.root, "ledger")
        os.makedirs(folder)
        hook = os.path.join(folder, "ledger_hook.py")
        shutil.copy(os.path.join(HERE, "ledger_hook.py"), hook)

        def entry(harness, event, matcher):
            command = "%s %s %s %s 2>/dev/null || true" % (shlex.quote(sys.executable), shlex.quote(hook), harness, event)
            group = {"hooks": [{"type": "command", "timeout": 5, "command": command}]}
            if matcher:
                group["matcher"] = matcher
            return [group]
        events = LEDGER_HOOKS["todo" if self.task.channel_text == "todo" else "fix1"]
        claude = {"hooks": {event: entry("claude", event, matcher) for event, matcher in events["claude"]}}
        self.write(".claude/settings.json", json.dumps(claude, indent=2) + "\n")
        if codex:
            with open(os.path.join(self.codex_home, "hooks.json"), "w") as f:
                json.dump({"hooks": {event: entry("codex", event, matcher) for event, matcher in events["codex"]}}, f, indent=2)

    def channel_name(self, role):
        """How each tool learns the agent's name before it starts, so hooks and prompt agree."""
        return {"agentbus": {"AGENTBUS_AGENT": role}, "ledger": {"LEDGER_NAME": role}}.get(self.condition, {})

    def write_claude_shim(self):
        """The launcher runs `claude` from PATH: this shim is that `claude`. It replaces the whole environment with the allowlist and
        the temp HOME, keeping only the config folder the launcher made. For `builtin`, both sessions must share one config folder, so
        the first copy of it in this run's own folder serves both, and it outlives either launcher."""
        real = os.path.realpath(self.args.claude_bin)
        env = " ".join("%s=%s" % (k, shlex.quote(v)) for k, v in self.base_env().items())
        lines = ["#!/bin/sh", 'echo $$ > "%s/$VALUE_ROLE.pid"' % self.tmp, 'CFG="$CLAUDE_CONFIG_DIR"']
        if self.condition == "builtin":
            shared = os.path.join(self.root, "shared-cfg")
            lines += ['if mkdir "%s.lock" 2>/dev/null; then cp -RP "$CLAUDE_CONFIG_DIR" "%s.tmp" && mv "%s.tmp" "%s"; fi' % (shared, shared, shared, shared),
                      'while [ ! -d "%s" ]; do sleep 0.2; done' % shared, 'CFG="%s"' % shared]
        name = "".join(' %s="$VALUE_ROLE"' % k for k in self.channel_name("x"))   # the documented way to name a lane, so hooks and prompt agree
        lines.append('exec /usr/bin/env -i %s%s CLAUDE_CONFIG_DIR="$CFG" %s "$@"' % (env, name, shlex.quote(real)))
        path = os.path.join(self.shim, "claude")
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(path, 0o755)

    # ---- agents -----------------------------------------------------------------------------------------------------

    def command(self, agent, prompt):
        """(argv, env) for one agent. A real Claude goes through the launcher; a stand-in runs straight from VALUE_STUB_DIR."""
        args = self.args
        env = self.base_env()
        if agent.harness == "claude":
            rest = claude_args(prompt, agent.role, args.claude_model, self.root, self.condition)
            if self.stub:
                return [os.path.join(self.stub, "claude")] + rest, dict(env, VALUE_ROLE=agent.role, **self.channel_name(agent.role))
            return (shlex.split(args.claude_launcher) + rest,
                    {"HOME": self.real_home, "USER": env["USER"], "LANG": env["LANG"], "TERM": env["TERM"], "VALUE_ROLE": agent.role,
                     "PATH": os.pathsep.join([self.shim, "/usr/bin", "/bin"])})
        env = dict(env, CODEX_HOME=self.codex_home, VALUE_ROLE=agent.role, **self.channel_name(agent.role))
        rest = codex_args(prompt, self.workdir(agent.role), args.codex_model, self.condition, self.proj if self.worktrees else None)
        if self.stub:
            return [os.path.join(self.stub, "codex")] + rest, env
        return [os.path.join(self.shim, "codex")] + rest, env

    def start(self, agent):
        prompt = tasks.prompt(self.task, agent.role, self.condition, agent.harness)
        with open(os.path.join(self.out, "prompt-%s.txt" % agent.role), "w") as f:
            f.write(prompt)
        argv, env = self.command(agent, prompt)
        agent.started = time.time()
        err = open(os.path.join(self.out, "stderr-%s.txt" % agent.role), "w")
        agent.proc = subprocess.Popen(argv, cwd=self.workdir(agent.role), env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=err,
                                      universal_newlines=True, start_new_session=True, errors="replace")
        agent.timer = threading.Timer(self.args.time_cap, self.stop_agent, (agent, "time_cap"))
        agent.timer.start()
        agent.reader = threading.Thread(target=self.read_stream, args=(agent,), daemon=True)
        agent.reader.start()

    def read_stream(self, agent):
        with open(os.path.join(self.out, "trace-%s.jsonl" % agent.role), "w") as raw:
            for line in agent.proc.stdout:
                wrapped = {"ts": time.time(), "line": line.rstrip("\n")}
                agent.lines.append(wrapped)
                raw.write(json.dumps(wrapped) + "\n")
                raw.flush()
                agent.tool_calls += grade.tool_calls_in_line(wrapped["line"], agent.harness)
                why = grade.provider_failure(wrapped["line"], agent.harness)   # the grader's own rule, so a halt and a grade never disagree
                if why and not self.usage_hit:
                    self.halt(why)
                if agent.tool_calls > self.args.tool_cap and agent.stop_reason is None:
                    self.stop_agent(agent, "tool_cap")

    def halt(self, reason):
        """The plan is spent or its sign-in is gone: the run is lost, so nothing in it runs on, and the batch stops after it."""
        self.usage_hit, self.halt_reason = True, reason
        for other in self.live:
            self.stop_agent(other, reason.replace(" ", "_"))

    def stderr_lines(self, role):
        path = os.path.join(self.out, "stderr-%s.txt" % role)
        return [line.rstrip("\n") for line in open(path, errors="replace")] if os.path.exists(path) else []

    def stderr_halt(self, agents):
        """A usage limit or sign-in failure that only reached stderr, by the grader's rule. Checked when the stage's agents have ended."""
        if self.usage_hit:
            return
        for role, a in agents.items():
            for line in self.stderr_lines(role):
                why = grade.provider_failure(line, a.harness)
                if why:
                    self.halt(why)
                    return

    def stop_agent(self, agent, reason, hard=False):
        """Only ever signals the group this runner started, and the pid its own shim recorded."""
        if agent.proc is None or agent.proc.poll() is not None:
            return
        if agent.stop_reason is None:
            agent.stop_reason = reason
        pidfile = os.path.join(self.tmp, "%s.pid" % agent.role)
        sig = signal.SIGKILL if hard else signal.SIGTERM
        try:
            root = int(open(pidfile).read().strip()) if os.path.exists(pidfile) else agent.proc.pid
        except ValueError:
            root = agent.proc.pid
        # The task's own kill is a session dying: the commands it was running die with it. A tool command can sit in a process group
        # of its own, so the agent's descendants are listed before any signal (after it, they belong to no one we can find).
        kids = descendants(root) if hard else []
        try:
            if os.path.exists(pidfile):
                os.kill(root, sig)   # the real agent first, so the launcher stays up and cleans its folder
        except OSError:
            pass
        for pid in kids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        try:
            if os.path.exists(pidfile):
                time.sleep(2)
            if agent.proc.poll() is None:
                os.killpg(agent.proc.pid, sig)
        except OSError:
            pass

        def finish():
            try:
                agent.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(agent.proc.pid, signal.SIGKILL)
                except OSError:
                    pass
        threading.Thread(target=finish, daemon=True).start()

    def watch_kill(self, agent):
        """recovery: the session dies once enough files exist. Files, not tool counts, so both harnesses die at the same point. (abandoned's
        kill is watch_items'.)"""
        spec = self.task.kill
        while agent.proc.poll() is None and not self.stop_threads.is_set():
            found = [p for p in glob.glob(os.path.join(self.proj, spec["glob"])) if os.path.getsize(p) > 0]
            if len(found) >= spec["at"]:
                self.kill = {"fired": True, "at": time.time(), "files": sorted(os.path.relpath(p, self.proj) for p in found)}
                agent.killed_by_task = True
                self.stop_agent(agent, "task_kill", hard=True)
                return
            time.sleep(0.5)

    def release_spec(self, item_id):
        self.released.append(item_id)
        path, text = tasks.abandoned_spec(self.seed, item_id)
        os.makedirs(os.path.dirname(os.path.join(self.proj, path)), exist_ok=True)
        with open(os.path.join(self.proj, path), "w") as f:
            f.write(text)

    def watch_items(self, agent):
        """abandoned and finished: hands the role its specs one at a time and, in abandoned, ends its session. One check drives both, on a
        fixed schedule: every WATCH_INTERVAL seconds from the start, the current item's file is read, and when it has changed the item's
        own check runs on a copy. When it passes, abandoned kills the session before anything is released, so no next spec ever reaches
        it; finished releases the next spec. A check that runs long skips ticks and never shifts the schedule."""
        order = self.task.release["order"]
        mine = tasks.abandoned_ids(self.seed)[0]
        paths = tasks.abandoned_item_paths(self.seed)
        current, last, t0, took = 0, None, time.time(), []
        self.release_spec(mine[order[0]])
        while agent.proc.poll() is None and not self.stop_threads.is_set() and current < len(order):
            self.stop_threads.wait(max(0.0, next_tick(t0, time.time(), WATCH_INTERVAL) - time.time()))
            role = order[current]
            try:
                with open(os.path.join(self.proj, paths[role]), errors="replace") as f:
                    state = f.read()
            except OSError:
                state = None
            if state is None or state == last:
                continue
            last, began = state, time.time()
            passed = role in grade.items_done(self.proj, self.task_name, self.seed, only=[role])
            took.append(round(time.time() - began, 3))
            if not passed:
                continue
            if self.task.kill and agent.proc.poll() is None:
                self.kill = {"fired": True, "at": time.time(), "done": list(order[:current + 1])}
                agent.killed_by_task = True
                self.stop_agent(agent, "task_kill", hard=True)
                break
            current, last = current + 1, None
            if current < len(order):
                self.release_spec(mine[order[current]])
        self.watch = {"interval": WATCH_INTERVAL, "checks": len(took), "max_check_s": max(took or [0.0]), "released": list(self.released)}

    def snapshot_loop(self):
        while not self.stop_threads.is_set():
            self.take_snapshot()
            self.loads.append(os.getloadavg()[0])
            self.stop_threads.wait(self.args.snap_every)

    def take_snapshot(self):
        files = {}
        if self.worktrees:
            for role in self.harnesses:
                files.update({role + "/" + k: v for k, v in grade.read_tree(self.workdir(role), CHANNEL_PATHS).items()})
        else:
            files = grade.read_tree(self.proj, CHANNEL_PATHS)
        changed = {k: v for k, v in files.items() if self.seen.get(k) != v}
        gone = [k for k in self.seen if k not in files]
        if changed or gone:
            self.snaps.write(json.dumps({"ts": time.time(), "changed": changed, "gone": gone}) + "\n")
            self.snaps.flush()
            self.seen = files

    def launch(self, agent):
        self.start(agent)
        if self.task.release and self.task.release["role"] == agent.role:
            threading.Thread(target=self.watch_items, args=(agent,), daemon=True).start()
        elif self.task.kill and self.task.kill["role"] == agent.role:
            threading.Thread(target=self.watch_kill, args=(agent,), daemon=True).start()

    def late_start_due(self, current, later, begun):
        """Why a delayed agent starts now, or None: its file changed from the repo's, every peer in its stage has ended, or its
        wait ran out. livehold: bob starts once alice's first edit to src/rates.py is on disk."""
        spec = self.task.start
        try:
            with open(os.path.join(self.proj, spec["path"]), errors="replace") as f:
                changed = f.read() != self.task.files.get(spec["path"])
        except OSError:
            changed = False
        if changed:
            return "changed"
        if all(o.ended is not None for o in current if o not in later):
            return "peers ended"
        return "max wait" if time.time() - begun > spec.get("max_wait", 600) else None

    def finish_stage(self, current, later, agents):
        """Wait for every agent in a stage, starting a delayed one when it is due, and record each end when its process exits."""
        begun = time.time()
        while True:
            for a in current:
                if a.proc is not None and a.ended is None and a.proc.poll() is not None:
                    a.ended = time.time()
            for a in list(later):
                why = self.halt_reason if self.usage_hit else self.late_start_due(current, later, begun)
                if why:
                    later.remove(a)
                    self.late = {"role": a.role, "at": time.time(), "why": why}
                    if self.usage_hit:
                        agents.pop(a.role)   # never started: the run is infrastructure anyway
                    else:
                        self.launch(a)
            if not later and all(a.ended is not None for a in current if a.proc is not None):
                break
            time.sleep(0.2)
        for a in current:
            if a.proc is not None:
                a.timer.cancel()
                a.reader.join(timeout=30)

    def hand_over(self):
        """What the next agent inherits, read once the session has ended: which items pass, a digest of each item's file (so a grader can
        tell finished work that was changed later), and every item's spec, so the specs say nothing about which were alice's. An
        abandoned session the kill never ended was not interrupted: the run is excluded and replaced, by the registered rule."""
        done = grade.items_done(self.proj, self.task_name, self.seed)
        digests = {rel: grade.file_digest(os.path.join(self.proj, rel)) for rel in tasks.abandoned_item_paths(self.seed).values()}
        self.handover = {"done": done, "open": [r for r in tasks.ITEM_ROLES if r not in done], "at": time.time(), "digests": digests}
        spec_dir = os.path.join(self.proj, tasks.SPEC_DIR)
        if os.path.isdir(spec_dir) and not os.path.islink(spec_dir):
            for name in os.listdir(spec_dir):
                if os.path.isfile(os.path.join(spec_dir, name)):
                    os.remove(os.path.join(spec_dir, name))
        for item_id in tasks.abandoned_ids(self.seed)[1]:
            self.release_spec(item_id)
        if self.task.kill and not self.kill.get("fired"):
            self.excluded = "not interrupted: the kill never fired"

    def watch_channel(self):
        """The ledger's growth, timed: each change of COORDINATION.md as it lands, so a grader can tell when a claim opened and
        closed. Each change is written with the poll that saw it (ts) and the poll before (prev), so an entry landed between the
        two. Not blind: these files sit under channel/, which no blind grader opens. The bus times its own log."""
        path, size, prev = os.path.join(self.proj, "COORDINATION.md"), -1, time.time()
        with open(os.path.join(self.channel_dir, "ledger-watch.jsonl"), "w") as out:
            while True:
                stop = self.stop_threads.is_set()
                now = time.time()
                try:
                    with open(path, errors="replace") as f:
                        text = f.read()
                except OSError:
                    text = None
                if text is not None and len(text) != size:
                    out.write(json.dumps({"ts": now, "prev": prev, "text": text}) + "\n")
                    out.flush()
                    size = len(text)
                if stop:
                    return
                prev = now
                self.stop_threads.wait(0.2)

    def keep_channel(self):
        """The channel as the agents left it, beside the run and never in final/: the bus file (and its WAL, if any), or the ledger."""
        if self.condition == "agentbus":
            for name in ("bus.db", "bus.db-wal"):
                src = os.path.join(self.proj, ".agentbus", name)
                if os.path.isfile(src):
                    shutil.copyfile(src, os.path.join(self.channel_dir, name))
        elif self.condition == "ledger" and os.path.isfile(os.path.join(self.proj, "COORDINATION.md")):
            shutil.copyfile(os.path.join(self.proj, "COORDINATION.md"), os.path.join(self.channel_dir, "COORDINATION.md"))

    def run_agents(self):
        agents = {}
        snapper = threading.Thread(target=self.snapshot_loop, daemon=True)
        snapper.start()
        watcher = threading.Thread(target=self.watch_channel, daemon=True) if self.condition == "ledger" else None
        if watcher:
            watcher.start()
        for stage in self.task.schedule:
            if self.usage_hit:
                break
            current = [Agent(r, self.harnesses[r]) for r in stage]
            self.live = current
            later = [a for a in current if self.task.start and a.role == self.task.start["role"]]
            for a in current:
                agents[a.role] = a
                if a not in later:
                    self.launch(a)
            self.finish_stage(current, later, agents)
            self.stderr_halt(agents)
            if self.task.handover and self.task.handover in stage:
                self.hand_over()
        self.stop_threads.set()
        snapper.join(timeout=30)
        if watcher:
            watcher.join(timeout=30)
        self.take_snapshot()
        self.snaps.close()
        self.keep_channel()
        if self.worktrees:
            self.merge_lanes()
        return agents

    # ---- after the agents -------------------------------------------------------------------------------------------

    def isolation(self, agents):
        """What was loaded and what changed outside the run. Every entry names a failure; empty is clean."""
        bad = []
        for a in agents.values():
            if a.harness == "claude":
                found = grade.check_claude_init(a.lines, self.condition, allowed_tools(self.condition))
                if found == ["no init event"] and a.stop_reason in grade.HALTS:
                    found = []   # the batch stopped this agent for a peer's provider failure before it printed anything
                bad += ["%s: %s" % (a.role, x) for x in found]
        if self.condition != "agentbus" and os.path.exists(os.path.join(self.proj, ".agentbus")):
            bad.append("a bus exists in a %s run" % self.condition)
        if self.worktrees and any(os.path.exists(os.path.join(self.workdir(r), ".agentbus")) for r in self.harnesses):
            bad.append("a second bus exists in a worktree")
        if sha_file(os.path.join(self.real_home, ".claude", "settings.json")) != self.real_state["settings_sha"]:
            bad.append("the real ~/.claude/settings.json changed during the run")
        if "codex" in self.harnesses.values():
            bad += self.check_codex()
        roster = bus_roster(os.environ.get("VALUE_REAL_BUS"))
        if roster is not None and (set(roster) - set(self.real_state["bus"] or [])) & {"alice", "bob"}:
            bad.append("a run's agent joined the real bus")
        return bad

    def check_codex(self):
        """Scratch CODEX_HOME holds only what this condition needs; the real sign-in did not change; no credential in anything kept."""
        bad = []
        own = {"agentbus": ("hooks.json", "AGENTS.md"), "ledger": ("hooks.json",)}.get(self.condition, ())
        bad += ["%s in a %s run" % (n, self.condition) for n in ("hooks.json", "AGENTS.md") if n not in own and os.path.exists(os.path.join(self.codex_home, n))]
        skills = os.path.join(self.codex_home, "skills")
        extra = sorted(set(os.listdir(skills)) - {".system"}) if os.path.isdir(skills) else []
        if extra:
            bad.append("a Codex skill beyond its own: %s" % extra)
        if self.codex_at_launch - CODEX_PLANTED:
            bad.append("CODEX_HOME held %s before launch" % sorted(self.codex_at_launch - CODEX_PLANTED))
        if self.auth_sha:
            auth = os.path.join(self.codex_home, "auth.json")
            if sha_file(self.args.codex_auth) != self.auth_sha["source"]:
                bad.append("the real Codex sign-in changed during the run")
            if sha_file(auth) != self.auth_sha["copy"]:
                bad.append("the run refreshed its copy of the Codex token; the real sign-in may now be stale")
            kept = [os.path.join(d, n) for d in (self.out, self.channel_dir) for n in os.listdir(d) if os.path.isfile(os.path.join(d, n))]
            leaks = grade.secret_leaks(auth, kept)
            if leaks:
                bad.append("a Codex credential is in %s" % leaks)
        return bad

    def collect(self, agents):
        events = []
        known = set(self.task.files) | set(grade.read_tree(self.proj, CHANNEL_PATHS))
        for a in agents.values():
            base = os.path.realpath(self.workdir(a.role))
            evs, _final = normalize.capture_events(a.lines, a.role, a.harness)
            found = [(e["ts"], e["path"]) for e in evs if e["kind"] == "edit" and e["path"]] + grade.script_edits(a.lines, a.harness, known)
            for ts, path in found:
                if os.path.isabs(path):
                    path = os.path.relpath(os.path.realpath(path), base)
                if not grade.is_channel_path(path):
                    events.append({"ts": ts, "agent": a.role, "path": path})
        grade.write_json(os.path.join(self.out, "edits.json"), sorted(events, key=lambda e: e["ts"]))
        final = os.path.join(self.out, "final")
        for rel, text in grade.read_tree(self.proj, CHANNEL_PATHS).items():
            path = os.path.join(final, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
        os.makedirs(final, exist_ok=True)
        grade.write_json(os.path.join(self.out, "run.json"), {
            "id": self.id, "task": self.task_name, "seed": self.seed, "harnesses": self.harnesses,
            "agents": {a.role: {"harness": a.harness, "seconds": round(a.ended - a.started, 1), "rc": a.proc.returncode, "stop": a.stop_reason,
                                "tool_calls": a.tool_calls, "t_start": a.started, "t_end": a.ended} for a in agents.values()},
            "seconds": round(max(a.ended for a in agents.values()) - min(a.started for a in agents.values()), 1),
            "load": {"max": max(self.loads or [0]), "mean": round(sum(self.loads or [0]) / max(1, len(self.loads)), 1)},
            "kill": self.kill, "merge": self.merge, "late_start": self.late, "handover": self.handover, "watch": self.watch})
        cost = {a.role: grade.cost_of(a.lines, a.harness, self.condition) for a in agents.values()}
        for a in agents.values():
            link = os.path.join(self.workdir(a.role), "COORDINATION.md")
            cost[a.role]["ledger_link_broken"] = self.condition == "ledger" and self.worktrees and not os.path.islink(link)
            if a.harness == "codex":
                cost[a.role]["hooks_loaded"] = grade.codex_hooks_loaded(self.codex_home, self.condition) if self.condition in grade.HOOKED else None
            if a.harness == "codex" and not cost[a.role]["complete"]:
                cost[a.role]["usage"] = grade.codex_rollout_usage(self.codex_home) or cost[a.role]["usage"]
        grade.write_json(os.path.join(self.out, "cost.json"), cost)
        self.quota = grade.codex_quota(self.codex_home) if "codex" in self.harnesses.values() else None
        grade.write_json(os.path.join(self.out, "quota.json"), self.quota)
        infra = {a.role: grade.infra_failure(a.lines, a.harness, a.proc.returncode, a.killed_by_task, a.stop_reason, self.stderr_lines(a.role))
                 for a in agents.values()}
        for a in agents.values():   # hooks that never loaded are infrastructure; a hook that ran and failed is an outcome, kept in cost.json
            unloaded = grade.hook_infra(a.lines, self.condition) if a.harness == "claude" else cost[a.role]["hooks_loaded"] is False
            if unloaded and not infra[a.role]:
                infra[a.role] = "hooks did not load"
        return infra

    def execute(self):
        try:
            self.build()
            agents = self.run_agents()
            infra = {r: why for r, why in self.collect(agents).items() if why}
            if self.usage_hit:
                infra = {r: self.halt_reason for r in agents}
            bad = self.isolation(agents)
            row = {"id": self.id, "task": self.task_name, "seed": self.seed, "condition": self.condition, "pairing": self.pairing,
                   "infra": infra, "isolation": bad, "ts": time.time(), "tool": sha_file(tool_path(self.args)), "quota": self.quota}
            if self.excluded and not infra:
                row["excluded"] = self.excluded
            if self.replaces:
                row["replaces"] = self.replaces
            with open(os.path.join(self.args.out, "manifest.jsonl"), "a") as f:
                f.write(json.dumps(row) + "\n")
            if bad:
                raise IsolationError("run %s: %s" % (self.id, "; ".join(bad)))
            return row
        finally:
            self.stop_threads.set()
            auth = os.path.join(self.codex_home, "auth.json")
            if os.path.exists(auth):
                os.remove(auth)   # a kept tree never keeps a credential
            if self.args.keep_tree:
                log("kept %s" % self.root)
            else:
                shutil.rmtree(self.root, ignore_errors=True)


# The ledger's hooks per study: fix1's two events, and for follow-up abandoned the events tasks.HOOK_MAP pairs with the pinned build's.
LEDGER_HOOKS = {
    "fix1": {"claude": [("SessionStart", "startup|resume|clear|compact|fork"), ("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit")],
             "codex": [("SessionStart", None), ("PreToolUse", "apply_patch|Edit|Write")]},
    "todo": {"claude": [("SessionStart", "startup|resume|clear|compact|fork"), ("UserPromptSubmit", None), ("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit")],
             "codex": [("SessionStart", None), ("UserPromptSubmit", None), ("PreToolUse", "apply_patch|Edit|Write")]},
}


def pinned_skill_sha(release):
    """sha256 of the skill at the pinned commit: which ledger text the run installs. None when git cannot show it."""
    p = subprocess.run(["git", "-C", ROOT, "show", "%s:skills/agentbus/SKILL.md" % release], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return hashlib.sha256(p.stdout).hexdigest() if p.returncode == 0 else None


def tool_path(args):
    """The bin/agentbus a run installs: --tool-bin when given (a build outside the checkout), else the checkout's own."""
    return getattr(args, "tool_bin", None) or os.path.join(ROOT, "bin", "agentbus")


def plan(args):
    """Every cell, seed blocks in order, shuffled inside each block from a recorded seed, so load and model drift do not
    line up with a condition. Same seeds in every cell: that is what makes runs paired."""
    order = random.Random(args.order_seed)
    runs = []
    for seed in args.seeds:
        block = [(t, seed, c, p) for t in args.tasks for c in args.conditions for p in args.pairings if not (c == "builtin" and p != "cc")]
        order.shuffle(block)
        runs += block
    return runs


def rerun_plan(out, shard):
    """The protocol's rule for infrastructure failures: each such run again, with the same task, seed, condition and pairing, in the
    order the batch first ran them. A run already replaced is not replaced twice. shard (i, n) takes every n-th from the i-th."""
    path = os.path.join(out, "manifest.jsonl")
    rows = [json.loads(l) for l in open(path)] if os.path.exists(path) else []
    replaced = {r["replaces"] for r in rows if r.get("replaces")}
    todo = [(r["task"], r["seed"], r["condition"], r["pairing"], r["id"]) for r in rows if (r["infra"] or r.get("excluded")) and r["id"] not in replaced]
    i, n = shard
    return todo[i - 1::n]


def claude_usage(cmd):
    """The first number a usage command prints: percent of the plan's window used. None if it prints none."""
    p = subprocess.run(["/bin/sh", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=60)
    found = re.search(r"\d+(?:\.\d+)?", p.stdout)
    return float(found.group(0)) if found else None


STOPS = {6: "codex budget", 7: "usage limit", 8: "claude usage", 9: "authentication failed"}


def record_stop(out, rc, done, total):
    """A halted batch says why in OUT/stop.json, so a budget-stop analysis can only follow a stop that happened."""
    grade.write_json(os.path.join(out, "stop.json"), {"rc": rc, "reason": STOPS[rc], "at": time.time(), "runs_done": done, "runs_planned": total})


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tasks", nargs="+", choices=tasks.TASKS + tasks.RETIRED + tasks.FOLLOWUP + tasks.FOLLOWUP_TODO, default=list(tasks.TASKS))
    ap.add_argument("--conditions", nargs="+", choices=tasks.CONDITIONS, default=list(tasks.CONDITIONS))
    ap.add_argument("--pairings", nargs="+", choices=PAIRINGS, default=list(PAIRINGS))
    ap.add_argument("--seeds", nargs="+", type=int, default=[1])
    ap.add_argument("--order-seed", type=int, default=20261105)
    ap.add_argument("--out", required=True, help="traces and results; local only, outside any repo")
    ap.add_argument("--go", action="store_true", help="spend tokens: required for real agents")
    ap.add_argument("--dry-run", action="store_true", help="print the plan and stop")
    ap.add_argument("--time-cap", type=int, default=TIME_CAP, help="seconds per agent")
    ap.add_argument("--tool-cap", type=int, default=TOOL_CAP, help="tool calls per agent")
    ap.add_argument("--snap-every", type=float, default=SNAP_EVERY)
    ap.add_argument("--keep-tree", action="store_true")
    ap.add_argument("--claude-model", default=CLAUDE_MODEL)
    ap.add_argument("--codex-model", default=CODEX_MODEL)
    ap.add_argument("--claude-launcher", default=os.environ.get("VALUE_CLAUDE_LAUNCHER"),
                    help="command that starts claude from PATH in a throwaway config folder, with a sign-in; or VALUE_CLAUDE_LAUNCHER")
    ap.add_argument("--claude-bin", default=os.path.expanduser("~/.local/bin/claude"))
    ap.add_argument("--codex-route", choices=("none", "exec"), default="none", help="exec: direct codex exec in mktemp, under a scratch CODEX_HOME")
    ap.add_argument("--codex-auth", default=os.environ.get("VALUE_CODEX_AUTH"), help="auth.json to copy into the scratch CODEX_HOME")
    ap.add_argument("--codex-bin", default="codex")
    ap.add_argument("--codex-budget", type=float, help="usage points; halt when projected use passes this (default %s; a registered study fixes it)" % CODEX_BUDGET)
    ap.add_argument("--tool-release", help="the commit whose bin/agentbus is under test (default: the tasks' own pin)")
    ap.add_argument("--tool-sha256", help="and the sha256 that bin/agentbus must have (default: the tasks' own pin)")
    ap.add_argument("--tool-bin", help="the bin/agentbus to install, when it is not the checkout's own (a build of an unreleased commit)")
    ap.add_argument("--rerun-infra", action="store_true", help="run again every infrastructure failure already in --out, as the protocol says")
    ap.add_argument("--skip-done", action="store_true", help="leave out every task, seed, condition and pairing the manifest in --out already has a row for (a failed one is --rerun-infra's)")
    ap.add_argument("--shard", default="1/1", help="I/N: with --rerun-infra, this runner's share")
    ap.add_argument("--claude-usage-cmd", help="a command printing the Claude plan's window use in percent; checked before every run")
    ap.add_argument("--claude-usage-stop", type=float, help="halt when the plan's use reaches or is projected past this percent (default 90)")
    args = ap.parse_args(argv)
    shard = tuple(int(x) for x in args.shard.split("/"))
    if args.rerun_infra:
        runs = rerun_plan(args.out if os.path.isabs(args.out) else os.path.abspath(args.out), shard)
        log("value eval: %d runs (replacing infrastructure failures)" % len(runs))
    else:
        runs = [r + (None,) for r in plan(args)]
        if args.skip_done:
            path = os.path.join(args.out if os.path.isabs(args.out) else os.path.abspath(args.out), "manifest.jsonl")
            have = {(r["task"], r["seed"], r["condition"], r["pairing"]) for r in map(json.loads, open(path))} if os.path.exists(path) else set()
            runs = [r for r in runs if r[:4] not in have]
        log("value eval: %d runs" % len(runs))
    for r in runs:
        log("  %s seed %d %s %s%s" % (r[0], r[1], r[2], r[3], " (replaces %s)" % r[4] if r[4] else ""))
    if args.dry_run:
        return 0
    stub = os.environ.get("VALUE_STUB_DIR")
    if not stub and not args.go:
        log("not running: this spends tokens on real agents. Re-run with --go.")
        return 3
    if not stub and not args.claude_launcher:
        log("not running: name a launcher with --claude-launcher or VALUE_CLAUDE_LAUNCHER.")
        return 2
    if not stub and any(r[3] == "cx" for r in runs):   # before any run: in cx a real Claude may start first
        if args.codex_route != "exec":
            log("not running: Codex needs --codex-route exec, the route the protocol's addenda set.")
            return 2
        if not args.codex_auth:
            log("not running: --codex-route exec needs --codex-auth or VALUE_CODEX_AUTH.")
            return 2
    try:
        release, sha256 = pins_for([tasks.build(t, 1) for t in sorted({r[0] for r in runs})] or [tasks.build("control", 1)])
    except Refused as e:
        log("refused: %s" % e)
        return 2
    study = next((k for k in STUDIES if all(tasks.build(r[0], 1).channel_text == k for r in runs)), None) if runs else None
    if study and not stub:
        cfg = STUDIES[study]
        if args.tool_release or args.tool_sha256:
            log("not running: the build is fixed by the study (%s); --tool-release and --tool-sha256 cannot change it." % cfg["pin"][0])
            return 2
        if args.codex_budget not in (None, cfg["codex_budget"]) or args.claude_usage_stop not in (None, cfg["claude_usage_stop"]):
            log("not running: the study fixes the Codex budget at %s points and the Claude usage stop at %s%%." % (cfg["codex_budget"], cfg["claude_usage_stop"]))
            return 2
        if not args.claude_usage_cmd:
            log("not running: the study needs the Claude usage stop on: give --claude-usage-cmd.")
            return 2
        args.codex_budget, args.claude_usage_stop = cfg["codex_budget"], cfg["claude_usage_stop"]
    args.codex_budget = CODEX_BUDGET if args.codex_budget is None else args.codex_budget
    args.claude_usage_stop = 90.0 if args.claude_usage_stop is None else args.claude_usage_stop
    release, sha256 = args.tool_release or release, args.tool_sha256 or sha256
    args.skill_sha = pinned_skill_sha(release) if study else None
    if study and args.skill_sha not in tasks.TODO_LEDGERS:
        log("not running: no ledger text is paired with the skill of %s; map it in tasks.SKILL_MAPS first." % release)
        return 2
    if not stub and os.environ.get("AGENTBUS_CMD"):
        log("not running: AGENTBUS_CMD is set, which would replace the pinned tool. Unset it.")
        return 2
    if not stub and any(r[2] == "agentbus" for r in runs) and not tool_pinned(ROOT, release, sha256, args.tool_bin):
        log("not running: %s is not the pinned %s (sha256 %s), and runs test that build." % (tool_path(args), release, sha256))
        return 2
    try:
        args.out = assert_outside(args.out if os.path.isabs(args.out) else os.path.abspath(args.out))
        os.makedirs(args.out, exist_ok=True)
        rec = check_study(args.out, study) if study else None
        path = os.path.join(args.out, "manifest.jsonl")
        before = [json.loads(line) for line in open(path)] if os.path.exists(path) else []
        done, use_start = 0, (rec or {}).get("claude_start")
        start = (rec or {}).get("codex_start")
        codex_done = sum(1 for r in before if r["pairing"] == "cx" and r.get("quota")) if rec else 0   # a resumed study counts from its start
        codex_total = codex_done + sum(1 for r in runs if r[3] == "cx")
        for t, seed, c, p, replaces in runs:
            if args.claude_usage_cmd:
                use = claude_usage(args.claude_usage_cmd)
                use_start = use if use_start is None else use_start
                note_study(args.out, rec, "claude_start", use_start)
                if use is None or analyze.over_budget(use_start, use, done, len(runs), args.claude_usage_stop - use_start, min_runs=20) or use >= args.claude_usage_stop:
                    log("Claude usage stop: the plan is at %s%% after %d of %d runs, against a stop at %s%%. Batch halted." % (use, done, len(runs), args.claude_usage_stop))
                    record_stop(args.out, 8, done, len(runs))
                    return 8
            row = Run(t, seed, c, p, args, replaces).execute()
            done += 1
            log("run %d of %d: %s%s" % (done, len(runs), row["id"], " infra: %s" % row["infra"] if row["infra"] else ""))
            if "usage limit" in row["infra"].values():
                log("usage limit: batch stopped after run %s. The plan's usage limit is reached; nothing more runs on it." % row["id"])
                record_stop(args.out, 7, done, len(runs))
                return 7
            if "authentication failed" in row["infra"].values():
                log("authentication failed: batch stopped after run %s. The plan's sign-in is gone; nothing more runs on it." % row["id"])
                record_stop(args.out, 9, done, len(runs))
                return 9
            if p == "cx" and row["quota"]:
                codex_done += 1
                now = row["quota"]["used_percent"]
                start = now if start is None or now < start else start   # first reading, or a window that reset
                note_study(args.out, rec, "codex_start", start)
                if analyze.over_budget(start, now, codex_done, codex_total, args.codex_budget):
                    log("Codex budget stop: %s points in %d of %d Codex runs passes %s projected. Batch halted." % (now - start, codex_done, codex_total, args.codex_budget))
                    record_stop(args.out, 6, done, len(runs))
                    return 6
    except Refused as e:
        log("refused: %s" % e)
        return 2
    except IsolationError as e:
        log("isolation check failed, batch stopped: %s" % e)
        return 5
    log("value eval complete: %d runs in %s" % (done, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
