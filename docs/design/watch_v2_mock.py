#!/usr/bin/env python3
"""Design mock for `agentbus watch` v2 (issue #7, workstream 05). Not shipped code.

It draws every frame in docs/design/watch-v2.md from the sample buses below, so the alignment in the
design is exact and the frames, the golden files, fixture.json, behaviour.json and the HTML review page
come from one source. The build (06, issue #8) does not import this file: it implements `render` in
bin/agentbus, must reproduce tests/golden/watch/*.txt byte for byte, and must pass the behaviour cases.

    python3 docs/design/watch_v2_mock.py              # rewrite every generated artifact
    python3 docs/design/watch_v2_mock.py --check      # exit 1 if any artifact is out of date
    python3 docs/design/watch_v2_mock.py --behaviour  # run the behaviour cases this mock can run

Column arithmetic reuses v0.1.0's own helpers (clean, fit, fit_left, ago, time_left, text_width,
share_rows, role_emoji and the colour and emoji tables), loaded from bin/agentbus with runpy.
Revision 2 (after the wd-opus and wd-astra reviews): see "Revision 2" in watch-v2.md.
"""
import functools
import html
import json
import os
import pathlib
import re
import runpy
import sys
import time
from datetime import timedelta

ROOT = pathlib.Path(__file__).resolve().parents[2]
os.environ["TZ"] = "UTC"  # detail times are local HH:MM; the goldens pin the zone
time.tzset()
AB = runpy.run_path(str(ROOT / "bin" / "agentbus"), run_name="agentbus_design_mock")
clean, ab_fit, ab_fit_left = AB["clean"], AB["fit"], AB["fit_left"]
ago, time_left, tw, share_rows = AB["ago"], AB["time_left"], AB["text_width"], AB["share_rows"]
role_emoji, colour_map, when = AB["role_emoji"], AB["colour_map"], AB["_when"]
KIND_EMOJI, KIND_COLOURS = AB["KIND_EMOJI"], AB["KIND_COLOURS"]
KINDS = ("note", "question", "answer", "handoff", "decision", "alert", "done", "todo", "dropped")
KIND_CODE = {"handoff": "hand", "question": "ask", "answer": "ans", "done": "done", "decision": "dec",
             "alert": "ALRT", "note": "note", "todo": "todo", "dropped": "drop"}
SECTION_EMOJI = {"Agents": "👥", "Claims": "🔒", "Facts": "📌", "Messages": "💬",
                 "Thread": "🧵", "History": "📜", "Mentioned in": "🔗"}
# Header bar: black on bus yellow, never bold (a terminal that draws bold as bright turns bold black
# grey). AGENTBUS_ASCII, TERM=linux and an ambiguous-wide terminal use reverse video instead.
HEADER_SGR, HEADER_PLAIN = "30;43", "1;7"
WAIT_SGR = "33;40"  # `waiting · Ns old` on the bar: yellow on black
WIDE_COLS, MIN_COLS, IDLE_MIN = 72, 40, 5
HELD = 200          # rows per section watch holds (v0.1.0's limit)
SCAN = 5000         # detail queries look at most at the newest 5000 messages
THREAD_MAX = 20     # ancestors and direct replies a message detail loads, each
LIST_MAX = 5        # messages an agent or claim detail lists
LOCK_WAIT_MS = 250  # the longest watch waits for the bus lock; then it keeps the last frame
# Watch's own glyphs. Unicode (the default) or ASCII (AGENTBUS_ASCII=1, TERM=linux, or a terminal that
# draws East Asian Ambiguous characters two columns wide).
GLYPHS = {
    False: {"on": "●", "off": "○", "goal": "◆ ", "nogoal": "◇ ", "new": "▌", "ell": "…", "dot": "·",
            "arrow": "→", "reply": "↳#", "lines": "↵+", "open": "*", "up": "↑", "down": "↓"},
    True: {"on": "*", "off": "o", "goal": "goal: ", "nogoal": "", "new": "|", "ell": "...", "dot": "-",
           "arrow": "->", "reply": "re:#", "lines": "+", "open": "*", "up": "Up", "down": "Down"},
}

GOLDEN = ROOT / "tests" / "golden" / "watch"
DOC = ROOT / "docs" / "design" / "watch-v2.md"
HTML_OUT = ROOT / "docs" / "design" / "watch-v2.html"

# ---------------------------------------------------------------- the sample buses

T_NOW = "2026-11-01T16:44:00Z"
T_BIG = "2026-11-01T16:58:20Z"
WHERE = "~/src/acme-api"


def at(hhmm):
    return f"2026-11-01T{hhmm}:00Z"


def msg(i, ts, sender, to, kind, body, reply=None, topic=None):
    return {"id": i, "ts": ts, "sender": sender, "recipient": to, "kind": kind, "topic": topic,
            "reply_to": reply, "body": body}


SAMPLE_MSGS = [
    msg(1, at("14:45"), "claude", "*", "note", "Kickoff: auth moves to the new token API today. Claim before you edit."),
    msg(2, at("14:47"), "claude", "codex", "handoff", "Take src/auth/: swap the session cookie for the token API.",
        topic="auth"),
    msg(3, at("15:10"), "tests", "*", "alert", "CI on main is red since a1b2c3; hold merges until test_login passes.",
        topic="ci"),
    msg(4, at("15:12"), "claude", "codex", "decision", "Keep the refresh path. Tokens live 7 days and refresh rotates them.",
        topic="auth"),
    msg(5, at("16:33"), "codex", "claude", "done", "Refresh path done, tests green.\nBranch ws-auth, sha 4f2e9c1.",
        topic="auth"),
    msg(6, at("16:35"), "tests", "codex", "question", "Is the 401 body part of the contract, or can it change?",
        topic="auth"),
    msg(7, at("16:37"), "codex", "tests", "answer", "Plain text for now. A test will pin it once the spec says otherwise, "
        "and the handler returns the same body for every 401.", reply=6, topic="auth"),
    msg(8, at("16:43"), "claude", "codex", "handoff",
        "Next: the token endpoint in src/auth/token.py once the spec lands. I will review the diff.", topic="auth"),
    msg(9, at("16:44"), "tests", "claude", "question", "Which signing algorithm should the tokens use? The spec draft says "
        "RS256, the old service used HS256, and the fixtures need one answer before I write them.", reply=7, topic="auth"),
]


def big_msgs():
    """The bus 14 minutes later: #10 answers #9, then 199 CI notes (#11 to #209)."""
    out = [msg(10, "2026-11-01T16:45:00Z", "claude", "tests", "answer",
               "RS256. The spec draft wins; the old service is going away.", reply=9, topic="auth")]
    for i in range(11, 210):
        s = (i - 10) * 4
        ts = f"2026-11-01T16:{45 + s // 60:02d}:{s % 60:02d}Z"
        out.append(msg(i, ts, "codex", "*", "note", f"token suite run {i - 10}: 412 passed, 0 failed", topic="ci"))
    return out


BUS = SAMPLE_MSGS + big_msgs()  # every message the detail queries can read
AGENTS = [
    {"name": "claude", "role": "planner", "joined_at": at("14:40"), "last_seen": at("16:44")},
    {"name": "codex", "role": "implementer", "joined_at": at("14:41"), "last_seen": at("16:38")},
    {"name": "tests", "role": "tester", "joined_at": at("14:52"), "last_seen": at("16:44")},
]
CLAIMS = [  # watch_snapshot order: soonest expiry first
    {"resource": "docs/api.md", "agent": "tests", "purpose": None, "expires_at": at("17:26")},
    {"resource": "src/auth/", "agent": "codex", "purpose": "token refactor", "expires_at": at("18:43")},
]
GOAL = {"goal": "auth on the new token API", "set_by": "nate", "set_at": at("14:44")}
CONTEXT = [  # newest first
    {"key": "baseline_sha", "value": "abc123", "updated_by": "codex", "updated_at": at("16:37")},
    {"key": "runtime", "value": "python 3.9+", "updated_by": "claude", "updated_at": at("16:30")},
]
def open_counts(msgs, window=None):
    """What watch_open reads from the bus, by brief's rules: an alert is open until any message replies to it, a question until
    an answer replies to it, a todo until a done or dropped does."""
    def closed(kinds):
        return {m["reply_to"] for m in msgs if m["reply_to"] and (kinds is None or m["kind"] in kinds)}
    count = lambda kind, kinds: sum(1 for m in msgs if m["kind"] == kind and m["id"] not in closed(kinds))
    return {"alerts": count("alert", None), "questions": count("question", ("answer",)),
            "todos": count("todo", ("done", "dropped")), "window": window}


SAMPLE = {
    "agents": AGENTS, "claims": CLAIMS, "goal": GOAL, "context": CONTEXT, "messages": SAMPLE_MSGS,
    "unread": {"claude": 1, "codex": 2, "tests": 0},  # from cursors, read without writing (addendum R6)
    "counts": {"agents": 3, "messages": 9, "claims": 2}, "open": open_counts(SAMPLE_MSGS),
}
EMPTY = {"agents": [], "claims": [], "goal": None, "context": [], "messages": [], "unread": {},
         "counts": {"agents": 0, "messages": 0, "claims": 0},
         "open": {"alerts": 0, "questions": 0, "todos": 0, "window": None}}
BIG = {
    "agents": [dict(a, last_seen=s) for a, s in zip(AGENTS, (at("16:58"), at("16:58"), at("16:55")))],
    "claims": CLAIMS, "goal": GOAL, "context": CONTEXT, "messages": BUS[-HELD:],
    "unread": {"claude": 0, "codex": 0, "tests": 12},
    "counts": {"agents": 3, "messages": len(BUS), "claims": 2}, "open": open_counts(BUS),
}
SNAPSHOTS = {"sample": SAMPLE, "empty": EMPTY, "big": BIG}
SNAP_T = {"sample": T_NOW, "empty": T_NOW, "big": T_BIG}
# What the detail views read beyond the snapshot (06: watch_detail, one read-only open per request, run on
# open and on r only). The bus as of a snapshot is every message in "messages" up to the snapshot's newest id.
DETAIL = {
    "claimed_at": {"docs/api.md": at("16:26"), "src/auth/": at("15:30")},
    "context_history": {
        "baseline_sha": [{"value": "abc123", "updated_by": "codex", "updated_at": at("16:37")},
                         {"value": "9f8e7d6", "updated_by": "claude", "updated_at": at("15:02")}],
        "runtime": [{"value": "python 3.9+", "updated_by": "claude", "updated_at": at("16:30")}],
    },
    "messages": BUS,
}

REFUSED = {"code": "schema_refused", "retry_s": 1, "last_good_s": None,
           "message": "bus schema is not agentbus's: table messages differs (no column request_id)"}
NEWER = {"code": "schema_newer", "retry_s": 1, "last_good_s": None, "version": "0.2.0",
         "message": "bus schema 3 is newer than this agentbus understands (2)"}
BUSY = {"code": "busy", "retry_s": 1, "last_good_s": 27,
        "message": f"the bus stayed locked for {LOCK_WAIT_MS} ms"}
NOBUS = {"code": "no_bus", "retry_s": 1, "last_good_s": 40,
         "message": "no bus here or in any parent folder"}
FULL_SCREEN = ("schema_refused", "schema_older", "schema_newer", "no_bus")

DEFAULT_VIEW = {"mode": "overview", "focus": "messages", "sel": {}, "paused": False, "frozen": {},
                "filter": "", "filter_input": False, "detail": None, "scroll": 0,
                "fresh": [], "error": None, "stale": None, "copied": None}


def S(name, title, blurb, view, snap="sample", live=True, held=None, ascii=False):
    return {"name": name, "title": title, "blurb": blurb, "view": view, "snap": snap, "live": live,
            "held": held, "ascii": ascii}


FROZEN = {"snapshot": "sample", "t_now": T_NOW}
STATES = [
    S("overview", "Overview, following",
      "What opens. Everything at a glance: the pinned goal, who is here and what each one has waiting and holds, "
      "what is claimed, the shared facts and the newest messages. The header answers \"what needs me?\": open "
      "alerts, open questions and open todos (an alert no message replies to, a question no answer replies to, a todo no done or dropped replies to). Messages follow the stream; "
      "message 9 arrived in the last 3 seconds, so it carries the `▌` bar and a bold body. While following, "
      "j does nothing in Messages, so the footer says `k browse`.",
      {"fresh": [9]}),
    S("section-focus", "A section focused, a row selected",
      "After Tab, Tab, j: Claims has the focus, so its title says `j/k move · Enter open`, and `src/auth/` is "
      "selected (`>` and reverse video). Messages keep following underneath.",
      {"focus": "claims", "sel": {"claims": "src/auth/"}}),
    S("messages-paused", "Paused",
      "After k in Messages: the whole view freezes, as it was at 16:44, so you can read (and nothing on the "
      "screen moves, which is also the reduced-motion mode). Rows hidden above and below the window are "
      "counted. p or G follows again.",
      {"focus": "messages", "sel": {"messages": 8}, "paused": True, "frozen": FROZEN}, held="sample"),
    S("pause-rollover", "Paused while 200 messages arrive",
      "Paused on #9, then 200 messages arrive (#10 to #209), more than the 200 watch holds. Pause keeps the "
      "records, the selection and the viewport it froze, so #9 stays on screen and selected; the title counts "
      "`+200 new`. p or G replaces the frozen view with the newest one.",
      {"focus": "messages", "sel": {"messages": 9}, "paused": True, "frozen": FROZEN}, snap="big", held="sample"),
    S("message-detail", "Message detail with its thread",
      "Enter on message 7: every field and the whole body, wrapped, never cut; the command that replies to it; "
      "and the thread (the messages it replies to and the replies to it). The open message is marked `*`. "
      "j/k select a thread row and Enter opens it; t hides the thread; Esc or q goes back one level.",
      {"mode": "detail", "detail": {"section": "messages", "key": 7, "thread": True}}),
    S("detail-nav", "Moving inside a detail",
      "On the bus with 209 messages: Enter on #10, then j. #10 answers #9, which is older than the 200 messages "
      "watch holds; the detail query loaded it, so it can be selected and opened like any other row.",
      {"mode": "detail", "detail": {"section": "messages", "key": 10, "thread": True,
                                    "sel": ["messages", 9]}}, snap="big"),
    S("detail-nested", "A detail opened from a detail",
      "Enter on #9 from the previous frame: #9 opens on top of #10. The footer says where Esc or q goes back to.",
      {"mode": "detail", "detail": {"section": "messages", "key": 9, "thread": True,
                                    "stack": [{"section": "messages", "key": 10, "sel": ["messages", 9]}]}},
      snap="big"),
    S("copied", "Copied",
      "y in a message detail copies the reply command (OSC 52). Some terminals ignore OSC 52, so the footer "
      "says what was copied and where it is on screen to select by hand.",
      {"mode": "detail", "detail": {"section": "messages", "key": 9, "thread": True},
       "copied": "agentbus --as NAME post --to tests --reply-to 9 --kind answer \"...\""}),
    S("agent-detail", "Agent detail",
      "Enter on an agent: its role, when it was last seen, how many messages wait for it, what it holds, and its "
      "last 5 messages (sent by it or addressed to it), with the route to the rest. j/k select a claim or a "
      "message; Enter opens it.",
      {"mode": "detail", "focus": "agents", "detail": {"section": "agents", "key": "codex"}}),
    S("claim-detail", "Claim detail",
      "Enter on a claim: the whole resource, the holder with the same activity dot as the overview, purpose, "
      "when it was taken and when it runs out, and the messages that name it. The holder and the messages are "
      "selectable.",
      {"mode": "detail", "focus": "claims", "detail": {"section": "claims", "key": "src/auth/",
                                                     "sel": ["agents", "codex"]}}),
    S("fact-detail", "Fact detail",
      "Enter on a fact: the whole key and value and its history, newest first, each value whole (what "
      "`agentbus ctx history KEY` prints).",
      {"mode": "detail", "focus": "facts", "detail": {"section": "facts", "key": "baseline_sha"}}),
    S("help", "Help",
      "? from anywhere: every key, mark and word on the screen, in plain words. With emoji on it also explains "
      "the emoji. Esc or q closes it; where the page is taller than the terminal, j/k scroll it.",
      {"mode": "help"}),
    S("filter", "Filter, typing",
      "/ then `kind:ask`: the input sits in the footer and every key is text (q types a q). A kind takes its "
      "word or the short code help and the narrow rows show. Sections the filter does not apply to say `n/a` "
      "and give their rows to the others. Enter keeps the filter, Esc clears it.",
      {"mode": "filter", "filter": "kind:ask", "filter_input": True}),
    S("filter-kept", "Filter kept",
      "After Enter: the filter stays on (here the word `auth`), the footer shows it, Esc clears it and / edits it. "
      "A long filter is cut in the footer, never the keys.",
      {"filter": "auth"}),
    S("filter-error", "Filter with an unknown kind",
      "A `kind:` that is neither a kind's start nor its code matches nothing and says which kinds exist, on the "
      "row above the input; the row stays after Enter.",
      {"mode": "filter", "filter": "kind:fyi", "filter_input": True}),
    S("filter-coverage", "A filter on a bus bigger than the view",
      "209 messages, of which watch holds the newest 200. `kind:alert` finds none in those 200, and says so: "
      "`0 of newest 200`, and the 9 older messages were not searched (`agentbus read` reads them). The header "
      "says the same of its counts.",
      {"filter": "kind:alert"}, snap="big"),
    S("busy", "Bus busy",
      f"Another process holds the bus. watch waits at most {LOCK_WAIT_MS} ms for it, then keeps the last frame "
      "and everything you were doing (here a selected claim) and says how old the frame is. Keys keep working.",
      {"focus": "claims", "sel": {"claims": "src/auth/"}, "error": BUSY}),
    S("error-refused", "Bus refused",
      "The bus could not be read (here a v0.1.0 bus whose tables differ). The sections are not drawn at all, so "
      "nothing stale passes for current. The fix is one command. watch keeps retrying; r retries now; your "
      "place comes back with the bus.",
      {"error": REFUSED}),
    S("error-newer", "Bus newer than this watch",
      "The bus was upgraded by a newer agentbus than the one running this watch.",
      {"error": NEWER}),
    S("error-nobus", "Bus gone",
      "The bus folder was removed while watch was open.",
      {"error": NOBUS}),
    S("empty-bus", "Empty bus",
      "A fresh bus: every section says how to fill it (the v0.1.0 lines, kept).",
      {}, snap="empty"),
    S("stale", "Running old code",
      "The bus copy on disk was upgraded to 0.2.0 while this watch kept running older code; the Messages title "
      "says so, next to the follow state.",
      {"stale": "0.2.0"}),
    S("ascii", "ASCII glyphs",
      "`AGENTBUS_ASCII=1`, `TERM=linux`, or a terminal that draws ambiguous-width characters two columns wide: "
      "watch's own marks become ASCII (`* o | ... -> re:#6 +1 -`), the goal reads `goal:`, emoji are off and the "
      "header is reverse video. Same layout, same meaning.",
      {"fresh": [9]}, ascii=True),
    S("ascii-detail", "ASCII glyphs, message detail",
      "Message 9 in ASCII mode, with its reply command.",
      {"mode": "detail", "detail": {"section": "messages", "key": 9, "thread": True}}, ascii=True),
    S("ascii-help", "ASCII glyphs, help",
      "Help in ASCII mode lists the ASCII marks.",
      {"mode": "help"}, ascii=True),
    S("once", "One frame (`--once`, a pipe, or `TERM=dumb`)",
      "Not a terminal, `--once`, or `TERM=dumb`/unset: one frame, content only, no footer, no hints, no escape "
      "codes; TERM=dumb also prints `agentbus: TERM=dumb, printing one frame. Use a terminal for the live view.` "
      "on stderr. Emoji are off whenever stdout is not a terminal; the emoji variant is what `--once` prints on "
      "one.",
      {}, live=False),
]
STATE = {s["name"]: s for s in STATES}
# Extra single goldens: (name, state-like dict, cols, rows)
EXTRA = [
    ("facts-focus-40x16", S("facts-focus", "", "", {"focus": "facts", "sel": {"facts": "runtime"}}), 40, 16),
    ("agents-focus-40x16", S("agents-focus", "", "", {"focus": "agents", "sel": {"agents": "tests"}}), 40, 16),
    ("too-narrow-39x8", S("too-narrow", "", "", {}), 39, 8),
    # Help's last page (G): every row wrapped within the width (revision 3, the w2-06 review's M4).
    ("help-end-60x20", S("help-end", "", "", {"mode": "help", "scroll": 999}), 60, 20),
    ("help-end-40x16", S("help-end", "", "", {"mode": "help", "scroll": 999}), 40, 16),
    ("ascii-help-end-72x24", S("ascii-help-end", "", "", {"mode": "help", "scroll": 999}, ascii=True), 72, 24),
    ("ascii-help-end-40x16", S("ascii-help-end", "", "", {"mode": "help", "scroll": 999}, ascii=True), 40, 16),
]

# ---------------------------------------------------------------- rows made of painted segments


class Row:
    """One physical row: segments of (text, SGR). sel: the whole row in reverse video, inner colours off."""

    def __init__(self, *segs, sel=False):
        self.segs, self.sel = [], sel
        for s in segs:
            self.add(*s)

    def add(self, text, sgr=""):
        if text:
            self.segs.append((text, sgr))
        return self

    def extend(self, other):
        self.segs.extend(other.segs)
        return self

    @property
    def width(self):
        return sum(tw(t) for t, _ in self.segs)

    @property
    def text(self):
        return "".join(t for t, _ in self.segs)


def right(left, right_segs, W):
    """left, then right_segs ending at column W; right_segs dropped when they do not fit."""
    r = Row(*right_segs)
    if right_segs and left.width + 2 + r.width <= W:
        left.add(" " * (W - left.width - r.width))
        left.extend(r)
    return left


def first_fit(left, variants, W, sgr):
    for v in variants:
        if not v or left.width + 2 + tw(v) <= W:
            return right(left, [(v, sgr)] if v else [], W)
    return left


@functools.lru_cache(maxsize=4096)
def wrap_lines(text, width):
    """Cleaned text wrapped at width columns: linear in the text, cached by (text, width).
    A word longer than the row is broken, never cut."""
    width = max(1, width)
    out = []
    for para in text.split("\n"):
        line, lw = [], 0
        for word in para.split(" "):
            ww = tw(word)
            if lw and lw + 1 + ww <= width:
                line += [" ", word]
                lw += 1 + ww
                continue
            if not lw and ww <= width:
                line, lw = [word], ww
                continue
            if ww <= width:
                out.append("".join(line))
                line, lw = [word], ww
                continue
            if lw:  # a long word starts on the current row after a space, as far as it goes
                if lw + 1 < width:
                    line.append(" ")
                    lw += 1
                else:
                    out.append("".join(line))
                    line, lw = [], 0
            for c in word:
                cw = tw(c)
                if lw + cw > width:
                    out.append("".join(line))
                    line, lw = [], 0
                line.append(c)
                lw += cw
        out.append("".join(line))
    return tuple(out)


def fit_ascii(text, n):
    """fit() with an ASCII ellipsis."""
    s = " ".join(clean(text if isinstance(text, str) else ("" if text is None else str(text))).split())
    n = max(0, n)
    if tw(s) <= n:
        return s + " " * (n - tw(s))
    keep = max(0, n - 3)
    out, w = [], 0
    for c in s:
        if w + tw(c) > keep:
            break
        out.append(c)
        w += tw(c)
    return "".join(out) + "..."[:n - w] + " " * max(0, n - w - 3)


def fit_left_ascii(text, n):
    s = clean(text)
    if tw(s) <= n:
        return s + " " * (n - tw(s))
    out, w = [], 0
    for c in reversed(s):
        if w + tw(c) > n - 3:
            break
        out.append(c)
        w += tw(c)
    return "..." + "".join(reversed(out)) + " " * (n - 3 - w)


def plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def bus_as_of(snap):
    """The bus a detail query reads: every message up to the snapshot's newest one (DETAIL["messages"], plus
    the snapshot's own rows for the made-up buses of the behaviour cases)."""
    top = max((m["id"] for m in snap["messages"]), default=0)
    byid = {m["id"]: m for m in DETAIL["messages"] if m["id"] <= top}
    byid.update({m["id"]: m for m in snap["messages"]})
    return [byid[i] for i in sorted(byid)]


def kind_matches(kind, want):
    """kind:X matches a kind that starts with X or whose short code is X (case ignored)."""
    k, w = str(kind).lower(), want.lower()
    return k.startswith(w) or KIND_CODE.get(k, "").lower() == w


KIND_ERROR = "kind must be one of: " + ", ".join(
    k if KIND_CODE[k] == k else f"{k} ({KIND_CODE[k]})" for k in KINDS)
MSG_ONLY = ("to", "kind", "topic")  # filter fields that apply to messages only


class Frame:
    def __init__(self, cols, rows, emoji, view, snap, where, t_now, live=True, held=None, ascii=False):
        self.cols, self.rows, self.live, self.A = cols, rows, live, ascii
        self.E = emoji and not ascii
        self.g = GLYPHS[ascii]
        self.W, self.wide = cols - 1, cols >= WIDE_COLS
        self.v = dict(DEFAULT_VIEW, **view)
        self.cur, self.where, self.t_cur = snap, where, t_now
        # Paused: the whole display is the frozen snapshot at its own time; only +N new comes from now.
        if self.v["paused"] and held is not None:
            self.snap, self.t = held, when(self.v["frozen"].get("t_now")) or t_now
            self.pending = max(0, snap["counts"]["messages"] - held["counts"]["messages"])
        else:
            self.snap, self.t, self.pending = snap, t_now, 0
        self.colour = colour_map(self.snap["agents"])
        self.hsgr = HEADER_PLAIN if ascii else HEADER_SGR

    # ------------------------------------------------ shared pieces

    def tx(self, s):
        """Watch's own words in the current glyph set."""
        if not self.A:
            return s
        return s.replace("…", "...").replace("·", "-").replace("→", "->").replace("↳#", "re:#")

    def fit(self, text, n):
        return fit_ascii(text, n) if self.A else ab_fit(text, n)

    def ac(self, name):
        return str(self.colour(name))

    def hhmm(self, ts):
        t = when(ts)
        if t is None:
            return "?"
        local = t.astimezone()
        today = self.t.astimezone().date()
        return local.strftime("%H:%M") if local.date() == today else \
            f"{local.strftime('%b')} {local.day} {local.strftime('%H:%M')}"

    def ago_words(self, ts):
        a = ago(ts, self.t)
        return "now" if a == "now" else f"{a} ago"

    def idle(self, a):
        seen = when(a["last_seen"]) if a else None
        return seen is None or (self.t - seen).total_seconds() > IDLE_MIN * 60

    def header(self, right_text, wait=None):
        """The bar: name, folder cut from the left, then the right-hand text. wait (`waiting · Ns old`, the
        bus is busy) is always shown; the right-hand text goes first when both do not fit."""
        W, H = self.W, self.hsgr
        head = " 🚌 agentbus  " if self.E else " agentbus  "
        sep = self.tx(" · ")
        right_text = self.tx(right_text or "")
        wait = self.tx(wait) if wait else ""
        if wait and right_text and tw(head) + tw(right_text) + tw(sep) + tw(wait) > W:
            right_text = ""
        segs = [(right_text + (sep if right_text and wait else ""), H), (wait, WAIT_SGR)]
        tail_w = sum(tw(t) for t, _ in segs)
        room = W - tw(head) - tail_w - 2
        if room >= 8:
            row = Row((head + (fit_left_ascii if self.A else ab_fit_left)(self.where, room) + " ", H), *segs)
        else:  # no room for the folder: the name, then the right-hand text, as much as fits
            left = next((h for h in (head, head[:-1], " agentbus ") if tw(h) + tail_w <= W), " agentbus ")
            if tw(left) + tail_w > W:
                segs = [(self.fit(segs[0][0] + segs[1][0], W - tw(left)).rstrip(), WAIT_SGR if wait else H)]
            row = Row((left, H), *segs)
        row.add(" " * (W - row.width), H)
        return row

    def summary(self):
        """The header's right-hand text in the overview: what needs a person. Counted by the rules brief lists by, over the
        whole bus (the newest 5000 messages, and saying so, on a very large one); open todos only when there are some."""
        o = self.snap["open"]
        alerts, asks, todos = o["alerts"], o["questions"], o["todos"]
        if self.wide:
            text = f"{plural(alerts, 'alert')} · {plural(asks, 'open question')}" + (f" · {plural(todos, 'open todo')}" if todos else "")
        else:
            text = f"{alerts} ALRT · {asks} ask" + (f" · {todos} todo" if todos else "")
        if o["window"]:
            text = f"newest {o['window']}: " + text
        return text

    def wait(self):
        e = self.v["error"]
        return f"waiting · {e['last_good_s']}s old" if e and e["code"] == "busy" else None

    def goal_row(self):
        W, g = self.W, self.snap.get("goal")
        if g:
            lead = "  🎯 " if self.E else "  " + self.g["goal"]
            tail = clean(f"{g['set_by']} {self.g['dot']} {ago(g['set_at'], self.t)}")
            goal_w = W - tw(lead) - 2 - tw(tail)
            if goal_w < 12 or not self.wide and tw(clean(g["goal"])) > goal_w:  # narrow: the goal first
                tail, goal_w = "", W - tw(lead)
            text = self.fit(g["goal"], goal_w)
            row = Row((lead, "1;33"), (text.rstrip() if not tail else text, "1"))
            if tail:
                row.add("  " + tail, "2")
            return row
        lead = "  🎯 " if self.E else "  " + self.g["nogoal"]
        return Row((lead + self.fit(self.tx('no goal yet · agentbus --as NAME goal "..."'), W - tw(lead)), "2"))

    def title(self, name, count, right_variants=(), right_sgr="2"):
        left = Row(((SECTION_EMOJI.get(name, "") + " " if self.E and name in SECTION_EMOJI else "") + name, "1"),
                   (f"  {count}" if count != "" else "", "2"))
        return first_fit(left, [self.tx(v) for v in right_variants], self.W, right_sgr)

    def footer(self, items, prefix=None):
        """items: (key, words, priority); lowest priority dropped first until the row fits. Keys bold, words
        at normal intensity (they are instructions), separators dim."""
        W = self.W
        keep = list(items)
        sep = self.tx(" · ")
        while True:
            row = Row(("  ", ""))
            if prefix:
                row.extend(prefix)
                if keep:
                    row.add(sep, "2")
            for i, (k, w, _) in enumerate(keep):
                if i:
                    row.add(sep, "2")
                row.add(k, "1")
                row.add((" " + self.tx(w)) if w else "", "")
            if row.width <= W or not keep:
                break
            keep.remove(min(keep, key=lambda x: x[2]))
        return row

    def more_row(self, text):
        return Row(("  " + self.fit(self.tx(text), self.W - 2).rstrip(), "2"))

    # ------------------------------------------------ section rows

    def agent_row(self, a, sel=False, hot=(), mark=None):
        W, E = self.W, self.E
        idle = self.idle(a)
        nw = 16 if self.wide else 12
        lead_w = 4 if E else 1
        rw = W - 2 - lead_w - 1 - nw - 1 - 5
        rolew = 16 if self.wide else 12
        info = self.agent_info(a)
        if info and rw >= rolew + 8:
            text = self.fit(a["role"], rolew - 1) + " " + self.fit(info, rw - rolew)
        else:
            text = self.fit(a["role"], rw) if (self.wide or rw >= 8) else " " * rw
        row = Row((mark or ("> " if sel else "  "), ""),
                  (self.g["off"] if idle else self.g["on"], "2" if idle else self.ac(a["name"])), sel=sel)
        if E:
            row.add(" " + role_emoji(a["role"]))
        row.add(" ")
        row.add(self.fit(a["name"], nw), "1" if a["name"] in hot else "")
        row.add(" ")
        row.add(text, "2")
        row.add(ago(a["last_seen"], self.t).rjust(5), "2")
        return row

    def agent_info(self, a):
        parts = []
        n = self.snap.get("unread", {}).get(a["name"], 0)
        if n:
            parts.append(f"{n} unread")
        held = [c["resource"] for c in self.snap["claims"] if c["agent"] == a["name"]]
        if held:
            parts.append(f"holds {held[0]}" + (f" +{len(held) - 1}" if len(held) > 1 else ""))
        return self.tx(" · ").join(parts)

    def claim_row(self, c, sel=False):
        W = self.W
        res_w = max(14, min(36, W // 3))
        hw = 12 if self.wide else 10
        rest = f"{time_left(c['expires_at'], self.t)} left" + (f" · {c['purpose']}" if self.wide and c["purpose"] else "")
        return Row(("> " if sel else "  ", ""), (self.fit(c["resource"], res_w), ""), (" ", ""),
                   (self.fit(c["agent"], hw), self.ac(c["agent"])), (" ", ""),
                   (self.fit(self.tx(rest), W - 2 - res_w - 1 - hw - 1), "2"), sel=sel)

    def fact_row(self, x, sel=False):
        W = self.W
        key_w = max(10, min(24, W // 5)) if self.wide else max(12, min(24, W // 4))
        if self.wide:
            by_w, by = min(20, W // 4), self.tx(f"{x['updated_by']} · {ago(x['updated_at'], self.t)}")
        else:
            by_w, by = 4, ago(x["updated_at"], self.t)
        return Row(("> " if sel else "  ", ""), (self.fit(x["key"], key_w), ""), (" ", ""),
                   (self.fit(x["value"], W - 2 - key_w - 1 - by_w - 1), ""), (" ", ""),
                   (self.fit(by, by_w).rstrip().rjust(by_w), "2"), sel=sel)

    def msg_row(self, m, sel=False, new=False, here=False):
        W, E, g = self.W, self.E, self.g
        kind = str(m["kind"])
        kc = str(KIND_COLOURS.get(kind, 2))
        emo = (KIND_EMOJI.get(kind, "📝") + " ") if E else ""
        if self.wide:
            to = "everyone" if m["recipient"] == "*" else m["recipient"]
            mid_w, route_w, arrow, kind_cell = 5, 24, f" {g['arrow']} ", emo + self.fit(kind, 9)
        else:
            to = "all" if m["recipient"] == "*" else m["recipient"]
            route_w = 13 + len(g["arrow"]) - 1  # the ASCII arrow takes a column from the body, not the names
            mid_w, arrow, kind_cell = 4, g["arrow"], emo + self.fit(KIND_CODE.get(kind, kind[:4]), 4)
        part = (route_w - len(arrow)) // 2
        frm, dest = self.fit(m["sender"], part).rstrip(), self.fit(to, part).rstrip()
        lines = str(m["body"] or "").split("\n")
        extra = f" {g['lines']}{len(lines) - 1}" if len(lines) > 1 else ""
        reply = f"{g['reply']}{m['reply_to']} " if m["reply_to"] else ""
        fixed = 2 + mid_w + route_w + 1 + tw(kind_cell) + 1 + tw(extra) + 1 + 4
        if not self.wide and W - fixed - tw(reply) < 8:
            reply = ""  # narrow: the body keeps 8 columns before the reply mark is shown
        body_w = W - fixed - tw(reply)
        mark = ">" if sel else g["open"] if here else g["new"] if new else " "
        row = Row(sel=sel)
        row.add(mark, kc if mark == g["new"] else "1" if here else "")
        row.add(" ")
        row.add(self.fit("#" + str(m["id"]), mid_w), "1" if here else "2")
        row.add(frm, self.ac(m["sender"]))
        row.add(arrow, "2")
        row.add(dest, "2" if m["recipient"] == "*" else self.ac(to))
        row.add(" " * (route_w - tw(frm) - len(arrow) - tw(dest)) + " ")
        row.add(kind_cell, kc)
        row.add(" ")
        row.add(reply, "2")
        text = self.fit(lines[0], body_w).rstrip()  # the ↵+N mark follows the text, then the padding
        row.add(text, "1" if new else "")
        row.add(extra, "2")
        row.add(" " * (body_w - tw(text)) + " ")
        row.add(ago(m["ts"], self.t).rjust(4), "2")
        return row

    # ------------------------------------------------ filter

    def filter_tokens(self):
        f = self.v["filter"].strip()
        return f.split() if f else []

    def kind_error(self):
        for tok in self.filter_tokens():
            if tok.lower().startswith("kind:"):
                want = tok[5:]
                if not any(kind_matches(k, want) for k in KINDS):
                    return KIND_ERROR
        return None

    def not_applicable(self, section):
        """The first filter field that does not apply to this section, or None."""
        if section == "messages":
            return None
        for tok in self.filter_tokens():
            field, colon, _ = tok.lower().partition(":")
            if colon and field in MSG_ONLY:
                return field
        return None

    def matches(self, section, item):
        toks = self.filter_tokens()
        if not toks:
            return True
        if self.kind_error():
            return False
        for tok in toks:
            low = tok.lower()
            field, colon, val = low.partition(":")
            if colon and field in ("from",) + MSG_ONLY:
                if section == "messages":
                    if field == "from":
                        ok = str(item["sender"]).lower().startswith(val)
                    elif field == "to":
                        r = str(item["recipient"]).lower()
                        ok = r == "*" and val in ("*", "all", "everyone") or r != "*" and r.startswith(val)
                    elif field == "topic":
                        ok = str(item.get("topic") or "").lower().startswith(val)
                    else:
                        ok = kind_matches(item["kind"], val)
                else:
                    who = {"agents": "name", "claims": "agent", "facts": "updated_by"}[section]
                    ok = str(item[who]).lower().startswith(val)
            else:
                fields = {"agents": ("name", "role"), "claims": ("resource", "agent", "purpose"),
                          "facts": ("key", "value", "updated_by"),
                          "messages": ("id", "sender", "recipient", "body")}[section]
                vals = [str(item.get(f) or "").lower() for f in fields]
                if section == "messages" and item["recipient"] == "*":
                    vals += ["everyone", "all"]  # a broadcast is shown as everyone (wide) or all (narrow)
                ok = any(low in x for x in vals)
            if not ok:
                return False
        return True

    # ------------------------------------------------ whole frames

    def render(self):
        if self.cols < MIN_COLS:
            return self.pad([Row((ab_fit(f"watch needs {MIN_COLS}+ columns", self.cols), ""))])
        e = self.v["error"]
        if e and e["code"] in FULL_SCREEN:
            return self.error_frame()
        if self.v["mode"] == "help":
            return self.help_frame()
        if self.v["mode"] == "detail":
            return self.detail_frame()
        return self.overview()

    def pad(self, out, footer=None):
        out = out[:self.rows - (1 if footer else 0)]
        while len(out) < self.rows - (1 if footer else 0):
            out.append(Row())
        if footer:
            out.append(footer)
        return out

    @staticmethod
    def window(n, k, si, bottom):
        """First index of a k-row window over n rows that shows row si: anchored at the bottom (Messages) or
        the top (the other sections), moved only as far as the selection needs."""
        if n <= k:
            return 0
        start = n - k if bottom else 0
        if si is not None:
            if si < start:
                start = si
            elif si >= start + k:
                start = si - k + 1
        return start

    def overview(self):
        W, v, snap, live = self.W, self.v, self.snap, self.live
        filtering = bool(self.filter_tokens())
        fresh = set(v["fresh"]) if not v["paused"] else set()
        hot = {m["sender"] for m in snap["messages"] if m["id"] in fresh}
        focus, sel = v["focus"], v["sel"]
        secs = []
        for name, key, items, rowf, empty, cmd, keyf in (
                ("Agents", "agents", snap["agents"], self.agent_row,
                 "no one yet. Join with: agentbus --as NAME join", "who", lambda x: x["name"]),
                ("Claims", "claims", snap["claims"], self.claim_row, "nothing claimed", "claims",
                 lambda x: x["resource"]),
                ("Facts", "facts", snap["context"], self.fact_row, "none yet", "ctx get", lambda x: x["key"])):
            total = snap["counts"]["agents"] if key == "agents" else snap["counts"]["claims"] if key == "claims" \
                else len(items)
            na = self.not_applicable(key) if filtering else None
            keep = [] if na else [x for x in items if self.matches(key, x)]
            rows_ = [rowf(x, sel=(focus == key and sel.get(key) == keyf(x)), **({"hot": hot} if key == "agents" else {}))
                     for x in keep]
            beyond = max(0, total - len(items))
            secs.append({"name": name, "key": key, "total": total, "held": len(items), "n": len(keep), "rows": rows_,
                         "empty": empty, "cmd": cmd, "na": na, "beyond": beyond, "older": filtering and beyond > 0})
        msgs = snap["messages"]
        n_msgs = snap["counts"]["messages"]
        capped = n_msgs > len(msgs)
        msg_keep = [m for m in msgs if self.matches("messages", m)]
        msg_rows = [self.msg_row(m, sel=(focus == "messages" and sel.get("messages") == m["id"]),
                                 new=m["id"] in fresh) for m in msg_keep]
        sel_idx = next((i for i, m in enumerate(msg_keep) if focus == "messages" and sel.get("messages") == m["id"]), None)
        older_m = filtering and capped
        err = self.kind_error() if live else None

        def need(s):
            if s["na"]:
                return 0
            if filtering:
                return s["n"] + (1 if s["older"] else 0)
            return max(1, len(s["rows"]) + (1 if s["beyond"] else 0))
        natural = 3 + 4 + sum(need(s) for s in secs) + max(1, len(msg_rows)) + older_m
        gap = live and (self.rows >= 30 or natural + 4 <= self.rows)
        err_rows = [Row((r.text, "31")) for r in self.wrap(err, W - 2, "  ")] if err else []
        if live:
            fixed = 1 + 1 + 1 + 4 + (4 if gap else 0) + len(err_rows)
            body_rows = max(4, self.rows - fixed)
            want = max(1, len(msg_rows) + older_m)
            msg_share = min(want, max(3, body_rows // 2))
            shares = share_rows([need(s) for s in secs], max(0, body_rows - msg_share))
            msg_share = max(1, body_rows - sum(shares))
        else:
            shares = [need(s) for s in secs]
            msg_share = 21

        out = [self.header(self.summary(), self.wait()), self.goal_row()]
        for s, share in zip(secs, shares):
            name, key, rows_, n, total = s["name"], s["key"], s["rows"], s["n"], s["total"]
            if gap or not live:
                out.append(Row())
            if s["na"]:
                out.append(self.title(name, "n/a", [f"{s['na']}: is for messages", ""]))
                continue
            count = (f"{n} of newest {s['held']}" if s["beyond"] else f"{n} of {total}") if filtering else str(total)
            older_row = self.more_row(f"… {s['beyond']} older not searched · agentbus {s['cmd']}")
            if filtering and n == 0:
                out.append(self.title(name, count, ["no match"]))
                if s["older"] and share:
                    out.append(older_row)
                continue
            hint = ["j/k move · Enter open", "j/k · Enter", ""] if live and focus == key else []
            if not rows_:
                out.append(self.title(name, count, hint))
                out.append(Row(("  " + self.fit(s["empty"], W - 2), "2")))
                continue
            show_older = s["older"] and share >= 2
            avail = share - (1 if show_older else 0) if live else len(rows_) + 1
            extra = 0 if filtering else s["beyond"]
            nr = len(rows_)
            si = next((i for i, r in enumerate(rows_) if r.sel), None)
            if nr + (1 if extra else 0) <= avail:
                out.append(self.title(name, count, hint))
                out.extend(rows_)
                if extra:
                    out.append(self.more_row(f"… {extra} more · agentbus {s['cmd']}"))
            elif avail >= 2:
                k = avail - 1
                start = self.window(nr, k, si, bottom=False)
                hidden = nr - k + extra
                out.append(self.title(name, count, hint))
                out.extend(rows_[start:start + k])
                out.append(self.more_row(f"… {hidden} more" + (f" · agentbus {s['cmd']}" if extra else "")))
            elif avail <= 0:  # no row at all: the title says how many are hidden (never 0)
                out.append(self.title(name, count, [f"… {nr + extra} more"]))
            else:  # one row: the selected one, and the title says how many are hidden
                hidden = nr - 1 + extra
                mark = f"… {hidden} more"
                out.append(self.title(name, count, [mark + " · j/k move · Enter open", mark + " · j/k · Enter", mark]
                                      if live and focus == key else [mark]))
                out.append(rows_[si or 0])
            if show_older:
                out.append(older_row)
        if gap or not live:
            out.append(Row())
        out += self.messages_block(msgs, msg_keep, msg_rows, sel_idx, n_msgs, capped, older_m, msg_share, filtering)
        if not live:
            return out
        footer = self.overview_footer()
        body = out[:self.rows - 1 - len(err_rows)]
        while len(body) < self.rows - 1 - len(err_rows):
            body.append(Row())
        return body + err_rows + [footer]

    def messages_block(self, msgs, keep, rows_, si, total, capped, older_m, share, filtering):
        v, live, focus = self.v, self.live, self.v["focus"]
        out = []
        rhs, fsgr = [], "2"
        if live:
            if v["paused"]:
                p, base = self.pending, f"paused at {self.t.astimezone().strftime('%H:%M')}"
                follow = ([f"{base} · +{p} new · p or G to follow", f"paused · +{p} new · p or G to follow",
                           f"paused · +{p} new", "paused"] if p else
                          [f"{base} · p or G to follow", "paused · p or G to follow", "paused"])
                fsgr = "33"
            else:
                follow = ["following · k to browse", "following"] if focus == "messages" else ["following"]
            if v["stale"]:
                follow = [f"restart for {v['stale']} · {f}" for f in follow] + follow
                fsgr = "33"
            rhs = follow
        count = (f"{len(keep)} of newest {len(msgs)}" if capped else f"{len(keep)} of {total}") if filtering else str(total)
        older_row = self.more_row(f"… {total - len(msgs)} older not searched · agentbus read")
        if filtering and not keep:
            out.append(self.title("Messages", count, ["no match"]))
            if older_m:
                out.append(older_row)
            return out
        out.append(self.title("Messages", count, rhs, fsgr))
        if not rows_:
            out.append(Row(("  quiet so far", "2")))
            return out
        pre = [older_row] if older_m else []
        avail = (share if live else 21) - len(pre)
        beyond = 0 if filtering else total - len(msgs)
        n = len(rows_)
        if n <= avail and not beyond:
            return out + pre + rows_
        k = avail
        for _ in range(4):
            start = self.window(n, k, si, bottom=True)
            earlier, later = start + beyond, n - start - min(k, n)
            marks = (1 if earlier else 0) + (1 if later > 0 else 0)
            if min(k, n) + marks <= avail:
                break
            k = max(1, avail - marks)
        k = min(k, n)
        out += pre
        if earlier:
            out.append(self.more_row(f"… {earlier} earlier" + (" · agentbus read" if beyond else "")))
        out += rows_[start:start + k]
        if later > 0:
            out.append(self.more_row(f"… {later} later"))
        return out

    def filter_footer(self):
        W = self.W
        text = clean(self.v["filter"])
        rhs = [("Enter", "1"), (" keep", ""), (self.tx(" · "), "2"), ("Esc", "1"), (" clear", "")]
        rw = sum(tw(t) for t, _ in rhs)
        room = W - 2 - rw - 2
        if tw(text) > room:  # scroll the input so the cursor end shows
            ell = self.g["ell"]
            keep, w = [], tw(ell)
            for c in reversed(text):
                if w + tw(c) > room:
                    break
                keep.append(c)
                w += tw(c)
            text = ell + "".join(reversed(keep))
        row = Row(("/", "1;33"), (text, ""), ("_", "1;33"))
        return right(row, rhs, W)

    def copied_footer(self):
        text, W = self.v["copied"], self.W
        short = self.tx(f"  copied: {text} · if paste fails, select it here")
        if tw(short) <= W:
            return Row((short, ""))
        what = "the reply command" if self.v["mode"] == "detail" else "the selected row"
        return Row(("  " + self.fit(self.tx(f"copied {what} · if paste fails, select it above"), W - 2).rstrip(), ""))

    def overview_footer(self):
        v = self.v
        if v["copied"]:
            return self.copied_footer()
        if v["mode"] == "filter":
            return self.filter_footer()
        q = [("?", "help", 90), ("q", "quit", 100)]
        if v["filter"]:  # the keys to leave the filter always fit; the filter text is cut instead
            req = [("Esc", "clear", 95)] + q
            room = self.W - self.footer(req).width - 3
            text = "/" + clean(v["filter"])
            if tw(text) > room:
                text = self.fit(text, room).rstrip()
            return self.footer([req[0], ("/", "edit", 70), ("j/k", "move", 60), ("Enter", "open", 50)] + q,
                               prefix=Row((text, "1;33")))
        if v["paused"]:
            return self.footer([("j/k", "move", 60), ("Enter", "open", 50), ("p", "follow", 80), ("y", "copy", 15),
                                ("g/G", "top/bottom", 20), ("/", "filter", 40)] + q)
        if v["focus"] != "messages":
            return self.footer([("j/k", "move", 60), ("Enter", "open", 50), ("y", "copy", 15), ("Tab", "section", 30),
                                ("/", "filter", 40)] + q)
        return self.footer([("k", "browse", 60), ("Enter", "open", 50), ("/", "filter", 40), ("p", "pause", 20),
                            ("Tab", "section", 30)] + q)

    # ------------------------------------------------ detail

    def wrap(self, text, width, indent):
        return [Row((indent + l, "")) for l in wrap_lines(clean(text, newlines=True), max(1, width))]

    def label_rows(self, label, text, sgr="", sel=False):
        """A label and a value wrapped under itself; nothing in a detail is cut."""
        lab = label.ljust(10)
        lines = wrap_lines(clean(text), max(1, self.W - 2 - tw(lab)))
        return [Row(("> " if sel and i == 0 else "  ", ""), (lab if i == 0 else " " * tw(lab), "2"), (l, sgr), sel=sel and i == 0)
                for i, l in enumerate(lines)]

    def pack(self, fields, indent="  ", gap="  "):
        """Fields (lists of segments) on rows of the page width, `gap` apart, wrapped between fields (a field
        that starts a row drops its leading separator); a field wider than a row wraps inside itself."""
        W, iw = self.W, tw(indent)
        rows, cur = [], Row((indent, ""))
        for f in fields:
            fw = sum(tw(t) for t, _ in f)
            if cur.width > iw and cur.width + tw(gap) + fw > W:
                rows.append(cur)
                cur = Row((indent, ""))
            if cur.width > iw:
                cur.add(gap, "2")
            if fw > W - cur.width:
                text = "".join(t for t, _ in f)
                lines = wrap_lines(text, W - iw)
                for l in lines[:-1]:
                    cur.add(l, f[0][1])
                    rows.append(cur)
                    cur = Row((indent, ""))
                cur.add(lines[-1], f[0][1])
                continue
            for t, s in f:
                cur.add(t, s)
        rows.append(cur)
        return rows

    def agent_line(self, name, sel=False, prefix="", extra=""):
        """`held by   ○ ✋ codex · implementer · seen 6m ago`: the same activity dot as the overview, wrapped
        between fields when the row is short."""
        a = next((x for x in self.snap["agents"] if x["name"] == name), None)
        idle = self.idle(a)
        first = [(self.g["off"] if idle else self.g["on"], "2" if idle else self.ac(name))]
        if self.E and a:
            first.append((" " + role_emoji(a["role"]), ""))
        first.append((" " + clean(name), self.ac(name)))
        fields = [first]
        sep = self.tx(" · ")
        if a and a["role"]:
            fields.append([(clean(a["role"]), "2")])
        if a:
            fields.append([(self.tx(f"seen {self.ago_words(a['last_seen'])}"), "2")])
        if extra:
            fields.append([(self.tx(extra), "2")])
        rows = self.pack(fields, indent=" " * (2 + tw(prefix)), gap=sep)
        lead = Row(("> " if sel else "  ", ""), (prefix, "2"), sel=sel)
        lead.segs += rows[0].segs[1:]
        return [lead] + rows[1:]

    def detail_frame(self):
        d, W = self.v["detail"], self.W
        sec, key = d["section"], d["key"]
        sel = tuple(d["sel"]) if d.get("sel") else None
        bus = bus_as_of(self.cur)[-SCAN:]
        scanned = len(bus_as_of(self.cur)) > SCAN
        body = [Row()]
        related = False
        hint = ["j/k select · Enter open", "j/k · Enter", ""]
        if sec == "messages":
            byid = {m["id"]: m for m in bus}
            m = byid[key]
            label = f"message #{m['id']}"
            kind = str(m["kind"])
            kc = str(KIND_COLOURS.get(kind, 2))
            to = "everyone" if m["recipient"] == "*" else m["recipient"]
            fields = [[(f"#{m['id']}", "1")],
                      [(clean(m["sender"]), self.ac(m["sender"])), (f" {self.g['arrow']} ", "2"),
                       (clean(to), "2" if to == "everyone" else self.ac(to))],
                      [((KIND_EMOJI.get(kind, "📝") + " " if self.E else "") + kind, kc)]]
            if m["reply_to"]:
                fields.append([(f"{self.g['reply']}{m['reply_to']}", "2")])
            if m.get("topic"):
                fields.append([(f"topic {clean(m['topic'])}", "2")])
            when_t = self.tx(f"{self.hhmm(m['ts'])} · {self.ago_words(m['ts'])}")
            meta = self.pack(fields)
            if len(meta) == 1 and meta[0].width + 2 + tw(when_t) <= W:
                body.append(right(meta[0], [(when_t, "2")], W))
            else:
                body += meta + [Row(("  " + when_t, "2"))]
            body.append(Row())
            body += self.wrap(m["body"], W - 4, "    ")
            body.append(Row())
            body += self.label_rows("reply", reply_command(m), "1")
            if d.get("thread", True):
                chain, cur = [], m
                while cur["reply_to"] and cur["reply_to"] in byid and len(chain) < THREAD_MAX:
                    cur = byid[cur["reply_to"]]
                    chain.append(cur)
                further = cur["reply_to"] if cur["reply_to"] and len(chain) == THREAD_MAX else None
                replies = [x for x in bus if x["reply_to"] == m["id"]]
                thread = sorted(chain + [m] + replies[:THREAD_MAX], key=lambda x: x["id"])
                related = len(thread) > 1
                body.append(Row())
                n_more = len(replies) - THREAD_MAX
                count = str(len(thread)) if not (further or n_more > 0) else f"{len(thread)} shown"
                body.append(self.title("Thread", count, hint + ["t hides it"] if related else ["t hides it", ""]))
                if further:
                    body.append(self.more_row(f"… #{chain[-1]['id']} replies to #{further} · open #{chain[-1]['id']} "
                                              f"to go further up"))
                body += [self.msg_row(x, sel=sel == ("messages", x["id"]), here=x["id"] == m["id"]) for x in thread]
                if n_more > 0:
                    body.append(self.more_row(f"… {n_more} more replies · agentbus read --since {m['id']}"))
        elif sec == "agents":
            a = next(x for x in self.snap["agents"] if x["name"] == key)
            label = f"agent {a['name']}"
            body += self.pack([[(self.g["off"] if self.idle(a) else self.g["on"],
                                 "2" if self.idle(a) else self.ac(a["name"]))]
                               + ([(" " + role_emoji(a["role"]), "")] if self.E else [])
                               + [(" " + clean(a["name"]), "1")], [(clean(a["role"]), "2")]])
            body += self.wrap(self.tx(f"last seen {self.hhmm(a['last_seen'])}, {self.ago_words(a['last_seen'])}"
                                      f" · joined {self.hhmm(a['joined_at'])}"), W - 2, "  ")
            n = self.snap.get("unread", {}).get(a["name"], 0)
            if n:
                body += self.wrap(self.tx(f"{n} unread · agentbus --as {a['name']} inbox --peek shows them"), W - 2, "  ")
            body.append(Row())
            cl = [c for c in self.snap["claims"] if c["agent"] == a["name"]]
            body.append(self.title("Claims", str(len(cl)), hint if cl else []))
            body += [self.claim_row(c, sel=sel == ("claims", c["resource"])) for c in cl] or [Row(("  nothing claimed", "2"))]
            body.append(Row())
            mine = [m for m in bus if a["name"] in (m["sender"], m["recipient"])]
            last = mine[-LIST_MAX:]
            related = bool(cl or last)
            count = f"{len(last)} of {len(mine)}" + (f" in newest {SCAN}" if scanned else "")
            body.append(self.title("Messages", count, [f"from or to {a['name']}", ""]))
            body += [self.msg_row(m, sel=sel == ("messages", m["id"])) for m in last] or [Row(("  quiet so far", "2"))]
            if len(mine) > len(last):
                body.append(self.more_row(self.older_route(mine[:-LIST_MAX], a["name"])))
        elif sec == "claims":
            c = next(x for x in self.snap["claims"] if x["resource"] == key)
            label = f"claim {c['resource']}"
            claimed = DETAIL["claimed_at"].get(c["resource"])
            body += self.label_rows("claim", c["resource"], "1")
            body += self.agent_line(c["agent"], sel=sel == ("agents", c["agent"]), prefix="held by   ")
            body += self.label_rows("purpose", c["purpose"] or "none given")
            if claimed:
                body += self.label_rows("claimed", f"{self.hhmm(claimed)}, {self.ago_words(claimed)}")
            body += self.label_rows("expires", f"{self.hhmm(c['expires_at'])}, {time_left(c['expires_at'], self.t)} left")
            body.append(Row())
            named = [m for m in bus if c["resource"] in str(m["body"])]  # instr(body, resource), never LIKE
            last = named[-LIST_MAX:]
            related = True
            count = (f"{len(last)} of {len(named)}" if len(named) > len(last) else str(len(named))) + \
                (f" in newest {SCAN}" if scanned else "")
            body.append(self.title("Mentioned in", count, ["messages that name it", ""]))
            body += [self.msg_row(m, sel=sel == ("messages", m["id"])) for m in last] or [Row(("  no message names it", "2"))]
            if len(named) > len(last):
                body.append(self.more_row(self.older_route(named[:-LIST_MAX], c["resource"])))
        else:
            x = next(f for f in self.snap["context"] if f["key"] == key)
            label = f"fact {x['key']}"
            body += self.label_rows("key", x["key"], "1")
            body += self.label_rows("value", x["value"])
            body += self.agent_line(x["updated_by"], sel=sel == ("agents", x["updated_by"]), prefix="set by    ",
                                    extra=f"set {self.hhmm(x['updated_at'])}")
            related = True
            hist = DETAIL["context_history"].get(x["key"], [])
            body.append(Row())
            body.append(self.title("History", str(min(len(hist), THREAD_MAX)) if len(hist) <= THREAD_MAX else
                                   f"{THREAD_MAX} of {len(hist)}", ["newest first", ""]))
            stamps = [self.hhmm(h["updated_at"]) for h in hist[:THREAD_MAX]]
            sw = max([5] + [len(t) for t in stamps])  # HH:MM today, `Nov 2 00:00` on an earlier day
            vw = W - 2 - sw - 2 - 13
            for h, stamp in zip(hist[:THREAD_MAX], stamps):
                lines = wrap_lines(clean(h["value"]), max(1, vw))
                body.append(Row(("  " + stamp.rjust(sw) + "  ", "2"),
                                (self.fit(h["updated_by"], 12), self.ac(h["updated_by"])), (" ", ""), (lines[0], "")))
                body += [Row((" " * (W - vw) + l, "")) for l in lines[1:]]
            if len(hist) > THREAD_MAX:
                body.append(self.more_row(f"… {len(hist) - THREAD_MAX} older · agentbus ctx history {x['key']}"))
        stack = d.get("stack") or []
        back = "back"
        if stack:
            p = stack[-1]
            back = f"back to #{p['key']}" if p["section"] == "messages" else f"back to {p['key']}"
        items = ([("j/k", "select", 60), ("Enter", "open", 55)] if related else [("j/k", "scroll", 60)])
        items.append(("y", "copy", 30))
        if sec == "messages":
            items.append(("t", "thread", 50))
        items += [("Esc/q", back, 95), ("?", "help", 90)]
        footer = self.copied_footer() if self.v["copied"] else self.footer(items)
        return self.page([self.header(label, self.wait()), self.goal_row()] + body, footer)

    def older_route(self, older, word):
        """The way to the rows a detail list leaves out: the filter, when they are all in the view's 200."""
        held = {m["id"] for m in self.snap["messages"]}
        if all(m["id"] in held for m in older):
            return f"… {len(older)} older · /{word} lists them"
        return f"… {len(older)} older · agentbus read"

    def page(self, rows, footer, keep=2):
        """Rows above the footer, scrolled by view.scroll and moved so the selected row shows; rows hidden
        above or below are counted on a dim row."""
        room = self.rows - 1
        head, rest = rows[:keep], rows[keep:]
        avail = room - len(head)
        n = len(rest)
        if n <= avail:
            return self.pad(head + rest, footer)
        si = next((i for i, r in enumerate(rest) if r.sel), None)
        s = max(0, min(self.v["scroll"], n - (avail - 1)))  # never past the page that ends at the last row
        for _ in range(4):
            top = 1 if s else 0
            k = avail - top
            if n - s > k:
                k -= 1
            if si is not None and si >= s + k:
                s = si - k + 1
                continue
            if si is not None and si < s:
                s = si
                continue
            break
        out = head
        if s:
            out = out + [self.more_row(f"… {s} lines above · PgUp")]
        out = out + rest[s:s + k]
        if n - s - k > 0:
            out.append(self.more_row(f"… {n - s - k} more lines · PgDn"))
        return self.pad(out, footer)

    # ------------------------------------------------ help

    def help_frame(self):
        W, E, g = self.W, self.E, self.g
        kw = 16
        move = [(f"j k  {g['down']} {g['up']}", "one row"), ("g G  Home End", "first, last row"),
                ("PgUp PgDn", "one page"), ("Ctrl-u Ctrl-d", "half a page"),
                ("Tab  Shift-Tab", "next, previous section"), ("1 2 3 4", "Agents, Claims, Facts, Messages")]
        look = [("Enter", "open the selected row; in a detail, open the selected related row"),
                ("t", "show or hide the thread of an open message"),
                ("y", "copy the selected id, or in a message its reply command (OSC 52; if paste fails, the "
                      "footer says where it is on screen)"),
                ("/", "filter: from:NAME to:NAME kind:KIND topic:NAME, or any words"),
                ("p", "pause the whole view, or follow again"),
                ("r", "read the bus now"),
                ("Esc  q", "back one level: a detail, the filter or this page; q quits from the overview"),
                ("Ctrl-C", "quit from anywhere")]
        rows = [self.header("keys")]
        rows += self.wrap("watch only reads the bus. It never marks a message read and never changes a claim.",
                          W - 2, "  ")
        # The header and the whole intro stay while the keys scroll, so no sentence is cut, unless the page is so
        # short that pinning them would leave fewer than 3 rows for the keys: then only the header stays.
        pinned = len(rows) if self.rows - 1 - len(rows) - 2 >= 3 else 1
        rows.append(Row())

        def entry(k, d, width, kwid=kw):
            return [Row(("  " + (k if i == 0 else "").ljust(kwid), "1"), (line.text, ""))
                    for i, line in enumerate(self.wrap(self.tx(d), width - 2 - kwid, ""))]
        rows.append(Row(("Move", "1")))
        half = W // 2
        if self.wide and all(len(entry(k, d, half if i % 2 == 0 else W - half)) == 1 for i, (k, d) in enumerate(move)):
            for i in range(0, len(move), 2):  # two entries a row, when each fits its half on one row
                r = Row(*entry(*move[i], half)[0].segs)
                r.add(" " * (half - r.width))
                r.extend(entry(*move[i + 1], W - half)[0])
                rows.append(r)
        else:
            for k, d in move:
                rows += entry(k, d, W)
        rows.append(Row())
        rows.append(Row(("Look closer", "1")))
        for k, d in look:
            rows += entry(k, d, W)
        rows.append(Row())
        rows.append(Row(("Marks", "1")))
        marks = [(g["on"], "seen in the last 5 minutes"), (g["off"], "quiet for 5 minutes or more"),
                 (">", "selected row"), (g["open"], "the record open in a detail"),
                 (g["new"], "new in the last 3 seconds"),
                 ("🎯" if E else g["goal"].strip(), "the team's goal"), (f"{g['reply']}6", "a reply to message 6"),
                 (f"{g['lines']}1", "one more line; Enter shows it")]
        mw = max(tw(m) for m, _ in marks) + 1
        cells = ["  " + gl + " " * (mw - tw(gl)) + d for gl, d in marks]

        def fits(per):  # every row of `per` cells, each but the last padded to W // per, within W
            return all(sum(max(tw(c), W // per) for c in cells[i:i + per][:-1]) + tw(cells[i:i + per][-1]) <= W
                       for i in range(0, len(cells), per))
        per = 3 if W >= 99 else 2 if self.wide else 1
        while per > 1 and not fits(per):
            per -= 1
        cw = W // per
        for i in range(0, len(marks), per):
            r = Row()
            for j, (gl, d) in enumerate(marks[i:i + per]):
                cell = "  " + gl + " " * (mw - tw(gl)) + d
                if j + 1 < per and i + j + 1 < len(marks):
                    cell += " " * (cw - tw(cell))
                r.add(cell)
            rows.append(r)
        rows.append(Row())
        rows.append(Row(("Words", "1")))
        words = [("following", "the newest messages, as they arrive"),
                 ("paused at 16:44", "the whole view is frozen as it was then; +N new counts what came since"),
                 ("… N earlier", "rows above the window; … N later, … N more: rows not shown"),
                 ("N of M", "rows the filter kept, of all there are"),
                 ("of newest 200", "watch holds the newest 200; older ones are not searched (agentbus read)"),
                 ("n/a", "the filter does not apply to this section"),
                 ("open", "no reply yet (alert), no answer yet (question), not done yet (todo)"),
                 ("waiting · 27s old", "the bus is busy; you are looking at the last frame, 27s old"),
                 ("restart for X", "the bus was upgraded; restart watch to run the new code")]
        ww = max(tw(self.tx(k)) for k, _ in words) + 2
        for k, d in words:
            rows += entry(self.tx(k), d, W, ww)
        rows.append(Row())
        rows += self.titled("Kinds", "kind: takes the word or the short code; narrow rows show the code")
        kinds = ["handoff", "question", "answer", "done", "todo", "dropped", "decision", "alert", "note"]
        cells = [((KIND_EMOJI[k] + " ") if E else "") + (f"{KIND_CODE[k]} {k}" if KIND_CODE[k] != k else k)
                 for k in kinds]
        rows += self.flow(cells, [str(KIND_COLOURS.get(k, 2)) for k in kinds])
        if E:
            rows.append(Row())
            rows += self.titled("Roles", "matched on words in the role")
            roles = [("🧠", "brain, lead, planner"), ("✋", "hand, implementer"), ("🧪", "tests"), ("🔍", "review"),
                     ("📚", "docs"), ("🚀", "ops, release"), ("🎨", "design"), ("🙋", "human"), ("🤖", "anyone else")]
            rows += self.flow([f"{e} {d}" for e, d in roles], [""] * len(roles))
        return self.page(rows, self.footer([("j/k", "scroll", 60), ("Esc/q", "back", 95)]), keep=pinned)

    def titled(self, title, note):
        """A help title with a dim note beside it, or wrapped under it when the row is short."""
        if tw(title) + 2 + tw(note) <= self.W:
            return [Row((title, "1"), ("  " + note, "2"))]
        return [Row((title, "1"))] + [Row((r.text, "2")) for r in self.wrap(note, self.W - 2, "  ")]

    def flow(self, cells, sgrs):
        """Cells laid out left to right, three spaces apart, wrapped at the row width."""
        out, row = [], Row(("  ", ""))
        for c, s in zip(cells, sgrs):
            if row.width > 2 and row.width + 3 + tw(c) > self.W:
                out.append(row)
                row = Row(("  ", ""))
            if row.width > 2:
                row.add("   ")
            row.add(c, s)
        out.append(row)
        return out

    # ------------------------------------------------ errors (full screen: refused, newer, no bus)

    def error_frame(self):
        e, W, E = self.v["error"], self.W, self.E
        code = e["code"]
        where = self.where
        label, sgr, icon, head, lines = {
            "schema_refused": ("not readable", "1;31", "🚧", "This bus could not be read, so the sections are not drawn.",
                               [("Run: ", f"agentbus upgrade {where}")]),
            "schema_older": ("not readable", "1;31", "🚧", "This bus could not be read, so the sections are not drawn.",
                             [("Run: ", f"agentbus upgrade {where}")]),
            "schema_newer": ("not readable", "1;31", "🚧", "This bus is newer than this watch, so the sections are not drawn.",
                             [("", f"This watch is agentbus {e.get('version', '0.2.0')}; the bus needs a newer one."),
                              ("Run: ", f"agentbus upgrade {where} from a newer install")]),
            "no_bus": ("no bus", "1;31", "", "There is no bus here any more, so the sections are not drawn.",
                       [("Run: ", f"agentbus init {where}")]),
        }[code]
        rows = [self.header(label), Row()]
        lead = "  " + (icon + " " if E and icon else "")
        for i, r in enumerate(self.wrap(head, W - tw(lead), "")):
            rows.append(Row(((lead if i == 0 else " " * tw(lead)), sgr if i == 0 else ""), (r.text, sgr)))
        ind = " " * tw(lead)
        rows += self.wrap(e["message"], W - tw(ind), ind)  # the reason: normal intensity, it is the diagnosis
        for pre, cmd in lines:
            for i, r in enumerate(self.wrap(pre + cmd, W - tw(ind), "")):
                t = r.text
                if i == 0 and pre:
                    rows.append(Row((ind + pre, ""), (t[len(pre):], "1")))
                else:
                    rows.append(Row((ind + t, "1" if pre else "")))
        rows.append(Row())
        last = "none" if e["last_good_s"] is None else f"{e['last_good_s']}s ago"
        rows += self.wrap(f"Retrying every {e['retry_s']}s. Last good frame: {last}. Your place (filter, selection, "
                          "pause, open detail) comes back with the bus.", W - tw(ind), ind)
        return self.page(rows, self.footer([("r", "retry now", 80), ("?", "help", 90), ("q", "quit", 100)]))


def reply_command(m):
    """The command that replies to m, shown in its detail and copied by y. NAME is $AGENTBUS_AGENT when set."""
    to = clean(m["sender"])
    kind = " --kind answer" if m["kind"] == "question" else ""
    return f"agentbus --as NAME post --to {to} --reply-to {m['id']}{kind} \"...\""


# ---------------------------------------------------------------- goldens, fixture, doc, html

EXTRA_SIZES = ("overview", "section-focus", "message-detail", "help", "error-refused")


def sizes_for(st):
    if st["ascii"]:
        return [(100, 30, False), (60, 20, False), (80, 24, False), (40, 16, False)]
    sizes = [(100, 30, False), (60, 20, False), (100, 30, True), (60, 20, True), (80, 24, False)]
    if st["name"] in EXTRA_SIZES:
        sizes += [(40, 16, False), (60, 24, False), (120, 40, False)]
    return sizes


def make_frame(st, cols, rows, emoji):
    snap = st["snap"]
    return Frame(cols, rows, emoji, st["view"], SNAPSHOTS[snap], WHERE, when(SNAP_T[snap]), live=st["live"],
                 held=SNAPSHOTS[st["held"]] if st["held"] else None, ascii=st["ascii"])


def entry(st, cols, rows, emoji, name=None):
    if not st["live"]:
        rows = len(make_frame(st, cols, 999, emoji).render())
    return {"name": name or f"{st['name']}-{cols}x{rows}" + ("-emoji" if emoji else ""), "state": st["name"],
            "cols": cols, "rows": rows, "emoji": emoji, "ascii": st["ascii"], "live": st["live"],
            "snapshot": st["snap"], "held": st["held"], "t_now": SNAP_T[st["snap"]], "where": WHERE,
            "view": dict(DEFAULT_VIEW, **st["view"])}


def entries():
    """Every golden: the owner's sizes (100x30, 60x20, with and without emoji), the runbook's 80x24 for
    every state, 40x16, 60x24 and 120x40 for the five states the runbook names, ASCII states without
    emoji at 100x30, 60x20, 80x24 and 40x16, and the extra single frames."""
    out = []
    for st in STATES:
        for cols, rows, emoji in sizes_for(st):
            out.append(entry(st, cols, rows, emoji))
    for name, st, cols, rows in EXTRA:
        out.append(entry(st, cols, rows, False, name=name))
    return out


def frame_for(e):
    st = {"name": e["state"], "view": e["view"], "snap": e["snapshot"], "live": e["live"], "held": e["held"],
          "ascii": e["ascii"]}
    snap = SNAPSHOTS[e["snapshot"]]
    return Frame(e["cols"], e["rows"], e["emoji"], e["view"], snap, e["where"], when(e["t_now"]), live=e["live"],
                 held=SNAPSHOTS[st["held"]] if st["held"] else None, ascii=e["ascii"]).render()


def golden_text(rows):
    return "".join(r.text.rstrip() + "\n" for r in rows)


def fixture():
    return {
        "about": "Sample buses and per-golden render inputs for tests/golden/watch (issue #7, revision 2). Generated "
                 "by docs/design/watch_v2_mock.py; edit there and regenerate. Times are UTC and the goldens are "
                 "rendered with TZ=UTC, colour off. A paused entry renders its `held` snapshot as of view.frozen.t_now "
                 "and counts +N new from `snapshot`. Detail queries read detail.messages up to the snapshot's "
                 "newest id.",
        "kinds": list(KINDS),
        "kind_codes": KIND_CODE,
        "limits": {"held": HELD, "scan": SCAN, "thread": THREAD_MAX, "list": LIST_MAX, "lock_wait_ms": LOCK_WAIT_MS},
        "snapshots": SNAPSHOTS,
        "detail": DETAIL,
        "goldens": entries(),
    }


SGR_CSS = {"1": "b", "2": "d", "7": "rv", "31": "c31", "32": "c32", "33": "c33", "34": "c34", "35": "c35",
           "36": "c36", "94": "c94", "95": "c95", "96": "c96", "30": "c30", "43": "bg43", "40": "bg40"}


def css_for(sgr):
    return " ".join(SGR_CSS[x] for x in sgr.split(";") if x in SGR_CSS)


def html_row(row, cols):
    def cell(text):
        out = []
        for c in text:
            w = tw(c)
            if ord(c) < 128:
                out.append(html.escape(c))
            else:
                out.append(f'<i class="w{w}">{html.escape(c)}</i>')
        return "".join(out)
    parts = []
    for text, sgr in row.segs:
        cls = css_for(sgr) if sgr and not row.sel else ""
        parts.append(f'<span class="{cls}">{cell(text)}</span>' if cls else cell(text))
    pad = cols - row.width
    if row.segs and row.segs[0][1] in (HEADER_SGR, HEADER_PLAIN):
        parts.append(f'<span class="{css_for(row.segs[0][1])}">{" " * max(0, pad)}</span>')
        pad = 0
    if row.sel:
        inner = "".join(parts) + " " * max(0, pad - 1)
        return f'<span class="rv">{inner}</span>'
    return "".join(parts)


def frame_block(st, cols, rows, emoji):
    """A ```text block for the doc: label line, then the rows with trailing blank rows elided."""
    fr = make_frame(st, cols, rows if st["live"] else 999, emoji).render()
    lines = [r.text.rstrip() for r in fr]
    while lines and not lines[-1]:
        lines.pop()
    label_rows = len(fr) if st["live"] else len(lines)
    tag = st["name"] + ("" if emoji or st["ascii"] else "-noemoji")
    return f"```text\n[frame {tag} {cols}x{label_rows}]\n" + "\n".join(lines) + "\n```\n"


def doc_variants(st):
    return [(c, r, e) for c, r in ((100, 30), (60, 20)) for e in ((False,) if st["ascii"] else (True, False))]


def doc_states():
    out = []
    for st in STATES:
        out.append(f"### {st['title']}\n\n{st['blurb']}\n")
        out += [frame_block(st, c, r, e) for c, r, e in doc_variants(st)]
    out.append("### Short sections at 40x16\n\nA section cut to one row still shows its selected row, and its title "
               "says how many rows are hidden (never `0 more`). Left: Facts focused with `runtime` selected. Right: "
               "Agents focused with `tests` selected.\n")
    for name, st, cols, rows in EXTRA[:2]:
        out.append(frame_block(dict(st, name=name.rsplit("-", 1)[0]), cols, rows, False))
    out.append("### Under 40 columns\n\nv0.1.0's one line, kept.\n")
    fr = Frame(39, 8, False, {}, SAMPLE, WHERE, when(T_NOW)).render()
    out.append("```text\n[frame too-narrow 39x8]\n" + fr[0].text.rstrip() + "\n```\n")
    return "\n".join(out)


def fill_doc(text):
    return re.sub(r"<!-- BEGIN states -->.*?<!-- END states -->",
                  lambda m: "<!-- BEGIN states -->\n" + doc_states() + "<!-- END states -->", text, flags=re.S)


CSS = """
:root { --bg:#17151f; --panel:#1f1c2b; --fg:#e8e3d6; --dim:#8f8a9e; --line:#35304a; }
* { box-sizing: border-box; }
body { margin:0; background:#0f0d16; color:var(--fg); font:15px/1.5 -apple-system, "Segoe UI", sans-serif; }
header.top { padding:28px 32px 8px; max-width:1500px; margin:auto; }
h1 { margin:0 0 4px; font-size:26px; } h1 .bus { background:#ffd166; color:#1a1626; padding:0 8px; border-radius:6px; }
h2 { margin:40px 0 4px; font-size:20px; border-top:1px solid var(--line); padding-top:24px; }
p.blurb, header.top p { color:#cfc8b8; max-width:980px; margin:6px 0 14px; }
main { max-width:1500px; margin:auto; padding:0 32px 60px; }
.toggles { position:sticky; top:0; z-index:5; background:#0f0d16ee; padding:10px 32px; border-bottom:1px solid var(--line); }
.toggles label { margin-right:22px; cursor:pointer; color:#cfc8b8; }
.row { display:flex; flex-wrap:wrap; gap:18px; align-items:flex-start; }
figure { margin:0; }
figcaption { color:var(--dim); font:12px ui-monospace, Menlo, monospace; margin:0 0 6px; }
pre.term { margin:0; padding:10px 12px 12px; background:var(--bg); border:1px solid var(--line); border-radius:10px;
  box-shadow: 0 6px 24px #0008; font:13px/1.32 ui-monospace, "SF Mono", Menlo, Consolas, monospace; color:var(--fg);
  white-space:pre; overflow-x:auto; }
pre.term .dots { display:block; margin:-2px 0 8px; height:10px; }
pre.term .dots b { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:6px; background:#ff6b6b; }
pre.term .dots b+b { background:#ffd166; } pre.term .dots b+b+b { background:#7bd88f; }
i { font-style:normal; display:inline-block; text-align:center; overflow:visible; }
i.w1 { width:1ch; } i.w2 { width:2ch; } i.w0 { width:0; }
.b { font-weight:700; } .d { color:var(--dim); }
.rv { background:var(--fg); color:var(--bg) !important; }
.rv * { color:var(--bg) !important; }
.c30 { color:#1a1626 !important; } .bg43 { background:#ffd166; } .bg40 { background:#000; }
.c31 { color:#ff6b6b; } .c32 { color:#7bd88f; } .c33 { color:#ffd166; } .c34 { color:#6cb6ff; }
.c35 { color:#d38cff; } .c36 { color:#5ee0e0; } .c94 { color:#9ec9ff; } .c95 { color:#f0a6ff; } .c96 { color:#9ef0f0; }
#nocolor:checked ~ main pre.term span { color:var(--fg) !important; background:none !important; font-weight:normal; }
#nocolor:checked ~ main pre.term span * { color:var(--fg) !important; }
.toggles label::before { content:"\2610  "; }
#nocolor:checked ~ .toggles label[for=nocolor]::before, #noemoji:checked ~ .toggles label[for=noemoji]::before,
#emojionly:checked ~ .toggles label[for=emojionly]::before, #hidesmall:checked ~ .toggles label[for=hidesmall]::before,
#hidelarge:checked ~ .toggles label[for=hidelarge]::before { content:"\2611  "; }
ol.decisions li { margin:6px 0; max-width:1000px; }
table.rev td:first-child { white-space:nowrap; }
#noemoji:checked ~ main .emoji-on { display:none; } #emojionly:checked ~ main .emoji-off { display:none; }
#hidesmall:checked ~ main .s60 { display:none; } #hidelarge:checked ~ main .s100 { display:none; }
table.keys { border-collapse:collapse; margin:10px 0; font-size:14px; }
table.keys td, table.keys th { border:1px solid var(--line); padding:4px 10px; text-align:left; vertical-align:top; }
table.keys th { background:var(--panel); } code { font-family:ui-monospace, Menlo, monospace; color:#ffd166; }
.sw { display:inline-block; padding:2px 10px; margin:2px; border-radius:4px; background:var(--bg); border:1px solid var(--line);
  font:13px ui-monospace, Menlo, monospace; }
"""


def build_html():
    def md_inline(s):
        s = html.escape(s.replace("\\|", "|"))
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)

    def md_table(block, cls):
        trs = [l for l in block.splitlines() if l.startswith("|") and not l.startswith("|---")]
        cells = [[md_inline(c.strip()) for c in l.strip().strip("|").split(" | ")] for l in trs]
        return (f"<table class='keys {cls}'><tr>" + "".join(f"<th>{c}</th>" for c in cells[0]) + "</tr>"
                + "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in cells[1:]) + "</table>")

    def section(doc, head):
        return doc.split(f"\n## {head}\n", 1)[1].split("\n## ", 1)[0]
    parts = ["<!doctype html><html lang=en><head><meta charset=utf-8>",
             "<meta name=viewport content='width=device-width, initial-scale=1'>",
             "<title>agentbus watch v2: the frames</title><style>" + CSS + "</style></head><body>",
             "<header class=top><h1><span class=bus>🚌 agentbus</span> watch v2: every frame</h1>",
             "<p>The proposal for issue #7, revision 2, for the owner's sign-off. Each state is drawn at 100x30 and "
             "60x20, with emoji and without (ASCII states without). Colours are the frames' own SGR codes on a dark "
             "terminal. Tick NO_COLOR to see exactly what a no-colour terminal shows: the same text, with nothing "
             "lost. Generated by <code>docs/design/watch_v2_mock.py</code> from the same data as the golden files; "
             "the text is in <code>docs/design/watch-v2.md</code>.</p></header>",
             "<input type=checkbox id=nocolor hidden><input type=checkbox id=noemoji hidden>"
             "<input type=checkbox id=emojionly hidden><input type=checkbox id=hidesmall hidden>"
             "<input type=checkbox id=hidelarge hidden>",
             "<div class=toggles><label for=nocolor>NO_COLOR</label><label for=noemoji>hide emoji frames</label>"
             "<label for=emojionly>hide no-emoji frames</label><label for=hidesmall>hide 60x20</label>"
             "<label for=hidelarge>hide 100x30</label></div>",
             "<main>"]
    doc = DOC.read_text()
    parts.append("<h2 id=revision-2>Revision 2: what changed after the two reviews</h2><p class=blurb>Every finding "
                 "of wd-opus and wd-astra, and the brain's rulings, with what was done. The build rules are in "
                 "<code>docs/design/watch-v2-build-addendum.md</code>.</p>"
                 + md_table(section(doc, "Revision 2"), "rev"))
    dec = section(doc, "Decisions for the owner")
    items = [md_inline(l.split(". ", 1)[1]) for l in dec.splitlines() if re.match(r"^\d+\. ", l)]
    parts.append("<h2>Decisions for the owner</h2><p class=blurb>One at a time, recommended answer first.</p>"
                 "<ol class=decisions>" + "".join(f"<li>{i}</li>" for i in items) + "</ol>")
    parts.append("<h2>Key map</h2>" + md_table(section(doc, "3. Key map"), ""))
    parts.append("<h2>Colours</h2><p class=blurb>Every meaning is also in the text, so NO_COLOR loses nothing.</p><div>")
    for label, cls in (("header bar 30;43", "c30 bg43"), ("header, ASCII or TERM=linux 1;7", "b rv"),
                       ("waiting on the bar 33;40", "c33 bg40"), ("section title 1", "b"), ("secondary 2", "d"),
                       ("goal mark 1;33", "b c33"), ("selected row 7", "rv"), ("alert, error 31", "c31"),
                       ("paused, stale 33", "c33"), ("handoff 33", "c33"), ("question 35", "c35"),
                       ("answer 36", "c36"), ("done 32", "c32"), ("decision 34", "c34"),
                       ("agents 34 36 35 32 33 94 96 95", "c34")):
        parts.append(f"<span class=sw><span class='{cls}'>{html.escape(label)}</span></span>")
    parts.append("</div>")

    def figure(fr, cols, cls, cap):
        body = "\n".join(html_row(r, cols - 1) for r in fr)
        return (f"<figure class='{cls}'><figcaption>{cap}</figcaption>"
                f"<pre class=term><span class=dots><b></b><b></b><b></b></span>{body}</pre></figure>")
    for st in STATES:
        parts.append(f"<h2 id='{st['name']}'>{md_inline(st['title'])} <code>{st['name']}</code></h2>"
                     f"<p class=blurb>{md_inline(st['blurb'])}</p>")
        for cols, rows in ((100, 30), (60, 20)):
            parts.append("<div class=row>")
            for emoji in ((False,) if st["ascii"] else (True, False)):
                fr = make_frame(st, cols, rows if st["live"] else 999, emoji).render()
                if not st["live"]:
                    while fr and not fr[-1].text.strip():
                        fr.pop()
                cls = ("emoji-on" if emoji else "emoji-off") + (" s100" if cols == 100 else " s60")
                cap = f"{st['name']} {cols}x{len(fr)} {'emoji' if emoji else 'ASCII' if st['ascii'] else 'no emoji'}"
                parts.append(figure(fr, cols, cls, cap))
            parts.append("</div>")
    parts.append("<h2 id=short>Short sections at 40x16</h2><div class=row>")
    for name, st, cols, rows in EXTRA[:2]:
        parts.append(figure(make_frame(st, cols, rows, False).render(), cols, "", name))
    parts.append("</div>")
    fr = Frame(39, 8, False, {}, SAMPLE, WHERE, when(T_NOW)).render()
    parts.append("<h2 id=too-narrow>Under 40 columns <code>too-narrow</code></h2><div class=row>"
                 + figure(fr, 39, "", "too-narrow 39x8") + "</div>")
    parts.append("</main></body></html>\n")
    return "".join(parts)


# ---------------------------------------------------------------- behaviour cases
# The reviewers' cheapest falsifying tests and the rules of revision 2, as cases. "mock" cases run here
# (python3 docs/design/watch_v2_mock.py --behaviour) and 06 ports them to bin/agentbus's render; "06" cases
# need the live loop (a pty, a held lock, a clock) and are 06's to write. behaviour.json lists all of them.


def text_of(cols, rows, view, snap="sample", held=None, ascii=False, emoji=False, live=True, snapshot=None):
    s = snapshot or SNAPSHOTS[snap]
    fr = Frame(cols, rows, emoji, view, s, WHERE, when(SNAP_T.get(snap, T_NOW)), live=live,
               held=SNAPSHOTS[held] if held else None, ascii=ascii).render()
    return [r.text.rstrip() for r in fr]


def ids_in(lines):
    return [int(m.group(1)) for l in lines for m in [re.match(r"^[ >*▌|] #(\d+)", l)] if m]


SIZES = [(40, 16), (60, 20), (60, 24), (80, 24), (100, 30)]


def case_pause_rollover():
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


def case_selection_never_hidden():
    for c, r in SIZES:
        for emoji in (False, True):
            for sec, keyname, items in (("agents", "name", AGENTS), ("claims", "resource", CLAIMS),
                                        ("facts", "key", CONTEXT), ("messages", "id", SAMPLE_MSGS)):
                for it in items:
                    v = {"focus": sec, "sel": {sec: it[keyname]}}
                    if sec == "messages":
                        v.update(paused=True, frozen=FROZEN)
                    t = text_of(c, r, v, held="sample" if sec == "messages" else None, emoji=emoji)
                    sel = [l for l in t if l.startswith(">")]
                    assert len(sel) == 1, (c, r, sec, it[keyname], t)
                    assert not any(re.search(r"(…|\.\.\.) 0 (more|earlier|later)", l) for l in t), (c, r, sec, t)


def case_kind_codes():
    def msgs(f):
        return ids_in(text_of(100, 30, {"filter": f}))
    assert msgs("kind:ask") == msgs("kind:question") == [6, 9]
    assert msgs("kind:ALRT") == msgs("kind:alert") == [3]
    assert msgs("kind:hand") == msgs("kind:handoff") == [2, 8]
    assert msgs("kind:dec") == [4] and msgs("kind:ans") == [7]
    t = text_of(100, 30, {"filter": "kind:fyi"})
    assert KIND_ERROR == ("kind must be one of: note, question (ask), answer (ans), handoff (hand), decision (dec), "
                          "alert (ALRT), done, todo, dropped (drop)")
    assert any("kind must be one of" in l for l in t), "the error stays after Enter"


def case_filter_coverage():
    t = text_of(100, 30, {"filter": "kind:alert"}, snap="big")
    assert any(l.startswith("Messages  0 of newest 200") for l in t), t
    assert any("9 older not searched · agentbus read" in l for l in t), t
    assert any(l.startswith("Agents  n/a") for l in t) and any(l.startswith("Facts  n/a") for l in t), t
    assert t[0].endswith("1 alert · 0 open questions"), t[0]  # the whole bus: #3 is still open, #6 and #9 are answered
    t = text_of(100, 30, {"filter": "topic:ci"})
    assert ids_in(t) == [3] and any(l.startswith("Claims  n/a") for l in t), t
    t = text_of(100, 30, {"filter": "everyone"})
    assert ids_in(t) == [1, 3], "a broadcast matches the word it is shown as"
    assert ids_in(text_of(60, 20, {"filter": "to:all"})) == [1, 3]


def case_long_input():
    long = "from:tests " + "x" * 69
    for c, r in ((60, 20), (40, 16), (100, 30)):
        t = text_of(c, r, {"filter": long})
        assert len(t[-1]) <= c - 1 and all(k in t[-1] for k in ("Esc clear", "? help", "q quit")), t[-1]
        t = text_of(c, r, {"filter": long, "mode": "filter", "filter_input": True})
        assert tw(t[-1]) <= c - 1 and "_" in t[-1] and "Esc clear" in t[-1] and t[-1].startswith("/…"), t[-1]


def case_detail_wraps():
    m = msg(123456, at("16:40"), "s" * 16, "r" * 16, "question", "short", reply=654321)
    snap = dict(SAMPLE, messages=[m], counts=dict(SAMPLE["counts"], messages=1))
    for c in (40, 60):
        t = text_of(c, 20, {"mode": "detail", "detail": {"section": "messages", "key": 123456}}, snapshot=snap)
        assert all(tw(l) <= c - 1 for l in t), t
        assert any("s" * 16 in l for l in t) and any("r" * 16 in l for l in t) and any("#123456" in l for l in t), t
    res = "src/" + "/".join(f"module{i:02d}" for i in range(10)) + "/a_very_long_file_name_that_keeps_going.py"
    res = res[:93]
    snap = dict(SAMPLE, claims=[{"resource": res, "agent": "codex", "purpose": None, "expires_at": at("18:43")}])
    t = text_of(60, 20, {"mode": "detail", "focus": "claims", "detail": {"section": "claims", "key": res}}, snapshot=snap)
    i = next(i for i, l in enumerate(t) if l.startswith("  claim     "))
    got = t[i][12:]
    for l in t[i + 1:]:
        if not l.startswith(" " * 12):
            break
        got += l[12:]
    assert got == res and len(res) == 93, (got, res)


def case_thread_limits():
    ms = [msg(1, at("10:00"), "a", "b", "note", "root")]
    ms += [msg(i, at("10:00"), "a", "b", "note", f"step {i}", reply=i - 1) for i in range(2, 27)]
    ms += [msg(i, at("10:00"), "b", "a", "answer", f"reply {i}", reply=26) for i in range(27, 52)]
    snap = dict(SAMPLE, messages=ms, counts=dict(SAMPLE["counts"], messages=len(ms)))
    t = text_of(100, 80, {"mode": "detail", "detail": {"section": "messages", "key": 26}}, snapshot=snap)
    assert any(l.startswith("Thread  41 shown") for l in t), t
    assert any("… #6 replies to #5 · open #6 to go further up" in l for l in t), t
    assert any("… 5 more replies · agentbus read --since 26" in l for l in t), t


def case_wrap_linear():
    # Deterministic: count the cells the wrapper measures (every cell_width call, direct or through
    # text_width) for one unbroken word at 1x and 2x. Linear wrapping visits each cell a bounded number of
    # times, so twice the text is about twice the work; quadratic wrapping would be about four times.
    g = tw.__globals__  # bin/agentbus's own module, whose cell_width text_width calls
    real, seen = g["cell_width"], [0]

    def counted(c):
        seen[0] += 1
        return real(c)

    def work(n):
        seen[0] = 0
        g["cell_width"] = counted
        try:
            wrap_lines.__wrapped__("w" * n, 57)
        finally:
            g["cell_width"] = real
        return seen[0]
    one = work(4000)  # checked before the 2x run, so quadratic wrapping fails fast
    assert 4000 <= one <= 4 * 4000, f"wrapping measured {one} cells for 4000 characters"
    two = work(8000)
    assert two <= 2.1 * one, f"wrapping is not linear: 2x text measured {two / one:.2f}x the cells"
    assert wrap_lines("a b", 5) is wrap_lines("a b", 5), "wrapping is cached by text and width"


def case_busy_keeps_frame():
    base = {"focus": "claims", "sel": {"claims": "src/auth/"}}
    for c, r in SIZES:
        a, b = text_of(c, r, base), text_of(c, r, dict(base, error=BUSY))
        assert a[1:] == b[1:] and "waiting · 27s old" in b[0], (c, r, b[0])
    t = text_of(60, 20, {"mode": "detail", "detail": {"section": "messages", "key": 7}, "error": BUSY})
    assert "waiting · 27s old" in t[0] and any("Thread" in l for l in t)


def case_claim_holder():
    t = text_of(100, 30, STATE["claim-detail"]["view"])
    holder = next(l for l in t if "held by" in l)
    assert "○ codex · implementer · seen 6m ago" in holder, holder


def case_ascii():
    for st in STATES:
        if st["ascii"]:
            for c, r, _ in sizes_for(st):
                for l in make_frame(st, c, r, False).render():
                    assert all(ord(ch) < 128 for ch in l.text), (st["name"], l.text)


def case_summary_and_agents():
    t = text_of(100, 30, {})
    assert t[0].endswith("1 alert · 1 open question"), t[0]
    assert text_of(60, 20, {})[0].endswith("1 ALRT · 1 ask")
    three = dict(SAMPLE, open=dict(SAMPLE["open"], todos=2))
    assert text_of(100, 30, {}, snapshot=three)[0].endswith("1 alert · 1 open question · 2 open todos"), "open todos in the header"
    assert text_of(60, 20, {}, snapshot=three)[0].endswith("1 ALRT · 1 ask · 2 todo")
    assert "open todo" not in t[0], "a zero todo count is shown"
    huge = dict(SAMPLE, open=dict(SAMPLE["open"], window=5000))
    assert "newest 5000: 1 alert" in text_of(100, 30, {}, snapshot=huge)[0], "a window is labelled"
    assert any("2 unread · holds src/auth/" in l for l in t), t
    assert t[-1].startswith("  k browse") and any(l.startswith("Messages  9") and "following · k to browse" in l
                                                  for l in t)


def case_detail_marks():
    t = text_of(100, 30, STATE["message-detail"]["view"])
    assert any(l.startswith("* #7") for l in t) and not any(l.startswith(">") for l in t), t
    t = text_of(100, 30, {"mode": "detail", "detail": {"section": "messages", "key": 9}})
    assert any('agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."' in l for l in t), t
    assert "Esc/q back" in t[-1] and "q quit" not in t[-1], t[-1]
    t = text_of(100, 30, STATE["detail-nav"]["view"], snap="big")
    assert any(l.startswith("> #9") for l in t) and any(l.startswith("* #10") for l in t), t
    t = text_of(100, 30, STATE["detail-nested"]["view"], snap="big")
    assert "back to #10" in t[-1], t[-1]


def case_help_pages():
    # Every page of help (scrolled from the top to past the end), 40 to 80 columns, three heights, every glyph
    # mode: each row within the width, the frame its height.
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


def case_no_zero_more():
    # No "… 0 more", "0 earlier" or "0 later" at any size, with or without a filter, whatever has the focus,
    # also on a bus where a section has one row (the one-row and no-row branches).
    one_fact = dict(SAMPLE, context=CONTEXT[:1])
    for snap in (SAMPLE, one_fact):
        for cols in (40, 47, 60, 80, 100):
            for rows in range(6, 31, 2):
                for f in ("", "x", "kind:ask", "from:c", "auth"):
                    for focus in ("agents", "claims", "facts", "messages"):
                        t = text_of(cols, rows, {"filter": f, "focus": focus}, snapshot=snap)
                        assert len(t) == rows, (cols, rows, f, focus, len(t))
                        bad = [l for l in t if re.search(r"(…|\.\.\.) 0 (more|earlier|later)", l)]
                        assert not bad and all(tw(l) <= cols - 1 for l in t), (cols, rows, f, focus, bad or t)


def case_mentions_instr():
    snap = dict(SAMPLE, claims=[{"resource": "src/my_mod/", "agent": "codex", "purpose": None, "expires_at": at("18:43")}],
                messages=[msg(1, at("16:00"), "a", "b", "note", "edited src/myXmod/ today")],
                counts=dict(SAMPLE["counts"], messages=1))
    t = text_of(100, 30, {"mode": "detail", "focus": "claims", "detail": {"section": "claims", "key": "src/my_mod/"}},
                snapshot=snap)
    assert any("no message names it" in l for l in t), "a _ in a resource is a character, not a wildcard"


MOCK_CASES = [
    ("pause-rollover", "astra 1; brain 2", case_pause_rollover,
     "Paused on #9, a snapshot of #10-#209 arrives: #9 stays selected and visible, the title says +200 new, at 40x16 "
     "to 100x30; a filter while paused searches the frozen records; resume shows the newest."),
    ("selection-never-hidden", "opus 1; brain 4", case_selection_never_hidden,
     "Every row of every section selected at 40x16 to 100x30, with and without emoji: exactly one > row, and no "
     "'0 more', '0 earlier' or '0 later'."),
    ("kind-codes", "opus 3; brain 7", case_kind_codes,
     "kind:ask equals kind:question, kind:ALRT equals kind:alert; the error lists the codes and stays after Enter."),
    ("filter-coverage", "opus 2, 14, 15; astra 2; brain 3", case_filter_coverage,
     "kind:alert on 209 messages: 0 of newest 200, 9 older not searched, n/a for the other sections; topic:, "
     "everyone and to:all."),
    ("long-input", "astra 3", case_long_input,
     "An 80-character filter, kept and typed, at 40, 60 and 100 columns: the footer fits and keeps Esc clear, ? help, "
     "q quit; the input scrolls to its cursor."),
    ("detail-wraps", "astra 3, 4; brain 5", case_detail_wraps,
     "16-character names and six-digit ids wrap by field at 40 and 60 columns; a 93-character resource is whole."),
    ("thread-limits", "astra 4; brain 5", case_thread_limits,
     "A message with 25 ancestors and 25 replies: 20 of each, labelled, with the route to the rest."),
    ("wrap-linear", "astra 6; brain 9", case_wrap_linear,
     "Wrapping twice the text (one unbroken word) measures at most 2.1 times the cells (counted, not timed), and is "
     "cached by text and width."),
    ("busy-keeps-frame", "opus 4; brain 6", case_busy_keeps_frame,
     "Busy: every row but the header equals the frame before, the header says waiting · 27s old; also in a detail."),
    ("claim-holder-idle", "opus 5; astra 5", case_claim_holder,
     "Claim detail shows the holder's real activity dot: ○ codex · implementer · seen 6m ago."),
    ("ascii-only", "opus 9; astra 7; brain 8", case_ascii,
     "Every ASCII-mode frame is pure ASCII (so ambiguous-width settings cannot move a column)."),
    ("summary-and-agents", "opus 6, 13; brain 1", case_summary_and_agents,
     "The header says 1 alert · 1 open question (1 ALRT · 1 ask narrow); agents show 2 unread · holds src/auth/; "
     "following says k browse."),
    ("detail-marks", "opus 7, 17; astra 4; brain 5, Missing", case_detail_marks,
     "The open message is marked *, nothing is selected on open, the reply command shows, Esc/q back replaces "
     "q quit, an ancestor outside the 200 can be selected, and a nested detail says where back goes."),
    ("help-pages", "w2-06 review M4", case_help_pages,
     "Every page of help, 40 to 80 columns, three heights, Unicode, emoji and ASCII: every row within the width, "
     "and the intro whole."),
    ("no-zero-more", "w2-06 review L1", case_no_zero_more,
     "No 0 more, 0 earlier or 0 later at 40 to 100 columns and 6 to 30 rows, with five filters and every focus, "
     "also when a section has one row."),
    ("mentions-instr", "opus 12; brain 9", case_mentions_instr,
     "A resource with _ matches only itself (instr, not LIKE)."),
]
BUILD_CASES = [
    ("busy-q-under-250ms", "opus 4; brain 6",
     "Another process holds an EXCLUSIVE lock on bus.db; q in a running watch exits in under 250 ms + 100 ms "
     "slack, with termios restored; the frame before the lock stays on screen with waiting · Ns old."),
    ("input-never-waits-on-sql", "astra 6; brain 9",
     "While a read is blocked on the lock, 20 keys each redraw in under 100 ms (the read runs off the input loop)."),
    ("detail-queries-on-open-and-r", "opus 12; brain 9",
     "With a detail open for 5 ticks, watch_detail runs once; r runs it once more."),
    ("scan-bounded", "opus 12; astra 6; brain 9",
     "On a 20000-message bus every detail query reads at most the newest 5000 (EXPLAIN QUERY PLAN uses the id "
     "range) and the lists say in newest 5000."),
    ("esc-and-q-back-one-level", "opus 7, 8; brain 5",
     "Overview, Enter on #7, j, Enter on #9: Esc shows #7, q shows the overview byte for byte, q quits."),
    ("pause-freezes-display", "astra 7; brain 2",
     "Paused for 10 ticks while messages arrive: no row changes but the +N new title; ages do not tick."),
    ("pause-rollover-pty", "astra 1",
     "The pause-rollover case through a pty: pause on #9, post 200 messages, #9 still selected; resize keeps it."),
    ("view-survives-errors", "opus 4; brain 6",
     "Filter, select, pause, open a detail; refuse the bus, then repair it: the same frame comes back."),
    ("copy-osc52", "opus Missing; brain 1",
     "y on #9 in detail writes ESC ] 52 ; c ; base64(reply command) BEL and the copied footer; nothing in bus.db "
     "changes."),
    ("ascii-auto", "opus 9; brain 8",
     "TERM=linux and AGENTBUS_ASCII=1 each give the ascii goldens; a terminal that reports ● two columns wide "
     "(cursor position probe at start) does too."),
    ("header-sgr", "opus 10; brain 8",
     "The header bar is SGR 30;43 (no 1), and 7 under TERM=linux or AGENTBUS_ASCII; the error reason has no SGR 2."),
]


def behaviour_doc():
    return {"about": "Behaviour cases for watch v2 (issue #7 revision 2). 'mock' cases run in "
                     "docs/design/watch_v2_mock.py --behaviour and 06 ports them to bin/agentbus; '06' cases need the "
                     "live loop and are 06's to write in tests/test_watch_keys.sh.",
            "cases": [{"name": n, "from": f, "runs": "mock", "checks": d} for n, f, _, d in MOCK_CASES]
            + [{"name": n, "from": f, "runs": "06", "checks": d} for n, f, d in BUILD_CASES]}


def run_behaviour():
    bad = 0
    for name, _, fn, _ in MOCK_CASES:
        try:
            fn()
            print(f"ok   {name}")
        except AssertionError as e:
            bad += 1
            print(f"FAIL {name}: {str(e)[:600]}")
    if bad:
        print(f"{bad} of {len(MOCK_CASES)} behaviour cases failed")
        sys.exit(1)
    print(f"{len(MOCK_CASES)} behaviour cases passed; {len(BUILD_CASES)} more are 06's")


def artifacts():
    files = {}
    fx = fixture()
    files[GOLDEN / "fixture.json"] = json.dumps(fx, indent=1, ensure_ascii=False) + "\n"
    files[GOLDEN / "behaviour.json"] = json.dumps(behaviour_doc(), indent=1, ensure_ascii=False) + "\n"
    for e in fx["goldens"]:
        files[GOLDEN / (e["name"] + ".txt")] = golden_text(frame_for(e))
    files[DOC] = fill_doc(DOC.read_text())
    files[HTML_OUT] = build_html()
    return files


def main():
    if "--behaviour" in sys.argv[1:]:
        return run_behaviour()
    check = "--check" in sys.argv[1:]
    stale = []
    files = artifacts()
    for path, text in files.items():
        if path.exists() and path.read_text() == text:
            continue
        stale.append(path)
        if not check:
            path.write_text(text)
    names = {p.name for p in files if p.parent == GOLDEN}
    for p in GOLDEN.glob("*.txt"):
        if p.name not in names:
            stale.append(p)
            if not check:
                p.unlink()
    for p in stale:
        print(("out of date: " if check else "wrote: ") + str(p.relative_to(ROOT)))
    if check and stale:
        sys.exit(1)
    print(f"{len(files)} artifacts, {len(stale)} {'stale' if check else 'written'}")


if __name__ == "__main__":
    main()
