#!/usr/bin/env python3
"""Capture the storyboard's terminal frames from the real tool.

  python3 storyboard/capture/capture.py

Runs bin/agentbus (copied into a throwaway HOME, as an install would put it) on a pseudo-terminal of a
fixed size and records exactly what it writes, colour codes included. watch is captured live: the
script answers its start-up probe, lets it paint, keeps the last whole frame and quits it with q.
Everything runs in a mktemp -d directory with HOME, TMPDIR and the XDG dirs inside it; nothing outside
that directory is touched. The result is storyboard/frames/captured.js (window.CAPTURED).

Paths are rewritten after capture so the frames read as a real machine would (~/src/app,
/Users/you, /usr/bin/python3) instead of the throwaway directory.
"""
import fcntl
import json
import os
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, "storyboard", "frames", "captured.js")
CLEAR = ("AGENTBUS_DB", "AGENTBUS_AGENT", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_PID", "CLAUDECODE")

ROOT = tempfile.mkdtemp(prefix="agentbus-storyboard-")
HOME = os.path.join(ROOT, "home")
APP = os.path.join(HOME, "src", "app")
BIN = os.path.join(HOME, ".local", "bin")
FRAMES = {}


def base_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_") and k not in CLEAR}
    env.update(HOME=HOME, TMPDIR=os.path.join(ROOT, "tmp"), SHELL="/bin/sh", TERM="xterm-256color",
               LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", AGENTBUS_NO_UPDATE_CHECK="1",
               AGENTBUS_CLAUDE_BIN=os.path.join(BIN, "claude-stub"),
               PATH=BIN + ":/usr/bin:/bin", GIT_CONFIG_NOSYSTEM="1", TZ="UTC")
    for x in ("STATE", "CACHE", "CONFIG", "DATA"):
        env[f"XDG_{x}_HOME"] = os.path.join(ROOT, "xdg", x.lower())
    env.pop("NO_COLOR", None)
    return env


def setup():
    for d in (BIN, APP, os.path.join(ROOT, "tmp"), *(os.path.join(ROOT, "xdg", x) for x in ("state", "cache", "config", "data"))):
        os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(REPO, "bin", "agentbus"), os.path.join(BIN, "agentbus"))
    os.chmod(os.path.join(BIN, "agentbus"), 0o755)
    with open(os.path.join(BIN, "claude-stub"), "w") as f:
        f.write("#!/bin/sh\necho '2.1.0 (Claude Code)'\n")
    os.chmod(os.path.join(BIN, "claude-stub"), 0o755)
    env = base_env()
    with open(os.path.join(HOME, ".gitconfig"), "w") as f:
        f.write("[user]\n\tname = you\n\temail = you@example.com\n[init]\n\tdefaultBranch = main\n[color]\n\tui = always\n")
    subprocess.run(["git", "init", "-q", APP], env=env, check=True)


def clean(text):
    for real in (os.path.realpath(HOME), HOME):
        text = text.replace("'" + real + "/", "'/Users/you/").replace(real + "/src", "~/src").replace(real, "~")
    for real in (os.path.realpath(ROOT), ROOT):
        text = text.replace(real + "/tmp", "/tmp").replace(real, "/tmp")
    py = os.path.realpath(sys.executable)
    for p in {py, sys.executable, "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"}:
        text = text.replace(p, "/usr/bin/python3")
    return text


def spawn(argv, cols, rows, env, cwd):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=env, cwd=cwd,
                         close_fds=True, start_new_session=True)
    os.close(slave)
    return p, master


def drain(master, secs, answer_probe=True):
    got, end = b"", time.monotonic() + secs
    while time.monotonic() < end:
        r, _, _ = select.select([master], [], [], 0.05)
        if not r:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        got += chunk
        if answer_probe and b"\x1b[6n" in chunk:
            os.write(master, b"\x1b[2;2R")  # the start-up probe: a narrow terminal
    return got


def run(argv, cols=80, rows=24, now=None, stdin=None, extra=None):
    """One command on a terminal of COLS x ROWS: everything it wrote."""
    env = base_env()
    if now:
        env["AGENTBUS_TEST_NOW"] = now
    env.update(extra or {})
    if stdin is not None:
        p = subprocess.run(argv, input=stdin, env=env, cwd=APP, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return p.stdout.decode()
    p, master = spawn(argv, cols, rows, env, APP)
    got = b""
    while True:
        got += drain(master, 0.2, answer_probe=False)
        if p.poll() is not None:
            got += drain(master, 0.2, answer_probe=False)
            break
    os.close(master)
    return got.decode("utf-8", "replace")


def shot(fid, argv, cols=80, rows=24, prompt=True, now=None, note="", show=None, stdin=b"", wrap=True, edit=None, **kw):
    """A command's output as a terminal of COLS shows it. It runs with stdout on a pipe so nothing is wrapped
    yet; the throwaway paths are rewritten, then each line is wrapped by the tool's own wrap_line, so the
    rows break where they would on a real machine's paths."""
    text = clean(run(argv, cols, rows, now=now, stdin=stdin, **kw)).replace("\r\n", "\n")
    for was, now_text in (edit or ()):
        assert was in text, was
        text = text.replace(was, now_text)
    if wrap:
        text = "\n".join(TOOL.wrap_line(l, cols) for l in text.split("\n"))
    cmd = show or " ".join(argv)
    head = f"\x1b[2m~/src/app\x1b[0m $ {cmd}\n" if prompt else ""
    rows = fit_rows(head + text, cols, rows)
    FRAMES[fid] = {"cols": cols, "rows": rows, "cmd": cmd, "ansi": (head + text).replace("\n", "\r\n"),
                   "source": "edited" if edit else "captured", "note": note}
    return text


def load_tool():
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("agentbus_mod", os.path.join(REPO, "bin", "agentbus"))
    spec = importlib.util.spec_from_loader("agentbus_mod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


TOOL = load_tool()


def fit_rows(text, cols, at_least):
    """Rows the text fills on a terminal COLS wide (a long line wraps), plus one for the prompt after it."""
    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text.rstrip("\n"))
    n = sum(max(1, -(-sum(TOOL.char_width(c) for c in line) // cols)) for line in plain.split("\n"))
    return max(n + 1, min(at_least, 4))


def last_frame(raw):
    """The last whole repaint watch wrote: from its last cursor-home to the clear-below that ends it."""
    end = raw.rfind("\x1b[J")
    start = raw.rfind("\x1b[H", 0, end)
    return raw[start:end + 3] if start >= 0 and end >= 0 else raw


class Watch:
    """agentbus watch, live on a terminal; snap() keeps its current screen."""

    def __init__(self, cols, rows, now=None, extra=None, args=()):
        env = base_env()
        if now:
            env["AGENTBUS_TEST_NOW"] = now
        env.update(extra or {})
        self.cols, self.rows = cols, rows
        self.p, self.master = spawn(["agentbus", "watch", *args], cols, rows, env, APP)
        self.raw, end = "", time.monotonic() + 10
        while "\x1b[J" not in self.raw and time.monotonic() < end:  # start-up can be slow on a busy machine
            self.raw += drain(self.master, 0.3).decode("utf-8", "replace")
        self.raw += drain(self.master, 0.4).decode("utf-8", "replace")

    def snap(self, fid, wait=0.0, note="", source="captured"):
        self.raw += drain(self.master, wait).decode("utf-8", "replace") if wait else ""
        frame = last_frame(self.raw)
        if "\x1b[J" not in frame:
            raise SystemExit(f"{fid}: no whole watch frame captured; it wrote: {self.raw[-600:]!r}")
        FRAMES[fid] = {"cols": self.cols, "rows": self.rows, "cmd": "agentbus watch", "source": source,
                       "ansi": "\x1b[2J" + clean(frame), "note": note}
        self.raw = self.raw[-200000:]

    def quit(self):
        os.write(self.master, b"q")
        drain(self.master, 0.8)
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait()
        os.close(self.master)


def ab(*args):
    return ["agentbus", *args]


def hook(dialect, sid, now):
    payload = json.dumps({"session_id": sid, "cwd": APP, "hook_event_name": "SessionStart", "source": "startup"})
    extra = {"CLAUDE_PID": str(os.getpid())} if dialect == "claude" else {}
    out = run(ab("hook", dialect, "SessionStart"), now=now, stdin=payload.encode(), extra=extra)
    return json.loads(out)["hookSpecificOutput"]["additionalContext"]


def write_file(rel, text):
    path = os.path.join(APP, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


# The first-handoff example (proposed in the storyboard; PR B builds examples/first-handoff/).
UPLOAD = '''MAX_UPLOAD_BYTES = None  # claude sets this


def check_size(n_bytes):
    """Raise TooLarge (HTTP 413) when an upload is over the limit."""
'''
TEST_GUESS = '''from app.upload import check_size, TooLarge
import pytest

LIMIT = 10 * 1024 * 1024  # guess: 10 MiB


def test_at_limit_passes():
    check_size(LIMIT)


def test_one_over_is_refused():
    with pytest.raises(TooLarge):
        check_size(LIMIT + 1)
'''
TEST_ANSWER = TEST_GUESS.replace("LIMIT = 10 * 1024 * 1024  # guess: 10 MiB", "LIMIT = 5_000_000  # from claude, bus message #2")


def first_run():
    shot("init", ab("init", "."), cols=92, rows=10, now="2026-11-05T16:40:00Z",
         edit=[("install agentbus so your agents have it on PATH (see the README), then ", "")],
         note="one line as an installed agentbus prints it: this capture ran a copied script, which also asks you to install")
    shot("setup-claude", ab("setup", "claude"), cols=92, rows=8, now="2026-11-05T16:40:20Z")
    shot("setup-codex", ab("setup", "codex"), cols=92, rows=10, now="2026-11-05T16:40:30Z")
    # Readiness: before the Codex hooks are trusted, only Claude's session has joined.
    ctx_claude = hook("claude", "7d2c1f4e-claude-first-run", "2026-11-05T16:41:00Z")
    shot("who-one", ab("who"), cols=92, rows=6, now="2026-11-05T16:41:20Z",
         note="Codex is started but its hooks are not trusted yet, so only Claude has joined")
    ctx_codex = hook("codex", "019a5e6b-codex-first-run", "2026-11-05T16:42:00Z")
    shot("who-two", ab("who"), cols=92, rows=6, now="2026-11-05T16:42:10Z", note="both sessions on the same bus")
    shot("doctor", ab("doctor"), cols=92, rows=14, now="2026-11-05T16:42:20Z")
    FRAMES["ctx"] = {"claude": clean(ctx_claude), "codex": clean(ctx_codex)}
    claude, codex = ctx_claude.split(" as ")[1].split(".")[0], ctx_codex.split(" as ")[1].split(".")[0]
    FRAMES["names"] = {"claude": claude, "codex": codex}

    # The first handoff: codex needs a number only claude was given.
    write_file("app/upload.py", UPLOAD)
    write_file("tests/test_upload.py", TEST_GUESS)
    env = base_env()
    subprocess.run(["git", "add", "-A"], cwd=APP, env=env, check=True)
    subprocess.run(["git", "commit", "-qm", "codex: first draft of the size tests"], cwd=APP, env=env, check=True)
    run(ab("--as", claude, "goal", "Uploads refuse files over the size limit"), now="2026-11-05T16:43:00Z")
    run(ab("--as", claude, "claim", "app/upload.py", "--purpose", "size check"), now="2026-11-05T16:43:05Z")
    run(ab("--as", codex, "claim", "tests/test_upload.py", "--purpose", "size tests"), now="2026-11-05T16:43:10Z")
    shot("ask", ab("--as", codex, "post", "What is the upload size limit, in bytes? I am pinning it in tests/test_upload.py.",
                   "--to", claude, "--kind", "question"), cols=92, rows=6, now="2026-11-05T16:44:00Z",
         show=f"agentbus --as {codex} post \"What is the upload size limit, in bytes? I am pinning it in tests/test_upload.py.\" --to {claude} --kind question")
    shot("claude-inbox", ab("--as", claude, "inbox"), cols=92, rows=6, now="2026-11-05T16:44:30Z")
    shot("answer", ab("--as", claude, "post", "5_000_000 bytes, decimal 5 MB. Exactly 5_000_000 passes; 5_000_001 gets 413.",
                      "--to", codex, "--kind", "answer", "--reply-to", "1"), cols=92, rows=6, now="2026-11-05T16:44:50Z",
         show=f"agentbus --as {claude} post \"5_000_000 bytes, decimal 5 MB. Exactly 5_000_000 passes; 5_000_001 gets 413.\" --to {codex} --kind answer --reply-to 1")
    shot("codex-inbox", ab("--as", codex, "inbox"), cols=92, rows=6, now="2026-11-05T16:45:10Z")
    write_file("tests/test_upload.py", TEST_ANSWER)
    shot("diff", ["git", "--no-pager", "diff"], cols=92, rows=14, show="git diff", wrap=False)
    run(ab("--as", codex, "post", "tests/test_upload.py now pins 5_000_000 from your answer; 2 tests green.",
           "--to", claude, "--kind", "done", "--reply-to", "2"), now="2026-11-05T16:46:00Z")
    for cols, rows in ((100, 30), (60, 20)):
        w = Watch(cols, rows, now="2026-11-05T16:46:20Z")
        w.snap(f"first-watch-{cols}")
        w.quit()


def watch_states():
    # A demo-shaped bus with three agents, for the claim hand-over.
    shutil.rmtree(os.path.join(APP, ".agentbus"))
    run(ab("init", "."), now="2026-11-05T16:30:00Z")
    run(ab("--as", "lead", "join", "--role", "planner"), now="2026-11-05T16:30:10Z")
    run(ab("--as", "worker", "join", "--role", "implementer", "--tool", "codex"), now="2026-11-05T16:30:20Z")
    run(ab("--as", "tests", "join", "--role", "tester"), now="2026-11-05T16:30:30Z")
    run(ab("--as", "lead", "goal", "Move auth to the new token API"), now="2026-11-05T16:31:00Z")
    run(ab("--as", "lead", "ctx", "set", "token_ttl", "7 days"), now="2026-11-05T16:31:30Z")
    run(ab("--as", "lead", "post", "Move src/auth/ onto the new token API.", "--to", "worker", "--kind", "handoff"), now="2026-11-05T16:32:00Z")
    run(ab("--as", "worker", "claim", "src/auth/", "--purpose", "token refactor"), now="2026-11-05T16:33:00Z")
    run(ab("--as", "tests", "claim", "tests/auth/", "--purpose", "token tests"), now="2026-11-05T16:33:30Z")
    run(ab("--as", "tests", "post", "Is the 401 body part of the contract?", "--to", "worker", "--kind", "question"), now="2026-11-05T16:38:00Z")
    run(ab("--as", "worker", "post", "Plain text for now.", "--to", "tests", "--kind", "answer", "--reply-to", "2"), now="2026-11-05T16:39:00Z")
    run(ab("--as", "worker", "post", "Auth is moved and tests pass. Over to you for review.", "--to", "lead", "--kind", "handoff"), now="2026-11-05T16:44:00Z")
    for cols, rows in ((100, 30), (60, 20)):
        w = Watch(cols, rows, now="2026-11-05T16:44:30Z")
        w.snap(f"handover-before-{cols}", note="worker holds src/auth/")
        w.quit()
    run(ab("--as", "worker", "release", "src/auth/"), now="2026-11-05T16:44:40Z")
    run(ab("--as", "lead", "claim", "src/auth/", "--purpose", "review"), now="2026-11-05T16:44:41Z")
    for cols, rows in ((100, 30), (60, 20)):
        w = Watch(cols, rows, now="2026-11-05T16:44:42Z")
        w.snap(f"handover-after-{cols}", note="lead holds src/auth/ (today's watch: no marker)")
        w.quit()
    for cols, rows, extra, fid in ((100, 30, {"NO_COLOR": "1"}, "handover-nocolor-100"),
                                   (60, 20, {"NO_COLOR": "1"}, "handover-nocolor-60")):
        w = Watch(cols, rows, now="2026-11-05T16:44:42Z", extra=extra)
        w.snap(fid, note="NO_COLOR=1")
        w.quit()
    shot("handover-pipe", ab("watch"), cols=100, rows=30, prompt=True, now="2026-11-05T16:44:42Z", wrap=False,
         show="agentbus watch | cat", extra={"COLUMNS": "100", "LINES": "30"}, note="stdout is a pipe: one frame, no colour")
    # Empty state: a goal and a fact, nobody on the bus.
    shutil.rmtree(os.path.join(APP, ".agentbus"))
    run(ab("init", "."), now="2026-11-05T16:20:00Z")
    run(ab("--as", "lead", "join", "--role", "planner"), now="2026-11-05T16:20:05Z")
    run(ab("--as", "lead", "goal", "Move auth to the new token API"), now="2026-11-05T16:20:10Z")
    run(ab("--as", "lead", "ctx", "set", "token_ttl", "7 days"), now="2026-11-05T16:20:20Z")
    run(ab("--as", "lead", "leave"), now="2026-11-05T16:20:30Z")
    for cols, rows in ((100, 30), (60, 20)):
        w = Watch(cols, rows, now="2026-11-05T16:21:00Z")
        w.snap(f"empty-goal-{cols}", note="today's empty state, bus with a goal and a fact")
        w.quit()
    shutil.rmtree(os.path.join(APP, ".agentbus"))
    run(ab("init", "."), now="2026-11-05T16:20:00Z")
    w = Watch(100, 30, now="2026-11-05T16:21:00Z")
    w.snap("empty-bare-100", note="today's empty state, a fresh bus")
    w.quit()


def demo_live():
    """The demo's own steps, run at the demo's pace while watch is open on the same bus."""
    steps = list(TOOL.DEMO_STEPS)
    steps.append(("Proposed: the lead takes the folder for review, so the claim changes hands.",
                  ("--as", "lead", "claim", "src/auth/", "--purpose", "review"), 0))
    shutil.rmtree(os.path.join(APP, ".agentbus"))
    run(ab("init", "."))
    caps = []
    for cols, rows, tag in ((100, 30, "100"), (60, 20, "60")):
        if os.path.exists(os.path.join(APP, ".agentbus")):
            shutil.rmtree(os.path.join(APP, ".agentbus"))
        run(ab("init", "."))
        w = Watch(cols, rows)
        w.snap(f"demo-{tag}-0", note="watch opens on the empty demo bus")
        for i, (caption, args, _want) in enumerate(steps, 1):
            out = run(ab(*args), cols=cols)
            if tag == "100":
                caps.append({"step": i, "caption": caption, "command": "agentbus " + " ".join(
                    a if " " not in a else '"' + a + '"' for a in args), "output": clean(out)})
            w.snap(f"demo-{tag}-{i}", wait=1.25, note=caption)
        w.snap(f"demo-{tag}-end", wait=3.2, note="3 s after the last step: the marks have faded")
        w.quit()
    FRAMES["demo-steps"] = caps
    shot("demo-pipe", ab("demo", "--no-pause"), cols=92, rows=40, show="agentbus demo | cat", wrap=False,
         note="stdout is a pipe: the tour as text")


def main():
    setup()
    try:
        first_run()
        watch_states()
        demo_live()
    finally:
        shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("// Generated by storyboard/capture/capture.py from the real bin/agentbus. Do not edit.\n")
        f.write("window.CAPTURED = " + json.dumps(FRAMES, indent=1, ensure_ascii=False) + ";\n")
    print(f"wrote {len(FRAMES)} frames to {os.path.relpath(OUT, REPO)}")


if __name__ == "__main__":
    main()
