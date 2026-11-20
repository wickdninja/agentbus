#!/usr/bin/env python3
"""ctxbench Stage 1 runner (docs/evals/ctxbench-protocol.md; issue #80, B-M1).

For each cell (N, E, mix) and seed: builds the history (sim.py), replays it into a bus one process per timestamp and
renders the ledger (registered.py), draws the probe instances, runs every arm's registered procedure on a fresh copy,
uncapped and capped, and checks each parser's answer against the oracle. Writes one JSON Lines row per instance and arm,
and a defects-only summary (<out>.defects.json) beside it; the descriptive report (registered.py's cell_report, <out>.report.json) is
written only with --counted. It prints no arm numbers.

  stage1.py --dev --out results.jsonl                       seeds 9901 and 9902 only, to find defects
  stage1.py --counted --out results.jsonl                   the registered run: the 30 seeds, 18 histories each
  stage1.py --dev --cells 5:50:sparse --probes P1,P7 --instances 1 --out r.jsonl

It refuses to run: a counted seed without --counted; when scripts/ctxbench/oracle.py is absent; and when a model
credential or an agent harness is configured in the environment (names are checked, values are never read or printed).
Stdlib only, Python 3.9+.
"""
import argparse
import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import registered as R  # noqa: E402
import sim  # noqa: E402

OUTCOMES = ("ok", "cannot", "wrong")
CREDENTIAL_NAMES = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
                    "GOOGLE_GENAI_API_KEY", "MISTRAL_API_KEY", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CONFIG_DIR",
                    "CODEX_HOME")
DEFECT_TRIES = 3


def refuse(msg):
    raise SystemExit("stage1: refusing to run: " + msg)


def load_oracle(path=None):
    """The oracle module (scripts/ctxbench/oracle.py, written by another lane), or a refusal naming what is missing."""
    path = path or os.path.join(R.HERE, "oracle.py")
    if not os.path.isfile(path):
        refuse(f"the oracle {path} does not exist (it is written by a separate lane); Stage 1 has nothing to check "
               "the arms' parsers against")
    import importlib.util
    spec = importlib.util.spec_from_file_location("ctxbench_oracle", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if not callable(getattr(mod, "oracle", None)):
        refuse(f"{path} defines no oracle(events, probe, me, now, inputs)")
    return mod.oracle


def check_environment(environ=None):
    environ = os.environ if environ is None else environ
    found = [k for k in CREDENTIAL_NAMES if environ.get(k)]
    found += sorted(k for k in environ if k.startswith(("AGENTBUS_DB", "AGENTBUS_AGENT")) and environ.get(k))
    if found:
        refuse("a model credential, agent harness or bus setting is configured in the environment ("
               + ", ".join(found) + "); unset it. Stage 1 spends no tokens and touches no live bus.")


def tool_version(cmd):
    for flag in ("--version", "-version", "-V", "-v"):
        try:
            r = subprocess.run([cmd, flag], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True,
                               timeout=10, env=dict(os.environ, LC_ALL="C"))
        except (OSError, subprocess.SubprocessError):
            return "not found"
        first = r.stdout.strip().split("\n")[0] if r.stdout.strip() else ""
        if r.returncode == 0 and first:
            return first
    return "version not reported"


def sha256_of(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def environment_row():
    git = subprocess.run(["git", "rev-parse", "HEAD"], cwd=R.ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         universal_newlines=True)
    files = ["scripts/ctxbench/gen_corpus.py"] + [f"scripts/ctxbench/data/{n}" for n in
                                                  ("corpus.txt", "names.txt", "items.txt", "fact_keys.txt")]
    files += ["scripts/ctxbench/registered.py", "scripts/ctxbench/sim.py", "scripts/ctxbench/stage1.py",
              "docs/evals/ctxbench-protocol.md"]
    return {"type": "environment", "os": platform.platform(), "python": sys.version.split("\n")[0],
            "tools": {t: tool_version(t) for t in ("awk", "grep", "sed", "cut", "tail")},
            "commit": git.stdout.strip() or "unknown",
            "sha256": {f: sha256_of(os.path.join(R.ROOT, f)) for f in files}}


# ---- one instance --------------------------------------------------------------------------------------------------

def classify(got, want):
    if got == R.CANNOT:
        return "cannot"
    return "ok" if got == want else "wrong"


def normal(probe, answer):
    """The oracle's answer in the parsers' shape: a set for every probe but P5, an (id, subject) tuple for P5."""
    if probe == "P5":
        return tuple(answer)
    return set(answer)


def jsonable(x):
    if isinstance(x, (set, frozenset)):
        return sorted(x, key=str)
    if isinstance(x, tuple):
        return list(x)
    return x


FAULT = None  # fault-injection hook for tests: a callable (point, context dict) that may raise R.ReplayDefect; never set by the CLI


def inject(point, ctx):
    if FAULT is not None:
        FAULT(point, dict(ctx))


class Cell:
    """One history: its events, built bus snapshots and ledgers, and the copies the arms run on. `ctx` names where the
    runner is (seed, cell, attempt, probe, instance, arm, cap) for defect rows and the fault hook."""

    def __init__(self, run, tmp, hist, ctx):
        self.run, self.tmp, self.hist, self.ctx = run, tmp, hist, ctx
        self.n = 0
        self.snaps = {}  # step -> bus folder holding that prefix

    def build(self, steps):
        """Replay the whole history into one bus, copying the bus folder after each step in `steps`."""
        h = self.hist
        self.ctx.update(point="build", probe=None, instance=None, arm=None, cap=None)
        inject("build", self.ctx)
        bus = os.path.join(self.tmp, "bus")
        os.makedirs(bus)
        db = os.path.join(bus, "bus.db")
        wanted, pos = sorted(set(steps)), 0
        for k in range(1, h.total + 1):
            for ev in h.events[h.step_end[k - 1]:h.step_end[k]]:
                R.apply_event(self.run, db, ev)
            if pos < len(wanted) and wanted[pos] == k:
                dst = os.path.join(self.tmp, "snap", str(k))
                shutil.copytree(bus, dst)
                self.snaps[k] = dst
                pos += 1
        R.check_stored_times(db, [e for e in h.events if e[2] != "inbox"])

    def copy(self, arm, step):
        """A fresh copy of the history as of `step`: the bus folder, or a folder holding COORDINATION.md."""
        self.n += 1
        dst = os.path.join(self.tmp, "copies", str(self.n))
        if arm.startswith("bus-"):
            shutil.copytree(self.snaps[step], dst)
        else:
            os.makedirs(dst)
            self.write_ledger(dst, step)
        return dst

    def write_ledger(self, folder, step):
        with open(os.path.join(folder, "COORDINATION.md"), "w") as fh:
            fh.write(R.render_ledger(self.hist.upto(step)))

    def advance(self, arm, copy, frm, to):
        """Bring a copy from the history as of step `frm` to step `to` (P7's windows): replay for the bus, re-render the
        append-only ledger."""
        h = self.hist
        if arm.startswith("bus-"):
            db = os.path.join(copy, "bus.db")
            for ev in h.events[h.step_end[frm]:h.step_end[to]]:
                R.apply_event(self.run, db, ev)
            self.ctx.update(point="advanced", copy=copy)
            inject("advanced", self.ctx)
            # a timing slip in the replayed window is a replay defect (reruns the seed-cell), never a scored miss
            R.check_stored_times(db, [e for e in h.events[:h.step_end[to]] if e[2] != "inbox"])
        else:
            self.write_ledger(copy, to)

    # ---- P1 to P6
    def probe_once(self, spec, arm, cap):
        self.ctx.update(point="probe", probe=spec["probe"], instance=spec["instance"], arm=arm, cap=cap)
        inject("probe", self.ctx)
        d = R.execute(self.run, arm, spec["probe"], self.copy(arm, spec["c"]), spec["me"], spec["now"], spec["inputs"], cap)
        return d, R.answer(arm, spec["probe"], d, spec["me"], spec["now"], spec["inputs"])

    # ---- P7
    def session_once(self, spec, arm, cap):
        self.ctx.update(point="session", probe="P7", instance=spec["instance"], arm=arm, cap=cap)
        inject("session", self.ctx)
        steps = spec["refreshes"]
        copy = self.copy(arm, steps[0])
        s = R.Session(self.run, arm, copy, spec["me"])
        deliveries, triples = [], []
        for k, step in enumerate(steps):
            if k:
                self.advance(arm, copy, steps[k - 1], step)
            d, triple = s.refresh(self.hist.times[step], cap)
            deliveries.append(d)
            triples.append(triple)
        return deliveries, triples


def measure_probe(cell, spec, arm, oracle_answer):
    """The row fields for one arm of a P1 to P6 instance. A replay defect propagates: the whole seed-cell reruns."""
    d, got = cell.probe_once(spec, arm, None)
    row = {"bytes": d.bytes, "calls": len(d.calls), "outcome": classify(got, oracle_answer),
           "answer": jsonable(got) if got != R.CANNOT else R.CANNOT}
    if any(len(t) > R.CAP for _, t, _ in d.calls):  # a cut is possible: measure again with the cap on a fresh copy
        dc, gotc = cell.probe_once(spec, arm, R.CAP)
        row.update(bytes_capped=dc.bytes, calls_capped=len(dc.calls), outcome_capped=classify(gotc, oracle_answer))
    else:  # no output reached the cap, so the capped run is the uncapped run
        row.update(bytes_capped=d.bytes, calls_capped=row["calls"], outcome_capped=row["outcome"])
    return row


def measure_session(cell, spec, arm, oracle_triples):
    def fold(triples):
        outcomes = [classify(got, want) for t, w in zip(triples, oracle_triples) for got, want in zip(t, w)]
        if "wrong" in outcomes:
            return "wrong"
        return "cannot" if "cannot" in outcomes else "ok"

    ds, triples = cell.session_once(spec, arm, None)
    texts = [len(t) for d in ds for _, t, _ in d.calls]
    row = {"bytes": sum(d.bytes for d in ds), "calls": sum(len(d.calls) for d in ds), "outcome": fold(triples),
           "answer": [[jsonable(x) if x != R.CANNOT else R.CANNOT for x in t] for t in triples]}
    if any(n > R.CAP for n in texts):
        dsc, triplesc = cell.session_once(spec, arm, R.CAP)
        row.update(bytes_capped=sum(d.bytes for d in dsc), calls_capped=sum(len(d.calls) for d in dsc),
                   outcome_capped=fold(triplesc))
    else:
        row.update(bytes_capped=row["bytes"], calls_capped=row["calls"], outcome_capped=row["outcome"])
    return row


def run_cell(args, run, tmp, seed, n, e, mix, out, acc, ctx):
    hist = sim.build_history(seed, n, e, mix)
    specs, empty = [], []
    for probe in args.probes:
        for i in range(args.instances):
            spec = sim.draw_instance(hist, seed, probe, i)
            (specs if spec else empty).append(spec or {"probe": probe, "instance": i})
    cell = Cell(run, tmp, hist, ctx)
    steps = [s["c"] for s in specs]
    cell.build(steps)
    base = {"seed": seed, "N": n, "E": e, "mix": mix}
    for spec in empty:
        out.write(json.dumps(dict(base, type="no-p7-candidate", probe=spec["probe"], instance=spec["instance"])) + "\n")
        acc.setdefault((n, e, mix, "P7"), {}).setdefault("no_candidate", 0)
        acc[(n, e, mix, "P7")]["no_candidate"] += 1
    for spec in specs:
        probe = spec["probe"]
        if probe == "P7":
            want = [tuple(normal(p, args.oracle(hist.upto(k), p, spec["me"], hist.times[k], {}))
                          for p in ("P1", "P3", "P4")) for k in spec["refreshes"]]
        else:
            want = normal(probe, args.oracle(hist.upto(spec["c"]), probe, spec["me"], spec["now"], spec["inputs"]))
        rows = {arm: (measure_session if probe == "P7" else measure_probe)(cell, spec, arm, want) for arm in R.ARMS}
        for arm, row in rows.items():
            meta = {k: v for k, v in spec.items() if k not in ("probe", "instance")}
            out.write(json.dumps(dict(base, type="instance", probe=probe, instance=spec["instance"], arm=arm,
                                      oracle=jsonable_oracle(want), **meta, **row)) + "\n")
            slot = acc.setdefault((n, e, mix, probe), {}).setdefault("arms", {}).setdefault(arm, {}).setdefault(seed, [])
            slot.append((row["bytes"], row["bytes_capped"], row["outcome"], row["outcome_capped"]))
    out.flush()
    return len(specs)


def jsonable_oracle(want):
    if isinstance(want, list):
        return [[jsonable(x) for x in t] for t in want]
    return jsonable(want)


# ---- the report ------------------------------------------------------------------------------------------------

def build_report(acc):
    report = []
    for (n, e, mix, probe), data in sorted(acc.items()):
        entry = {"N": n, "E": e, "mix": mix, "probe": probe, "no_p7_candidate": data.get("no_candidate", 0)}
        arms = data.get("arms", {})
        for variant, bi, oi in (("uncapped", 0, 2), ("capped", 1, 3)):
            seeds = sorted({s for a in arms.values() for s in a})
            per_seed = {a: [sum(r[bi] for r in arms[a][s]) / len(arms[a][s]) for s in seeds if s in arms[a]] for a in arms}
            outcomes = {a: [[r[oi] for r in arms[a][s]] for s in seeds if s in arms[a]] for a in arms}
            if per_seed:
                rep = R.cell_report(per_seed, outcomes)
                rep["agreement"] = {a: {"oracle_agrees": v["derivable"], "oracle_disagrees": v["wrong"],
                                        "cannot_decide": v["cannot_decide"], "run": v["run"]}
                                    for a, v in rep["derivability"].items()}
                entry[variant] = rep
        report.append(entry)
    return report


# ---- command line ----------------------------------------------------------------------------------------------

def scratch_dir(base, seed, n, e, mix):
    """A scratch folder no other unit or attempt shares, even for the same unit."""
    return tempfile.mkdtemp(prefix=f"{seed}-{n}-{e}-{mix}.", dir=base)


def run_unit(settings, cli, base, seed, n, e, mix):
    """One (seed, cell) on its own folder, runner and oracle. A replay defect reruns the whole seed-cell, every arm of
    every instance, on a fresh folder, up to DEFECT_TRIES times; a seed-cell that still has a defect is excluded: it
    writes defect rows and no instance rows, and the report never sees it. Every defect is a row, a cleared one too.
    Returns {"text": results rows, "acc": the report's accumulator, "defects": [rows], "excluded": bool, "instances": n}.
    Units share nothing, so they can run in separate processes and be merged in a fixed order."""
    args = argparse.Namespace(probes=settings["probes"], instances=settings["instances"],
                              oracle=load_oracle(settings["oracle_file"]))
    unit = {"seed": seed, "N": n, "E": e, "mix": mix}
    defects = []
    for attempt in range(1, DEFECT_TRIES + 1):
        tmp = scratch_dir(base, seed, n, e, mix)
        out, acc = io.StringIO(), {}
        ctx = dict(unit, attempt=attempt)
        try:
            count = run_cell(args, R.Runner(cli, tmp), tmp, seed, n, e, mix, out, acc, ctx)
        except R.ReplayDefect as exc:
            last = attempt == DEFECT_TRIES
            defects.append(dict(unit, type="defect", attempt=attempt, where={k: ctx.get(k) for k in ("point", "probe", "instance", "arm", "cap")},
                                defect=str(exc), outcome="excluded" if last else "rerun"))
            continue
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        text = "".join(json.dumps(d) + "\n" for d in defects) + out.getvalue()
        print(f"seed {seed} N={n} E={e} {mix}: {count} instances, {len(defects)} defects", file=sys.stderr, flush=True)
        return {"text": text, "acc": acc, "defects": defects, "excluded": False, "instances": count}
    print(f"seed {seed} N={n} E={e} {mix}: excluded after {DEFECT_TRIES} defects", file=sys.stderr, flush=True)
    return {"text": "".join(json.dumps(d) + "\n" for d in defects), "acc": {}, "defects": defects, "excluded": True,
            "instances": 0}


def disagreements(text):
    """The oracle-parser disagreements of a unit's rows, one entry each (no counts by arm)."""
    out = []
    for line in text.splitlines():
        r = json.loads(line)
        if r["type"] == "instance":
            for variant, key in (("uncapped", "outcome"), ("capped", "outcome_capped")):
                if r[key] == "wrong":
                    out.append({k: r[k] for k in ("seed", "N", "E", "mix", "probe", "instance", "arm")} | {"variant": variant})
    return out


def merge_results(results, out, acc):
    """Write each unit's rows and fold its accumulator into acc, in the order given; returns the defect summary:
    defects and oracle-parser disagreements only, never a per-arm aggregate."""
    summary = {"defect_rows": [], "excluded_seed_cells": [], "oracle_parser_disagreements": [], "defects_cleared_by_rerun": 0}
    for r in results:
        out.write(r["text"])
        summary["defect_rows"] += r["defects"]
        if not r["excluded"]:
            summary["defects_cleared_by_rerun"] += len(r["defects"])
        if r["excluded"]:
            d = r["defects"][-1]
            summary["excluded_seed_cells"].append({k: d[k] for k in ("seed", "N", "E", "mix")})
        summary["oracle_parser_disagreements"] += disagreements(r["text"])
        for key, data in r["acc"].items():
            into = acc.setdefault(key, {})
            if "no_candidate" in data:
                into["no_candidate"] = into.get("no_candidate", 0) + data["no_candidate"]
            for arm, seeds in data.get("arms", {}).items():
                for seed, rows in seeds.items():
                    into.setdefault("arms", {}).setdefault(arm, {}).setdefault(seed, []).extend(rows)
    summary["defects_total"] = len(summary["defect_rows"])
    return summary


def parse_cells(text, dev_only=False):
    """Cells as N:E:MIX. Counted seeds take only the registered grid; development seeds (never counted) may use any
    N >= 2 and E >= 10 so tests can stay small."""
    cells = []
    for part in text.split(","):
        n, e, mix = part.split(":")
        if dev_only and int(n) >= 2 and int(e) >= 10 and mix in sim.GRID_MIX:
            cells.append((int(n), int(e), mix))
            continue
        if int(n) not in sim.GRID_N or int(e) not in sim.GRID_E or mix not in sim.GRID_MIX:
            raise SystemExit(f"stage1: cell {part!r} is not in the grid (N {sim.GRID_N}, E {sim.GRID_E}, mix {sim.GRID_MIX})")
        cells.append((int(n), int(e), mix))
    return cells


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cells", help="comma-separated N:E:MIX (default: all 18)")
    ap.add_argument("--seeds", help="comma-separated seeds (default: the protocol's 30)")
    ap.add_argument("--dev", action="store_true", help="run only the development seeds 9901 and 9902")
    ap.add_argument("--counted", action="store_true", help="allow the protocol's counted seeds (the registered run)")
    ap.add_argument("--probes", help="comma-separated probes (default: P1 to P7)")
    ap.add_argument("--instances", type=int, default=sim.M_INSTANCES, help="instances per seed, cell and probe (default 10)")
    ap.add_argument("--out", default="ctxbench-stage1.jsonl", help="results file (JSON Lines); the report goes beside it")
    ap.add_argument("--cli", help="the command that runs agentbus, split on whitespace (default: this Python and bin/agentbus)")
    ap.add_argument("--oracle-file", help="load the oracle from this file instead of scripts/ctxbench/oracle.py (tests)")
    ap.add_argument("--jobs", type=int, default=1, help="run (seed, cell) units in this many processes; the results file "
                    "is identical to a serial run (units are merged in a fixed order)")
    ap.add_argument("--tmp", help="working folder for buses and copies (default: a new temp folder, removed after)")
    args = ap.parse_args(argv)
    if args.dev and args.seeds:
        raise SystemExit("stage1: --dev and --seeds are exclusive")
    args.seed_list = sim.DEV_SEEDS if args.dev else ([int(x) for x in args.seeds.split(",")] if args.seeds else sim.SEEDS)
    dev_only = all(s in sim.DEV_SEEDS for s in args.seed_list)
    args.cell_list = parse_cells(args.cells, dev_only) if args.cells else [(n, e, m) for n in sim.GRID_N for e in sim.GRID_E for m in sim.GRID_MIX]
    args.probes = args.probes.split(",") if args.probes else list(sim.PROBES)
    bad = [p for p in args.probes if p not in sim.PROBES]
    if bad:
        raise SystemExit(f"stage1: unknown probe {bad}")
    if args.counted:
        full = [(n, e, m) for n in sim.GRID_N for e in sim.GRID_E for m in sim.GRID_MIX]
        why = [w for w, bad in (
            ("--dev", args.dev), ("a seed list other than the 30 registered seeds", args.seed_list != sim.SEEDS),
            ("a cell subset", sorted(args.cell_list) != sorted(full)),
            ("a probe subset", args.probes != list(sim.PROBES)),
            ("--instances other than 10", args.instances != sim.M_INSTANCES)) if bad]
        if why:
            raise SystemExit("stage1: --counted is exactly the registered design; refused with " + ", ".join(why))
    for what, items in (("seeds", args.seed_list), ("cells", args.cell_list)):
        dup = sorted({str(x) for x in items if items.count(x) > 1})
        if dup:
            raise SystemExit(f"stage1: duplicate {what} {dup}: every (seed, cell) unit must be unique")
    if args.jobs < 1:
        raise SystemExit("stage1: --jobs must be at least 1")
    if args.instances < 1:
        raise SystemExit("stage1: --instances must be at least 1")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    counted = [s for s in args.seed_list if s in sim.SEEDS]
    if counted and not args.counted:
        refuse(f"seeds {counted[:3]}{'...' if len(counted) > 3 else ''} are the protocol's counted seeds; pass --counted "
               "for the registered run (use --dev for the development seeds)")
    args.oracle = load_oracle(args.oracle_file)
    check_environment()
    cli = args.cli.split() if args.cli else [sys.executable, os.path.join(R.ROOT, "bin", "agentbus")]
    base = args.tmp or tempfile.mkdtemp(prefix="ctxbench-stage1.")
    acc = {}
    units = [(seed, n, e, mix) for seed in args.seed_list for n, e, mix in args.cell_list]
    settings = {"probes": args.probes, "instances": args.instances, "oracle_file": args.oracle_file}
    stem = os.path.splitext(args.out)[0]
    try:
        with open(args.out, "w") as out:
            out.write(json.dumps(environment_row()) + "\n")
            if args.jobs > 1:
                with ProcessPoolExecutor(max_workers=args.jobs) as pool:
                    futures = [pool.submit(run_unit, settings, cli, base, *u) for u in units]
                    results = (f.result() for f in futures)  # merged in unit order, whatever order they finish in
                    summary = merge_results(results, out, acc)
            else:
                summary = merge_results((run_unit(settings, cli, base, *u) for u in units), out, acc)
        with open(stem + ".defects.json", "w") as fh:
            json.dump(summary, fh, indent=1, sort_keys=True)
            fh.write("\n")
        report_path = None
        if args.counted:  # arm comparisons exist only for the registered run (protocol: development seeds are never summarised by arm)
            report_path = stem + ".report.json"
            with open(report_path, "w") as fh:
                json.dump(build_report(acc), fh, indent=1, sort_keys=True)
                fh.write("\n")
    finally:
        if not args.tmp:
            shutil.rmtree(base, ignore_errors=True)
    ex = len(summary["excluded_seed_cells"])
    print(f"stage1: done; results {args.out}, defects {stem}.defects.json" + (f", report {report_path}" if report_path else "")
          + f"; {summary['defects_total']} replay defects ({summary['defects_cleared_by_rerun']} cleared by rerun), "
          f"{ex} seed-cells excluded")
    return 3 if ex else 0


if __name__ == "__main__":
    sys.exit(main())
