#!/usr/bin/env python3
"""Value eval analysis (docs/evals/value-protocol.md, Analysis).

python3 scripts/value-eval/analyze.py OUT --n N    effects, only once every cell has N runs
python3 scripts/value-eval/analyze.py OUT --cost   tokens and minutes per run: no conditions compared, safe on a pilot

No contrast prints for a batch short of N. That is the no-peeking rule in code, and it is why pilot numbers cannot turn into results.
"""
import argparse
import json
import math
import os
import random
import statistics
import sys

sys.dont_write_bytecode = True
RESAMPLES, RNG_SEED, SESOI = 10000, 20261105, 0.15
ALPHA = 0.025    # one-sided, the lower end of a two-sided 95% interval; Holm keeps it family-wise across P1 to P3
P3_MARGIN = 1.25
COORDINATION = ("overlap", "interface", "recovery", "facts")
MIN_PROJECTION_RUNS = 30


def load(out):
    """The manifest joined to grades and costs. Infra failures are dropped here and only here, and returned for the report."""
    rows, dropped = [], []
    for line in open(os.path.join(out, "manifest.jsonl")):
        row = json.loads(line)
        if row["infra"] or row["isolation"] or row.get("excluded"):
            dropped.append(row)
            continue
        with open(os.path.join(out, row["id"], "grade.json")) as f:
            row["grade"] = json.load(f)
        with open(os.path.join(out, row["id"], "cost.json")) as f:
            row["cost"] = json.load(f)
        rows.append(row)
    return rows, dropped


def dropped_summary(dropped):
    """How many runs were dropped, by reason, without listing every id."""
    reasons = {}
    for d in dropped:
        why = "; ".join(sorted(set(list(d["infra"].values()) + list(d["isolation"]) + ([d["excluded"]] if d.get("excluded") else [])))) or "unknown"
        reasons[why] = reasons.get(why, 0) + 1
    lines = ["dropped under the protocol's rule: %d" % len(dropped)]
    lines += ["  %d %s: %s" % (n, "run" if n == 1 else "runs", why) for why, n in sorted(reasons.items(), key=lambda x: -x[1])]
    return "\n".join(lines)


def tokens(row):
    """Everything the model read or wrote, cache reads included, summed over the run's agents."""
    return sum(sum(c["usage"].values()) for c in row["cost"].values())


def fresh_tokens(row):
    """The same without cache reads, which cost about a tenth and otherwise dominate the total."""
    return sum(c["usage"]["input"] + c["usage"]["cache_write"] + c["usage"]["output"] for c in row["cost"].values())


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, mid - half), min(1.0, mid + half))


def percentile(sorted_values, q):
    i = (len(sorted_values) - 1) * q
    lo, hi = int(math.floor(i)), int(math.ceil(i))
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (i - lo)


def pair_blocks(rows, a, b, task_set, pairing, value):
    """{seed: [value(a run) - value(b run) for each task]}: runs paired on seed and task, resampled by seed block."""
    cell = {}
    for r in rows:
        if r["task"] in task_set and r["pairing"] == pairing and r["condition"] in (a, b):
            cell[(r["seed"], r["task"], r["condition"])] = value(r)
    blocks = {}
    for (seed, task, cond), v in cell.items():
        if cond == a and (seed, task, b) in cell:
            blocks.setdefault(seed, []).append(v - cell[(seed, task, b)])
    return blocks


def diff_draws(blocks, resamples=RESAMPLES, seed=RNG_SEED):
    """Mean paired difference and its sorted bootstrap draws, resampling whole seed blocks."""
    keys = sorted(blocks)
    flat = [x for k in keys for x in blocks[k]]
    r = random.Random(seed)
    means = []
    for _ in range(resamples):
        sample = [x for k in (r.choice(keys) for _ in keys) for x in blocks[k]]
        means.append(sum(sample) / len(sample))
    means.sort()
    return sum(flat) / len(flat), means


def bootstrap_mean_diff(blocks, resamples=RESAMPLES, seed=RNG_SEED):
    """Mean paired difference and a 95% percentile interval, resampling whole seed blocks."""
    point, means = diff_draws(blocks, resamples, seed)
    return point, percentile(means, 0.025), percentile(means, 0.975)


def boot_p(draws, null, side):
    """One-sided bootstrap p: the share of draws on the null's side, with the usual +1 so it is never 0. side "above": the claim
    is that the value exceeds null (P1, P2). side "below": that it stays under null (P3's margin)."""
    against = sum(1 for d in draws if (d <= null if side == "above" else d >= null))
    return (1 + against) / (len(draws) + 1)


def holm(pvals):
    """Holm-adjusted p values for a family {name: p}: step down from the smallest, multiply by the hypotheses still standing, and keep
    the sequence monotone."""
    order = sorted(pvals, key=lambda k: pvals[k])
    m, out, running = len(order), {}, 0.0
    for i, k in enumerate(order):
        running = max(running, min(1.0, (m - i) * pvals[k]))
        out[k] = running
    return out


def ratio_draws(rows, a, b, value, resamples=RESAMPLES, seed=RNG_SEED):
    """Ratio of means, a over b, and its sorted bootstrap draws, resampling seeds."""
    seeds = sorted({r["seed"] for r in rows})
    per = {s: ([value(r) for r in rows if r["seed"] == s and r["condition"] == a], [value(r) for r in rows if r["seed"] == s and r["condition"] == b]) for s in seeds}
    rnd = random.Random(seed)

    def ratio(chosen):
        xs = [x for s in chosen for x in per[s][0]]
        ys = [y for s in chosen for y in per[s][1]]
        return (sum(xs) / len(xs)) / (sum(ys) / len(ys)) if xs and sum(ys) else float("nan")
    draws = sorted(x for x in (ratio([rnd.choice(seeds) for _ in seeds]) for _ in range(resamples)) if x == x)
    return ratio(seeds), draws


def bootstrap_ratio(rows, a, b, value, resamples=RESAMPLES, seed=RNG_SEED):
    """Ratio of means, a over b, with a 95% interval, resampling seeds."""
    point, draws = ratio_draws(rows, a, b, value, resamples, seed)
    return point, percentile(draws, 0.025), percentile(draws, 0.975)


def p3(rows, resamples=RESAMPLES, value=None):
    """P3 as registered: agentbus over ledger in mean total tokens, cache reads included, on control. (point, lo, hi, draws)."""
    point, draws = ratio_draws(rows, "agentbus", "ledger", value or tokens, resamples)
    return point, percentile(draws, 0.025), percentile(draws, 0.975), draws


def over_budget(start, now, done, total, budget, min_runs=MIN_PROJECTION_RUNS):
    """The protocol's Codex stop rule. Quota moves in whole points and the pool is shared, so a projection from a handful of runs
    is noise: it needs min_runs first. Points already spent past the budget halt at any time. A reading below the start is a
    window reset, not a saving, and spends nothing."""
    if start is None or now is None or now <= start:
        return False
    spent = now - start
    return spent > budget or (done >= min_runs and spent * total / done > budget)


def verdict(point, lo, hi, holm_reject=None):
    """The protocol's table, in code, so a result is read the way it was registered. "Above zero" is the Holm decision across the
    family when one is given; the raw interval otherwise. An interval wholly below zero means the flat file did better."""
    above = lo > 0 if holm_reject is None else holm_reject
    if hi < 0:
        return "flat file better"
    if above and point >= SESOI:
        return "value over a flat file"
    if above:
        return "real but small: little value"
    if hi < SESOI:
        return "no meaningful value over a flat file"
    return "inconclusive: no evidence of value"


def flat_file_better(p3_within, pass_verdict, ledger_cheaper):
    """The protocol's combined rule: P3 failing, the flat file winning on pass rate, or matching it at lower cost, says the flat file
    is the better choice. A match means no meaningful value; an inconclusive pass rate is not a match."""
    return (not p3_within) or pass_verdict == "flat file better" or (pass_verdict == "no meaningful value over a flat file" and ledger_cheaper)


def missing_cells(rows, n):
    counts = {}
    for r in rows:
        counts[(r["task"], r["condition"], r["pairing"])] = counts.get((r["task"], r["condition"], r["pairing"]), 0) + 1
    tasks_seen = {r["task"] for r in rows}
    conds = {r["condition"] for r in rows}
    pairs = {r["pairing"] for r in rows}
    want = [(t, c, p) for t in tasks_seen for c in conds for p in pairs if not (c == "builtin" and p != "cc")]
    return [c for c in want if counts.get(c, 0) < n]


def cost_report(rows):
    """Harness numbers only: no row here is split by condition, so a pilot cannot be read as a result."""
    print("runs %d" % len(rows))
    if not rows:
        return
    mins = [r["grade"]["seconds"] / 60 for r in rows]
    print("minutes per run: mean %.1f, max %.1f" % (statistics.mean(mins), max(mins)))
    print("tokens per run: mean %.0f total, %.0f without cache reads" % (statistics.mean(tokens(r) for r in rows), statistics.mean(fresh_tokens(r) for r in rows)))
    usd = [sum(c["cost_usd"] or 0 for c in r["cost"].values()) for r in rows]
    print("Claude reported cost per run: mean $%.2f, max $%.2f" % (statistics.mean(usd), max(usd)))
    print("load during runs: max %.0f" % max(r["grade"]["load"]["max"] for r in rows))
    for task in sorted({r["task"] for r in rows}):
        sub = [r for r in rows if r["task"] == task]
        print("  %s: %d runs, %.1f min, %.0f fresh tokens" % (task, len(sub), statistics.mean(r["grade"]["seconds"] / 60 for r in sub), statistics.mean(fresh_tokens(r) for r in sub)))


def _sum(r, key):
    return sum((c.get(key) or 0) if not isinstance(c.get(key), dict) else c[key].get("failed", 0) for c in r["cost"].values())


def effects(rows):
    passed = lambda r: 1.0 if r["grade"]["pass"] else 0.0  # noqa: E731
    print("| task | condition | pairing | pass | 95% CI | n |\n| --- | --- | --- | --- | --- | --- |")
    keys = sorted({(r["task"], r["condition"], r["pairing"]) for r in rows})
    for t, c, p in keys:
        sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == (t, c, p)]
        k = sum(1 for r in sub if r["grade"]["pass"])
        lo, hi = wilson(k, len(sub))
        print("| %s | %s | %s | %d of %d | %.2f to %.2f | %d |" % (t, c, p, k, len(sub), lo, hi, len(sub)))
    cols = ("tokens", "fresh tokens", "minutes", "tool calls", "channel calls", "channel writes", "channel bytes back", "rework",
            "merge conflicts", "lost features", "duplicates", "caps hit", "hook failures", "ledger links broken")
    print("\n| task | condition | pairing | " + " | ".join(cols) + " |\n" + "| --- " * (len(cols) + 3) + "|")
    for t, c, p in keys:
        sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == (t, c, p)]
        mean = lambda f: statistics.mean(f(r) for r in sub)  # noqa: E731
        vals = (mean(tokens), mean(fresh_tokens), mean(lambda r: r["grade"]["seconds"] / 60), mean(lambda r: _sum(r, "tool_calls")),
                mean(lambda r: _sum(r, "channel_calls")), mean(lambda r: _sum(r, "channel_writes")), mean(lambda r: _sum(r, "channel_bytes_back")),
                mean(lambda r: r["grade"]["rework_events"]), mean(lambda r: len(r["grade"]["merge_conflicts"] or [])),
                mean(lambda r: len(r["grade"]["lost_features"])), mean(lambda r: len(r["grade"]["duplicates"])),
                sum(1 for r in sub if r["grade"]["stops"]), sum(_sum(r, "hooks") for r in sub), sum(_sum(r, "ledger_link_broken") for r in sub))
        print("| %s | %s | %s | " % (t, c, p) + " | ".join("%.1f" % v for v in vals) + " |")

    print("\nPrimary (one family, Holm-corrected, one-sided alpha %.3f)" % ALPHA)
    found, pvals = {}, {}
    for name, pairing in (("P1", "cx"), ("P2", "cc")):
        blocks = pair_blocks(rows, "agentbus", "ledger", COORDINATION, pairing, passed)
        if blocks:
            point, draws = diff_draws(blocks)
            found[name] = (pairing, point, percentile(draws, 0.025), percentile(draws, 0.975))
            pvals[name] = boot_p(draws, 0.0, "above")
    control = [r for r in rows if r["task"] == "control"]
    if control:
        point, lo, hi, draws = p3(control)
        found["P3"] = ("both", point, lo, hi)
        pvals["P3"] = boot_p(draws, P3_MARGIN, "below")
    adjusted = holm(pvals) if pvals else {}
    for name in ("P1", "P2"):
        if name in found:
            pairing, point, lo, hi = found[name]
            v = verdict(point, lo, hi, adjusted[name] < ALPHA)
            found[name] += (v,)
            print("%s agentbus minus ledger, %s: %+.3f (%.3f to %.3f), Holm-adjusted p %.4f: %s" % (name, pairing, point, lo, hi, adjusted[name], v))
    p3_within = True
    if "P3" in found:
        _, point, lo, hi = found["P3"]
        p3_within = adjusted["P3"] < ALPHA
        print("P3 control tokens, agentbus over ledger: %.2f (%.2f to %.2f), Holm-adjusted p %.4f: %s" % (
            point, lo, hi, adjusted["P3"], "within %.2f" % P3_MARGIN if p3_within else "not shown within %.2f" % P3_MARGIN))
        print("P3 fresh tokens, secondary: %.2f (%.2f to %.2f)" % p3(control, value=fresh_tokens)[:3])
    for name in ("P1", "P2"):
        if name in found:
            pairing, verdict_text = found[name][0], found[name][4]
            spend = [r for r in rows if r["pairing"] == pairing and r["task"] in COORDINATION]
            _pt, cost_lo, _hi = bootstrap_ratio(spend, "agentbus", "ledger", tokens)
            better = flat_file_better(p3_within, verdict_text, cost_lo > 1)
            print("Conclusion, %s: %s" % (pairing, "the flat file is the better choice for this work" if better else "no flat-file rule applies"))

    print("\nSensitivity: P1 and P2 without overlap (not part of the family)")
    for name, pairing in (("P1", "cx"), ("P2", "cc")):
        blocks = pair_blocks(rows, "agentbus", "ledger", tuple(t for t in COORDINATION if t != "overlap"), pairing, passed)
        if blocks:
            print("%s without overlap, %s: %+.3f (%.3f to %.3f)" % ((name, pairing) + bootstrap_mean_diff(blocks)))

    print("\nSecondary (leads, not findings)")
    for task in COORDINATION:
        for pairing in ("cx", "cc"):
            blocks = pair_blocks(rows, "agentbus", "ledger", (task,), pairing, passed)
            if blocks:
                print("%s %s agentbus minus ledger: %+.3f (%.3f to %.3f)" % ((task, pairing) + bootstrap_mean_diff(blocks)))
    for a, b, pairing in (("ledger", "none", "cx"), ("ledger", "none", "cc"), ("agentbus", "builtin", "cc")):
        blocks = pair_blocks(rows, a, b, COORDINATION, pairing, passed)
        if blocks:
            print("%s minus %s, %s: %+.3f (%.3f to %.3f)" % ((a, b, pairing) + bootstrap_mean_diff(blocks)))

    print("\nS8: per passing run, coordination tasks\n| pairing | condition | passing runs | tokens | minutes | rework |\n| --- | --- | --- | --- | --- | --- |")
    for pairing in ("cx", "cc"):
        for cond in ("agentbus", "ledger", "builtin", "none"):
            ok_runs = [r for r in rows if r["pairing"] == pairing and r["condition"] == cond and r["task"] in COORDINATION and r["grade"]["pass"]]
            if ok_runs:
                print("| %s | %s | %d | %.0f | %.2f | %.1f |" % (pairing, cond, len(ok_runs), statistics.mean(tokens(r) for r in ok_runs),
                      statistics.mean(r["grade"]["seconds"] / 60 for r in ok_runs), statistics.mean(r["grade"]["rework_events"] for r in ok_runs)))

    print("\nProtocol steps: share of agents that did each (a manipulation check)\n| condition | read first | claim first | released | finished |\n| --- | --- | --- | --- | --- |")
    for cond in ("agentbus", "ledger", "builtin"):
        agents = [c["protocol"] for r in rows if r["condition"] == cond for c in r["cost"].values() if c.get("protocol")]
        if agents:
            print("| %s | " % cond + " | ".join("%.2f" % (sum(1 for a in agents if a[k]) / len(agents)) for k in ("read_first", "claim_first", "released", "finished")) + " |")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--n", type=int)
    ap.add_argument("--cost", action="store_true")
    args = ap.parse_args(argv)
    rows, dropped = load(args.out)
    print(dropped_summary(dropped))
    if args.cost:
        cost_report(rows)
        return 0
    if not args.n:
        ap.error("name the registered sample size with --n, or use --cost")
    short = missing_cells(rows, args.n)
    if short:
        print("no contrasts: %d cells have fewer than %d runs. Pilot numbers are not results." % (len(short), args.n))
        return 3
    effects(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
