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
        s.until(lambda t: any(w in t for w in wait_for), 15, "the first frame")
    except BaseException:
        s.close()
        raise
    return s


def sel_row(f):
    return next((r for r in f if r.startswith(">")), None)


def key(s, data, cond, what, seconds=5):
    m = s.mark()
    s.send(data)
    return s.frame_after(m, cond, seconds, what)


def settled(s, cond, what):
    """The raw bytes of a fresh frame for which cond holds (a refresh is drawn every tick)."""
    m = s.mark()
    s.frame_after(m, cond, 5, what)
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


def post(*args):
    r = subprocess.run(agentbus_argv() + list(args), env=env(), capture_output=True, text=True, timeout=30)
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
        s.frame_after(m, lambda f: "message #10" not in f[0], 5, "Esc back to the overview")
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
        s.frame_after(m, lambda f: "message #7" in f[0], 5, "Esc back to #7")
        assert s.frames(m, raw=True)[-1] == at7, "Esc did not restore #7 as it was"
        m = s.mark()
        s.send(b"q")
        s.frame_after(m, lambda f: "message #" not in f[0], 5, "q back to the overview")
        assert s.frames(m, raw=True)[-1] == over7, "q in a detail did not return to the overview byte for byte"
        assert s.p.poll() is None, "q in a detail quit watch"
        key(s, b"?", lambda f: any(r.startswith("Look closer") for r in f), "? shows the help page")
        key(s, b"\x1b", lambda f: not any(r.startswith("Look closer") for r in f), "Esc closes help")
        s.send(b"q")
        assert s.wait(10) == 0
    finally:
        s.close()


@case
def pause():
    s = start()
    try:
        f = key(s, b"p", lambda f: any(r.startswith("Messages") and "paused at" in r for r in f), "p pauses")
        frozen = [r for r in f if not r.startswith("Messages")]
        post("--as", "codex", "post", "posted while paused", "--to", "claude")
        f = s.frame_after(s.mark(), lambda f: any("+1 new" in r for r in f), 10, "+1 new while paused")
        assert [r for r in f if not r.startswith("Messages")] == frozen, "the view changed while paused"
        # pause-freezes-display: more posts over several ticks change no row but the Messages title
        for i in range(3):
            post("--as", "codex", "post", f"more {i}")
        m = s.mark()
        s.frame_after(m, lambda f: any("+4 new" in r for r in f), 10, "+4 new")
        later = s.frame_after(s.mark(), lambda f: True, 5, "two ticks later")
        for f in s.frames(m) + [later]:
            assert [r for r in f if not r.startswith("Messages")] == frozen, ("a row changed while paused", f)
        f = key(s, b"p", lambda f: any("posted while paused" in r for r in f), "p follows and shows the message")
        assert not any("new" in r and "+" in r for r in f if r.startswith("Messages")), f
        s.send(b"q")
        assert s.wait(10) == 0
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
        f = s.frame_after(s.mark(), lambda f: any("+200 new" in r for r in f), 10, "+200 new")
        assert sel_row(f) and "#9" in sel_row(f), f
        m = s.mark()
        s.resize(60, 20)
        f = s.frame_after(m, lambda f: len(f[0]) <= 59 and any("+200" in r for r in f), 5, "the narrow redraw")
        assert sel_row(f) and "#9" in sel_row(f) and len(f) == 20, f
        s.send(b"q")
        assert s.wait(10) == 0
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
                rc = s.wait(10)
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
        f = s.frame_after(s.mark(), lambda f: "not readable" in f[0], 10, "the refused frame")
        text = "\n".join(f)
        assert "This bus could not be read" in text and "Run: agentbus upgrade" in text, text
        assert "Agents" not in text and "Messages" not in text, text
        restore()
        m = s.mark()
        s.send(b"r")
        s.frame_after(m, lambda f: "fact runtime" in f[0], 10, "r brings the bus back")
        after = settled(s, lambda f: "fact runtime" in f[0] and any("History" in r for r in f), "the fact detail again")
        assert after == before, ("the view did not come back as it was", s.frames(m)[-1])
        key(s, b"q", lambda f: "fact runtime" not in f[0] and f[-1].startswith("  /from:c"), "q back to the filtered overview")
        s.send(b"q")
        assert s.wait(10) == 0
    finally:
        s.close()


@case
def latency():
    """Key to redraw under 100 ms for 20 keys; then the same while another process holds the bus (the reads wait
    on the lock off the input loop), and q exits within 250 ms + 100 ms slack with the terminal restored."""
    def run(s, label):
        key(s, b"k", lambda f: sel_row(f) is not None, "k selects")
        worst = 0.0
        for i in range(20):
            want = "#9" if i % 2 == 0 else "#10"
            m = s.mark()
            t0 = time.monotonic()
            s.send(b"k" if i % 2 == 0 else b"j")
            s.frame_after(m, lambda f: (sel_row(f) or "> -").split()[1] == want, 5, f"{label}: the redraw for key {i}")
            worst = max(worst, time.monotonic() - t0)
        assert worst < 0.1, f"{label}: a key took {worst * 1000:.0f} ms to redraw"
        return worst
    s = start()
    try:
        w1 = run(s, "idle")
        s.send(b"G")
        hold = sqlite3.connect(DB, timeout=0)
        hold.execute("PRAGMA locking_mode=EXCLUSIVE")
        hold.execute("SELECT COUNT(*) FROM messages").fetchone()
        try:
            s.frame_after(s.mark(), lambda f: "waiting" in f[0] and "s old" in f[0], 10, "waiting · Ns old in the header")
            f = s.frame_after(s.mark(), lambda f: True, 5, "a frame")
            assert any(r.startswith("Messages  10") for r in f), ("the busy frame lost the last frame", f)
            w2 = run(s, "locked")
            t0 = time.monotonic()
            s.send(b"q")
            rc = s.wait(5)
            took = time.monotonic() - t0
        finally:
            hold.close()
        assert rc == 0 and took < 0.35, (rc, f"q took {took * 1000:.0f} ms with the bus locked")
        assert s.termios_now() == s.before, "terminal modes not restored after q on a locked bus"
        print(f"worst key to redraw: {w1 * 1000:.0f} ms idle, {w2 * 1000:.0f} ms locked; q on a locked bus {took * 1000:.0f} ms")
    finally:
        s.close()


@case
def dumb():
    s = PtySession(agentbus_argv() + ["watch"], env(TERM="dumb"), cols=100, rows=30)
    try:
        assert s.wait(15) == 0
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
        f = s.frame_after(0, lambda f: any(r.startswith("Messages") for r in f), 5, "a frame")
        assert b"\x1b[3" not in s.buf and b"\x1b[1m" not in s.buf, "colour with NO_COLOR set"
        rows = [r for r in f if __import__("re").match(r"^[ >▌|] #\d", r)]
        assert len(rows) >= 3, f
        import re
        for r in rows:
            assert re.match(r"^[ >▌|] #\d+\s+\S+\s+(hand|ask |ans |done|dec |ALRT|note) ", r), ("no kind code", r)
        s.send(b"q")
        assert s.wait(10) == 0
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
            s.frame_after(s.mark(), lambda f: True, 5, "a frame after a key")
        assert s.p.poll() is None, "a key in the mix quit watch"
        s.send(b"4q")
        assert s.wait(10) == 0
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
        assert s.wait(10) == 0
    finally:
        s.close()
    assert bus_state(DB) == before, "y changed the bus"


@case
def ascii_auto():
    """TERM=linux and AGENTBUS_ASCII=1 draw ASCII glyphs with a reverse-video header; so does a terminal that answers
    the start-up probe with a two-column advance for ●."""
    def check(s, what):
        f = s.frame_after(0, lambda f: any(r.startswith("Messages") for r in f), 5, what)
        assert all(ord(ch) < 128 for r in f for ch in r), (what, [r for r in f if any(ord(ch) >= 128 for ch in r)])
        raw = s.frames(0, raw=True)[-1]
        assert raw[0].startswith("\x1b[1;7m"), (what, raw[0][:30])
        s.send(b"q")
        assert s.wait(10) == 0
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
        s.until(lambda t: "following" in t, 10, "the first frame")
        check(s, "the probe")
    finally:
        s.close()


@case
def detail_reads():
    """detail-queries-on-open-and-r: with a detail open over several ticks, watch_detail runs once; r runs it again."""
    path = bin_path()
    log = os.path.join(os.path.dirname(DB), "..", "..", "detail-calls")
    wrapper = os.path.join(os.path.dirname(log), "count_detail.py")
    with open(wrapper, "w") as f:
        f.write("import runpy, sys\n"
                "g = runpy.run_path(sys.argv[1], run_name='agentbus_counted')\n"
                "real, log = g['watch_detail'], sys.argv[2]\n"
                "def counted(*a, **k):\n"
                "    open(log, 'a').write('call\\n')\n"
                "    return real(*a, **k)\n"
                "g['render_watch'].__globals__['watch_detail'] = counted\n"
                "sys.argv = ['agentbus'] + sys.argv[3:]\n"
                "g['render_watch'].__globals__['contract_main']()\n")
    s = start(argv=[os.environ.get("PYTHON") or "python3", wrapper, path, log])
    try:
        key(s, b"\r", lambda f: "message #10" in f[0] and any(r.startswith("Thread") for r in f), "Enter opens #10")
        for _ in range(6):  # six ticks at 0.2 s
            s.frame_after(s.mark(), lambda f: True, 5, "a tick")
        n = open(log).read().count("call")
        assert n == 1, f"watch_detail ran {n} times for one open detail over several ticks"
        key(s, b"r", lambda f: "message #10" in f[0], "r")
        t0 = time.monotonic()
        while open(log).read().count("call") < 2 and time.monotonic() - t0 < 5:
            s.pump(0.05)
        assert open(log).read().count("call") == 2, "r did not read the detail again"
        s.send(b"qq")
        assert s.wait(10) == 0
    finally:
        s.close()


CASES["restore"] = restore

if __name__ == "__main__":
    CASES[sys.argv[1]]()
    print("ok", sys.argv[1])
