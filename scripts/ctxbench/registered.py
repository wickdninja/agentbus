"""ctxbench Stage 1: everything docs/evals/ctxbench-protocol.md registers as code.

The ledger renderer, the four arms' procedures, the output cap and completeness adapter, every reference parser
(P1 to P7), the generator's choice rules, the reader-time check and the descriptive report. B-M1 imports this module;
it does not rewrite it. A change here after merge is a registration repair: a new failing fixture and a dated Change
log entry. Stdlib only, Python 3.9+.
"""
import json
import os
import re
import sqlite3
import statistics
import subprocess
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
AWK_DIR = os.path.join(HERE, "ledger_awk")
DATA_DIR = os.path.join(HERE, "data")
BUS_PLACEHOLDER = "/ctxbench"   # every copy's folder is replaced by this before bytes are counted (fixed length)
CAP = 30000                     # characters per call, the capped report
CAP_MARKER = "\n[ctxbench: output cut at 30000 characters]\n"
TTL = timedelta(minutes=120)
GUARD = timedelta(seconds=120)  # no claim may expire in (now, now + GUARD]
ARMS = ("bus-default", "bus-complete", "ledger-raw", "ledger-awk")


class ReplayDefect(Exception):
    """A replay or reader-time defect: the protocol reruns every arm of the seed."""


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(ts):
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


# ---- running commands --------------------------------------------------------------------------------------------

class Runner:
    """Runs the CLI one process per simulated second, and ledger commands under sh. A measured reader command must
    finish within one second of starting (the bracket that proves its clock stayed on the registered second), else
    ReplayDefect."""

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

    def bus(self, db, at, *args, measured=False):
        env = dict(self.base, AGENTBUS_DB=db, AGENTBUS_TEST_NOW=at)
        start = time.monotonic()
        r = subprocess.run(self.cli + [str(x) for x in args], env=env, cwd=self.cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
        if measured and time.monotonic() - start >= 1.0:
            raise ReplayDefect(f"agentbus {' '.join(map(str, args))} took over a second; its clock may have left {at}")
        if r.returncode != 0:
            raise SystemExit(f"FAIL: agentbus {' '.join(map(str, args))} exited {r.returncode}: {r.stderr.strip()}")
        return r.stdout

    def sh(self, cwd, command):
        r = subprocess.run(["sh", "-c", command], env=self.base, cwd=cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
        if r.returncode not in (0, 1):  # grep exits 1 on no match: an empty answer, not an error
            raise SystemExit(f"FAIL: {command} exited {r.returncode}: {r.stderr.strip()}")
        return r.stdout


# ---- replay of semantic events -------------------------------------------------------------------------------------
# An event is (iso_time, actor, action, fields). post: kind, to ("*" = everyone), body, topic, reply_to.
# claim: res, purpose, frm (a takeover). release: res. join, leave, inbox (a consuming read): no fields.

def apply_event(run, db, ev):
    at, actor, action, f = ev
    if action in ("join", "leave", "inbox"):
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
        raise SystemExit(f"FAIL: unknown action {action}")


def check_stored_times(db, events):
    """Every stored time is a simulated event time: messages in order, every log row, claims (expiry = start + TTL),
    last_seen and facts. A mismatch is a replay defect."""
    times = {e[0] for e in events}
    con = sqlite3.connect(db)
    try:
        want = [e[0] for e in events if e[2] == "post" or (e[2] == "claim" and e[3].get("frm"))]
        got = [r[0] for r in con.execute("SELECT ts FROM messages ORDER BY id")]
        if got != want:
            raise ReplayDefect(f"messages stamped {got}, simulated {want}")
        for (ts,) in con.execute("SELECT ts FROM log"):
            if ts not in times:
                raise ReplayDefect(f"log row stamped {ts}, not a simulated time")
        for start, until in con.execute("SELECT claimed_at, expires_at FROM claims"):
            if start not in times or until != iso(parse_ts(start) + TTL):
                raise ReplayDefect(f"claim stamped {start} until {until}")
        for (ts,) in con.execute("SELECT last_seen FROM agents"):
            if ts not in times:
                raise ReplayDefect(f"last_seen {ts} is not a simulated time")
        for (ts,) in con.execute("SELECT updated_at FROM context"):
            if ts not in times:
                raise ReplayDefect(f"fact stamped {ts}")
    finally:
        con.close()


def build_bus(run, bus_dir, events):
    os.makedirs(bus_dir, exist_ok=True)
    db = os.path.join(bus_dir, "bus.db")
    for ev in events:
        apply_event(run, db, ev)
    check_stored_times(db, events)
    return db


# ---- the raw ledger ----------------------------------------------------------------------------------------------

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


def render_ledger(events):
    """The ledger text from the semantic events alone: message ids are counted here (posts and generated alerts), never
    read from the bus. Rendering a prefix of the events gives a prefix of the file (append-only)."""
    out, eid, mid, held = [LEDGER_HEADER], 0, 0, {}

    def add(*a):
        nonlocal eid
        eid += 1
        out.append(ledger_line(eid, *a))

    for ts, actor, action, f in events:
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
        # inbox (a consuming read) writes nothing to the ledger
    return "\n".join(out) + "\n"


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


# ---- procedures --------------------------------------------------------------------------------------------------
# A call is (source, kind, command): kind "bus" (CLI words after `agentbus`) or "sh" (run in the copy's folder).
# `source` names the evidence; a probe's parser requires only its own sources (REQUIRED).

GREP = "grep -n -E 'kind=({})( |$)' COORDINATION.md | cut -d'|' -f1"
P5_GREP = ("grep -n -E '^- eid=E[0-9]+ ts=[^ ]+ kind=DECISION id=[^ ]+ from=[^ ]+ to=[^ ]+ topic=decision ' "
           "COORDINATION.md | cut -d'|' -f1 | tail -n 1")
P5_EXPAND = "awk -v L={} 'NR==L{{p=1; print; next}} p && /^- eid=/{{exit}} p{{print}}' COORDINATION.md"
P5_V1 = "grep -n -E 'kind=DECISION .* topic=decision ' COORDINATION.md"  # not registered (fixture F2)
P7_KINDS = "TODO|DONE|DROPPED|QUESTION|ANSWER|JOIN|LEAVE"
LEDGER_RAW = {
    "P1": GREP.format("TODO|DONE|DROPPED"),
    "P2": GREP.format("CLAIM|TAKEOVER|RELEASE|LEAVE"),
    "P3": GREP.format("QUESTION|ANSWER"),
    "P4": GREP.format("TODO|DONE|DROPPED|JOIN|LEAVE"),
    "P6": GREP.format("CLAIM|TAKEOVER|RELEASE|JOIN|LEAVE|TODO|DONE|DROPPED"),
}

REQUIRED = {
    "bus-default": {"P1": {"brief"}, "P2": {"brief"}, "P3": {"brief"}, "P4": {"brief"}, "P5": {"decisions"},
                    "P6": {"brief"}},
    "bus-complete": {"P1": {"brief"}, "P2": {"claims"}, "P3": {"brief"}, "P4": {"brief", "log"},
                     "P5": {"decisions", "whole"}, "P6": {"claims", "brief"}},
}


def awk_cmd(probe, **kv):
    flags = " ".join(f"-v {k}={v}" for k, v in kv.items())
    return f"awk {flags} -f '{AWK_DIR}/common.awk' -f '{AWK_DIR}/{probe.lower()}.awk' COORDINATION.md"


def static_calls(arm, probe, me, now, inputs):
    """The calls of a probe that do not depend on earlier output (all but P5's second call)."""
    if arm == "bus-default":
        calls = [("brief", "bus", ["--as", me, "--json", "brief"]),
                 ("inbox", "bus", ["--as", me, "--json", "inbox", "--limit", "20", "--peek"])]
        if probe == "P5":
            calls.append(("decisions", "bus", ["--as", me, "--json", "read", "--topic", "decision"]))
        return calls
    if arm == "bus-complete":
        brief = ("brief", "bus", ["--as", me, "--json", "brief", "--limit", "-1"])
        claims = ("claims", "bus", ["--as", me, "--json", "claims", "--limit", "-1"])
        return {"P1": [brief], "P3": [brief], "P2": [claims], "P6": [claims, brief],
                "P4": [brief, ("log", "bus", ["--as", me, "--json", "log", "show", "--limit", "-1"])],
                "P5": [("decisions", "bus", ["--as", me, "--json", "read", "--topic", "decision", "--limit", "-1"])]}[probe]
    if arm == "ledger-raw":
        return [("decisions", "sh", P5_GREP)] if probe == "P5" else [("rows", "sh", LEDGER_RAW[probe])]
    if arm == "ledger-awk":
        kv = {"P1": {"me": me}, "P3": {"me": me}, "P4": {"me": me}, "P5": {},
              "P2": {"x": inputs.get("x"), "now": now}, "P6": {"y": inputs.get("y"), "now": now}}[probe]
        return [("answer", "sh", awk_cmd(probe, **kv))]
    raise SystemExit(f"FAIL: unknown arm {arm}")


def deliver(text, cap):
    """(delivered text, cut). cap None = uncapped. A cut output keeps its first `cap` characters and the marker line."""
    if cap is None or len(text) <= cap:
        return text, False
    return text[:cap] + CAP_MARKER, True


class Delivery:
    """What one procedure delivered: per call (source, text, cut), and the byte total the measure counts."""

    def __init__(self):
        self.calls = []

    def add(self, source, text, cut):
        self.calls.append((source, text, cut))

    def get(self, source):
        hits = [c for c in self.calls if c[0] == source]
        return hits[-1] if hits else None

    @property
    def bytes(self):
        return sum(len(t.encode("utf-8")) for _, t, _ in self.calls)

    @property
    def texts(self):
        return [t for _, t, _ in self.calls]


def execute(run, arm, probe, copy, me, now, inputs, cap=None):
    """Run an arm's registered procedure on a copy; returns a Delivery. `cap`: None, an int, or {source: int}
    (fixtures only). P5's second call is decided from delivered evidence alone: a cut first output makes no second call."""
    cap_of = (lambda s: cap.get(s)) if isinstance(cap, dict) else (lambda s: cap)
    d = Delivery()

    def call(source, kind, cmd):
        if kind == "bus":
            raw = run.bus(os.path.join(copy, "bus.db"), now, *cmd, measured=True).replace(copy, BUS_PLACEHOLDER)
        else:
            raw = run.sh(copy, cmd)
        text, cut = deliver(raw, cap_of(source))
        d.add(source, text, cut)
        return text, cut

    for source, kind, cmd in static_calls(arm, probe, me, now, inputs):
        call(source, kind, cmd)
    if probe == "P5" and arm == "bus-complete":
        _, text, cut = d.get("decisions")
        if not cut:
            items = [m for m in json.loads(text)["items"] if m["kind"] == "decision"]
            if items:
                newest = max(items, key=lambda m: m["id"])
                if newest.get("body_truncated"):
                    call("whole", "bus", ["--as", me, "--json", "read", "--id", newest["id"]])
    if probe == "P5" and arm == "ledger-raw":
        _, text, cut = d.get("decisions")
        m = re.match(r"^(\d+):", text)
        if m and not cut:
            call("record", "sh", P5_EXPAND.format(m.group(1)))
    return d


# ---- reference parsers -------------------------------------------------------------------------------------------
# A parser sees only the Delivery and the probe's inputs. It returns the answer, or CANNOT (the registered parser cannot
# decide from this evidence). The adapter (answer()) returns CANNOT before any parsing when a required source was cut.

CANNOT = "cannot-decide"


def overlaps(a, b):
    a, b = a.rstrip("/"), b.rstrip("/")
    return a == b or b.startswith(a + "/") or a.startswith(b + "/")


def subject_of(body):
    last = body.rstrip("\n").split("\n")[-1]
    return last[len("Subject: "):] if last.startswith("Subject: ") else None


def _j(d, source):
    return json.loads(d.get(source)[1])


def parse_bus(arm, probe, d, me, now, inputs):
    if probe == "P5":
        page = _j(d, "decisions")
        items = [m for m in page["items"] if m["kind"] == "decision"]
        if not items:
            return CANNOT if page["has_more"] else (None, None)
        newest = max(items, key=lambda m: m["id"])
        if newest.get("body_truncated"):
            whole = d.get("whole")
            if whole is None:
                return CANNOT  # the subject was cut away and this arm reads no whole body
            newest = json.loads(whole[1])
        return (newest["id"], subject_of(newest["body"]))
    live = None
    if probe in ("P2", "P6"):
        if arm == "bus-complete":
            claims = _j(d, "claims")
            if claims["has_more"]:
                return CANNOT
            live = [(c["agent"], c["resource"]) for c in claims["items"] if c["expires_at"] > now]  # by time, not state
        else:
            b = _j(d, "brief")
            if b["omitted"]["agents"] or any(a["claims_omitted"] for a in b["agents"]["items"]):
                return CANNOT
            live = [(a["name"], c["resource"]) for a in b["agents"]["items"] for c in a["claims"] if c["expires_at"] > now]
    if probe == "P2":
        return {h for h, r in live if overlaps(r, inputs["x"])}
    brief = _j(d, "brief")
    if probe == "P6":
        if brief["omitted"]["todos"]:
            return CANNOT
        y = inputs["y"]
        return ({h for h, r in live if overlaps(r, "src/" + y + "/")}
                | {t["owner"] for t in brief["todos"]["items"] if t["topic"] == y and t["owner_on_roster"]})
    if probe == "P1":
        return CANNOT if brief["omitted"]["todos"] else {t["id"] for t in brief["todos"]["items"] if t["owner"] == me}
    if probe == "P3":
        return CANNOT if brief["omitted"]["questions"] else {q["id"] for q in brief["questions"]["items"] if q["sender"] != me}
    if probe == "P4":
        if brief["omitted"]["todos"]:
            return CANNOT
        leaves = None
        if arm == "bus-complete":
            logs = _j(d, "log")
            if logs["has_more"]:
                return CANNOT
            leaves = [(e["agent"], e["ts"]) for e in logs["items"] if e["action"] == "leave"]
        take = set()
        for t in brief["todos"]["items"]:
            if t["owner"] == me:
                take.add(t["id"])
            elif not t["owner_on_roster"]:
                if leaves is None:
                    return CANNOT  # no leave times; `next` is not used as evidence (protocol, "Bus-default and next")
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


def fold_rows(rows, probe, me, now, inputs):
    todos, closed, questions, answered, roster, leaves, holder = {}, set(), {}, set(), set(), [], {}
    for ts, kind, item, frm, to, topic, path, reply_to in rows:
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
            holder[path] = (frm, parse_ts(ts) + TTL)
        elif kind == "RELEASE" and holder.get(path, ("",))[0] == frm:
            del holder[path]
    live = [(h, p) for p, (h, until) in holder.items() if until > parse_ts(now)]
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


def parse_ledger_raw(probe, d, me, now, inputs):
    if probe == "P5":
        first = d.get("decisions")[1].strip()
        if not first:
            return (None, None)
        m = HEADER.match(first)
        rec = d.get("record")
        if not m or rec is None:
            return CANNOT
        lines = rec[1].split("\n")
        body = re.sub(r"^[^|]*\| ?", "", lines[0])
        rest = [x[2:] for x in lines[1:] if x.startswith("  ")]
        return (int(m.group(3)), subject_of("\n".join([body] + rest)))
    return fold_rows(ledger_rows(d.get("rows")[1]), probe, me, now, inputs)


def parse_ledger_awk(probe, d, me, now, inputs):
    lines = [x for x in d.get("answer")[1].split("\n") if x]
    if probe == "P5":
        w = lines[0].split(" ", 2)
        return (None, None) if w[1] == "none" else (int(w[1]), w[2] if len(w) > 2 else None)
    vals = [x.split(" ", 1)[1] for x in lines]
    return {int(x) for x in vals} if probe in ("P1", "P3", "P4") else set(vals)


def answer(arm, probe, d, me, now, inputs):
    """The adapter: a cut source this probe requires makes it CANNOT before parsing (so cut JSON never reaches
    json.loads); a cut source it does not use changes nothing. Ledger arms require every call they made."""
    required = REQUIRED.get(arm, {}).get(probe)
    for source, _, cut in d.calls:
        if cut and (required is None or source in required):
            return CANNOT
    if arm.startswith("bus-"):
        return parse_bus(arm, probe, d, me, now, inputs)
    return (parse_ledger_raw if arm == "ledger-raw" else parse_ledger_awk)(probe, d, me, now, inputs)


# ---- P7: a session of three refreshes ------------------------------------------------------------------------------

class Session:
    """One P7 session on one copy. refresh() runs the arm's per-refresh procedure and returns (Delivery, answer triple
    (P1, P3, P4) with CANNOT in any slot the parser could not decide). Ledger-raw keeps a private line cursor and its
    folded rows between refreshes."""

    def __init__(self, run, arm, copy, me):
        self.run, self.arm, self.copy, self.me = run, arm, copy, me
        self.rows, self.lines_read = [], 0

    def refresh(self, now, cap=None):
        me, arm, d = self.me, self.arm, Delivery()

        def put(source, raw):
            text, cut = deliver(raw, cap)
            d.add(source, text, cut)
            return text, cut

        if arm.startswith("bus-"):
            db = os.path.join(self.copy, "bus.db")
            b = lambda *c: self.run.bus(db, now, *c, measured=True).replace(self.copy, BUS_PLACEHOLDER)
            if arm == "bus-default":
                put("brief", b("--as", me, "--json", "brief"))
                put("inbox", b("--as", me, "--json", "inbox", "--limit", "20"))  # consuming, as the skill says
            else:
                put("brief", b("--as", me, "--json", "brief", "--limit", "-1"))
                put("log", b("--as", me, "--json", "log", "show", "--limit", "-1"))
            req = {"P1": {"brief"}, "P3": {"brief"}, "P4": {"brief"} if arm == "bus-default" else {"brief", "log"}}
            triple = []
            for p in ("P1", "P3", "P4"):
                cut = any(c for s, _, c in d.calls if s in req[p])
                triple.append(CANNOT if cut else parse_bus(arm, p, d, me, now, {}))
            return d, tuple(triple)
        if arm == "ledger-awk":
            for p in ("p1", "p3", "p4"):
                put(p, self.run.sh(self.copy, awk_cmd(p, me=me)))
            triple = []
            for p in ("p1", "p3", "p4"):
                _, text, cut = d.get(p)
                vals = {int(x.split(" ", 1)[1]) for x in text.split("\n") if x}
                triple.append(CANNOT if cut else vals)
            return d, tuple(triple)
        # ledger-raw
        n_text, _ = put("count", self.run.sh(self.copy, "wc -l < COORDINATION.md"))
        n = int(n_text.strip())
        if self.lines_read == 0:
            text, cut = put("rows", self.run.sh(self.copy, GREP.format(P7_KINDS)))
        else:
            cmd = (f"sed -n '{self.lines_read + 1},{n}p' COORDINATION.md | grep -n -E 'kind=({P7_KINDS})( |$)' "
                   f"| cut -d'|' -f1")
            text, cut = put("rows", self.run.sh(self.copy, cmd))
        self.lines_read = n
        if cut:
            self.rows = None  # a cut refresh loses rows for good: every later refresh of this session is CANNOT
        if self.rows is None:
            return d, (CANNOT, CANNOT, CANNOT)
        self.rows += list(ledger_rows(text))
        return d, tuple(fold_rows(self.rows, p, me, now, {}) for p in ("P1", "P3", "P4"))


# ---- generator choice rules (sim.py calls these; it does not re-implement them) ----------------------------------

MIXES = {  # share of E, per cent, in this order
    "sparse": {"note": 30, "question": 5, "answer": 4, "decision": 3, "alert": 1, "handoff": 2, "todo": 8, "done": 6,
               "dropped": 1, "claim": 18, "release": 14, "fact": 5, "join": 2, "leave": 1},
    "busy": {"note": 20, "question": 10, "answer": 8, "decision": 4, "alert": 3, "handoff": 4, "todo": 12, "done": 9,
             "dropped": 2, "claim": 14, "release": 10, "fact": 2, "join": 1, "leave": 1},
    "handoff-heavy": {"note": 12, "question": 8, "answer": 7, "decision": 3, "alert": 1, "handoff": 14, "todo": 16,
                      "done": 10, "dropped": 3, "claim": 12, "release": 8, "fact": 2, "join": 2, "leave": 2},
}
FOLDER_SHARE = 0.3
REDRAWS = 10


def load_list(name):
    with open(os.path.join(DATA_DIR, name)) as fh:
        return [x for x in fh.read().split("\n") if x]


def name_at(i):
    """The i-th name (0-based) of the never-exhausted pool: the 40 names, then the same with suffix 2, 3, ..."""
    names = load_list("names.txt")
    k, r = divmod(i, len(names))
    return names[r] + (str(k + 1) if k else "")


def draw_type(rng, mix):
    u, acc = rng.random() * 100, 0
    for kind, share in MIXES[mix].items():
        acc += share
        if u < acc:
            return kind
    return "leave"


def draw_event(rng, mix, eligible_actors, live):
    """(type, actor). The type is drawn from the mix; the actor uniformly among the agents for which that type is
    eligible (eligible_actors(type) -> set). An empty set redraws the type (and so the actor), up to REDRAWS times;
    then a note by a uniformly drawn live agent."""
    for _ in range(1 + REDRAWS):
        kind = draw_type(rng, mix)
        actors = sorted(eligible_actors(kind))
        if actors:
            return kind, rng.choice(actors)
    return "note", rng.choice(sorted(live))


def item_resources(item, files=4):
    return [f"src/{item}/"] + [f"src/{item}/f{n}.py" for n in range(1, files + 1)]


def choose_new_resource(rng, items, live_claims):
    """A new claim's resource: the folder sort with probability FOLDER_SHARE, else the file sort; uniformly among the
    free resources of that sort (overlapping no live claim), else of the other sort; None when nothing is free."""
    def free(res):
        return not any(overlaps(res, c) for c in live_claims)
    folders = [r for i in items for r in item_resources(i)[:1] if free(r)]
    files = [r for i in items for r in item_resources(i)[1:] if free(r)]
    first, second = (folders, files) if rng.random() < FOLDER_SHARE else (files, folders)
    pool = first or second
    return rng.choice(pool) if pool else None


def p2_target(rng, live_claims, items):
    """X for P2: one uniform draw u first; u < 0.5 and any live claim: a file the claim covers (the claimed file, or a
    uniform file of a claimed folder); otherwise a uniform file of any item (also when no claim is live)."""
    u = rng.random()
    if u < 0.5 and live_claims:
        c = rng.choice(sorted(live_claims))
        if c.endswith("/"):
            return rng.choice(item_resources(c[len("src/"):-1])[1:])
        return c
    return rng.choice([r for i in items for r in item_resources(i)[1:]])


def p6_target(rng, active_items, items):
    """Y for P6: u < 0.5 and any active item: a uniform active item; otherwise a uniform item (also when none is active)."""
    u = rng.random()
    if u < 0.5 and active_items:
        return rng.choice(sorted(active_items))
    return rng.choice(list(items))


def guard_ok(now, claim_expiries):
    """No claim expires in (now, now + GUARD]."""
    t = parse_ts(now)
    return not any(t < parse_ts(e) <= t + GUARD for e in claim_expiries)


def checkpoint_now(ts_c, u0, claim_expiries):
    """P1 to P6: now = time of event c plus u seconds, u scanned from u0 through 300 then 1 to u0-1, the first u for
    which the guard holds; None when none does (the instance moves to the next checkpoint index)."""
    base = parse_ts(ts_c)
    for u in list(range(u0, 301)) + list(range(1, u0)):
        now = iso(base + timedelta(seconds=u))
        if guard_ok(now, claim_expiries):
            return now
    return None


def next_index(c, lo, hi):
    """The checkpoint index after c in the registered scan: c+1, wrapping from hi to lo."""
    return lo if c >= hi else c + 1


def p7_pick(rng, c0, lo, hi, candidates_at):
    """P7: scan checkpoint indexes from c0 (next_index order, each at most once); at the first c whose candidate set is
    non-empty (candidates_at(c): agents live at c and at c+20 with no leave or crash in c+1..c+20, and the guard holds at
    all three refresh times), me = a uniform candidate. None when no index qualifies (reported as a count)."""
    c = c0
    for _ in range(hi - lo + 1):
        cands = sorted(candidates_at(c))
        if cands:
            return c, rng.choice(cands)
        c = next_index(c, lo, hi)
    return None


# ---- the descriptive report --------------------------------------------------------------------------------------

def describe(values):
    """Median, quartiles (statistics.quantiles, method 'inclusive'), min and max of per-seed values."""
    v = sorted(values)
    q = statistics.quantiles(v, n=4, method="inclusive") if len(v) > 1 else [v[0]] * 3
    return {"median": statistics.median(v), "q1": q[0], "q3": q[2], "min": v[0], "max": v[-1]}


def ratio(num, den):
    """A ratio, or 'n/a: empty' with both values when the denominator is zero (never imputed)."""
    if den == 0:
        return f"n/a: empty (numerator {num}, denominator {den})"
    return num / den


def cell_report(per_seed_bytes, outcomes):
    """per_seed_bytes: {arm: [mean delivered bytes per seed]}; outcomes: {arm: [[outcome per instance] per seed]}, an
    outcome being 'ok', 'cannot' or 'wrong'. Returns the registered descriptive summary for one cell."""
    rep = {"bytes": {a: describe(v) for a, v in per_seed_bytes.items()}, "ratios": {}, "derivability": {}}
    for bus in ("bus-default", "bus-complete"):
        for led in ("ledger-raw", "ledger-awk"):
            if bus in per_seed_bytes and led in per_seed_bytes:
                n, m = per_seed_bytes[bus], per_seed_bytes[led]
                rep["ratios"][f"{bus}/{led}"] = {"ratio_of_medians": ratio(statistics.median(n), statistics.median(m)),
                                                 "ratio_of_sums": ratio(sum(n), sum(m))}
    for a, seeds in outcomes.items():
        flat = [o for s in seeds for o in s]
        rep["derivability"][a] = {"derivable": flat.count("ok"), "run": len(flat), "cannot_decide": flat.count("cannot"),
                                  "wrong": flat.count("wrong"), "seeds_with_any_miss": sum(any(o != "ok" for o in s) for s in seeds),
                                  "seeds": len(seeds)}
    return rep
