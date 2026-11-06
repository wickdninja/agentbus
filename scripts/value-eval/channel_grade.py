#!/usr/bin/env python3
"""Channel grades for follow-up fix1 (docs/evals/value-protocol.md, addenda). NOT blind: these read the channel the agents left
(channel/ beside each run, never final/), the manifest and the traces. They are mechanical rules in code, and the blind
hidden-test grade in grade.json is never changed by them.

livehold: alice is alive and holds src/rates.py; bob's ticket does not give him her work. The run's `live_ok` is False when, while
alice's session was still running, bob
  - took over a claim of hers (the bus: a claim_taken row from alice; the ledger: a CLAIM of bob's on a path an open CLAIM of
    alice's covers, or that covers it), or
  - edited a path one of her open claims covers, between her claim and her own release of it (or her session's end).
A claim stays alice's until she releases it herself: a takeover does not end her hold. Times lean toward the channel on both: a hold
starts at the latest moment its claim can have landed and ends at the earliest moment its release can have, so the window only
shrinks (the bus logs whole seconds, rounded down; the ledger is timed by the runner's watch, between two polls 0.2 s apart).

Every run also gets counts the report quotes: takeovers with --from, refused claims, facts recorded with ctx set (the bus) or
FACT (the ledger), whether brief came before inbox, and in recovery whether alice wrote the owner's two notes into the channel.

python3 scripts/value-eval/channel_grade.py OUT    writes channel.json into each run folder under OUT
"""
import calendar
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.append(os.path.join(os.path.dirname(HERE), "agent-eval"))
import grade  # noqa: E402
import ledger_hook as lh  # noqa: E402
import normalize  # noqa: E402
import tasks  # noqa: E402


def bus_time(text):
    return float(calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ")))


def overlaps(a, b):
    return lh.covers(a, b) or lh.covers(b, a)


def read_bus(channel_dir):
    """(log rows, context_history rows, messages) from the run's copy of the bus, or None when there is none. Opened from a
    private copy, so nothing is written beside the kept file."""
    src = os.path.join(channel_dir, "bus.db")
    if not os.path.isfile(src):
        return None
    work = tempfile.mkdtemp(prefix="value-chan-")
    try:
        for name in ("bus.db", "bus.db-wal"):
            if os.path.isfile(os.path.join(channel_dir, name)):
                shutil.copyfile(os.path.join(channel_dir, name), os.path.join(work, name))
        con = sqlite3.connect(os.path.join(work, "bus.db"))
        con.row_factory = sqlite3.Row
        try:
            log = [dict(r) for r in con.execute("SELECT ts, agent, action, detail FROM log ORDER BY id")]
            facts = [dict(r) for r in con.execute("SELECT key, value, updated_by, updated_at FROM context_history WHERE key != 'goal' ORDER BY id")]
            messages = [dict(r) for r in con.execute("SELECT ts, sender, recipient, kind, body FROM messages ORDER BY id")]
        finally:
            con.close()
        return log, facts, messages
    finally:
        shutil.rmtree(work, ignore_errors=True)


def bus_events(log, holder):
    """(holds, takeovers). holds: [[path, start, end or None]] for holder's own claims, ended only by holder's own release or leave.
    takeovers: [(ts, taker, [paths])] for every claim_taken row that took from holder."""
    holds, takeovers = [], []
    for row in log:
        ts = bus_time(row["ts"])
        detail = row["detail"] or ""
        if row["agent"] == holder and row["action"] == "claim" and " until " in detail and " auto-released " not in detail:
            path = detail.split(" until ", 1)[0]
            if not any(h[0] == path and h[2] is None for h in holds):
                holds.append([path, ts + 1, None])   # logged in whole seconds, rounded down: it landed before ts + 1
        elif row["agent"] == holder and (row["action"] == "leave" or (row["action"] == "release" and detail.startswith("all "))):
            for h in holds:
                h[2] = ts if h[2] is None else h[2]
        elif row["agent"] == holder and row["action"] == "release":
            gone = [p.strip() for p in detail.split(",")]
            for h in holds:
                if h[2] is None and h[0] in gone:
                    h[2] = ts
        elif row["action"] == "claim_taken":
            try:
                info = json.loads(detail)
            except ValueError:
                continue
            if info.get("from") == holder:
                takeovers.append((ts + 1, row["agent"], info.get("resources") or []))
    return holds, takeovers


def ledger_timed(channel_dir):
    """[(earliest, latest, entry)] for the ledger's entries: each landed after the watch's poll before the one that first saw it
    (earliest) and by that poll (latest). None without a watch."""
    path = os.path.join(channel_dir, "ledger-watch.jsonl")
    if not os.path.isfile(path):
        return None
    timed = []
    for line in open(path):
        snap = json.loads(line)
        entries = lh.parse(snap["text"])
        for e in entries[len(timed):]:
            timed.append((snap["prev"], snap["ts"], e))
    return timed


def ledger_events(timed, holder):
    """The ledger's (holds, takeovers), on the same rules as bus_events. A takeover is a CLAIM by someone else on a path an open
    CLAIM of holder's covers, or that covers it."""
    holds, takeovers = [], []
    for earliest, latest, e in timed:
        paths = [p.rstrip("/") or p for p in lh._paths(e["text"])] if e["kind"] in ("CLAIM", "RELEASE") else []
        if e["name"] == holder and e["kind"] == "CLAIM":
            holds += [[p, latest, None] for p in paths if not any(h[0] == p and h[2] is None for h in holds)]
        elif e["name"] == holder and e["kind"] == "RELEASE":
            for h in holds:
                if h[2] is None and h[0] in paths:
                    h[2] = earliest
        elif e["kind"] == "CLAIM":
            taken = [p for p in paths if any(h[2] is None and overlaps(h[0], p) for h in holds)]
            if taken:
                takeovers.append((latest, e["name"], taken))
    return holds, takeovers


def live_grade(holds, takeovers, edits, holder, other, holder_end):
    """The livehold rule. holder_end: when the holder's session ended. Only acts while it ran count."""
    alive = lambda ts: holder_end is None or ts < holder_end  # noqa: E731
    took = [t for t in takeovers if t[1] == other and alive(t[0])]
    under = []
    for e in edits:
        if e["agent"] != other:
            continue
        for path, start, end in holds:
            stops = [x for x in (end, holder_end) if x is not None]
            stop = min(stops) if stops else None
            if overlaps(path, e["path"]) and e["ts"] >= start and (stop is None or e["ts"] < stop):
                under.append(e["path"])
                break
    return {"holder_claimed": bool(holds), "takeovers_while_alive": len(took), "edits_under_live_claim": len(under),
            "live_ok": not took and not under}


def bus_verbs(lines, harness):
    verbs = []
    for name, text, _result in grade._calls(lines, harness):
        if name == "Bash":
            verbs += [v for v, _a in normalize.bus_commands(text)]
    return verbs


def trace_lines(run_dir, role):
    path = os.path.join(run_dir, "trace-%s.jsonl" % role)
    return [json.loads(l) for l in open(path)] if os.path.isfile(path) else []


def channel_grade(run_dir, row):
    with open(os.path.join(run_dir, "run.json")) as f:
        run = json.load(f)
    task = tasks.build(run["task"], run["seed"])
    channel_dir = os.path.join(run_dir, "channel")
    out = {"id": row["id"], "condition": row["condition"], "roles": {}}
    bus = read_bus(channel_dir) if row["condition"] == "agentbus" else None
    timed = ledger_timed(channel_dir) if row["condition"] == "ledger" else None
    entries = [e for _a, _b, e in timed] if timed else []
    for role, info in run["agents"].items():
        lines = trace_lines(run_dir, role)
        verbs = bus_verbs(lines, info["harness"]) if row["condition"] == "agentbus" else []
        r = {"brief_before_inbox": ("brief" in verbs and ("inbox" not in verbs or verbs.index("brief") < verbs.index("inbox"))) if verbs else None}
        if bus:
            log, facts, messages = bus
            r.update({"takeovers": sum(1 for x in log if x["agent"] == role and x["action"] == "claim_taken"),
                      "claims_refused": sum(1 for x in log if x["agent"] == role and x["action"] == "claim_refused"),
                      "facts": sum(1 for x in facts if x["updated_by"] == role)})
            written = [x["value"] or "" for x in facts if x["updated_by"] == role] + [x["key"] for x in facts if x["updated_by"] == role]
            sent = [x["body"] for x in messages if x["sender"] == role]
        elif row["condition"] == "ledger":
            mine = [e for e in entries if e["name"] == role]
            r.update({"facts": sum(1 for e in mine if e["kind"] == "FACT")})
            written = ["%s %s" % (e["key"] or "", e["text"]) for e in mine if e["kind"] == "FACT"]
            sent = [e["text"] for e in mine]
        else:
            written, sent = [], []
        if run["task"] == "recovery" and role == "alice":
            p = tasks._recovery_params(run["seed"])
            skip, factor = p["mods"][4], str(p["new_factor"])
            r["notes_in_channel"] = {"skip": any(skip in t for t in sent + written), "factor": any(factor in t for t in sent + written)}
            r["notes_as_facts"] = {"skip": any(skip in t for t in written), "factor": any(factor in t for t in written)}
        out["roles"][role] = r
    if task.contested:
        holder, other = task.contested["holder"], task.contested["other"]
        if bus:
            holds, takeovers = bus_events(bus[0], holder)
        elif timed is not None:
            holds, takeovers = ledger_events(timed, holder)
        else:
            holds, takeovers = [], []
        with open(os.path.join(run_dir, "edits.json")) as f:
            edits = json.load(f)
        out["live"] = live_grade(holds, takeovers, edits, holder, other, (run["agents"].get(holder) or {}).get("t_end"))
        out["live"]["late_start"] = run.get("late_start")
    return out


def main(argv):
    out = argv[0]
    n = 0
    for line in open(os.path.join(out, "manifest.jsonl")):
        row = json.loads(line)
        run_dir = os.path.join(out, row["id"])
        if os.path.isfile(os.path.join(run_dir, "run.json")):
            grade.write_json(os.path.join(run_dir, "channel.json"), channel_grade(run_dir, row))
            n += 1
    print("channel-graded %d runs" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
