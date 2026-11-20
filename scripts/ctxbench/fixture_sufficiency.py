#!/usr/bin/env python3
"""ctxbench sufficiency fixture (docs/evals/ctxbench-protocol.md, "Sufficiency fixture").

Two histories that differ only in when bob left (12:00 or 12:20; the todos are posted at 12:10). alice's takeable set
(probe P4) is {1} in history A and {1, 2} in history B. This script builds both histories with the real CLI, one process
per simulated timestamp (AGENTBUS_TEST_NOW), renders the same events as a raw COORDINATION.md ledger, then runs every
registered P4 procedure on a fresh copy and gives a reference parser ONLY the text that procedure returned.

It asserts:
  1. every registered Bus-complete and Ledger-raw procedure derives {1} from A and {1, 2} from B;
  2. Bus-default (brief, inbox --peek, read at default limits) returns the same text for A and B, so no parser can
     derive both answers from it (the documented gap);
  3. the evidence that makes the difference is necessary: without `log show` (bus) or the LEAVE lines (ledger) the
     two histories return the same text.

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

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DAY = "2026-11-19T"
CHECKPOINT = DAY + "12:30:00Z"
ME = "alice"
EXPECTED = {"A": {1}, "B": {1, 2}}

# ---- the two histories -------------------------------------------------------------------------------------------
# (time, actor, action, fields). post fields: kind, to, body. Bob's leave is the only difference.


def history(bob_leaves_at):
    ev = [("11:50:00", n, "join", {}) for n in ("lead", ME, "bob", "carol")]
    if bob_leaves_at == "12:00:00":
        ev.append(("12:00:00", "bob", "leave", {}))
    ev += [
        ("12:10:00", "lead", "post", {"kind": "todo", "to": "carol",
                                      "body": "Carol, please wire the retry budget into the uploader and say when it lands."}),
        ("12:10:00", "lead", "post", {"kind": "todo", "to": "bob",
                                      "body": "Bob, the parser still drops escaped delimiters; take it when you are back."}),
        ("12:20:00", "carol", "leave", {}),
    ]
    if bob_leaves_at == "12:20:00":
        ev.append(("12:20:00", "bob", "leave", {}))
    return ev


HISTORIES = {"A": history("12:00:00"), "B": history("12:20:00")}

# ---- running the CLI ---------------------------------------------------------------------------------------------


class Runner:
    def __init__(self, cli, tmp):
        self.cli = cli
        self.home = os.path.join(tmp, "home")
        self.cwd = os.path.join(tmp, "cwd")  # outside any repo, so discovery never walks to a live bus
        os.makedirs(self.home, exist_ok=True)
        os.makedirs(self.cwd, exist_ok=True)
        base = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
        for k in ("CLAUDECODE", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_PID"):
            base.pop(k, None)
        base.update(HOME=self.home, TZ="UTC", LC_ALL="C", COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1",
                    AGENTBUS_NO_UPDATE_CHECK="1", AGENTBUS_NO_UPDATE_NOTICE="1")
        self.base = base

    def bus(self, db, at, *args):
        """One CLI process at simulated time `at` (the clock rule: a fresh process per timestamp)."""
        env = dict(self.base, AGENTBUS_DB=db, AGENTBUS_TEST_NOW=at)
        r = subprocess.run(self.cli + list(args), env=env, cwd=self.cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
        if r.returncode != 0:
            raise SystemExit(f"FAIL: agentbus {' '.join(args)} exited {r.returncode}: {r.stderr.strip()}")
        return r.stdout

    def sh(self, cwd, command):
        r = subprocess.run(["sh", "-c", command], env=self.base, cwd=cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
        if r.returncode not in (0, 1):  # grep exits 1 on no match: an empty answer, not an error
            raise SystemExit(f"FAIL: {command} exited {r.returncode}: {r.stderr.strip()}")
        return r.stdout


def build_bus(run, bus_dir, events):
    """Replay events into a bus; returns the message ids the bus assigned, in post order."""
    os.makedirs(bus_dir)
    db = os.path.join(bus_dir, "bus.db")
    ids = []
    for t, actor, action, f in events:
        at = DAY + t + "Z"
        if action == "join":
            run.bus(db, at, "--as", actor, "join")
        elif action == "leave":
            run.bus(db, at, "--as", actor, "leave")
        elif action == "post":
            out = json.loads(run.bus(db, at, "--json", "--as", actor, "post", f["body"], "--to", f["to"], "--kind", f["kind"]))
            ids.append(out["id"])
        else:
            raise SystemExit(f"FAIL: unknown fixture action {action}")
    # Read-back check from the clock rule: every stored time is the simulated one.
    want = [DAY + t + "Z" for t, _, a, _ in events if a == "post"]
    got = [m["ts"] for m in json.loads(run.bus(db, CHECKPOINT, "--json", "read", "--limit", "-1"))["items"]]
    if got != want:
        raise SystemExit(f"FAIL: replay stamped {got}, simulated {want}")
    return ids


# ---- the raw ledger (docs/evals/ctxbench-protocol.md, "Ledger-raw file format") ----------------------------------

def enc(v):
    """A metadata value: '-' when absent, else percent-encoded so it holds no space, '|', '%' or newline."""
    if v is None or v == "":
        return "-"
    return "".join(c if c not in " |%\n\r\t=" else "%%%02X" % ord(c) for c in str(v))


def ledger_line(eid, ts, kind, item, frm, to, topic, path, reply_to, text):
    head = (f"- eid=E{eid} ts={ts} kind={kind} id={enc(item)} from={enc(frm)} to={enc(to)} "
            f"topic={enc(topic)} path={enc(path)} reply_to={enc(reply_to)} |")
    lines = str(text).split("\n")
    return "\n".join([head + (" " + lines[0] if lines[0] else "")] + ["  " + x for x in lines[1:]])


LEDGER_HEADER = ("# COORDINATION.md\n\nAppend-only. One event per line; continuation lines of a body are indented two spaces.\n"
                 "Fields: eid ts kind id from to topic path reply_to | text. '-' means none; to=all is a broadcast.\n\n")


def render_ledger(path, events, ids):
    out, eid, posts = [LEDGER_HEADER], 0, iter(ids)
    for t, actor, action, f in events:
        eid += 1
        ts = DAY + t + "Z"
        if action == "join":
            out.append(ledger_line(eid, ts, "JOIN", None, actor, None, None, None, None, ""))
        elif action == "leave":
            out.append(ledger_line(eid, ts, "LEAVE", None, actor, None, None, None, None, "released 0 claims"))
        elif action == "post":
            to = "all" if f["to"] == "*" else f["to"]
            out.append(ledger_line(eid, ts, f["kind"].upper(), next(posts), actor, to, None, None, None, f["body"]))
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")


# ---- registered P4 procedures ------------------------------------------------------------------------------------
# Each is the exact command list the protocol registers (CLI words after `agentbus`; shell for the ledger). Every call
# is charged. These must match the P4 rows of the command table in docs/evals/ctxbench-protocol.md.

P4_PROCEDURES = {
    "bus-complete": [
        ["--as", ME, "--json", "brief", "--limit", "-1"],
        ["--as", ME, "--json", "log", "show", "--limit", "-1"],
    ],
    "ledger-raw": [
        "grep -n -E 'kind=(TODO|DONE|DROPPED|JOIN|LEAVE)( |$)' COORDINATION.md",
    ],
}
BUS_DEFAULT = [
    ["--as", ME, "brief"],
    ["--as", ME, "inbox", "--peek"],
    ["--as", ME, "read"],
]

# ---- reference parsers: given only the returned text (and the probe's own inputs: who I am) ------------------------


def parse_bus_complete_p4(texts, me):
    brief, logs = json.loads(texts[0]), json.loads(texts[1])
    if brief["omitted"]["todos"] or logs["has_more"]:
        return None  # an incomplete listing cannot prove a set: a miss, never a guess
    leaves = [(e["agent"], e["ts"]) for e in logs["items"] if e["action"] == "leave"]
    take = set()
    for t in brief["todos"]["items"]:
        if t["owner"] == me or (not t["owner_on_roster"] and any(a == t["owner"] and ts >= t["ts"] for a, ts in leaves)):
            take.add(t["id"])
    return take


LINE = re.compile(r"^\d+:- eid=(\S+) ts=(\S+) kind=(\S+) id=(\S+) from=(\S+) to=(\S+) topic=(\S+) path=(\S+) "
                  r"reply_to=(\S+) \|")


def parse_ledger_raw_p4(texts, me):
    todos, closed, roster, leaves = {}, set(), set(), []
    for raw in texts[0].splitlines():
        m = LINE.match(raw)
        if not m:
            continue
        _, ts, kind, item, frm, to, _, _, reply_to = m.groups()
        if kind == "TODO":
            todos[int(item)] = (ts, frm if to == "all" else to)
        elif kind in ("DONE", "DROPPED") and reply_to != "-":
            closed.add(int(reply_to))
        elif kind == "JOIN":
            roster.add(frm)
        elif kind == "LEAVE":
            roster.discard(frm)
            leaves.append((frm, ts))
    take = set()
    for i, (ts, owner) in todos.items():
        if i in closed:
            continue
        if owner == me or (owner not in roster and any(a == owner and lt >= ts for a, lt in leaves)):
            take.add(i)
    return take


PARSERS = {"bus-complete": parse_bus_complete_p4, "ledger-raw": parse_ledger_raw_p4}

# ---- the fixture -------------------------------------------------------------------------------------------------


def fresh_copy(src, tmp, tag):
    """A fresh copy per probe and strategy, so presence and cursor writes never leak between trials."""
    dst = os.path.join(tmp, "copies", tag)
    shutil.copytree(src, dst)
    return dst


def norm(text, where):
    return text.replace(where, "<BUS>")


def run_bus_cmds(run, copy, cmds):
    db = os.path.join(copy, "bus.db")
    return [norm(run.bus(db, CHECKPOINT, *c), copy) for c in cmds]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cli", help="the command that runs agentbus, split on whitespace (default: this Python and bin/agentbus)")
    args = ap.parse_args()
    cli = args.cli.split() if args.cli else [sys.executable, os.path.join(ROOT, "bin", "agentbus")]
    tmp = tempfile.mkdtemp(prefix="ctxbench-fixture.")
    try:
        run = Runner(cli, tmp)
        built = {}
        for h, events in HISTORIES.items():
            bus_dir = os.path.join(tmp, "hist" + h, "bus")
            ids = build_bus(run, bus_dir, events)
            if ids != [1, 2]:
                raise SystemExit(f"FAIL: history {h} assigned ids {ids}, the fixture expects [1, 2]")
            ledger_dir = os.path.join(tmp, "hist" + h, "ledger")
            os.makedirs(ledger_dir)
            render_ledger(os.path.join(ledger_dir, "COORDINATION.md"), events, ids)
            built[h] = (bus_dir, ledger_dir)

        # 1. every registered sufficient procedure derives the expected set from its own text alone
        texts = {}
        for arm, proc in P4_PROCEDURES.items():
            for h, (bus_dir, ledger_dir) in built.items():
                if arm == "bus-complete":
                    out = run_bus_cmds(run, fresh_copy(bus_dir, tmp, f"{arm}-{h}"), proc)
                else:
                    copy = fresh_copy(ledger_dir, tmp, f"{arm}-{h}")
                    out = [run.sh(copy, c) for c in proc]
                texts[(arm, h)] = out
                got = PARSERS[arm](out, ME)
                if got != EXPECTED[h]:
                    raise SystemExit(f"FAIL: {arm} P4 on history {h} derived {got}, expected {EXPECTED[h]}")
                print(f"PASS: {arm} P4 derives {sorted(EXPECTED[h])} from history {h}'s returned text "
                      f"({len(proc)} call{'s' if len(proc) > 1 else ''}, {sum(len(t.encode()) for t in out)} bytes)")
            # the parser reads the text, not the history: swapped inputs give swapped answers
            if PARSERS[arm](texts[(arm, "A")], ME) == PARSERS[arm](texts[(arm, "B")], ME):
                raise SystemExit(f"FAIL: {arm} parser gave one answer for both histories")

        # 2. Bus-default cannot: the same text for both histories, two different answers
        default = {h: run_bus_cmds(run, fresh_copy(b, tmp, f"default-{h}"), BUS_DEFAULT) for h, (b, _) in built.items()}
        if default["A"] != default["B"]:
            raise SystemExit("FAIL: Bus-default text differs between the histories; the documented gap has changed:\n"
                             + "\n---\n".join(a + "\n+++\n" + b for a, b in zip(default["A"], default["B"]) if a != b))
        print("PASS: Bus-default (brief, inbox --peek, read) returns identical text for A and B, so it cannot derive P4 "
              f"({sum(len(t.encode()) for t in default['A'])} bytes)")

        # 3. the leave evidence is what decides it
        brief_only = {h: run_bus_cmds(run, fresh_copy(b, tmp, f"brief-only-{h}"), P4_PROCEDURES["bus-complete"][:1])
                      for h, (b, _) in built.items()}
        if brief_only["A"] != brief_only["B"]:
            raise SystemExit("FAIL: brief --json alone differs between the histories; log show is no longer the only evidence")
        # (line numbers and event ids shift with an earlier LEAVE line, so they are dropped before comparing)
        todo_only = {h: re.sub(r"(?m)^\d+:- eid=E\d+ ", "- ", run.sh(l, "grep -n -E 'kind=(TODO|DONE|DROPPED)( |$)' COORDINATION.md"))
                     for h, (_, l) in built.items()}
        if todo_only["A"] != todo_only["B"]:
            raise SystemExit("FAIL: the ledger's TODO lines differ between the histories; LEAVE lines are no longer the only evidence")
        print("PASS: without log show (bus) or LEAVE lines (ledger) the two histories read the same")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("ctxbench sufficiency fixture: all checks passed")


if __name__ == "__main__":
    main()
