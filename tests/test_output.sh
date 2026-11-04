#!/bin/bash
set -euo pipefail
# Output discipline and context budget: what a command prints is small, readable and says how to get more.
# No hard wrap off a terminal, compact JSON off a terminal, ~ for the home folder, one time format, listing
# defaults of 20 and 50 with the exact next command, a 64 KB body cap, bodies cut at 2 KB in listings with
# read --id N for the rest, status that obeys --limit, and a schema an agent can read one command at a time.
# Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
export TZ=America/New_York
"$PY" - "$T" <<'PY'
import calendar, json, os, pty, fcntl, re, shlex, sqlite3, struct, subprocess, sys, termios, time
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
T = sys.argv[1]
BASE = {k: v for k, v in os.environ.items() if (not k.startswith("AGENTBUS_") or k == "AGENTBUS_TEST_NOW") and k != "COLUMNS"}
BASE["PYTHONDONTWRITEBYTECODE"] = "1"
n = [0]


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def new_bus(name):
    d = os.path.join(T, name)
    os.makedirs(d)
    return os.path.join(d, "bus.db")


def run(db, *args, env=None, stdin=None, cwd=None):
    e = dict(BASE, AGENTBUS_DB=db, **(env or {}))
    return subprocess.run([*agentbus_argv(), *args], env=e, input=stdin, cwd=cwd or T, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)


def ok(db, *args, **k):
    p = run(db, *args, **k)
    if p.returncode != 0:
        fail("%s exited %d: %s" % (args, p.returncode, p.stderr))
    return p.stdout


def js(db, *args, **k):
    return json.loads(ok(db, "--json", *args, **k))


def refused(db, *args, **k):
    p = run(db, "--json", *args, **k)
    if p.returncode == 0:
        fail("expected a refusal: %s" % (args,))
    return json.loads(p.stderr.splitlines()[0])["error"], p


def tty(db, *args, cols=50):
    """stdout and stderr on a pseudo-terminal `cols` wide; COLUMNS unset. Returns the output."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, cols, 0, 0))
    p = subprocess.Popen([*agentbus_argv(), *args], env=dict(BASE, AGENTBUS_DB=db), stdin=subprocess.DEVNULL,
                         stdout=slave, stderr=slave, cwd=T)
    os.close(slave)
    chunks = []
    while True:
        try:
            b = os.read(master, 65536)
        except OSError:
            break
        if not b:
            break
        chunks.append(b)
    p.wait(timeout=60)
    os.close(master)
    return b"".join(chunks).decode().replace("\r\n", "\n")


def plant(db, sql, rows):
    con = sqlite3.connect(db)
    con.executemany(sql, rows)
    con.commit()
    con.close()


# ---------------------------------------------------------------- 1. wrapping
db = new_bus("wrap")
ok(db, "--as", "a", "join")
words = " ".join("word%03d" % i for i in range(40))   # 320 characters, 40 words
ok(db, "--as", "a", "post", words)
out = ok(db, "read")
body = [l for l in out.splitlines() if "word000" in l]
if len(body) != 1 or "word039" not in body[0]:
    fail("piped output was wrapped at the terminal width: the 320-character body is not on one row: %r" % body[:2])
long_purpose = " ".join("purpose%02d" % i for i in range(30))
ok(db, "--as", "a", "claim", "src/x.py", "--purpose", long_purpose)
ok(db, "--as", "b", "join")
p = run(db, "--as", "b", "claim", "src/x.py")
if p.returncode != 1 or len(p.stderr.splitlines()) != 1 or "purpose29" not in p.stderr:
    fail("a conflict message was wrapped when piped: %r" % p.stderr)
print("PASS: output to a pipe or file is never hard-wrapped")

out = ok(db, "read", env={"COLUMNS": "40"})
rows = out.splitlines()
if max(len(r) for r in rows) > 40 or len(rows) < 8:
    fail("an explicit COLUMNS=40 did not wrap: %r" % out)
tokens = {t for r in rows for t in r.split()}
if not all("word%03d" % i in tokens for i in range(40)):
    fail("wrapping cut inside a token that fits a row: %r" % out)
print("PASS: an explicit COLUMNS still wraps, and never inside a word that fits a row")

out = tty(db, "read", cols=50)
rows = out.splitlines()
if max(len(r) for r in rows) > 50 or sum("word" in r for r in rows) < 5:
    fail("on a terminal 50 columns wide the body was not wrapped to 50: %r" % out)
if not all(r.startswith("  ") or r.startswith("#") for r in rows if r):
    fail("a wrapped row starts at column 0 with body text: %r" % out)
if not all(("word%03d" % i) in out.replace("\n  ", " ") for i in range(40)):
    fail("a terminal's wrapping lost or cut a word: %r" % out)
print("PASS: on a terminal, wrapped at its width, rows indented, no word cut")

# ---------------------------------------------------------------- 2. compact JSON
for args in (("status",), ("who",), ("read",), ("claims",), ("ctx", "get"), ("log", "show"), ("schema", "--index"), ("goal",)):
    raw = ok(db, "--json", *args)
    if raw.count("\n") != 1 or raw != json.dumps(json.loads(raw), separators=(",", ":")) + "\n":
        fail("--json %s is not compact when piped: %r" % (" ".join(args), raw[:120]))
print("PASS: --json is compact (no indent, no spaces) when stdout is a pipe")
raw = tty(db, "--json", "who")
if not raw.startswith("{\n  \"contract\": 1,\n  \"items\": [\n"):
    fail("--json on a terminal is not indented: %r" % raw[:80])
if json.loads(raw) != json.loads(ok(db, "--json", "who")):
    fail("the indented and compact JSON hold different values")
print("PASS: --json is indented on a terminal, with the same values")
raw = ok(db, "--json", "setup", "codex", "--dry-run", env={"HOME": os.path.join(T, "sethome")})
if raw.count("\n") != 1:
    fail("setup --json is not compact when piped: %r" % raw[:120])

# ---------------------------------------------------------------- 3. ~ for the home folder
home = os.path.realpath(os.path.join(T, "home"))
app = os.path.join(home, "app")
os.makedirs(app)
subprocess.run(["git", "init", "-q", app], check=True)
e = dict(BASE, HOME=home)
e.pop("AGENTBUS_DB", None)


def at_app(*args):
    return subprocess.run([*agentbus_argv(), *args], env=e, cwd=app, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)


p = at_app("init")
if p.returncode != 0 or "installed agentbus" not in p.stdout or home in p.stdout or "into ~/app/.agentbus/" not in p.stdout:
    fail("init shows the home folder in full: %r" % p.stdout)
if "next: cd ~/app" not in p.stdout:
    fail("init's next step shows the home folder in full: %r" % p.stdout)
p = at_app("--as", "a", "join")
if "joined as a on ~/app/.agentbus/bus.db" not in p.stdout:
    fail("join shows the home folder in full: %r" % p.stdout)
if "== bus ~/app/.agentbus/bus.db" not in at_app("status").stdout:
    fail("status shows the home folder in full")
if not re.search(r"^  0  ~/app  bus\.db exists", at_app("buses").stdout, re.M):
    fail("buses shows the home folder in full: %r" % at_app("buses").stdout)
j = json.loads(at_app("--as", "b", "--json", "join").stdout)
if not j["bus"].startswith(home + "/") or not j["bus"].endswith("/app/.agentbus/bus.db"):
    fail("--json must keep the whole path: %r" % j["bus"])
print("PASS: human paths show ~ for the home folder; --json keeps the whole path")

# HOME is a link (macOS's /var is one): paths agentbus resolves still show ~, whichever spelling of the home folder they have
real2 = os.path.realpath(os.path.join(T, "realhome"))
os.makedirs(os.path.join(real2, "app"))
subprocess.run(["git", "init", "-q", os.path.join(real2, "app")], check=True)
link = os.path.join(T, "linkhome")
os.symlink(real2, link)
e2 = dict(BASE, HOME=link)
e2.pop("AGENTBUS_DB", None)
def via_link(*args):
    return subprocess.run([*agentbus_argv(), *args], env=e2, cwd=os.path.join(link, "app"), text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
p = via_link("init")
if "into ~/app/.agentbus/" not in p.stdout or real2 in p.stdout or link in p.stdout:
    fail("init does not show ~ when HOME is a link: %r" % p.stdout)
p = via_link("--as", "c", "join")
if "joined as c on ~/app/.agentbus/bus.db" not in p.stdout:
    fail("join does not show ~ when HOME is a link: %r" % p.stdout)
if "== bus ~/app/.agentbus/bus.db" not in via_link("status").stdout:
    fail("status does not show ~ when HOME is a link")
print("PASS: ~ is shown when HOME is a symlink to the folder paths resolve to")

# ---------------------------------------------------------------- 4. one human time format
db = new_bus("time")
ok(db, "--as", "a", "join")
ok(db, "--as", "b", "join")
plant(db, "INSERT INTO context(key,value,updated_by,updated_at) VALUES(?,?,?,?)", [("old", "v", "a", "2026-01-05T15:04:00Z")])
plant(db, "INSERT INTO context_history(key,value,updated_by,updated_at) VALUES(?,?,?,?)", [("old", "v", "a", "2026-01-05T15:04:00Z")])
plant(db, "INSERT INTO log(ts,agent,action,detail) VALUES(?,?,?,?)", [("2026-01-05T15:04:00Z", "a", "note", "planted")])
plant(db, "INSERT INTO messages(ts,sender,recipient,kind,topic,body,reply_to) VALUES(?,?,?,?,?,?,?)",
      [("2026-01-05T15:04:00Z", "b", "a", "note", None, "old news", None)])
ok(db, "--as", "a", "goal", "ship it")
plant(db, "UPDATE context SET updated_at=? WHERE key='goal'", [("2026-01-05T15:04:00Z",)])
checks = {
    "ctx get": (("ctx", "get"), r"old = v   \(a, Jan 5 10:04\)"),
    "ctx history": (("ctx", "history", "old"), r"^  Jan 5 10:04 a: v$"),
    "log show": (("log", "show"), r"^  Jan 5 10:04 +a +note +planted$"),
    "read": (("read",), r"^#1 b -> a \[note\] · Jan 5 10:04$"),
    "goal": (("goal",), r"set by a at Jan 5 10:04"),
}
for name, (args, pattern) in checks.items():
    out = ok(db, *args)
    if not re.search(pattern, out, re.M):
        fail("%s does not use `Mon D HH:MM` for another day (wanted %s): %r" % (name, pattern, out))
if re.search(r"\d{4}-\d\d-\d\dT", ok(db, "ctx", "get") + ok(db, "log", "show", "--limit", "1") + ok(db, "goal")):
    fail("an ISO time is left in human output")
claimed = ok(db, "--as", "a", "claim", "src/a.py", "--purpose", "edit")
# AGENTBUS_TEST_NOW (a test-only hook) starts the tool's clock at a given UTC time, so this runs at any hour: "now" is
# that moment, and an expiry 2 hours on is HH:MM if it is still today (local) and `Mon D HH:MM` if it is tomorrow.
pin = os.environ.get("AGENTBUS_TEST_NOW")
now = calendar.timegm(time.strptime(pin, "%Y-%m-%dT%H:%M:%SZ")) if pin else time.time()


def human(t):
    """The expected text of the time t (epoch seconds) relative to now: the format the tool documents."""
    local, today = time.localtime(t), time.localtime(now)
    stamp = time.strftime("%H:%M", local)
    return stamp if local[:3] == today[:3] else "%s %d %s" % (time.strftime("%b", local), local.tm_mday, stamp)


expected_until = {human(now + 7200 + d) for d in (-90, -30, 0, 30, 90)}   # the clock runs a little between commands
m = re.fullmatch(r"claimed src/a\.py for 2h \(until ((?:[A-Z][a-z]{2} \d{1,2} )?\d\d:\d\d)\)\n", claimed)
if not m or m.group(1) not in expected_until:
    fail("claim does not say `for 2h (until HH:MM)` (or with the date when tomorrow, wanted one of %s): %r" % (sorted(expected_until), claimed))
listed = ok(db, "claims")
if not re.search(r"^  src/a\.py +a +for 2h \(until " + re.escape(m.group(1)) + r"\) +edit$", listed, re.M):
    fail("claims does not say `for 2h (until HH:MM)`: %r" % listed)
day = ok(db, "--as", "a", "claim", "src/b.py", "--ttl-min", "1500")
if not re.search(r"claimed src/b\.py for 1d 1h \(until [A-Z][a-z]{2} \d{1,2} \d\d:\d\d\)", day):
    fail("a claim past today does not give the day: %r" % day)
# the same claim at fixed moments (TZ is America/New_York, EST in November): 23:30 local puts the expiry on the next
# day, so it carries the date; 10:00 local keeps it today; a malformed AGENTBUS_TEST_NOW is ignored
for pinned, want in (("2026-11-04T04:30:00Z", "for 2h (until Nov 4 01:30)"), ("2026-11-04T15:00:00Z", "for 2h (until 12:00)"),
                     ("2026-11-04T04:59:00Z", "for 2h (until Nov 4 01:59)")):
    pdb = new_bus("pin" + pinned[11:16].replace(":", ""))
    ok(pdb, "--as", "p", "join", env={"AGENTBUS_TEST_NOW": pinned})
    got = ok(pdb, "--as", "p", "claim", "x", env={"AGENTBUS_TEST_NOW": pinned})
    if got != "claimed x " + want + "\n":
        fail("with the clock at %s the claim says %r, wanted %r" % (pinned, got, want))
    if "(until " + want[len("for 2h (until "):-1] + ")" not in ok(pdb, "claims", env={"AGENTBUS_TEST_NOW": pinned}):
        fail("claims at %s lost the expiry" % pinned)
pdb = new_bus("pinbad")
ok(pdb, "--as", "p", "join")
if not re.fullmatch(r"claimed x for 2h \(until [^)]+\)\n", ok(pdb, "--as", "p", "claim", "x", env={"AGENTBUS_TEST_NOW": "yesterday"})):
    fail("a malformed AGENTBUS_TEST_NOW must change nothing")
error, p = refused(db, "--as", "b", "claim", "src/a.py")
if error["code"] != "claim_conflict" or not re.search(r"claimed by a until " + re.escape(m.group(1)) + r" \(purpose: \"edit\"\)", error["message"]):
    fail("the conflict message does not use the same time as the claim, %s: %r" % (m.group(1), error["message"]))
if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", error["expires_at"]):
    fail("the error field expires_at is not the stored ISO time: %r" % error)
doc = js(db, "ctx", "get", "old")
if doc["updated_at"] != "2026-01-05T15:04:00Z" or js(db, "claims")["items"][0]["expires_at"][-1] != "Z":
    fail("--json no longer holds the ISO UTC time")
print("PASS: local HH:MM today, `Mon D HH:MM` otherwise, `for 2h (until 13:47)` for a claim; --json keeps ISO UTC")

# ---------------------------------------------------------------- 5. listing defaults and the next command
db = new_bus("limits")
ok(db, "--as", "a", "join")
plant(db, "INSERT INTO agents(name,tool,model,cwd,branch,role,joined_at,last_seen) VALUES(?,?,?,?,?,?,?,?)",
      [("lane%03d" % i, None, None, "/", None, None, "2026-01-05T15:04:00Z", "2026-01-05T15:04:00Z") for i in range(70)])
plant(db, "INSERT INTO messages(ts,sender,recipient,kind,topic,body,reply_to) VALUES(?,?,?,?,?,?,?)",
      [("2026-01-05T15:%02d:00Z" % (i % 60), "lane001", "a" if i % 2 else "*", "note", "t" if i % 3 == 0 else None, "m%03d" % i, None)
       for i in range(1, 121)])
plant(db, "INSERT INTO context(key,value,updated_by,updated_at) VALUES(?,?,?,?)",
      [("k%03d" % i, "v", "a", "2026-01-05T15:04:00Z") for i in range(60)])
plant(db, "INSERT INTO log(ts,agent,action,detail) VALUES(?,?,?,?)", [("2026-01-05T15:04:00Z", "a", "note", "l%d" % i) for i in range(60)])
plant(db, "INSERT INTO claims(resource,agent,purpose,claimed_at,expires_at) VALUES(?,?,?,?,?)",
      [("dir/f%02d" % i, "lane%03d" % i, None, "2026-01-05T15:04:00Z", "2099-01-05T15:04:00Z") for i in range(55)])
for args, want, more in ((("who",), 50, True), (("claims",), 50, True), (("ctx", "get"), 50, True), (("log", "show"), 50, True),
                         (("read",), 50, True), (("--as", "a", "inbox", "--peek"), 20, True)):
    got = js(db, *args)
    if len(got["items"]) != want or got["has_more"] is not more:
        fail("%s returned %d rows (wanted %d, has_more %s)" % (" ".join(args), len(got["items"]), want, got["has_more"]))
st = js(db, "status")
if [len(st[k]) for k in ("agents", "context", "claims", "messages")] != [20, 20, 20, 20]:
    fail("status sections are not 20 rows each: %r" % {k: len(st[k]) for k in ("agents", "context", "claims", "messages")})
if st["omitted"] != {"agents": 51, "context": 40, "claims": 35, "messages": 100}:
    fail("status omitted counts are wrong: %r" % st["omitted"])
st = js(db, "status", "--limit", "3")
if [len(st[k]) for k in ("agents", "context", "claims", "messages")] != [3, 3, 3, 3] or st["omitted"]["messages"] != 117:
    fail("status --limit 3 does not apply to messages: %r" % st["omitted"])
if len(js(db, "status", "--limit", "-1")["messages"]) != 120:
    fail("status --limit -1 is not every message")
print("PASS: 20 for the inbox and each status section (messages too), 50 for every other listing")


def follow(db, text, *prefix):
    """The `next:` line of a text listing, run as written (agentbus replaced by the CLI): its stdout."""
    lines = [l.strip() for l in text.splitlines() if l.strip().startswith("next: ")]
    if len(lines) != 1:
        fail("a cut listing must print exactly one next: line, got %r in %r" % (lines, text[-300:]))
    words = shlex.split(lines[0][len("next: "):])
    if words[0] != "agentbus":
        fail("the next command does not start with agentbus: %r" % lines[0])
    return lines[0], ok(db, *words[1:])


def ids(text):
    return [int(x) for x in re.findall(r"^#(\d+) ", text, re.M)]


first = ok(db, "read", "--limit", "5")
line, nxt = follow(db, first)
if "... 115 earlier" not in first or "agentbus read --before v1." not in line or "--limit 5" not in line:
    fail("read's hint is wrong: %r" % first)
if ids(first) != [116, 117, 118, 119, 120] or ids(nxt) != [111, 112, 113, 114, 115]:
    fail("read's next command did not continue back from the page: %r %r" % (ids(first), ids(nxt)))
t = ok(db, "read", "--topic", "t", "--limit", "3")
line, nxt = follow(db, t)
if "--topic t" not in line or not ids(nxt) or ids(nxt)[-1] >= ids(t)[0]:
    fail("read --topic's next command must keep the topic (a cursor is bound to it): %r" % line)
fwd = ok(db, "read", "--since", "10", "--limit", "4")
line, nxt = follow(db, fwd)
if "--since 14" not in line or ids(nxt)[0] != 15:
    fail("read --since's next command: %r" % line)
for cmd, wantline in ((("who",), "agentbus who --limit "), (("claims",), "agentbus claims --limit "), (("ctx", "get"), "agentbus ctx get --limit ")):
    text = ok(db, *cmd)
    line, more = follow(db, text)
    if not line.startswith("next: " + wantline) or len([l for l in more.splitlines() if l.startswith("  ")]) <= 50:
        fail("%s hint: %r" % (cmd, line))
text = ok(db, "log", "show", "--limit", "5")
line, nxt = follow(db, text)
rows_a, rows_b = [l for l in text.splitlines() if " note " in l], [l for l in nxt.splitlines() if " note " in l]
if "agentbus log show --before v1." not in line or len(rows_a) != 5 or len(rows_b) != 5 or set(rows_a) & set(rows_b):
    fail("log show hint: %r" % line)
plant(db, "INSERT INTO context_history(key,value,updated_by,updated_at) VALUES(?,?,?,?)", [("h", "v%d" % i, "a", "2026-01-05T15:04:00Z") for i in range(10)])
first = ok(db, "ctx", "history", "h", "--limit", "3")
line, nxt = follow(db, first)
vals = lambda t: re.findall(r"a: (v\d)$", t, re.M)
if "agentbus ctx history h --before v1." not in line or vals(first) != ["v7", "v8", "v9"] or vals(nxt) != ["v4", "v5", "v6"]:
    fail("ctx history hint: %r" % line)
# inbox: consuming continues with the same command; peeking continues with the cursor and never says "run inbox again"
peek = ok(db, "--as", "a", "inbox", "--peek", "--limit", "5")
line, nxt = follow(db, peek)
if "run inbox again" in peek or "agentbus --as a inbox --peek --after v1." not in line or ids(nxt)[0] <= ids(peek)[-1]:
    fail("inbox --peek's hint is wrong: %r" % peek[-300:])
cons = ok(db, "--as", "a", "inbox", "--limit", "5")
line, nxt = follow(db, cons)
if line != "next: agentbus --as a inbox --limit 5" or ids(nxt)[0] <= ids(cons)[-1]:
    fail("inbox's hint is wrong: %r" % line)
text = ok(db, "status")
hints = [l.strip() for l in text.splitlines() if l.strip().startswith("next: ")]
if len(hints) != 4 or not any("agentbus read --before v1." in h for h in hints) or not any("agentbus who --limit 71" in h for h in hints):
    fail("status needs a next command under each cut section: %r" % hints)
# the longest ordinary ones fit an 80-column row, so a terminal never has to break the command
for text in (first, peek, cons):
    for l in text.splitlines():
        if l.startswith("  next: ") and len(l) > 80:
            fail("a next: line is %d columns, wider than 80: %r" % (len(l), l))
print("PASS: every cut listing prints the exact next command, it works as written, and it fits 80 columns")

# ---------------------------------------------------------------- 6. body cap, cut bodies, read --id
db = new_bus("bodies")
ok(db, "--as", "a", "join")
ok(db, "--as", "b", "join")
big = "z" * 65537
error, p = refused(db, "--as", "a", "post", "-", stdin=big)
if error["code"] != "bad_input" or error.get("field") != "body" or p.returncode != 2 or "64 KB" not in error["message"]:
    fail("a body over 64 KB was not refused as bad_input field body: %r rc %d" % (error, p.returncode))
if js(db, "read")["items"]:
    fail("a refused body was stored")
error, p = refused(db, "--as", "a", "post", big)
if error.get("field") != "body":
    fail("a body over 64 KB on the command line was not refused: %r" % error)
for args, field in ((("ctx", "set", "k", "-"), "value"), (("log", "add", "x", "-"), "detail"), (("goal", "-"), "text")):
    error, p = refused(db, "--as", "a", *args, stdin=big)
    if error["code"] != "bad_input" or error.get("field") != field:
        fail("%s over 64 KB: %r" % (args[0], error))
ok(db, "--as", "a", "post", "-", stdin="y" * 65536)
if len(js(db, "read", "--id", "1")["body"]) != 65536:
    fail("a body of exactly 64 KB must be accepted whole")
text = "".join(("line %04d " % i) + "w" * 40 + "\n" for i in range(100))   # 5 KB
ok(db, "--as", "a", "post", "-", "--to", "b", "--topic", "long", stdin=text)
ok(db, "--as", "a", "post", "short one", "--to", "b")
mid = 2
for listing in (("read",), ("--as", "b", "inbox", "--peek"), ("status",)):
    items = js(db, *listing)
    items = items["items"] if "items" in items else items["messages"]
    long, short = [m for m in items if m["id"] == mid][0], [m for m in items if m["id"] == mid + 1][0]
    if len(long["body"].encode()) != 2048 or long.get("body_truncated") is not True:
        fail("%s did not cut a 5 KB body to 2048 bytes with body_truncated true: %d" % (listing[-1], len(long["body"])))
    if "body_truncated" in short or short["body"] != "short one":
        fail("%s marked or cut a short body: %r" % (listing[-1], short))
whole = js(db, "read", "--id", str(mid))
if whole["body"] != text.strip() or "body_truncated" in whole or whole["id"] != mid or set(whole) != {"contract", "id", "ts", "sender", "recipient", "kind", "topic", "body", "reply_to"}:
    fail("read --id N did not return the whole message as a Message: %r" % list(whole))
shown = ok(db, "read", "--limit", "2")
if "  ... cut at 2 KB. Full text: agentbus read --id %d\n" % mid not in shown or "line 0099" in shown:
    fail("a cut body in text mode does not name read --id N: %r" % shown[-300:])
if "line 0099" not in ok(db, "read", "--id", str(mid)) or "cut at 2 KB" in ok(db, "read", "--id", str(mid)):
    fail("read --id N in text must show the whole body")
euro = "€" * 2000   # 3 bytes each: the cut falls inside a character
ok(db, "--as", "a", "post", "-", stdin=euro)
cut = [m for m in js(db, "read")["items"] if m["body"].startswith("€")][0]
if cut["body_truncated"] is not True or len(cut["body"].encode()) > 2048 or len(cut["body"].encode()) < 2045 or set(cut["body"]) != {"€"}:
    fail("a cut inside a multi-byte character must end on a character boundary: %d bytes" % len(cut["body"].encode()))
error, p = refused(db, "read", "--id", "999")
if error["code"] != "no_message" or p.returncode != 1:
    fail("read --id of a missing message: %r" % error)
for extra in (("--topic", "long"), ("--since", "1"), ("--before", "v1.x")):
    error, p = refused(db, "read", "--id", "1", *extra)
    if error["code"] != "bad_input":
        fail("read --id with %s must be refused: %r" % (extra[0], error))
print("PASS: bodies over 64 KB are refused; listings cut at 2 KB with body_truncated; read --id N has it all")

# ---------------------------------------------------------------- 7. status in text
db = new_bus("status")
ok(db, "--as", "a", "join")
ok(db, "--as", "a", "ctx", "set", "plan", "-", stdin="first line of the plan\nsecond line\nthird line")
ok(db, "--as", "a", "ctx", "set", "wide", "w" * 300)
ok(db, "--as", "a", "ctx", "set", "small", "tiny")
text = ok(db, "status")
rows = {l.split(" = ")[0].strip(): l for l in text.splitlines() if " = " in l}
if not rows["plan"].startswith("  plan = first line of the plan...   (a, ") or "second" in text or "\\x0a" in text:
    fail("status must cut a multi-line fact to its first line: %r" % rows["plan"])
if not re.fullmatch(r"  wide = w{80}\.\.\.   \(a, \d\d:\d\d\)", rows["wide"]):
    fail("status must cut a long fact to 80 characters: %r" % rows["wide"])
if not re.fullmatch(r"  small = tiny   \(a, \d\d:\d\d\)", rows["small"]):
    fail("status must show a short fact whole: %r" % rows["small"])
if ok(db, "ctx", "get", "wide").strip() != "w" * 300:
    fail("ctx get KEY must show the whole value")
full = {f["key"]: f["value"] for f in js(db, "status")["context"]}
if full["plan"] != "first line of the plan\nsecond line\nthird line" or len(full["wide"]) != 300:
    fail("status --json must keep every fact value whole")
print("PASS: status text cuts a fact to one line; ctx get KEY and --json keep it whole")

# ---------------------------------------------------------------- 8. schema one command at a time, and the index
whole = js(db, "schema")
if "global_args" not in whole or [g["name"] for g in whole["global_args"]] != ["--as", "--json", "--up"]:
    fail("schema --json must carry global_args: %r" % list(whole))
one = js(db, "schema", "post")
if list(one["commands"]) != ["post"] or "Agent" in one["objects"] or "claim_conflict" in one["errors"] or "no_message" not in one["errors"]:
    fail("schema post is not trimmed to post: %r" % {k: list(v) for k, v in one.items() if isinstance(v, dict)})
if len(json.dumps(one, separators=(",", ":"))) > 10000 or len(json.dumps(whole, separators=(",", ":"))) < 30000:   # post carries the request id, the warning and the roster error since dx-id: 8.5 KB of a 54 KB schema
    fail("schema post should be a fraction of the full schema: %d vs %d" % (len(json.dumps(one)), len(json.dumps(whole))))
many = js(db, "schema", "ctx")
if set(many["commands"]) != {"ctx set", "ctx get", "ctx history"} or "Fact" not in many["objects"] or "FactVersion" not in many["objects"]:
    fail("schema ctx must hold the three ctx commands and the objects they use: %r" % list(many["objects"]))
index_raw = ok(db, "--json", "schema", "--index")
index = json.loads(index_raw)
if len(index_raw) >= 3072:
    fail("schema --index is %d bytes, not under 3 KB" % len(index_raw))
if set(index["commands"]) != set(whole["commands"]) or index["global_args"] != ["--as", "--json", "--up"]:
    fail("schema --index does not list every command")
for name, entry in index["commands"].items():
    if entry["args"] != [a["name"] for a in whole["commands"][name]["args"]]:
        fail("schema --index args differ for %s" % name)
    if any(e not in whole["commands"][name]["errors"] for e in entry["errors"]) or not set(index["common_errors"]) <= set(whole["errors"]):
        fail("schema --index names an error %s does not have" % name)
if index["commands"]["post"]["errors"] != ["no_message", "not_on_roster", "request_id_reused"]:
    fail("schema --index must keep a command's own error codes: %r" % index["commands"]["post"])
text = ok(db, "schema", "--index")
if "  post  body --to --kind --topic --reply-to --request-id  errors: no_message not_on_roster request_id_reused" not in text:
    fail("schema --index in text: %r" % text[:300])
error, p = refused(db, "schema", "--index", "post")
if error["code"] != "bad_input":
    fail("--index with a COMMAND must be refused")
print("PASS: schema COMMAND is trimmed to that command; schema --index is under 3 KB; global_args is in the schema")
PY
all_passed "All output tests passed"
