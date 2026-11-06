#!/bin/bash
set -euo pipefail
# The machine contract (WS07): `agentbus schema --json` is the one registry of result shapes, error
# codes, exit codes and retry rules. Every claim it makes is checked against the running tool: its
# entries against the parser, its result schemas against the output of a scripted workflow of every
# command, its error table against failures produced on purpose. The expected tables below are
# written out here, independently of the registry, so a registry edit that drifts fails.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
"$PY" - "$BIN" "$T" <<'PY'
import ast, json, os, re, runpy, subprocess, sys, tempfile, sqlite3, argparse
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
from schema_check import validate, check_schema
bin_, tmp = sys.argv[1:]
NEEDS_ENVELOPE = True  # listings return {contract, items, has_more, next}
BASE = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
BASE.update(COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1")
count = [0]

def run(*args, db=None, env=None, cwd=None, closed=False, home=None, stdin=None):
    count[0] += 1
    e = dict(BASE, **(env or {}))
    home = home or os.path.join(tmp, "h%d" % count[0]); os.makedirs(home, exist_ok=True)
    e["HOME"] = home
    if db:
        e["AGENTBUS_DB"] = str(db)
    kw = dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if closed:  # the child's stdout is closed (>&-), not redirected
        kw["preexec_fn"] = lambda: os.close(1)
        kw["stdout"] = None
    return subprocess.run([*agentbus_argv(), *args], cwd=cwd or home, env=e, text=True, timeout=60, input=stdin, **kw)

def fresh(name):
    d = os.path.join(tmp, name); os.makedirs(d)
    return os.path.join(d, "bus.db")

def ok(*args, db=None, **k):
    p = run("--json", *args, db=db, **k)
    assert p.returncode == 0, (args, p.returncode, p.stderr)
    return json.loads(p.stdout)

def error(*args, db=None, **k):
    p = run("--json", *args, db=db, **k)
    assert p.returncode != 0, ("expected a failure", args, p.stdout)
    assert p.stdout == "", ("stdout must be empty on a refusal", args, p.stdout)
    lines = p.stderr.splitlines()
    assert len(lines) == 1, ("stderr must hold exactly one JSON object", args, p.stderr)
    return json.loads(lines[0])["error"], p.returncode

doc = ok("schema")
objects, commands = doc["objects"], doc["commands"]

# ---- the parser and the registry list the same commands ----
module = runpy.run_path(bin_, run_name="agentbus_test")
parser = module["build_parser"]()
def leaves(p, prefix=()):
    found = []
    for action in p._actions:
        if isinstance(action, argparse._SubParsersAction):
            for name, child in action.choices.items():
                inner = leaves(child, prefix + (name,))
                found.extend(inner or [prefix + (name,)])
    return found
parser_commands = {" ".join(path) for path in leaves(parser)} | {"schema"}
parser_commands -= set(module["CONTRACT"]["hidden"])  # commands the parser has that `schema` leaves out (hook)
assert doc["contract"] == 1 and isinstance(doc["agentbus"], str), doc["contract"]
assert set(commands) == parser_commands, ("registry vs parser", sorted(set(commands) ^ parser_commands))
print("PASS: schema --json has an entry for every subcommand in the parser and none for a command that does not exist")
# Which arguments a caller must give is the same on every Python: argparse itself marks a bare nargs="*" positional
# required below 3.12 (goal TEXT, update DIR, schema COMMAND), so the contract states it. Written out here, not read
# from the registry; this file runs on whatever Python the suite uses, so each version is held to the same lists.
REQUIRED = {"post body", "ctx set KEY", "ctx set VALUE", "ctx history KEY", "claim RESOURCE", "log add ACTION", "log add DETAIL",
            "completion shell", "setup target", "hooks target"}
OPTIONAL_POSITIONAL = {"join NAME", "ctx get KEY", "release RESOURCE", "goal text", "init DIR", "upgrade DIR", "schema COMMAND", "help COMMAND", "update DIR"}
got_required = {c + " " + a["name"] for c, v in commands.items() for a in v["args"] if a.get("required")}
got_optional = {c + " " + a["name"] for c, v in commands.items() for a in v["args"] if a.get("positional") and not a.get("required")}
for what, got, want in (("required arguments", got_required, REQUIRED), ("optional positionals", got_optional, OPTIONAL_POSITIONAL)):
    if got != want:  # a FAIL line, so tests/mutations.json can tell this check killed the change
        print("FAIL: %s on Python %d.%d differ from the contract: %s" % (what, *sys.version_info[:2], sorted(got ^ want)))
        sys.exit(1)
print("PASS: schema marks the same arguments required on every Python")

# ---- the registry's own tables equal the design (written out here, not read from the registry) ----
EXPECTED_ERRORS = {  # code: (exit, retryable, extra fields)
    "claim_conflict": (1, False, ["resource", "holder", "expires_at", "purpose", "holder_last_seen", "holder_idle_min", "takeover"]),
    "not_held": (1, False, ["resource"]),
    "no_message": (1, False, ["id"]),
    "no_context_key": (1, False, ["key"]),
    "not_on_roster": (1, False, ["agent", "did_you_mean", "roster"]),
    "name_active": (1, False, ["agent", "last_seen_min", "suggested_name"]),
    "request_id_reused": (1, False, ["request_id", "agent", "original_id"]),
    "bad_input": (2, False, []),
    "no_bus": (3, False, []),
    "busy": (3, True, ["bus"]),
    "schema_refused": (3, False, []),
    "schema_older": (3, False, ["bus", "bus_schema", "tool_schema"]),
    "schema_newer": (3, False, ["bus", "bus_schema", "tool_schema"]),
    "schema_corrupt": (3, False, ["bus", "bus_schema"]),
    "backup_failed": (3, False, ["bus", "reason"]),
    "copy_newer": (1, False, ["directory", "copy_version", "tool_version"]),
    "bus_unavailable": (3, False, []),
    "ack_failed": (3, True, ["delivered"]),
    "output_failed": (1, True, []),
    "interrupted": (130, True, []),
    "items_failed": (1, False, ["failed"]),
    "installer_failed": (1, False, ["argv", "exit_status", "reason", "recovery"]),
    "download_failed": (1, False, ["reason", "asset"]),
    "manual_step": (1, False, ["commands"]),
    "release_offline": (1, True, ["reason"]),
    "rate_limited": (1, True, ["retry_after"]),
    "release_unknown": (1, False, ["reason"]),
    "update_running": (1, True, ["lock"]),
    "internal": (4, False, []),
    "wait_timeout": (124, True, ["waited"]),
}
assert set(doc["errors"]) == set(EXPECTED_ERRORS), sorted(set(doc["errors"]) ^ set(EXPECTED_ERRORS))
# fields every error of the code may carry, when they apply (a refused bus file names itself)
# outcome_unknown: the hold watchdog stopped the command during a COMMIT, so the write may or may not have been saved
EXPECTED_OPTIONAL = {"bus_unavailable": ["file", "outcome_unknown"],
                     # several resources: every blocked one, and every one not held
                     "claim_conflict": ["conflicts"], "not_held": ["resources"],
                     # an identifier with a control character: the argument that held it
                     "bad_input": ["field"],
                     # upgrade stopped once a migration committed: what was migrated, its backup, how to finish
                     # and the files the command had already changed (init, upgrade's copy, setup)
                     "interrupted": ["directory", "backup", "migrations", "rerun", "changed", "argv"]}
for code, (status, retryable, fields) in EXPECTED_ERRORS.items():
    e = doc["errors"][code]
    assert (e["exit"], e["retryable"], e["fields"]) == (status, retryable, fields), (code, e)
    assert e["optional_fields"] == EXPECTED_OPTIONAL.get(code, []), (code, e)
    assert e["action"] and e["meaning"], code
assert {int(k): v for k, v in doc["exit_codes"].items()}.keys() == {0, 1, 2, 3, 4, 124, 130}, doc["exit_codes"]
assert {"AGENTBUS_DB", "AGENTBUS_AGENT"} <= set(doc["env"]), doc["env"]
RETRY = {"safe", "at_least_once", "idempotent", "idempotent_with_flag", "needs_request_id", "unsafe"}
for name, c in commands.items():
    assert c["summary"] and c["retry"]["class"] in RETRY and c["retry"]["how"], name
    assert set(c["errors"]) <= set(EXPECTED_ERRORS) and "internal" in c["errors"], (name, c["errors"])
    assert c["exit_codes"] and set(c["exit_codes"]) <= {0, 1, 2, 3, 4, 124, 130}, name
    assert check_schema(c["result"], objects) == [], (name, check_schema(c["result"], objects))
for name, o in objects.items():
    assert check_schema(o, objects) == [], (name, check_schema(o, objects))
print("PASS: the registry's error, exit-code, env and retry tables match the design")

# ---- schema COMMAND prints one command's entry ----
one = ok("schema", "post")
assert set(one["commands"]) == {"post"} and one["commands"]["post"] == commands["post"], one["commands"].keys()
group = ok("schema", "ctx")
assert set(group["commands"]) == {"ctx set", "ctx get", "ctx history"}, group["commands"].keys()
assert set(ok("schema", "ctx", "get")["commands"]) == {"ctx get"}
e, status = error("schema", "nope")
assert e["code"] == "bad_input" and e["retryable"] is False, e
args = {a["name"]: a for a in commands["post"]["args"]}
assert args["body"]["positional"] is True and args["--to"]["default"] == "*", args
assert args["--kind"]["choices"] == ["note", "question", "answer", "handoff", "decision", "alert", "done"], args["--kind"]
assert args["--request-id"]["type"] == "string" and "default" not in args["--request-id"], args["--request-id"]
assert commands["who"]["args"][-1]["name"] == "--limit" and commands["who"]["args"][-1]["type"] == "integer"
# the output-discipline additions (WS L-out): written out here, independently of the registry
assert [g["name"] for g in doc["global_args"]] == ["--as", "--json", "--up"], doc["global_args"]
full_branch = commands["schema"]["result"]["anyOf"][0]
assert "global_args" in full_branch["properties"], "schema's own result must describe global_args"
# schema COMMAND leaves the shared parts out unless --full, so they are no longer required of every schema result
assert {"global_args", "exit_codes", "env"}.isdisjoint(full_branch["required"]) and {"contract", "commands", "errors"} <= set(full_branch["required"]), full_branch["required"]
assert objects["Message"]["properties"]["body_truncated"] == {"type": "boolean"} and "body_truncated" not in objects["Message"]["required"]
read_args = {a["name"]: a for a in commands["read"]["args"]}
assert read_args["--id"]["type"] == "integer" and read_args["--limit"]["default"] == 50, read_args
assert "no_message" in commands["read"]["errors"] and len(commands["read"]["result"]["anyOf"]) == 2, commands["read"]
assert {a["name"]: a for a in commands["schema"]["args"]}["--index"]["type"] == "boolean"
assert {a["name"]: a for a in commands["inbox"]["args"]}["--limit"]["default"] == 20
assert {a["name"]: a for a in commands["status"]["args"]}["--limit"]["default"] == 20
for name in ("who", "claims"):
    assert {a["name"]: a for a in commands[name]["args"]}["--limit"]["default"] == 50, name
assert doc["errors"]["bad_input"]["optional_fields"] == ["field"] and "64 KB" in doc["errors"]["bad_input"]["meaning"]
assert "pipe" in doc["env"]["COLUMNS"]["meaning"]
trim = ok("schema", "post")
assert set(trim["objects"]) == {"Warning"} and set(trim["errors"]) <= set(doc["errors"]) and "claim_conflict" not in trim["errors"], trim.keys()
assert set(ok("schema", "ctx")["objects"]) == {"Fact", "FactVersion"}
print("PASS: schema COMMAND prints one command's entry, with arguments read from the parser")

# ---- the human table: one line per command ----
p = run("schema")
assert p.returncode == 0 and p.stdout, p
assert re.search(r"^  post +\{id, warnings\} +retry: only with --request-id$", p.stdout, re.M), p.stdout
assert len(p.stdout.splitlines()) <= 34, "one screen"   # 29 commands plus the header and the details line; was 30 before help, completion, brief, demo, update and doctor joined the table
for name in commands:
    assert re.search(r"^  " + re.escape(name) + r"  ", p.stdout, re.M), (name, p.stdout)
print("PASS: schema prints a one-screen table: command, result, retry")

# ---- help ends with the registry's result line ----
for name, c in commands.items():
    h = run(*name.split(), "--help")
    assert h.returncode == 0, (name, h.stderr)
    last = [l for l in h.stdout.splitlines() if l.strip()][-1]
    assert last == c["help"], (name, last, c["help"])
    assert re.fullmatch(r"JSON result: .+\. Retry: .+\.", c["help"]), c["help"]
assert commands["post"]["help"] == 'JSON result: {"id": integer, "warnings": [Warning]}. Retry: only with --request-id.'
print("PASS: help text for each subcommand ends with its JSON result line")

# ---- every die() carries a code (static check over the source) ----
src = open(bin_).read()
tree = ast.parse(src)
bad = []
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ("die", "die_now", "exit_now", "Diag"):
        kws = {k.arg: k.value for k in node.keywords}
        code = node.args[1] if len(node.args) > 1 else kws.get("code")
        if code is None:
            bad.append((node.lineno, node.func.id))
        elif isinstance(code, ast.Constant) and code.value not in EXPECTED_ERRORS:
            bad.append((node.lineno, "unregistered code " + repr(code.value)))
# the definitions' own defaults and the helper that forwards a code are the only calls with a variable code
bad = [b for b in bad if b[0] not in ()]
assert not bad, ("die() without a registered code", bad)
print("PASS: no die() in the source lacks a registered code")

# ---- every error code is produced by a scripted failure, with its extra fields and retryable ----
# a real SIGINT is sent to a running command in tests/test_failure_phases.sh
NOT_YET = {"interrupted"}
produced = {}
# Per command: every code a scripted failure of a command produces must be in that command's own errors list (a code
# declared for some other command is not enough). Bug it catches: init raised schema_newer, schema_corrupt and
# schema_refused, which only the bus commands declared.
def command_of(args):
    rest = list(args)
    while rest and rest[0] in ("--json", "--as", "--up"):
        rest = rest[2:] if rest[0] != "--json" else rest[1:]
    name = rest[0]
    if name in ("ctx", "log") and len(rest) > 1:
        name += " " + rest[1]
    return name
def declared(code, args):
    name = command_of(args)
    assert code in commands[name]["errors"], ("a code the command does not declare", name, code, commands[name]["errors"])
    assert EXPECTED_ERRORS[code][0] in commands[name]["exit_codes"], (name, code, commands[name]["exit_codes"])
def expect(code, *args, db=None, **k):
    e, status = error(*args, db=db, **k)
    assert e["code"] == code, (code, e)
    declared(code, args)
    spec = EXPECTED_ERRORS[code]
    assert e["retryable"] is spec[1], (code, e)
    for f in spec[2]:
        assert f in e, (code, "missing field", f, e)
    assert isinstance(e["message"], str) and e["message"], e
    assert isinstance(e["committed"], bool), ("every error says whether the command's change was saved", e)
    produced[code] = e
    return e

db = fresh("errs")
for n in ("a", "b"):
    ok("--as", n, "join", db=db)
ok("--as", "a", "claim", "src/api/", "--purpose", "refactor", db=db)
e = expect("claim_conflict", "--as", "b", "claim", "src/api/x.py", db=db)
assert (e["resource"], e["holder"], e["purpose"]) == ("src/api/x.py", "a", "refactor"), e
assert e["holder_idle_min"] in (0, 1) and e["takeover"] is None and "conflicts" not in e, ("one resource: the old fields plus the holder's age", e)
e = expect("claim_conflict", "--as", "b", "claim", "src/api/x.py", "src/api/y.py", "free.py", db=db)
assert [c["resource"] for c in e["conflicts"]] == ["src/api/x.py", "src/api/y.py"] and {c["holder"] for c in e["conflicts"]} == {"a"}, e
assert all(set(c) == {"resource", "holder", "held", "expires_at", "purpose", "holder_last_seen", "holder_idle_min", "takeover"} for c in e["conflicts"]), e
expect("not_held", "--as", "b", "release", "src/api/", db=db)
e = expect("not_held", "--as", "b", "release", "src/api/", "other/", db=db)
assert e["resources"] == ["src/api/", "other/"], e
expect("wait_timeout", "--as", "a", "wait", "--timeout", "1", db=db)
expect("no_message", "--as", "a", "post", "hi", "--reply-to", "99", db=db)
expect("no_context_key", "ctx", "get", "nope", db=db)
expect("not_on_roster", "--as", "ghost", "claim", "x", db=db)
e = expect("name_active", "--as", "a", "join", db=db)
assert e["agent"] == "a" and isinstance(e["last_seen_min"], int) and e["suggested_name"] == "a-2", e
first = ok("--as", "a", "post", "one", "--request-id", "tok", db=db)
e = expect("request_id_reused", "--as", "a", "post", "two", "--request-id", "tok", db=db)
assert e["original_id"] == first["id"] and "Original: #%d" % first["id"] in e["message"], e
expect("bad_input", "--as", "a", "post", "hi", "--kind", "fyi", db=db)
expect("no_bus", "who")
expect("internal", "who", db=db, env={"AGENTBUS_TEST_FAIL": "internal"})
ok("--as", "a", "post", "unread", "--to", "b", db=db)
p = run("--json", "--as", "b", "inbox", db=db, env={"AGENTBUS_TEST_FAIL": "ack"})
e = json.loads(p.stderr)["error"]   # the one failure that leaves complete output on stdout
assert p.returncode == 3 and e["code"] == "ack_failed" and e["delivered"] is True and e["retryable"] is True, p
assert json.loads(p.stdout)["items"], "the delivered messages are on stdout"
produced["ack_failed"] = e
open(db + "-journal", "w").close()
e = expect("bus_unavailable", "who", db=db)
assert e["file"] == os.path.abspath(db) + "-journal", ("a refused bus file is named in file", e)
os.unlink(db + "-journal")
p = run("--json", "--as", "a", "post", "late", db=db, closed=True)
assert p.returncode != 0 and json.loads(p.stderr)["error"]["code"] == "output_failed", p
e = json.loads(p.stderr)["error"]
# the post was saved and had no request id, so repeating it would post twice
assert e["committed"] is True and e["retryable"] is False, e
p = run("--json", "--as", "a", "post", "late2", "--request-id", "tokC", db=db, closed=True)
assert json.loads(p.stderr)["error"]["retryable"] is True, "with a request id the retry is safe"
produced["output_failed"] = True
# every error object declares the fields all of them carry
assert set(doc["error_fields"]) == {"code", "message", "retryable", "committed", "next"}, doc.get("error_fields")
for name in ("code", "message", "retryable", "committed", "next"):
    assert doc["error_fields"][name]["meaning"], name
for e in produced.values():
    if isinstance(e, dict):
        assert set(doc["error_fields"]) <= set(e), ("an error lacks a declared common field", e)
sdb = fresh("foreign")
ok("--as", "a", "join", db=sdb)
c = sqlite3.connect(sdb); c.execute("CREATE TABLE foreign_table(x)"); c.commit(); c.close()
expect("schema_refused", "who", db=sdb)
bdb = fresh("held")
ok("--as", "a", "join", db=bdb)
holder = sqlite3.connect(bdb); holder.execute("SELECT * FROM agents").fetchall()
try:
    expect("busy", "who", db=bdb)
finally:
    holder.close()
# The schema and upgrade codes. A bus one schema version ahead (newer) or a version no release writes
# (corrupt), set with sqlite3 as another tool would; a folder whose copy says it is a later release.
def set_version(db, v):
    c = sqlite3.connect(db); c.execute("PRAGMA user_version=%d" % v); c.close()
ndb = fresh("newer")
ok("--as", "a", "join", db=ndb)
set_version(ndb, 2)
e = expect("schema_newer", "who", db=ndb)
assert (e["bus"], e["bus_schema"], e["tool_schema"]) == (os.path.abspath(ndb), 2, 1), e
set_version(ndb, -1)
e = expect("schema_corrupt", "who", db=ndb)
assert (e["bus"], e["bus_schema"]) == (os.path.abspath(ndb), -1), e
cdir = os.path.join(tmp, "copynewer"); os.makedirs(cdir)
ok("init", cdir)
with open(os.path.join(cdir, ".agentbus", "VERSION"), "w") as f:
    f.write("99.0.0\n")
e = expect("copy_newer", "upgrade", cdir)
assert (e["directory"], e["copy_version"]) == (os.path.realpath(cdir), "99.0.0") and e["tool_version"] == doc["agentbus"], e
# An older bus needs a release that knows a later schema: this checkout's agentbus with schema 2, as a
# release that changes the schema would ship it (a new SCHEMA, SCHEMA_VERSION and a MIGRATIONS entry).
v2 = os.path.join(tmp, "v2.py")
with open(v2, "w") as f:
    f.write("""import runpy, sys
m = runpy.run_path(sys.argv.pop(1), run_name="agentbus_v2")
old = "action TEXT NOT NULL, detail TEXT);"
assert old in m["SCHEMA"]
g = m["cli"].__globals__
g["SCHEMA"] = m["SCHEMA"].replace(old, "action TEXT NOT NULL, detail TEXT, extra TEXT);")
g["SCHEMA_VERSION"] = 2
g["MIGRATIONS"][1] = ["ALTER TABLE log ADD COLUMN extra TEXT"]
g["reference_shapes"].cache_clear()
g["reference_indexes"].cache_clear()
sys.argv = ["agentbus"] + sys.argv[1:]
g["cli"]()
""")
V2 = [sys.executable, v2, os.environ.get("AGENTBUS_BIN") or bin_]
def expect_v2(code, *args, db, env=None):
    e = dict(BASE, AGENTBUS_DB=db, HOME=os.path.join(tmp, "v2home"), **(env or {}))
    os.makedirs(e["HOME"], exist_ok=True)
    p = subprocess.run([*V2, "--json", *args], cwd=e["HOME"], env=e, text=True, timeout=60, capture_output=True)
    assert p.returncode == EXPECTED_ERRORS[code][0] and p.stdout == "", (code, p.returncode, p.stdout, p.stderr)
    err = json.loads(p.stderr)["error"]
    assert err["code"] == code and err["retryable"] is EXPECTED_ERRORS[code][1], err
    declared(code, args)
    for f in EXPECTED_ERRORS[code][2]:
        assert f in err, (code, "missing field", f, err)
    produced[code] = err
    return err
odb = fresh("older")
ok("--as", "a", "join", db=odb)
e = expect_v2("schema_older", "watch", "--once", db=odb)  # a read-only open never migrates
assert (e["bus"], e["bus_schema"], e["tool_schema"]) == (os.path.abspath(odb), 1, 2), e
e = expect_v2("backup_failed", "who", db=odb, env={"AGENTBUS_TEST_BACKUP_FAIL": "enospc"})
assert e["bus"] == os.path.abspath(odb) and e["reason"], e
# init over a bus folder whose bus it cannot read as its own: a newer schema, a version no release writes, foreign tables
idir = os.path.join(tmp, "initbus"); os.makedirs(idir)
ok("init", idir)
ok("--as", "a", "join", db=os.path.join(idir, ".agentbus", "bus.db"))
idb = os.path.join(idir, ".agentbus", "bus.db")
set_version(idb, 5)
expect("schema_newer", "init", idir)
set_version(idb, -3)
expect("schema_corrupt", "init", idir)
set_version(idb, 1)
c = sqlite3.connect(idb); c.execute("ALTER TABLE claims ADD COLUMN extra TEXT"); c.commit(); c.close()
expect("schema_refused", "init", idir)
# items_failed: upgrade --all with a bus it cannot upgrade, and setup refusing a file it will not overwrite. The
# result is on stdout; the error, on stderr, lists the failed rows.
fdir = os.path.join(tmp, "allfail"); os.makedirs(os.path.join(fdir, "x"))
ok("init", os.path.join(fdir, "x"))
os.unlink(os.path.join(fdir, "x", ".agentbus", "bin", "agentbus"))
os.symlink(bin_, os.path.join(fdir, "x", ".agentbus", "bin", "agentbus"))
for args, env in ((("upgrade", "--all", fdir), None),
                  (("setup", "codex"), {"CODEX_HOME": os.path.join(tmp, "cxlink")})):
    if env:
        os.makedirs(env["CODEX_HOME"]); os.symlink(os.path.join(tmp, "elsewhere.md"), os.path.join(env["CODEX_HOME"], "AGENTS.md"))
    p = run("--json", *args, env=env)
    e = json.loads(p.stderr)["error"]
    assert p.returncode == 1 and e["code"] == "items_failed" and e["retryable"] is False and e["failed"], (args, p.returncode, p.stderr)
    assert json.loads(p.stdout), ("the result is still on stdout", args, p.stdout)
    declared("items_failed", args)
    produced["items_failed"] = e
# The six update codes: tests/update_codes.sh runs one failing `update` per code against fake installs and the fixture
# release server, and leaves each JSON error in a file here.
ucodes = os.path.join(tmp, "update_codes"); os.makedirs(ucodes)
p = subprocess.run(["bash", os.path.join(os.environ["TESTS_DIR"], "update_codes.sh"), ucodes], capture_output=True, text=True, timeout=300,
                   env=dict(BASE, **{k: v for k, v in os.environ.items() if k in ("PYTHON", "AGENTBUS_BIN", "TESTS_DIR")}))
assert p.returncode == 0, ("update_codes.sh", p.returncode, p.stdout[-500:], p.stderr[-800:])
for code in ("installer_failed", "manual_step", "release_offline", "rate_limited", "release_unknown", "download_failed", "update_running"):
    err = json.loads(open(os.path.join(ucodes, code + ".json")).read())["error"]
    assert err["code"] == code and err["retryable"] is EXPECTED_ERRORS[code][1], (code, err)
    for f in EXPECTED_ERRORS[code][2]:
        assert f in err, (code, "missing field", f, err)
    assert isinstance(err["committed"], bool) and set(doc["error_fields"]) <= set(err), (code, err)
    declared(code, ("--json", "update"))
    produced[code] = err
missing = set(EXPECTED_ERRORS) - set(produced) - NOT_YET
assert not missing, ("codes with no scripted failure", sorted(missing))
print("PASS: every error code in the registry is produced by at least one scripted failure, with its extra fields")

# ---- status and watch --json carry omitted counts (the key 06 depends on) ----
wdb = fresh("omit")
for n in ("a", "b", "c"):
    ok("--as", n, "join", db=wdb)
    ok("--as", n, "claim", "res-" + n, db=wdb)
ok("--as", "a", "ctx", "set", "k1", "v", db=wdb); ok("--as", "a", "ctx", "set", "k2", "v", db=wdb)
for i in range(12):
    ok("--as", "a", "post", "m%d" % i, db=wdb)
st = ok("status", "--limit", "1", db=wdb)
# 3 agents and claims, 2 facts, 12 messages: one of each is shown by --limit 1 (messages too), and all of them by default
assert st["omitted"] == {"agents": 2, "context": 1, "claims": 2, "messages": 11}, st["omitted"]
assert ok("status", db=wdb)["omitted"] == {"agents": 0, "context": 0, "claims": 0, "messages": 0}
w = ok("watch", db=wdb)
assert w["omitted"] == {"agents": 0, "context": 0, "claims": 0, "messages": 0}, w["omitted"]
print("PASS: status and watch --json carry omitted counts")

# ---- the scripted workflow: every --json result validates against its schema ----
wf = fresh("flow")
RESULTS = {}
def step(name, *args, **k):
    r = ok(*args, db=wf, **k)
    problems = validate(r, commands[name]["result"], objects)
    assert not problems, (name, args, problems, r)
    RESULTS.setdefault(name, []).append(r)
    return r
step("join", "--as", "a", "join", "--tool", "t")
step("join", "--as", "b", "join")
step("post", "--as", "a", "post", "hello")
q = step("post", "--as", "a", "post", "q", "--to", "b", "--kind", "question")
step("post", "--as", "a", "post", "q", "--to", "b", "--kind", "question", "--request-id", "r1")
step("post", "--as", "a", "post", "q", "--to", "b", "--kind", "question", "--request-id", "r1")
step("post", "--as", "b", "post", "ans", "--to", "a", "--reply-to", str(q["id"]), "--kind", "answer")
long_post = step("post", "--as", "a", "post", "-", stdin="long body " * 400)   # 4 KB: a listing cuts it
step("ctx set", "--as", "a", "ctx", "set", "k", "v1")
step("ctx get", "ctx", "get", "k")
step("goal", "--as", "a", "goal", "ship it")
step("goal", "goal")
step("claim", "--as", "a", "claim", "src/a.py", "--purpose", "p")
step("claim", "--as", "a", "claim", "issue:1")
step("release", "--as", "a", "release", "src/a.py")
step("release", "--as", "a", "release", "--all")
step("claim", "--as", "a", "claim", "src/m1.py", "src/m2.py")   # several: the second shape of the claim result
step("release", "--as", "a", "release", "src/m1.py", "src/m2.py")
ok("--as", "a", "post", "for wait", "--to", "b", db=wf)
step("wait", "--as", "b", "wait", "--timeout", "5")
step("log add", "--as", "a", "log", "add", "note", "detail")
step("status", "status")
step("watch", "watch")
step("watch", "watch", "--once")
step("brief", "brief")
step("brief", "--as", "b", "brief")
step("schema", "schema")
step("schema", "schema", "post")
step("schema", "schema", "--index")
# update --check from the checkout (a clone) answers from a good cache entry: no request is made. (The full update
# result is validated in tests/test_update.sh.)
uhome = os.path.join(tmp, "uhome")
ucache = os.path.join(uhome, "Library", "Caches", "agentbus") if sys.platform == "darwin" else os.path.join(uhome, ".cache", "agentbus")
os.makedirs(ucache, mode=0o700)
json.dump({"v": 1, "checked_at": int(__import__("time").time()), "ok": True, "reason": None, "retry_after": None,
           "stable": "0.9.0", "pre": None, "notified": None}, open(os.path.join(ucache, "release-check.json"), "w"))
os.chmod(os.path.join(ucache, "release-check.json"), 0o600)
chk = step("update", "update", "--check", home=uhome, env={"XDG_CACHE_HOME": os.path.join(uhome, ".cache")})
assert chk["update_available"] is True and chk["latest"] == "0.9.0" and chk["install"]["method"] == "clone", chk
step("leave", "--as", "a", "leave")
repo = os.path.join(tmp, "install"); os.makedirs(repo)
step("init", "init", repo)
step("upgrade", "upgrade", repo)
step("upgrade", "upgrade", "--all", repo)
step("upgrade", "upgrade", "--dry-run", repo)
step("demo", "demo")
step("skill", "skill")
step("skill", "skill", "--agents-md")
step("help", "help", "ctx", "set")
step("completion", "completion", "bash")
# a dry run writes nothing; the config folders point into this test's own temp folder all the same
step("setup", "setup", "claude", "--dry-run", env={"CLAUDE_CONFIG_DIR": os.path.join(tmp, "cc"), "CODEX_HOME": os.path.join(tmp, "cx")})
step("setup", "setup", "codex", "--dry-run", env={"CLAUDE_CONFIG_DIR": os.path.join(tmp, "cc"), "CODEX_HOME": os.path.join(tmp, "cx")})
step("hooks", "hooks", "codex")
# doctor reads only; its config folders point into this test's own temp folder too
step("doctor", "doctor", env={"CLAUDE_CONFIG_DIR": os.path.join(tmp, "cc"), "CODEX_HOME": os.path.join(tmp, "cx")})
step("doctor", "doctor", "--scope", "project", env={"CLAUDE_CONFIG_DIR": os.path.join(tmp, "cc"), "CODEX_HOME": os.path.join(tmp, "cx")})
LISTINGS = ["who", "inbox", "read", "claims", "ctx get", "ctx history", "log show", "buses"]
if NEEDS_ENVELOPE:
    step("who", "who")
    step("inbox", "--as", "b", "inbox")
    step("read", "read")
    cut = [m for m in RESULTS["read"][-1]["items"] if m["id"] == long_post["id"]][0]
    assert cut["body_truncated"] is True and len(cut["body"].encode()) == 2048, cut
    whole = step("read", "read", "--id", str(long_post["id"]))   # one Message, whole: not a listing
    assert len(whole["body"]) == 4000 - 1 and "body_truncated" not in whole, whole
    step("claims", "claims")
    step("ctx get", "ctx", "get")
    step("ctx history", "ctx", "history", "k")
    step("log show", "log", "show")
    step("buses", "buses")
    # a listing's rows carry exactly the fields its object declares: none undeclared (copy_version and stale on buses)
    for name in LISTINGS:
        ref = commands[name]["result"]
        ref = next((x for x in ref.get("anyOf", [ref]) if "items" in x.get("properties", {})), ref)
        obj = objects[ref["properties"]["items"]["items"]["$ref"].rsplit("/", 1)[1]]
        for r in RESULTS[name]:
            for row in (r["items"] if isinstance(r, dict) and "items" in r else []):
                assert set(row) <= set(obj["properties"]), (name, "fields the registry does not declare", sorted(set(row) - set(obj["properties"])))
covered = set(RESULTS) | (set() if NEEDS_ENVELOPE else set(LISTINGS))
assert covered == set(commands), ("commands the workflow never ran", sorted(set(commands) - covered))
# a wrong result must fail validation: the validator is not vacuous
assert validate({"id": "1"}, commands["post"]["result"], objects), "a string id passed"
assert validate({}, commands["post"]["result"], objects), "a missing id passed"
assert RESULTS["post"][3] == {"contract": 1, "id": RESULTS["post"][2]["id"], "duplicate": True, "warnings": []}, RESULTS["post"]
print("PASS: every --json result of a scripted workflow of all commands validates against its schema")
# ---- the tables of docs/reference.md are generated from the registry, and --check notices when they are not ----
root = os.path.dirname(os.path.dirname(os.path.abspath(bin_)))
gen = [os.environ.get("PYTHON") or "python3", os.path.join(root, "scripts", "gen_reference.py")]
genv = dict(BASE, **{k: v for k, v in os.environ.items() if k in ("AGENTBUS_CMD", "AGENTBUS_BIN")})
p = subprocess.run(gen + ["--check"], capture_output=True, text=True, env=genv, timeout=60)
assert p.returncode == 0 and p.stdout.strip() == "reference tables are current", (p.stdout, p.stderr)
stale = os.path.join(tmp, "reference.md")
text = open(os.path.join(root, "docs", "reference.md"), encoding="utf-8").read()
assert "| `bad_input` | 2 |" in text, "the error table lists bad_input with exit 2"
# The prose around the tables: the codes that can leave output on stdout with a non-zero exit (items_failed prints the
# whole result first), and the setup row names the backup a change may carry.
m = re.search(r"Output together with a non-zero exit is possible for (.*?)\.", text)
assert m and set(re.findall(r"`([a-z_]+)`", m.group(1))) == {"ack_failed", "output_failed", "interrupted", "items_failed"}, m and m.group(1)
assert "The one refusal with output is `items_failed`" in text, "the stdout-empty rule names its exception"
row = next(l for l in text.splitlines() if l.startswith("| `setup` |"))
assert '"backup"' in row and '"backup"' in commands["setup"]["help"], row
open(stale, "w", encoding="utf-8").write(text.replace("| `bad_input` | 2 |", "| `bad_input` | 1 |"))
p = subprocess.run(gen + ["--check", "--file", stale], capture_output=True, text=True, env=genv, timeout=60)
assert p.returncode != 0 and "errors" in p.stderr and "stale" in p.stderr, (p.returncode, p.stdout, p.stderr)
p = subprocess.run(gen + ["--file", stale], capture_output=True, text=True, env=genv, timeout=60)
assert p.returncode == 0 and open(stale, encoding="utf-8").read() == text, "regenerating restores the page"
print("PASS: docs/reference.md tables are current, and --check fails on a stale page")
PY
echo "All contract tests passed"
