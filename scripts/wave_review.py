#!/usr/bin/env python3
"""Wave-close review of a bus (internal). Read-only.

  wave_review.py [--since ID] [--coordinator NAME[,NAME]] [--append FILE]
                 [--json EXPORT.json] [--cli "python3 bin/agentbus"]

Reads `read --json` and `log show --json` from the bus the environment names (AGENTBUS_DB or the
nearest bus), or one `read --json` export given with --json (no log, no roster). Friction posts are
`[key] text` or `+1 [key]`; a key at 3 or more gets an issue.
"""
import argparse, collections, datetime, json, os, re, shlex, subprocess, sys


def run(cli, *args, agent=None):
    cmd = shlex.split(cli) + (["--as", agent] if agent else []) + ["--json", *args]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode:
        sys.exit("wave_review: %s failed: %s" % (" ".join(args), p.stderr.strip()))
    return json.loads(p.stdout)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--since", type=int, default=0, help="only messages after this id (and log rows from its time)")
    ap.add_argument("--coordinator", default="claude-brain", help="comma-separated names")
    ap.add_argument("--append", help="append one summary line to this file")
    ap.add_argument("--json", dest="export", help="a saved `read --json` result instead of a live bus")
    ap.add_argument("--cli", default="agentbus")
    a = ap.parse_args()
    coord = set(a.coordinator.split(","))
    if a.export:
        msgs, log, roster = json.load(open(a.export))["items"], None, None
        msgs = [m for m in msgs if m["id"] > a.since]
    else:
        msgs = run(a.cli, "read", "--since", str(a.since), "--limit", "-1")["items"]
        cut = ""
        if a.since:
            cut = run(a.cli, "read", "--id", str(a.since))["ts"]
        log = [r for r in run(a.cli, "log", "show", "--limit", "-1")["items"] if r["ts"] >= cut]
        roster = {r["name"] for r in run(a.cli, "who")["items"]}
    unread = "n/a"
    if roster is not None and coord & roster:
        unread = len(run(a.cli, "inbox", "--peek", "--limit", "-1", agent=sorted(coord & roster)[0])["items"])
    def where(m):
        if m["sender"] in coord: return "from brain"
        if m["recipient"] in coord: return "to brain"
        return "to everyone" if m["recipient"] == "*" else "lane to lane"
    kinds = collections.Counter(m["kind"] for m in msgs)
    dirs = collections.Counter(where(m) for m in msgs)
    answered = {m["reply_to"] for m in msgs if m["reply_to"]}
    qs = [m for m in msgs if m["kind"] == "question"]
    loose = sum(1 for m in msgs if m["kind"] == "answer" and not m["reply_to"])
    keys, unkeyed = collections.Counter(), 0
    for m in msgs:
        if m["topic"] != "friction": continue
        k = re.match(r"\s*(?:\+1\s*)?\[([^\]\s]+)\]", m["body"] or "")
        if k: keys[k.group(1)] += 1
        else: unkeyed += 1
    refused = sum(1 for r in log or [] if r["action"] == "claim_refused") if log is not None else "n/a"
    out = ["messages %d since #%d" % (len(msgs), a.since),
           "by kind: " + (", ".join("%s %d" % kv for kv in sorted(kinds.items())) or "none"),
           "direction: " + ", ".join("%s %d" % (d, dirs[d]) for d in ("lane to lane", "to brain", "from brain", "to everyone")),
           "decisions: %d" % kinds["decision"],
           "questions: %d, answered with reply_to %d, unanswered %d (answers without reply_to: %d)"
           % (len(qs), sum(q["id"] in answered for q in qs), sum(q["id"] not in answered for q in qs), loose),
           "claim refusals logged: %s" % refused,
           "coordinator unread: %s" % unread,
           "friction keys:"]
    out += ["  %s %d" % kv for kv in keys.most_common()] + ["  unkeyed %d" % unkeyed]
    big = [k for k, n in keys.items() if n >= 3]
    out.append("rule: every key at 3 or more gets an issue" + (" -> " + ", ".join(sorted(big)) if big else ""))
    print("\n".join(out))
    if a.append:
        line = "%s since=%d msgs=%d l2l=%d unanswered=%d refused=%s unread=%s friction=%d/%s" % (
            datetime.date.today(), a.since, len(msgs), dirs["lane to lane"], sum(q["id"] not in answered for q in qs),
            refused, unread, sum(keys.values()) + unkeyed, ",".join("%s:%d" % kv for kv in keys.most_common()) or "-")
        with open(a.append, "a") as f: f.write(line + "\n")


if __name__ == "__main__":
    main()
