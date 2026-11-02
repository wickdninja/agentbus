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
                           "alert (ALRT), done")

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
    assert "newest 200: 0 alerts" in t[0], t[0]
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
    wl = g["wrap_lines"]
    def cost(n):
        best = 9.0
        for _ in range(7):  # best of 7: a timing check must not trip on a busy machine
            t0 = time.perf_counter()
            wl.__wrapped__("w" * n, 57)
            best = min(best, time.perf_counter() - t0)
        return best
    ratio = cost(32000) / max(cost(16000), 1e-6)
    assert ratio < 3.0, f"wrapping is not linear: 2x text took {ratio:.1f}x"
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
ok "all 14 of the design mock's behaviour cases pass on bin/agentbus's render"

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
agentbus --as seed post "seed" >/dev/null
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

echo "TEST 11: key to redraw under 100 ms for 20 keys, also while another process holds the bus; q then exits in under 350 ms"
live latency || fail "latency"
ok "keys redraw under 100 ms idle and with the bus locked; waiting · Ns old keeps the frame; q exits fast with the terminal restored"

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

echo "All watch key tests passed"
