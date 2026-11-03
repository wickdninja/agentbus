#!/bin/bash
set -euo pipefail
# Retry safety (WS07): what a second run of each command does, observed, and the retry class that
# `agentbus schema --json` promises for it.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
"$PY" - "$BIN" "$T" <<'PY'
import json, os, sqlite3, subprocess, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
bin_, tmp = sys.argv[1:]
BASE = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
BASE.update(COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1", HOME=tmp)
n = [0]

def fresh():
    n[0] += 1
    d = os.path.join(tmp, "bus%d" % n[0]); os.makedirs(d)
    return os.path.join(d, "bus.db")

def run(db, *args, env=None):
    return subprocess.run([*agentbus_argv(), *args], cwd=tmp, env=dict(BASE, AGENTBUS_DB=db, **(env or {})),
                          capture_output=True, text=True, timeout=60)

def ok(db, *args, **k):
    p = run(db, "--json", *args, **k)
    assert p.returncode == 0, (args, p.returncode, p.stderr)
    return json.loads(p.stdout)

def rows(db, sql, *params):
    con = sqlite3.connect(db)
    try:
        return con.execute(sql, params).fetchall()
    finally:
        con.close()

def bus(*setup):
    db = fresh()
    for args in (("--as", "a", "join"), ("--as", "b", "join")) + setup:
        ok(db, *args)
    return db

# ---- release --if-held ----
db = bus(("--as", "a", "claim", "src/x.py"))
assert ok(db, "--as", "a", "release", "src/x.py", "--if-held") == {"released": ["src/x.py"], "released_count": 1}
for _ in range(2):
    assert ok(db, "--as", "a", "release", "src/x.py", "--if-held") == {"released": [], "released_count": 0}
p = run(db, "--json", "--as", "a", "release", "src/x.py")
assert p.returncode == 1 and json.loads(p.stderr)["error"]["code"] == "not_held", p
p = run(db, "--as", "a", "release", "src/x.py", "--if-held")
assert p.returncode == 0 and "released 0 claims" in p.stdout, p.stdout
print("PASS: release --if-held twice both exit 0, and a plain release of an unheld claim still refuses")

# ---- leave twice writes one log row ----
db = bus(("--as", "a", "claim", "r1"), ("--as", "a", "claim", "r2"))
logs = lambda: rows(db, "SELECT COUNT(*) FROM log WHERE action IN ('leave','release')")[0][0]
before = logs()
first = ok(db, "--as", "a", "leave")
assert first["released_count"] == 2 and logs() == before + 1, first
second = ok(db, "--as", "a", "leave")
assert second == {"left": "a", "released": [], "released_count": 0} and logs() == before + 1, second
ok(db, "--as", "b", "claim", "r3"); ok(db, "--as", "b", "release", "--all")
mid = logs()
assert ok(db, "--as", "b", "release", "--all") == {"released": [], "released_count": 0} and logs() == mid
print("PASS: leave twice writes one log row; release --all again writes none")

# ---- ctx set and goal: an unchanged value writes nothing ----
db = bus()
hist = lambda: rows(db, "SELECT COUNT(*) FROM context_history WHERE key='k'")[0][0]
first = ok(db, "--as", "a", "ctx", "set", "k", "v")
assert first["unchanged"] is False and hist() == 1, first
second = ok(db, "--as", "b", "ctx", "set", "k", "v")
assert second["unchanged"] is True and second["updated_by"] == "a" and second["updated_at"] == first["updated_at"] and hist() == 1, second
third = ok(db, "--as", "b", "ctx", "set", "k", "w")
assert third["unchanged"] is False and third["updated_by"] == "b" and hist() == 2, third
p = run(db, "--as", "a", "ctx", "set", "k", "w")
assert p.returncode == 0 and p.stdout.strip() == "set k (unchanged)", p.stdout
glog = lambda: rows(db, "SELECT COUNT(*) FROM log WHERE action='goal'")[0][0]
g1 = ok(db, "--as", "a", "goal", "ship it")
g2 = ok(db, "--as", "b", "goal", "ship it")
assert g1["unchanged"] is False and g2["unchanged"] is True and g2["set_by"] == "a" and glog() == 1, (g1, g2)
assert ok(db, "goal") == {"goal": "ship it", "set_by": "a", "set_at": g1["set_at"]}
assert rows(db, "SELECT COUNT(*) FROM context_history WHERE key='goal'")[0][0] == 1
print("PASS: ctx set and goal set with the same value twice write one history row and report unchanged")

# ---- post: a token makes a retry safe ----
db = bus()
a1 = ok(db, "--as", "a", "post", "hello", "--request-id", "t1")
a2 = ok(db, "--as", "a", "post", "hello", "--request-id", "t1")
assert a2 == {"id": a1["id"], "duplicate": True} and rows(db, "SELECT COUNT(*) FROM messages")[0][0] == 1, (a1, a2)
ok(db, "--as", "a", "post", "again"); ok(db, "--as", "a", "post", "again")
assert rows(db, "SELECT COUNT(*) FROM messages WHERE body='again'")[0][0] == 2, "without a token each post is a message"
p = run(db, "--json", "--as", "a", "post", "late", "--request-id", "t2", env={"AGENTBUS_TEST_FAIL": "emit"})
assert p.returncode == 1 and json.loads(p.stderr)["error"]["code"] == "output_failed"
ok(db, "--as", "a", "post", "late", "--request-id", "t2")
assert rows(db, "SELECT COUNT(*) FROM messages WHERE body='late'")[0][0] == 1
print("PASS: post --request-id twice returns one message and duplicate true; a post whose stdout failed after commit, retried with the same token, leaves one message")

# ---- the registry's retry class equals the observed behaviour, command by command ----
schema = ok(fresh(), "schema")["commands"]

def effect(db, tables):
    out = {}
    con = sqlite3.connect(db)
    try:
        for name, cols in tables.items():
            out[name] = con.execute("SELECT %s FROM %s ORDER BY 1, 2" % (cols, name)).fetchall()
    finally:
        con.close()
    return out

MESSAGES = {"messages": "id, sender, recipient, kind, body"}
CLAIMS = {"claims": "resource, agent, purpose, claimed_at"}
FACTS = {"context_history": "key, value, updated_by", "context": "key, value, updated_by"}
ROSTER = {"agents": "name, role", "claims": "resource, agent"}
LOG = {"log": "agent, action"}
EVERYTHING = {**MESSAGES, **CLAIMS, **FACTS, **ROSTER, **LOG}

def observe(setup, args, tables, variant=None, tokened=None):
    """The class a command shows: run it on a prepared bus, look at the effect after the first and
    the second run. variant: the same command with the flag that makes a refused retry work."""
    db = bus(*setup)
    s0 = effect(db, tables)
    p1 = run(db, "--json", *args)
    s1 = effect(db, tables)
    p2 = run(db, "--json", *args)
    s2 = effect(db, tables)
    assert p1.returncode == 0, (args, p1.stderr)
    if p2.returncode != 0:
        assert variant, (args, "refused a retry and has no flagged form", p2.stderr)
        v1, v2 = run(db, "--json", *variant), run(db, "--json", *variant)
        assert v1.returncode == 0 and v2.returncode == 0, (variant, v1.stderr, v2.stderr)
        return "idempotent_with_flag"
    if s1 == s0 and s2 == s1:
        return "safe"
    if s2 == s1:
        return "idempotent"
    if tokened:
        db2 = bus(*setup)
        run(db2, "--json", *tokened); t1 = effect(db2, tables)
        run(db2, "--json", *tokened)
        if effect(db2, tables) == t1:
            return "needs_request_id"
    return "unsafe"

def observe_inbox():
    db = bus(("--as", "a", "post", "m", "--to", "b"))
    first = json.loads(run(db, "--json", "--as", "b", "inbox", env={"AGENTBUS_TEST_FAIL": "ack"}).stdout)
    again = ok(db, "--as", "b", "inbox")
    assert [m["id"] for m in first["items"]] == [m["id"] for m in again["items"]] != [], (first, again)
    assert ok(db, "--as", "b", "inbox")["items"] == [], "a clean inbox consumes"
    return "at_least_once"

POSTED = (("--as", "a", "post", "m", "--to", "b"),)
OBSERVED = {
    "join": observe((), ("--as", "c", "join"), ROSTER, variant=("--as", "c", "join", "--takeover")),
    "leave": observe((("--as", "a", "claim", "x"),), ("--as", "a", "leave"), EVERYTHING),
    "who": observe((), ("who",), EVERYTHING),
    "post": observe((), ("--as", "a", "post", "hi"), MESSAGES, tokened=("--as", "a", "post", "hi", "--request-id", "tok")),
    "inbox": observe_inbox(),
    "read": observe(POSTED, ("read",), EVERYTHING),
    "ctx set": observe((), ("--as", "a", "ctx", "set", "k", "v"), {**FACTS}),
    "ctx get": observe((("--as", "a", "ctx", "set", "k", "v"),), ("ctx", "get", "k"), EVERYTHING),
    "ctx history": observe((("--as", "a", "ctx", "set", "k", "v"),), ("ctx", "history", "k"), EVERYTHING),
    "claim": observe((), ("--as", "a", "claim", "x", "--purpose", "p"), CLAIMS),
    "release": observe((("--as", "a", "claim", "x"),), ("--as", "a", "release", "x"), {**CLAIMS, **LOG},
                       variant=("--as", "a", "release", "x", "--if-held")),
    "claims": observe((), ("claims",), EVERYTHING),
    "log add": observe((), ("--as", "a", "log", "add", "note", "d"), LOG),
    "log show": observe((), ("log", "show"), EVERYTHING),
    "status": observe((), ("status",), EVERYTHING),
    "goal": observe((), ("--as", "a", "goal", "g"), {**FACTS, **LOG}),
    "watch": observe((), ("watch",), EVERYTHING),
    "buses": observe((), ("buses",), EVERYTHING),
    "schema": observe((), ("schema",), EVERYTHING),
    "skill": observe((), ("skill",), EVERYTHING),
    "doctor": observe((), ("doctor",), EVERYTHING),
}
# init and upgrade write files, not rows: a second run leaves the folder as the first did
repo = os.path.join(tmp, "repo"); os.makedirs(repo)
def tree():
    return sorted((r, f, open(os.path.join(r, f), "rb").read()) for r, _, fs in os.walk(repo) for f in fs)
ok(fresh(), "init", repo); t1 = tree(); ok(fresh(), "init", repo)
OBSERVED["init"] = "idempotent" if tree() == t1 else "unsafe"
ok(fresh(), "upgrade", repo); t2 = tree(); ok(fresh(), "upgrade", repo)
OBSERVED["upgrade"] = "idempotent" if tree() == t2 else "unsafe"
# setup writes user config, not rows: a second run leaves the config folders as the first did. They point
# into this test's own temp folder (HOME is tmp too), never a real ~/.claude or ~/.codex.
cfg = {"CLAUDE_CONFIG_DIR": os.path.join(tmp, "cc"), "CODEX_HOME": os.path.join(tmp, "cx")}
def cfg_tree():
    return sorted((r, f, open(os.path.join(r, f), "rb").read()) for d in cfg.values() for r, _, fs in os.walk(d) for f in fs)
# update writes the tool, bus copies and a cache; its retry-safe forms are observed on the one that needs no network, --check
# answering from a good cache entry (a second run leaves the cache as the first did).
ucache = os.path.join(tmp, "Library", "Caches", "agentbus") if sys.platform == "darwin" else os.path.join(tmp, ".cache", "agentbus")
os.makedirs(ucache, mode=0o700)
with open(os.path.join(ucache, "release-check.json"), "w") as f:
    json.dump({"v": 1, "checked_at": int(__import__("time").time()), "ok": True, "reason": None, "retry_after": None,
               "stable": "0.9.0", "pre": None, "notified": None}, f)
os.chmod(os.path.join(ucache, "release-check.json"), 0o600)
def ucache_tree():
    return sorted((r, f, open(os.path.join(r, f), "rb").read()) for r, _, fs in os.walk(ucache) for f in fs)
uenv = {"XDG_CACHE_HOME": os.path.join(tmp, ".cache")}
ok(fresh(), "update", "--check", env=uenv); t4 = ucache_tree(); ok(fresh(), "update", "--check", env=uenv)
OBSERVED["update"] = "idempotent" if ucache_tree() == t4 else "unsafe"
for target in ("claude", "codex"):
    ok(fresh(), "setup", target, env=cfg); t3 = cfg_tree(); ok(fresh(), "setup", target, env=cfg)
    assert t3, ("setup wrote nothing", target)
    OBSERVED["setup"] = "idempotent" if cfg_tree() == t3 and OBSERVED.get("setup", "idempotent") == "idempotent" else "unsafe"
assert set(OBSERVED) == set(schema), ("commands with no observation", sorted(set(schema) ^ set(OBSERVED)))
wrong = {k: (schema[k]["retry"]["class"], v) for k, v in OBSERVED.items() if schema[k]["retry"]["class"] != v}
assert not wrong, ("registry class vs observed", wrong)
# the flagged and peek forms the registry names are real
assert schema["inbox"]["retry"]["with"]["--peek"]["class"] == "safe"
db = bus(("--as", "a", "post", "m", "--to", "b"))
s = effect(db, EVERYTHING); ok(db, "--as", "b", "inbox", "--peek"); ok(db, "--as", "b", "inbox", "--peek")
assert effect(db, EVERYTHING) == s, "inbox --peek changed the bus"
print("PASS: the retry class in schema --json equals the observed behaviour for each command in a table-driven run")
PY
echo "All retry tests passed"
