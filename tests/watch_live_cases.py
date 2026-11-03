"""Live `agentbus watch` sessions on a pty for tests/test_watch_keys.sh: python3 watch_live_cases.py CASE.

Each case starts watch in its own process group on its own pty (term_oracle.PtySession), waits only on frame
content with a bound (never a fixed sleep), and kills only what it started. The bus is $AGENTBUS_DB, filled by
`setup`: the golden fixture's sample bus three days back (ages are whole days and stay put while a case runs) plus
#10, a 400-character answer to #9.
"""
import base64
import os
import signal
import sqlite3
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from term_oracle import PtySession  # noqa: E402
from agentbus_cmd import agentbus_argv  # noqa: E402
from watch_case import W, bus_state, bin_path  # noqa: E402

DB = os.environ.get("AGENTBUS_DB", "")
ROOT = os.path.dirname(os.path.dirname(DB))  # the folder holding .agentbus
BODY10 = ("The tokens are RS256 because the spec draft wins and the old service is going away. " * 6)[:400]
CASES = {}
# Every wait is on an event (a frame, a sentinel, an exit) and ends at this deadline only if the event never comes:
# a loaded CI runner may be slow, never wrong. No case asserts on elapsed time.
DEADLINE = 60


def case(fn):
    CASES[fn.__name__] = fn
    return fn


def env(**kw):
    """A colour terminal; emoji off so section titles start their rows (the emoji frames are golden-tested)."""
    e = dict(os.environ, TERM="xterm-256color", AGENTBUS_NO_EMOJI="1")
    for k in ("COLUMNS", "LINES", "NO_COLOR", "AGENTBUS_ASCII"):
        e.pop(k, None)
    e.update(kw)
    return e


def start(*args, cols=100, rows=30, interval="0.2", argv=None, wait_for=("following", "not readable"), **kw):
    s = PtySession((argv or agentbus_argv()) + ["watch", "--interval", interval, *args], env(**kw), cols=cols, rows=rows)
    try:
        s.until(lambda t: any(w in t for w in wait_for), DEADLINE, "the first frame")
    except BaseException:
        s.close()
        raise
    return s


def sel_row(f):
    return next((r for r in f if r.startswith(">")), None)


def key(s, data, cond, what, seconds=DEADLINE):
    m = s.mark()
    s.send(data)
    return s.frame_after(m, cond, seconds, what)


def settled(s, cond, what):
    """The raw bytes of a fresh frame for which cond holds (a refresh is drawn every tick)."""
    m = s.mark()
    s.frame_after(m, cond, DEADLINE, what)
    return s.frames(m, raw=True)[[i for i, f in enumerate(s.frames(m)) if cond(f)][-1]]


def restore():
    """Put back the bus `setup` made (good.db beside the bus folder), dropping any -wal a writer left."""
    for side in ("-wal", "-shm", "-journal"):
        try:
            os.unlink(DB + side)
        except FileNotFoundError:
            pass
    with open(os.path.join(os.path.dirname(ROOT), "good.db"), "rb") as src, open(DB, "wb") as dst:
        dst.write(src.read())


def resident_kb(pid):
    """A process's resident size in KB, without external tools on Linux (/proc) and with ps on macOS."""
    try:
        with open(f"/proc/{pid}/status") as f:
            return next(int(l.split()[1]) for l in f if l.startswith("VmRSS:"))
    except FileNotFoundError:
        r = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, timeout=DEADLINE)
        return int(r.stdout.split()[0])


def post(*args):
    r = subprocess.run(agentbus_argv() + list(args), env=env(), capture_output=True, text=True, timeout=DEADLINE)
    assert r.returncode == 0, r.stderr


@case
def setup():
    W.make_bus(DB)
    c = sqlite3.connect(DB)
    c.execute("INSERT INTO messages(id, ts, sender, recipient, kind, topic, body, reply_to) "
              "VALUES(10, '2026-10-29T16:45:00Z', 'claude', 'tests', 'answer', 'auth', ?, 9)", (BODY10,))
    c.commit()
    c.close()


@case
def keys():
    s = start()
    try:
        f = key(s, b"\x1b[A", lambda f: sel_row(f) and "#10" in sel_row(f), "Up to select the newest message")
        assert s.p.poll() is None, "an arrow key quit watch"
        assert any("paused" in r for r in f), f
        key(s, b"\x1b[A", lambda f: sel_row(f) and "#9" in sel_row(f), "Up to move to #9")
        key(s, b"k", lambda f: sel_row(f) and "#8" in sel_row(f), "k to move to #8")
        key(s, b"j", lambda f: sel_row(f) and "#9" in sel_row(f), "j to move back to #9")
        key(s, b"G", lambda f: sel_row(f) is None and any("following" in r for r in f), "G to follow again")
        f = key(s, b"\t", lambda f: any(r.startswith("Agents") and "j/k move" in r for r in f), "Tab: Agents says j/k move")
        assert not any(r.startswith("Messages") and "j/k move" in r for r in f), f
        f = key(s, b"\t", lambda f: any(r.startswith("Claims") and "j/k move" in r for r in f), "Tab: Claims says j/k move")
        assert not any(r.startswith("Agents") and "j/k move" in r for r in f), f
        key(s, b"4/kind:question", lambda f: any(r.startswith("Messages  2 of 10") for r in f)
            and f[-1].startswith("/kind:question_"), "/ then kind:question, q typed as text")
        assert s.p.poll() is None, "q in the filter input quit watch"
        key(s, b"\r", lambda f: f[-1].startswith("  /kind:question") and "Esc clear" in f[-1], "Enter keeps the filter")
        key(s, b"\x1b", lambda f: any(r.startswith("Messages  10") for r in f) and not f[-1].startswith("  /"),
            "Esc clears the kept filter")
        # Enter on the newest message: the whole 400-character body, wrapped; Esc: the very same overview frame.
        raw0 = settled(s, lambda f: any("following" in r for r in f) and f[0].startswith(" "), "the overview")
        f = key(s, b"\r", lambda f: "message #10" in f[0] and any(r.startswith("  reply") for r in f), "Enter on the newest")
        body = " ".join(r.strip() for r in f if r.startswith("    ") and not r.startswith("     "))
        assert BODY10.strip() in body, ("a 400-character body was cut", body)
        m = s.mark()
        s.send(b"\x1b")
        s.frame_after(m, lambda f: "message #10" not in f[0], DEADLINE, "Esc back to the overview")
        assert s.frames(m, raw=True)[-1] == raw0, "Esc did not return to the overview frame byte for byte"
        # Enter on #7, j j to #9, Enter: Esc shows #7 as it was; q the overview as it was; q quits.
        key(s, b"kkkk", lambda f: sel_row(f) and "#7" in sel_row(f), "#7 selected")
        over7 = settled(s, lambda f: sel_row(f) and "#7" in sel_row(f), "the paused overview")
        key(s, b"\r", lambda f: "message #7" in f[0] and any(r.startswith("* #7") for r in f), "Enter on #7")
        key(s, b"jj", lambda f: "message #7" in f[0] and sel_row(f) and "#9" in sel_row(f), "j j to #9 in the thread")
        at7 = settled(s, lambda f: "message #7" in f[0], "the #7 detail")
        key(s, b"\r", lambda f: "message #9" in f[0] and "back to #7" in f[-1], "Enter on #9 opens it on top")
        m = s.mark()
        s.send(b"\x1b")
        s.frame_after(m, lambda f: "message #7" in f[0], DEADLINE, "Esc back to #7")
        assert s.frames(m, raw=True)[-1] == at7, "Esc did not restore #7 as it was"
        m = s.mark()
        s.send(b"q")
        s.frame_after(m, lambda f: "message #" not in f[0], DEADLINE, "q back to the overview")
        assert s.frames(m, raw=True)[-1] == over7, "q in a detail did not return to the overview byte for byte"
        assert s.p.poll() is None, "q in a detail quit watch"
        key(s, b"?", lambda f: any(r.startswith("Look closer") for r in f), "? shows the help page")
        key(s, b"\x1b", lambda f: not any(r.startswith("Look closer") for r in f), "Esc closes help")
        s.send(b"q")
        assert s.wait(DEADLINE) == 0
    finally:
        s.close()


@case
def pause():
    s = start()
    try:
        f = key(s, b"p", lambda f: any(r.startswith("Messages") and "paused at" in r for r in f), "p pauses")
        frozen = [r for r in f if not r.startswith("Messages")]
        post("--as", "codex", "post", "posted while paused", "--to", "claude")
        f = s.frame_after(s.mark(), lambda f: any("+1 new" in r for r in f), DEADLINE, "+1 new while paused")
        assert [r for r in f if not r.startswith("Messages")] == frozen, "the view changed while paused"
        # pause-freezes-display: more posts over several ticks change no row but the Messages title
        for i in range(3):
            post("--as", "codex", "post", f"more {i}")
        m = s.mark()
        s.frame_after(m, lambda f: any("+4 new" in r for r in f), DEADLINE, "+4 new")
        later = s.frame_after(s.mark(), lambda f: True, DEADLINE, "two ticks later")
        for f in s.frames(m) + [later]:
            assert [r for r in f if not r.startswith("Messages")] == frozen, ("a row changed while paused", f)
        f = key(s, b"p", lambda f: any("posted while paused" in r for r in f), "p follows and shows the message")
        assert not any("new" in r and "+" in r for r in f if r.startswith("Messages")), f
        s.send(b"q")
        assert s.wait(DEADLINE) == 0
    finally:
        s.close()


@case
def rollover():
    """pause-rollover-pty: paused on #9, 200 more messages arrive; #9 stays selected, +200 new; a resize keeps it."""
    s = start()
    try:
        key(s, b"kk", lambda f: sel_row(f) and "#9" in sel_row(f), "k k selects #9")
        c = sqlite3.connect(DB)
        c.executemany("INSERT INTO messages(ts, sender, recipient, kind, body) VALUES('2026-10-29T16:50:00Z', 'codex', '*', "
                      "'note', ?)", [(f"token suite run {i}",) for i in range(200)])
        c.commit()
        c.close()
        f = s.frame_after(s.mark(), lambda f: any("+200 new" in r for r in f), DEADLINE, "+200 new")
        assert sel_row(f) and "#9" in sel_row(f), f
        m = s.mark()
        s.resize(60, 20)
        f = s.frame_after(m, lambda f: len(f[0]) <= 59 and any("+200" in r for r in f), DEADLINE, "the narrow redraw")
        assert sel_row(f) and "#9" in sel_row(f) and len(f) == 20, f
        s.send(b"q")
        assert s.wait(DEADLINE) == 0
    finally:
        s.close()
        c = sqlite3.connect(DB)
        c.execute("DELETE FROM messages WHERE id > 10")
        c.commit()
        c.close()


@case
def exits():
    """q, Ctrl-C (SIGINT, which the terminal sends for the key; step() maps a raw C-c byte to quit too), SIGTERM and
    SIGHUP: each leaves the terminal modes as they were and ends with the cursor shown and the alternate screen left;
    SIGHUP exits 129."""
    for how, want in (("q", 0), ("SIGINT", 0), ("SIGTERM", 0), ("SIGHUP", 129)):
        s = start()
        try:
            key(s, b"\t", lambda f: any(r.startswith("Agents") and "j/k move" in r for r in f), "a key before " + how)
            if how == "q":
                s.send(b"q")
            else:
                s.signal(getattr(signal, how))
            try:
                rc = s.wait(DEADLINE)
            except AssertionError as e:
                raise AssertionError(f"{how}: {e}")
            assert rc == want, (how, rc)
            assert s.termios_now() == s.before, (how, "terminal modes not restored")
            assert s.buf.rstrip(b"\r\n").endswith(b"\x1b[?25h\x1b[?1049l"), (how, s.buf[-80:])
            assert b"Traceback" not in s.buf, (how, s.buf[-1500:])
        finally:
            s.close()


@case
def refused():
    """A refused bus says so and names the fix; the view state (filter, selection, pause, an open detail) survives
    it, and once the bus reads again r brings back the same frame (view-survives-errors)."""
    good = os.path.join(os.path.dirname(ROOT), "good.db")
    s = start()
    try:
        key(s, b"/from:c\r", lambda f: f[-1].startswith("  /from:c"), "a kept filter")
        key(s, b"3j", lambda f: sel_row(f) and "runtime" in sel_row(f), "3 j selects the runtime fact")
        key(s, b"p", lambda f: any("paused at" in r for r in f), "p pauses")
        key(s, b"\r", lambda f: "fact runtime" in f[0] and any("History" in r for r in f), "Enter opens the fact")
        before = settled(s, lambda f: "fact runtime" in f[0] and any("History" in r for r in f), "the fact detail")
        c = sqlite3.connect(DB)
        c.execute("ALTER TABLE messages ADD COLUMN extra TEXT")
        c.commit()
        c.close()
        f = s.frame_after(s.mark(), lambda f: "not readable" in f[0], DEADLINE, "the refused frame")
        text = "\n".join(f)
        assert "This bus could not be read" in text and "Run: agentbus upgrade" in text, text
        assert "Agents" not in text and "Messages" not in text, text
        restore()
        m = s.mark()
        s.send(b"r")
        s.frame_after(m, lambda f: "fact runtime" in f[0], DEADLINE, "r brings the bus back")
        after = settled(s, lambda f: "fact runtime" in f[0] and any("History" in r for r in f), "the fact detail again")
        assert after == before, ("the view did not come back as it was", s.frames(m)[-1])
        key(s, b"q", lambda f: "fact runtime" not in f[0] and f[-1].startswith("  /from:c"), "q back to the filtered overview")
        s.send(b"q")
        assert s.wait(DEADLINE) == 0
    finally:
        s.close()


@case
def latency():
    """R13 and R5, by construction rather than by the clock: a snapshot read is held blocked inside watch (a
    wrapper parks it until the test lets it go), and every key still redraws, and q still exits, while that read
    is in flight. Then a real lock on the bus: the last frame stays, with waiting · Ns old."""
    work = os.path.dirname(ROOT)
    parked, release = os.path.join(work, "read.parked"), os.path.join(work, "read.release")
    for f in (parked, release):
        if os.path.exists(f):
            os.unlink(f)
    wrapper = os.path.join(work, "park_read.py")
    with open(wrapper, "w") as f:
        f.write("import os, runpy, sys, time\n"
                "g = runpy.run_path(sys.argv[1], run_name='agentbus_park')\n"
                "G = g['render_watch'].__globals__\n"
                "real, n, parked, release = G['watch_snapshot'], [0], sys.argv[2], sys.argv[3]\n"
                "def parks(*a, **k):\n"
                "    n[0] += 1\n"
                "    if n[0] == 3:  # the third read waits until the test releases it\n"
                "        open(parked, 'w').close()\n"
                "        while not os.path.exists(release):\n"
                "            time.sleep(0.01)\n"
                "    return real(*a, **k)\n"
                "G['watch_snapshot'] = parks\n"
                "sys.argv = ['agentbus'] + sys.argv[4:]\n"
                "G['contract_main']()\n")
    s = start(argv=[os.environ.get("PYTHON") or "python3", wrapper, bin_path(), parked, release])
    try:
        end = time.monotonic() + DEADLINE
        while not os.path.exists(parked):  # the event: a read is now in flight and will not finish by itself
            assert time.monotonic() < end, "the third read never started"
            s.pump(0.02)
        key(s, b"k", lambda f: sel_row(f) is not None, "k while a read is parked")
        for i in range(20):
            want = "#9" if i % 2 == 0 else "#10"
            key(s, b"k" if i % 2 == 0 else b"j", lambda f: (sel_row(f) or "> -").split()[1] == want,
                f"the redraw for key {i} while a read is parked")
        assert not os.path.exists(release), "the read was let go early"
        s.send(b"q")
        assert s.wait(DEADLINE) == 0, "q did not exit while a read was in flight"
        assert s.termios_now() == s.before, "terminal modes not restored after q with a read in flight"
    finally:
        open(release, "w").close()
        s.close()
    s = start()
    try:
        hold = sqlite3.connect(DB, timeout=0)
        hold.execute("PRAGMA locking_mode=EXCLUSIVE")
        hold.execute("SELECT COUNT(*) FROM messages").fetchone()
        try:
            f = s.frame_after(s.mark(), lambda f: "waiting" in f[0] and "s old" in f[0], DEADLINE,
                              "waiting · Ns old in the header")
            assert any(r.startswith("Messages  10") for r in f), ("the busy frame lost the last frame", f)
            key(s, b"\t", lambda f: any(r.startswith("Agents") and "j/k move" in r for r in f), "Tab with the bus locked")
            s.send(b"q")
            assert s.wait(DEADLINE) == 0
        finally:
            hold.close()
        assert s.termios_now() == s.before, "terminal modes not restored after q on a locked bus"
    finally:
        s.close()


@case
def dumb():
    s = PtySession(agentbus_argv() + ["watch"], env(TERM="dumb"), cols=100, rows=30)
    try:
        assert s.wait(DEADLINE) == 0
        out = s.buf.decode("utf-8", "replace")
        assert "\x1b" not in out, ("escape codes under TERM=dumb", out[:400])
        assert "agentbus: TERM=dumb, printing one frame. Use a terminal for the live view." in out, out
        assert out.count("Messages  10") == 1 and "#10" in out and "q quit" not in out, out
    finally:
        s.close()


@case
def narrow():
    """NO_COLOR and AGENTBUS_NO_EMOJI at 40 columns: every message row says its kind as a code."""
    s = start(cols=40, rows=30, NO_COLOR="1", AGENTBUS_NO_EMOJI="1")
    try:
        f = s.frame_after(0, lambda f: any(r.startswith("Messages") for r in f), DEADLINE, "a frame")
        assert b"\x1b[3" not in s.buf and b"\x1b[1m" not in s.buf, "colour with NO_COLOR set"
        rows = [r for r in f if __import__("re").match(r"^[ >▌|] #\d", r)]
        assert len(rows) >= 3, f
        import re
        for r in rows:
            assert re.match(r"^[ >▌|] #\d+\s+\S+\s+(hand|ask |ans |done|dec |ALRT|note) ", r), ("no kind code", r)
        s.send(b"q")
        assert s.wait(DEADLINE) == 0
    finally:
        s.close()


@case
def readonly():
    """30 mixed keys, a copy, a detail, help and the filter: bus.db's bytes, every table and every cursor unchanged."""
    before = bus_state(DB)
    s = start()
    try:
        for k in (b"j", b"k", b"\t", b"\r", b"j", b"\r", b"\x1b", b"\x1b", b"y", b"t", b"/", b"x", b"\r", b"\x1b", b"p",
                  b"?", b"q", b"r", b"G", b"1", b"j", b"\r", b"y", b"q", b"2", b"\r", b"\x1b", b"3", b"\r", b"\x1b"):
            s.send(k)
            s.frame_after(s.mark(), lambda f: True, DEADLINE, "a frame after a key")
        assert s.p.poll() is None, "a key in the mix quit watch"
        s.send(b"4q")
        assert s.wait(DEADLINE) == 0
    finally:
        s.close()
    assert bus_state(DB) == before, "watch changed bus.db"
    assert not os.path.exists(DB + "-journal"), "watch left a journal"


@case
def copy():
    """y on #9's detail writes OSC 52 with the reply command and says so in the footer; the bus is unchanged."""
    before = bus_state(DB)
    s = start()
    try:
        key(s, b"kk", lambda f: sel_row(f) and "#9" in sel_row(f), "#9 selected")
        key(s, b"\r", lambda f: "message #9" in f[0], "Enter on #9")
        cmd = 'agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."'
        f = key(s, b"y", lambda f: "copied" in f[-1], "y copies")
        assert b"\x1b]52;c;" + base64.b64encode(cmd.encode()) + b"\x07" in s.buf, s.buf[-400:]
        assert "copied" in f[-1] and ("select it here" in f[-1] or "select it above" in f[-1]), f[-1]
        f = key(s, b"t", lambda f: "copied" not in f[-1], "the next key clears the copied footer")
        s.send(b"qq")
        assert s.wait(DEADLINE) == 0
    finally:
        s.close()
    assert bus_state(DB) == before, "y changed the bus"


@case
def ascii_auto():
    """TERM=linux and AGENTBUS_ASCII=1 draw ASCII glyphs with a reverse-video header; so does a terminal that answers
    the start-up probe with a two-column advance for ●."""
    def check(s, what):
        f = s.frame_after(0, lambda f: any(r.startswith("Messages") for r in f), DEADLINE, what)
        assert all(ord(ch) < 128 for r in f for ch in r), (what, [r for r in f if any(ord(ch) >= 128 for ch in r)])
        raw = s.frames(0, raw=True)[-1]
        assert raw[0].startswith("\x1b[1;7m"), (what, raw[0][:30])
        s.send(b"q")
        assert s.wait(DEADLINE) == 0
    for kw in ({"TERM": "linux"}, {"AGENTBUS_ASCII": "1"}):
        s = start(**kw)
        try:
            check(s, str(kw))
        finally:
            s.close()
    s = PtySession(agentbus_argv() + ["watch", "--interval", "0.2"], env(), cols=100, rows=30)
    try:
        end = time.monotonic() + 10
        while b"\x1b[6n" not in s.buf:
            assert time.monotonic() < end, "no cursor position probe"
            s.pump(0.02)
        s.send(b"\x1b[30;3R")  # ● advanced the cursor two columns
        s.until(lambda t: "following" in t, DEADLINE, "the first frame")
        check(s, "the probe")
    finally:
        s.close()


@case
def detail_reads():
    """detail-queries-on-open-and-r: with a detail open over several ticks, watch_detail runs once; r runs it again."""
    path = bin_path()
    log = os.path.join(os.path.dirname(DB), "..", "..", "detail-calls")
    wrapper = os.path.join(os.path.dirname(log), "count_detail.py")
    if os.path.exists(log):
        os.unlink(log)
    with open(wrapper, "w") as f:
        f.write("import runpy, sys\n"
                "g = runpy.run_path(sys.argv[1], run_name='agentbus_counted')\n"
                "real, log = g['watch_detail'], sys.argv[2]\n"
                "def counted(*a, **k):\n"
                "    open(log, 'a').write('call\\n')\n"
                "    try:\n"
                "        return real(*a, **k)\n"
                "    except BaseException as e:\n"
                "        open(log, 'a').write('failed ' + repr(getattr(e, 'code', e))[:300] + '\\n')\n"
                "        raise\n"
                "g['render_watch'].__globals__['watch_detail'] = counted\n"
                "sys.argv = ['agentbus'] + sys.argv[3:]\n"
                "g['render_watch'].__globals__['contract_main']()\n")
    s = start(argv=[os.environ.get("PYTHON") or "python3", wrapper, path, log])
    try:
        key(s, b"\r", lambda f: "message #10" in f[0] and any(r.startswith("Thread") for r in f)
            and not any("reading the bus" in r for r in f), "Enter opens #10 and its detail is read")
        for _ in range(6):  # six more frames (ticks at 0.2 s), the window ended by events
            s.frame_after(s.mark(), lambda f: True, DEADLINE, "a tick")
        n = open(log).read().count("call")
        assert n == 1, f"watch_detail ran {n} times for one open detail over several ticks: {open(log).read()[-600:]}"
        key(s, b"r", lambda f: "message #10" in f[0], "r")
        end = time.monotonic() + DEADLINE
        while open(log).read().count("call") < 2:  # the event: r's read has started
            assert time.monotonic() < end, "r did not read the detail again"
            s.pump(0.05)
        for _ in range(4):  # four more ticks: r read the detail once, not once per effect or per tick
            s.frame_after(s.mark(), lambda f: True, DEADLINE, "a tick after r")
        n = open(log).read().count("call")
        assert n == 2, f"r read the detail {n - 1} times (want once)"
        s.send(b"qq")
        assert s.wait(DEADLINE) == 0
    finally:
        s.close()



# Every kind of hostile byte a lane can store: OSC 52 (writes the clipboard), CSI (leaves the alternate screen,
# clears it, moves the cursor), the C1 CSI (U+009B), bidi overrides and isolates, a zero-width joiner, BEL.
HOSTILE = "\x1b]52;c;ZWNobyBwd25lZAo=\x07\x1b[?1049l\x1b[2J\x1b[5;5H\u009b31m‮⁦‍\x07"
ALLOWED = (rb"\x1b\[[0-9;?]*[mHKJhl]", rb"\x1b\[6n", rb"\x1b\]52;c;[A-Za-z0-9+/=]*\x07", rb"\r", rb"\n")


def raw_controls(buf):
    """What is left after removing every sequence watch itself writes: any control byte, C1, format (bidi,
    zero-width) or other unsafe character is a leak."""
    import re
    import unicodedata
    rest = re.sub(b"|".join(ALLOWED), b"", buf)
    bad = [b for b in rest if b < 0x20 or b == 0x7f]
    text = rest.decode("utf-8", "replace")
    bad += [hex(ord(c)) for c in text if 0x80 <= ord(c) <= 0x9f or unicodedata.category(c) in ("Cf", "Cc")]
    return bad


@case
def hostile():
    """H1: hostile bytes in every field a bus can hold (planted into bus.db, since the CLI refuses control characters
    in identifiers: agent names and roles, recipients, ctx keys and values,
    claim resources and purposes, topics, bodies, the goal), walked through every view (the overview, every
    detail kind, a nested detail, help to its last page, the filter input, a kept filter, the copied footer):
    no raw control, C1 or format character reaches the terminal."""
    db = os.path.join(os.path.dirname(ROOT), "hostile", ".agentbus", "bus.db")
    os.makedirs(os.path.dirname(db), exist_ok=True)
    H = "HOSTILEPLACEHOLDER"   # the CLI refuses control characters in identifiers (#20); planted into bus.db below
    e = env(AGENTBUS_DB=db)

    def cli(*args):
        r = subprocess.run(agentbus_argv() + list(args), env=e, capture_output=True, text=True, timeout=DEADLINE)
        assert r.returncode == 0, (args, r.stderr)
    evil, bob = "ev" + H, "bob"
    cli("--as", evil, "join", "--role", "lead" + H)
    cli("--as", bob, "join", "--role", "tester")
    cli("--as", evil, "goal", "goal" + H)
    cli("--as", evil, "claim", "src/" + H, "--purpose", "why" + H)
    cli("--as", bob, "claim", "docs/" + H)
    cli("--as", evil, "ctx", "set", "key" + H, "value" + H)
    cli("--as", evil, "post", "body" + H + "\nline two" + H, "--to", bob, "--kind", "question", "--topic", "t" + H)
    cli("--as", bob, "post", "names src/" + H + " and " + evil, "--to", evil, "--kind", "answer", "--reply-to", "1")
    cli("--as", bob, "post", "to a ghost", "--to", "ghost" + H)
    # Plant the hostile text the way an older release left it: the rows above were made by the CLI with a plain
    # placeholder, so their shape is exactly the CLI's; swap the placeholder for the hostile bytes in every text column.
    con = sqlite3.connect(db)
    for table in ("agents", "messages", "cursors", "context", "context_history", "claims", "log"):
        for col in [r[1] for r in con.execute(f"PRAGMA table_info({table})") if r[2].upper() == "TEXT"]:
            con.execute(f"UPDATE {table} SET {col} = REPLACE({col}, ?, ?) WHERE {col} LIKE ?", (H, HOSTILE, "%" + H + "%"))
    con.commit()
    assert con.execute("SELECT count(*) FROM agents WHERE name LIKE ?", ("%" + HOSTILE,)).fetchone()[0] == 1
    con.close()   # closed before watch starts: an open connection of ours must not be what it waits on
    H = HOSTILE
    evil = "ev" + H
    for emoji in (False, True):
        ee = dict(e)
        if emoji:
            ee.pop("AGENTBUS_NO_EMOJI")
        s = PtySession(agentbus_argv() + ["watch", "--interval", "0.2"], ee, cols=100, rows=30)
        try:
            s.until(lambda t: "following" in t, DEADLINE, "the first frame")
            over = lambda f: "open question" in f[0]
            head = lambda w: (lambda f: w in f[0] and not any("reading the bus" in r for r in f))  # its data is in
            sel = lambda f: sel_row(f) is not None
            copied = lambda f: "copied" in f[-1]
            walk = [(b"1", lambda f: any(r.startswith("Agents") and "j/k" in r for r in f) or "Agents" in f[3]),
                    (b"\r", head("agent ")), (b"j", sel), (b"\r", head("claim ")), (b"y", copied),  # nested, copy
                    (b"q", head("agent ")), (b"q", over),
                    (b"2", lambda f: True), (b"\r", head("claim ")), (b"j", sel), (b"\r", head("agent ")),
                    (b"q", head("claim ")), (b"j", lambda f: sel_row(f) and "#" in sel_row(f)),
                    (b"\r", head("message #")), (b"y", copied), (b"q", head("claim ")), (b"q", over),
                    (b"3", lambda f: True), (b"\r", head("fact ")), (b"j", sel), (b"\r", head("agent ")),
                    (b"q", head("fact ")), (b"y", copied), (b"q", over),
                    (b"4", lambda f: True), (b"k", sel), (b"k", lambda f: sel_row(f) and "#2" in sel_row(f)),
                    (b"\r", head("message #2")), (b"j", sel),
                    (b"\r", lambda f: "back to #" in f[-1]), (b"y", copied), (b"q", head("message #")), (b"q", over),
                    (b"?", head("keys")), (b"G", lambda f: any("lines above" in r for r in f)), (b"q", over),
                    (b"/", lambda f: f[-1].startswith("/")), (b"e", lambda f: f[-1].startswith("/e_")),
                    (b"v", lambda f: f[-1].startswith("/ev_")), (b"\r", lambda f: f[-1].startswith("  /ev")),
                    (b"y", copied), (b"\x1b", lambda f: not f[-1].startswith("  /ev") and "copied" not in f[-1])]
            for k, cond in walk:
                key(s, k, cond, f"the view after {k!r}")
            s.send(b"q")
            assert s.wait(DEADLINE) == 0
            for want in ("agent ", "claim ", "fact key", "message #2", "message #1", "keys"):
                assert any(want in f[0] for f in s.frames()), ("a view the walk did not reach", want)
            leaks = raw_controls(s.buf)
            assert not leaks, ("raw control characters reached the terminal", leaks[:20])
            import re
            for payload in re.findall(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x07", s.buf):  # only watch's own y copies
                assert payload != b"ZWNobyBwd25lZAo=", "the planted OSC 52 reached the terminal raw"
        finally:
            s.close()


@case
def jobctl():
    """M2: Ctrl-Z in an interactive bash gives the terminal back (cursor shown, alternate screen left) and the job
    stops; fg takes it again (cbreak, the alternate screen, a full frame) and keys work at once; q exits."""
    import fcntl
    import pty
    import select
    import shlex
    import struct
    import termios
    e = env(PS1="PROMPT$ ", AGENTBUS_DB=DB)
    pid, fd = pty.fork()
    if pid == 0:  # the child: an interactive shell with job control on this pty
        os.execve("/bin/bash", ["bash", "--norc", "--noprofile", "-i"], e)
    buf = [b""]

    def until(cond, seconds, what, since=0):
        end = time.monotonic() + seconds
        while not cond(buf[0][since:]):
            if time.monotonic() > end:
                raise AssertionError(f"timed out waiting for {what}: ...{buf[0][-500:]!r}")
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    buf[0] += os.read(fd, 65536)
                except OSError:
                    break

    def lflag():
        l = termios.tcgetattr(fd)[3]
        return bool(l & termios.ICANON), bool(l & termios.ECHO)
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        until(lambda b: b"PROMPT$" in b, DEADLINE, "the prompt")
        os.write(fd, (shlex.join(agentbus_argv() + ["watch", "--interval", "0.2"]) + "\n").encode())
        until(lambda b: b"following" in b, DEADLINE, "the first frame")
        assert lflag() == (False, False), ("watch is not in cbreak", lflag())
        m = len(buf[0])
        os.write(fd, b"\x1a")
        until(lambda b: b"PROMPT$" in b, DEADLINE, "the prompt after Ctrl-Z", m)
        after = buf[0][m:]
        assert b"\x1b[?25h\x1b[?1049l" in after and after.index(b"\x1b[?25h\x1b[?1049l") < after.index(b"PROMPT$"), \
            ("Ctrl-Z did not give the terminal back before the prompt", after.find(b"\x1b[?25h\x1b[?1049l"),
             after.find(b"PROMPT$"), after[-400:])
        m = len(buf[0])
        os.write(fd, b"fg\n")
        until(lambda b: b"\x1b[?1049h" in b and b"\x1b[?25l" in b and b"following" in b.split(b"\x1b[?1049h")[-1], DEADLINE,
              "the alternate screen and a full frame after fg", m)
        assert lflag() == (False, False), ("after fg the terminal is not in cbreak", lflag())
        m = len(buf[0])
        os.write(fd, b"\t")  # a key works at once, no Enter needed
        until(lambda b: b"j/k move" in b, DEADLINE, "Tab redrawn after fg", m)
        m = len(buf[0])
        os.write(fd, b"q")
        until(lambda b: b"PROMPT$" in b, DEADLINE, "q to exit to the prompt", m)
        assert b"\x1b[?25h\x1b[?1049l" in buf[0][m:], "q after fg did not restore the screen"
        os.write(fd, b"exit\n")
        end = time.monotonic() + 10
        while time.monotonic() < end:
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done:
                pid = 0
                break
            select.select([fd], [], [], 0.05) and None
            try:
                buf[0] += os.read(fd, 65536) if select.select([fd], [], [], 0)[0] else b""
            except OSError:
                pass
    finally:
        if pid:
            os.kill(pid, signal.SIGKILL)  # the shell this case started
            os.waitpid(pid, 0)
        os.close(fd)


@case
def bigbodies():
    """M3: 200 held messages of 1 MB each: keys redraw and the process stays small (a tick reads only the head of
    a body it has not seen; TEST 2d proves the reads with SQLite's trace)."""
    db = os.path.join(os.path.dirname(ROOT), "big", ".agentbus", "bus.db")
    os.makedirs(os.path.dirname(db), exist_ok=True)
    e = env(AGENTBUS_DB=db)
    for words in (["join"], ["post", "seed"]):
        r = subprocess.run(agentbus_argv() + ["--as", "seed", *words], env=e, capture_output=True, text=True, timeout=DEADLINE)
        assert r.returncode == 0, r.stderr
    c = sqlite3.connect(db)
    c.execute("INSERT INTO messages(ts, sender, recipient, kind, body) "
              "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200) "
              "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-3 days'), 'codex', '*', 'note', "
              "CASE i % 2 WHEN 0 THEN printf('%.*c', 1000000, 'x') "
              "ELSE replace(printf('%.*c', 1000000, 'x'), 'xxxxxxxxx', 'xxxxxxxx' || char(10)) END FROM n")
    c.commit()
    c.close()
    s = PtySession(agentbus_argv() + ["watch", "--interval", "0.2"], e, cols=100, rows=30)
    try:
        s.until(lambda t: "following" in t, DEADLINE, "the first frame")
        key(s, b"k", lambda f: sel_row(f) is not None, "k selects the newest")
        for i in range(20):  # every key redraws (its frame is the event); how fast is the reader's business
            key(s, b"k" if i % 2 == 0 else b"j", lambda f: sel_row(f) is not None, f"the redraw for key {i}")
        rss = resident_kb(s.p.pid)
        s.send(b"q")
        assert s.wait(DEADLINE) == 0
        assert rss < 150 * 1024, f"watch holds {rss // 1024} MB with 200 bodies of 1 MB"
        print(f"200 x 1 MB bodies: 20 keys redrawn, {rss // 1024} MB resident")
    finally:
        s.close()


@case
def watchdog():
    """L2: when the watchdog ends a hung read, the terminal is restored and the exit shows the watchdog's own
    reason (not an error from pipes closed under the loop)."""
    wrapper = os.path.join(os.path.dirname(ROOT), "hang_read.py")
    with open(wrapper, "w") as f:
        f.write("import runpy, sys, time\n"
                "g = runpy.run_path(sys.argv[1], run_name='agentbus_hang')\n"
                "G = g['render_watch'].__globals__\n"
                "real, n = G['watch_snapshot'], [0]\n"
                "def hangs(*a, **k):\n"
                "    n[0] += 1\n"
                "    if n[0] == 4:\n"
                "        with G['watched'](0.3, 'test: the read hung'):\n"
                "            time.sleep(20)\n"
                "    return real(*a, **k)\n"
                "G['watch_snapshot'] = hangs\n"
                "sys.argv = ['agentbus'] + sys.argv[2:]\n"
                "G['contract_main']()\n")
    s = start(argv=[os.environ.get("PYTHON") or "python3", wrapper, bin_path()])
    try:
        rc = s.wait(DEADLINE)
        out = s.buf.decode("utf-8", "replace")
        assert "test: the read hung" in out, ("the exit does not show the watchdog's reason", out[-400:])
        assert "Bad file descriptor" not in out and "Traceback" not in out, out[-600:]
        assert rc == 3, rc
        assert b"\x1b[?25h\x1b[?1049l" in s.buf, "the watchdog's exit did not restore the screen"
        now, before = s.termios_now(), s.before
        assert now[:3] + now[4:] == before[:3] + before[4:] and \
            (now[3] | getattr(__import__("termios"), "PENDIN", 0)) == (before[3] | getattr(__import__("termios"), "PENDIN", 0)), \
            ("terminal modes not restored after the watchdog's exit", now, before)
    finally:
        s.close()


@case
def encodings():
    """L6: a stdout that is not UTF-8 (ASCII, or a latin-1 locale) draws the ASCII glyphs and keeps running."""
    for extra, want_ascii in (({"PYTHONIOENCODING": "ascii"}, True), ({"LC_ALL": "en_US.ISO8859-1", "LANG": "en_US.ISO8859-1"}, False)):
        s = start(**extra)
        try:
            f = s.frame_after(0, lambda f: any(r.startswith("Messages") for r in f), DEADLINE, f"a frame under {extra}")
            if want_ascii:
                assert all(ord(c) < 128 for r in f for c in r), ("non-ASCII under an ASCII stdout", f)
            key(s, b"\t", lambda f: any(r.startswith("Agents") and "j/k" in r for r in f), f"Tab under {extra}")
            s.send(b"q")
            assert s.wait(DEADLINE) == 0, extra
            assert b"Traceback" not in s.buf and s.termios_now() == s.before, extra
        finally:
            s.close()


@case
def paste():
    """N1: what y copies, pasted into a real interactive shell inside bracketed paste (as a terminal sends a
    paste, control bytes and all), runs nothing: a sender, a value or a key carrying ESC [ 2 0 1 ~ (ends the
    paste), Ctrl-U (kills the line) and CR (runs what follows) is copied without a control byte."""
    import fcntl
    import pty
    import select
    import shutil
    import struct
    import termios
    g = W.g
    evils = ["a\x1b[201~\x15touch PWNED1\r", "\x1b[201~\rtouch PWNED2\r", "x\x03touch PWNED3\n", "y\x1b\x1b[201~;touch PWNED4\r"]
    copies = []
    for e in evils:
        copies.append(g["reply_command"]({"sender": e, "id": 1, "kind": "question"}, e))
        copies.append(g["copy_text"](e))
    snap = W.snap("sample")
    snap["context"] = [{"key": "k" + evils[0], "value": evils[1], "updated_by": evils[2], "updated_at": W.T_NOW}]
    v = g["View"]()
    for k in ("3", "y"):
        v = g["step"](v, k, snap, (100, 30), W.when(W.T_NOW))
    copies.append(v.copied)  # the overview copies the key
    v = g["step"](g["step"](v, "Enter", snap, (100, 30), W.when(W.T_NOW)), "y", snap, (100, 30), W.when(W.T_NOW),
                  W.detail_for(g["step"](v, "Enter", snap, (100, 30), W.when(W.T_NOW)), snap))
    copies.append(v.copied)  # the fact detail copies the value
    for c in copies:
        assert c and not any(ord(ch) < 0x20 or 0x7f <= ord(ch) < 0xa0 for ch in c), ("a control byte in a copy", c)
    shells = [sh for sh in (["/bin/zsh", "-f", "-i"], [shutil.which("bash") or "", "--norc", "--noprofile", "-i"])
              if sh[0] and os.path.exists(sh[0])]
    assert shells, "no interactive shell to paste into"
    work = os.path.join(os.path.dirname(ROOT), "paste")
    os.makedirs(work, exist_ok=True)
    for sh in shells:
        e = {"HOME": work, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "P> ", "PROMPT": "P> "}
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(work)
            os.execve(sh[0], sh, e)
        buf = [b""]

        def until(cond, seconds, what):
            end = time.monotonic() + seconds
            while not cond(buf[0]):
                if time.monotonic() > end:
                    raise AssertionError(f"{sh[0]}: timed out waiting for {what}: ...{buf[0][-300:]!r}")
                r, _, _ = select.select([fd], [], [], 0.05)
                if r:
                    try:
                        buf[0] += os.read(fd, 65536)
                    except OSError:
                        break
        try:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 200, 0, 0))
            until(lambda b: b"P> " in b, DEADLINE, "the prompt")
            for i, c in enumerate(copies):
                os.write(fd, b"\x1b[200~" + c.encode() + b"\x1b[201~")
                os.write(fd, b"\x15" + f"echo DONE$((40+{i}))\r".encode())  # clear the line, then a marker command
                until(lambda b, i=i: f"DONE{40 + i}".encode() in b, DEADLINE, f"the marker after paste {i}")
            ran = [f for f in os.listdir(work) if f.startswith("PWNED")]
            assert not ran, (sh[0], "a paste ran a command", ran)
            os.write(fd, b"exit\r")
            end = time.monotonic() + 10
            while pid and time.monotonic() < end:
                if os.waitpid(pid, os.WNOHANG)[0]:
                    pid = 0
                    break
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        os.read(fd, 65536)
                    except OSError:
                        pass
        finally:
            if pid:
                try:
                    os.kill(pid, signal.SIGKILL)  # the shell this case started
                    os.waitpid(pid, 0)
                except (ProcessLookupError, ChildProcessError):
                    pass
            os.close(fd)
    print(f"{len(copies)} copies pasted into {', '.join(s[0] for s in shells)}: nothing ran")


CASES["restore"] = restore

if __name__ == "__main__":
    CASES[sys.argv[1]]()
    print("ok", sys.argv[1])
