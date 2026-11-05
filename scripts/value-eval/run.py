#!/usr/bin/env python3
"""Value eval runner: does agentbus add anything over a flat file? Protocol: docs/evals/value-protocol.md.

One run builds a seeded repo in mktemp, installs one condition's channel, runs the task's agents to a schedule under
time and tool caps, then keeps the traces, the final tree and snapshots in --out. Nothing here grades: grade.py does,
blind to condition, from what this collected.

A real agent never sees the caller's environment or config. Claude is the first-party binary launched by
`clauth start --isolated` (a throwaway runtime with the owner's sign-in), through a shim that swaps in a temp HOME and an
allowlisted environment. Every run ends in isolation checks, and one failure stops the batch.
"""
import argparse
import fnmatch
import glob
import hashlib
import json
import os
import random
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
import grade  # noqa: E402
import normalize  # noqa: E402
import tasks  # noqa: E402

PAIRINGS = ("cc", "cx")
BASE_TOOLS = ["Bash", "Read", "Edit", "Write", "Skill"]
BUILTIN_TOOLS = ["ListAgents", "SendMessage", "ToolSearch"]
CLAUDE_MODEL, CODEX_MODEL = "sonnet", "gpt-6.1-sol"
TIME_CAP, TOOL_CAP, SNAP_EVERY = 2400, 80, 5
CHANNEL_PATHS = (".agentbus", "COORDINATION.md", ".claude", "AGENTS.md", ".git", "__pycache__", "CLAUDE.md")
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


def codex_args(prompt, proj, model, condition):
    argv = ["exec", "--json", "--skip-git-repo-check", "--color", "never", "-C", proj, "-m", model, "-s", "workspace-write",
            "-c", 'model_reasoning_effort="medium"']
    for feature in CODEX_FEATURE_PINS:
        argv += ["-c", "features.%s=false" % feature]
    if condition == "agentbus":
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
    def __init__(self, task_name, seed, condition, pairing, args):
        if condition == "builtin" and pairing != "cc":
            raise Refused("builtin is Claude only: it has no cx cell")
        self.task_name, self.seed, self.condition, self.pairing, self.args = task_name, seed, condition, pairing, args
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
        self.loads, self.kill = [], {"fired": False}
        self.real_home = os.environ["HOME"]
        self.real_state = {"settings_sha": sha_file(os.path.join(self.real_home, ".claude", "settings.json")),
                           "bus": bus_roster(os.environ.get("VALUE_REAL_BUS"))}

    # ---- setup ------------------------------------------------------------------------------------------------------

    def path_var(self):
        """No agentbus on PATH unless this condition has it: `none` must not find the tool by accident."""
        return os.pathsep.join(([self.ab] if self.condition == "agentbus" else []) + ["/usr/bin", "/bin"])

    def base_env(self):
        env = {"HOME": self.home, "PATH": self.path_var(), "TMPDIR": self.tmp, "LANG": "en_US.UTF-8", "TERM": "dumb",
               "USER": os.environ.get("USER", "eval"), "AGENTBUS_NO_UPDATE_CHECK": "1", "PYTHONDONTWRITEBYTECODE": "1"}
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
            f.write("\n__pycache__/\n.claude/\nAGENTS.md\n")
        self.install_channel()
        if not self.stub:
            self.write_claude_shim()

    def install_channel(self):
        codex = "codex" in self.harnesses.values()
        if self.condition == "ledger":
            self.write(".claude/skills/ledger/SKILL.md", tasks.LEDGER_SKILL)
            if codex:
                self.write("AGENTS.md", tasks.LEDGER_AGENTS_BLOCK)
        elif self.condition == "builtin":
            self.write(".claude/skills/peer-messages/SKILL.md", tasks.PEER_SKILL)
        elif self.condition == "agentbus":
            cmd = shlex.split(os.environ.get("AGENTBUS_CMD") or "%s %s" % (shlex.quote(sys.executable), shlex.quote(os.path.join(ROOT, "bin", "agentbus"))))
            shim = os.path.join(self.ab, "agentbus")
            with open(shim, "w") as f:
                f.write('#!/bin/sh\nexec %s "$@"\n' % " ".join(shlex.quote(c) for c in cmd))
            os.chmod(shim, 0o755)
            env = dict(self.base_env(), AGENTBUS_CLAUDE_BIN="/nonexistent/claude")
            self.sh([shim, "init", self.proj], env=env)
            self.sh([shim, "setup", "claude", "--scope", "project"], env=env)
            if codex:
                self.sh([shim, "setup", "codex"], env=dict(env, CODEX_HOME=self.codex_home))

    def write_claude_shim(self):
        """clauth execs `claude` from PATH: this shim is that `claude`. It replaces the whole environment with the allowlist and
        the temp HOME, keeping only the runtime clauth made. For `builtin`, both sessions must share one config folder, so the
        first copy of clauth's runtime in this run's own folder serves both, and it outlives either clauth."""
        real = os.path.realpath(self.args.claude_bin)
        env = " ".join("%s=%s" % (k, shlex.quote(v)) for k, v in self.base_env().items())
        lines = ["#!/bin/sh", 'echo $$ > "%s/$VALUE_ROLE.pid"' % self.tmp, 'CFG="$CLAUDE_CONFIG_DIR"']
        if self.condition == "builtin":
            shared = os.path.join(self.root, "shared-cfg")
            lines += ['if mkdir "%s.lock" 2>/dev/null; then cp -RP "$CLAUDE_CONFIG_DIR" "%s.tmp" && mv "%s.tmp" "%s"; fi' % (shared, shared, shared, shared),
                      'while [ ! -d "%s" ]; do sleep 0.2; done' % shared, 'CFG="%s"' % shared]
        lines.append('exec /usr/bin/env -i %s CLAUDE_CONFIG_DIR="$CFG" %s "$@"' % (env, shlex.quote(real)))
        path = os.path.join(self.shim, "claude")
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(path, 0o755)

    # ---- agents -----------------------------------------------------------------------------------------------------

    def command(self, agent, prompt):
        """(argv, env) for one agent. A real Claude goes through clauth; a stand-in runs straight from VALUE_STUB_DIR."""
        args = self.args
        env = self.base_env()
        if agent.harness == "claude":
            rest = claude_args(prompt, agent.role, args.claude_model, self.root, self.condition)
            if self.stub:
                return [os.path.join(self.stub, "claude")] + rest, dict(env, VALUE_ROLE=agent.role)
            return ([args.clauth_bin, "start", "--isolated", args.claude_profile] + rest,
                    {"HOME": self.real_home, "USER": env["USER"], "LANG": env["LANG"], "TERM": env["TERM"], "VALUE_ROLE": agent.role,
                     "PATH": os.pathsep.join([self.shim, "/usr/bin", "/bin"])})
        env = dict(env, CODEX_HOME=self.codex_home, VALUE_ROLE=agent.role)
        rest = codex_args(prompt, self.proj, args.codex_model, self.condition)
        if self.stub:
            return [os.path.join(self.stub, "codex")] + rest, env
        auth = os.path.join(self.codex_home, "auth.json")
        if not os.path.lexists(auth):
            os.symlink(args.codex_auth, auth)
        return ["codex"] + rest, env

    def start(self, agent):
        prompt = tasks.prompt(self.task, agent.role, self.condition, agent.harness)
        with open(os.path.join(self.out, "prompt-%s.txt" % agent.role), "w") as f:
            f.write(prompt)
        argv, env = self.command(agent, prompt)
        agent.started = time.time()
        err = open(os.path.join(self.out, "stderr-%s.txt" % agent.role), "w")
        agent.proc = subprocess.Popen(argv, cwd=self.proj, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=err,
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
                if agent.tool_calls > self.args.tool_cap and agent.stop_reason is None:
                    self.stop_agent(agent, "tool_cap")

    def stop_agent(self, agent, reason, hard=False):
        """Only ever signals the group this runner started, and the pid its own shim recorded."""
        if agent.proc.poll() is not None:
            return
        if agent.stop_reason is None:
            agent.stop_reason = reason
        pidfile = os.path.join(self.tmp, "%s.pid" % agent.role)
        sig = signal.SIGKILL if hard else signal.SIGTERM
        try:
            if os.path.exists(pidfile):
                os.kill(int(open(pidfile).read().strip()), sig)   # the real agent first, so clauth stays up and cleans its runtime
                time.sleep(2)
            if agent.proc.poll() is None:
                os.killpg(agent.proc.pid, sig)
        except (OSError, ValueError):
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
        """recovery: the session dies once enough files exist. Files, not tool counts, so both harnesses die at the same point."""
        spec = self.task.kill
        while agent.proc.poll() is None and not self.stop_threads.is_set():
            found = [p for p in glob.glob(os.path.join(self.proj, spec["glob"])) if os.path.getsize(p) > 0]
            if len(found) >= spec["at"]:
                self.kill = {"fired": True, "at": time.time(), "files": sorted(os.path.relpath(p, self.proj) for p in found)}
                agent.killed_by_task = True
                self.stop_agent(agent, "task_kill", hard=True)
                return
            time.sleep(0.5)

    def snapshot_loop(self):
        while not self.stop_threads.is_set():
            self.take_snapshot()
            self.loads.append(os.getloadavg()[0])
            self.stop_threads.wait(self.args.snap_every)

    def take_snapshot(self):
        files = grade.read_tree(self.proj, CHANNEL_PATHS)
        changed = {k: v for k, v in files.items() if self.seen.get(k) != v}
        gone = [k for k in self.seen if k not in files]
        if changed or gone:
            self.snaps.write(json.dumps({"ts": time.time(), "changed": changed, "gone": gone}) + "\n")
            self.snaps.flush()
            self.seen = files

    def run_agents(self):
        agents = {}
        snapper = threading.Thread(target=self.snapshot_loop, daemon=True)
        snapper.start()
        for stage in self.task.schedule:
            current = [Agent(r, self.harnesses[r]) for r in stage]
            watchers = []
            for a in current:
                agents[a.role] = a
                self.start(a)
                if self.task.kill and self.task.kill["role"] == a.role:
                    watchers.append(threading.Thread(target=self.watch_kill, args=(a,), daemon=True))
                    watchers[-1].start()
            for a in current:
                a.proc.wait()
                a.ended = time.time()
                a.timer.cancel()
                a.reader.join(timeout=30)
        self.stop_threads.set()
        snapper.join(timeout=30)
        self.take_snapshot()
        self.snaps.close()
        return agents

    # ---- after the agents -------------------------------------------------------------------------------------------

    def isolation(self, agents):
        """What was loaded and what changed outside the run. Every entry names a failure; empty is clean."""
        bad = []
        for a in agents.values():
            if a.harness == "claude":
                bad += ["%s: %s" % (a.role, x) for x in grade.check_claude_init(a.lines, self.condition, allowed_tools(self.condition))]
        if self.condition != "agentbus" and os.path.exists(os.path.join(self.proj, ".agentbus")):
            bad.append("a bus exists in a %s run" % self.condition)
        if sha_file(os.path.join(self.real_home, ".claude", "settings.json")) != self.real_state["settings_sha"]:
            bad.append("the real ~/.claude/settings.json changed during the run")
        roster = bus_roster(os.environ.get("VALUE_REAL_BUS"))
        if roster is not None and (set(roster) - set(self.real_state["bus"] or [])) & {"alice", "bob"}:
            bad.append("a run's agent joined the real bus")
        return bad

    def collect(self, agents):
        base = os.path.realpath(self.proj)
        events = []
        for a in agents.values():
            evs, _final = normalize.capture_events(a.lines, a.role, a.harness)
            for e in evs:
                if e["kind"] == "edit" and e["path"]:
                    if os.path.isabs(e["path"]):
                        e["path"] = os.path.relpath(os.path.realpath(e["path"]), base)
                    if e["path"].split(os.sep)[0] not in CHANNEL_PATHS:
                        events.append({"ts": e["ts"], "agent": e["agent"], "path": e["path"]})
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
                                "tool_calls": a.tool_calls} for a in agents.values()},
            "seconds": round(max(a.ended for a in agents.values()) - min(a.started for a in agents.values()), 1),
            "load": {"max": max(self.loads or [0]), "mean": round(sum(self.loads or [0]) / max(1, len(self.loads)), 1)},
            "kill": self.kill})
        cost = {a.role: grade.cost_of(a.lines, a.harness, self.condition) for a in agents.values()}
        grade.write_json(os.path.join(self.out, "cost.json"), cost)
        return {a.role: grade.infra_failure(a.lines, a.harness, a.proc.returncode, a.killed_by_task, a.stop_reason) for a in agents.values()}

    def execute(self):
        try:
            self.build()
            agents = self.run_agents()
            infra = {r: why for r, why in self.collect(agents).items() if why}
            bad = self.isolation(agents)
            row = {"id": self.id, "task": self.task_name, "seed": self.seed, "condition": self.condition, "pairing": self.pairing,
                   "infra": infra, "isolation": bad, "ts": time.time()}
            with open(os.path.join(self.args.out, "manifest.jsonl"), "a") as f:
                f.write(json.dumps(row) + "\n")
            if bad:
                raise IsolationError("run %s: %s" % (self.id, "; ".join(bad)))
            return row
        finally:
            self.stop_threads.set()
            if self.args.keep_tree:
                log("kept %s" % self.root)
            else:
                shutil.rmtree(self.root, ignore_errors=True)


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


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tasks", nargs="+", choices=tasks.TASKS, default=list(tasks.TASKS))
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
    ap.add_argument("--claude-profile", default=os.environ.get("VALUE_CLAUDE_PROFILE"), help="clauth profile; or VALUE_CLAUDE_PROFILE")
    ap.add_argument("--claude-bin", default=os.path.expanduser("~/.local/bin/claude"))
    ap.add_argument("--clauth-bin", default=os.path.expanduser("~/.local/bin/clauth"))
    ap.add_argument("--codex-route", choices=("none", "exec"), default="none", help="exec: direct codex exec in mktemp; the owner's call")
    ap.add_argument("--codex-auth", default=os.environ.get("VALUE_CODEX_AUTH"), help="auth.json to link into the scratch CODEX_HOME")
    args = ap.parse_args(argv)
    runs = plan(args)
    log("value eval: %d runs" % len(runs))
    for r in runs:
        log("  %s seed %d %s %s" % (r[0], r[1], r[2], r[3]))
    if args.dry_run:
        return 0
    stub = os.environ.get("VALUE_STUB_DIR")
    if not stub and not args.go:
        log("not running: this spends tokens on real agents. Re-run with --go.")
        return 3
    if not stub and not args.claude_profile:
        log("not running: name a clauth profile with --claude-profile or VALUE_CLAUDE_PROFILE.")
        return 2
    if not stub and "cx" in args.pairings:   # before any run: in cx a real Claude may start first
        if args.codex_route != "exec":
            log("not running: Codex has no route. codex-lane refuses a write lane in mktemp, and --codex-route exec is the owner's call "
                "(docs/evals/value-protocol.md, Open items).")
            return 2
        if not args.codex_auth:
            log("not running: --codex-route exec needs --codex-auth or VALUE_CODEX_AUTH.")
            return 2
    try:
        args.out = assert_outside(args.out if os.path.isabs(args.out) else os.path.abspath(args.out))
        os.makedirs(args.out, exist_ok=True)
        done = 0
        for t, seed, c, p in runs:
            row = Run(t, seed, c, p, args).execute()
            done += 1
            log("run %d of %d: %s%s" % (done, len(runs), row["id"], " infra: %s" % row["infra"] if row["infra"] else ""))
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
