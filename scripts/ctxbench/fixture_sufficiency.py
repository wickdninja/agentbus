#!/usr/bin/env python3
"""ctxbench sufficiency fixtures (docs/evals/ctxbench-protocol.md, "Sufficiency fixtures").

Builds small hand-derived histories with the real CLI, one process per simulated timestamp (AGENTBUS_TEST_NOW), renders
the same semantic events as a raw COORDINATION.md ledger, and runs every registered procedure of every arm on a fresh
copy. Each arm's reference parser gets ONLY the text its procedure returned (plus the probe's own inputs: me, now, X, Y)
and must produce the hand-derived answer, or None where the protocol registers a structural miss.

  F1 (N1): two histories that differ only in when bob left; alice's takeable set (P4) is {1} vs {1, 2}.
  F2 (Codex finding 4): two histories that differ only in the genuine decision's continuation-line subject, with a later
     note quoting a decision header; P5 must give (1, parser) vs (1, uploader).
  F3: claims (expired, at the expiry boundary, taken over), questions and todos; P1, P2, P3, P6.
  Parity: after a takeover, the bus's messages (including the generated alert) equal the ledger's message lines.

It computes no study numbers. Stdlib only, Python 3.9+.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AWK_DIR = os.path.join(ROOT, "scripts", "ctxbench", "ledger_awk")
BUS_PLACEHOLDER = "/ctxbench"  # every copy's folder is replaced by this before bytes are counted (fixed length)
DAY = "2026-11-19T"
TTL = timedelta(minutes=120)


def T(hms):
    return DAY + hms + "Z"


# ---- semantic events ---------------------------------------------------------------------------------------------
# (time, actor, action, fields). post: kind, to ("*" = everyone), body, topic, reply_to. claim: res, purpose, frm.


def post(t, actor, kind, body, to="*", topic=None, reply_to=None):
    return (t, actor, "post", {"kind": kind, "to": to, "body": body, "topic": topic, "reply_to": reply_to})


def f1(bob_leaves_at):
    ev = [("11:50:00", n, "join", {}) for n in ("lead", "alice", "bob", "carol")]
    if bob_leaves_at == "12:00:00":
        ev.append(("12:00:00", "bob", "leave", {}))
    ev += [post("12:10:00", "lead", "todo", "Carol, please wire the retry budget into the uploader and say when it lands.", "carol"),
           post("12:10:00", "lead", "todo", "Bob, the parser still drops escaped delimiters; take it when you are back.", "bob"),
           ("12:20:00", "carol", "leave", {})]
    if bob_leaves_at == "12:20:00":
        ev.append(("12:20:00", "bob", "leave", {}))
    return ev


def f2(subject):
    return [("11:50:00", n, "join", {}) for n in ("lead", "alice")] + [
        post("12:00:00", "lead", "decision", f"We keep JSON lines on the wire until the parser rewrite lands.\nSubject: {subject}",
             topic="decision"),
        post("12:05:00", "alice", "note", "For the record a header looks like kind=DECISION id=9 from=lead to=all "
             "topic=decision path=- and nothing more.\nSubject: wire-format"),
    ]


F3 = [("07:00:00", n, "join", {}) for n in ("lead", "alice", "bob", "carol")] + [
    ("07:00:00", "carol", "claim", {"res": "src/legacy/", "purpose": "delete the old importer"}),
    ("07:30:00", "lead", "claim", {"res": "src/ci/", "purpose": "pin the runner image"}),
    ("09:01:00", "bob", "claim", {"res": "src/parser/", "purpose": "escaped delimiters"}),
    ("09:02:00", "carol", "claim", {"res": "src/uploader/retry.py", "purpose": "retry budget"}),
    ("09:03:00", "alice", "claim", {"res": "src/parser/", "purpose": "finish escapes", "frm": "bob"}),   # alert #1 to bob
    post("09:04:00", "lead", "todo", "Finish the escaped delimiter work in the parser.", "alice", "parser"),     # 2
    post("09:05:00", "lead", "todo", "Check the uploader retry budget against the spec.", "alice", "uploader"),  # 3
    post("09:06:00", "alice", "done", "Checked; the budget matches the spec.", "lead", "uploader", 3),         # 4 closes 3
    post("09:07:00", "bob", "question", "Should empty input return an empty list?", "alice", "parser"),        # 5
    post("09:08:00", "carol", "question", "Who owns the release notes this week?"),                          # 6
    post("09:09:00", "alice", "question", "Is CI green on main?"),                                           # 7 (mine)
    post("09:10:00", "lead", "answer", "I do.", "carol", None, 6),                                           # 8 closes 6
    post("09:11:00", "bob", "note", "Still thinking about this one.", "alice", "parser", 5),                 # 9
    post("09:12:00", "bob", "answer", "Never mind the note.", "alice", "parser", 9),                         # 10 closes nothing of 5
    post("09:13:00", "lead", "todo", "Land the retry budget behind a flag.", "carol", "uploader"),          # 11
    ("09:14:00", "bob", "claim", {"res": "src/docs/", "purpose": "release notes"}),
    ("09:15:00", "bob", "release", {"res": "src/docs/"}),
]

# Each case: (name, events, checkpoint, me, probe, inputs, expected per arm). Expected None = a registered miss.
ALL = ("bus-default", "bus-complete", "ledger-raw", "ledger-awk")


def same(ans):
    return {a: ans for a in ALL}


CASES = []
for h, at, want in (("F1-A", "12:00:00", {1}), ("F1-B", "12:20:00", {1, 2})):
    CASES.append((h, f1(at), T("12:30:00"), "alice", "P4", {}, dict(same(want), **{"bus-default": None})))
for h, subj in (("F2-A", "parser"), ("F2-B", "uploader")):
    CASES.append((h, f2(subj), T("12:30:00"), "alice", "P5", {}, same((1, subj))))
F3_NOW = T("09:30:00")  # src/ci/ expires exactly now: not live (D5)
for probe, inputs, want in (
        ("P1", {}, {2}),
        ("P3", {}, {5}),
        ("P2", {"x": "src/parser/lexer.py"}, {"alice"}),
        ("P2", {"x": "src/uploader/"}, {"carol"}),
        ("P2", {"x": "src/legacy/old.py"}, set()),
        ("P2", {"x": "src/ci/run.sh"}, set()),
        ("P6", {"y": "uploader"}, {"carol"}),
        ("P6", {"y": "parser"}, {"alice"}),
        ("P6", {"y": "docs"}, set())):
    CASES.append(("F3", F3, F3_NOW, "alice", probe, inputs, same(want)))

# ---- running the CLI ---------------------------------------------------------------------------------------------


class Runner:
    def __init__(self, cli, tmp):
        self.cli = cli
        self.cwd = os.path.join(tmp, "cwd")  # outside any repo, so discovery never walks to a live bus
        home = os.path.join(tmp, "home")
        os.makedirs(home, exist_ok=True)
        os.makedirs(self.cwd, exist_ok=True)
        base = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
        for k in ("CLAUDECODE", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_PID"):
            base.pop(k, None)
        base.update(HOME=home, TZ="UTC", LC_ALL="C", COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1",
                    AGENTBUS_NO_UPDATE_CHECK="1", AGENTBUS_NO_UPDATE_NOTICE="1")
        self.base = base

    def bus(self, db, at, *args):
        """One CLI process at simulated time `at` (the clock rule: a fresh process per timestamp)."""
        env = dict(self.base, AGENTBUS_DB=db, AGENTBUS_TEST_NOW=at)
        r = subprocess.run(self.cli + [str(x) for x in args], env=env, cwd=self.cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
        if r.returncode != 0:
            raise SystemExit(f"FAIL: agentbus {' '.join(map(str, args))} exited {r.returncode}: {r.stderr.strip()}")
        return r.stdout

    def sh(self, cwd, command):
        r = subprocess.run(["sh", "-c", command], env=self.base, cwd=cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
        if r.returncode not in (0, 1):  # grep exits 1 on no match: an empty answer, not an error
            raise SystemExit(f"FAIL: {command} exited {r.returncode}: {r.stderr.strip()}")
        return r.stdout


def build_bus(run, bus_dir, events):
    os.makedirs(bus_dir)
    db = os.path.join(bus_dir, "bus.db")
    for t, actor, action, f in events:
        at = T(t)
        if action in ("join", "leave"):
            run.bus(db, at, "--as", actor, action)
        elif action == "post":
            args = ["--as", actor, "post", f["body"], "--kind", f["kind"]]
            if f["to"] != "*":
                args += ["--to", f["to"]]
            if f.get("topic"):
                args += ["--topic", f["topic"]]
            if f.get("reply_to") is not None:
                args += ["--reply-to", f["reply_to"]]
            run.bus(db, at, *args)
        elif action == "claim":
            args = ["--as", actor, "claim", f["res"], "--purpose", f["purpose"]]
            if f.get("frm"):
                args += ["--from", f["frm"]]
            run.bus(db, at, *args)
        elif action == "release":
            run.bus(db, at, "--as", actor, "release", f["res"])
        else:
            raise SystemExit(f"FAIL: unknown fixture action {action}")
    # Read-back check from the clock rule: every stored message time is the simulated one.
    want = [T(t) for t, _, a, f in events if a == "post" or (a == "claim" and f.get("frm"))]
    got = [m["ts"] for m in json.loads(run.bus(db, T("23:59:00"), "--json", "read", "--limit", "-1"))["items"]]
    if got != want:
        raise SystemExit(f"FAIL: replay stamped {got}, simulated {want}")
    return db


# ---- the raw ledger (docs/evals/ctxbench-protocol.md, "Ledger-raw file format") ----------------------------------

def enc(v):
    """A metadata value: '-' when absent, else percent-encoded so it holds no space, '|', '%', '=' or newline."""
    if v is None or v == "":
        return "-"
    return "".join(c if c not in " |%\n\r\t=" else "%%%02X" % ord(c) for c in str(v))


def ledger_line(eid, ts, kind, item, frm, to, topic, path, reply_to, text):
    head = (f"- eid=E{eid} ts={ts} kind={kind} id={enc(item)} from={enc(frm)} to={enc(to)} "
            f"topic={enc(topic)} path={enc(path)} reply_to={enc(reply_to)} |")
    lines = str(text).split("\n")
    return "\n".join([head + (" " + lines[0] if lines[0] else "")] + ["  " + x for x in lines[1:]])


LEDGER_HEADER = ("# COORDINATION.md\n\nAppend-only. One event per line; continuation lines of a body are indented two spaces.\n"
                 "Fields: eid ts kind id from to topic path reply_to | text. '-' means none; to=all is a broadcast.\n"
                 "A claim lasts 120 minutes from its CLAIM or TAKEOVER line unless renewed.\n\n")


def takeover_alert(name, res, purpose):
    """The alert the bus sends the former holder on claim --from (one resource, one holder)."""
    why = f'purpose: "{purpose}"' if purpose else "no purpose given"
    return f"{name} took your claim on {res} with claim --from and now holds {res} ({why})."


def render_ledger(path, events):
    """Render from the semantic events alone: message ids are counted here (posts and generated alerts), never read
    from the bus; the parity check compares the two."""
    out, eid, mid, held = [LEDGER_HEADER], 0, 0, {}

    def add(*a):
        nonlocal eid
        eid += 1
        out.append(ledger_line(eid, *a))

    for t, actor, action, f in events:
        ts = T(t)
        if action == "join":
            add(ts, "JOIN", None, actor, None, None, None, None, "")
        elif action == "leave":
            for res in sorted(r for r, h in held.items() if h == actor):
                add(ts, "RELEASE", None, actor, None, None, res, None, "")
                del held[res]
            add(ts, "LEAVE", None, actor, None, None, None, None, "")
        elif action == "claim":
            if f.get("frm"):
                add(ts, "TAKEOVER", None, actor, f["frm"], None, f["res"], None, f["purpose"])
                mid += 1
                add(ts, "ALERT", mid, actor, f["frm"], "claim", None, None, takeover_alert(actor, f["res"], f["purpose"]))
            else:
                add(ts, "CLAIM", None, actor, None, None, f["res"], None, f["purpose"])
            held[f["res"]] = actor
        elif action == "release":
            add(ts, "RELEASE", None, actor, None, None, f["res"], None, "")
            held.pop(f["res"], None)
        elif action == "post":
            mid += 1
            to = "all" if f["to"] == "*" else f["to"]
            add(ts, f["kind"].upper(), mid, actor, to, f.get("topic"), None, f.get("reply_to"), f["body"])
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")


def ledger_messages(text):
    """(id, kind, from, to, topic, reply_to, body) of every message line, bodies joined: for the parity check."""
    msgs, cur = [], None
    for line in text.splitlines():
        m = re.match(r"^- eid=E\d+ ts=\S+ kind=([A-Z]+) id=(\S+) from=(\S+) to=(\S+) topic=(\S+) path=\S+ reply_to=(\S+) \| ?(.*)$", line)
        if m:
            cur = None
            k, i, f, t, tp, r, body = m.groups()
            if k.lower() in ("note", "question", "answer", "handoff", "decision", "alert", "done", "todo", "dropped"):
                cur = [int(i), k.lower(), f, "*" if t == "all" else t, None if tp == "-" else tp,
                       None if r == "-" else int(r), body]
                msgs.append(cur)
        elif cur is not None and line.startswith("  "):
            cur[6] += "\n" + line[2:]
    return [tuple(m) for m in msgs]


# ---- registered procedures ---------------------------------------------------------------------------------------
# Bus commands are CLI words after `agentbus`; ledger commands run under sh in the copy's folder. They must match the
# command table in docs/evals/ctxbench-protocol.md.

HEAD = "'^- eid=E[0-9]+ ts=[^ ]+ kind={} '"
GREP = "grep -n -E 'kind=({})( |$)' COORDINATION.md | cut -d'|' -f1"
P5_GREP = ("grep -n -E '^- eid=E[0-9]+ ts=[^ ]+ kind=DECISION id=[^ ]+ from=[^ ]+ to=[^ ]+ topic=decision ' "
           "COORDINATION.md | cut -d'|' -f1 | tail -n 1")
P5_EXPAND = "awk -v L={} 'NR==L{{p=1; print; next}} p && /^- eid=/{{exit}} p{{print}}' COORDINATION.md"
P5_OLD = ["grep -n -E 'kind=DECISION .* topic=decision ' COORDINATION.md",  # v1, replaced (Codex finding 4)
          "awk -v L={} 'NR==L{{p=1; print; next}} p && /^- eid=/{{exit}} p{{print}}' COORDINATION.md"]

LEDGER_RAW = {
    "P1": [GREP.format("TODO|DONE|DROPPED")],
    "P2": [GREP.format("CLAIM|TAKEOVER|RELEASE|LEAVE")],
    "P3": [GREP.format("QUESTION|ANSWER")],
    "P4": [GREP.format("TODO|DONE|DROPPED|JOIN|LEAVE")],
    "P6": [GREP.format("CLAIM|TAKEOVER|RELEASE|JOIN|LEAVE|TODO|DONE|DROPPED")],
}


def awk_cmd(probe, **kv):
    flags = " ".join(f"-v {k}={v}" for k, v in kv.items())
    return f"awk {flags} -f '{AWK_DIR}/common.awk' -f '{AWK_DIR}/{probe.lower()}.awk' COORDINATION.md"


def run_bus_default(run, db, me, probe):
    cmds = [["--as", me, "--json", "brief"], ["--as", me, "--json", "inbox", "--limit", "20", "--peek"]]
    if probe == "P5":
        cmds.append(["--as", me, "--json", "read", "--topic", "decision"])
    return cmds


def run_bus_complete(run, db, me, now, probe):
    """Bus-complete is adaptive only where registered: P5 reads the newest decision whole when its body was cut."""
    brief = ["--as", me, "--json", "brief", "--limit", "-1"]
    if probe in ("P1", "P3"):
        return [brief]
    if probe == "P4":
        return [brief, ["--as", me, "--json", "log", "show", "--limit", "-1"]]
    if probe == "P2":
        return [["--as", me, "--json", "claims", "--limit", "-1"]]
    if probe == "P6":
        return [["--as", me, "--json", "claims", "--limit", "-1"], brief]
    if probe == "P5":
        return [["--as", me, "--json", "read", "--topic", "decision", "--limit", "-1"]]
    raise SystemExit(f"FAIL: no Bus-complete procedure for {probe}")


def execute(run, arm, probe, copy, me, now, inputs):
    """Run an arm's registered procedure; returns the list of returned texts (bus path normalised)."""
    if arm.startswith("bus-"):
        db = os.path.join(copy, "bus.db")
        call = lambda c: run.bus(db, now, *c).replace(copy, BUS_PLACEHOLDER)
        cmds = run_bus_default(run, db, me, probe) if arm == "bus-default" else run_bus_complete(run, db, me, now, probe)
        texts = [call(c) for c in cmds]
        if arm == "bus-complete" and probe == "P5":
            items = [m for m in json.loads(texts[0])["items"] if m["kind"] == "decision"]
            if items:
                newest = max(items, key=lambda m: m["id"])
                if newest.get("body_truncated"):
                    texts.append(call(["--as", me, "--json", "read", "--id", newest["id"]]))
        return texts
    if arm == "ledger-raw":
        if probe == "P5":
            first = run.sh(copy, P5_GREP)
            m = re.match(r"^(\d+):", first)
            return [first] + ([run.sh(copy, P5_EXPAND.format(m.group(1)))] if m else [])
        return [run.sh(copy, c) for c in LEDGER_RAW[probe]]
    if arm == "ledger-awk":
        kv = {"P1": {"me": me}, "P3": {"me": me}, "P4": {"me": me}, "P5": {},
              "P2": {"x": inputs.get("x"), "now": now}, "P6": {"y": inputs.get("y"), "now": now}}[probe]
        return [run.sh(copy, awk_cmd(probe, **kv))]
    raise SystemExit(f"FAIL: unknown arm {arm}")


# ---- reference parsers: only the returned text and the probe's inputs ----------------------------------------------

def overlaps(a, b):
    a, b = a.rstrip("/"), b.rstrip("/")
    return a == b or b.startswith(a + "/") or a.startswith(b + "/")


def subject_of(body):
    last = body.rstrip("\n").split("\n")[-1]
    return last[len("Subject: "):] if last.startswith("Subject: ") else None


def parse_bus(arm, probe, texts, me, now, inputs):
    """Bus-default and Bus-complete share field logic; completeness is checked per evidence source the probe uses."""
    if probe == "P5":
        items = [m for m in json.loads(texts[-1] if arm == "bus-default" else texts[0])["items"] if m["kind"] == "decision"]
        if not items:
            return None if json.loads(texts[0 if arm == "bus-complete" else -1])["has_more"] else (None, None)
        newest = max(items, key=lambda m: m["id"])
        if newest.get("body_truncated"):
            if arm == "bus-default" or len(texts) < 2:
                return None  # the subject was cut away
            newest = json.loads(texts[1])
        return (newest["id"], subject_of(newest["body"]))
    if probe in ("P2", "P6") and arm == "bus-complete":
        claims = json.loads(texts[0])
        if claims["has_more"]:
            return None
        live = [(c["agent"], c["resource"]) for c in claims["items"] if c["expires_at"] > now]  # by time, not `state`
    elif probe in ("P2", "P6"):
        brief = json.loads(texts[0])
        if brief["omitted"]["agents"] or any(a["claims_omitted"] for a in brief["agents"]["items"]):
            return None
        live = [(a["name"], c["resource"]) for a in brief["agents"]["items"] for c in a["claims"] if c["expires_at"] > now]
    if probe == "P2":
        return {h for h, r in live if overlaps(r, inputs["x"])}
    brief = json.loads(texts[-1] if (arm == "bus-complete" and probe == "P6") else texts[0])
    if probe == "P6":
        if brief["omitted"]["todos"]:
            return None
        y = inputs["y"]
        return ({h for h, r in live if overlaps(r, "src/" + y + "/")}
                | {t["owner"] for t in brief["todos"]["items"] if t["topic"] == y and t["owner_on_roster"]})
    if probe == "P1":
        return None if brief["omitted"]["todos"] else {t["id"] for t in brief["todos"]["items"] if t["owner"] == me}
    if probe == "P3":
        return None if brief["omitted"]["questions"] else {q["id"] for q in brief["questions"]["items"] if q["sender"] != me}
    if probe == "P4":
        if brief["omitted"]["todos"]:
            return None
        leaves = None
        if arm == "bus-complete":
            logs = json.loads(texts[1])
            if logs["has_more"]:
                return None
            leaves = [(e["agent"], e["ts"]) for e in logs["items"] if e["action"] == "leave"]
        take = set()
        for t in brief["todos"]["items"]:
            if t["owner"] == me:
                take.add(t["id"])
            elif not t["owner_on_roster"]:
                if leaves is None:
                    return None  # Bus-default has no leave times: an off-roster owner's todo cannot be decided
                if any(a == t["owner"] and ts >= t["ts"] for a, ts in leaves):
                    take.add(t["id"])
        return take
    raise SystemExit(f"FAIL: no bus parser for {probe}")


HEADER = re.compile(r"^\d+:- eid=E\d+ ts=(\S+) kind=([A-Z]+) id=(\S+) from=(\S+) to=(\S+) topic=(\S+) path=(\S+) reply_to=(\S+)")


def ledger_rows(text):
    for raw in text.splitlines():
        m = HEADER.match(raw)
        if m:
            yield m.groups()


def epoch(ts):
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def parse_ledger_raw(probe, texts, me, now, inputs):
    if probe == "P5":
        m = HEADER.match(texts[0].strip()) if texts[0].strip() else None
        if not m:
            return (None, None)
        body = re.sub(r"^[^|]*\| ?", "", texts[1].split("\n", 1)[0])
        rest = [x[2:] for x in texts[1].split("\n")[1:] if x.startswith("  ")]
        return (int(m.group(3)), subject_of("\n".join([body] + rest)))
    todos, closed, questions, answered, roster, leaves, holder = {}, set(), {}, set(), set(), [], {}
    for ts, kind, item, frm, to, topic, path, reply_to in ledger_rows(texts[0]):
        if kind == "TODO":
            todos[int(item)] = (ts, frm if to == "all" else to, topic)
        elif kind in ("DONE", "DROPPED") and reply_to != "-":
            closed.add(int(reply_to))
        elif kind == "QUESTION":
            questions[int(item)] = (frm, to)
        elif kind == "ANSWER" and reply_to != "-":
            answered.add(int(reply_to))
        elif kind == "JOIN":
            roster.add(frm)
        elif kind == "LEAVE":
            roster.discard(frm)
            leaves.append((frm, ts))
        elif kind in ("CLAIM", "TAKEOVER"):
            holder[path] = (frm, epoch(ts) + TTL)
        elif kind == "RELEASE" and holder.get(path, ("",))[0] == frm:
            del holder[path]
    live = [(h, p) for p, (h, until) in holder.items() if until > epoch(now)]
    open_todos = {i: v for i, v in todos.items() if i not in closed}
    if probe == "P1":
        return {i for i, (_, o, _) in open_todos.items() if o == me}
    if probe == "P3":
        return {i for i, (f, t) in questions.items() if i not in answered and t in (me, "all") and f != me}
    if probe == "P4":
        return {i for i, (ts, o, _) in open_todos.items()
                if o == me or (o not in roster and any(a == o and lt >= ts for a, lt in leaves))}
    if probe == "P2":
        return {h for h, p in live if overlaps(p, inputs["x"])}
    if probe == "P6":
        y = inputs["y"]
        return {h for h, p in live if overlaps(p, "src/" + y + "/")} | {o for _, o, tp in open_todos.values() if tp == y and o in roster}
    raise SystemExit(f"FAIL: no ledger-raw parser for {probe}")


def parse_ledger_awk(probe, texts, me, now, inputs):
    lines = texts[0].split("\n")
    if probe == "P5":
        w = lines[0].split(" ", 2)
        return (None, None) if w[1] == "none" else (int(w[1]), w[2] if len(w) > 2 else None)
    vals = [x.split(" ", 1)[1] for x in lines if x]
    return {int(x) for x in vals} if probe in ("P1", "P3", "P4") else set(vals)


def parse(arm, probe, texts, me, now, inputs):
    if arm.startswith("bus-"):
        return parse_bus(arm, probe, texts, me, now, inputs)
    return (parse_ledger_raw if arm == "ledger-raw" else parse_ledger_awk)(probe, texts, me, now, inputs)

# ---- the fixtures ------------------------------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cli", help="the command that runs agentbus, split on whitespace (default: this Python and bin/agentbus)")
    args = ap.parse_args()
    cli = args.cli.split() if args.cli else [sys.executable, os.path.join(ROOT, "bin", "agentbus")]
    tmp = tempfile.mkdtemp(prefix="ctxbench-fixture.")
    n_copy = 0
    try:
        run = Runner(cli, tmp)
        built = {}
        for name, events, *_ in CASES:
            if name in built:
                continue
            bus_dir = os.path.join(tmp, name, "bus")
            build_bus(run, bus_dir, events)
            led_dir = os.path.join(tmp, name, "ledger")
            os.makedirs(led_dir)
            render_ledger(os.path.join(led_dir, "COORDINATION.md"), events)
            built[name] = (bus_dir, led_dir)
            # parity: the bus's messages (generated alerts included) equal the ledger's message lines
            bus_msgs = [(m["id"], m["kind"], m["sender"], m["recipient"], m["topic"], m["reply_to"], m["body"])
                        for m in json.loads(run.bus(os.path.join(bus_dir, "bus.db"), T("23:59:00"), "--json", "read", "--limit", "-1"))["items"]]
            with open(os.path.join(led_dir, "COORDINATION.md")) as fh:
                led_msgs = ledger_messages(fh.read())
            if bus_msgs != led_msgs:
                raise SystemExit(f"FAIL: {name}: bus and ledger messages differ:\n{bus_msgs}\n{led_msgs}")
        print(f"PASS: bus and ledger hold the same messages in every fixture, the takeover alert included ({len(built)} histories)")

        texts = {}
        for name, _, now, me, probe, inputs, want in CASES:
            for arm in ALL:
                n_copy += 1
                src = built[name][0 if arm.startswith("bus-") else 1]
                copy = os.path.join(tmp, "copies", str(n_copy))  # a fresh copy per probe and arm
                shutil.copytree(src, copy)
                out = execute(run, arm, probe, copy, me, now, inputs)
                got = parse(arm, probe, out, me, now, inputs)
                if got != want[arm]:
                    raise SystemExit(f"FAIL: {name} {probe} {inputs} {arm}: derived {got!r}, expected {want[arm]!r}\n"
                                     + "\n---\n".join(out))
                texts[(name, probe, json.dumps(inputs), arm)] = out
        print(f"PASS: every arm's parser derives the hand-derived answer, or the registered miss, from its own text "
              f"({len(CASES)} cases x {len(ALL)} arms)")

        # F1: Bus-default's text is the same for both histories, so its miss is structural, not a parser weakness
        if texts[("F1-A", "P4", "{}", "bus-default")] != texts[("F1-B", "P4", "{}", "bus-default")]:
            raise SystemExit("FAIL: F1 Bus-default text differs between the histories; the documented gap has changed")
        # F1: the leave evidence decides it: without log show (bus) or LEAVE lines (ledger) the histories read the same
        if texts[("F1-A", "P4", "{}", "bus-complete")][0] != texts[("F1-B", "P4", "{}", "bus-complete")][0]:
            raise SystemExit("FAIL: F1 brief --json alone differs; log show is no longer the only evidence")
        strip = lambda s: re.sub(r"(?m)^\d+:- eid=E\d+ ", "- ", s)
        a, b = (strip(run.sh(built[h][1], GREP.format("TODO|DONE|DROPPED"))) for h in ("F1-A", "F1-B"))
        if a != b:
            raise SystemExit("FAIL: F1 the ledger's TODO lines differ; LEAVE lines are no longer the only evidence")
        print("PASS: F1 Bus-default reads the same for both histories; without leave evidence every arm does")

        # F2: the v1 Ledger-raw P5 recipe (unanchored grep, expand the last hit) cannot tell the histories apart
        old = []
        for h in ("F2-A", "F2-B"):
            first = run.sh(built[h][1], P5_OLD[0])
            line = first.strip().split("\n")[-1].split(":", 1)[0]
            old.append((first, run.sh(built[h][1], P5_OLD[1].format(line))))
        if old[0] != old[1]:
            raise SystemExit("FAIL: F2 the v1 P5 recipe now distinguishes the histories; the fixture no longer tests anchoring")
        print("PASS: F2 the unanchored v1 P5 recipe returns identical text for both histories; the anchored one does not")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("ctxbench sufficiency fixture: all checks passed")


if __name__ == "__main__":
    main()
