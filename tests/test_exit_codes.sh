#!/bin/bash
set -euo pipefail
# One exit-code mapping, independent of --json (WS07): 0 success, 1 the command ran and refused,
# 2 usage, 3 the bus is unavailable or unsafe, 4 internal error. Each row of the table is produced on
# purpose, in human and --json mode, and the two modes must agree.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
"$PY" - "$BIN" "$T" <<'PY' || fail "exit-code mapping differs from the contract (assertion above)"
import concurrent.futures, json, os, sqlite3, subprocess, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
bin_, tmp = sys.argv[1:]
BASE = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
BASE.update(COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1")
n = [0]

def run(db, *args, env=None):
    n[0] += 1
    home = os.path.join(tmp, "h%d" % n[0]); os.makedirs(home)
    e = dict(BASE, HOME=home, **(env or {}))
    if db:
        e["AGENTBUS_DB"] = db
    return subprocess.run([*agentbus_argv(), *args], cwd=home, env=e, capture_output=True, text=True, timeout=60)

OBSERVED = []  # (args, code, exit status) of every refusal produced below

def both(db, args, status, code=None, env=None):
    """args run in human mode and with --json: the same exit status, and the documented code in JSON.
    The two run side by side: a held database makes each wait 15 s before it gives up."""
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        hf, jf = pool.submit(run, db, *args, env=env), pool.submit(run, db, "--json", *args, env=env)
        h, j = hf.result(), jf.result()
    assert h.returncode == status, ("human", args, h.returncode, h.stderr)
    assert j.returncode == status, ("json", args, j.returncode, j.stderr)
    if code:
        err = json.loads(j.stderr.splitlines()[-1])["error"]
        assert err["code"] == code, (args, err)
        OBSERVED.append((args, code, status))
        if status == 4:  # a bug keeps its traceback in human mode, for the report
            assert "Traceback" in h.stderr and "injected internal failure" in h.stderr, h.stderr
        else:
            assert h.stderr.startswith("agentbus: ") and h.stderr.count("\n") == 1, ("human errors are one line", h.stderr)
        return err
    return None

db = os.path.join(tmp, "bus", "bus.db"); os.makedirs(os.path.dirname(db))
for who in ("a", "b"):
    assert run(db, "--as", who, "join").returncode == 0

# 0: success, --version, --help, and a listing with nothing in it
both(db, ["who"], 0)
for flag in ("--version", "--help", "post --help"):
    assert run(db, *flag.split()).returncode == 0, flag
assert run(db, "--version").stdout.startswith("agentbus ")
print("PASS: exit 0 for success, --version and --help")

# 1: the command ran and refused
assert run(db, "--as", "a", "claim", "src/").returncode == 0
both(db, ["--as", "b", "claim", "src/x.py"], 1, "claim_conflict")
both(db, ["--as", "b", "release", "src/"], 1, "not_held")
both(db, ["--as", "a", "post", "x", "--reply-to", "99"], 1, "no_message")
both(db, ["ctx", "get", "nope"], 1, "no_context_key")
both(db, ["--as", "ghost", "claim", "z"], 1, "not_on_roster")
both(db, ["--as", "a", "join"], 1, "name_active")
assert run(db, "--as", "a", "post", "one", "--request-id", "t").returncode == 0
both(db, ["--as", "a", "post", "two", "--request-id", "t"], 1, "request_id_reused")
print("PASS: exit 1 for every refusal, in human and --json mode")

# 2: usage. The same for argparse errors, unknown commands and invalid values, in both modes
both(db, ["lgo"], 2, "bad_input")
both(db, ["read", "--limit", "abc"], 2, "bad_input")
both(db, ["--as", "a", "post", "hi", "--kind", "fyi"], 2, "bad_input")
both(db, ["--as", "a", "post"], 2, "bad_input")
both(db, ["post"], 2, "bad_input")        # no identity
both(db, ["--as", "a", "claim", "../x"], 2, "bad_input")
both(db, ["--as", "a", "claim", "x", "--ttl-min", "0"], 2, "bad_input")
both(db, [], 2, "bad_input")               # no command at all
both(db, ["schema", "nope"], 2, "bad_input")
# argparse accepts any unambiguous prefix of a long option: --js would be --json to it, but the tool
# decides how to print errors before parsing, so prefixes are not accepted at all
for args in (["--js", "who"], ["--as", "a", "post", "--ki", "note", "x"], ["--as", "a", "claim", "x", "--ttl", "5"]):
    for mode in ((), ("--json",)):
        p = run(db, *mode, *args)
        assert p.returncode == 2 and p.stdout == "" and "unrecognized arguments" in p.stderr, (mode, args, p.returncode, p.stdout, p.stderr)
print("PASS: option abbreviations are usage errors, in both modes")
print("PASS: exit 2 for usage errors and unknown commands, equal in both modes")

# 3: the bus is unavailable or unsafe
both(None, ["who"], 3, "no_bus")
foreign = os.path.join(tmp, "foreign", "bus.db"); os.makedirs(os.path.dirname(foreign))
assert run(foreign, "--as", "a", "join").returncode == 0
c = sqlite3.connect(foreign); c.execute("CREATE TABLE foreign_table(x)"); c.commit(); c.close()
both(foreign, ["who"], 3, "schema_refused")
bad = os.path.join(tmp, "journal", "bus.db"); os.makedirs(os.path.dirname(bad))
assert run(bad, "--as", "a", "join").returncode == 0
open(bad + "-journal", "w").close()
both(bad, ["who"], 3, "bus_unavailable")
held = os.path.join(tmp, "held", "bus.db"); os.makedirs(os.path.dirname(held))
assert run(held, "--as", "a", "join").returncode == 0
con = sqlite3.connect(held); con.execute("SELECT * FROM agents").fetchall()
try:
    err = both(held, ["who"], 3, "busy")
    assert err["retryable"] is True and err["bus"] == held, err
finally:
    con.close()
# the commands that need no open bus find (or fail to find) one too
both(None, ["buses", "--up", "5"], 3, "no_bus")
both(bad, ["buses"], 3, "bus_unavailable")
empty = os.path.join(tmp, "emptydir"); os.makedirs(empty)
both(None, ["upgrade", empty], 3, "no_bus")
both(None, ["init", os.path.join(tmp, "not-a-dir")], 2, "bad_input")
print("PASS: exit 3 for no bus, a refused schema, an unsafe folder and a held database (busy is retryable)")

# 4: a bug is exit 4 in both modes (and a traceback in human mode, not exit 1)
h = run(db, "who", env={"AGENTBUS_TEST_FAIL": "internal"})
assert h.returncode == 4, h
both(db, ["who"], 4, "internal", env={"AGENTBUS_TEST_FAIL": "internal"})
print("PASS: exit 4 for an internal error, in both modes")

# a stdout that cannot take the text is output_failed (exit 1), not a usage error
assert run(db, "--as", "a", "post", "caf\u00e9 \u2603").returncode == 0
p = run(db, "read", env={"PYTHONIOENCODING": "ascii:strict", "PYTHONUTF8": "0"})
assert p.returncode == 1 and "agentbus: " in p.stderr and "Traceback" not in p.stderr, (p.returncode, p.stderr)
assert "cannot be shown" in p.stderr, p.stderr
print("PASS: a stdout that cannot encode the text exits 1 with the output_failed message")

# the registry says the same thing the tool does
doc = json.loads(run(db, "--json", "schema").stdout)
seen = {"claim_conflict": 1, "bad_input": 2, "no_bus": 3, "busy": 3, "internal": 4}
for code, status in seen.items():
    assert doc["errors"][code]["exit"] == status, code
print("PASS: observed exit codes equal the documented table")

# every code a command was seen to raise is listed in that command's schema entry, with its exit status
def command_key(args):
    args, skip, words = list(args), False, []
    for a in args:
        if skip:
            skip = False
        elif a in ("--as", "--up"):
            skip = True
        elif not a.startswith("--"):
            words.append(a)
    if not words:
        return None
    name = words[0]
    if name in ("ctx", "log") and len(words) > 1:
        name += " " + words[1]
    return name
checked = 0
for args, code, status in OBSERVED:
    key = command_key(args)
    if key not in doc["commands"]:
        assert code == "bad_input", (args, "an unknown command can only be a usage error")
        continue
    entry = doc["commands"][key]
    assert code in entry["errors"], ("schema %s does not list %s, which it raised" % (key, code), entry["errors"])
    assert status in entry["exit_codes"], ("schema %s lists exit codes %s but exited %d" % (key, entry["exit_codes"], status))
    checked += 1
assert checked > 20, checked
print("PASS: every error code observed for a command is listed in its schema entry")
PY
echo "All exit code tests passed"
