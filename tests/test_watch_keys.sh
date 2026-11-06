#!/usr/bin/env bash
# watch v2 (issue #8): the key decoder, the state machine and the renderer as pure functions on the golden fixture,
# the design's behaviour cases (tests/golden/watch/behaviour.json), and live sessions on a pty. Every wait in a pty
# session is bounded and waits on frame content, never a fixed sleep; a session kills only its own process group.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
[ -z "${AGENTBUS_CMD:-}" ] || skip_test "the pure watch core is loaded from a script; AGENTBUS_CMD names an installed command"
cd "$T"

echo "TEST 1: the key decoder turns terminal bytes into keys, holds split sequences and drops unknown ones whole"
"$PY" - <<'PY' || fail "key decoder"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g = W.g
dk, KD = g["decode_keys"], g["KeyDecoder"]
table = [
    (b"\x1b[A", ["Up"], "ESC [ A decodes to Up and never to quit"),
    (b"\x1b[B\x1b[C\x1b[D", ["Down", "Right", "Left"], "arrows"),
    (b"\x1bOA\x1bOB", ["Up", "Down"], "SS3 arrows"),
    (b"\x1b[Z", ["S-Tab"], "ESC [ Z decodes to S-Tab"),
    (b"\x1b[H\x1b[F\x1b[1~\x1b[4~", ["Home", "End", "Home", "End"], "Home and End"),
    (b"\x1b[5~\x1b[6~", ["PgUp", "PgDn"], "PgUp and PgDn"),
    (b"\x15\x04\x03", ["C-u", "C-d", "C-c"], "Ctrl-u, Ctrl-d, Ctrl-c"),
    (b"\t\r\n\x7f", ["Tab", "Enter", "Enter", "Backspace"], "Tab, Enter, Backspace"),
    (b"\x1b", ["Esc"], "a lone ESC followed by nothing decodes to Esc"),
    (b"\x1b[99~q", ["q"], "an unknown sequence ESC [ 99 ~ is dropped whole"),
    (b"\x1b[1;5A", ["Up"], "a modified arrow is still the arrow"),
    (b"\x1bq", [], "Alt+q is not q (dropped whole)"),
    (b"\x1b\x1b[A", ["Esc", "Up"], "ESC ESC [ A: one Esc, then Up"),
    ("kind:é".encode(), list("kind:é"), "printable text, UTF-8 too"),
    (b"\x01\x02\x1f", [], "other control characters are dropped"),
    (b"\x1b[30;3Rq", ["CPR 30;3", "q"], "a cursor position report (the probe's answer, however late) is one key"),
]
for data, want, name in table:
    got = dk(data)
    assert got == want, (name, data, got, want)
d = KD()
assert d.feed(b"\x1b") == [] and d.pending(), "a lone ESC is held"
assert d.feed(b"[") == [] and d.pending(), "ESC [ is held"
assert d.feed(b"A") == ["Up"] and not d.pending(), "a split sequence ESC then [ A in two reads decodes to Up"
d = KD()
assert d.feed(b"\x1b") == [] and d.flush() == ["Esc"], "a lone ESC with nothing after it (the 50 ms wait) is Esc"
d = KD()
assert d.feed("é".encode()[:1]) == [] and d.feed("é".encode()[1:]) == ["é"], "a split UTF-8 character is held"
d = KD()
assert d.feed(b"\x1b[" + b"1" * 40) == [] and not d.pending(), "an overlong sequence is dropped whole"
import random
rnd = random.Random(7)
paste = bytes(rnd.choice(b"abcdefghij \n\t\x1b[0123456789;~ABZO\x7f\x03q") for _ in range(4096))
keys = dk(paste)
known = {"Up", "Down", "Left", "Right", "Home", "End", "PgUp", "PgDn", "Tab", "S-Tab", "Enter", "Esc", "Backspace",
         "C-c", "C-u", "C-d"}
assert all(k in known or (len(k) == 1 and k.isprintable()) for k in keys), set(keys) - known
print(len(table), "decoder cases;", len(keys), "keys from a 4 KB paste")
PY
ok "ESC [ A is Up, never quit; ESC [ Z is S-Tab; a lone ESC is Esc after the wait; split sequences join; ESC [ 99 ~ is dropped whole; a 4 KB paste decodes only known keys"

echo "TEST 2: the state machine, one key at a time (pure)"
"$PY" - <<'PY' || fail "state machine"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g = W.g
step, settle, View = g["step"], g["settle"], g["View"]
S, BIG = W.snap("sample"), W.snap("big")
T0 = W.when(W.T_NOW)
size = (100, 30)

def keys(v, ks, snap=S, detail=None, error=None):
    for k in ks:
        v = step(v, k, snap, size, T0, detail, error)
    return v

def frame(v, snap=S, held=None, cols=100, rows=30):
    return [r.rstrip() for r in g["render"](v, snap, W.WHERE, (cols, rows), T0, g["Paint"](False), held=held,
                                             detail=W.detail_for(v, snap, held))]

# Tab, Tab, j, Enter: the second claim's detail (Tab from Messages goes to Agents, then Claims).
v = keys(View(), ["Tab", "Tab"])
assert v.focus == "claims" and v.sel.get("claims") == "docs/api.md", (v.focus, v.sel)
v = keys(v, ["j", "Enter"])
assert v.mode == "detail" and v.detail["section"] == "claims" and v.detail["key"] == "src/auth/", v.detail
assert ("detail",) in v.effects, v.effects

# k in Messages while following pauses on the newest message and holds its id when new ones arrive.
v = keys(View(), ["k"])
assert v.paused and v.sel["messages"] == 9 and v.frozen["snap"] is S, (v.paused, v.sel)
v = settle(v, BIG)
assert v.sel["messages"] == 9, v.sel
t = frame(v, BIG)
assert any(l.startswith(">") and "#9" in l for l in t) and any("+200 new" in l for l in t), t
# G resumes following and clears +N new.
v = keys(v, ["G"], snap=BIG)
assert not v.paused and "messages" not in v.sel, (v.paused, v.sel)
t = frame(v, BIG)
assert not any("new" in l and "+" in l for l in t) and any("following" in l for l in t) and 209 in W.ids_in(t), t

# A refresh that inserts rows above the selection does not move the selected key.
v = keys(View(), ["2", "j"])
assert v.sel["claims"] == "src/auth/", v.sel
more = W.snap("sample")
more["claims"] = [{"resource": "aaa/", "agent": "tests", "purpose": None, "expires_at": "2026-11-01T16:50:00Z"}] + more["claims"]
v = settle(v, more)
assert v.sel["claims"] == "src/auth/", v.sel
# A selected row that goes moves the selection to the row now in its place.
gone = W.snap("sample")
gone["claims"] = gone["claims"][:1]
assert settle(v, gone).sel["claims"] == "docs/api.md"

# The filter grammar on the state machine's own keys.
v = keys(View(), ["/"] + list("from:tests kind:question") + ["Enter"])
assert v.mode == "overview" and v.filter == "from:tests kind:question" and not v.filter_input, vars(v)
assert W.ids_in(frame(v)) == [6, 9], W.ids_in(frame(v))
v = keys(View(), ["/"] + list("kind:fyi"))
t = frame(v)
assert g["KIND_ERROR"] in " ".join(l.strip() for l in t[-4:-1]) and W.ids_in(t) == [], t  # wrapped above the input
assert g["KIND_ERROR"] == ("kind must be one of: note, question (ask), answer (ans), handoff (hand), decision (dec), "
                           "alert (ALRT), done, todo, dropped (drop)")

# In filter input every printable key is text; only Ctrl-C quits; Esc clears and closes; Enter keeps.
text = "qjkgprt?1234 Gy/"
v = keys(View(), ["/"] + list(text))
assert v.mode == "filter" and v.filter == text and not v.effects, (v.mode, v.filter)
for k in ("Up", "Down", "Tab", "PgDn", "Home"):
    w = step(v, k, S, size, T0)
    assert w.filter == text and w.mode == "filter" and not w.effects, k
assert ("quit", 0) in step(v, "C-c", S, size, T0).effects
w = step(v, "Esc", S, size, T0)
assert w.mode == "overview" and w.filter == "" and not w.filter_input
w = step(v, "Enter", S, size, T0)
assert w.mode == "overview" and w.filter == text
assert step(step(v, "Backspace", S, size, T0), "Enter", S, size, T0).filter == text[:-1]

# Esc in the overview with no filter does nothing; with a kept filter it clears it; q quits.
v0 = View()
v = step(v0, "Esc", S, size, T0)
assert vars(v) == vars(v0), "Esc changed the overview"
assert ("quit", 0) in step(v0, "q", S, size, T0).effects
v = keys(View(), ["/", "a", "Enter", "Esc"])
assert v.filter == "" and not v.effects

# Details stack; Esc and q go back one level, as they were; q quits only from the overview.
base = frame(View())
v = keys(View(), ["k", "k", "k", "Enter"])  # the first k selects #9 and pauses
assert v.detail["key"] == 7 and v.detail["sel"] is None, v.detail
d7 = W.detail_for(v, S)
v = keys(v, ["j"], detail=d7)
assert tuple(v.detail["sel"]) == ("messages", 6), v.detail
v = keys(v, ["j"], detail=d7)
assert tuple(v.detail["sel"]) == ("messages", 9), v.detail
at7 = frame(v)
v = keys(v, ["Enter"], detail=d7)
assert v.detail["key"] == 9 and v.detail["stack"][-1]["key"] == 7, v.detail
assert "back to #7" in frame(v)[-1], frame(v)[-1]
v = keys(v, ["Esc"], detail=W.detail_for(v, S))
assert v.detail["key"] == 7 and frame(v) == at7, "Esc did not restore #7 as it was"
v = keys(v, ["q"], detail=d7)
assert v.mode == "overview" and not v.effects
assert not any(e[0] == "quit" for e in v.effects)
v = keys(v, ["G"])
assert frame(v) == base, "back in the overview, following, is not the frame it left"

# y copies the selected key in the overview and the reply command in a message detail; nothing else happens.
v = keys(View(), ["2", "y"])
assert v.copied == "docs/api.md" and v.effects == [("copy", "docs/api.md")], (v.copied, v.effects)
assert step(v, "j", S, size, T0).copied is None, "the copied footer lasts until the next key"
v = keys(View(), ["Enter"])  # following: Enter opens the newest message
assert v.detail["key"] == 9
v = keys(v, ["y"], detail=W.detail_for(v, S))
assert v.copied == 'agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."', v.copied
w = View(); w.me = "claude"
w = keys(keys(w, ["Enter"]), ["y"])
assert w.copied.startswith("agentbus --as claude post"), w.copied

# ? opens help from anywhere and Esc, q or ? return to where it was; a full-screen error takes r, ? and q only.
v = keys(View(), ["Enter", "?"])
assert v.mode == "help"
v = keys(v, ["q"])
assert v.mode == "detail" and v.detail["key"] == 9
err = {"code": "schema_refused", "message": "x", "retry_s": 1, "last_good_s": None}
v = keys(View(), ["2", "j"])
w = keys(v, ["j", "Enter", "/", "p", "Tab"], error=err)
assert (w.mode, w.focus, w.sel, w.filter, w.paused) == (v.mode, v.focus, v.sel, v.filter, v.paused), "an error frame took a key it should not"
assert ("read",) in step(v, "r", S, size, T0, None, err).effects and ("quit", 0) in step(v, "q", S, size, T0, None, err).effects
print("state machine cases passed")
PY
ok "Tab Tab j Enter opens the second claim; k pauses on the newest and holds it; G follows and clears +N new; refreshes keep the selected key; filters keep 6 and 9; kind:fyi says the kinds; filter input takes q, j, k and digits as text; Esc in the overview does nothing; details stack and go back one level; y copies"

echo "TEST 2b: y copies plain text safely, and a copied reply command means the same and runs nothing in every shell"
"$PY" - "$T" <<'PY' || fail "copy and paste"
import os, subprocess, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g, T = W.g, sys.argv[1]
S = W.snap("sample")
step, View = g["step"], g["View"]
T0 = W.when(W.T_NOW)
# Raw: a backslash and a long run of spaces are copied as written, not as clean()'s escapes.
snap = W.snap("sample")
snap["context"] = [{"key": "path", "value": "C:\\Users\\nate          x", "updated_by": "codex", "updated_at": W.T_NOW}]
v = View()
for k in ("3", "Enter"):
    v = step(v, k, snap, (100, 30), T0)
v = step(v, "y", snap, (100, 30), T0, W.detail_for(v, snap))
assert v.copied == "C:\\Users\\nate          x", repr(v.copied)
# W7: non-ASCII next to $, ` or a backslash is copied with the non-ASCII escaped (bash 3.2 under LANG=C reads
# bytes 0x80 and up as Meta keys on paste); plain non-ASCII, and ASCII with $, are copied as written.
assert g["copy_text"]("$(touch x)\u00c5") == "$(touch x)\\xc5", g["copy_text"]("$(touch x)\u00c5")
assert g["copy_text"]("caf\u00e9") == "caf\u00e9" and g["copy_text"]("$HOME") == "$HOME"
# Plain words: the copied reply command means the same in every shell (dash, sh, bash, zsh, fish when present),
# run here with a stub agentbus that records its arguments. A name or sender that is not a plain word is copied as
# NAME or SENDER for the person to fill in, so nothing in it can run.
import shutil
stub = os.path.join(T, "stubbin")
os.makedirs(stub, exist_ok=True)
with open(os.path.join(stub, "agentbus"), "w") as f:
    f.write('#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done > "$ARGS_OUT"\n')
os.chmod(os.path.join(stub, "agentbus"), 0o755)
shells = [["sh", "-c"]] + [[p, "-c"] for p in ("/bin/dash", shutil.which("bash"), shutil.which("zsh"), shutil.which("fish"))
                           if p and os.path.exists(p)]
evil = ["ops$(touch PWNED1)", "a;touch PWNED2", "`touch PWNED3`", "x' ; touch PWNED4 ; '", "$HOME", "a b\n touch PWNED5",
        "-n", "q\x1b]52;c;eA==\x07", "x\x1b'; touch PWNED6; #", "a\\", "it's\\'; touch PWNED7 #", "~root", ""]
plain = ["tests", "ws03-claude", "claude@host", "a.b_c+d=e:f,g/h"]
for sh in shells:
    for i, sender in enumerate(evil + plain):
        m = {"id": 9, "sender": sender, "kind": "question"}
        for me in ("NAME", sender):
            cmd = g["reply_command"](m, me)
            assert not any(ord(c) < 0x20 or 0x7f <= ord(c) for c in cmd), ("not plain ASCII", cmd)
            out = os.path.join(T, f"args{i}")
            r = subprocess.run(sh + [cmd], cwd=T, env=dict(os.environ, PATH=stub + ":/usr/bin:/bin", ARGS_OUT=out, HOME=T),
                               capture_output=True, text=True, timeout=60)
            assert r.returncode == 0, (sh, sender, r.stderr)
            got = open(out).read().split("\n")[:-1]
            word = lambda v, ph: v if v in plain else ph
            want = ["--as", word(me, "NAME"), "post", "--to", word(sender, "SENDER"), "--reply-to", "9", "--kind", "answer", "..."]
            assert got == want, (sh, sender, got)
assert not [f for f in os.listdir(T) if f.startswith("PWNED")], "a copied reply command ran a command"
print(len(evil + plain), "senders through", ", ".join(s[0] for s in shells), "- agentbus got the same words, nothing else ran")
PY
ok "y copies C:\\Users as written and escapes non-ASCII beside \$; a reply command copies plain words only (NAME or SENDER otherwise) and runs the same in sh, dash, bash, zsh"

echo "TEST 2c: a filter holds at most FILTER_MAX characters; a 4 KB paste settles the selection at most that many times"
"$PY" - <<'PY' || fail "filter cap"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g = W.g
S, T0 = W.snap("big"), W.when(W.T_NOW)
cap = g["FILTER_MAX"]
assert cap == 200, cap
real, calls = g["settle"], [0]
def counted(*a, **k):
    calls[0] += 1
    return real(*a, **k)
g["settle"] = counted
try:
    v = g["step"](g["View"](), "/", S, (100, 30), T0)
    for k in g["decode_keys"](b"x" * 4096):
        v = g["step"](v, k, S, (100, 30), T0)
finally:
    g["settle"] = real
assert v.filter == "x" * cap and v.mode == "filter", len(v.filter)
assert calls[0] <= cap, f"a 4 KB paste settled the selection {calls[0]} times"
print(f"4096 keys: filter {len(v.filter)} characters, {calls[0]} settles")
PY
ok "the filter stops at 200 characters and a 4 KB paste costs at most 200 selection updates"

echo "TEST 2d: dated history rows fit, a non-UTF-8 stdout measures what it writes, the body cache follows the bus file"
"$PY" - "$T" <<'PY' || fail "history, encoding, cache"
import os, shutil, sqlite3, subprocess, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
from term_oracle import width
from agentbus_cmd import agentbus_argv
g, T = W.g, sys.argv[1]
S, T0 = W.snap("sample"), W.when(W.T_NOW)
tw = g["text_width"]
# N2: history from earlier days (`Nov 2 00:00`) fits every width from 40 to 100.
hist = [{"value": "v" * 90, "updated_by": "claude", "updated_at": f"2026-10-{d:02d}T00:00:00Z"} for d in (30, 29, 3)]
data = {"section": "facts", "key": "baseline_sha", "top": 9, "scanned": False, "record": S["context"][0],
        "history": hist, "n_history": 3}
v = W.view(mode="detail", focus="facts", detail={"section": "facts", "key": "baseline_sha"})
for cols in range(40, 101):
    rows = [r.rstrip() for r in g["render"](v, S, W.WHERE, (cols, 40), T0, g["Paint"](False), detail=data)]
    assert all(tw(r) <= cols - 1 for r in rows), (cols, [r for r in rows if tw(r) > cols - 1])
    assert any("Oct 30 00:00" in r for r in rows), rows
# N3: under a latin-1 stdout, what cannot be encoded is written as ?; the row is measured as it will be written.
snap = W.snap("sample")
snap["messages"] = [dict(snap["messages"][0], body="é" * 60 + "漢" * 40)]
g["_WATCH_ENCODING"] = "latin-1"
g["wrap_lines"].cache_clear()
try:
    for cols in (40, 60, 100):
        for ascii_ in (True, False):
            for f in (W.view(), W.view(mode="detail", detail={"section": "messages", "key": 1})):
                rows = g["render"](f, snap, W.WHERE, (cols, 30), T0, g["Paint"](False, False, ascii_),
                                   detail=W.detail_for(f, snap))
                for r in rows:
                    out = r.encode("latin-1", "replace").decode("latin-1")
                    assert sum(width(c) for c in out) <= cols - 1, (cols, ascii_, out)
finally:
    g["_WATCH_ENCODING"] = None
    g["wrap_lines"].cache_clear()
# N4: the body cache follows the bus file: a replaced bus.db, or an id that comes back with another message.
env = dict(os.environ, HOME=T)
def bus(name, body):
    d = os.path.join(T, name, ".agentbus")
    os.makedirs(d, exist_ok=True)
    e = dict(env, AGENTBUS_DB=os.path.join(d, "bus.db"))
    j = subprocess.run(agentbus_argv() + ["--as", "a", "join", "--takeover"], env=e, capture_output=True, text=True, timeout=30)
    assert j.returncode == 0, j.stderr
    r = subprocess.run(agentbus_argv() + ["--as", "a", "post", body], env=e, capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    return os.path.join(d, "bus.db")
live = bus("cache1", "alpha")
cache = {}
body = lambda: g["watch_snapshot"](live, False, 200, body_head=4096, bodies=cache)["messages"][0]["body"]
def same_message(path, text):
    """path's message 1 with only its body changed: same id, time and sender (and, for bravo, the same length)."""
    c = sqlite3.connect(path)
    c.execute("UPDATE messages SET body=? WHERE id=1", (text,))
    c.commit(); c.close()
assert body() == "alpha"
# W5: another file (another inode) in its place, same id, time, sender and body length: read again.
other = os.path.join(T, "cache1", ".agentbus", "other.db")
shutil.copyfile(live, other)
same_message(other, "bravo")
os.replace(other, live)
assert body() == "bravo", "a replaced bus.db (another inode) was served from the cache"
# W6: the same file copied over in place (same inode), same id, time and sender, another length: read again.
shutil.copyfile(live, os.path.join(T, "cache1", "copy.db"))
same_message(os.path.join(T, "cache1", "copy.db"), "charlie!")
with open(os.path.join(T, "cache1", "copy.db"), "rb") as src, open(live, "r+b") as dst:
    data = src.read()
    dst.seek(0); dst.write(data); dst.truncate()
assert body() == "charlie!", "a bus.db copied over in place was served from the cache"
# An id that comes back as another message (another time) is read again too.
c = sqlite3.connect(live)
c.execute("UPDATE messages SET body='delta', ts='2026-01-01T00:00:00Z' WHERE id=1")
c.commit(); c.close()
assert body() == "delta"
# W2: help on a short pane: scrolling reaches every row of the help page, at heights 5 to 8.
for cols in (40, 50, 60, 80):
    for ascii_ in (False, True):
        full = [r.rstrip() for r in g["render"](W.view(mode="help"), S, W.WHERE, (cols, 400), T0,
                                                g["Paint"](False, False, ascii_))]
        content = {r for r in full[1:-1] if r.strip()}
        for rows in (5, 6, 7, 8):
            seen = set()
            for scroll in range(0, 400):
                t = [r.rstrip() for r in g["render"](W.view(mode="help", scroll=scroll), S, W.WHERE, (cols, rows), T0,
                                                     g["Paint"](False, False, ascii_))]
                assert len(t) == rows, (cols, rows, scroll)
                seen.update(t[1:-1])
            missing = content - seen
            assert not missing, (cols, rows, ascii_, "help rows scrolling never reaches", sorted(missing)[:3])
# W8: only the probe's own answer (row 2, column 2 or 3) counts; a modified F3 (ESC [ 1 ; m R) never does.
pa = g["probe_answer"]
assert (pa("CPR 2;2"), pa("CPR 2;3")) == (False, True)
assert all(pa(k) is None for k in ("CPR 1;5", "CPR 1;2", "CPR 1;3", "CPR 30;3", "CPR 2;4", "q"))
# M3, counted: with the cache, a body is read once (SQLite's trace shows the statements), at most BODY_HEAD long.
bigdb = bus("cache3", "x" * 10000)
for _ in range(3):
    subprocess.run(agentbus_argv() + ["--as", "a", "post", "y" * 9000], env=dict(env, AGENTBUS_DB=bigdb), check=True,
                   capture_output=True, timeout=60)
cache, seen = {}, []
def traced(con):
    con.set_trace_callback(seen.append)
snap = g["watch_snapshot"](bigdb, False, 200, body_head=g["BODY_HEAD"], bodies=cache, opened=traced)
assert [len(m["body"]) for m in snap["messages"]] == [4096] * 4 and all(m["body_cut"] for m in snap["messages"]), \
    [len(m["body"]) for m in snap["messages"]]
first = [q for q in seen if "substr(body" in q]
assert len(first) == 1, first  # one read of the four new bodies
seen.clear()
g["watch_snapshot"](bigdb, False, 200, body_head=g["BODY_HEAD"], bodies=cache, opened=traced)
assert not [q for q in seen if "substr(body" in q], ("a later tick read bodies again", seen)  # octet_length reads none
print("dated history fits 40 to 100; latin-1 rows fit as written; the cache read beta and gamma, not alpha; "
      "a body is read once, cut to 4096")
PY
ok "fact history from earlier days fits 40 to 100 columns; on a latin-1 stdout rows fit after the ? replacement; a replaced bus.db or a reused id is read again"

echo "TEST 3: the design's behaviour cases, on bin/agentbus's render (ported from the design mock)"
"$PY" - <<'PY' || fail "behaviour cases"
import os, re, sys, time
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g = W.g
tw = g["text_width"]
text_of, ids_in, FROZEN = W.text_of, W.ids_in, W.FROZEN
SIZES = [(40, 16), (60, 20), (60, 24), (80, 24), (100, 30)]
S = W.snap("sample")
at = lambda hhmm: f"2026-11-01T{hhmm}:00Z"
msg = lambda i, ts, s, to, k, body, reply=None, topic=None: {"id": i, "ts": ts, "sender": s, "recipient": to, "kind": k,
                                                              "topic": topic, "reply_to": reply, "body": body}
done = []

def case(fn):
    fn()
    done.append(fn.__name__)

@case
def pause_rollover():
    v = {"focus": "messages", "sel": {"messages": 9}, "paused": True, "frozen": FROZEN}
    for c, r in SIZES:
        t = text_of(c, r, v, snap="big", held="sample")
        sel = [l for l in t if l.startswith(">")]
        assert len(sel) == 1 and "#9" in sel[0], (c, r, sel)
        assert any("+200 new" in l for l in t), (c, r, "no +200 new")
        assert not any("quiet so far" in l for l in t) and 10 not in ids_in(t), (c, r)
    t = text_of(60, 20, dict(v, filter="kind:ask"), snap="big", held="sample")
    assert ids_in(t) == [6, 9] and any(l.startswith(">") and "#9" in l for l in t), t
    t = text_of(60, 20, {"focus": "messages"}, snap="big")
    assert 209 in ids_in(t) and 9 not in ids_in(t), "resume shows the newest"

@case
def selection_never_hidden():
    for c, r in SIZES:
        for emoji in (False, True):
            for sec, keyname, items in (("agents", "name", S["agents"]), ("claims", "resource", S["claims"]),
                                        ("facts", "key", S["context"]), ("messages", "id", S["messages"])):
                for it in items:
                    v = {"focus": sec, "sel": {sec: it[keyname]}}
                    if sec == "messages":
                        v.update(paused=True, frozen=FROZEN)
                    t = text_of(c, r, v, held="sample" if sec == "messages" else None, emoji=emoji)
                    sel = [l for l in t if l.startswith(">")]
                    assert len(sel) == 1, (c, r, sec, it[keyname], t)
                    assert not any(re.search(r"(…|\.\.\.) 0 (more|earlier|later)", l) for l in t), (c, r, sec, t)

@case
def kind_codes():
    m = lambda f: ids_in(text_of(100, 30, {"filter": f}))
    assert m("kind:ask") == m("kind:question") == [6, 9]
    assert m("kind:ALRT") == m("kind:alert") == [3]
    assert m("kind:hand") == m("kind:handoff") == [2, 8]
    assert m("kind:dec") == [4] and m("kind:ans") == [7]
    t = text_of(100, 30, {"filter": "kind:fyi"})
    assert any("kind must be one of" in l for l in t), "the error stays after Enter"

@case
def filter_coverage():
    t = text_of(100, 30, {"filter": "kind:alert"}, snap="big")
    assert any(l.startswith("Messages  0 of newest 200") for l in t), t
    assert any("9 older not searched · agentbus read" in l for l in t), t
    assert any(l.startswith("Agents  n/a") for l in t) and any(l.startswith("Facts  n/a") for l in t), t
    assert t[0].endswith("1 alert · 0 open questions"), t[0]  # the whole bus, by brief's rules (issue 66): #3 is open, #6 and #9 are answered
    t = text_of(100, 30, {"filter": "topic:ci"})
    assert ids_in(t) == [3] and any(l.startswith("Claims  n/a") for l in t), t
    assert ids_in(text_of(100, 30, {"filter": "everyone"})) == [1, 3], "a broadcast matches the word it is shown as"
    assert ids_in(text_of(60, 20, {"filter": "to:all"})) == [1, 3]

@case
def long_input():
    long = "from:tests " + "x" * 69
    for c, r in ((60, 20), (40, 16), (100, 30)):
        t = text_of(c, r, {"filter": long})
        assert len(t[-1]) <= c - 1 and all(k in t[-1] for k in ("Esc clear", "? help", "q quit")), t[-1]
        t = text_of(c, r, {"filter": long, "mode": "filter", "filter_input": True})
        assert tw(t[-1]) <= c - 1 and "_" in t[-1] and "Esc clear" in t[-1] and t[-1].startswith("/…"), t[-1]

@case
def detail_wraps():
    m = msg(123456, at("16:40"), "s" * 16, "r" * 16, "question", "short", reply=654321)
    snap = dict(S, messages=[m], counts=dict(S["counts"], messages=1))
    for c in (40, 60):
        t = text_of(c, 20, {"mode": "detail", "detail": {"section": "messages", "key": 123456}}, snapshot=snap)
        assert all(tw(l) <= c - 1 for l in t), t
        assert any("s" * 16 in l for l in t) and any("r" * 16 in l for l in t) and any("#123456" in l for l in t), t
    res = ("src/" + "/".join(f"module{i:02d}" for i in range(10)) + "/a_very_long_file_name_that_keeps_going.py")[:93]
    snap = dict(S, claims=[{"resource": res, "agent": "codex", "purpose": None, "expires_at": at("18:43")}])
    t = text_of(60, 20, {"mode": "detail", "focus": "claims", "detail": {"section": "claims", "key": res}}, snapshot=snap)
    i = next(i for i, l in enumerate(t) if l.startswith("  claim     "))
    got = t[i][12:]
    for l in t[i + 1:]:
        if not l.startswith(" " * 12):
            break
        got += l[12:]
    assert got == res and len(res) == 93, (got, res)

@case
def thread_limits():
    ms = [msg(1, at("10:00"), "a", "b", "note", "root")]
    ms += [msg(i, at("10:00"), "a", "b", "note", f"step {i}", reply=i - 1) for i in range(2, 27)]
    ms += [msg(i, at("10:00"), "b", "a", "answer", f"reply {i}", reply=26) for i in range(27, 52)]
    snap = dict(S, messages=ms, counts=dict(S["counts"], messages=len(ms)))
    t = text_of(100, 80, {"mode": "detail", "detail": {"section": "messages", "key": 26}}, snapshot=snap)
    assert any(l.startswith("Thread  41 shown") for l in t), t
    assert any("… #6 replies to #5 · open #6 to go further up" in l for l in t), t
    assert any("… 5 more replies · agentbus read --since 26" in l for l in t), t

@case
def wrap_linear():
    # Counted, not timed: every cell the wrapper measures (cell_width, direct or through text_width) for one
    # unbroken word at 1x and 2x. Linear is about 2x the cells; quadratic wrapping would be about 4x.
    wl, real, seen = g["wrap_lines"], g["cell_width"], [0]
    def counted(c):
        seen[0] += 1
        return real(c)
    def work(n):
        seen[0] = 0
        g["cell_width"] = counted
        try:
            wl.__wrapped__("w" * n, 57)
        finally:
            g["cell_width"] = real
        return seen[0]
    one = work(4000)  # checked before the 2x run, so quadratic wrapping fails fast
    assert 4000 <= one <= 4 * 4000, f"wrapping measured {one} cells for 4000 characters"  # never passes on 0
    two = work(8000)
    assert two <= 2.1 * one, f"wrapping is not linear: 2x text measured {two / one:.2f}x the cells"
    assert wl("a b", 5) is wl("a b", 5), "wrapping is cached by text and width"

BUSY = {"code": "busy", "retry_s": 1, "last_good_s": 27, "message": "the bus stayed locked for 250 ms"}

@case
def busy_keeps_frame():
    base = {"focus": "claims", "sel": {"claims": "src/auth/"}}
    for c, r in SIZES:
        a, b = text_of(c, r, base), text_of(c, r, dict(base, error=BUSY))
        assert a[1:] == b[1:] and "waiting · 27s old" in b[0], (c, r, b[0])
    t = text_of(60, 20, {"mode": "detail", "detail": {"section": "messages", "key": 7}, "error": BUSY})
    assert "waiting · 27s old" in t[0] and any("Thread" in l for l in t)

@case
def claim_holder_idle():
    t = text_of(100, 30, {"mode": "detail", "focus": "claims", "detail": {"section": "claims", "key": "src/auth/",
                                                                        "sel": ["agents", "codex"]}})
    holder = next(l for l in t if "held by" in l)
    assert "○ codex · implementer · seen 6m ago" in holder, holder

@case
def ascii_only():
    for e in W.fx["goldens"]:
        if e["ascii"]:
            t = text_of(e["cols"], e["rows"], e["view"], snap=e["snapshot"], ascii=True)
            assert all(ord(ch) < 128 for l in t for ch in l), (e["name"], t)

@case
def summary_and_agents():
    t = text_of(100, 30, {})
    assert t[0].endswith("1 alert · 1 open question"), t[0]
    assert text_of(60, 20, {})[0].endswith("1 ALRT · 1 ask")
    assert any("2 unread · holds src/auth/" in l for l in t), t
    assert t[-1].startswith("  k browse") and any(l.startswith("Messages  9") and "following · k to browse" in l
                                                  for l in t)

@case
def detail_marks():
    t = text_of(100, 30, {"mode": "detail", "detail": {"section": "messages", "key": 7, "thread": True}})
    assert any(l.startswith("* #7") for l in t) and not any(l.startswith(">") for l in t), t
    t = text_of(100, 30, {"mode": "detail", "detail": {"section": "messages", "key": 9}})
    assert any('agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."' in l for l in t), t
    assert "Esc/q back" in t[-1] and "q quit" not in t[-1], t[-1]
    t = text_of(100, 30, {"mode": "detail", "detail": {"section": "messages", "key": 10, "thread": True,
                                                         "sel": ["messages", 9]}}, snap="big")
    assert any(l.startswith("> #9") for l in t) and any(l.startswith("* #10") for l in t), t
    t = text_of(100, 30, {"mode": "detail", "detail": {"section": "messages", "key": 9, "thread": True,
                                                         "stack": [{"section": "messages", "key": 10,
                                                                    "sel": ["messages", 9]}]}}, snap="big")
    assert "back to #10" in t[-1], t[-1]

@case
def help_pages():
    for cols in range(40, 81):
        for rows in (16, 20, 24):
            for ascii_, emoji in ((False, False), (False, True), (True, False)):
                last = None
                for scroll in range(0, 120, 3):
                    t = text_of(cols, rows, {"mode": "help", "scroll": scroll}, ascii=ascii_, emoji=emoji)
                    assert len(t) == rows, (cols, rows, scroll, len(t))
                    for l in t:
                        assert tw(l) <= cols - 1, (cols, rows, ascii_, emoji, scroll, l)
                    intro = " ".join(l.strip() for l in t[1:5])  # the intro stays whole on every page
                    assert "watch only reads the bus" in intro and "never changes a claim." in intro, (cols, rows, t)
                    if t == last:
                        break
                    last = t

@case
def no_zero_more():
    one_fact = dict(S, context=S["context"][:1])
    for snap in (S, one_fact):
        for cols in (40, 47, 60, 80, 100):
            for rows in range(6, 31, 2):
                for f in ("", "x", "kind:ask", "from:c", "auth"):
                    for focus in ("agents", "claims", "facts", "messages"):
                        t = text_of(cols, rows, {"filter": f, "focus": focus}, snapshot=snap)
                        assert len(t) == rows, (cols, rows, f, focus, len(t))
                        bad = [l for l in t if re.search(r"(…|\.\.\.) 0 (more|earlier|later)", l)]
                        assert not bad and all(tw(l) <= cols - 1 for l in t), (cols, rows, f, focus, bad or t)

@case
def mentions_instr():
    snap = dict(S, claims=[{"resource": "src/my_mod/", "agent": "codex", "purpose": None, "expires_at": at("18:43")}],
                messages=[msg(1, at("16:00"), "a", "b", "note", "edited src/myXmod/ today")],
                counts=dict(S["counts"], messages=1))
    t = text_of(100, 30, {"mode": "detail", "focus": "claims", "detail": {"section": "claims", "key": "src/my_mod/"}},
                snapshot=snap)
    assert any("no message names it" in l for l in t), "a _ in a resource is a character, not a wildcard"

import json
cases = json.load(open(os.path.join(os.environ["TESTS_DIR"], "golden", "watch", "behaviour.json")))["cases"]
mock = {c["name"] for c in cases if c["runs"] == "mock"}
assert {n.replace("_", "-") for n in done} == mock, (sorted(mock - {n.replace("_", "-") for n in done}))
print(len(done), "behaviour cases passed on bin/agentbus")
PY
ok "all 16 of the design mock's behaviour cases pass on bin/agentbus's render"

echo "TEST 4: detail queries scan at most the newest 5000 messages, by primary key, and match mentions with instr"
"$PY" - "$T" <<'PY' || fail "detail queries"
import os, sqlite3, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g, R = W.g, __import__("render")
con = sqlite3.connect(":memory:")
con.row_factory = sqlite3.Row
con.executescript(g["SCHEMA"])
con.executemany("INSERT INTO messages(id, ts, sender, recipient, kind, body, reply_to) VALUES(?,?,?,?,?,?,?)",
                [(i, "2026-11-01T10:00:00Z", "a" if i % 2 else "b", "b" if i % 2 else "a", "note",
                  f"touches src/my_mod/ run {i}" if i % 3 == 0 else f"run {i}", i - 1 if i > 1 else None)
                 for i in range(1, 20001)])
con.execute("INSERT INTO agents(name, role, joined_at, last_seen) VALUES('a', 'r', 'x', 'x')")
con.execute("INSERT INTO claims(resource, agent, claimed_at, expires_at) VALUES('src/my_mod/', 'a', 'x', '2099-01-01T00:00:00Z')")
# Every statement the detail queries run reads the messages table through the id range, never a full scan.
plans = []
orig = con.execute
class Spy:
    def __init__(self, c): self.c = c
    def execute(self, sql, params=()):
        if "FROM messages" in sql and "id > ?" in sql:
            plans.append((sql, [tuple(r) for r in self.c.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()]))
        return self.c.execute(sql, params)
spy = Spy(con)
for sec, key in (("messages", 19999), ("agents", "a"), ("claims", "src/my_mod/")):
    d = g["watch_detail_rows"](spy, sec, key, 20000)
    assert d["scanned"], (sec, "a 20000-message bus is wider than the scan")
assert plans, "no windowed query ran"
for sql, plan in plans:
    text = " ".join(str(r[-1]) for r in plan)
    assert "SEARCH messages USING INTEGER PRIMARY KEY (rowid" in text and "SCAN" not in text, (sql, text)
d = g["watch_detail_rows"](con, "agents", "a", 20000)
assert d["n"] == 5000 and len(d["list"]) == 5 and d["list"][-1]["id"] == 20000 and d["first"] == 15001, (d["n"], d["first"])
d = g["watch_detail_rows"](con, "claims", "src/my_mod/", 20000)
assert d["n"] == len([i for i in range(15001, 20001) if i % 3 == 0]), d["n"]
d = g["watch_detail_rows"](con, "messages", 19999, 20000)
assert len(d["chain"]) == 20 and d["chain"][-1]["id"] == 19979 and d["further"] == 19978 and d["n_replies"] == 1, (len(d["chain"]), d["further"])
# The lists say how far they looked.
snap = {"agents": [{"name": "a", "role": "r", "joined_at": "2026-11-01T10:00:00Z", "last_seen": "2026-11-01T10:00:00Z"}],
        "claims": [], "goal": None, "context": [], "unread": {},
        "messages": [dict(r) for r in con.execute("SELECT id, ts, sender, recipient, kind, topic, body, reply_to FROM messages "
                                                   "ORDER BY id DESC LIMIT 200")][::-1],
        "counts": {"agents": 1, "claims": 0, "messages": 20000}}
v = W.view(mode="detail", focus="agents", detail={"section": "agents", "key": "a"})
rows = [r.rstrip() for r in g["render"](v, snap, "~/x", (100, 30), W.when("2026-11-01T10:00:00Z"), g["Paint"](False),
                                        detail=g["watch_detail_rows"](con, "agents", "a", 20000))]
assert any("5 of 5000 in newest 5000" in r for r in rows) and any("4995 older · agentbus read" in r for r in rows), rows
# instr, not LIKE: a _ in a resource matches only itself.
c2 = sqlite3.connect(":memory:"); c2.row_factory = sqlite3.Row; c2.executescript(g["SCHEMA"])
c2.execute("INSERT INTO messages(id, ts, sender, recipient, kind, body) VALUES(1, 'x', 'a', 'b', 'note', 'edited src/myXmod/ today')")
c2.execute("INSERT INTO messages(id, ts, sender, recipient, kind, body) VALUES(2, 'x', 'a', 'b', 'note', 'and src/my_mod/ too')")
d = g["watch_detail_rows"](c2, "claims", "src/my_mod/", 2)
assert d["n"] == 1 and [m["id"] for m in d["list"]] == [2], d
d = g["watch_detail_rows"](c2, "claims", "src/my%", 2)
assert d["n"] == 0, "a % in a resource matched as a wildcard"
print(len(plans), "windowed statements, every one on the id range")
PY
ok "on a 20000-message bus every detail statement reads the id range (EXPLAIN QUERY PLAN), lists say in newest 5000, and mentions use instr"

echo "TEST 5: colours and cleanup: the header is 30;43 (1;7 in ASCII), instructions are not dim, a failing screen write still restores the terminal"
"$PY" - <<'PY' || fail "colours and cleanup"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g = W.g
f = W.frame(100, 30, {}, paint_on=True)
assert f[0].startswith("\x1b[30;43m") and "\x1b[1;30;43m" not in f[0] and "\x1b[1m" not in f[0], repr(f[0][:40])
f = W.frame(100, 30, {}, paint_on=True, ascii=True)
assert f[0].startswith("\x1b[1;7m"), repr(f[0][:40])
f = W.frame(100, 30, {"error": {"code": "busy", "retry_s": 1, "last_good_s": 27, "message": "m"}}, paint_on=True)
assert "\x1b[33;40mwaiting · 27s old\x1b[0m" in f[0], repr(f[0])
err = {"code": "schema_refused", "retry_s": 1, "last_good_s": None, "message": "bus schema is not agentbus's"}
f = W.frame(100, 30, {"error": err}, paint_on=True)
reason = next(r for r in f if "bus schema is not agentbus" in r)
run = next(r for r in f if "Run: " in r)
assert "\x1b[2m" not in reason and "\x1b[2m" not in run and "\x1b[1mr\x1b[0m retry now" in f[-1], (reason, run, f[-1])
# Footer words are at normal intensity, keys bold, separators dim.
f = W.frame(100, 30, {}, paint_on=True)
assert "\x1b[1mq\x1b[0m quit" in f[-1] and "\x1b[2m quit" not in f[-1], repr(f[-1])

# Cleanup: a failing screen write must not skip the termios restore (runpy'd module, monkeypatched).
import io, termios, tty, types  # tty first: it reads termios's names when imported
calls = []
class BadOut:
    def write(self, s):
        if "\x1b[?1049l" in s:
            calls.append("write-failed")
            raise OSError(5, "EIO")
        return len(s)
    def flush(self):
        pass
    def isatty(self):
        return True
    encoding = "utf-8"
fake_termios = types.SimpleNamespace(tcgetattr=lambda fd: ["saved"], tcsetattr=lambda fd, when, attrs: calls.append(("tcsetattr", attrs)),
                                     TCSADRAIN=termios.TCSADRAIN)
real = sys.modules["termios"]
sys.modules["termios"] = fake_termios
class FakeStdin:
    def isatty(self): return True
    def fileno(self): return 0
g["sys"] = types.SimpleNamespace(stdout=BadOut(), stdin=FakeStdin(), exc_info=sys.exc_info, stderr=sys.stderr)
def boom(*a, **k):
    raise RuntimeError("the loop failed")
g["_watch_loop"] = boom
devnull = []
g["_stdout_to_devnull"] = lambda: devnull.append(1)
a = types.SimpleNamespace(_db="/nonexistent/bus.db", interval=1.0)
try:
    g["watch_live"](a, False, "~/x", g["Paint"](False))
except RuntimeError:
    pass
finally:
    sys.modules["termios"] = real
assert ("tcsetattr", ["saved"]) in calls and "write-failed" in calls, calls
assert calls.index(("tcsetattr", ["saved"])) < calls.index("write-failed"), ("termios is restored first", calls)
assert devnull, "after a failed screen write stdout is not redirected, so the exit's own flush can fail"
print("cleanup order:", calls)
PY
ok "the header bar is 30;43, never bold, and 1;7 in ASCII; waiting is 33;40; the reason, Run: and footer words carry no dim; a failing screen write during cleanup still restores termios, first"

# ---- live sessions on a pty (tests/watch_live_cases.py) ----------------------------------------------------------------
# The bus: the fixture's sample bus three days back, plus #10, a 400-character answer to #9 (watch_live_cases.py setup).
export AGENTBUS_DB="$T/live/.agentbus/bus.db"
mkdir -p "$T/live/.agentbus"
agentbus --as seed join >/dev/null; agentbus --as seed post "seed" >/dev/null
"$PY" "$TESTS_DIR/watch_live_cases.py" setup >/dev/null || fail "live bus setup"
cp "$AGENTBUS_DB" "$T/good.db"
live() { "$PY" "$TESTS_DIR/watch_live_cases.py" restore >/dev/null && "$PY" "$TESTS_DIR/watch_live_cases.py" "$1"; }

echo "TEST 6: live keys: arrows and j/k move >, Tab moves the hint, / takes q as text, Enter shows a whole body, Esc and q go back one level byte for byte"
live keys || fail "live keys"
ok "arrows do not quit and move >; Tab moves j/k move; / kind:question shows Messages 2 of 10 with q typed as text; a 400-character body is whole; Esc and q go back one level, byte for byte; ? and Esc"

echo "TEST 7: p pauses the whole view: a post shows +1 new and nothing else changes; p follows and shows it"
live pause || fail "pause"
ok "paused: +1 new, +4 new, no other row changes over several ticks; p shows the new message"

echo "TEST 8: paused on #9 while 200 messages arrive: #9 stays selected and shown, +200 new, through a resize"
live rollover || fail "pause rollover"
ok "pause rollover through a pty keeps #9 selected at 100x30 and after a resize to 60x20"

echo "TEST 9: q, Ctrl-C, SIGINT, SIGTERM and SIGHUP restore the terminal; SIGHUP exits 129"
live exits || fail "exits"
ok "q, the Ctrl-C key, SIGINT and SIGTERM exit 0, SIGHUP 129, each with termios as before and the cursor shown, alternate screen left"

echo "TEST 10: a refused bus says so and names the fix; the filter, selection, pause and open detail come back with the bus"
live refused || fail "refused bus"
ok "This bus could not be read and Run: agentbus upgrade; after the bus is put back, r shows the same frame"

echo "TEST 11: keys redraw and q exits while a read is in flight; a locked bus keeps the last frame"
live latency || fail "latency"
ok "20 keys redraw and q exits while a snapshot read is parked; with the bus locked, waiting · Ns old keeps the frame; the terminal is restored"

echo "TEST 12: TERM=dumb prints one frame without escape codes and says why on stderr"
live dumb || fail "TERM=dumb"
ok "TERM=dumb: one frame, no escape codes, exit 0, the stderr line"

echo "TEST 13: NO_COLOR and AGENTBUS_NO_EMOJI at 40 columns: every message row carries its kind code"
live narrow || fail "narrow kind codes"
ok "at 40 columns without colour or emoji every message row says hand, ask, ans, done, dec, ALRT or note"

echo "TEST 14: 30 mixed keys change nothing in the bus: bytes, every table, every cursor"
live readonly || fail "read-only"
ok "after 30 mixed keys bus.db's bytes and a full table dump are unchanged"

echo "TEST 15: y writes the reply command with OSC 52 and says so; nothing in the bus changes"
live copy || fail "copy"
ok "y on #9 writes ESC ] 52 ; c ; base64 BEL and the copied footer; the bus is unchanged"

echo "TEST 16: ASCII glyphs under TERM=linux, AGENTBUS_ASCII=1 and a terminal that draws ● two columns wide"
live ascii_auto || fail "ascii"
ok "TERM=linux, AGENTBUS_ASCII=1 and the probe each give pure-ASCII frames with a 1;7 header"

echo "TEST 17: a detail is read when it opens and on r, never per tick"
live detail_reads || fail "detail reads"
ok "watch_detail ran once over several ticks with a detail open, and once more on r"

echo "TEST 18: hostile bytes in every field the CLI takes, walked through every view, never reach the terminal raw"
live hostile || fail "hostile text"
ok "ESC, OSC 52, CSI, C1, bidi and zero-width bytes in names, roles, recipients, keys, values, resources, purposes, topics, bodies and the goal: none reached the pty raw in the overview, every detail, a nested detail, help, the filter and the footers"

echo "TEST 19: Ctrl-Z in a shell gives the terminal back and stops; fg takes it again and keys work at once"
live jobctl || fail "job control"
ok "Ctrl-Z shows the cursor and leaves the alternate screen before the prompt; fg restores cbreak, the alternate screen and a full frame; Tab works without Enter; q exits"

echo "TEST 20: 200 held messages of 1 MB each: j and k move the selection and the process stays small"
live bigbodies || fail "large bodies"
ok "with 200 bodies of 1 MB, 20 keys alternate the selection between #200 and #201, under 150 MB resident"

echo "TEST 21: when the watchdog ends a hung read, the terminal is restored and the exit says why"
live watchdog || fail "watchdog exit"
ok "a hung read ended by the watchdog exits 3 with its own reason, the screen and modes restored"

echo "TEST 22: a stdout that is not UTF-8 draws ASCII and keeps running"
live encodings || fail "encodings"
ok "PYTHONIOENCODING=ascii draws pure ASCII; a latin-1 locale runs; both quit cleanly"

echo "TEST 23: what y copies, pasted into an interactive zsh or bash inside bracketed paste, runs nothing"
live paste || fail "paste"
ok "senders, keys and values carrying ESC [ 201 ~, Ctrl-U and CR are copied without a control byte; pasted into each shell, nothing ran"

echo "TEST 24: the full-screen error's Run: command names the bus folder as one shell word, also one holding a space and a ;"
# Bug it catches: the frame pasted the folder in as it is (Run: agentbus init {where}), so "q dir;touch CANARY" made two commands.
"$PY" - <<'PY' || fail "the error frame's Run: command is not one command on the folder"
import os, shlex, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
odd = "/tmp/q dir;touch CANARY"
home = os.path.join(os.path.expanduser("~"), "q dir;touch CANARY")
for code, verb in (("no_bus", "init"), ("schema_older", "upgrade"), ("schema_refused", "upgrade"), ("schema_newer", "upgrade")):
    for where in (odd, home):
        err = {"code": code, "retry_s": 1, "last_good_s": None, "message": "m", "directory": where}
        f = W.frame(200, 30, {"error": err})
        run = next(r for r in f if "Run: " in r).split("Run: ", 1)[1].strip()
        run = run.removesuffix(" from a newer install")
        words = shlex.split(run.replace("~/", os.path.expanduser("~") + "/", 1) if run.split(" ")[2].startswith("~/") else run)
        assert words == ["agentbus", verb, where], (code, where, run, words)
print("error frame commands passed")
PY
ok "no_bus, schema_older, schema_refused and schema_newer frames name the folder as one shell word"

echo "TEST 25: started with --up 1, watch's hints and the reply y copies carry --up 1"
# Bug it catches: watch --up 1 showed "agentbus --as NAME goal" and copied "agentbus --as NAME post ...", which from the same
# folder reach the inner bus, not the one on screen.
"$PY" - <<'PY' || fail "a watch on an outer bus showed or copied a command without --up"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g = W.g
f = "\n".join(W.text_of(120, 30, {"up": 1}, snap="empty"))
assert 'no goal yet · agentbus --up 1 --as NAME goal "..."' in f, f
assert "Join with: agentbus --up 1 --as NAME join" in f, f
f0 = "\n".join(W.text_of(120, 30, {}, snap="empty"))
assert 'no goal yet · agentbus --as NAME goal "..."' in f0 and "Join with: agentbus --as NAME join" in f0, f0
S = W.snap("sample")
v = g["View"](); v.up = 1
for k in ["Enter", "y"]:
    v = g["step"](v, k, S, (100, 30), W.when(W.T_NOW), W.detail_for(v, S) if k == "y" else None, None)
assert v.copied.startswith("agentbus --up 1 --as NAME post --to "), v.copied
f = "\n".join(W.text_of(100, 30, {"up": 1, "mode": v.mode, "detail": v.detail}))
assert "agentbus --up 1 --as NAME post --to " in f, f
print("watch --up cases passed")
PY
ok "goal and join hints and the copied reply carry --up 1; with no --up they are as before"

echo "TEST 26: the older-versions hint quotes a fact key with a space, and the unread hint shows NAME for an agent name that is not a plain word"
# Bug it catches: "agentbus ctx history my key" (two arguments) and "--as co dex! inbox --peek" pasted as printed.
"$PY" - <<'PY' || fail "a watch hint puts a fact key or an agent name into a command unquoted"
import json, os, re, shlex, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
src = W.fx["detail"]["context_history"]["baseline_sha"]
W.fx["detail"]["context_history"]["my key"] = [dict(src[0], value="v%d" % i) for i in range(W.g["THREAD_MAX"] + 3)]
snap = json.loads(json.dumps(W.snaps["sample"]).replace("baseline_sha", "my key"))
t = W.text_of(100, 30, {"mode": "detail", "detail": {"section": "facts", "key": "my key"}}, snapshot=snap)
line = next(l for l in t if "older" in l)
assert shlex.split(line.split("·", 1)[1].strip()) == ["agentbus", "ctx", "history", "my key"], line
snap = json.loads(json.dumps(W.snaps["sample"]).replace('"codex"', '"co dex!"'))
t = W.text_of(100, 30, {"mode": "detail", "detail": {"section": "agents", "key": "co dex!"}}, snapshot=snap)
line = next(l for l in t if "unread" in l)
cmd = re.search(r"· (agentbus .*?) shows them", line).group(1)
assert shlex.split(cmd) == ["agentbus", "--as", "NAME", "inbox", "--peek"], line
print("watch hints are shell safe")
PY
ok "the ctx history hint quotes the key; the unread hint names NAME for an unsafe agent name"

echo "TEST 27: a negative span reads 0s, and fit to zero columns is empty"
"$PY" - <<'PY' || fail "human_span and fit edges"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g = W.g
span, fit = g["human_span"], g["fit"]
for seconds, want in ((-5, "0s"), (-3600, "0s"), (0, "0s"), (45, "45s"), (60, "1m"), (3599, "59m"), (3600, "1h"), (7140, "1h 59m"), (86400, "1d"), (601200, "6d 23h")):
    assert span(seconds) == want, (seconds, span(seconds), want)
assert fit("hello", 0) == "" and fit("", 0) == "" and fit("世界", 0) == "", (fit("hello", 0), fit("世界", 0))
assert fit("hello", -3) == "", repr(fit("hello", -3))
for text in ("hello world", "世界世界", "ab"):
    for n in range(1, 12):
        out = fit(text, n)
        assert g["text_width"](out) == n, (text, n, out)   # always exactly n columns
assert fit("hello world", 1) == "…" and fit("hello world", 5) == "hell…", (fit("hello world", 1), fit("hello world", 5))
print("human_span and fit edges")
PY
ok "human_span(-5) is 0s, not -1m; fit(text, 0) is empty, not a one-column ellipsis; fit is exactly n columns for n 1 to 11"

echo "TEST 28: fit_left, fit_ascii and fit_left_ascii give exactly n columns, n 0 to 11"
# Bug it catches: fit_left at 0 columns printed a one-column ellipsis, and fit_left_ascii at 1 or 2 columns printed all
# three dots, so a narrow field pushed the row wider than the terminal.
"$PY" - <<'PY' || fail "fit_left and the ASCII fits overflow narrow fields"
import os, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from watch_case import W
g = W.g
for name in ("fit_left", "fit_ascii", "fit_left_ascii"):
    f = g[name]
    for text in ("~/src/app/very/long/path", "世界世界", "ab", ""):
        for n in range(0, 12):
            out = f(text, n)
            assert g["text_width"](out) == n, (name, text, n, out)
    assert f("hello", -3) == "", (name, f("hello", -3))
assert g["fit_left"]("~/src/app", 4) == "…app" and g["fit_left_ascii"]("~/src/app", 2) == "..", (g["fit_left"]("~/src/app", 4), g["fit_left_ascii"]("~/src/app", 2))
print("narrow fits")
PY
ok "fit_left, fit_ascii and fit_left_ascii are exactly n columns for n 0 to 11, and empty below zero"

echo "All watch key tests passed"
