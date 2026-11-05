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
COORDINATION = ("overlap", "interface", "recovery", "facts")
MIN_PROJECTION_RUNS = 30


def load(out):
    """The manifest joined to grades and costs. Infra failures are dropped here and only here, and returned for the report."""
    rows, dropped = [], []
    for line in open(os.path.join(out, "manifest.jsonl")):
        row = json.loads(line)
        if row["infra"] or row["isolation"]:
            dropped.append(row)
            continue
        with open(os.path.join(out, row["id"], "grade.json")) as f:
            row["grade"] = json.load(f)
        with open(os.path.join(out, row["id"], "cost.json")) as f:
            row["cost"] = json.load(f)
        rows.append(row)
    return rows, dropped


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


def bootstrap_mean_diff(blocks, resamples=RESAMPLES, seed=RNG_SEED):
    """Mean paired difference and a 95% percentile interval, resampling whole seed blocks."""
    keys = sorted(blocks)
    flat = [x for k in keys for x in blocks[k]]
    r = random.Random(seed)
    means = []
    for _ in range(resamples):
        sample = [x for k in (r.choice(keys) for _ in keys) for x in blocks[k]]
        means.append(sum(sample) / len(sample))
    means.sort()
    return sum(flat) / len(flat), percentile(means, 0.025), percentile(means, 0.975)


def bootstrap_ratio(rows, a, b, value, resamples=RESAMPLES, seed=RNG_SEED):
    """Ratio of means, a over b, with a 95% interval, resampling seeds."""
    seeds = sorted({r["seed"] for r in rows})
    per = {s: ([value(r) for r in rows if r["seed"] == s and r["condition"] == a], [value(r) for r in rows if r["seed"] == s and r["condition"] == b]) for s in seeds}
    rnd = random.Random(seed)

    def ratio(chosen):
        xs = [x for s in chosen for x in per[s][0]]
        ys = [y for s in chosen for y in per[s][1]]
        return (sum(xs) / len(xs)) / (sum(ys) / len(ys)) if xs and sum(ys) else float("nan")
    draws = sorted(x for x in (ratio([rnd.choice(seeds) for _ in seeds]) for _ in range(resamples)) if x == x)
    return ratio(seeds), percentile(draws, 0.025), percentile(draws, 0.975)


def over_budget(start, now, done, total, budget, min_runs=MIN_PROJECTION_RUNS):
    """The protocol's Codex stop rule. Quota moves in whole points and the pool is shared, so a projection from a handful of runs
    is noise: it needs min_runs first. Points already spent past the budget halt at any time. A reading below the start is a
    window reset, not a saving, and spends nothing."""
    if start is None or now is None or now <= start:
        return False
    spent = now - start
    return spent > budget or (done >= min_runs and spent * total / done > budget)


def verdict(point, lo, hi):
    """The protocol's table, in code, so a result is read the way it was registered."""
    if lo > 0 and point >= SESOI:
        return "value over a flat file"
    if lo > 0:
        return "real but small: little value"
    if hi < SESOI:
        return "no meaningful value over a flat file"
    return "inconclusive: no evidence of value"


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


def effects(rows):
    passed = lambda r: 1.0 if r["grade"]["pass"] else 0.0  # noqa: E731
    print("| task | condition | pairing | pass | 95% CI | n |\n| --- | --- | --- | --- | --- | --- |")
    keys = sorted({(r["task"], r["condition"], r["pairing"]) for r in rows})
    for t, c, p in keys:
        sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == (t, c, p)]
        k = sum(1 for r in sub if r["grade"]["pass"])
        lo, hi = wilson(k, len(sub))
        print("| %s | %s | %s | %d of %d | %.2f to %.2f | %d |" % (t, c, p, k, len(sub), lo, hi, len(sub)))
    print("\n| task | condition | pairing | fresh tokens | minutes | tool calls | channel calls | rework | merge conflicts | lost features | duplicates | caps hit |\n" + "| --- " * 12 + "|")
    for t, c, p in keys:
        sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == (t, c, p)]
        mean = lambda f: statistics.mean(f(r) for r in sub)  # noqa: E731
        print("| %s | %s | %s | %.0f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %d |" % (
            t, c, p, mean(fresh_tokens), mean(lambda r: r["grade"]["seconds"] / 60), mean(lambda r: sum(a["tool_calls"] for a in r["cost"].values())),
            mean(lambda r: sum(a["channel_calls"] for a in r["cost"].values())), mean(lambda r: r["grade"]["rework_events"]),
            mean(lambda r: len(r["grade"]["merge_conflicts"] or [])), mean(lambda r: len(r["grade"]["lost_features"])), mean(lambda r: len(r["grade"]["duplicates"])),
            sum(1 for r in sub if r["grade"]["stops"])))
    print("\nPrimary")
    for name, pairing in (("P1", "cx"), ("P2", "cc")):
        blocks = pair_blocks(rows, "agentbus", "ledger", COORDINATION, pairing, passed)
        if blocks:
            point, lo, hi = bootstrap_mean_diff(blocks)
            print("%s agentbus minus ledger, %s: %+.3f (%.3f to %.3f): %s" % (name, pairing, point, lo, hi, verdict(point, lo, hi)))
    control = [r for r in rows if r["task"] == "control"]
    if control:
        point, lo, hi = bootstrap_ratio(control, "agentbus", "ledger", fresh_tokens)
        print("P3 control tokens, agentbus over ledger: %.2f (%.2f to %.2f): %s" % (point, lo, hi, "within 1.25" if hi <= 1.25 else "not shown within 1.25"))
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


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--n", type=int)
    ap.add_argument("--cost", action="store_true")
    args = ap.parse_args(argv)
    rows, dropped = load(args.out)
    print("dropped under the protocol's rule: %d%s" % (len(dropped), "".join("\n  %s: %s %s" % (d["id"], d["infra"], d["isolation"]) for d in dropped)))
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
