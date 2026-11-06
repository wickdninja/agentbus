#!/usr/bin/env python3
"""Follow-up fix1 analysis (docs/evals/value-protocol.md, addenda): does v0.3.0 close the recovery gap? A separate batch from
the counted run, read on its own; nothing here reads or changes the counted results.

python3 scripts/value-eval/analyze_fix1.py OUT --n N    the registered contrasts, only once all eight cells have N runs
python3 scripts/value-eval/analyze_fix1.py OUT --cost   harness numbers only, safe on a pilot

Needs grade.py and channel_grade.py run on OUT first. A livehold run passes when its hidden tests pass (blind) and bob neither took
nor edited under a claim of alice's while she was alive (channel_grade.py). A recovery run passes as in the counted run.
"""
import argparse
import json
import os
import statistics
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze  # noqa: E402

MARGIN = -0.10   # the acceptable deficit: agentbus minus ledger above this counts as closed (the addendum says why)
ALPHA = analyze.ALPHA
TASKS, CONDITIONS, PAIRINGS = ("recovery", "livehold"), ("agentbus", "ledger"), ("cx", "cc")
FAMILY = (("R-cx", "recovery", "cx"), ("R-cc", "recovery", "cc"), ("L-cx", "livehold", "cx"), ("L-cc", "livehold", "cc"))


def load(out):
    rows, dropped = analyze.load(out)
    for r in rows:
        with open(os.path.join(out, r["id"], "channel.json")) as f:
            r["channel"] = json.load(f)
        live = r["channel"].get("live")
        r["ok"] = bool(r["grade"]["pass"]) and (live is None or live["live_ok"])
    return rows, dropped


def short_cells(rows, n):
    """Every registered cell, counted: a cell with no runs at all is short too."""
    counts = {}
    for r in rows:
        counts[(r["task"], r["condition"], r["pairing"])] = counts.get((r["task"], r["condition"], r["pairing"]), 0) + 1
    return [(t, c, p) for t in TASKS for c in CONDITIONS for p in PAIRINGS if counts.get((t, c, p), 0) < n]


def noninferiority(rows, task, pairing):
    """agentbus minus ledger, paired by seed: (point, lo, hi, one-sided p against a difference at or below MARGIN)."""
    blocks = analyze.pair_blocks(rows, "agentbus", "ledger", (task,), pairing, lambda r: 1.0 if r["ok"] else 0.0)
    point, draws = analyze.diff_draws(blocks)
    return point, analyze.percentile(draws, 0.025), analyze.percentile(draws, 0.975), analyze.boot_p(draws, MARGIN, "above")


def share(xs):
    xs = list(xs)
    return "%d of %d" % (sum(1 for x in xs if x), len(xs))


def effects(rows):
    print("| task | condition | pairing | pass | 95% CI | n |\n| --- | --- | --- | --- | --- | --- |")
    for t in TASKS:
        for c in CONDITIONS:
            for p in PAIRINGS:
                sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == (t, c, p)]
                k = sum(1 for r in sub if r["ok"])
                lo, hi = analyze.wilson(k, len(sub))
                print("| %s | %s | %s | %d of %d | %.2f to %.2f | %d |" % (t, c, p, k, len(sub), lo, hi, len(sub)))

    print("\nPrimary (one family of four, Holm-corrected, one-sided alpha %.3f; closed means agentbus minus ledger above %.2f)" % (ALPHA, MARGIN))
    found = {name: noninferiority(rows, task, pairing) for name, task, pairing in FAMILY}
    adjusted = analyze.holm({name: v[3] for name, v in found.items()})
    closed = {name: adjusted[name] < ALPHA for name in found}
    for name, task, pairing in FAMILY:
        point, lo, hi, p = found[name]
        print("%s %s agentbus minus ledger, %s: %+.3f (%.3f to %.3f), p %.4f, Holm-adjusted p %.4f: %s" % (
            name, task, pairing, point, lo, hi, p, adjusted[name], "closed" if closed[name] else "not shown closed"))
    for pairing in PAIRINGS:
        r, l = closed["R-" + pairing], closed["L-" + pairing]
        text = ("the recovery gap is closed, and live claims are not taken more than with the ledger" if r and l else
                "the recovery gap is closed, but the live-holder cell is not shown within the margin" if r else
                "the recovery gap is not shown closed")
        print("Conclusion, %s: %s" % (pairing, text))

    print("\nlivehold, from the channel (not blind)\n| condition | pairing | alice claimed | took a live claim | edited under a live claim | steps failed | promo failed | bob started on |\n| --- | --- | --- | --- | --- | --- | --- | --- |")
    for c in CONDITIONS:
        for p in PAIRINGS:
            sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == ("livehold", c, p)]
            live = [r["channel"]["live"] for r in sub]
            why = {}
            for x in live:
                key = (x.get("late_start") or {}).get("why", "none")
                why[key] = why.get(key, 0) + 1
            print("| %s | %s | %s | %s | %s | %s | %s | %s |" % (c, p, share(x["holder_claimed"] for x in live), share(x["takeovers_while_alive"] for x in live),
                  share(x["edits_under_live_claim"] for x in live), share(not r["grade"]["features"].get("steps") for r in sub),
                  share(not r["grade"]["features"].get("promo") for r in sub), ", ".join("%s %d" % kv for kv in sorted(why.items()))))

    print("\nrecovery, from the channel (not blind)\n| condition | pairing | bob took a claim with --from | alice wrote both notes in the channel | alice recorded both as facts | bob read brief before inbox |\n| --- | --- | --- | --- | --- | --- |")
    for c in CONDITIONS:
        for p in PAIRINGS:
            sub = [r["channel"]["roles"] for r in rows if (r["task"], r["condition"], r["pairing"]) == ("recovery", c, p)]
            took = share((x.get("bob") or {}).get("takeovers") for x in sub) if c == "agentbus" else "n/a"
            notes = share(all(((x.get("alice") or {}).get("notes_in_channel") or {}).values() or [False]) for x in sub)
            facts = share(all(((x.get("alice") or {}).get("notes_as_facts") or {}).values() or [False]) for x in sub)
            brief = share((x.get("bob") or {}).get("brief_before_inbox") for x in sub) if c == "agentbus" else "n/a"
            print("| %s | %s | %s | %s | %s | %s |" % (c, p, took, notes, facts, brief))

    cols = ("tokens", "fresh tokens", "minutes", "tool calls", "channel calls", "channel writes")
    print("\n| task | condition | pairing | " + " | ".join(cols) + " |\n" + "| --- " * (len(cols) + 3) + "|")
    for t in TASKS:
        for c in CONDITIONS:
            for p in PAIRINGS:
                sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == (t, c, p)]
                mean = lambda f: statistics.mean(f(r) for r in sub)  # noqa: E731
                vals = (mean(analyze.tokens), mean(analyze.fresh_tokens), mean(lambda r: r["grade"]["seconds"] / 60),
                        mean(lambda r: analyze._sum(r, "tool_calls")), mean(lambda r: analyze._sum(r, "channel_calls")), mean(lambda r: analyze._sum(r, "channel_writes")))
                print("| %s | %s | %s | " % (t, c, p) + " | ".join("%.1f" % v for v in vals) + " |")

    print("\nProtocol steps: share of agents that did each (a manipulation check)\n| condition | read first | claim first | released | finished |\n| --- | --- | --- | --- | --- |")
    for c in CONDITIONS:
        agents = [x["protocol"] for r in rows if r["condition"] == c for x in r["cost"].values() if x.get("protocol")]
        if agents:
            print("| %s | " % c + " | ".join("%.2f" % (sum(1 for a in agents if a[k]) / len(agents)) for k in ("read_first", "claim_first", "released", "finished")) + " |")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--n", type=int)
    ap.add_argument("--cost", action="store_true")
    args = ap.parse_args(argv)
    rows, dropped = load(args.out)
    print(analyze.dropped_summary(dropped))
    if args.cost:
        analyze.cost_report(rows)
        return 0
    if not args.n:
        ap.error("name the registered sample size with --n, or use --cost")
    short = short_cells(rows, args.n)
    if short:
        print("no contrasts: %d cells have fewer than %d runs. Pilot numbers are not results." % (len(short), args.n))
        return 3
    effects(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
