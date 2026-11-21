#!/usr/bin/env python3
"""The W1 storyboard frames (issue 89): watch opens on what needs the owner.

  python3 storyboard/capture/w1.py

Seeds real buses with the real bin/agentbus (in a throwaway HOME), reads each one with watch's own
watch_snapshot(), and draws two kinds of frame from that snapshot:

  today: the frame today's watch draws (bin/agentbus render(), unchanged).
  w1:    the W1 design, drawn by W1Frame below. It subclasses watch's own _Frame and reuses its header,
         goal row, message rows, footer and painting, so widths, glyphs and colours are the real ones.
         Only the top of the overview is new: Needs you, Working now, and the line for other buses.

Writes storyboard/frames/w1.js: window.CAPTURED (today) and window.MOCKED (W1), the shapes term.js draws.
Nothing outside the mktemp -d directory is touched.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(REPO, "bin", "agentbus")
OUT = os.path.join(REPO, "storyboard", "frames", "w1.js")
NOW = "2026-11-21T15:30:00Z"
OWNER = "nate"
WHERE = "~/src/app"

ROOT = tempfile.mkdtemp(prefix="agentbus-w1-")
HOME = os.path.join(ROOT, "home")
APP = os.path.join(HOME, "src", "app")


def env_for(now):
    env = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_") and k not in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDECODE")}
    env.update(HOME=HOME, TMPDIR=os.path.join(ROOT, "tmp"), AGENTBUS_NO_UPDATE_CHECK="1", AGENTBUS_TEST_NOW=now,
               TZ="UTC", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", AGENTBUS_DB=os.path.join(APP, ".agentbus", "bus.db"))
    return env


def ab(now, *args):
    p = subprocess.run([sys.executable, BIN, *args], env=env_for(now), cwd=APP, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    if p.returncode:
        raise SystemExit(f"agentbus {' '.join(args)}: {p.stdout}")
    return p.stdout


def at(minutes_ago):
    from datetime import datetime, timedelta, timezone
    t = datetime.strptime(NOW, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) - timedelta(minutes=minutes_ago)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


os.environ["AGENTBUS_TEST_NOW"] = NOW
os.environ["TZ"] = "UTC"
_loader = importlib.machinery.SourceFileLoader("agentbus_w1", BIN)
_spec = importlib.util.spec_from_loader("agentbus_w1", _loader)
T = importlib.util.module_from_spec(_spec)
_loader.exec_module(T)
Row, fit, text_width, ago, _when = T.Row, T.fit, T.text_width, T.ago, T._when


# ------------------------------------------------------------------ the buses

def fresh_bus():
    shutil.rmtree(os.path.join(APP, ".agentbus"), ignore_errors=True)
    os.makedirs(APP, exist_ok=True)
    os.makedirs(os.path.join(ROOT, "tmp"), exist_ok=True)
    ab(at(90), "init", ".")


def team(start=60):
    """Three agents on the auth move; the owner has joined, as a person who answers does."""
    ab(at(start), "--as", "lead", "join", "--role", "planner")
    ab(at(start), "--as", "worker", "join", "--role", "implementer", "--tool", "codex")
    ab(at(start), "--as", "tests", "join", "--role", "tester")
    ab(at(start), "--as", OWNER, "join", "--role", "owner")
    ab(at(start - 1), "--as", "lead", "goal", "Move auth to the new token API")
    ab(at(start - 2), "--as", "lead", "post", "Move src/auth/ onto the new token API.", "--to", "worker", "--kind", "handoff")
    ab(at(30), "--as", "worker", "claim", "src/auth/", "--purpose", "token refactor")
    ab(at(29), "--as", "tests", "claim", "tests/auth/", "--purpose", "token tests")
    ab(at(25), "--as", "lead", "claim", "docs/auth.md", "--purpose", "rewrite the auth guide")
    ab(at(start - 36), "--as", "tests", "post", "Is the 401 body part of the contract?", "--to", "worker", "--kind", "question")
    ab(at(start - 37), "--as", "worker", "post", "Plain text for now.", "--to", "tests", "--kind", "answer", "--reply-to", "2")


def mail_for_owner():
    """Two things only the owner can settle. Returns their ids."""
    q = ab(at(12), "--as", "tests", "post", "Should an expired token get 401 or 403? The old API sent 403.",
           "--to", OWNER, "--kind", "question", "--json")
    ab(at(8), "--as", "worker", "post", "Token refresh is in; 41 of 41 auth tests pass.", "--to", "lead", "--kind", "note")
    h = ab(at(3), "--as", "worker", "post", "Auth is moved and tests pass. Over to you for review before I merge.",
           "--to", OWNER, "--kind", "handoff", "--json")
    ab(at(1), "--as", "lead", "post", "Docs next: I am rewriting docs/auth.md.", "--kind", "note")
    seen_all()
    return json.loads(q)["id"], json.loads(h)["id"]


def seen_all():
    for name in ("lead", "worker", "tests"):
        ab(at(1), "--as", name, "inbox", "--peek")


def snapshot():
    return T.watch_snapshot(os.path.join(APP, ".agentbus", "bus.db"), False, 200, body_head=T.BODY_HEAD)


# ------------------------------------------------------------------ the W1 frame

ACCENT = "1;33"     # the bus yellow, bold: the one accent (header bar, Needs you, its keys)
DONE = "32"         # green only where it means it worked: "copied"
VERB = {"question": "asks", "handoff": "hands off"}


def open_for(snap, owner):
    """Questions and handoffs to the owner that the owner has not replied to, oldest first.
    A question closes with his answer; a handoff closes with any reply from him."""
    msgs = snap["messages"]
    replied = {m["reply_to"] for m in msgs if m["sender"] == owner and m["reply_to"] is not None}
    answered = {m["reply_to"] for m in msgs if m["kind"] == "answer" and m["reply_to"] is not None}
    out = [m for m in msgs if m["recipient"] == owner and m["kind"] in VERB and m["id"] not in replied
           and not (m["kind"] == "question" and m["id"] in answered)]
    return sorted(out, key=lambda m: m["id"])


class W1Frame(T._Frame):
    """The overview with Needs you and Working now on top. Everything below them is today's watch."""

    def __init__(self, *a, owner=OWNER, others=(), copied=None, show=4, **k):
        super().__init__(*a, **k)
        self.owner, self.others, self.copied_id, self.show = owner, list(others), copied, show
        self.me = owner

    # Needs you -------------------------------------------------------------

    def need_row(self, key, m):
        W, E = self.W, self.E
        emo = (T.KIND_EMOJI[m["kind"]] + " ") if E else ""
        sw = 10 if self.wide else 8
        vw = 10
        age = ago(m["ts"], self.t)
        old = (self.t - _when(m["ts"])).total_seconds() >= 3600
        body_w = W - 2 - 1 - 2 - text_width(emo) - sw - 1 - vw - 1 - 5
        body = self.fit(str(m["body"]).split("\n")[0], body_w).rstrip()
        row = Row(("  ", ""), (key, ACCENT), ("  ", ""), (emo, ""), (self.fit(m["sender"], sw), self.ac(m["sender"])),
                  (" ", ""), (self.fit(VERB[m["kind"]], vw), "2"), (" ", ""), (body, ""))
        row.add(" " * (W - row.width - text_width(age)))
        row.add(age, "1" if old else "2")
        return row

    def copied_rows(self, m):
        cmd = T.reply_command(m, self.owner, self.up)
        lead = "     "
        one = Row((lead, ""), ("copied", DONE), ("  ", ""), (cmd, ""))
        if one.width <= self.W:
            return [one]
        return [Row((lead, ""), ("copied", DONE)), Row((lead, ""), (self.cut(cmd, self.W - len(lead)), ""))]

    def others_row(self):
        if not self.others:
            return []
        row = Row(("  Also waiting for you: ", "2"))
        for i, (where, n) in enumerate(self.others):
            if i:
                row.add(self.tx(" · "), "2")
            row.add(where, "")
            row.add(f" {n}", ACCENT)
        if row.width > self.W:  # narrow: the count of buses and items, one line
            total = sum(n for _, n in self.others)
            row = Row(("  Also waiting for you: ", "2"), (f"{total} on {T._plural(len(self.others), 'other bus')}", ""))
        return [row]

    def needs_block(self, items):
        out = []
        if not items:
            out.append(Row(("  Nothing needs you. ", "1"), (f"{T._plural(len(self.working()), 'agent')} working.", "1")))
            return out + self.others_row()
        oldest = ago(items[0]["ts"], self.t)
        head = Row(("🙋 " if self.E else "", ""), ("Needs you", ACCENT), (f"  {len(items)}", "2"))
        out.append(T._first_fit(head, [f"waiting longest {oldest}", f"oldest {oldest}", ""], self.W, "2"))
        shown = items[:self.show] if len(items) > self.show + 1 else items
        for i, m in enumerate(shown, 1):
            out.append(self.need_row(str(i) if i <= 9 else " ", m))
            if self.copied_id == m["id"]:
                out += self.copied_rows(m)
        rest = len(items) - len(shown)
        if rest:
            out.append(self.more_row(f"   … {rest} more waiting · Tab, then j/k to see them"))
        if self.copied_id is None:
            keys = "1" if len(shown) == 1 else f"1 or {len(shown)}" if len(shown) == 2 else f"1 to {len(shown)}"
            out.append(Row(("     ", ""), (keys, "1"), (" copies the reply. Paste it in a terminal and type your answer.", "2")))
        return out + self.others_row()

    # Working now -----------------------------------------------------------

    def working(self):
        return sorted({c["agent"] for c in self.snap["claims"] if c["agent"] != self.owner})

    def work_row(self, c):
        W, E = self.W, self.E
        a = self.find_agent(c["agent"]) or {"role": "", "last_seen": None}
        nw, rw = (12, max(14, min(28, W // 4))) if self.wide else (10, 14)
        seen = ago(a["last_seen"], self.t)
        row = Row(("  ", ""), (self.g["on"] if not self.idle(a) else self.g["off"], self.ac(c["agent"])))
        if E:
            row.add(" " + T.role_emoji(a["role"]))
        row.add(" ")
        row.add(self.fit(c["agent"], nw), self.ac(c["agent"]))
        row.add(" ")
        pw = W - row.width - 1 - rw - 1 - 5
        row.add(self.fit(c["purpose"] or "", pw), "")
        row.add(" ")
        row.add(self.fit(c["resource"], rw), "2")
        row.add(seen.rjust(5), "2")
        return row

    def working_block(self, room):
        claims = [c for c in sorted(self.snap["claims"], key=lambda c: c["agent"]) if c["agent"] != self.owner]
        if not claims:
            return [Row(("🔨 " if self.E else "", ""), ("Working now", "1"), ("  0", "2")),
                    Row(("  nobody is holding any files right now", "2"))]
        out = [Row(("🔨 " if self.E else "", ""), ("Working now", "1"), (f"  {len(self.working())}", "2"))]
        rows_ = [self.work_row(c) for c in claims]
        if len(rows_) > room:
            out += rows_[:max(1, room - 1)]
            out.append(self.more_row(f"… {len(rows_) - max(1, room - 1)} more"))
        else:
            out += rows_
        return out

    # The whole overview ----------------------------------------------------

    def summary(self):
        n = len(open_for(self.snap, self.owner))
        elsewhere = sum(k for _, k in self.others)
        text = (f"{n} need you" if n else "nothing needs you")
        if elsewhere:
            text += f" · {elsewhere} elsewhere"
        return text

    def overview(self):
        items = open_for(self.snap, self.owner)
        out = [self.header(self.summary(), None), self.goal_row(), Row()]
        out += self.needs_block(items)
        out.append(Row())
        out += self.working_block(4 if self.rows >= 30 else 3)
        out.append(Row())
        msgs = self.snap["messages"]
        rows_ = [self.msg_row(m) for m in msgs]
        share = max(1, self.rows - 1 - len(out) - 1)
        out += self.messages_block(msgs, msgs, rows_, None, self.snap["counts"]["messages"],
                                   self.snap["counts"]["messages"] > len(msgs), False, share, False)
        body = out[:self.rows - 1]
        while len(body) < self.rows - 1:
            body.append(Row())
        return body + [self.w1_footer(items)]

    def w1_footer(self, items):
        if self.copied_id is not None:
            return Row(("  Copied. Paste it in a terminal and type your answer between the quotes.", ""))
        n = min(len(items), self.show if len(items) > self.show + 1 else len(items), 9)
        keys = [("Enter", "open", 50), ("Tab", "section", 30), ("/", "filter", 40), ("?", "help", 90), ("q", "quit", 100)]
        if n:
            keys.insert(0, ("1" if n == 1 else f"1-{n}", "copy reply", 95))
        return self.footer(keys)


# ------------------------------------------------------------------ drawing

CAPTURED, MOCKED = {}, {}


def ansi(rows):
    return "\x1b[2J\x1b[H" + "\r\n".join(r + "\x1b[K" for r in rows) + "\x1b[J"


def paint(colour=True):
    return T.Paint(colour, emoji=True, ascii=False)


def t_now():
    return _when(NOW)


def today(fid, snap, cols, rows, note):
    v = T.View()
    out = T.render(v, snap, WHERE, (cols, rows), t_now(), paint())
    CAPTURED[fid] = {"cols": cols, "rows": rows, "cmd": "agentbus watch", "source": "captured", "ansi": ansi(out), "note": note}


def w1(fid, snap, cols, rows, note, **kw):
    v = T.View()
    v.me = OWNER
    v.focus = "messages"
    f = W1Frame(cols, rows, paint(), v, snap, WHERE, t_now(), live=True, **kw)
    out = [r.painted(paint()) for r in f.render()]
    cmd = f"AGENTBUS_OWNER={OWNER} agentbus watch"
    MOCKED[fid] = {"cols": cols, "rows": rows, "cmd": cmd, "source": "mocked", "ansi": ansi(out), "note": note}
    return out


def main():
    try:
        # (2) needs you: a question and a handoff to the owner
        fresh_bus()
        team()
        q, h = mail_for_owner()
        s = snapshot()
        assert [m["id"] for m in open_for(s, OWNER)] == [q, h], open_for(s, OWNER)
        for cols, rows in ((100, 30), (80, 24)):
            today(f"needs-{cols}", s, cols, rows, "today: the question sits in the stream")
            w1(f"needs-{cols}", s, cols, rows, "two things wait for you")
            w1(f"copied-{cols}", s, cols, rows, "you pressed 1", copied=q)
            w1(f"others-{cols}", s, cols, rows, "two other buses wait for you",
               others=[("~/src/hub", 1), ("~/src/kidmath", 2)])

        # (1) nothing needs you: the owner answered both
        ab(at(0), "--as", OWNER, "post", "401, with a WWW-Authenticate header.", "--to", "tests", "--reply-to", str(q), "--kind", "answer")
        ab(at(0), "--as", OWNER, "post", "Reviewed. Merge it.", "--to", "worker", "--reply-to", str(h), "--kind", "answer")
        seen_all()
        s = snapshot()
        assert not open_for(s, OWNER)
        for cols, rows in ((100, 30), (80, 24)):
            today(f"calm-{cols}", s, cols, rows, "today")
            w1(f"calm-{cols}", s, cols, rows, "nothing waits for you")
            w1(f"calm-others-{cols}", s, cols, rows, "nothing here, but another bus waits", others=[("~/src/hub", 1)])

        # (3) many: nine things wait, the oldest three hours
        fresh_bus()
        team(start=240)
        ask = [(190, "tests", "question", "The staging token issuer is down. Wait for it, or test against a local issuer?"),
               (130, "lead", "question", "Keep the old /v1/token route for one release, or remove it now?"),
               (75, "worker", "handoff", "Session cookie rename is ready. Over to you to approve the migration note."),
               (52, "tests", "question", "Can I drop the flaky Safari login test? It fails 1 run in 12."),
               (40, "lead", "question", "Who owns the rate limit numbers, you or the platform team?"),
               (21, "worker", "question", "Rotate the signing key now, or with the release?"),
               (14, "tests", "handoff", "Load test results are in docs/load.md. Yours to sign off."),
               (6, "lead", "question", "Ship the docs today, or wait for the review?"),
               (2, "worker", "question", "The old SDK breaks on the new error body. Bump its major version?")]
        for mins, who, kind, body in ask:
            ab(at(mins), "--as", who, "post", body, "--to", OWNER, "--kind", kind)
        ab(at(1), "--as", "lead", "post", "Docs next: I am rewriting docs/auth.md.", "--kind", "note")
        seen_all()
        s = snapshot()
        assert len(open_for(s, OWNER)) == 9
        for cols, rows in ((100, 30), (80, 24)):
            today(f"many-{cols}", s, cols, rows, "today")
            w1(f"many-{cols}", s, cols, rows, "nine wait; the four oldest show")
    finally:
        shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("// Generated by storyboard/capture/w1.py from the real bin/agentbus. Do not edit.\n")
        f.write("window.CAPTURED = " + json.dumps(CAPTURED, indent=1, ensure_ascii=False) + ";\n")
        f.write("window.MOCKED = " + json.dumps(MOCKED, indent=1, ensure_ascii=False) + ";\n")
    print(f"wrote {len(CAPTURED)} today frames and {len(MOCKED)} W1 frames to {os.path.relpath(OUT, REPO)}")


if __name__ == "__main__":
    main()
