#!/usr/bin/env python3
"""Wave-close review of a bus (internal). Read-only.

  wave_review.py --coordinator NAME[,NAME] [--since ID] [--append FILE]
                 [--json EXPORT.json] [--cli "python3 bin/agentbus"]

Reads `read`, `log show`, `who` and `watch` (all --json, none with --as, and AGENTBUS_AGENT dropped, so no agent's
last-seen or cursor moves) from the bus the environment names (AGENTBUS_DB or the nearest bus), or one `read --json`
export given with --json (no log, no roster). A coordinator's unread count is the one `watch --json` reports, which
covers the first 200 agents by join time. Friction posts are `[key] text` or `+1 [key]`; a key at 3 or more gets an issue.
"""
import argparse, collections, datetime, json, os, re, shlex, subprocess, sys


def run(cli, *args):
    env = {k: v for k, v in os.environ.items() if k != "AGENTBUS_AGENT"}  # an identity would refresh its last-seen
    p = subprocess.run(shlex.split(cli) + ["--json", *args], capture_output=True, text=True, env=env)
    if p.returncode:
        sys.exit("wave_review: %s failed: %s" % (" ".join(args), p.stderr.strip()))
    return json.loads(p.stdout)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--since", type=int, default=0, help="only messages after this id (and log rows from its time)")
    ap.add_argument("--coordinator", required=True, help="comma-separated names")
    ap.add_argument("--append", help="append one summary line to this file")
    ap.add_argument("--json", dest="export", help="a saved `read --json` result instead of a live bus")
    ap.add_argument("--cli", default="agentbus")
    a = ap.parse_args()
    names = [c for c in a.coordinator.split(",") if c]
    coord = set(names)
    if a.export:
        with open(a.export) as f:
            msgs = [m for m in json.load(f)["items"] if m["id"] > a.since]
        log = waiting = None
    else:
        msgs = run(a.cli, "read", "--since", str(a.since), "--limit", "-1")["items"]
        cut = run(a.cli, "read", "--id", str(a.since))["ts"] if a.since else ""
        log = [r for r in run(a.cli, "log", "show", "--limit", "-1")["items"] if r["ts"] >= cut]
        roster = {r["name"] for r in run(a.cli, "who", "--limit", "-1")["items"]}
        counts = run(a.cli, "watch")["unread"]
        waiting = {c: counts[c] for c in names if c in roster and c in counts}
    unread = [(c, waiting.get(c, "n/a") if waiting is not None else "n/a") for c in names]
    def where(m):
        if m["sender"] in coord: return "from brain"
        if m["recipient"] in coord: return "to brain"
        return "to everyone" if m["recipient"] == "*" else "lane to lane"
    kinds = collections.Counter(m["kind"] for m in msgs)
    dirs = collections.Counter(where(m) for m in msgs)
    answered = {m["reply_to"] for m in msgs if m["kind"] == "answer" and m["reply_to"]}
    qs = [m for m in msgs if m["kind"] == "question"]
    loose = sum(1 for m in msgs if m["kind"] == "answer" and not m["reply_to"])
    keys, unkeyed = collections.Counter(), 0
    for m in msgs:
        if m["topic"] != "friction": continue
        k = re.match(r"\s*(?:\+1\s*)?\[([^\]\s]+)\]", m["body"] or "")
        if k: keys[k.group(1)] += 1
        else: unkeyed += 1
    refused = sum(1 for r in log if r["action"] == "claim_refused") if log is not None else "n/a"
    out = ["messages %d since #%d" % (len(msgs), a.since),
           "by kind: " + (", ".join("%s %d" % kv for kv in sorted(kinds.items())) or "none"),
           "direction: " + ", ".join("%s %d" % (d, dirs[d]) for d in ("lane to lane", "to brain", "from brain", "to everyone")),
           "decisions: %d" % kinds["decision"],
           "questions: %d, answered with reply_to %d, unanswered %d (answers without reply_to: %d)"
           % (len(qs), sum(q["id"] in answered for q in qs), sum(q["id"] not in answered for q in qs), loose),
           "claim refusals logged: %s" % refused,
           "coordinator unread: " + ", ".join("%s %s" % cu for cu in unread),
           "friction keys:"]
    out += ["  %s %d" % kv for kv in keys.most_common()] + ["  unkeyed %d" % unkeyed]
    big = [k for k, n in keys.items() if n >= 3]
    out.append("rule: every key at 3 or more gets an issue" + (" -> " + ", ".join(sorted(big)) if big else ""))
    print("\n".join(out))
    if a.append:
        line = "%s since=%d msgs=%d l2l=%d unanswered=%d refused=%s unread=%s friction=%d/%s" % (
            datetime.date.today(), a.since, len(msgs), dirs["lane to lane"], sum(q["id"] not in answered for q in qs),
            refused, ",".join("%s:%s" % cu for cu in unread), sum(keys.values()) + unkeyed,
            ",".join("%s:%d" % kv for kv in keys.most_common()) or "-")
        with open(a.append, "a") as f:
            f.write(line + "\n")


if __name__ == "__main__":
    main()
