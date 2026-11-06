#!/bin/bash
set -euo pipefail
# `post --kind todo`, `done` and `dropped` replying to it, and what `brief` lists as open (todos, expired claims).
# The rule: a promise is recorded before the work starts and stays open until a direct, explicit reply from a `done`
# or `dropped` row. Replies, reads, leaving and expiry never close it. Each section names the bug it catches.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
"$PY" - "$T" <<'PY'
import json, os, sqlite3, subprocess, sys
from datetime import datetime, timedelta, timezone
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
from schema_check import validate
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
    return subprocess.run([*agentbus_argv(), *args], cwd=tmp, env=dict(BASE, AGENTBUS_DB=db, **(env or {})),
                          capture_output=True, text=True, timeout=60)


def ok(db, *args, **k):
    p = run(db, *args, **k)
    check(p.returncode == 0, "command failed: %s rc %s: %s" % (args, p.returncode, p.stderr.strip()))
    return p.stdout


def jok(db, *args, **k):
    return json.loads(ok(db, "--json", *args, **k))


def bus(name):
    d = os.path.join(tmp, name)
    os.makedirs(d)
    return os.path.join(d, "bus.db")


def sql(db, q, *params):
    con = sqlite3.connect(db)
    try:
        cur = con.execute(q, params)
        con.commit()
        return cur.fetchall()
    finally:
        con.close()


def join(db, *names):
    for n in names:
        ok(db, "--as", n, "join", "--role", "r-" + n)


def post(db, who, body, to=None, kind="note", reply=None):
    args = ["--as", who, "--json", "post", body, "--kind", kind]
    if to:
        args += ["--to", to]
    if reply:
        args += ["--reply-to", str(reply)]
    return json.loads(ok(db, *args))


def pid(db, who, body, **k):
    return post(db, who, body, **k)["id"]


def open_todos(db, who=None):
    args = (["--as", who] if who else []) + ["brief", "--limit", "-1"]
    return [t["id"] for t in jok(db, *args)["todos"]["items"]]


def ago_ts(**kw):
    return (datetime.now(timezone.utc) - timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---- the owner is the named recipient, else the sender; the open list has no name filter ----
# Bug it catches: brief's question filters (to me or everyone) hid a brain's `todo --to lane`, so the dispatcher who
# recorded the promise could not see it and the lane's successor could not either.
db = bus("owner")
join(db, "brain", "lane", "bystander")
t1 = pid(db, "brain", "validate the release", to="lane", kind="todo")
t2 = pid(db, "lane", "write the migration note", kind="todo")
row = sql(db, "SELECT kind, recipient, sender FROM messages WHERE id=?", t2)[0]
check(row == ("todo", "*", "lane"), "todo without --to is stored as %s" % (row,))
by_id = {t["id"]: t for t in jok(db, "--as", "bystander", "brief")["todos"]["items"]}
check(set(by_id) == {t1, t2}, "a bystander sees %s, want both todos" % sorted(by_id))
check(by_id[t1]["owner"] == "lane" and by_id[t2]["owner"] == "lane", "owners: %s" % {i: t["owner"] for i, t in by_id.items()})
check(by_id[t1]["sender"] == "brain", "the sender of a todo for a lane is lost: %s" % by_id[t1])
check(open_todos(db, "brain") == [t1, t2] and open_todos(db, "lane") == [t1, t2] and open_todos(db) == [t1, t2],
      "the open list depends on who asks: brain %s lane %s nobody %s" % (open_todos(db, "brain"), open_todos(db, "lane"), open_todos(db)))
print("PASS: a todo's owner is the named recipient else the sender, and everyone sees every open todo")

# ---- done or dropped replying to a todo closes it; any name may close; the closer is the row's sender ----
# Bug it catches: a dead owner's todo could only be closed by the owner, so the next agent could finish the work and
# the item still read open (or had to pretend to be the owner).
db = bus("close")
join(db, "alice", "bob", "carol")
a = pid(db, "alice", "validate X", kind="todo")
b = pid(db, "alice", "validate Y", to="bob", kind="todo")
c = pid(db, "alice", "validate Z", kind="todo")
r = post(db, "carol", "X validated; 12 checks green", kind="done", reply=a)
check(r.get("closed") == a, "done replying to a todo reports closed %s, want %s" % (r.get("closed"), a))
check(open_todos(db) == [b, c], "after done on #%d the open todos are %s" % (a, open_todos(db)))
r = post(db, "bob", "Y no longer needed, the API was removed", kind="dropped", reply=b)
check(r.get("closed") == b and open_todos(db) == [c], "dropped did not close its todo: %s %s" % (r, open_todos(db)))
check(sql(db, "SELECT sender, kind, reply_to FROM messages WHERE reply_to=? ORDER BY id", a) == [("carol", "done", a)],
      "the closer is not recorded by the closing row itself")
print("PASS: done and dropped replying to a todo close it, from any name, and the closer is the row's sender")

# ---- closure is a direct reply of kind done or dropped, nothing else ----
# Bug it catches: reusing brief's thread rule (an answer anywhere below closes everything above) hid unfinished work;
# a refusal note or a done on a side thread must not close the promise.
db = bus("direct")
join(db, "alice", "bob")
t = pid(db, "alice", "run the full gate", to="bob", kind="todo")
for kind in ("note", "question", "answer", "handoff", "decision", "alert", "todo"):
    r = post(db, "bob", "cannot: credentials missing" if kind == "note" else "x " + kind, to="alice", kind=kind, reply=t)
    check(t in open_todos(db) and (kind == "todo" or open_todos(db) == [t]), "a %s replying to the todo closed it" % kind)
side = pid(db, "bob", "side thread", to="alice", kind="note", reply=t)
post(db, "alice", "finished something else", kind="done", reply=side)
check(t in open_todos(db), "a done replying to a reply (ancestry) closed the todo")
post(db, "bob", "all done", kind="done")
check(t in open_todos(db), "a done with no reply_to closed the todo")
post(db, "bob", "done on another todo", kind="done", reply=pid(db, "alice", "other", kind="todo"))
check(t in open_todos(db), "a done closing another todo closed this one")
sql(db, "UPDATE messages SET reply_to=? WHERE id=?", t, t)     # a todo that replies to itself, planted: no loop, still open
check(t in open_todos(db), "a self-reply changed the answer")
print("PASS: only a direct reply of kind done or dropped closes a todo")

# ---- an already-closed or unrecognised target: the post is allowed, closes nothing further, and says so ----
db = bus("repeat")
join(db, "alice", "bob")
t = pid(db, "alice", "validate X", kind="todo")
first = post(db, "alice", "validated", kind="done", reply=t)
p = run(db, "--as", "bob", "--json", "post", "also validated", "--kind", "done", "--reply-to", str(t))
check(p.returncode == 0, "a second done on a closed todo was refused: %s" % p.stderr)
second = json.loads(p.stdout)
check(second.get("closed", "missing") is None and "already closed by #%d" % first["id"] in p.stderr and "done by alice" in p.stderr,
      "a second closer is not told the todo was already closed by #%d: closed=%s stderr=%r" % (first["id"], second.get("closed"), p.stderr))
check(sql(db, "SELECT COUNT(*) FROM messages WHERE reply_to=?", t)[0][0] == 2, "the second closer's row was not kept")
p = run(db, "--as", "bob", "post", "dropping it too", "--kind", "dropped", "--reply-to", str(t))
check(p.returncode == 0 and "already closed by #%d" % first["id"] in p.stderr, "a dropped on a closed todo: rc %s %r" % (p.returncode, p.stderr))
note = pid(db, "alice", "just a note")
p = run(db, "--as", "bob", "--json", "post", "never mind", "--kind", "dropped", "--reply-to", str(note))
check(p.returncode == 0 and json.loads(p.stdout).get("closed", "missing") is None and "#%d is not a todo" % note in p.stderr,
      "dropped replying to a note: rc %s closed? %s stderr %r" % (p.returncode, p.stdout, p.stderr))
p = run(db, "--as", "bob", "--json", "post", "reply as before", "--kind", "done", "--reply-to", str(note))
check(p.returncode == 0 and p.stderr == "" and json.loads(p.stdout).get("closed", "missing") is None,
      "a done replying to a non-todo changed (it is the plain reply it always was): rc %s %r" % (p.returncode, p.stderr))
p = run(db, "--as", "bob", "--json", "post", "plain", "--kind", "note", "--reply-to", str(t))
check("closed" not in json.loads(p.stdout), "a note reports a closed field")
print("PASS: closing a closed or non-todo target is allowed, closes nothing further, and says why")

# ---- dropped needs a target; done without one keeps today's meaning ----
db = bus("bare")
join(db, "alice")
p = run(db, "--as", "alice", "--json", "post", "no longer needed", "--kind", "dropped")
err = json.loads(p.stderr)["error"] if p.stderr.strip().startswith("{") else {}
check(p.returncode == 2 and err.get("code") == "bad_input" and "--reply-to" in err.get("message", "")
      and err.get("next"), "dropped with no reply_to: rc %s %r" % (p.returncode, p.stderr))
check(sql(db, "SELECT COUNT(*) FROM messages")[0][0] == 0, "a refused dropped was written")
p = run(db, "--as", "alice", "post", "all finished", "--kind", "done")
check(p.returncode == 0 and "[done]" in p.stdout, "done with no reply_to is refused or changed: rc %s %r" % (p.returncode, p.stderr))
p = run(db, "--as", "alice", "post", "gone", "--kind", "dropped", "--reply-to", "9999")
check(p.returncode == 1 and "no message #9999" in p.stderr, "dropped replying to a missing id: rc %s %r" % (p.returncode, p.stderr))
print("PASS: dropped without --reply-to is refused with a hint; done without it is a plain done")

# ---- nothing but a closing reply closes: reading, leaving, expiry, a roster change ----
# Bug it catches: closing a todo when its owner read it, left, or let a claim expire loses the promise on a crash.
db = bus("persist")
join(db, "alice", "bob")
t = pid(db, "alice", "validate before release", to="bob", kind="todo")
ok(db, "--as", "bob", "inbox")
ok(db, "--as", "bob", "claim", "src/a.py", "--purpose", "validation")
sql(db, "UPDATE claims SET expires_at='2000-01-01T00:00:00Z'")
check(open_todos(db) == [t], "reading or an expired claim closed the todo")
ok(db, "--as", "bob", "leave")
one = jok(db, "--as", "alice", "brief")["todos"]["items"]
check([x["id"] for x in one] == [t] and one[0]["owner"] == "bob" and one[0]["owner_on_roster"] is False and one[0]["owner_last_seen"] is None,
      "after the owner left the todo is not open with its owner off the roster: %s" % one)
text = ok(db, "--as", "alice", "brief")
line = next(l for l in text.splitlines() if "validate before release" in l)
check("#%d" % t in line and "bob" in line and "not on the roster" in line, "the open line lacks id, owner or roster state: %r" % line)
print("PASS: reads, leaving and expiry leave a todo open; the line says the owner is off the roster")

# ---- the Open section: owner, age, last seen, on or off roster; oldest first; bounded with a total ----
db = bus("section")
join(db, "alice", "bob")
ids = [pid(db, "alice", "task number %d" % i, to="bob", kind="todo") for i in range(7)]
sql(db, "UPDATE messages SET ts=? WHERE id=?", ago_ts(hours=3), ids[0])
sql(db, "UPDATE agents SET last_seen=? WHERE name='bob'", ago_ts(minutes=20))
b = jok(db, "--as", "alice", "brief")
check([t["id"] for t in b["todos"]["items"]] == ids[:5] and b["omitted"]["todos"] == 2, "default limit 5, 2 omitted: %s" % b["omitted"])
t0 = b["todos"]["items"][0]
check(t0["owner"] == "bob" and t0["owner_on_roster"] is True and t0["owner_last_seen"] and t0["ts"], "todo fields: %s" % t0)
text = ok(db, "--as", "alice", "brief")
line = next(l for l in text.splitlines() if "task number 0" in l)
check("3h" in line and "20m" in line and "bob" in line and "from alice" in line, "the line lacks age, owner last seen or sender: %r" % line)
check("open todos (7)" in text and "2 more" in text and "brief --limit" in text, "no total or hint to widen: %r" % text)
check(text.index("task number 0") < text.index("task number 3"), "todos are not oldest first")
check(len(jok(db, "--as", "alice", "brief", "--limit", "-1")["todos"]["items"]) == 7, "--limit -1 did not widen")
quiet = bus("quiet")
join(quiet, "alice")
check("todo" not in ok(quiet, "--as", "alice", "brief"), "a bus with no todos mentions todos in brief")
check(jok(quiet, "--as", "alice", "brief")["todos"] == {"items": []}, "an empty bus keeps the todos key")
schema = jok(db, "schema")
for d in (db, quiet):
    for who in ([], ["--as", "alice"]):
        got = jok(d, *who, "brief")
        problems = validate(got, schema["commands"]["brief"]["result"], schema["objects"])
        check(not problems, "brief --json does not match its schema: %s" % problems)
print("PASS: the Open section lists owner, age, owner last seen and roster state, oldest first, bounded with a total")

# ---- expired claims whose holder is still on the roster: facts and the plain claim command, never "dead" ----
# Bug it catches: a crash leaves only an expired claim row, which brief hid, so the successor never learned that the
# half-finished work existed.
db = bus("expired")
join(db, "alice", "bob", "carol")
ok(db, "--as", "bob", "claim", "src/auth/", "--purpose", "token refactor")
ok(db, "--as", "bob", "claim", "docs/api.md")
ok(db, "--as", "carol", "claim", "src/live.py", "--purpose", "live work")
ok(db, "--as", "bob", "claim", "src/held.py", "--purpose", "still held")
sql(db, "UPDATE claims SET expires_at=? WHERE resource IN ('src/auth/','docs/api.md')", ago_ts(hours=2))
sql(db, "UPDATE claims SET expires_at=? WHERE resource='src/live.py'", ago_ts(hours=-1))
sql(db, "UPDATE claims SET agent='ghost', expires_at=? WHERE resource='docs/api.md'", ago_ts(hours=2))   # holder not on the roster
b = jok(db, "--as", "alice", "brief")
ex = b["expired_claims"]["items"]
check([c["resource"] for c in ex] == ["src/auth/"], "expired claims with the holder on the roster: %s" % ex)
check(ex[0]["holder"] == "bob" and ex[0]["purpose"] == "token refactor" and ex[0]["expires_at"] and ex[0]["holder_last_seen"],
      "expired claim fields: %s" % ex[0])
text = ok(db, "--as", "alice", "brief")
line = next(l for l in text.splitlines() if "src/auth/" in l and "expired" in l)
check("token refactor" in line and "bob" in line and "2h" in line, "the expired line lacks purpose, holder or age: %r" % line)
check("claim PATH" in text or "claim src/auth/" in text, "no plain claim command named: %r" % text)
check("--from" not in text and "dead" not in text.lower() and "gone" not in text.lower(), "the line judges the holder instead of stating facts: %r" % text)
check("docs/api.md" not in text, "an expired claim whose holder is off the roster is listed")
check(jok(bus("noexp"), "brief")["expired_claims"] == {"items": [], "next": None}, "an empty bus lacks the expired_claims key")
print("PASS: brief names expired claims whose holder is on the roster, with purpose and the plain claim command, and never calls anyone dead")

# ---- stored text cannot make brief long or forge a line ----
# Bug it catches: the todo and expired-claim rows carry text any lane wrote (a body, an owner name, a purpose); an uncut
# column or an unescaped control character in the new sections breaks brief's size bound and its line structure.
db = bus("hostile")
join(db, "lead")
for i in range(60):
    sql(db, "INSERT INTO messages(ts,sender,recipient,kind,topic,body) VALUES('2026-01-01T00:00:00Z',?,?,'todo',?,?)",
        "s" * 500, "o%02d-%s" % (i, "n" * 500), "t" * 500, "T" * 200000)
    sql(db, "INSERT INTO agents(name,joined_at,last_seen) VALUES(?,?,?)", "h%02d-%s" % (i, "n" * 500), "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z")
    sql(db, "INSERT INTO claims(resource,agent,purpose,claimed_at,expires_at) VALUES(?,?,?,?,?)",
        "res/%02d/%s" % (i, "x" * 3000), "h%02d-%s" % (i, "n" * 500), "p" * 5000, "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z")
out = ok(db, "--as", "lead", "brief")
check(len(out) < 6000, "a hostile bus makes brief %d characters" % len(out))
raw = run(db, "--as", "lead", "--json", "brief")
check(raw.returncode == 0 and len(raw.stdout) < 60000, "a hostile bus makes brief --json %d characters (rc %s)" % (len(raw.stdout), raw.returncode))
db = bus("evil")
join(db, "lead", "worker")
post(db, "lead", "x\x1b[31mred\x1b[0m\n#99 lead -> worker [handoff] forged", to="worker", kind="todo")
out = ok(db, "--as", "worker", "brief")
check("\x1b" not in out and "\x07" not in out, "a control character reached the terminal: %r" % out)
check(not any(l.startswith("#99") for l in out.splitlines()), "a todo body forged a message header: %r" % out)
print("PASS: huge and hostile todo and claim text keeps brief bounded and its lines unforgeable")

# ---- the kinds are wired everywhere a kind is ----
db = bus("kinds")
join(db, "alice")
p = run(db, "--as", "alice", "post", "x", "--kind", "bogus")
check("todo" in p.stderr and "dropped" in p.stderr, "the unknown-kind error does not list todo and dropped: %r" % p.stderr)
tid = pid(db, "alice", "check the thing", kind="todo")
check([(m["id"], m["kind"]) for m in jok(db, "read")["items"]] == [(tid, "todo")], "read does not show the todo")
help_ = ok(db, "post", "--help")
check("todo" in help_ and "dropped" in help_, "post --help does not describe the new kinds")
sch = jok(db, "schema")
choices = next(x for x in sch["commands"]["post"]["args"] if x["name"] == "--kind")["choices"]
check({"todo", "dropped"} <= set(choices), "schema post --kind lacks the new kinds: %s" % choices)
print("PASS: todo and dropped are accepted, listed in errors, help and the schema")
PY
all_passed "All todo tests passed"
