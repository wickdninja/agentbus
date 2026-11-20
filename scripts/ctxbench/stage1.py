#!/usr/bin/env python3
"""ctxbench Stage 1 runner (docs/evals/ctxbench-protocol.md; issue #80, B-M1).

For each cell (N, E, mix) and seed: builds the history (sim.py), replays it into a bus one process per timestamp and
renders the ledger (registered.py), draws the probe instances, runs every arm's registered procedure on a fresh copy,
uncapped and capped, and checks each parser's answer against the oracle. Writes one JSON Lines row per instance and arm,
and the descriptive report (registered.py's cell_report) beside it. It prints no arm numbers.

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


class Cell:
    """One history: its events, built bus snapshots and ledgers, and the copies the arms run on."""

    def __init__(self, run, tmp, hist):
        self.run, self.tmp, self.hist = run, tmp, hist
        self.n = 0
        self.snaps = {}  # step -> bus folder holding that prefix

    def build(self, steps):
        """Replay the whole history into one bus, copying the bus folder after each step in `steps`."""
        h = self.hist
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
            for ev in h.events[h.step_end[frm]:h.step_end[to]]:
                R.apply_event(self.run, os.path.join(copy, "bus.db"), ev)
        else:
            self.write_ledger(copy, to)

    # ---- P1 to P6
    def probe_once(self, spec, arm, cap):
        d = R.execute(self.run, arm, spec["probe"], self.copy(arm, spec["c"]), spec["me"], spec["now"], spec["inputs"], cap)
        return d, R.answer(arm, spec["probe"], d, spec["me"], spec["now"], spec["inputs"])

    # ---- P7
    def session_once(self, spec, arm, cap):
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


def run_with_retries(fn):
    """A replay defect reruns the instance on fresh copies; DEFECT_TRIES defects in a row is returned as a defect."""
    last = None
    for _ in range(DEFECT_TRIES):
        try:
            return fn(), None
        except R.ReplayDefect as exc:
            last = str(exc)
    return None, last


def measure_probe(cell, spec, arm, oracle_answer):
    """(row fields) for one arm of a P1 to P6 instance, or (None, defect text)."""
    def go(cap):
        d, got = cell.probe_once(spec, arm, cap)
        return d, got

    res, defect = run_with_retries(lambda: go(None))
    if defect:
        return None, defect
    d, got = res
    row = {"bytes": d.bytes, "calls": len(d.calls), "outcome": classify(got, oracle_answer),
           "answer": jsonable(got) if got != R.CANNOT else R.CANNOT}
    if any(len(t) > R.CAP for _, t, _ in d.calls):  # a cut is possible: measure again with the cap on a fresh copy
        res, defect = run_with_retries(lambda: go(R.CAP))
        if defect:
            return None, defect
        dc, gotc = res
        row.update(bytes_capped=dc.bytes, outcome_capped=classify(gotc, oracle_answer))
    else:  # no output reached the cap, so the capped run is the uncapped run
        row.update(bytes_capped=d.bytes, outcome_capped=row["outcome"])
    return row, None


def measure_session(cell, spec, arm, oracle_triples):
    def go(cap):
        return cell.session_once(spec, arm, cap)

    def fold(triples):
        outcomes = [classify(got, want) for t, w in zip(triples, oracle_triples) for got, want in zip(t, w)]
        if "wrong" in outcomes:
            return "wrong"
        return "cannot" if "cannot" in outcomes else "ok"

    res, defect = run_with_retries(lambda: go(None))
    if defect:
        return None, defect
    ds, triples = res
    texts = [len(t) for d in ds for _, t, _ in d.calls]
    row = {"bytes": sum(d.bytes for d in ds), "calls": sum(len(d.calls) for d in ds), "outcome": fold(triples),
           "answer": [[jsonable(x) if x != R.CANNOT else R.CANNOT for x in t] for t in triples]}
    if any(n > R.CAP for n in texts):
        res, defect = run_with_retries(lambda: go(R.CAP))
        if defect:
            return None, defect
        dsc, triplesc = res
        row.update(bytes_capped=sum(d.bytes for d in dsc), outcome_capped=fold(triplesc))
    else:
        row.update(bytes_capped=row["bytes"], outcome_capped=row["outcome"])
    return row, None


def run_cell(args, run, tmp, seed, n, e, mix, oracle, out, acc, log):
    hist = sim.build_history(seed, n, e, mix)
    specs, empty = [], []
    for probe in args.probes:
        for i in range(args.instances):
            spec = sim.draw_instance(hist, seed, probe, i)
            (specs if spec else empty).append(spec or {"probe": probe, "instance": i})
    cell = Cell(run, tmp, hist)
    steps = [s["c"] for s in specs]
    cell.build(steps)
    base = {"seed": seed, "N": n, "E": e, "mix": mix}
    defects = 0
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
        rows = {}
        for arm in R.ARMS:
            row, defect = (measure_session if probe == "P7" else measure_probe)(cell, spec, arm, want)
            if defect:
                defects += 1
                out.write(json.dumps(dict(base, type="defect", probe=probe, instance=spec["instance"], arm=arm,
                                          defect=defect)) + "\n")
                rows = None
                break
            rows[arm] = row
        if rows is None:  # a replay defect reruns every arm of the seed: nothing of this instance is scored
            continue
        for arm, row in rows.items():
            meta = {k: v for k, v in spec.items() if k not in ("probe", "instance")}
            out.write(json.dumps(dict(base, type="instance", probe=probe, instance=spec["instance"], arm=arm,
                                      oracle=jsonable_oracle(want), **meta, **row)) + "\n")
            slot = acc.setdefault((n, e, mix, probe), {}).setdefault("arms", {}).setdefault(arm, {}).setdefault(seed, [])
            slot.append((row["bytes"], row["bytes_capped"], row["outcome"], row["outcome_capped"]))
    out.flush()
    log(f"seed {seed} N={n} E={e} {mix}: {len(specs)} instances, {defects} defects")
    return defects


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

def run_unit(settings, cli, base, seed, n, e, mix):
    """One (seed, cell) on its own folder, runner and oracle; returns (results text, accumulator, replay defects). Units
    share nothing, so they can run in separate processes and be merged in a fixed order."""
    args = argparse.Namespace(probes=settings["probes"], instances=settings["instances"],
                              oracle=load_oracle(settings["oracle_file"]))
    tmp = os.path.join(base, f"{seed}-{n}-{e}-{mix}")
    os.makedirs(tmp)
    out, acc = io.StringIO(), {}
    try:
        defects = run_cell(args, R.Runner(cli, tmp), tmp, seed, n, e, mix, args.oracle, out, acc,
                           lambda m: print(m, file=sys.stderr, flush=True))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out.getvalue(), acc, defects


def merge_results(results, out, acc):
    """Write each unit's rows and fold its accumulator into acc, in the order given; returns the replay defect count."""
    defects = 0
    for text, part, n in results:
        out.write(text)
        defects += n
        for key, data in part.items():
            into = acc.setdefault(key, {})
            if "no_candidate" in data:
                into["no_candidate"] = into.get("no_candidate", 0) + data["no_candidate"]
            for arm, seeds in data.get("arms", {}).items():
                for seed, rows in seeds.items():
                    into.setdefault("arms", {}).setdefault(arm, {}).setdefault(seed, []).extend(rows)
    return defects


def parse_cells(text):
    cells = []
    for part in text.split(","):
        n, e, mix = part.split(":")
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
    args.cell_list = parse_cells(args.cells) if args.cells else [(n, e, m) for n in sim.GRID_N for e in sim.GRID_E for m in sim.GRID_MIX]
    args.probes = args.probes.split(",") if args.probes else list(sim.PROBES)
    bad = [p for p in args.probes if p not in sim.PROBES]
    if bad:
        raise SystemExit(f"stage1: unknown probe {bad}")
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
    acc, defects = {}, 0
    units = [(seed, n, e, mix) for seed in args.seed_list for n, e, mix in args.cell_list]
    settings = {"probes": args.probes, "instances": args.instances, "oracle_file": args.oracle_file}
    try:
        with open(args.out, "w") as out:
            out.write(json.dumps(environment_row()) + "\n")
            if args.jobs > 1:
                with ProcessPoolExecutor(max_workers=args.jobs) as pool:
                    futures = [pool.submit(run_unit, settings, cli, base, *u) for u in units]
                    results = (f.result() for f in futures)  # merged in unit order, whatever order they finish in
                    defects = merge_results(results, out, acc)
            else:
                defects = merge_results((run_unit(settings, cli, base, *u) for u in units), out, acc)
        report_path = os.path.splitext(args.out)[0] + ".report.json"
        with open(report_path, "w") as fh:
            json.dump(build_report(acc), fh, indent=1, sort_keys=True)
            fh.write("\n")
    finally:
        if not args.tmp:
            shutil.rmtree(base, ignore_errors=True)
    print(f"stage1: done; results {args.out}, report {report_path}, {defects} replay defects")
    return 3 if defects else 0


if __name__ == "__main__":
    sys.exit(main())
