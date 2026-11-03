#!/usr/bin/env python3
"""Mutation check: break one behaviour of bin/agentbus on purpose and require a test to notice.

  python3 scripts/mutate.py NAME            run one mutation from tests/mutations.json
  python3 scripts/mutate.py --all           run every mutation whose test file exists
  python3 scripts/mutate.py --list          print the names
  --mutations FILE                          use another mutations file (tests/test_mutations.sh does)
  -j N, --jobs N                            run N mutations at once (default min(cpu count, 4); the environment
                                            variable AGENTBUS_MUTATION_JOBS sets it too, -j wins)

tests/mutations.json is an array of {"name", "file", "find", "replace", "count", "run", "expect"}, plus an
optional "after" (the stream that adds the test, shown when the entry is skipped):
  file     the file to mutate, relative to the repo root (bin/agentbus)
  find     a regex (re.MULTILINE); replace is its re.sub template
  count    how many times find must match; any other number is a stale mutation and fails loudly
  run      the test file that must fail against the mutated copy
  expect   text that must appear in the test's own FAIL line: the mutation counts as killed only when the test
           fails for that reason, not when it crashes, times out, or cannot find its interpreter

Each distinct test file is first run unmutated and must pass (exit 77 skips its entries). The mutated run is then
classified: KILLED (exit non-zero, a FAIL line holding `expect`), WRONG (a FAIL line without it), SURVIVED (exit 0),
TIMEOUT (over MUTATE_TIMEOUT seconds, default 400, below run_all's per-file cap), CRASHED (non-zero exit with no FAIL
line: a traceback, a missing interpreter), STALE (the pattern matches the wrong number of times).

Mutations are independent, so they run in a bounded pool of threads, each driving its own subprocess in its own
temp dir with its own HOME and TMPDIR (nothing shared between two running tests). Results print in file order,
whatever order they finish in, and the summary line is the same at any -j.

The test runs from a shadow tree in a temp dir (symlinks to the checkout, the mutated file real), so BIN
in tests/lib.sh is the mutated copy; AGENTBUS_BIN names it too, which tests/lib.sh and
tests/agentbus_cmd.py honour (AGENTBUS_CMD is dropped so the copy is what runs). An entry whose
test file does not exist yet is skipped with a printed line.

Exit 0: every selected mutation killed. 1: a mutation survived, was killed for another reason, or timed out.
2: stale, crashed, a baseline that fails, or unusable (unknown name, bad file).
"""
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FILE = os.path.join(ROOT, "tests", "mutations.json")
TIMEOUT = int(os.environ.get("MUTATE_TIMEOUT", "400"))


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            entries = json.load(f)
    except (OSError, ValueError) as e:
        print("mutate: cannot read %s: %s" % (path, e), file=sys.stderr)
        sys.exit(2)
    if not isinstance(entries, list):
        print("mutate: %s must hold a JSON array" % path, file=sys.stderr)
        sys.exit(2)
    names = set()
    for e in entries:
        missing = [k for k in ("name", "file", "find", "replace", "count", "run", "expect") if k not in e]
        if missing:
            print("mutate: entry %r lacks %s" % (e.get("name"), ", ".join(missing)), file=sys.stderr)
            sys.exit(2)
        if e["name"] in names:
            print("mutate: duplicate name %r" % e["name"], file=sys.stderr)
            sys.exit(2)
        if not isinstance(e["expect"], str) or not e["expect"].strip():
            print("mutate: entry %r has an empty expect: name the FAIL text that must kill it" % e["name"], file=sys.stderr)
            sys.exit(2)
        names.add(e["name"])
    return entries


def shadow(root, tmp, rel, text):
    """A copy of the tree in tmp where every entry is a symlink to the checkout except the mutated
    file, which is a real file holding `text` (the directories on its way are real too). Returns
    the mutated file's path."""
    src, dst = root, tmp
    parts = rel.split("/")
    for i, part in enumerate(parts):
        for name in os.listdir(src):
            if name != part:
                os.symlink(os.path.join(src, name), os.path.join(dst, name))
        if i < len(parts) - 1:
            src, dst = os.path.join(src, part), os.path.join(dst, part)
            os.mkdir(dst)
    target = os.path.join(dst, parts[-1])
    with open(target, "w", encoding="utf-8") as f:
        f.write(text)
    shutil.copymode(os.path.join(src, parts[-1]), target)
    return target


def _env(copy, work):
    """The environment of one test run: nothing inherited that names a bus, a config dir or a home, and a HOME and
    TMPDIR of its own inside `work`, so two runs at once share no file."""
    env = dict(os.environ)
    for k in ("AGENTBUS_CMD", "AGENTBUS_DB", "AGENTBUS_AGENT", "CODEX_HOME", "CLAUDE_CONFIG_DIR"):
        env.pop(k, None)
    home, tmpdir = os.path.join(work, "h"), os.path.join(work, "t")
    os.makedirs(home, exist_ok=True)
    os.makedirs(tmpdir, exist_ok=True)
    env["HOME"] = home
    env["TMPDIR"] = tmpdir
    env["AGENTBUS_BIN"] = copy
    return env


def _run(test, cwd, env):
    """(returncode or None on timeout, output text)."""
    try:
        p = subprocess.run(["bash", test], env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=TIMEOUT)
    except subprocess.TimeoutExpired as err:
        return None, (err.stdout or b"").decode("utf-8", "replace")
    return p.returncode, p.stdout.decode("utf-8", "replace")


_baselines = {}


def baseline(e, root):
    """'ok', 'skip:<reason>' or 'bad:<why>' for the unmutated test file, run once per file."""
    key = (root, e["run"])
    if key not in _baselines:
        test = os.path.join(root, e["run"])
        work = os.path.realpath(tempfile.mkdtemp(prefix="agentbus-mutation-"))
        try:
            rc, out = _run(test, root, _env(os.path.join(root, "bin", "agentbus"), work))
        finally:
            shutil.rmtree(work, ignore_errors=True)
        if rc == 0:
            _baselines[key] = "ok"
        elif rc == 77 and re.match(r"All .* (passed|killed)", (out.strip().splitlines() or [""])[-1]):
            _baselines[key] = "ok"  # a file that ran everything it could and skipped a section (all_passed): its assertions held
        elif rc == 77:
            skips = [x for x in out.splitlines() if x.startswith("SKIP")]
            _baselines[key] = "skip:" + (skips[-1][5:].strip() if skips else "no reason")
        elif rc is None:
            _baselines[key] = "bad:timed out after %ds" % TIMEOUT
        else:
            fails = [x for x in out.splitlines() if x.startswith("FAIL")] or out.strip().splitlines()[-1:]
            _baselines[key] = "bad:rc %d: %s" % (rc, (fails[-1] if fails else "")[:160])
    return _baselines[key]


def shadow_run(e, mutated, root):
    work = os.path.realpath(tempfile.mkdtemp(prefix="agentbus-mutation-"))
    tmp = os.path.join(work, "s")
    os.mkdir(tmp)
    try:
        copy = shadow(root, tmp, e["file"], mutated)
        test = os.path.join(root, e["run"])
        rel = os.path.relpath(test, root)
        shadow_test = test if rel.startswith("..") else os.path.join(tmp, rel)  # a test outside the tree runs in place
        # AGENTBUS_BIN is the CLI under test: the mutated copy only when the CLI is what is mutated.
        cli = copy if e["file"] == "bin/agentbus" else os.path.join(tmp, "bin", "agentbus")
        return _run(shadow_test, tmp, _env(cli, work))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def prepare(e, root):
    """Everything before the mutated run. Returns ('done', verdict, line) when the entry is settled without one, or
    ('baseline', mutated) when it needs its test file's unmutated result first."""
    name = e["name"]
    test = os.path.join(root, e["run"])
    if not os.path.isfile(test):
        after = " (after %s)" % e["after"] if e.get("after") else ""
        return ("done", "skipped", "SKIP %s: %s does not exist yet%s" % (name, e["run"], after))
    src = os.path.join(root, e["file"])
    try:
        with open(src, encoding="utf-8") as f:
            text = f.read()
    except OSError as err:
        return ("done", "stale", "STALE %s: cannot read %s: %s" % (name, e["file"], err))
    try:
        mutated, n = re.subn(e["find"], e["replace"], text, flags=re.MULTILINE)
    except re.error as err:
        return ("done", "stale", "STALE %s: bad pattern: %s" % (name, err))
    if n != e["count"]:
        return ("done", "stale", "STALE %s: pattern matched %d times in %s, the entry says %d" % (name, n, e["file"], e["count"]))
    if mutated == text:
        return ("done", "stale", "STALE %s: the replacement changes nothing" % name)
    return ("baseline", mutated)


def after_baseline(e, root):
    """('done', verdict, line) when the unmutated test file settles the entry, else None."""
    name = e["name"]
    base = baseline(e, root)
    if base.startswith("skip:"):
        return ("done", "skipped", "SKIP %s: %s skips unmutated (%s)" % (name, e["run"], base[5:]))
    if base.startswith("bad:"):
        return ("done", "broken", "BROKEN %s: %s fails before any mutation (%s)" % (name, e["run"], base[4:]))
    return None


def classify(e, rc, out):
    """(verdict, line) for the mutated run's result."""
    name = e["name"]
    if rc is None:
        return "timeout", "TIMEOUT %s: %s ran past %ds on the mutated copy" % (name, e["run"], TIMEOUT)
    if rc == 0:
        return "survived", "SURVIVED %s: %s passed against the mutated copy" % (name, e["run"])
    fails = [x for x in out.splitlines() if x.startswith("FAIL")]
    if rc in (77, 124, 126, 127) or not fails:
        tail = (out.strip().splitlines() or ["(no output)"])[-1]
        return "crashed", "CRASHED %s: %s exited %d with no FAIL line: %s" % (name, e["run"], rc, tail[:160])
    hit = [x for x in fails if e["expect"] in x]
    if not hit:
        return "wrong", "WRONG %s: %s failed for another reason: %s (wanted %r)" % (name, e["run"], fails[-1][:160], e["expect"])
    return "killed", "KILLED %s: %s rc %d: %s" % (name, e["run"], rc, hit[0][:160])


def run_one(e, root=ROOT):
    """Returns 'killed', 'wrong', 'survived', 'timeout', 'crashed', 'stale', 'broken' or 'skipped'; prints one line."""
    step = prepare(e, root)
    if step[0] == "baseline":
        step = after_baseline(e, root) or ("test", step[1])
    if step[0] == "done":
        print(step[2])
        return step[1]
    verdict, line = classify(e, *shadow_run(e, step[1], root))
    print(line)
    return verdict


def run_all(picked, jobs, root=ROOT):
    """Run the entries on up to `jobs` threads (each one waits on its own subprocess); print one line per entry in
    the order given, as soon as it and every entry before it are settled. Returns the verdicts in that order."""
    steps = [prepare(e, root) for e in picked]
    keys, first = set(), []
    for e, st in zip(picked, steps):  # one unmutated run per test file, in the pool as well
        if st[0] == "baseline" and (root, e["run"]) not in keys:
            keys.add((root, e["run"]))
            first.append(e)
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs))
    try:
        for f in [pool.submit(baseline, e, root) for e in first]:
            f.result()
        pending = []
        for e, st in zip(picked, steps):
            if st[0] == "baseline":
                st = after_baseline(e, root) or ("test", st[1])
            pending.append(st if st[0] == "done" else pool.submit(lambda e=e, m=st[1]: classify(e, *shadow_run(e, m, root))))
        results = []
        for st in pending:
            if isinstance(st, tuple):
                verdict, line = st[1], st[2]
            else:
                verdict, line = st.result()
            print(line, flush=True)
            results.append(verdict)
        return results
    except BaseException:
        pool.shutdown(wait=False, cancel_futures=True)
        raise
    finally:
        pool.shutdown(wait=True)


def default_jobs():
    raw = os.environ.get("AGENTBUS_MUTATION_JOBS", "").strip()
    if not raw:
        return max(1, min(os.cpu_count() or 1, 4))
    if not raw.isdigit() or int(raw) < 1:
        print("mutate: AGENTBUS_MUTATION_JOBS must be a whole number of 1 or more, not %r" % raw, file=sys.stderr)
        sys.exit(2)
    return int(raw)


def main(argv):
    path, args, jobs = DEFAULT_FILE, [], None
    it = iter(argv)
    for a in it:
        if a == "--mutations":
            path = next(it, None)
            if not path:
                print("mutate: --mutations needs a file", file=sys.stderr)
                return 2
        elif a in ("-j", "--jobs"):
            v = next(it, None)
            if v is None or not v.isdigit() or int(v) < 1:
                print("mutate: %s needs a whole number of 1 or more" % a, file=sys.stderr)
                return 2
            jobs = int(v)
        else:
            args.append(a)
    if len(args) != 1 or args[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if args[:1] in (["-h"], ["--help"]) else 2
    entries = load(path)
    if args[0] == "--list":
        for e in entries:
            print(e["name"])
        return 0
    if args[0] == "--all":
        picked = entries
    else:
        picked = [e for e in entries if e["name"] == args[0]]
        if not picked:
            print("mutate: no mutation named %r (see --list)" % args[0], file=sys.stderr)
            return 2
    try:
        results = run_all(picked, jobs if jobs is not None else default_jobs())
    except KeyboardInterrupt:
        print("mutate: interrupted", file=sys.stderr)
        return 130
    print("%d killed, %d survived, %d wrong reason, %d timed out, %d crashed, %d stale, %d broken, %d skipped" % tuple(
        results.count(k) for k in ("killed", "survived", "wrong", "timeout", "crashed", "stale", "broken", "skipped")))
    if any(r in results for r in ("stale", "crashed", "broken")):
        return 2
    if any(r in results for r in ("survived", "wrong", "timeout")):
        return 1
    if not [r for r in results if r != "skipped"]:
        print("mutate: nothing ran", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
