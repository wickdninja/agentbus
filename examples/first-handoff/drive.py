#!/usr/bin/env python3
"""Drive the first-handoff probe: two real headless sessions on the generated project, Claude as alice and then Codex as bob.

  python3 drive.py --out DIR [--condition agentbus|ledger|both|none] [--runs 3] [--seed-base 1] [--max-minutes 10]

Alice holds three answers from a partner call. Bob's ticket cannot be done correctly without them, and they are in no
file. One channel carries them: agentbus, or a shared Markdown ledger with the same instructions (examples/first-handoff/
ledger_skill.md). `none` is the control: no channel at all, so a pass there means the probe is broken.
A run passes only when the hidden check passes AND bob's own transcript shows him reading alice's message before the first
write to feed/parse.py. Both are counted from artifacts, never from what an agent says.

Everything runs under a scratch HOME, CLAUDE_CONFIG_DIR and CODEX_HOME that hold only a private copy of each sign-in
(CLAUDE_AUTH_FROM, default ~/.claude/.credentials.json; CODEX_AUTH_FROM, default ~/.codex/auth.json). The copies are deleted
as soon as each session ends, the real files are hashed before and after, and the real ~/.claude and ~/.codex are never
written. Needs claude and codex signed in and on PATH. Each run makes two model calls; it is not part of tests/run_all.sh.
--out DIR keeps per-run transcripts, the channel dump and a results.json (never a credential: kept files are scanned).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import scenario  # noqa: E402

ALICE_FILES = {"feed/report.py", "tests/test_report.py"}
CHANNEL_PATHS = (".agentbus", "COORDINATION.md")
# A command that writes feed/parse.py: the verb and the path together, so a ledger entry that merely names the file is not one.
_P = r"[\w./-]*parse\.py"
WRITE_RES = [re.compile(x) for x in (
    r">>?\s*['\"]?" + _P,                                   # cat > feed/parse.py <<EOF
    r"\btee\b[^|;&]*" + _P,
    r"\b(?:sed|perl)\s+-\w*i\b[^|;&]*" + _P,                # in-place edit
    r"\b(?:cp|mv|install)\s[^|;&]*" + _P,
    r"\*\*\* (?:Add|Update) File:\s*" + _P,                  # apply_patch through the shell
    r"open\(\s*['\"]" + _P + r"['\"]\s*,\s*['\"][wa]",
    r"Path\(\s*['\"]" + _P + r"['\"]\s*\)\.write_",
)]


def sha_file(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def nospace(text):
    return re.sub(r"\s+", "", text or "")


def log(msg):
    print(msg, flush=True)


# ---- running one agent ----------------------------------------------------------------------------------------------

def run_agent(argv, env, cwd, raw_path, err_path, max_seconds, command_cap=None):
    """Run argv with output stamped line by line. Returns {"rc", "seconds", "killed": reason or None, "events": [(t, obj)]}.
    The child gets its own process group; only that group is ever killed."""
    events, lines = [], []
    start = time.time()

    def reader(pipe):
        for line in pipe:
            t = time.time() - start
            lines.append(line)
            try:
                events.append((t, json.loads(line)))
            except ValueError:
                pass

    with open(err_path, "wb") as err:
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=err,
                                text=True, bufsize=1, start_new_session=True)
        thread = threading.Thread(target=reader, args=(proc.stdout,), daemon=True)
        thread.start()
        killed = None
        while proc.poll() is None:
            time.sleep(0.5)
            if time.time() - start > max_seconds:
                killed = "time cap %ds" % max_seconds
            elif command_cap and sum(1 for _, e in list(events) if e.get("type") == "item.started" and e.get("item", {}).get("type") == "command_execution") > command_cap:
                killed = "command cap %d" % command_cap
            if killed:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
                proc.wait()
        thread.join(5)
    with open(raw_path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    return {"rc": proc.returncode, "seconds": round(time.time() - start, 1), "killed": killed, "events": events}


# ---- reading the transcripts ----------------------------------------------------------------------------------------

def claude_summary(events):
    out = {"commands": 0, "hook_events": 0, "num_turns": None, "cost_usd": None, "tokens": None, "result_error": None}
    for _, e in events:
        if e.get("type") == "system" and str(e.get("subtype", "")).startswith("hook"):
            out["hook_events"] += 1
        if e.get("type") == "assistant":
            for b in e.get("message", {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
                    out["commands"] += 1
        if e.get("type") == "result":
            u = e.get("usage") or {}
            out["num_turns"] = e.get("num_turns")
            out["cost_usd"] = e.get("total_cost_usd")
            out["tokens"] = {"input": u.get("input_tokens"), "cache_read": u.get("cache_read_input_tokens"),
                             "cache_write": u.get("cache_creation_input_tokens"), "output": u.get("output_tokens")}
            out["result_error"] = e.get("subtype") if e.get("is_error") or e.get("subtype") != "success" else None
    return out


def codex_steps(events):
    """Bob's actions in order: commands with their output, and patch applications."""
    steps = []
    for t, e in events:
        if e.get("type") != "item.completed":
            continue
        it = e.get("item") or {}
        if it.get("type") == "command_execution":
            steps.append({"n": len(steps), "t": round(t, 1), "kind": "command", "cmd": it.get("command") or "", "out": it.get("aggregated_output") or "", "rc": it.get("exit_code")})
        elif it.get("type") == "file_change":
            paths = [c.get("path", "") for c in it.get("changes") or []]
            steps.append({"n": len(steps), "t": round(t, 1), "kind": "patch", "cmd": "patch " + " ".join(paths), "out": "", "paths": paths, "rc": None})
    return steps


def codex_tokens(events):
    tot = {"input": 0, "cached_input": 0, "output": 0}
    for _, e in events:
        if e.get("type") == "turn.completed":
            u = e.get("usage") or {}
            tot["input"] += u.get("input_tokens") or 0
            tot["cached_input"] += u.get("cached_input_tokens") or 0
            tot["output"] += u.get("output_tokens") or 0
    return tot


def writes_parse(step):
    if step["kind"] == "patch":
        return any(p.endswith("feed/parse.py") for p in step.get("paths", []))
    return any(r.search(step["cmd"]) for r in WRITE_RES)


def grade_b(steps, alice_texts, side_markers):
    """Where bob first read a line of alice's message, where he first wrote feed/parse.py, and whether he went around the channel.
    A read is a command whose output holds the head or the tail of one of alice's messages (whitespace ignored, since the CLI
    wraps lines)."""
    needles = []
    for text in alice_texts:
        s = nospace(text)
        if len(s) >= 25:
            needles += [s[:25], s[-25:]]
        elif len(s) >= 12:
            needles.append(s)
    read = next((s for s in steps if s["kind"] == "command" and any(n in nospace(s["out"]) for n in needles)), None)
    write = next((s for s in steps if writes_parse(s)), None)
    side = [s["n"] for s in steps if any(m in s["cmd"] or m in s["out"] for m in side_markers)]
    chan = [{"n": s["n"], "t": s["t"], "cmd": s["cmd"][:160], "carried_alice": bool(read and s["n"] >= read["n"] and any(n in nospace(s["out"]) for n in needles))}
            for s in steps if "agentbus" in s["cmd"] or "COORDINATION" in s["cmd"]]
    return {"read_step": read["n"] if read else None, "read_t": read["t"] if read else None, "read_cmd": read["cmd"][:160] if read else None,
            "write_step": write["n"] if write else None, "write_t": write["t"] if write else None, "write_cmd": write["cmd"][:160] if write else None,
            "read_before_write": bool(read and write and read["n"] < write["n"]), "side_channel_steps": side, "channel_commands": chan,
            "steps": len(steps)}


def alice_texts_agentbus(project, shim):
    p = subprocess.run([shim, "--json", "read", "--limit", "200"], cwd=project, capture_output=True, text=True, timeout=30)
    data = json.loads(p.stdout)
    texts = [m["body"] for m in data["items"] if m.get("sender") == "alice"]
    p = subprocess.run([shim, "--json", "ctx", "get", "--limit", "-1"], cwd=project, capture_output=True, text=True, timeout=30)
    facts = json.loads(p.stdout)["items"] if p.returncode == 0 else []
    texts += [f["value"] for f in facts if f.get("updated_by") == "alice"]   # a shared fact is part of her message
    return texts, data["items"] + facts


LEDGER_HEADER = re.compile(r"^\d{1,2}:\d{2}(?::\d{2})?\s+([A-Za-z0-9_.-]+)\s+([A-Z]+)")


def alice_texts_ledger(project):
    path = os.path.join(project, "COORDINATION.md")
    if not os.path.exists(path):
        return [], []
    entries = []
    for line in open(path, encoding="utf-8", errors="replace").read().splitlines():
        m = LEDGER_HEADER.match(line.strip())
        if m:
            entries.append({"sender": m.group(1), "kind": m.group(2), "body": line.strip()})
        elif entries and line.strip():
            entries[-1]["body"] += "\n" + line.rstrip()
    return [e["body"] for e in entries if e["sender"] == "alice" and e["kind"] not in ("JOIN", "CLAIM", "RELEASE")], entries


# ---- one run --------------------------------------------------------------------------------------------------------

def git(project, env, *args):
    return subprocess.run(["git", "-c", "user.name=probe", "-c", "user.email=probe@example.invalid", "-C", project] + list(args),
                          env=env, capture_output=True, text=True, timeout=30)


def copy_secret(src, dst):
    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as out, open(src, "rb") as fh:   # open() follows a symlinked sign-in file
        out.write(fh.read())


def tool_dirs():
    dirs = []
    for tool in ("claude", "codex", "node", "git"):
        p = shutil.which(tool)
        if p:
            d = os.path.dirname(os.path.realpath(p)) if tool in ("node",) else os.path.dirname(p)
            if d not in dirs:
                dirs.append(d)
    return dirs


def run_one(args, condition, seed, out_dir):
    scratch = tempfile.mkdtemp(prefix="fh.")
    real = os.path.realpath(scratch)
    if real.startswith(ROOT + os.sep):
        raise SystemExit("the scratch folder %s is inside the checkout; set TMPDIR elsewhere" % scratch)
    dirs = {k: os.path.join(real, k) for k in ("proj", "home", "tmp", "bin", "claude-config", "codex-home", "out")}
    for d in dirs.values():
        os.makedirs(d)
    shim = os.path.join(dirs["bin"], "agentbus")
    with open(shim, "w") as fh:
        fh.write('#!/bin/sh\nexec "%s" "%s/bin/agentbus" "$@"\n' % (sys.executable, ROOT))
    os.chmod(shim, 0o755)
    base = {"HOME": dirs["home"], "TMPDIR": dirs["tmp"], "XDG_CONFIG_HOME": dirs["home"] + "/.config", "XDG_CACHE_HOME": dirs["home"] + "/.cache",
            "XDG_STATE_HOME": dirs["home"] + "/.state", "XDG_DATA_HOME": dirs["home"] + "/.local/share", "TERM": "dumb", "NO_COLOR": "1",
            "LANG": os.environ.get("LANG", "en_US.UTF-8"), "SHELL": "/bin/zsh", "USER": os.environ.get("USER", "probe"),
            "LOGNAME": os.environ.get("USER", "probe"), "PATH": ":".join([dirs["bin"]] + tool_dirs() + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])}
    env_a = dict(base, CLAUDE_CONFIG_DIR=dirs["claude-config"])
    env_b = dict(base, CODEX_HOME=dirs["codex-home"])
    if condition == "agentbus":
        env_a["AGENTBUS_AGENT"] = "alice"
        env_b["AGENTBUS_AGENT"] = "bob"
    proj = dirs["proj"]
    scenario.make_project(proj)
    gitenv = dict(base)
    for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "start"]):
        r = git(proj, gitenv, *cmd)
        if r.returncode:
            raise SystemExit("git %s failed: %s" % (cmd[0], r.stderr.strip()[:200]))
    if condition == "agentbus":
        for argv, env in ((["init", proj], base), (["setup", "claude"], env_a), (["setup", "codex"], env_b)):
            r = subprocess.run([shim] + argv, env=env, cwd=real, capture_output=True, text=True, timeout=60)
            if r.returncode:
                raise SystemExit("agentbus %s failed: %s" % (argv[0], (r.stderr or r.stdout).strip()[:300]))
    elif condition == "ledger":
        skill = open(os.path.join(HERE, "ledger_skill.md"), encoding="utf-8").read()
        os.makedirs(os.path.join(dirs["claude-config"], "skills", "ledger"))
        with open(os.path.join(dirs["claude-config"], "skills", "ledger", "SKILL.md"), "w", encoding="utf-8") as fh:
            fh.write(skill)
        with open(os.path.join(dirs["codex-home"], "AGENTS.md"), "w", encoding="utf-8") as fh:
            fh.write("# Ledger\n\n" + skill.split("---\n", 2)[2].lstrip())
    tag = "%s-seed%d" % (condition, seed)
    keep = os.path.join(out_dir, tag)
    os.makedirs(keep, exist_ok=True)
    rec = {"condition": condition, "seed": seed}

    # alice: Claude, headless
    copy_secret(args.claude_auth, os.path.join(dirs["claude-config"], ".credentials.json"))
    a = run_agent(["claude", "-p", scenario.prompt("alice", condition, seed), "--model", "sonnet", "--max-turns", str(args.a_max_turns),
                   "--max-budget-usd", str(args.a_budget), "--permission-mode", "bypassPermissions", "--setting-sources", "user",
                   "--strict-mcp-config", "--output-format", "stream-json", "--verbose", "--include-hook-events"],
                  env_a, proj, os.path.join(keep, "alice-stream.jsonl"), os.path.join(keep, "alice.err"), args.max_minutes * 60)
    os.remove(os.path.join(dirs["claude-config"], ".credentials.json"))
    rec["alice"] = dict(claude_summary(a["events"]), rc=a["rc"], seconds=a["seconds"], killed=a["killed"])
    texts, entries = alice_texts_agentbus(proj, shim) if condition == "agentbus" else alice_texts_ledger(proj)
    with open(os.path.join(keep, "channel-after-alice.json"), "w") as fh:
        json.dump(entries, fh, indent=1)
    status = git(proj, gitenv, "status", "--porcelain", "--untracked-files=all").stdout.splitlines()
    changed = sorted(l[3:] for l in status)
    rec["alice"]["posted"] = len(texts)
    rec["alice"]["drift"] = [p for p in changed if p not in ALICE_FILES and not p.startswith(CHANNEL_PATHS)]
    f = scenario.facts(seed)
    leaks = []
    for p in changed:
        if p.startswith(CHANNEL_PATHS) or not os.path.isfile(os.path.join(proj, p)):
            continue
        body = open(os.path.join(proj, p), encoding="utf-8", errors="replace").read()
        leaks += [p for s in (f["weight_unit"], f["date_name"]) if re.search(r"\b%s\b" % re.escape(s), body, re.I)]
    rec["alice"]["answers_in_files"] = sorted(set(leaks))
    t = subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_report.py"], cwd=proj, env=dict(base, PYTHONDONTWRITEBYTECODE="1"), capture_output=True, text=True, timeout=60)
    rec["alice"]["visible_tests_pass"] = t.returncode == 0

    # bob: Codex, headless
    copy_secret(args.codex_auth, os.path.join(dirs["codex-home"], "auth.json"))
    b = run_agent(["codex", "exec", "--dangerously-bypass-hook-trust", "-s", "workspace-write", "--json", "-o", os.path.join(keep, "bob-last.txt"),
                   scenario.prompt("bob", condition, seed)], env_b, proj, os.path.join(keep, "bob-events.jsonl"), os.path.join(keep, "bob.err"),
                  args.max_minutes * 60, command_cap=args.b_max_commands)
    os.remove(os.path.join(dirs["codex-home"], "auth.json"))
    steps = codex_steps(b["events"])
    with open(os.path.join(keep, "bob-steps.json"), "w") as fh:
        json.dump([dict(s, out=s["out"][:600]) for s in steps], fh, indent=1)
    side = ["claude-config", "check.py", "scenario.py", "first-handoff", "alice-stream", ROOT]
    grade = grade_b(steps, texts, side)
    ok, detail = scenario.check(proj, seed)
    t = subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_parse.py"], cwd=proj, env=dict(base, PYTHONDONTWRITEBYTECODE="1"), capture_output=True, text=True, timeout=60)
    rec["bob"] = dict(grade, rc=b["rc"], seconds=b["seconds"], killed=b["killed"], tokens=codex_tokens(b["events"]), visible_tests_pass=t.returncode == 0)
    rec["check"] = detail
    why = []
    if not ok:
        why.append("check failed")
    if grade["read_step"] is None:
        why.append("bob never read alice's message")
    elif grade["write_step"] is None:
        why.append("bob's write to feed/parse.py was not located in the transcript")
    elif not grade["read_before_write"]:
        why.append("bob wrote feed/parse.py before reading alice's message")
    if grade["side_channel_steps"]:
        why.append("bob touched something outside the project (steps %s)" % grade["side_channel_steps"])
    rec["passed"] = not why
    rec["why_not"] = why
    shutil.copy(os.path.join(proj, "feed", "parse.py"), os.path.join(keep, "bob-parse.py"))
    with open(os.path.join(keep, "run.json"), "w") as fh:
        json.dump(rec, fh, indent=1)
    shutil.rmtree(real)
    return rec


def leak_scan(out_dir, secret_files):
    """Count credential strings found in the kept files (never printed)."""
    secrets = set()

    def walk(x):
        if isinstance(x, str) and len(x) >= 20:
            secrets.add(x)
        elif isinstance(x, dict):
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    for p in secret_files:
        try:
            walk(json.load(open(p)))
        except (OSError, ValueError):
            pass
    hits = 0
    for dirpath, _, names in os.walk(out_dir):
        for n in names:
            text = open(os.path.join(dirpath, n), encoding="utf-8", errors="replace").read()
            hits += sum(1 for s in secrets if s in text)
    return hits


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, help="folder for transcripts and results.json (must be outside the checkout)")
    ap.add_argument("--condition", choices=("agentbus", "ledger", "both", "none"), default="both")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--seed-base", type=int, default=1)
    ap.add_argument("--max-minutes", type=int, default=10, help="wall-clock cap for each session")
    ap.add_argument("--a-max-turns", type=int, default=30)
    ap.add_argument("--a-budget", type=float, default=2.0, help="dollar cap for alice's session")
    ap.add_argument("--b-max-commands", type=int, default=60)
    ap.add_argument("--claude-auth", default=os.environ.get("CLAUDE_AUTH_FROM", os.path.expanduser("~/.claude/.credentials.json")))
    ap.add_argument("--codex-auth", default=os.environ.get("CODEX_AUTH_FROM", os.path.expanduser("~/.codex/auth.json")))
    args = ap.parse_args(argv)
    for tool in ("claude", "codex", "git"):
        if not shutil.which(tool):
            print("FAIL: %s is not on PATH" % tool)
            return 2
    for p in (args.claude_auth, args.codex_auth):
        if not os.path.isfile(p):
            print("FAIL: no sign-in file at %s (set CLAUDE_AUTH_FROM / CODEX_AUTH_FROM)" % p)
            return 2
    out_dir = os.path.abspath(args.out)
    if os.path.realpath(out_dir).startswith(ROOT + os.sep):
        print("FAIL: --out is inside the checkout")
        return 2
    os.makedirs(out_dir, exist_ok=True)
    home = os.path.expanduser("~")
    watched = [args.claude_auth, args.codex_auth] + [os.path.join(home, p) for p in (".claude/settings.json", ".codex/config.toml", ".codex/hooks.json", ".codex/AGENTS.md")]
    before = {p: sha_file(p) for p in watched}
    versions = {"claude": subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip(),
                "codex": subprocess.run(["codex", "--version"], capture_output=True, text=True).stdout.strip(),
                "agentbus": subprocess.run([sys.executable, os.path.join(ROOT, "bin", "agentbus"), "--version"], capture_output=True, text=True, cwd=tempfile.gettempdir()).stdout.strip()}
    log("versions: %s" % json.dumps(versions))
    conditions = ["agentbus", "ledger"] if args.condition == "both" else [args.condition]
    results = []
    for i in range(args.runs):
        for condition in conditions:
            seed = args.seed_base + i
            log("run %s seed %d ..." % (condition, seed))
            rec = run_one(args, condition, seed, out_dir)
            results.append(rec)
            log("  %s: alice %.0fs, bob %.0fs, check %s, read step %s write step %s%s" % (
                "PASS" if rec["passed"] else "FAIL", rec["alice"]["seconds"], rec["bob"]["seconds"], "ok" if rec["check"]["ok"] else "no",
                rec["bob"]["read_step"], rec["bob"]["write_step"], "" if rec["passed"] else " (" + "; ".join(rec["why_not"]) + ")"))
    after = {p: sha_file(p) for p in watched}
    changed = [os.path.basename(p) for p in watched if before[p] != after[p]]
    leaks = leak_scan(out_dir, [args.claude_auth, args.codex_auth])
    with open(os.path.join(out_dir, "results.json"), "w") as fh:
        json.dump({"versions": versions, "runs": results, "real_files_changed": changed, "credential_strings_in_kept_files": leaks}, fh, indent=1)
    log("real sign-in and config files changed: %s" % (changed or "none"))
    log("credential strings found in kept files: %d" % leaks)
    return 1 if (changed or leaks) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
