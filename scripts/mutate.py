#!/usr/bin/env python3
"""Mutation check: break one behaviour of bin/agentbus on purpose and require a test to notice.

  python3 scripts/mutate.py NAME            run one mutation from tests/mutations.json
  python3 scripts/mutate.py --all           run every mutation whose test file exists
  python3 scripts/mutate.py --list          print the names
  --mutations FILE                          use another mutations file (tests/test_mutations.sh does)

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

The test runs from a shadow tree in a temp dir (symlinks to the checkout, the mutated file real), so BIN
in tests/lib.sh is the mutated copy; AGENTBUS_BIN names it too, which tests/lib.sh and
tests/agentbus_cmd.py honour (AGENTBUS_CMD is dropped so the copy is what runs). An entry whose
test file does not exist yet is skipped with a printed line.

Exit 0: every selected mutation killed. 1: a mutation survived, was killed for another reason, or timed out.
2: stale, crashed, a baseline that fails, or unusable (unknown name, bad file).
"""
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


def _env(copy):
    env = dict(os.environ)
    env.pop("AGENTBUS_CMD", None)
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
        env = dict(os.environ)
        env.pop("AGENTBUS_CMD", None)
        env["AGENTBUS_BIN"] = os.path.join(root, "bin", "agentbus")
        rc, out = _run(test, root, env)
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
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="agentbus-mutation-"))
    try:
        copy = shadow(root, tmp, e["file"], mutated)
        test = os.path.join(root, e["run"])
        rel = os.path.relpath(test, root)
        shadow_test = test if rel.startswith("..") else os.path.join(tmp, rel)  # a test outside the tree runs in place
        # AGENTBUS_BIN is the CLI under test: the mutated copy only when the CLI is what is mutated.
        cli = copy if e["file"] == "bin/agentbus" else os.path.join(tmp, "bin", "agentbus")
        return _run(shadow_test, tmp, _env(cli))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run_one(e, root=ROOT):
    """Returns 'killed', 'wrong', 'survived', 'timeout', 'crashed', 'stale', 'broken' or 'skipped'; prints one line."""
    name = e["name"]
    test = os.path.join(root, e["run"])
    if not os.path.isfile(test):
        after = " (after %s)" % e["after"] if e.get("after") else ""
        print("SKIP %s: %s does not exist yet%s" % (name, e["run"], after))
        return "skipped"
    src = os.path.join(root, e["file"])
    try:
        with open(src, encoding="utf-8") as f:
            text = f.read()
    except OSError as err:
        print("STALE %s: cannot read %s: %s" % (name, e["file"], err))
        return "stale"
    try:
        mutated, n = re.subn(e["find"], e["replace"], text, flags=re.MULTILINE)
    except re.error as err:
        print("STALE %s: bad pattern: %s" % (name, err))
        return "stale"
    if n != e["count"]:
        print("STALE %s: pattern matched %d times in %s, the entry says %d" % (name, n, e["file"], e["count"]))
        return "stale"
    if mutated == text:
        print("STALE %s: the replacement changes nothing" % name)
        return "stale"
    base = baseline(e, root)
    if base.startswith("skip:"):
        print("SKIP %s: %s skips unmutated (%s)" % (name, e["run"], base[5:]))
        return "skipped"
    if base.startswith("bad:"):
        print("BROKEN %s: %s fails before any mutation (%s)" % (name, e["run"], base[4:]))
        return "broken"
    rc, out = shadow_run(e, mutated, root)
    if rc is None:
        print("TIMEOUT %s: %s ran past %ds on the mutated copy" % (name, e["run"], TIMEOUT))
        return "timeout"
    if rc == 0:
        print("SURVIVED %s: %s passed against the mutated copy" % (name, e["run"]))
        return "survived"
    fails = [x for x in out.splitlines() if x.startswith("FAIL")]
    if rc in (77, 124, 126, 127) or not fails:
        tail = (out.strip().splitlines() or ["(no output)"])[-1]
        print("CRASHED %s: %s exited %d with no FAIL line: %s" % (name, e["run"], rc, tail[:160]))
        return "crashed"
    hit = [x for x in fails if e["expect"] in x]
    if not hit:
        print("WRONG %s: %s failed for another reason: %s (wanted %r)" % (name, e["run"], fails[-1][:160], e["expect"]))
        return "wrong"
    print("KILLED %s: %s rc %d: %s" % (name, e["run"], rc, hit[0][:160]))
    return "killed"


def main(argv):
    path, args = DEFAULT_FILE, []
    it = iter(argv)
    for a in it:
        if a == "--mutations":
            path = next(it, None)
            if not path:
                print("mutate: --mutations needs a file", file=sys.stderr)
                return 2
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
    results = [run_one(e) for e in picked]
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
