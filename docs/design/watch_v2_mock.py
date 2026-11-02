#!/usr/bin/env python3
"""Design mock for `agentbus watch` v2 (issue #7, workstream 05). Not shipped code.

It draws every frame in docs/design/watch-v2.md from the sample bus below, so the alignment in the
design is exact and the frames, the golden files, fixture.json and the HTML review page come from
one source. The build (06) does not import this file: it implements `render` in bin/agentbus and
must reproduce tests/golden/watch/*.txt byte for byte.

    python3 docs/design/watch_v2_mock.py            # rewrite every generated artifact
    python3 docs/design/watch_v2_mock.py --check    # exit 1 if any artifact is out of date

Column arithmetic reuses v0.1.0's own helpers (clean, fit, fit_left, ago, time_left, text_width,
share_rows, role_emoji and the colour and emoji tables), loaded from bin/agentbus with runpy.
"""
import html
import json
import os
import pathlib
import re
import runpy
import sys
import time
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
os.environ["TZ"] = "UTC"  # detail times are local HH:MM; the goldens pin the zone
time.tzset()
AB = runpy.run_path(str(ROOT / "bin" / "agentbus"), run_name="agentbus_design_mock")
clean, fit, fit_left = AB["clean"], AB["fit"], AB["fit_left"]
ago, time_left, tw, share_rows = AB["ago"], AB["time_left"], AB["text_width"], AB["share_rows"]
role_emoji, colour_map, when = AB["role_emoji"], AB["colour_map"], AB["_when"]
KIND_EMOJI, KIND_COLOURS = AB["KIND_EMOJI"], AB["KIND_COLOURS"]
KINDS = ("note", "question", "answer", "handoff", "decision", "alert", "done")
KIND_CODE = {"handoff": "hand", "question": "ask", "answer": "ans", "done": "done", "decision": "dec",
             "alert": "ALRT", "note": "note"}
SECTION_EMOJI = {"Agents": "👥", "Claims": "🔒", "Facts": "📌", "Messages": "💬",
                 "Thread": "🧵", "History": "📜", "Mentioned in": "🔗"}
HEADER_SGR = "1;30;43"  # bold black on yellow: the bus
WIDE_COLS, MIN_COLS, IDLE_MIN = 72, 40, 5

GOLDEN = ROOT / "tests" / "golden" / "watch"
DOC = ROOT / "docs" / "design" / "watch-v2.md"
HTML_OUT = ROOT / "docs" / "design" / "watch-v2.html"

# ---------------------------------------------------------------- the sample bus

T_NOW = "2026-11-01T16:44:00Z"
WHERE = "~/src/acme-api"


def at(hhmm):
    return f"2026-11-01T{hhmm}:00Z"


SAMPLE = {
    "agents": [
        {"name": "claude", "role": "planner", "joined_at": at("14:40"), "last_seen": at("16:44")},
        {"name": "codex", "role": "implementer", "joined_at": at("14:41"), "last_seen": at("16:38")},
        {"name": "tests", "role": "tester", "joined_at": at("14:52"), "last_seen": at("16:44")},
    ],
    "claims": [  # watch_snapshot order: soonest expiry first
        {"resource": "docs/api.md", "agent": "tests", "purpose": None, "expires_at": at("17:26")},
        {"resource": "src/auth/", "agent": "codex", "purpose": "token refactor", "expires_at": at("18:43")},
    ],
    "goal": {"goal": "auth on the new token API", "set_by": "nate", "set_at": at("14:44")},
    "context": [  # newest first
        {"key": "baseline_sha", "value": "abc123", "updated_by": "codex", "updated_at": at("16:37")},
        {"key": "runtime", "value": "python 3.9+", "updated_by": "claude", "updated_at": at("16:30")},
    ],
    "messages": [
        {"id": 1, "ts": at("14:45"), "sender": "claude", "recipient": "*", "kind": "note", "reply_to": None,
         "body": "Kickoff: auth moves to the new token API today. Claim before you edit."},
        {"id": 2, "ts": at("14:47"), "sender": "claude", "recipient": "codex", "kind": "handoff", "reply_to": None,
         "body": "Take src/auth/: swap the session cookie for the token API."},
        {"id": 3, "ts": at("15:10"), "sender": "tests", "recipient": "*", "kind": "alert", "reply_to": None,
         "body": "CI on main is red since a1b2c3; hold merges until test_login passes."},
        {"id": 4, "ts": at("15:12"), "sender": "claude", "recipient": "codex", "kind": "decision", "reply_to": None,
         "body": "Keep the refresh path. Tokens live 7 days and refresh rotates them."},
        {"id": 5, "ts": at("16:33"), "sender": "codex", "recipient": "claude", "kind": "done", "reply_to": None,
         "body": "Refresh path done, tests green.\nBranch ws-auth, sha 4f2e9c1."},
        {"id": 6, "ts": at("16:35"), "sender": "tests", "recipient": "codex", "kind": "question", "reply_to": None,
         "body": "Is the 401 body part of the contract, or can it change?"},
        {"id": 7, "ts": at("16:37"), "sender": "codex", "recipient": "tests", "kind": "answer", "reply_to": 6,
         "body": "Plain text for now. A test will pin it once the spec says otherwise, and the handler "
                 "returns the same body for every 401."},
        {"id": 8, "ts": at("16:43"), "sender": "claude", "recipient": "codex", "kind": "handoff", "reply_to": None,
         "body": "Next: the token endpoint in src/auth/token.py once the spec lands. I will review the diff."},
        {"id": 9, "ts": at("16:44"), "sender": "tests", "recipient": "claude", "kind": "question", "reply_to": 7,
         "body": "Which signing algorithm should the tokens use? The spec draft says RS256, the old service "
                 "used HS256, and the fixtures need one answer before I write them."},
    ],
    "counts": {"agents": 3, "messages": 9, "claims": 2},
}
EMPTY = {"agents": [], "claims": [], "goal": None, "context": [], "messages": [],
         "counts": {"agents": 0, "messages": 0, "claims": 0}}
# What the detail views read beyond the snapshot (06: watch_detail, one read-only open per request).
DETAIL = {
    "claimed_at": {"docs/api.md": at("16:26"), "src/auth/": at("15:30")},
    "context_history": {
        "baseline_sha": [{"value": "abc123", "updated_by": "codex", "updated_at": at("16:37")},
                         {"value": "9f8e7d6", "updated_by": "claude", "updated_at": at("15:02")}],
        "runtime": [{"value": "python 3.9+", "updated_by": "claude", "updated_at": at("16:30")}],
    },
}
SNAPSHOTS = {"sample": SAMPLE, "empty": EMPTY}

REFUSED = {"code": "schema_refused", "retry_s": 1, "last_good_s": None,
           "message": "bus schema is not agentbus's: table messages differs (no column request_id)"}
NEWER = {"code": "schema_newer", "retry_s": 1, "last_good_s": None, "version": "0.2.0",
         "message": "bus schema 3 is newer than this agentbus understands (2)"}
BUSY = {"code": "busy", "retry_s": 1, "last_good_s": 12,
        "message": "the bus stayed locked for 15s"}
NOBUS = {"code": "no_bus", "retry_s": 1, "last_good_s": 40,
         "message": "no bus here or in any parent folder"}

DEFAULT_VIEW = {"mode": "overview", "focus": "messages", "sel": {}, "paused": False, "frozen": {},
                "pending": 0, "filter": "", "filter_input": False, "detail": None, "scroll": 0,
                "fresh": [], "error": None, "stale": None}

# State name -> (title, blurb, view overrides, snapshot, live)
STATES = [
    ("overview", "Overview, following",
     "What opens. Everything at a glance: the pinned goal, who is here, what is claimed, the shared facts and "
     "the newest messages. Messages follow the stream (`following`); message 9 arrived in the last 3 seconds, "
     "so it carries the `▌` bar in its kind colour and a bold body. The footer teaches the keys.",
     {"fresh": [9]}, "sample", True),
    ("section-focus", "A section focused, a row selected",
     "After Tab, Tab, j: Claims has the focus, so its title says `j/k move · Enter open`, and `src/auth/` "
     "is selected (`>` and reverse video). Messages keep following underneath.",
     {"focus": "claims", "sel": {"claims": "src/auth/"}}, "sample", True),
    ("messages-paused", "Messages paused",
     "After k in Messages: the stream stops so you can read. A message that arrives while paused is counted "
     "(`+1 new`) and does not move the view; p or G follows again. Agents, claims and facts keep refreshing.",
     {"focus": "messages", "sel": {"messages": 8}, "paused": True, "frozen": {"messages": 8}, "pending": 1},
     "sample", True),
    ("message-detail", "Message detail with its thread",
     "Enter on message 7: the whole body, wrapped, never cut, and the thread (the messages it replies to and "
     "the replies to it). t hides the thread; Esc goes back to exactly the frame you left.",
     {"mode": "detail", "detail": {"section": "messages", "key": 7, "thread": True}}, "sample", True),
    ("agent-detail", "Agent detail",
     "Enter on an agent: its role, when it was last seen, what it holds, and its last 5 messages "
     "(sent by it or addressed to it).",
     {"mode": "detail", "focus": "agents", "detail": {"section": "agents", "key": "codex"}}, "sample", True),
    ("claim-detail", "Claim detail",
     "Enter on a claim: holder, purpose, when it was taken and when it runs out, and the messages that name it.",
     {"mode": "detail", "focus": "claims", "detail": {"section": "claims", "key": "src/auth/"}}, "sample", True),
    ("fact-detail", "Fact detail",
     "Enter on a fact: the whole value and its history, newest first (what `agentbus ctx history KEY` prints).",
     {"mode": "detail", "focus": "facts", "detail": {"section": "facts", "key": "baseline_sha"}}, "sample", True),
    ("help", "Help",
     "? from anywhere: every key and every mark, in plain words. With emoji on it also explains the emoji. "
     "Esc closes it. Where the page is taller than the terminal, j/k scroll it.",
     {"mode": "help"}, "sample", True),
    ("filter", "Filter, typing",
     "/ then `kind:question`: the input sits in the footer and every key is text (q types a q). Sections "
     "narrow as you type and say `N of M`; a section with nothing left says `no match` on its title row and "
     "gives its rows to the others. Enter keeps the filter, Esc clears it.",
     {"mode": "filter", "filter": "kind:question", "filter_input": True}, "sample", True),
    ("filter-kept", "Filter kept",
     "After Enter: the filter stays on (here the word `auth`), the footer shows it, Esc clears it and / edits it.",
     {"filter": "auth"}, "sample", True),
    ("filter-error", "Filter with an unknown kind",
     "A `kind:` no kind starts with matches nothing and says which kinds exist, on the row above the input.",
     {"mode": "filter", "filter": "kind:fyi", "filter_input": True}, "sample", True),
    ("error-refused", "Bus refused",
     "The bus could not be read (here a v0.1.0 bus whose tables differ). The sections are not drawn at all, so "
     "nothing stale passes for current. The fix is one command. watch keeps retrying; r retries now.",
     {"error": REFUSED}, "sample", True),
    ("error-newer", "Bus newer than this watch",
     "The bus was upgraded by a newer agentbus than the one running this watch.",
     {"error": NEWER}, "sample", True),
    ("error-busy", "Bus busy",
     "Another process held the bus past the 15 s wait. Not an error in the bus, so yellow, not red.",
     {"error": BUSY}, "sample", True),
    ("error-nobus", "Bus gone",
     "The bus folder was removed while watch was open.",
     {"error": NOBUS}, "sample", True),
    ("empty-bus", "Empty bus",
     "A fresh bus: every section says how to fill it (the v0.1.0 lines, kept).",
     {}, "empty", True),
    ("stale", "Running old code",
     "The bus copy on disk was upgraded to 0.2.0 while this watch kept running older code; the Messages title "
     "says so, next to the follow state.",
     {"stale": "0.2.0"}, "sample", True),
    ("once", "One frame (--once, a pipe, or TERM=dumb)",
     "Not a terminal, `--once`, or `TERM=dumb`/unset: one frame, content only, no footer, no hints, no escape "
     "codes; TERM=dumb also prints `agentbus: TERM=dumb, printing one frame. Use a terminal for the live view.` "
     "on stderr. Emoji are off whenever stdout is not a terminal; the emoji variant is what `--once` prints on one.",
     {}, "sample", False),
]
STATE = {s[0]: s for s in STATES}

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


class Frame:
    def __init__(self, cols, rows, emoji, view, snap, where, t_now, live=True):
        self.cols, self.rows, self.E, self.live = cols, rows, emoji, live
        self.W, self.wide = cols - 1, cols >= WIDE_COLS
        self.v = dict(DEFAULT_VIEW, **view)
        self.snap, self.where, self.t = snap, where, t_now
        self.colour = colour_map(snap["agents"])

    # ------------------------------------------------ shared pieces

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

    def header(self, right_text):
        W = self.W
        head = " 🚌 agentbus  " if self.E else " agentbus  "
        r = right_text + " "
        room = W - tw(head) - tw(r) - 1
        if room >= 8:
            text = head + fit_left(self.where, room) + " " + r
        else:  # no room for the folder: the name, then the right-hand text, as much as fits
            text = next((h + right_text for h in (head, head[:-1], " agentbus ") if tw(h + right_text) <= W),
                        " agentbus " + right_text)
            text = fit(text, W) if tw(text) > W else text + " " * (W - tw(text))
        return Row((text, HEADER_SGR))

    def stats(self):
        n = self.snap["counts"]

        def plural(k, word):
            return f"{n[k]} {word}{'' if n[k] == 1 else 's'}"
        return " · ".join([plural("agents", "agent"), plural("claims", "claim"),
                           plural("messages", "message" if self.wide else "msg")])

    def goal_row(self):
        W, g = self.W, self.snap.get("goal")
        if g:
            lead = "  🎯 " if self.E else "  ◆ "
            tail = clean(f" · {g['set_by']} · {ago(g['set_at'], self.t)}")
            goal_w = W - tw(lead) - tw(tail)
            if goal_w < 12 or not self.wide and tw(clean(g["goal"])) > goal_w:  # narrow: the goal before who set it
                tail, goal_w = "", W - tw(lead)
            return Row((lead, "1;33"), (fit(g["goal"], goal_w), "1"), (tail, "2"))
        lead = "  🎯 " if self.E else "  ◇ "
        return Row((lead + fit('no goal yet · agentbus --as NAME goal "..."', W - tw(lead)), "2"))

    def title(self, name, count, right_variants=(), right_sgr="2"):
        left = Row(((SECTION_EMOJI.get(name, "") + " " if self.E and name in SECTION_EMOJI else "") + name, "1"),
                   (f"  {count}" if count != "" else "", "2"))
        return first_fit(left, list(right_variants), self.W, right_sgr)

    def footer(self, items, prefix=None, rhs=None):
        """items: (key, words, priority); lowest priority dropped first until the row fits."""
        W = self.W
        keep = list(items)
        while True:
            row = Row(("  ", ""))
            if prefix:
                row.extend(prefix)
                if keep:
                    row.add(" · ", "2")
            for i, (k, w, _) in enumerate(keep):
                if i:
                    row.add(" · ", "2")
                row.add(k, "1")
                row.add((" " + w) if w else "", "2")
            if row.width <= W or not keep:
                break
            keep.remove(min(keep, key=lambda x: x[2]))
        if rhs:
            row = right(row, rhs, W)
        return row

    # ------------------------------------------------ section rows

    def agent_row(self, a, sel=False, hot=()):
        W, E = self.W, self.E
        seen = when(a["last_seen"])
        idle = seen is None or (self.t - seen).total_seconds() > IDLE_MIN * 60
        nw = 16 if self.wide else 12
        lead_w = 4 if E else 1
        rw = W - 2 - lead_w - 1 - nw - 1 - 5
        role = fit(a["role"], rw) if (self.wide or rw >= 8) else " " * rw
        row = Row(("> " if sel else "  ", ""), ("○" if idle else "●", "2" if idle else self.ac(a["name"])), sel=sel)
        if E:
            row.add(" " + role_emoji(a["role"]))
        row.add(" ")
        row.add(fit(a["name"], nw), "1" if a["name"] in hot else "")
        row.add(" ")
        row.add(role, "2")
        row.add(ago(a["last_seen"], self.t).rjust(5), "2")
        return row

    def claim_row(self, c, sel=False):
        W = self.W
        res_w = max(14, min(36, W // 3))
        hw = 12 if self.wide else 10
        rest = f"{time_left(c['expires_at'], self.t)} left" + (f" · {c['purpose']}" if self.wide and c["purpose"] else "")
        return Row(("> " if sel else "  ", ""), (fit(c["resource"], res_w), ""), (" ", ""),
                   (fit(c["agent"], hw), self.ac(c["agent"])), (" ", ""),
                   (fit(rest, W - 2 - res_w - 1 - hw - 1), "2"), sel=sel)

    def fact_row(self, x, sel=False):
        W = self.W
        key_w = max(10, min(24, W // 5)) if self.wide else max(12, min(24, W // 4))
        if self.wide:
            by_w, by = min(20, W // 4), f"{x['updated_by']} · {ago(x['updated_at'], self.t)}"
        else:
            by_w, by = 4, ago(x["updated_at"], self.t)
        return Row(("> " if sel else "  ", ""), (fit(x["key"], key_w), ""), (" ", ""),
                   (fit(x["value"], W - 2 - key_w - 1 - by_w - 1), ""), (" ", ""),
                   (fit(by, by_w).rstrip().rjust(by_w), "2"), sel=sel)

    def msg_row(self, m, sel=False, new=False, here=False):
        W, E = self.W, self.E
        kind = str(m["kind"])
        kc = str(KIND_COLOURS.get(kind, 2))
        to = "everyone" if m["recipient"] == "*" else m["recipient"]
        emo = (KIND_EMOJI.get(kind, "📝") + " ") if E else ""
        if self.wide:
            mid_w, route_w, arrow, kind_cell = 5, 24, " → ", emo + fit(kind, 9)
        else:
            mid_w, route_w, arrow, kind_cell = 4, 13, "→", emo + fit(KIND_CODE.get(kind, kind[:4]), 4)
        part = (route_w - len(arrow)) // 2
        frm, dest = fit(m["sender"], part).rstrip(), fit(to, part).rstrip()
        lines = str(m["body"] or "").split("\n")
        extra = f" ↵+{len(lines) - 1}" if len(lines) > 1 else ""
        reply = f"↳#{m['reply_to']} " if m["reply_to"] else ""
        fixed = 2 + mid_w + route_w + 1 + tw(kind_cell) + 1 + tw(extra) + 1 + 4
        if not self.wide and W - fixed - tw(reply) < 8:
            reply = ""  # narrow: the body keeps 8 columns before the reply mark is shown
        body_w = W - fixed - tw(reply)
        mark = ">" if (sel or here) else ("▌" if new else " ")
        row = Row(sel=sel)
        row.add(mark, kc if mark == "▌" else "1" if here else "")
        row.add(" ")
        row.add(fit("#" + str(m["id"]), mid_w), "2")
        row.add(frm, self.ac(m["sender"]))
        row.add(arrow, "2")
        row.add(dest, "2" if to == "everyone" else self.ac(to))
        row.add(" " * (route_w - tw(frm) - len(arrow) - tw(dest)) + " ")
        row.add(kind_cell, kc)
        row.add(" ")
        row.add(reply, "2")
        text = fit(lines[0], body_w).rstrip()  # the ↵+N mark follows the text, then the padding
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
                want = tok[5:].lower()
                if not any(k.startswith(want) for k in KINDS):
                    return "kind must be one of: " + ", ".join(KINDS)
        return None

    def matches(self, section, item):
        toks = self.filter_tokens()
        if not toks:
            return True
        if self.kind_error():
            return False
        for tok in toks:
            low = tok.lower()
            field, _, val = low.partition(":")
            if field in ("from", "to", "kind") and _:
                if section == "messages":
                    if field == "from":
                        ok = str(item["sender"]).lower().startswith(val)
                    elif field == "to":
                        r = str(item["recipient"]).lower()
                        ok = r == "*" and val in ("*", "everyone") or r != "*" and r.startswith(val)
                    else:
                        ok = str(item["kind"]).lower().startswith(val)
                elif field == "from":
                    who = {"agents": "name", "claims": "agent", "facts": "updated_by"}[section]
                    ok = str(item[who]).lower().startswith(val)
                else:
                    ok = False
            else:
                fields = {"agents": ("name", "role"), "claims": ("resource", "agent", "purpose"),
                          "facts": ("key", "value", "updated_by"),
                          "messages": ("id", "sender", "recipient", "body")}[section]
                ok = any(low in str(item.get(f) or "").lower() for f in fields)
            if not ok:
                return False
        return True

    # ------------------------------------------------ whole frames

    def render(self):
        if self.cols < MIN_COLS:
            return self.pad([Row((fit(f"watch needs {MIN_COLS}+ columns", self.cols), ""))])
        if self.v["error"]:
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

    def overview(self):
        W, v, snap, live = self.W, self.v, self.snap, self.live
        filtering = bool(self.filter_tokens())
        fresh = set(v["fresh"])
        hot = {m["sender"] for m in snap["messages"] if m["id"] in fresh}
        focus = v["focus"]
        sel = v["sel"]
        secs = []
        for name, key, items, rowf, empty, cmd, keyf in (
                ("Agents", "agents", snap["agents"], self.agent_row,
                 "no one yet. Join with: agentbus --as NAME join", "who", lambda x: x["name"]),
                ("Claims", "claims", snap["claims"], self.claim_row, "nothing claimed", "claims",
                 lambda x: x["resource"]),
                ("Facts", "facts", snap["context"], self.fact_row, "none yet", "ctx get", lambda x: x["key"])):
            total = snap["counts"]["agents"] if key == "agents" else snap["counts"]["claims"] if key == "claims" \
                else len(items)
            keep = [x for x in items if self.matches(key, x)]
            rows_ = [rowf(x, sel=(focus == key and sel.get(key) == keyf(x)), **({"hot": hot} if key == "agents" else {}))
                     for x in keep]
            secs.append((name, key, total, len(keep), rows_, empty, cmd))
        msgs = snap["messages"]
        frozen = v["frozen"].get("messages")
        shown_msgs = [m for m in msgs if frozen is None or m["id"] <= frozen]
        msg_keep = [m for m in shown_msgs if self.matches("messages", m)]
        msg_rows = [self.msg_row(m, sel=(focus == "messages" and sel.get("messages") == m["id"]),
                                 new=m["id"] in fresh) for m in msg_keep]
        sel_idx = next((i for i, m in enumerate(msg_keep) if focus == "messages" and sel.get("messages") == m["id"]), None)
        n_msgs = snap["counts"]["messages"]
        err = self.kind_error() if v["mode"] == "filter" else None

        # rows: v0.1.0's shares; a filtered section with no match keeps its title only
        def need(s):
            name, key, total, n, rows_, empty, cmd = s
            if filtering and n == 0:
                return 0
            return max(1, len(rows_) + (1 if not filtering and total > len(rows_) else 0))
        natural = 3 + 4 + sum(need(s) for s in secs) + max(1, len(msg_rows))
        gap = live and (self.rows >= 30 or natural + 4 <= self.rows)
        if live:
            err_rows = self.wrap(err, W - 2, "  ") if err else []
            fixed = 1 + 1 + 1 + 4 + (4 if gap else 0) + len(err_rows)
            body_rows = max(4, self.rows - fixed)
            want = max(1, len(msg_rows))
            msg_share = min(want, max(3, body_rows // 2))
            shares = share_rows([need(s) for s in secs], max(0, body_rows - msg_share))
            msg_share = max(1, body_rows - sum(shares))
        else:
            shares = [need(s) for s in secs]
            msg_share = 21

        out = [self.header(self.stats()), self.goal_row()]
        for s, share in zip(secs, shares):
            name, key, total, n, rows_, empty, cmd = s
            if gap or not live:
                out.append(Row())
            count = f"{n} of {total}" if filtering else str(total)
            if filtering and n == 0:
                out.append(self.title(name, count, ["no match"]))
                continue
            hint = ["j/k move · Enter open", "j/k · Enter", ""] if live and focus == key else []
            out.append(self.title(name, count, hint))
            if not rows_:
                out.append(Row(("  " + fit(empty, W - 2), "2")))
                continue
            cut = len(rows_) > share or (not filtering and total > len(rows_))
            if not cut:
                out.extend(rows_)
                continue
            if share <= 1:
                out.extend(rows_[:1])
                continue
            si = next((i for i, r in enumerate(rows_) if r.sel), 0)
            top = max(0, min(si - (share - 2), len(rows_) - (share - 1)))
            vis = rows_[top:top + share - 1]
            out.extend(vis)
            below = total - top - len(vis)
            more = f"… {below} more" + (f" · agentbus {cmd}" if total > len(rows_) else "")
            out.append(Row(("  " + fit(more, W - 2), "2")))
        if gap or not live:
            out.append(Row())
        # Messages title: the follow state, always, plus the stale-process note
        rhs = []
        if live:
            if v["paused"]:
                p = v["pending"]
                follow = ([f"paused · +{p} new · p or G to follow", f"paused · +{p} new", "paused"] if p else
                          ["paused · p or G to follow", "paused"])
                fsgr = "33"
            else:
                follow, fsgr = ["following"], "2"
            if v["stale"]:
                follow = [f"restart for {v['stale']} · {f}" for f in follow] + follow
                fsgr = "33"
            rhs = follow
        count = f"{len(msg_keep)} of {n_msgs}" if filtering else str(n_msgs)
        if filtering and not msg_keep:
            out.append(self.title("Messages", count, ["no match"]))
        else:
            out.append(self.title("Messages", count, rhs, fsgr if live else "2"))
            if not msg_rows:
                out.append(Row(("  quiet so far", "2")))
            elif len(msg_rows) <= msg_share and n_msgs <= len(msgs) or not live and len(msg_rows) <= 20:
                out.extend(msg_rows if live else msg_rows[-20:])
            else:
                k = msg_share - 1 if live else 20
                end = len(msg_rows) if sel_idx is None else max(sel_idx + 1, min(len(msg_rows), k))
                start = max(0, end - k)
                vis = msg_rows[start:end]
                earlier = start + (0 if filtering else n_msgs - len(msgs))
                if earlier:
                    note = f"… {earlier} earlier" + (" · agentbus read" if n_msgs > len(msgs) and not filtering else "")
                    out.append(Row(("  " + fit(note, W - 2), "2")))
                out.extend(vis)
        if not live:
            return out
        if err:
            err_rows = [Row((r.text, "31")) for r in self.wrap(err, W - 2, "  ")]
            body = out[:self.rows - 1 - len(err_rows)]
            while len(body) < self.rows - 1 - len(err_rows):
                body.append(Row())
            return body + err_rows + [self.filter_footer()]
        return self.pad(out, self.overview_footer())

    def filter_footer(self):
        W = self.W
        text = self.v["filter"]
        row = Row(("/", "1;33"), (fit(text, W - 1 - 1).rstrip(), ""), ("_", "1;33"))
        return right(row, [("Enter", "1"), (" keep", "2"), (" · ", "2"), ("Esc", "1"), (" clear", "2")], W)

    def overview_footer(self):
        v = self.v
        if v["mode"] == "filter":
            return self.filter_footer()
        q = [("?", "help", 90), ("q", "quit", 100)]
        if v["filter"]:
            return self.footer([("Esc", "clear", 80), ("/", "edit", 70), ("j/k", "move", 60), ("Enter", "open", 50)] + q,
                               prefix=Row(("/" + v["filter"], "1;33")))
        if v["paused"]:
            return self.footer([("j/k", "move", 60), ("Enter", "open", 50), ("p", "follow", 80),
                                ("g/G", "top/bottom", 20), ("/", "filter", 40)] + q)
        if v["focus"] != "messages":
            return self.footer([("j/k", "move", 60), ("Enter", "open", 50), ("Tab", "next section", 30),
                                ("/", "filter", 40)] + q)
        return self.footer([("j/k", "move", 60), ("Enter", "open", 50), ("/", "filter", 40), ("p", "pause", 20),
                            ("Tab", "section", 30)] + q)

    # ------------------------------------------------ detail

    def wrap(self, text, width, indent):
        out = []
        for para in clean(text, newlines=True).split("\n"):
            line = ""
            for word in para.split(" "):
                while tw(word) > width:  # a word longer than the row is broken, never cut
                    room = width - tw(line) - (1 if line else 0)
                    if room <= 0:
                        out.append(line)
                        line, room = "", width
                    cut, w = "", 0
                    for c in word:
                        if w + tw(c) > room:
                            break
                        cut, w = cut + c, w + tw(c)
                    line = (line + " " + cut) if line else cut
                    word = word[len(cut):]
                if not line:
                    line = word
                elif tw(line) + 1 + tw(word) <= width:
                    line += " " + word
                else:
                    out.append(line)
                    line = word
            out.append(line)
        return [Row((indent + l, "")) for l in out]

    def label_rows(self, label, value_segs, wrap_text=None):
        W = self.W
        lab = "  " + label.ljust(10)
        if wrap_text is not None:
            lines = self.wrap(wrap_text, W - tw(lab), "")
            rows = []
            for i, r in enumerate(lines):
                rows.append(Row((lab if i == 0 else " " * tw(lab), "2"), (r.text, "1" if label == "key" else "")))
            return rows
        return [Row((lab, "2"), *value_segs)]

    def detail_frame(self):
        d, snap, W = self.v["detail"], self.snap, self.W
        sec = d["section"]
        body = [Row()]
        hint_t = None
        if sec == "messages":
            byid = {m["id"]: m for m in snap["messages"]}
            m = byid[d["key"]]
            label = f"message #{m['id']}"
            kind = str(m["kind"])
            kc = str(KIND_COLOURS.get(kind, 2))
            to = "everyone" if m["recipient"] == "*" else m["recipient"]
            meta = Row(("  ", ""), (f"#{m['id']}", "1"), ("  ", ""), (fit(m["sender"], 16).rstrip(), self.ac(m["sender"])),
                       (" → ", "2"), (fit(to, 16).rstrip(), "2" if to == "everyone" else self.ac(to)), ("  ", ""),
                       ((KIND_EMOJI.get(kind, "📝") + " " if self.E else "") + kind, kc))
            if m["reply_to"]:
                meta.add(f"  ↳ re #{m['reply_to']}", "2")
            when_t = f"{self.hhmm(m['ts'])} · {self.ago_words(m['ts'])}"
            if meta.width + 2 + tw(when_t) <= W:
                body.append(right(meta, [(when_t, "2")], W))
            else:
                body += [meta, Row(("  " + when_t, "2"))]
            body.append(Row())
            body += self.wrap(m["body"], W - 4, "    ")
            if d.get("thread", True):
                chain, cur = [], m
                while cur["reply_to"] and cur["reply_to"] in byid and len(chain) < 20:
                    cur = byid[cur["reply_to"]]
                    chain.append(cur)
                replies = [x for x in snap["messages"] if x["reply_to"] == m["id"]][:20]
                thread = sorted(chain + [m] + replies, key=lambda x: x["id"])
                body.append(Row())
                body.append(self.title("Thread", str(len(thread)), ["t hides it", ""]))
                body += [self.msg_row(x, here=x["id"] == m["id"]) for x in thread]
            hint_t = True
        elif sec == "agents":
            a = next(x for x in snap["agents"] if x["name"] == d["key"])
            label = "agent"
            seen = when(a["last_seen"])
            idle = seen is None or (self.t - seen).total_seconds() > IDLE_MIN * 60
            r = Row(("  ", ""), ("○" if idle else "●", "2" if idle else self.ac(a["name"])))
            if self.E:
                r.add(" " + role_emoji(a["role"]))
            r.add(" ")
            r.add(fit(a["name"], 24).rstrip(), "1")
            r.add("  ")
            r.add(fit(a["role"], max(0, W - r.width)).rstrip(), "2")
            body.append(r)
            body.append(Row(("  " + fit(f"last seen {self.hhmm(a['last_seen'])}, {self.ago_words(a['last_seen'])}"
                                        f" · joined {self.hhmm(a['joined_at'])}", W - 2), "2")))
            body.append(Row())
            cl = [c for c in snap["claims"] if c["agent"] == a["name"]]
            body.append(self.title("Claims", str(len(cl))))
            body += [self.claim_row(c) for c in cl] or [Row(("  nothing claimed", "2"))]
            body.append(Row())
            mine = [m for m in snap["messages"] if a["name"] in (m["sender"], m["recipient"])]
            last = mine[-5:]
            body.append(self.title("Messages", f"{len(last)} of {len(mine)}",
                                   [f"from or to {a['name']}", ""]))
            body += [self.msg_row(m) for m in last] or [Row(("  quiet so far", "2"))]
        elif sec == "claims":
            c = next(x for x in snap["claims"] if x["resource"] == d["key"])
            label = "claim"
            holder = next((x for x in snap["agents"] if x["name"] == c["agent"]), None)
            claimed = DETAIL["claimed_at"].get(c["resource"])
            body += self.label_rows("claim", [(fit(c["resource"], W - 12).rstrip(), "1")])
            h = Row(("●", self.ac(c["agent"])))
            if self.E and holder:
                h.add(" " + role_emoji(holder["role"]))
            h.add(" ")
            h.add(c["agent"], self.ac(c["agent"]))
            if holder and holder["role"]:
                h.add(" · " + holder["role"], "2")
            body += self.label_rows("held by", h.segs)
            body += self.label_rows("purpose", [], wrap_text=c["purpose"] or "none given")
            if claimed:
                body += self.label_rows("claimed", [(f"{self.hhmm(claimed)}, {self.ago_words(claimed)}", "")])
            body += self.label_rows("expires", [(f"{self.hhmm(c['expires_at'])}, "
                                                 f"{time_left(c['expires_at'], self.t)} left", "")])
            body.append(Row())
            named = [m for m in snap["messages"] if c["resource"] in str(m["body"])]
            body.append(self.title("Mentioned in", str(len(named)), ["messages that name it", ""]))
            body += [self.msg_row(m) for m in named[-5:]] or [Row(("  no message names it", "2"))]
        else:
            x = next(f for f in snap["context"] if f["key"] == d["key"])
            label = "fact"
            body += self.label_rows("key", [(fit(x["key"], W - 12).rstrip(), "1")])
            body += self.label_rows("value", [], wrap_text=x["value"])
            body += self.label_rows("set by", [(x["updated_by"], self.ac(x["updated_by"])),
                                               (f", {self.hhmm(x['updated_at'])}, {self.ago_words(x['updated_at'])}", "")])
            hist = DETAIL["context_history"].get(x["key"], [])
            body.append(Row())
            body.append(self.title("History", str(len(hist)), ["newest first", ""]))
            for h in hist:
                body.append(Row(("  " + self.hhmm(h["updated_at"]).rjust(5) + "  ", "2"),
                                (fit(h["updated_by"], 12), self.ac(h["updated_by"])), (" ", ""),
                                (fit(h["value"], W - 2 - 7 - 13), "")))
        items = [("j/k", "scroll", 60)]
        if hint_t:
            items.append(("t", "thread", 50))
        items += [("Esc", "back", 95), ("?", "help", 90), ("q", "quit", 100)]
        return self.page([self.header(label), self.goal_row()] + body, self.footer(items))

    def page(self, rows, footer):
        """Rows above the footer, scrolled by view.scroll; an overflow ends in a dim '… N more lines' row."""
        room = self.rows - 1
        head, rest = rows[:2], rows[2:]
        s = self.v["scroll"]
        rest = rest[s:]
        if len(head) + len(rest) > room:
            keep = room - len(head) - 1
            hidden = len(rest) - keep
            rest = rest[:keep] + [Row(("  " + fit(f"… {hidden} more lines · j to scroll", self.W - 2), "2"))]
        return self.pad(head + rest, footer)

    # ------------------------------------------------ help

    def help_frame(self):
        W, E = self.W, self.E
        kw = 16
        move = [("j k  ↓ ↑", "one row"), ("g G  Home End", "first, last row"),
                ("PgUp PgDn", "one page"), ("Ctrl-u Ctrl-d", "half a page"),
                ("Tab  Shift-Tab", "next, previous section"), ("1 2 3 4", "Agents, Claims, Facts, Messages")]
        look = [("Enter", "open the selected row; a message opens with its thread"),
                ("t", "show or hide the thread of an open message"),
                ("/", "filter: from:NAME to:NAME kind:KIND, or any words"),
                ("p", "pause the messages, or follow them again"),
                ("r", "read the bus now"),
                ("Esc", "back: closes a detail, the filter or this page"),
                ("q  Ctrl-C", "quit (Esc never quits)")]
        rows = [self.header("keys")]
        rows += [Row((r.text, "2")) for r in self.wrap(
            "watch only reads the bus. It never marks a message read and never changes a claim.", W - 2, "  ")]
        rows.append(Row())

        def entry(k, d, width):
            return [Row(("  " + (k if i == 0 else "").ljust(kw), "1"), (line.text, ""))
                    for i, line in enumerate(self.wrap(d, width - 2 - kw, ""))]
        rows.append(Row(("Move", "1")))
        if self.wide:  # two entries a row
            half = W // 2
            for i in range(0, len(move), 2):
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
        marks = [("●", "seen in the last 5 minutes"), ("○", "quiet for 5 minutes or more"),
                 (">", "selected row"), ("▌", "new in the last 3 seconds"),
                 ("🎯" if E else "◆", "the team's goal"), ("↳#6", "a reply to message 6"),
                 ("↵+1", "one more line; Enter shows it")]
        per = 3 if W >= 99 else 2 if self.wide else 1
        cw = W // per
        for i in range(0, len(marks), per):
            r = Row()
            for j, (g, d) in enumerate(marks[i:i + per]):
                cell = "  " + g + " " * (4 - tw(g)) + d
                if j + 1 < per and i + j + 1 < len(marks):
                    cell += " " * (cw - tw(cell))
                r.add(cell)
            rows.append(r)
        rows.append(Row())
        rows.append(Row(("Kinds", "1"), ("  the short form is used under 72 columns", "2")))
        kinds = ["handoff", "question", "answer", "done", "decision", "alert", "note"]
        cells = [((KIND_EMOJI[k] + " ") if E else "") + (f"{KIND_CODE[k]} {k}" if KIND_CODE[k] != k else k)
                 for k in kinds]
        rows += self.flow(cells, [str(KIND_COLOURS.get(k, 2)) for k in kinds])
        if E:
            rows.append(Row())
            rows.append(Row(("Roles", "1"), ("  matched on words in the role", "2")))
            roles = [("🧠", "brain, lead, planner"), ("✋", "hand, implementer"), ("🧪", "tests"), ("🔍", "review"),
                     ("📚", "docs"), ("🚀", "ops, release"), ("🎨", "design"), ("🙋", "human"), ("🤖", "anyone else")]
            rows += self.flow([f"{e} {d}" for e, d in roles], [""] * len(roles))
        return self.page(rows, self.footer([("j/k", "scroll", 60), ("Esc", "back", 95), ("q", "quit", 100)]))

    def flow(self, cells, sgrs):
        """Cells laid out left to right, two spaces apart, wrapped at the row width."""
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

    # ------------------------------------------------ errors

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
            "busy": ("waiting", "1;33", "⏳", f"Another process holds the bus. Retrying every {e['retry_s']}s.", []),
            "no_bus": ("no bus", "1;31", "🌱", "There is no bus here any more, so the sections are not drawn.",
                       [("Run: ", f"agentbus init {where}")]),
        }[code]
        rows = [self.header(label), Row()]
        lead = "  " + (icon + " " if E else "")
        for i, r in enumerate(self.wrap(head, W - tw(lead), "")):
            rows.append(Row(((lead if i == 0 else " " * tw(lead)), sgr if i == 0 else ""), (r.text, sgr)))
        ind = " " * tw(lead)
        rows += [Row((r.text, "2")) for r in self.wrap(e["message"], W - tw(ind), ind)]
        for pre, cmd in lines:
            for i, r in enumerate(self.wrap(pre + cmd, W - tw(ind), "")):
                t = r.text
                if i == 0 and pre:
                    rows.append(Row((ind + pre, "2"), (t[len(pre):], "1")))
                else:
                    rows.append(Row((ind + t, "1" if pre else "")))
        rows.append(Row())
        last = "none" if e["last_good_s"] is None else f"{e['last_good_s']}s ago"
        tail = f"Last good frame: {last}." if code == "busy" else f"Retrying every {e['retry_s']}s. Last good frame: {last}."
        rows += [Row((r.text, "2")) for r in self.wrap(tail, W - tw(ind), ind)]
        return self.page(rows, self.footer([("r", "retry now", 80), ("?", "help", 90), ("q", "quit", 100)]))


# ---------------------------------------------------------------- goldens, fixture, doc, html

def entries():
    """Every golden: the owner's sizes (100x30, 60x20, with and without emoji), the runbook's 80x24 for
    every state, and 40x16, 60x24 and 120x40 for the five states the runbook names."""
    out = []
    extra = ("overview", "section-focus", "message-detail", "help", "error-refused")
    for name, _, _, view, snap, live in STATES:
        sizes = [(100, 30, False), (60, 20, False), (100, 30, True), (60, 20, True), (80, 24, False)]
        if name in extra:
            sizes += [(40, 16, False), (60, 24, False), (120, 40, False)]
        for cols, rows, emoji in sizes:
            if not live:
                rows = len(Frame(cols, 999, emoji, view, SNAPSHOTS[snap], WHERE, T_DT, live=False).render())
            out.append({"name": f"{name}-{cols}x{rows}" + ("-emoji" if emoji else ""), "state": name,
                        "cols": cols, "rows": rows, "emoji": emoji, "live": live, "snapshot": snap,
                        "t_now": T_NOW, "where": WHERE, "view": dict(DEFAULT_VIEW, **view)})
    out.append({"name": "too-narrow-39x8", "state": "too-narrow", "cols": 39, "rows": 8, "emoji": False, "live": True,
                "snapshot": "sample", "t_now": T_NOW, "where": WHERE, "view": dict(DEFAULT_VIEW)})
    return out


T_DT = when(T_NOW)


def frame_for(e):
    f = Frame(e["cols"], e["rows"], e["emoji"], e["view"], SNAPSHOTS[e["snapshot"]], e["where"], when(e["t_now"]),
              live=e["live"])
    return f.render()


def golden_text(rows):
    return "".join(r.text.rstrip() + "\n" for r in rows)


def fixture():
    return {
        "about": "Sample bus and per-golden render inputs for tests/golden/watch (issue #7). Generated by "
                 "docs/design/watch_v2_mock.py; edit there and regenerate. Times are UTC and the goldens are "
                 "rendered with TZ=UTC, colour off.",
        "kinds": list(KINDS),
        "snapshots": SNAPSHOTS,
        "detail": DETAIL,
        "goldens": entries(),
    }


SGR_CSS = {"1": "b", "2": "d", "7": "rv", "31": "c31", "32": "c32", "33": "c33", "34": "c34", "35": "c35",
           "36": "c36", "94": "c94", "95": "c95", "96": "c96", "30": "c30", "43": "bg43"}


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
        cls = " ".join(SGR_CSS[x] for x in sgr.split(";") if x in SGR_CSS) if sgr and not row.sel else ""
        parts.append(f'<span class="{cls}">{cell(text)}</span>' if cls else cell(text))
    pad = cols - row.width
    if row.segs and row.segs[0][1] == HEADER_SGR:
        parts.append(f'<span class="b c30 bg43">{" " * max(0, pad)}</span>')
        pad = 0
    if row.sel:
        inner = "".join(parts) + " " * max(0, pad - 1)
        return f'<span class="rv">{inner}</span>'
    return "".join(parts)


def frame_block(name, cols, rows, emoji, view, snap, live):
    """A ```text block for the doc: label line, then the rows with trailing blank rows elided."""
    if not live:
        rows = 999
    fr = Frame(cols, rows, emoji, view, SNAPSHOTS[snap], WHERE, T_DT, live=live).render()
    lines = [r.text.rstrip() for r in fr]
    while lines and not lines[-1]:
        lines.pop()
    label_rows = len(fr) if live else len(lines)
    tag = name + ("" if emoji else "-noemoji")
    return f"```text\n[frame {tag} {cols}x{label_rows}]\n" + "\n".join(lines) + "\n```\n", fr


def doc_section(state):
    name, title, blurb, view, snap, live = STATE[state]
    out = [f"{blurb}\n"]
    for cols, rows in ((100, 30), (60, 20)):
        for emoji in (True, False):
            out.append(frame_block(name, cols, rows, emoji, view, snap, live)[0])
    return "\n".join(out)


def fill_doc(text):
    def sub(m):
        state = m.group(1)
        if state == "too-narrow":
            fr = Frame(39, 8, False, {}, SAMPLE, WHERE, T_DT).render()
            body = "```text\n[frame too-narrow 39x8]\n" + fr[0].text.rstrip() + "\n```\n"
        else:
            body = doc_section(state)
        return f"<!-- BEGIN frames {state} -->\n{body}<!-- END frames {state} -->"
    return re.sub(r"<!-- BEGIN frames (\S+) -->.*?<!-- END frames \1 -->", sub, text, flags=re.S)


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
.c30 { color:#1a1626 !important; } .bg43 { background:#ffd166; }
.c31 { color:#ff6b6b; } .c32 { color:#7bd88f; } .c33 { color:#ffd166; } .c34 { color:#6cb6ff; }
.c35 { color:#d38cff; } .c36 { color:#5ee0e0; } .c94 { color:#9ec9ff; } .c95 { color:#f0a6ff; } .c96 { color:#9ef0f0; }
#nocolor:checked ~ main pre.term span { color:var(--fg) !important; background:none !important; font-weight:normal; }
#nocolor:checked ~ main pre.term span * { color:var(--fg) !important; }
.toggles label::before { content:"\2610  "; }
#nocolor:checked ~ .toggles label[for=nocolor]::before, #noemoji:checked ~ .toggles label[for=noemoji]::before,
#emojionly:checked ~ .toggles label[for=emojionly]::before, #hidesmall:checked ~ .toggles label[for=hidesmall]::before,
#hidelarge:checked ~ .toggles label[for=hidelarge]::before { content:"\2611  "; }
ol.decisions li { margin:6px 0; max-width:1000px; }
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
        s = html.escape(s)
        return re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    parts = ["<!doctype html><html lang=en><head><meta charset=utf-8>",
             "<meta name=viewport content='width=device-width, initial-scale=1'>",
             "<title>agentbus watch v2: the frames</title><style>" + CSS + "</style></head><body>",
             "<header class=top><h1><span class=bus>🚌 agentbus</span> watch v2: every frame</h1>",
             "<p>The proposal for issue #7, for the owner's sign-off. Each state is drawn at 100x30 and 60x20, with "
             "emoji and without. Colours are the frames' own SGR codes on a dark terminal. Tick NO_COLOR to see "
             "exactly what a no-colour terminal shows: the same text, with nothing lost. Generated by "
             "<code>docs/design/watch_v2_mock.py</code> from the same data as the golden files; the text "
             "is in <code>docs/design/watch-v2.md</code>.</p></header>",
             "<input type=checkbox id=nocolor hidden><input type=checkbox id=noemoji hidden>"
             "<input type=checkbox id=emojionly hidden><input type=checkbox id=hidesmall hidden>"
             "<input type=checkbox id=hidelarge hidden>",
             "<div class=toggles><label for=nocolor>NO_COLOR</label><label for=noemoji>hide emoji frames</label>"
             "<label for=emojionly>hide no-emoji frames</label><label for=hidesmall>hide 60x20</label>"
             "<label for=hidelarge>hide 100x30</label></div>",
             "<main>"]
    doc = DOC.read_text()
    dec = doc.split("## Decisions for the owner\n", 1)[1].split("\n## ", 1)[0]
    items = [re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", md_inline(l.split(". ", 1)[1]))
             for l in dec.splitlines() if re.match(r"^\d+\. ", l)]
    parts.append("<h2>Decisions for the owner</h2><p class=blurb>One at a time, recommended answer first.</p>"
                 "<ol class=decisions>" + "".join(f"<li>{i}</li>" for i in items) + "</ol>")
    keymap = doc.split("## 3. Key map\n", 1)[1].split("\n## ", 1)[0]
    trs = [l for l in keymap.splitlines() if l.startswith("|") and not l.startswith("|---")]
    cells = [[md_inline(c.strip()) for c in l.strip("|").split(" | ")] for l in trs]
    parts.append("<h2>Key map</h2><table class=keys>" + "<tr>" + "".join(f"<th>{c}</th>" for c in cells[0]) + "</tr>"
                 + "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in cells[1:]) + "</table>")
    parts.append("<h2>Colours</h2><p class=blurb>Every meaning is also in the text, so NO_COLOR loses nothing.</p><div>")
    for label, cls in (("header bar 1;30;43", "b c30 bg43"), ("section title 1", "b"), ("secondary 2", "d"),
                       ("goal mark 1;33", "b c33"), ("selected row 7", "rv"), ("alert, error 31", "c31"),
                       ("paused, stale, busy 33", "c33"), ("handoff 33", "c33"), ("question 35", "c35"),
                       ("answer 36", "c36"), ("done 32", "c32"), ("decision 34", "c34"),
                       ("agents 34 36 35 32 33 94 96 95", "c34")):
        parts.append(f"<span class=sw><span class='{cls}'>{html.escape(label)}</span></span>")
    parts.append("</div>")
    for name, title, blurb, view, snap, live in STATES:
        parts.append(f"<h2 id='{name}'>{html.escape(title)} <code>{name}</code></h2><p class=blurb>{md_inline(blurb)}</p>")
        for cols, rows in ((100, 30), (60, 20)):
            parts.append("<div class=row>")
            for emoji in (True, False):
                fr = Frame(cols, rows if live else 999, emoji, view, SNAPSHOTS[snap], WHERE, T_DT, live=live).render()
                if not live:
                    while fr and not fr[-1].text.strip():
                        fr.pop()
                body = "\n".join(html_row(r, cols - 1) for r in fr)
                cls = ("emoji-on" if emoji else "emoji-off") + (" s100" if cols == 100 else " s60")
                cap = f"{name} {cols}x{len(fr)} {'emoji' if emoji else 'no emoji'}"
                parts.append(f"<figure class='{cls}'><figcaption>{cap}</figcaption>"
                             f"<pre class=term><span class=dots><b></b><b></b><b></b></span>{body}</pre></figure>")
            parts.append("</div>")
    fr = Frame(39, 8, False, {}, SAMPLE, WHERE, T_DT).render()
    parts.append("<h2 id=too-narrow>Under 40 columns <code>too-narrow</code></h2><div class=row><figure>"
                 "<figcaption>too-narrow 39x8</figcaption><pre class=term><span class=dots><b></b><b></b><b></b></span>"
                 + "\n".join(html_row(r, 38) for r in fr) + "</pre></figure></div>")
    parts.append("</main></body></html>\n")
    return "".join(parts)


def artifacts():
    files = {}
    fx = fixture()
    files[GOLDEN / "fixture.json"] = json.dumps(fx, indent=1, ensure_ascii=False) + "\n"
    for e in fx["goldens"]:
        files[GOLDEN / (e["name"] + ".txt")] = golden_text(frame_for(e))
    files[DOC] = fill_doc(DOC.read_text())
    files[HTML_OUT] = build_html()
    return files


def main():
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
