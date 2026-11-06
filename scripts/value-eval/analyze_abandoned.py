#!/usr/bin/env python3
"""Follow-up abandoned analysis (docs/evals/value-protocol.md, addenda): does the todo build keep promised work from being lost as
well as a ledger with the same instructions? A separate batch, read on its own; nothing here reads or changes another study.

python3 scripts/value-eval/analyze_abandoned.py OUT --n 20    the registered contrasts, only once all eight cells have 20 runs
python3 scripts/value-eval/analyze_abandoned.py OUT --cost    harness numbers only, safe on a pilot

Needs grade.py and channel_grade.py run on OUT first.

The margin test is exact. Runs are paired by seed; with n pairs, a10 seeds where only agentbus passed and a01 where only the ledger
did, the hypothesis "agentbus is at most MARGIN worse" (H0: p10 - p01 <= -MARGIN) is tested with Tango's score statistic, and its p
value is the largest tail probability over every value of the nuisance parameter on the null boundary (an exact unconditional test,
evaluated on a grid of step GRID). Twenty ties therefore give p of at least 0.9 ** 20 = 0.12: a ceiling cannot show
non-inferiority, which the bootstrap of the earlier study did (its p was near 0 on twenty ties).
"""
import argparse
import math
import os
import statistics
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze  # noqa: E402

MARGIN, N, ALPHA, GRID = 0.10, 20, 0.025, 0.00025
GRID_CI = 0.002           # the interval is descriptive, so its bisection uses a coarser grid; every decision uses GRID
SEEDS = (41, 60)          # counted seeds, inclusive; never used by another study
TASKS, CONDITIONS, PAIRINGS = ("abandoned", "finished"), ("agentbus", "ledger"), ("cx", "cc")
FAMILY = (("R-cx", "abandoned", "cx", "recovered", "recovery"), ("R-cc", "abandoned", "cc", "recovered", "recovery"),
          ("D-cx", "abandoned", "cx", "discovered", "discovery"), ("D-cc", "abandoned", "cc", "discovered", "discovery"),
          ("G-cx", "finished", "cx", "clean", "nothing open, nothing broken"), ("G-cc", "finished", "cc", "clean", "nothing open, nothing broken"))


def _outcomes(n):
    """Every (a10, a01) with a10 + a01 <= n, and the log multinomial coefficient of each."""
    lf = [math.lgamma(k + 1) for k in range(n + 1)]
    return [(a, b, lf[n] - lf[a] - lf[b] - lf[n - a - b]) for a in range(n + 1) for b in range(n + 1 - a)]


def _restricted_p01(a, b, n, delta0):
    """The maximum-likelihood p01 under p10 = p01 + delta0, on [max(0, -delta0), (1 - delta0) / 2]."""
    lo, hi = max(0.0, -delta0), (1.0 - delta0) / 2
    c = n - a - b

    def loglik(p):
        terms = ((a, p + delta0), (b, p), (c, 1 - 2 * p - delta0))
        if any(k > 0 and q <= 0 for k, q in terms):
            return -math.inf
        return sum(k * math.log(q) for k, q in terms if k > 0)
    bq = (a + b) * (1 - delta0) - 2 * delta0 * (b + c)
    disc = bq * bq + 8 * n * b * delta0 * (1 - delta0)
    cands = [lo, hi]
    if disc >= 0:
        cands += [(bq + s * math.sqrt(disc)) / (4 * n) for s in (1, -1)]
    cands = [min(hi, max(lo, x)) for x in cands]
    return max(cands, key=loglik)


def score(a, b, n, delta0):
    """Tango's statistic for H0: p10 - p01 = delta0. Large means agentbus is ahead of delta0."""
    p01 = _restricted_p01(a, b, n, delta0)
    var = (2 * p01 + delta0 - delta0 * delta0) / n
    diff = (a - b) / n - delta0
    if var <= 1e-15:
        return 0.0 if abs(diff) < 1e-12 else math.copysign(math.inf, diff)
    return diff / math.sqrt(var)


_CACHE = {}


def _p_values(n, delta0, side, step=GRID):
    """{(a10, a01): exact unconditional p} for every outcome at once. side "above": H0 p10 - p01 <= delta0 (large scores reject);
    "below": H0 p10 - p01 >= delta0 (small scores reject); "two": H0 p10 - p01 = delta0 (large |score| rejects). The nuisance p01
    runs over its whole null range in steps of `step`; each outcome's p is the largest tail seen."""
    key = (n, round(delta0, 12), side, step)
    if key in _CACHE:
        return _CACHE[key]
    outs = _outcomes(n)
    sign = {"above": 1, "below": -1}
    stat = [(abs(score(a, b, n, delta0)) if side == "two" else sign[side] * score(a, b, n, delta0)) for a, b, _ in outs]
    order = sorted(range(len(outs)), key=lambda i: -stat[i])
    groups = []   # outcomes with equal statistics share one tail
    for i in order:
        if groups and abs(stat[groups[-1][0]] - stat[i]) < 1e-9:
            groups[-1].append(i)
        else:
            groups.append([i])
    terms = [[(outs[i][0], outs[i][1], n - outs[i][0] - outs[i][1], outs[i][2]) for i in g] for g in groups]
    lo, hi = max(0.0, -delta0), (1.0 - delta0) / 2
    steps = max(1, int(round((hi - lo) / step)))
    best = [0.0] * len(groups)
    exp = math.exp
    for k in range(steps + 1):
        p01 = lo + (hi - lo) * k / steps
        p10, pc = p01 + delta0, 1 - 2 * p01 - delta0
        l10 = math.log(p10) if p10 > 0 else None
        l01 = math.log(p01) if p01 > 0 else None
        lc = math.log(pc) if pc > 0 else None
        run = 0.0
        for g, members in enumerate(terms):
            for a, b, c, coef in members:
                if (a and l10 is None) or (b and l01 is None) or (c and lc is None):
                    continue
                run += exp(coef + (a * l10 if a else 0.0) + (b * l01 if b else 0.0) + (c * lc if c else 0.0))
            if run > best[g]:
                best[g] = run
    out = {}
    for g, members in enumerate(groups):
        for i in members:
            out[(outs[i][0], outs[i][1])] = min(1.0, best[g])
    _CACHE[key] = out
    return out


def exact_ni_p(a10, a01, n, margin=MARGIN):
    """One-sided exact p for non-inferiority: H0 says agentbus is worse by margin or more."""
    return _p_values(n, -margin, "above")[(a10, a01)]


def exact_two_sided_p(a10, a01, n):
    """Exact unconditional two-sided p for no difference at all (both arms pass equally often)."""
    if a10 == a01 == 0:
        return 1.0
    return _p_values(n, 0.0, "two")[(a10, a01)]


def rejection_rate(n, margin, p10, p01, alpha):
    """The chance that the non-inferiority test rejects at alpha when the truth is (p10, p01): full enumeration, no simulation."""
    pv = _p_values(n, -margin, "above")
    total = 0.0
    for a, b, coef in _outcomes(n):
        if pv[(a, b)] <= alpha:
            c = n - a - b
            parts = [(a, p10), (b, p01), (c, 1 - p10 - p01)]
            if all(cnt == 0 or q > 0 for cnt, q in parts):
                total += math.exp(coef + sum(cnt * math.log(q) for cnt, q in parts if cnt))
    return total


def exact_interval(a10, a01, n, level=0.95):
    """The two-sided interval for p10 - p01 that inverts the two one-sided exact tests (each at (1 - level) / 2), by bisection on a
    grid of GRID_CI. Descriptive: decisions use exact_ni_p and exact_two_sided_p."""
    tail = (1 - level) / 2
    point = (a10 - a01) / n

    def bound(side):
        inside, outside = point, (-1.0 if side == "above" else 1.0)
        for _ in range(16):
            mid = (inside + outside) / 2
            if _p_values(n, mid, side, GRID_CI)[(a10, a01)] > tail:
                inside = mid
            else:
                outside = mid
        return inside
    return bound("above"), bound("below")


def load(out):
    rows, dropped = analyze.load(out)
    for r in rows:
        g = r["grade"]
        g["clean"] = bool(g.get("discovered")) and bool(g.get("recovered"))
        path = os.path.join(out, r["id"], "channel.json")
        r["channel"] = analyze_json(path)
    return rows, dropped


def analyze_json(path):
    import json
    if not os.path.isfile(path):
        return {}
    with open(path) as f:
        return json.load(f)


def short_cells(rows, n):
    counts = {}
    for r in rows:
        k = (r["task"], r["condition"], r["pairing"])
        counts[k] = counts.get(k, 0) + 1
    return [(t, c, p) for t in TASKS for c in CONDITIONS for p in PAIRINGS if counts.get((t, c, p), 0) < n]


def discordant(rows, task, pairing, measure):
    """(n pairs, agentbus-only passes, ledger-only passes) over the seeds where both arms ran."""
    cell = {}
    for r in rows:
        if r["task"] == task and r["pairing"] == pairing and r["condition"] in CONDITIONS:
            cell[(r["seed"], r["condition"])] = bool(r["grade"].get(measure))
    seeds = sorted({s for s, _c in cell if (s, "agentbus") in cell and (s, "ledger") in cell})
    a10 = sum(1 for s in seeds if cell[(s, "agentbus")] and not cell[(s, "ledger")])
    a01 = sum(1 for s in seeds if cell[(s, "ledger")] and not cell[(s, "agentbus")])
    return len(seeds), a10, a01


def share(xs):
    xs = list(xs)
    return "%d of %d" % (sum(1 for x in xs if x), len(xs))


def effects(rows):
    print("| task | condition | pairing | discovered | recovered | both | n |\n| --- | --- | --- | --- | --- | --- | --- |")
    for t in TASKS:
        for c in CONDITIONS:
            for p in PAIRINGS:
                sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == (t, c, p)]
                print("| %s | %s | %s | %s | %s | %s | %d |" % (t, c, p, share(r["grade"].get("discovered") for r in sub),
                      share(r["grade"].get("recovered") for r in sub), share(r["grade"].get("clean") for r in sub), len(sub)))

    print("\nPrimary (one family of six, Holm-corrected, one-sided alpha %.3f; non-inferior means agentbus is shown at most %d points "
          "below the ledger, by the exact test)" % (ALPHA, round(MARGIN * 100)))
    found = {}
    for name, task, pairing, measure, _label in FAMILY:
        n, a10, a01 = discordant(rows, task, pairing, measure)
        found[name] = (n, a10, a01, exact_ni_p(a10, a01, n) if n else 1.0)
    adjusted = analyze.holm({k: v[3] for k, v in found.items()})
    shown = {}
    for name, _task, pairing, _measure, label in FAMILY:
        n, a10, a01, p = found[name]
        lo, hi = exact_interval(a10, a01, n) if n else (-1.0, 1.0)
        two = exact_two_sided_p(a10, a01, n) if n else 1.0
        shown[name] = adjusted[name] < ALPHA
        verdict = ("non-inferior: agentbus within %d points of the ledger" % round(MARGIN * 100)) if shown[name] else "not shown within the margin"
        if two < 0.05 and a01 > a10:
            verdict += "; the ledger does better"
        elif two < 0.05 and a10 > a01:
            verdict += "; agentbus does better"
        print("%s %s, %s: agentbus minus ledger %+.3f (agentbus only %d, ledger only %d, of %d seeds), exact 95%% interval %+.3f to %+.3f, "
              "non-inferiority p %.4f, Holm p %.4f, two-sided p of no difference %.4f: %s" % (
                  name, label, pairing, (a10 - a01) / n if n else 0.0, a10, a01, n, lo, hi, p, adjusted[name], two, verdict))
    for pairing in PAIRINGS:
        held = all(shown[x + "-" + pairing] for x in ("R", "D", "G"))
        print("Conclusion, %s: %s" % (pairing, "todo keeps promised work at least as well as the ledger, within the margin" if held else
                                       "not shown that todo keeps promised work as well as the ledger"))

    print("\nabandoned, from the channel (not blind)\n| condition | pairing | alice recorded all three | as todos | closed the one she finished | "
          "bob closed what he finished | open at handover |\n| --- | --- | --- | --- | --- | --- | --- |")
    for c in CONDITIONS:
        for p in PAIRINGS:
            sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == ("abandoned", c, p)]
            roles = [r["channel"].get("roles", {}) for r in sub]
            opened = {}
            for r in sub:
                key = ",".join(r["grade"].get("open") or []) or "none"
                opened[key] = opened.get(key, 0) + 1
            print("| %s | %s | %s | %s | %s | %s | %s |" % (
                c, p, share((x.get("alice") or {}).get("named_all") for x in roles), share((x.get("alice") or {}).get("todos_all") for x in roles),
                share((x.get("alice") or {}).get("closed_done") for x in roles), share((x.get("bob") or {}).get("closed_all") for x in roles),
                ", ".join("%s %d" % kv for kv in sorted(opened.items()))))

    print("\nfinished, from the channel (not blind)\n| condition | pairing | alice closed all three | named a finished item as open | "
          "broke or redid work |\n| --- | --- | --- | --- | --- |")
    for c in CONDITIONS:
        for p in PAIRINGS:
            sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == ("finished", c, p)]
            print("| %s | %s | %s | %s | %s |" % (c, p, share((r["channel"].get("roles", {}).get("alice") or {}).get("closed_all") for r in sub),
                  share(bool(r["grade"].get("named")) for r in sub), share(not r["grade"].get("recovered") for r in sub)))

    cols = ("tokens", "fresh tokens", "minutes", "tool calls", "channel calls", "channel writes")
    print("\n| task | condition | pairing | " + " | ".join(cols) + " |\n" + "| --- " * (len(cols) + 3) + "|")
    for t in TASKS:
        for c in CONDITIONS:
            for p in PAIRINGS:
                sub = [r for r in rows if (r["task"], r["condition"], r["pairing"]) == (t, c, p)]
                if not sub or not all(r.get("cost") for r in sub):
                    continue
                vals = [statistics.mean(f(r) for r in sub) for f in (analyze.tokens, analyze.fresh_tokens, lambda r: r["grade"]["seconds"] / 60,
                        lambda r: analyze._sum(r, "tool_calls"), lambda r: analyze._sum(r, "channel_calls"), lambda r: analyze._sum(r, "channel_writes"))]
                print("| %s | %s | %s | " % (t, c, p) + " | ".join("%.1f" % v for v in vals) + " |")


def power_table(n=N, alpha=ALPHA, family=None):
    """What the registered test can show at n, stated before any run: the fewest agentbus-only seeds that show non-inferiority with
    none the other way, unadjusted and at the strictest Holm step, and the chance of showing it when both arms truly pass alike."""
    family = family or len(FAMILY)
    lines = []
    for a01 in (0, 1, 2):
        need = [a for a in range(0, n - a01 + 1) if exact_ni_p(a, a01, n) < alpha]
        strict = [a for a in range(0, n - a01 + 1) if exact_ni_p(a, a01, n) < alpha / family]
        lines.append("ledger-only seeds %d: non-inferior needs at least %s agentbus-only seeds (%s at the strictest Holm step)" % (
            a01, need[0] if need else "more than n", strict[0] if strict else "more than n"))
    for q in (0.0, 0.1, 0.2):
        lines.append("both arms alike, %d%% of seeds discordant each way: shown with probability %.3f" % (
            round(q * 100), rejection_rate(n, MARGIN, q, q, alpha)))
    return lines


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?")
    ap.add_argument("--n", type=int)
    ap.add_argument("--cost", action="store_true")
    ap.add_argument("--power", action="store_true", help="print what the registered test can show at n = 20, and stop")
    args = ap.parse_args(argv)
    if args.power:
        print("\n".join(power_table()))
        return 0
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
    effects([r for r in rows if r["condition"] in CONDITIONS])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
