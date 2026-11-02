#!/usr/bin/env bash
# agentbus watch: the live view. It reads the bus each tick and never holds it while drawing or writes it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/bus/bus.db"; mkdir -p "$T/bus"

cd "$T"
agentbus --as claude join --role lead >/dev/null
agentbus --as codex join --role implementer >/dev/null
agentbus --as claude post "add a live watch view" --to codex --kind handoff >/dev/null
agentbus --as codex claim bin/agentbus --purpose "watch command" >/dev/null
agentbus --as codex ctx set style "stdlib only" >/dev/null
agentbus --as $'evil\x1b]52;c;aGk=\x07#99' join >/dev/null

# Compare every cursor, including broadcast boundaries, across all watch modes below.
cursor_snapshot() { "$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("SELECT * FROM cursors ORDER BY agent").fetchall())' "$T/bus/bus.db"; }
cursors_before=$(cursor_snapshot)

echo "TEST 1: one frame when stdout is not a terminal: every section, no escape codes, no key hint"
o=$(outof env COLUMNS=100 NO_COLOR= "${AB[@]}" watch)
for want in "Agents  3" "claude" "implementer" "Claims  1" "bin/agentbus" "watch command" "Facts  1" "stdlib only" \
            "Messages  1" "claude → codex" "handoff" "add a live watch view" "0 alerts · 0 open questions" \
            "holds bin/agentbus"; do
  grep -qF -- "$want" <<<"$o" || fail "one frame lacks '$want': $o"
done
if grep -q $'\x1b' <<<"$o"; then fail "escape codes in a frame written to a pipe"; fi
if grep -q 'q quit' <<<"$o"; then fail "a key hint in a one-shot frame"; fi
grep -qF 'evil\x1b]52' <<<"$o" || fail "hostile name not shown escaped: $o"
# Every row starts with agentbus's own text: a section title, the header, or an indent.
printf '%s\n' "$o" > "$T/frame"
"$PY" - "$T/frame" <<'PY' || fail "a row starts with lane text"
import sys
for line in open(sys.argv[1]).read().split("\n"):
    assert line == "" or line.startswith((" agentbus", "  ", "Agents", "Claims", "Facts", "Messages")), repr(line)
PY
ok "a single frame shows agents, claims, facts and messages, escaped, without terminal codes"

echo "TEST 2: --once is the same frame even on a terminal; the empty bus explains how to join"
E="$T/empty/bus.db"; mkdir -p "$T/empty"
o=$(outof env COLUMNS=100 AGENTBUS_DB="$E" "${AB[@]}" watch --once)
grep -qF "no one yet. Join with: agentbus --as NAME join" <<<"$o" || fail "empty bus gives no hint: $o"
grep -qF "nothing claimed" <<<"$o" && grep -qF "quiet so far" <<<"$o" || fail "empty sections not named: $o"
ok "an empty bus says how to start"

echo "TEST 3: --interval is bounded"
expect_fail "must be between 0.2 and 60 seconds" agentbus watch --interval 0.01
expect_fail "not a number" agentbus watch --interval soon
ok "--interval outside 0.2 to 60 s is refused"

echo "TEST 4: live under a terminal: updates, arrows don't quit, resize redraws, q and Ctrl-C restore the terminal"
"$PY" - "$AGENTBUS_DB" <<'PY' || fail "live watch"
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, time, tty
import os as _os, sys as _sys
plain = lambda b: re.sub(rb"\x1b\[[0-9;]*m", b"", b)  # the text without colour: footer keys are bold
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
db = sys.argv[1]
env = dict(os.environ, AGENTBUS_DB=db)
env.pop("COLUMNS", None)
env.pop("LINES", None)

def launch(interval, inherited=None):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    # macOS sets PENDIN on a cbreak-to-canonical change with input pending. Prime that driver state
    # before the baseline, then compare every attribute exactly, nothing masked.
    initial = termios.tcgetattr(slave)
    tty.setcbreak(slave)
    termios.tcsetattr(slave, termios.TCSANOW, initial)
    before = termios.tcgetattr(slave)
    def pre():
        os.setsid()
        if inherited:
            inherited()
    p = subprocess.Popen([*agentbus_argv(), "watch", "--interval", interval], stdin=slave, stdout=slave, stderr=slave,
                         env=env, preexec_fn=pre)
    return p, master, slave, before

def until(master, buf, cond, seconds, what):
    end = time.time() + seconds
    while time.time() < end:
        if cond(buf[0]):
            return
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            try:
                buf[0] += os.read(master, 65536)
            except OSError:
                break
    assert cond(buf[0]), f"timed out waiting for {what}: ...{buf[0][-600:]!r}"

# 1. q: live updates, the new-message mark, arrow keys ignored, terminal restored.
p, master, slave, before = launch("0.3")
buf = [b""]
until(master, buf, lambda b: b"Agents" in b, 10, "the first frame")
t0 = time.time()
r = subprocess.run([*agentbus_argv(), "--as", "codex", "post", "watch is in", "--to", "claude", "--kind", "done"],
                   env=env, capture_output=True, text=True, timeout=30)
took = time.time() - t0
assert r.returncode == 0, r.stderr
assert took < 5, f"a post beside watch took {took:.1f}s"
until(master, buf, lambda b: b"watch is in" in b, 10, "the posted message")
os.write(master, b"\x1b[A")  # Up: must not quit
mark = len(buf[0])
until(master, buf, lambda b: plain(b[mark:]).count(b"q quit") >= 2, 5, "two more frames after Up")  # keeps reading
assert p.poll() is None, "an arrow key quit watch"
os.write(master, b"q")
until(master, buf, lambda b: p.poll() is not None, 10, "watch to quit on q")
rc = p.wait(timeout=1)
until(master, buf, lambda b: b"\x1b[?1049l" in b, 2, "leaving the alternate screen")
out = buf[0].decode("utf-8", "replace")
assert rc == 0, rc
after = termios.tcgetattr(slave); assert after == before, ("terminal modes not restored after q", [(i, before[i], after[i]) for i in range(6) if before[i] != after[i]])
assert "Traceback" not in out, out[-2000:]
assert "\x1b[?1049h" in out and "\x1b[?25l" in out and "\x1b[?25h" in out
assert "▌" in out, "a new message was not marked"
assert "q quit" in plain(buf[0]).decode("utf-8", "replace")
assert "\x1b]52" not in out, "a lane's OSC 52 sequence reached the terminal"
os.close(master); os.close(slave)

# 2. A resize redraws at once even with a 30 s refresh; Ctrl-C (SIGINT) ends it cleanly.
p, master, slave, before = launch("30")
buf = [b""]
WIDE, NARROW = b"\x1b[2m \xe2\x86\x92 \x1b[0m", b"\x1b[2m\xe2\x86\x92\x1b[0m"  # the arrow, dimmed
until(master, buf, lambda b: b"Agents" in b and WIDE in b, 10, "the first, wide frame")
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 60, 0, 0))
os.killpg(p.pid, signal.SIGWINCH)
mark = len(buf[0])
until(master, buf, lambda b: NARROW in b[mark:], 3, "the narrow redraw after a resize")
os.killpg(p.pid, signal.SIGINT)
until(master, buf, lambda b: p.poll() is not None, 10, "watch to end on Ctrl-C")
rc = p.wait(timeout=1)
until(master, buf, lambda b: b"\x1b[?1049l" in b, 2, "leaving the alternate screen")
assert rc == 0, rc
assert termios.tcgetattr(slave) == before, "terminal modes not restored after Ctrl-C"
assert b"Traceback" not in buf[0]
os.close(master); os.close(slave)

# 3. The same, started the way a CI runner or a parent shell may start it: SIGINT and SIGWINCH
# blocked and SIGINT ignored, all inherited across exec. Bug it catches: watch installed its
# handlers but left the inherited mask, so a blocked Ctrl-C stayed pending and watch slept out its
# 30 s interval, again and again (macos-latest, system Python 3.9: "timed out waiting for watch to
# end on Ctrl-C").
def hostile_start():
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGWINCH})
    signal.signal(signal.SIGINT, signal.SIG_IGN)
p, master, slave, before = launch("30", hostile_start)
buf = [b""]
until(master, buf, lambda b: b"Agents" in b and WIDE in b, 10, "the first, wide frame (blocked signals)")
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 60, 0, 0))
os.killpg(p.pid, signal.SIGWINCH)
mark = len(buf[0])
until(master, buf, lambda b: NARROW in b[mark:], 3, "the narrow redraw after a resize (SIGWINCH blocked by the parent)")
os.killpg(p.pid, signal.SIGINT)
until(master, buf, lambda b: p.poll() is not None, 10, "watch to end on Ctrl-C (SIGINT blocked and ignored by the parent)")
rc = p.wait(timeout=1)
until(master, buf, lambda b: b"\x1b[?1049l" in b, 2, "leaving the alternate screen (blocked signals)")
assert rc == 0, rc
assert termios.tcgetattr(slave) == before, "terminal modes not restored after Ctrl-C (blocked signals)"
assert b"Traceback" not in buf[0]
os.close(master); os.close(slave)
print(f"post beside watch: {took:.2f}s")
PY
ok "live view updates and marks new messages; arrows ignored; resize redraws at once; q and Ctrl-C restore the terminal, even when started with SIGINT blocked"

echo "TEST 5: watch writes nothing to the bus"
before=$("$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("select group_concat(name||last_seen) from agents").fetchone()[0], c.execute("select count(*) from log").fetchone()[0])' "$AGENTBUS_DB")
agentbus --as claude watch --once >/dev/null
after=$("$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("select group_concat(name||last_seen) from agents").fetchone()[0], c.execute("select count(*) from log").fetchone()[0])' "$AGENTBUS_DB")
[ "$before" = "$after" ] || fail "watch changed the bus: $before -> $after"
[ "$(cursor_snapshot)" = "$cursors_before" ] || fail "watch moved an inbox cursor"
# What waits in each inbox is counted from the cursors, read-only: codex has the handoff, claude the done from TEST 4.
o=$(outof env COLUMNS=100 "${AB[@]}" watch --once)
grep -qF "1 unread · holds bin/agentbus" <<<"$o" || fail "the frame does not count codex's unread handoff: $o"
AGENTBUS_DB="$T/bus/bus.db" json_ok agentbus watch --json | "$PY" -c 'import json,sys; u=json.load(sys.stdin)["unread"]; assert u["codex"] == 1 and u["claude"] == 1 and len(u) == 3, u' \
  || fail "watch --json unread is not codex 1, claude 1"
[ "$(cursor_snapshot)" = "$cursors_before" ] || fail "counting unread moved an inbox cursor"
# The original handoff remains unread after one-shot and live watch; then inbox consumes it.
o=$(json_ok agentbus --as codex inbox --peek --json)
printf '%s' "$o" | "$PY" -c 'import json,sys; assert [m["body"] for m in json.load(sys.stdin)["items"]] == ["add a live watch view"]'
o=$(json_ok agentbus --as codex inbox --json)
printf '%s' "$o" | "$PY" -c 'import json,sys; assert [m["body"] for m in json.load(sys.stdin)["items"]] == ["add a live watch view"]'
[ "$(njson agentbus --as codex inbox --peek --json)" = 0 ] || fail "inbox did not consume the handoff"
ok "watch is read-only, even under a name"

echo "TEST 6: --up selects the workspace bus and its header names the workspace directory"
unset AGENTBUS_DB
WS="$T/workspace"; mkdir "$WS"; agentbus init "$WS" >/dev/null
R="$WS/repo"; mkrepo "$R"; agentbus init "$R" >/dev/null
(cd "$WS" && agentbus --as outer post "workspace message" >/dev/null)
(cd "$R" && agentbus --as inner post "repo message" >/dev/null)
# Keep the full path visible even under a harness with a long temporary directory.
o=$(cd "$R" && outof env COLUMNS=1000 "${AB[@]}" watch --once --up 1)
grep -qF "$(cd "$WS" && pwd -P)" <<<"$o" || fail "header does not name the workspace: $o"
grep -qF "workspace message" <<<"$o" || fail "outer message missing: $o"
if grep -qF "repo message" <<<"$o"; then fail "inner messages leaked into outer watch"; fi
o=$(cd "$R" && outof env COLUMNS=1000 "${AB[@]}" --up 1 watch --once)
grep -qF "workspace message" <<<"$o" || fail "--up before watch failed: $o"
o=$(cd "$R" && outof env COLUMNS=1000 "${AB[@]}" watch --once)
grep -qF "$(cd "$R" && pwd -P)" <<<"$o" || fail "header does not name repo: $o"
grep -qF "repo message" <<<"$o" || fail "nearest bus message missing: $o"
ok "watch uses the selected bus and names its directory"

echo "TEST 7: watch --json is one JSON snapshot for agents"
j=$(AGENTBUS_DB="$T/bus/bus.db" json_ok agentbus watch --json)
printf '%s' "$j" > "$T/w.json"
python3 - "$T/w.json" <<'PY' || fail "watch --json shape"
import json, sys
j = json.load(open(sys.argv[1]))
assert set(j) >= {"bus", "directory", "agents", "claims", "context", "messages", "counts"}, sorted(j)
assert j["counts"]["agents"] == len(j["agents"]) and j["counts"]["messages"] >= 1
assert any(m["body"] == "add a live watch view" for m in j["messages"])
assert all("topic" in m for m in j["messages"]) and isinstance(j["unread"], dict), "topic and unread (additive) missing"
assert set(j["omitted"]) == {"agents", "context", "claims", "messages"}, j.get("omitted")
PY
# A bus folder nothing has written yet is the empty bus, with the same keys (omitted and unread too), and stays unwritten.
mkdir -p "$T/fresh"
j=$(AGENTBUS_DB="$T/fresh/bus.db" json_ok agentbus watch --json)
"$PY" -c 'import json,sys; j=json.loads(sys.argv[1]); assert j["omitted"] == {"agents": 0, "context": 0, "claims": 0, "messages": 0} and j["unread"] == {} and j["messages"] == [], j' "$j" \
  || fail "watch --json on an unwritten bus folder lacks omitted or unread: $j"
[ ! -e "$T/fresh/bus.db" ] || fail "watch --json created bus.db"
ok "watch --json returns agents, claims, context, messages and counts"

echo "TEST 8: a crowded bus fits every terminal: messages keep their share, cut sections say what they left out"
CB="$T/crowd/bus.db"; mkdir -p "$T/crowd"
for n in claude codex tests reviewer-subagent-security gemini nate ops docs perf ui; do
  AGENTBUS_DB="$CB" agentbus --as $n join --role "role of $n" >/dev/null
done
for i in $(seq 1 10); do AGENTBUS_DB="$CB" agentbus --as codex claim "src/mod$i/" --purpose "item $i" >/dev/null; done
for k in a b c d e f; do AGENTBUS_DB="$CB" agentbus --as claude ctx set "key_$k" "value $k" >/dev/null; done
"$PY" - "$CB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for i in range(60):
    body = f"msg {i} café résumé \u2014 naïve façade" if i % 7 == 0 else (f"line one {i}\nline two" if i % 11 == 0 else f"message number {i}")
    c.execute("INSERT INTO messages(ts,sender,recipient,kind,topic,body,reply_to) VALUES(strftime('%Y-%m-%dT%H:%M:%SZ','now'),?,?,?,NULL,?,?)",
              (["claude", "codex", "reviewer-subagent-security"][i % 3], "*" if i % 2 else "codex", ["note", "handoff", "done"][i % 3], body, i or None))
c.commit()
PY
"$PY" - "$BIN" "$CB" <<'PY' || fail "crowded layout"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from term_oracle import rows
import re
import sqlite3
import importlib.machinery, importlib.util
bin_, db = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("agentbus_mod", bin_)
spec = importlib.util.spec_from_loader("agentbus_mod", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
from datetime import datetime, timezone
snap = m.watch_snapshot(db, False, 200)
for (cols, height), emoji in [(size, e) for size in ((40, 24), (60, 20), (80, 24), (120, 40)) for e in (False, True)]:
    frame = m.render_watch(snap, "~/work", cols, height, set(), datetime.now(timezone.utc), m.Paint(False, emoji))
    assert len(frame) == height, (cols, emoji, len(frame))
    for line in frame:
        assert len(rows(line, cols)) == 1, f"{cols} cols, emoji {emoji}: a row wraps: {line!r}"
    text = "\n".join(frame)
    assert "Messages  60" in text and "#60" in text, f"{cols}x{height}: newest message missing:\n{text}"
    shown = sum(1 for l in frame if re.match(r"^[^\w#]{0,3}\s*#\d", l))  # after a kind bar or emoji
    assert shown >= 3, f"{cols}x{height}: only {shown} messages shown:\n{text}"
    # Every row is held (10 agents, 10 claims, 60 messages, under the 200 watch holds): a cut section counts what
    # it hides, and points at a command only for rows beyond the 200 (docs/design/watch-v2.md, Layout rules).
    for hint in (r"^  … [1-9]\d* more$", r"^  … [1-9]\d* earlier$"):
        assert any(re.match(hint, l.rstrip()) for l in frame), f"{cols}x{height}: no row matching {hint!r}:\n{text}"
    assert not re.search(r"… 0 (more|earlier|later)", text), f"{cols}x{height}: a marker counts 0:\n{text}"
    assert "agentbus who" not in text and "agentbus read" not in text, f"{cols}x{height}: a held row sent to a command:\n{text}"
    assert "q quit" in frame[-1]
# Past the 200 messages watch holds, the earlier marker names the command that reads the rest.
c = sqlite3.connect(db)
c.executemany("INSERT INTO messages(ts,sender,recipient,kind,body) VALUES(strftime('%Y-%m-%dT%H:%M:%SZ','now'),'codex','*','note',?)",
              [(f"more {i}",) for i in range(200)])
c.commit(); c.close()
big = m.watch_snapshot(db, False, 200)
for cols, height in ((40, 24), (100, 30)):
    text = "\n".join(m.render_watch(big, "~/work", cols, height, set(), datetime.now(timezone.utc), m.Paint(False)))
    assert re.search(r"… [1-9]\d* earlier · agentbus read", text), f"{cols}x{height}: no earlier · agentbus read:\n{text}"
narrow = m.render_watch(snap, "~/work", 30, 10, set(), datetime.now(timezone.utc), m.Paint(False))
assert narrow[0] == "watch needs 40+ columns" + " " * 7 and narrow[1:] == [""] * 9, narrow
colours = m.colour_map(snap["agents"])
first = [colours(a["name"]) for a in snap["agents"][:8]]
assert len(set(first)) == 8 and 31 not in first, first
PY
ok "40, 60, 80 and 120 columns, with and without emoji: every row fits, the newest messages show, cut sections point at their command"

echo "TEST 9 (pin): watch --once and watch --json on a refused bus exit 3 with the error, never empty sections"
RB="$T/refused/bus.db"; mkdir -p "$T/refused"
AGENTBUS_DB="$RB" agentbus --as a post "kept" >/dev/null
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("ALTER TABLE messages ADD COLUMN extra TEXT"); c.commit(); c.close()' "$RB"
rc=0; o=$(AGENTBUS_DB="$RB" "${AB[@]}" watch --once 2>"$T/err") || rc=$?
[ "$rc" = 3 ] || fail "watch --once on a refused bus exited $rc"
grep -qF "extra column extra" "$T/err" || fail "watch --once did not say why: $(cat "$T/err")"
if grep -qF "no one yet" <<<"$o" || grep -qF "quiet so far" <<<"$o"; then fail "watch --once drew empty sections: $o"; fi
rc=0; o=$(AGENTBUS_DB="$RB" "${AB[@]}" watch --json 2>"$T/err") || rc=$?
[ "$rc" = 3 ] && [ -z "$o" ] || fail "watch --json on a refused bus: rc $rc, stdout $o"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="schema_refused", e' "$T/err" || fail "watch --json error: $(cat "$T/err")"
ok "watch --once and --json on a refused bus exit 3 with the error"

echo "TEST 10: the live view of a bus it cannot read says so and names the fix, instead of drawing empty sections"
NB="$HOME/newerbus/bus.db"; mkdir -p "$HOME/newerbus"
AGENTBUS_DB="$NB" agentbus --as a post "kept" >/dev/null
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=5"); c.close()' "$NB"
"$PY" - "$RB" "$NB" <<'PY' || fail "live watch on an unreadable bus"
import fcntl, os, pty, re, select, struct, subprocess, sys, termios, time
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
plain = lambda b: re.sub(rb"\x1b\[[0-9;]*m", b"", b)  # the text without colour

def frame_of(db, want):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    env = dict(os.environ, AGENTBUS_DB=db)
    env.pop("COLUMNS", None)
    p = subprocess.Popen([*agentbus_argv(), "watch", "--interval", "0.5"], stdin=slave, stdout=slave, stderr=slave,
                         env=env, preexec_fn=os.setsid)
    buf, end = b"", time.time() + 15
    while time.time() < end and want.encode() not in plain(buf):
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            buf += os.read(master, 65536)
    os.write(master, b"q")
    end = time.time() + 10
    while p.poll() is None and time.time() < end:  # keep draining, or a full pty blocks its write
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            buf += os.read(master, 65536)
    assert p.wait(timeout=1) == 0
    os.close(master); os.close(slave)
    return plain(buf).decode("utf-8", "replace")

out = frame_of(sys.argv[1], "Retrying every 0.5s.")
for want in ("not readable", "This bus could not be read, so the sections are not drawn.",
             "bus schema is not agentbus's: table messages differs (extra column extra)", "Retrying every 0.5s.", "q quit"):
    assert want in out, f"refused bus frame lacks {want!r}: {out[-1500:]!r}"
for bad in ("no one yet", "quiet so far", "Agents", "Messages"):
    assert bad not in out, f"refused bus frame drew {bad!r}"
out = frame_of(sys.argv[2], "from a newer install")
for want in ("This bus is newer than this watch, so the sections are not drawn.",
             "this bus is newer than this copy of agentbus (schema 5, this copy knows 1).",
             "Run: agentbus upgrade ~/newerbus from a newer install", "r retry now", "q quit"):
    assert want in out.replace("\r\n", "\n"), f"newer bus frame lacks {want!r}: {out[-1500:]!r}"
assert "no one yet" not in out
PY
ok "a refused bus shows \"could not be read\" and the fix line, not \"no one yet\""

echo "TEST 11: a watch left running after its bus copy was upgraded says restart for X.Y.Z in the Messages title"
SD="$T/stalebus"; mkdir -p "$SD"; agentbus init "$SD" >/dev/null
AGENTBUS_DB="$SD/.agentbus/bus.db" agentbus --as a post "kept" >/dev/null
"$PY" - "$SD/.agentbus" <<'PY' || fail "restart for"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from term_oracle import PtySession
from agentbus_cmd import agentbus_argv
folder = sys.argv[1]
env = dict(os.environ, AGENTBUS_DB=os.path.join(folder, "bus.db"), TERM="xterm-256color", AGENTBUS_NO_EMOJI="1")
env.pop("COLUMNS", None)
s = PtySession(agentbus_argv() + ["watch", "--interval", "0.2"], env, cols=100, rows=30)
try:
    s.until(lambda t: "following" in t, 15, "the first frame")
    assert "restart for" not in s.text, "restart for before any upgrade"
    v = os.path.join(folder, "VERSION")
    with open(v + ".new", "w") as f:  # what upgrade leaves: a newer copy's VERSION, replaced in place
        f.write("9.9.9\n")
    os.replace(v + ".new", v)
    s.frame_after(s.mark(), lambda f: any(r.startswith("Messages") and "restart for 9.9.9 · following" in r for r in f), 10,
                  "restart for 9.9.9 in the Messages title")
    s.send(b"q")
    assert s.wait(10) == 0
finally:
    s.close()
PY
ok "after the bus copy on disk turns 9.9.9 the running watch says restart for 9.9.9 · following"

echo "TEST 12: watch --help names the keys, that it is read-only, and what --once and --json give"
o=$(outof "${AB[@]}" watch --help)
for want in "Keys: j/k move, Tab section, Enter open, / filter, p pause, y copy, ? help, q quit. Read-only." \
            "Esc and q go back; q quits from the main view, Esc never quits." \
            "--once prints one frame (so do a pipe and TERM=dumb); --json prints one snapshot."; do
  grep -qF -- "$want" <<<"$o" || fail "watch --help lacks '$want': $o"
done
ok "watch --help states the keys, read-only, Esc and q, --once and --json"
