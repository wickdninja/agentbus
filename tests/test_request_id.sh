#!/bin/bash
set -euo pipefail
# --request-id replays a write only where the bus stores the token: post and join. Everywhere else it is accepted and
# ignored, and the help, schema and error say so. Bug it catches: a retry of ctx set or goal under a token overwrote
# another agent's change while the flag, `schema` and `retryable: true` promised a safe retry.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cat > "$T/h.py" <<'PY'
import json, os, subprocess, sys, tempfile
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
tmp = os.environ["T"]
BASE = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
BASE.update(COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1", HOME=tmp)

def fresh():
    return os.path.join(tempfile.mkdtemp(dir=tmp), "bus.db")

def run(db, *args, env=None):
    return subprocess.run([*agentbus_argv(), *args], cwd=tmp, env=dict(BASE, AGENTBUS_DB=db, **(env or {})),
                          capture_output=True, text=True, timeout=60)

def ok(db, *args):
    p = run(db, "--json", *args)
    assert p.returncode == 0, (args, p.returncode, p.stderr)
    return json.loads(p.stdout)

def bus():
    db = fresh()
    for name in ("a", "b"):
        ok(db, "--as", name, "join")
    return db
PY
export T PYTHONPATH="$T"

echo "TEST 1: a ctx set or goal retried with its token sets the value again, over a change made since"
"$PY" - <<'PY' || fail "a retried ctx set or goal did not behave as the docs now say (it sets the value again)"
from h import *
db = bus()
ok(db, "--as", "a", "ctx", "set", "k", "old", "--request-id", "T")
ok(db, "--as", "b", "ctx", "set", "k", "new")
r = ok(db, "--as", "a", "ctx", "set", "k", "old", "--request-id", "T")
assert r["value"] == "old" and r["unchanged"] is False and ok(db, "ctx", "get", "k")["value"] == "old", r
ok(db, "--as", "a", "goal", "one", "--request-id", "G"); ok(db, "--as", "b", "goal", "two")
assert ok(db, "--as", "a", "goal", "one", "--request-id", "G")["goal"] == "one"
# claim never overwrites: another agent's claim stays theirs, the retry is a claim_conflict
ok(db, "--as", "a", "claim", "r", "--request-id", "C"); ok(db, "--as", "a", "release", "r"); ok(db, "--as", "b", "claim", "r")
p = run(db, "--json", "--as", "a", "claim", "r", "--request-id", "C")
assert p.returncode == 1 and json.loads(p.stderr)["error"]["code"] == "claim_conflict", p
# a plain release that worked, repeated with its token, is not_held; --if-held is the repeat
ok(db, "--as", "b", "release", "r", "--request-id", "R")
p = run(db, "--json", "--as", "b", "release", "r", "--request-id", "R")
assert p.returncode == 1 and json.loads(p.stderr)["error"]["code"] == "not_held", p
assert ok(db, "--as", "b", "release", "r", "--if-held", "--request-id", "R")["released_count"] == 0
PY
ok "ctx set and goal overwrite on a retry, claim gives claim_conflict, release needs --if-held"

echo "TEST 2: after a saved write, retryable is true with a token only for post and join"
"$PY" - <<'PY' || fail "retryable after a saved write must be true only for a post or join with a token"
from h import *
for cmd in (("ctx", "set", "k", "v"), ("goal", "g"), ("claim", "r"), ("leave",), ("release", "r")):
    db = bus()
    ok(db, "--as", "a", "claim", "x")   # something to release, so leave and release save a change
    if cmd[0] == "release":
        ok(db, "--as", "a", "claim", "r")
    p = run(db, "--json", "--as", "a", *cmd, "--request-id", "T1", env={"AGENTBUS_TEST_FAIL": "emit"})
    e = json.loads(p.stderr)["error"]
    assert e["code"] == "output_failed" and e["committed"] is True and e["retryable"] is False, (cmd, e)
for cmd, name in ((("post", "hi"), "a"), (("join",), "c")):
    db = bus()
    p = run(db, "--json", "--as", name, *cmd, "--request-id", "T2", env={"AGENTBUS_TEST_FAIL": "emit"})
    e = json.loads(p.stderr)["error"]
    assert e["code"] == "output_failed" and e["committed"] is True and e["retryable"] is True, (cmd, e)
    assert ok(db, "--as", name, *cmd, "--request-id", "T2")["duplicate"] is True, cmd
PY
ok "ctx set, goal, claim, leave: retryable false; post and join: true, and the retry replays"

echo "TEST 3: the help says the token is ignored outside post and join, and what a repeat does"
"$PY" - <<'PY' || fail "help for --request-id"
from h import *
facts = {("ctx", "set"): "ctx get KEY first", ("goal",): "goal first", ("claim",): "renews your hold",
         ("release",): "--if-held", ("leave",): "Repeating leave is safe"}
for cmd, what in facts.items():
    flat = " ".join(run(fresh(), *cmd, "--help").stdout.split())
    assert "Accepted and ignored" in flat and what in flat and "Retry safely" not in flat, (cmd, flat)
for cmd in (("post",), ("join",)):
    flat = " ".join(run(fresh(), *cmd, "--help").stdout.split())
    assert "Accepted and ignored" not in flat and "Retry safely" in flat, (cmd, flat)
PY
ok "ctx set, goal, claim, release and leave say ignored; post and join say retry safely"

echo "TEST 4: schema retry text says the same, and the skill and reference do"
"$PY" - "$TESTS_DIR/.." <<'PY' || fail "schema, skill or reference text for --request-id"
import sys
from h import *
root = sys.argv[1]
sch = ok(fresh(), "schema")["commands"]
for k in ("ctx set", "goal"):
    how = sch[k]["retry"]["how"]
    assert "--request-id is ignored" in how and "overwrite" in how, (k, how)
for k in ("claim", "release", "leave"):
    assert "--request-id is ignored" in sch[k]["retry"]["how"], (k, sch[k]["retry"])
assert "ignored" not in json.dumps(sch["post"]["retry"]) and "ignored" not in json.dumps(sch["join"]["retry"])
skill = open(root + "/skills/agentbus/SKILL.md").read()
assert "When a `post` or `join` might be retried, add `--request-id`" in skill and "Other writes ignore it." in skill, "skill"
ref = open(root + "/docs/reference.md").read()
assert "`--request-id` replays a write only where the bus stores the token" in ref, "reference"
assert "One rule for every write" not in ref, "the old rule is still in the reference"
PY
ok "schema, skill and reference agree with the help"

echo "All request-id tests passed"
