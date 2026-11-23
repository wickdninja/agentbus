#!/bin/bash
set -euo pipefail
# Learning cycle 1, M1 (issue #89): three cuts and the roster's ghosts.
# K2: `demo` and `completion` are gone: no help line, no schema entry, no mention in the docs or the skill, and running
#     either gets the ordinary unknown-command error. Bug it catches: a cut command that still answers, or a doc or
#     the skill that still sends an agent to it.
# K4: `log` is not a verb: any `agentbus log ...` refuses with one line pointing at brief (rulings) and read --topic
#     (messages by topic), and the log table still gets its rows. Bug it catches: `log --topic ruling` mistaken for
#     read, and a cut that also stopped the writes the usage collector reads.
# E2: brief and who list only agents that posted, claimed or read, and count the rest in one line. Bug it catches:
#     hook-made names that never did anything burying the agents that did.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
"$PY" - "$T" "$ROOT" <<'PY'
import json, os, re, sqlite3, subprocess, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
tmp, root = sys.argv[1], sys.argv[2]
BASE = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
BASE.update(COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1", HOME=tmp)
CUT = ("demo", "completion")


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def run(db, *args):
    return subprocess.run([*agentbus_argv(), *args], cwd=tmp, env=dict(BASE, AGENTBUS_DB=db), capture_output=True,
                          text=True, timeout=60)


def ok(db, *args):
    p = run(db, *args)
    if p.returncode != 0:
        fail("command failed: %s rc %s: %s" % (args, p.returncode, p.stderr.strip()))
    return p.stdout


DB = os.path.join(tmp, "bus", "bus.db")
os.makedirs(os.path.dirname(DB))

print("TEST 1 (K2): demo and completion are named nowhere: help, schema, docs, the skill")
help_text = ok(DB, "--help")
for word in CUT + ("log",):
    if re.search(r"^\s+%s\b" % word, help_text, re.M):
        fail("--help still lists %s" % word)
    if re.search(r"agentbus %s\b" % word, help_text):
        fail("--help still names agentbus %s" % word)
schema = json.loads(ok(DB, "--json", "schema"))
for name in schema["commands"]:
    if name.split()[0] in CUT + ("log",):
        fail("schema --json still has the command %r" % name)
index = ok(DB, "schema", "--index")
for word in CUT + ("log",):
    if re.search(r"^\s*%s\b" % word, index, re.M):
        fail("schema --index still lists %s" % word)
named = re.compile(r"agentbus (?:--\S+ (?:\S+ )?)*(demo|completion|log)\b|`(demo|completion|log(?: add| show)?)`")
texts = {"agentbus skill": ok(DB, "skill")}
for rel in ("README.md", "docs/reference.md", "docs/protocol.md", "skill/SKILL.md", "skills/agentbus/SKILL.md",
            "CONTRIBUTING.md"):
    texts[rel] = open(os.path.join(root, rel), encoding="utf-8").read()
for where, text in texts.items():
    m = named.search(text)
    if m:
        fail("%s still names a cut command: %r" % (where, m.group(0)))
print("PASS: help, schema, README, docs and the skill name neither demo, completion nor log")

print("TEST 2 (K2): agentbus demo and agentbus completion get the ordinary unknown-command error")
for word, args in (("demo", ("demo",)), ("demo", ("demo", "--no-pause")), ("completion", ("completion", "zsh")),
                   ("demo", ("help", "demo")), ("completion", ("help", "completion"))):
    p = run(DB, *args)
    lines = p.stderr.splitlines()
    if p.returncode != 2 or p.stdout or len(lines) != 1:
        fail("%s: rc %s, stdout %r, stderr %r" % (args, p.returncode, p.stdout, p.stderr))
    if not lines[0].startswith("agentbus: error: unknown command '%s'." % word) or not lines[0].endswith("See: agentbus --help"):
        fail("%s is not the unknown-command error: %r" % (args, lines[0]))
    listed = lines[0].split("Commands: ", 1)[1].split(". See:")[0].split(", ")
    for gone in CUT + ("log",):
        if gone in listed:
            fail("the unknown-command error still lists %s: %r" % (gone, lines[0]))
j = json.loads(run(DB, "--json", "demo").stderr)
if j["error"]["code"] != "bad_input" or "unknown command 'demo'" not in j["error"]["message"]:
    fail("--json demo: %r" % j)
print("PASS: both are unknown commands, and the list of commands names neither")

print("TEST 3 (K4): every agentbus log ... refuses with one line pointing at brief and read --topic")
POINTER = "agentbus: error: log is not a command; rulings: agentbus brief; messages by topic: agentbus read --topic T"
ok(DB, "--as", "a", "join")
for args in (("log",), ("log", "show"), ("log", "show", "--limit", "5"), ("--as", "a", "log", "add", "note", "x"),
             ("log", "--topic", "ruling"), ("--up", "1", "log", "show"), ("help", "log"), ("log", "--help")):
    p = run(DB, *args)
    if p.returncode != 2 or p.stdout or p.stderr != POINTER + "\n":
        fail("%s: rc %s, stdout %r, stderr %r" % (args, p.returncode, p.stdout, p.stderr))
j = json.loads(run(DB, "--json", "log", "show").stderr)
if j["error"]["code"] != "bad_input" or j["error"]["next"] != "agentbus brief" or "\n" in j["error"]["message"]:
    fail("--json log show: %r" % j)
print("PASS: one line, rc 2, nothing on stdout")

print("TEST 4 (K4): the log table still gets its rows (the collector reads them)")
ok(DB, "--as", "a", "claim", "area:x")
ok(DB, "--as", "a", "goal", "ship")
ok(DB, "--as", "a", "release", "area:x")
ok(DB, "--as", "a", "leave")
c = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
actions = [r[0] for r in c.execute("SELECT action FROM log WHERE agent='a' ORDER BY id")]
c.close()
if actions != ["join", "claim", "goal", "release", "leave"]:
    fail("log rows: %r" % actions)
print("PASS: join, claim, goal, release and leave still write their rows")

print("TEST 5 (E2): brief and who list the agents that posted, claimed or read, and count the ghost")
DB2 = os.path.join(tmp, "bus2", "bus.db")
os.makedirs(os.path.dirname(DB2))
for n in ("ghost", "poster", "claimer", "reader"):
    ok(DB2, "--as", n, "join")
ok(DB2, "--as", "poster", "post", "--to", "reader", "hello")
ok(DB2, "--as", "claimer", "claim", "area:c")
ok(DB2, "--as", "reader", "inbox")
active = {"poster", "claimer", "reader"}
GHOST_LINE = "1 more joined and never posted, claimed or read"
b = json.loads(ok(DB2, "--json", "--as", "reader", "brief"))
names = {x["name"] for x in b["agents"]["items"]}
if names != active or b["agents"]["inactive"] != 1:
    fail("brief --json agents: %r inactive %r" % (names, b["agents"].get("inactive")))
text = ok(DB2, "--as", "reader", "brief")
if "ghost" in text or not re.search(r"^here \(3\):$", text, re.M) or not re.search(r"^  %s$" % GHOST_LINE, text, re.M):
    fail("brief text roster: %s" % text)
for n in active:
    if not re.search(r"^  %s\b" % n, text, re.M):
        fail("brief does not list %s: %s" % (n, text))
w = json.loads(ok(DB2, "--json", "who"))
if {x["name"] for x in w["items"]} != active or w["inactive"] != 1 or w["has_more"]:
    fail("who --json: %r" % w)
text = ok(DB2, "who")
if "ghost" in text or text.splitlines()[-1] != "  " + GHOST_LINE or len(text.splitlines()) != 4:
    fail("who text: %r" % text)
print("PASS: three acting agents listed, the ghost counted in one line")

print("TEST 6 (E2): an agent that only set a fact is acting; a bus of ghosts and an empty bus each say so")
DB3 = os.path.join(tmp, "bus3", "bus.db")
os.makedirs(os.path.dirname(DB3))
ok(DB3, "--as", "g1", "join")
ok(DB3, "--as", "g2", "join")
if json.loads(ok(DB3, "--json", "who"))["items"] or json.loads(ok(DB3, "--json", "who"))["inactive"] != 2:
    fail("a bus of ghosts: who --json lists one")
text = ok(DB3, "who")
if text != "  2 more joined and never posted, claimed or read\n":
    fail("a bus of ghosts, who: %r" % text)
text = ok(DB3, "brief")
if not re.search(r"^here: 2 joined, none has posted, claimed or read$", text, re.M):
    fail("a bus of ghosts, brief: %s" % text)
ok(DB3, "--as", "g1", "ctx", "set", "k", "v")
w = json.loads(ok(DB3, "--json", "who"))
if [x["name"] for x in w["items"]] != ["g1"] or w["inactive"] != 1:
    fail("a fact setter is acting: %r" % w)
text = ok(DB, "who")
if text.strip() != "no agents. Join with: agentbus --as NAME join":
    fail("an empty roster, who: %r" % text)
print("PASS: facts count as acting; an all-ghost bus and an empty bus each read right")
PY
all_passed "All cut tests passed"
