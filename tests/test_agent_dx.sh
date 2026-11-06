#!/bin/bash
set -euo pipefail
# Agent DX from the live skill trial: what brief tells an agent to do next when work is open, rows it cut say so, a
# --limit 0 brief never says "none" for what it only left out, and the decision line the skill teaches reads back.
# Each section names the bug that turns it red.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
"$PY" - "$T" <<'PY'
import json, os, subprocess, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
tmp = sys.argv[1]
BASE = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
BASE.update(COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1", HOME=tmp)


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def check(cond, msg):
    if not cond:
        fail(msg)


def run(db, *args, env=None):
    return subprocess.run([*agentbus_argv(), *args], cwd=tmp, env=dict(BASE, AGENTBUS_DB=db, **(env or {})), capture_output=True, text=True, timeout=60)


def ok(db, *args, env=None):
    p = run(db, *args, env=env)
    check(p.returncode == 0, "command failed: %s rc %s: %s" % (args, p.returncode, p.stderr.strip()))
    return p.stdout


def jok(db, *args):
    return json.loads(ok(db, "--json", *args))


def bus(name):
    d = os.path.join(tmp, name)
    os.makedirs(d)
    return os.path.join(d, "bus.db")


def join(db, *names):
    for n in names:
        ok(db, "--as", n, "join", "--role", "r-" + n)


def post(db, who, body, to=None, kind="note", reply=None, topic=None):
    args = ["--as", who, "--json", "post", body, "--kind", kind]
    for flag, v in (("--to", to), ("--reply-to", reply), ("--topic", topic)):
        if v is not None:
            args += [flag, str(v)]
    return json.loads(ok(db, *args))["id"]


def lines(text):
    return text.splitlines()


def line_with(text, needle):
    return next((l for l in lines(text) if needle in l), "")


# ---- next: points at the oldest open todo (how to read it whole, how to close it) ----
# Bug it catches: the live trial's agents were told "claim PATH --purpose WHY" while their own todos sat open, so a finished
# job ended the run with the other two never touched. Open todos come before the claim suggestion.
db = bus("next")
join(db, "alice", "bob")
t1 = post(db, "alice", "validate src/auth/", kind="todo")
t2 = post(db, "alice", "validate billing", kind="todo")
b = jok(db, "--as", "alice", "brief")
check(b["next"] == "agentbus --as alice read --id %d" % t1, "next with open todos: %s" % b["next"])
text = ok(db, "--as", "alice", "brief")
check("next: agentbus --as alice read --id %d" % t1 in lines(text), "text next line: %r" % text)
close = line_with(text, "--kind done")
check("post RESULT --reply-to %d --kind done" % t1 in close and "agentbus --as alice" in close,
      "no line says how to close the oldest todo: %r" % text)
check(lines(text).index(close) > lines(text).index("next: agentbus --as alice read --id %d" % t1) - 3,
      "the close line is not next to next:")
ok(db, "--as", "alice", "post", "validated", "--reply-to", str(t1), "--kind", "done")
check(jok(db, "--as", "alice", "brief")["next"] == "agentbus --as alice read --id %d" % t2, "next did not move to the next oldest todo")
ok(db, "--as", "alice", "post", "validated", "--reply-to", str(t2), "--kind", "done")
b = jok(db, "--as", "alice", "brief")
check(b["next"] == "agentbus --as alice claim PATH --purpose WHY", "with no open todo next is the claim line again: %s" % b["next"])
check("--kind done" not in ok(db, "--as", "alice", "brief"), "a close line shows with no open todo")
# a todo someone else owns (owner left) is still the oldest open one; an open question to me still comes first
join(db, "carol")
t3 = post(db, "bob", "finish the migration note", kind="todo")
ok(db, "--as", "bob", "leave")
ok(db, "--as", "carol", "inbox")
check(jok(db, "--as", "carol", "brief")["next"] == "agentbus --as carol read --id %d" % t3, "a todo whose owner left is not next")
q = post(db, "alice", "which branch?", to="carol", kind="question")
ok(db, "--as", "carol", "inbox")
check(jok(db, "--as", "carol", "brief")["next"].startswith("agentbus --as carol post ANSWER --to alice --reply-to %d" % q),
      "an open question to me must come before a todo")
text = ok(db, "--as", "carol", "brief")
check("--kind done" not in text, "a close line shows although next: is not the todo: %r" % text)
print("PASS: next names the oldest open todo with how to read and close it, after unread and questions, before the claim line")

# ---- a cut row says so and names read --id ----
# Bug it catches: a todo body "Validate src/auth/." + 40 lines of indentation + "Also validate billing." shows only the first
# sentence in brief; the second job is invisible and nothing says a body was cut.
db = bus("cut")
join(db, "alice", "bob")
long_body = "Validate src/auth/." + "\n    " * 40 + "Also validate billing."
t = post(db, "alice", long_body, to="bob", kind="todo")
text = ok(db, "--as", "alice", "brief")
row = line_with(text, "Validate src/auth/.")
check("read --id %d" % t in row and "cut" in row, "a todo cut by the 200-character read says nothing: %r" % row)
check(jok(db, "--as", "alice", "brief")["todos"]["items"][0]["body_truncated"] is True, "fixture: body_truncated is not true")
short = post(db, "alice", "short body\nwith two lines", to="bob", kind="todo")
row = line_with(ok(db, "--as", "alice", "brief"), "short body")
check("read --id" not in row and "cut" not in row, "a body that fits shows a marker anyway: %r" % row)
# a body past the 90 characters the text view shows
over = post(db, "alice", "x" * 150, to="bob", kind="todo")
row = line_with(ok(db, "--as", "alice", "brief"), "xxxxxxxx")
check("read --id %d" % over in row, "a body cut at 90 characters has no read --id: %r" % row)
# every section that shows bodies: question, unread handoff, pending between others, fact
q = post(db, "bob", "Q" * 150, to="alice", kind="question")
h = post(db, "bob", "H" * 150, to="alice", kind="handoff")
join(db, "dave")
p = post(db, "bob", "P" * 150, to="dave", kind="question")
ok(db, "--as", "bob", "ctx", "set", "wide", "F" * 150)
text = ok(db, "--as", "alice", "brief")
for needle, want in (("QQQQQQQQ", "read --id %d" % q), ("HHHHHHHH", "read --id %d" % h), ("PPPPPPPP", "read --id %d" % p),
                     ("wide = ", "ctx get wide")):
    row = line_with(text, needle)
    check(want in row, "the row with %s lacks %r: %r" % (needle, want, row))
ok(db, "--as", "bob", "ctx", "set", "narrow", "short value")
check("ctx get" not in line_with(ok(db, "--as", "alice", "brief"), "narrow = "), "a short fact shows a marker")
print("PASS: every brief row whose body was cut says so and names the command that reads it whole; whole rows stay clean")

# ---- --limit 0 never says "none" for what it only left out ----
# Bug it catches: at --limit 0 brief printed "here: nobody has joined", "open questions: none" and "facts: none" on a bus with
# agents, questions and facts, so an agent concluded the bus was empty.
db = bus("limit0")
join(db, "alice", "bob")
post(db, "bob", "question one", to="alice", kind="question")
post(db, "bob", "question two", to="*", kind="question")
join(db, "dave")
post(db, "bob", "between others", to="dave", kind="question")
ok(db, "--as", "bob", "ctx", "set", "k1", "v1")
text = ok(db, "--as", "alice", "brief", "--limit", "0")
for gone in ("nobody has joined", "open questions: none", "facts: none", "pending between others: none"):
    check(gone not in text, "--limit 0 says %r for items it only omitted: %r" % (gone, text))
check("here (3):" in text and "... 3 more" in text, "no agents total or hint: %r" % text)
check("open questions (2):" in text and "... 2 more" in text, "no questions total or hint: %r" % text)
check("pending between others (1):" in text, "no pending total: %r" % text)
check("facts (1):" in text and "... 1 more" in text, "no facts total or hint: %r" % text)
check("brief --limit" in text, "no widening hint: %r" % text)
# facts changed since a read keep their own wording
ok(db, "--as", "alice", "inbox")
post(db, "dave", "later", to="alice")
ok(db, "--as", "dave", "ctx", "set", "k2", "v2")
text = ok(db, "--as", "alice", "brief", "--limit", "0")
check("facts: none changed" not in text and "facts changed since your last read (" in text, "since-read facts at --limit 0: %r" % text)
# where the total really is zero, "none" stays
empty = bus("empty0")
text = ok(empty, "brief", "--limit", "0")
check("here: nobody has joined" in text and "open questions: none" in text and "facts: none" in text and "pending between others: none" in text,
      "an empty bus at --limit 0 lost its none lines: %r" % text)
print("PASS: --limit 0 shows each section's total and the widening hint; none only when the total is zero")

# ---- the decision line the skill teaches reads back ----
# Bug it catches: the skill said decisions are read with `read --topic decision`, but --kind decision sets no topic, so the
# read returned "no messages". No implicit topic: the post line carries --topic decision.
db = bus("decision")
join(db, "alice")
bare = post(db, "alice", "use RS256", kind="decision")
check(jok(db, "read", "--topic", "decision")["items"] == [], "--kind decision alone must not set a topic")
taught = json.loads(ok(db, "--as", "alice", "--json", "post", "use sqlite", "--kind", "decision", "--topic", "decision"))["id"]
got = [m["id"] for m in jok(db, "read", "--topic", "decision")["items"]]
check(got == [taught], "read --topic decision after the taught post line: %s" % got)
print("PASS: post --kind decision --topic decision is what read --topic decision returns")
# ---- watch counts the same open questions as brief, and shows open todos ----
# Bug it catches (issue 66): watch closed a question on any reply of any kind and counted only the 200 messages it holds, and it
# ignored todos; brief closes a question only on a direct answer and lists open todos. Two screens, two answers to "what is open".
db = bus("watchopen")
join(db, "alice", "bob")
qid = post(db, "alice", "which signing algorithm?", to="*", kind="question")
post(db, "bob", "looking into it", to="alice", kind="note", reply=qid)   # a reply of another kind does not answer it
tid = post(db, "alice", "validate billing", kind="todo")
aid = post(db, "alice", "CI is red", to="*", kind="alert")


def header(db):
    return lines(ok(db, "watch", "--once"))[0]


def both(db):
    w = jok(db, "watch")["open"]
    b = jok(db, "brief")
    return w, b


w, b = both(db)
check(w["questions"] == len(b["questions"]["items"]) == 1, "watch open questions %s, brief %s" % (w, len(b["questions"]["items"])))
check(w["todos"] == len(b["todos"]["items"]) == 1 and w["alerts"] == 1, "watch open todos/alerts: %s" % w)
check(header(db).endswith("1 alert \u00b7 1 open question \u00b7 1 open todo"), "watch header: %r" % header(db))
narrow = lines(ok(db, "watch", "--once", env={"COLUMNS": "60", "LINES": "20"}))[0]
check(narrow.endswith("1 ALRT \u00b7 1 ask \u00b7 1 todo"), "narrow watch header: %r" % narrow)
ok(db, "--as", "bob", "post", "RS256", "--kind", "answer", "--reply-to", str(qid))
ok(db, "--as", "bob", "post", "done it", "--kind", "done", "--reply-to", str(tid))
w, b = both(db)
check(w["questions"] == len(b["questions"]["items"]) == 0 and w["todos"] == len(b["todos"]["items"]) == 0, "after closing: %s" % w)
check(header(db).endswith("1 alert \u00b7 0 open questions"), "a header with no open todo mentions todos: %r" % header(db))
check("open todo" not in header(db), "a zero todo count is shown")
print("PASS: watch's open questions and todos are brief's, and its header shows open todos only when there are some")
# ---- on a very large bus watch counts the newest SCAN messages and says so ----
# Bug it catches: counting open items over the whole table every tick makes the live view slower as the bus grows; an old open
# question beyond the window is left out of the header and the header must carry the window so the count is not mistaken for all.
import runpy, sqlite3
g = runpy.run_path(os.path.join(os.environ["TESTS_DIR"], "..", "bin", "agentbus") if not os.environ.get("AGENTBUS_BIN") else os.environ["AGENTBUS_BIN"],
                   run_name="agentbus_dx")
g["watch_open"].__globals__["SCAN"] = 3
db = bus("window")
join(db, "alice")
old = post(db, "alice", "old question", to="*", kind="question")
for i in range(5):
    post(db, "alice", "note %d" % i)
recent = post(db, "alice", "recent question", to="*", kind="question")
con = sqlite3.connect(db)
o = g["watch_open"](con)
con.close()
check(o == {"alerts": 0, "questions": 1, "todos": 0, "window": 3}, "watch_open over a window of 3 newest: %s" % o)
check(jok(db, "watch")["open"] == {"alerts": 0, "questions": 2, "todos": 0, "window": None}, "a bus under the window counts everything")
print("PASS: watch counts the newest SCAN messages on a huge bus and reports the window")
PY
all_passed "All agent DX tests passed"
