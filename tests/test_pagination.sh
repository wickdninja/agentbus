#!/bin/bash
set -euo pipefail
# Listings and completeness (WS07): the envelope, what has_more and next mean, and that a reader can
# always learn about rows it did not get.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
"$PY" - "$BIN" "$T" <<'PY'
import base64, json, os, sqlite3, subprocess, sys
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
bin_, tmp = sys.argv[1:]
BASE = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
BASE.update(COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1", HOME=tmp)
count = [0]

def fresh(name):
    d = os.path.join(tmp, name); os.makedirs(d)
    return os.path.join(d, "bus.db")

def run(db, *args):
    return subprocess.run([*agentbus_argv(), *args], cwd=tmp, env=dict(BASE, AGENTBUS_DB=db), capture_output=True, text=True, timeout=60)

def ok(db, *args):
    p = run(db, "--json", *args)
    assert p.returncode == 0, (args, p.stderr)
    return json.loads(p.stdout)

def usage_error(db, *args):
    p = run(db, "--json", *args)
    assert p.returncode == 2 and p.stdout == "", (args, p.returncode, p.stdout, p.stderr)
    e = json.loads(p.stderr)["error"]
    assert e["code"] == "bad_input", e
    return e

def shape(r, items=None):
    assert set(r) == {"v", "items", "has_more", "next"} and r["v"] == 1, r
    assert isinstance(r["items"], list) and isinstance(r["has_more"], bool) and (r["next"] is None or isinstance(r["next"], str)), r
    return r

def ids(r):
    return [x["id"] for x in r["items"]]

# ---- every listing is an envelope ----
db = fresh("env")
ok(db, "--as", "a", "join"); ok(db, "--as", "b", "join")
ok(db, "--as", "a", "post", "hi", "--to", "b"); ok(db, "--as", "a", "ctx", "set", "k", "v"); ok(db, "--as", "a", "claim", "x")
for args in (("who",), ("--as", "b", "inbox"), ("read",), ("claims",), ("ctx", "get"), ("ctx", "history", "k"), ("log", "show"), ("buses",)):
    r = shape(ok(db, *args)); assert r["items"] and r["has_more"] is False and r["next"] is None, (args, r)
assert shape(ok(db, "claims", "--stale"))["items"] == []
single = ok(db, "ctx", "get", "k")
assert single["key"] == "k" and "items" not in single, single
print("PASS: every listing returns {v, items, has_more, next}; single objects keep their shape")

# ---- inbox --limit 0: an empty page is not an empty inbox ----
db = fresh("inbox0")
ok(db, "--as", "a", "join"); ok(db, "--as", "b", "join")
for i in range(3):
    ok(db, "--as", "a", "post", "m%d" % i, "--to", "b")
r = shape(ok(db, "--as", "b", "inbox", "--limit", "0"))
assert r["items"] == [] and r["has_more"] is True, r
assert len(ok(db, "--as", "b", "inbox", "--peek")["items"]) == 3, "limit 0 consumed nothing"
print("PASS: inbox --limit 0 --json returns items [] with has_more true while unread remain")

# ---- who, claims, ctx get: has_more, no cursor, the v0.1.0 order ----
db = fresh("flat")
for i in range(7):
    ok(db, "--as", "n%d" % i, "join")
    ok(db, "--as", "n%d" % i, "ctx", "set", "key%d" % (6 - i), "v")
    ok(db, "--as", "n%d" % i, "claim", "res%d" % (6 - i))
con = sqlite3.connect(db)
for i in range(7):  # distinct last_seen, newest is n6
    con.execute("UPDATE agents SET last_seen=? WHERE name=?", ("2026-01-01T00:00:%02dZ" % i, "n%d" % i))
con.commit(); con.close()
r = shape(ok(db, "who", "--limit", "2"))
assert [x["name"] for x in r["items"]] == ["n6", "n5"] and r["has_more"] is True and r["next"] is None, r
r = shape(ok(db, "claims", "--limit", "2"))
assert [x["resource"] for x in r["items"]] == ["res0", "res1"] and r["has_more"] is True and r["next"] is None, r
r = shape(ok(db, "ctx", "get", "--limit", "2"))
assert [x["key"] for x in r["items"]] == ["key0", "key1"] and r["has_more"] is True and r["next"] is None, r
for args in (("who",), ("claims",), ("ctx", "get")):
    assert shape(ok(db, *args, "--limit", "7"))["has_more"] is False, args
    assert shape(ok(db, *args, "--limit", "-1"))["has_more"] is False, args
print("PASS: who, claims and ctx get with limit 2 over 7 rows report has_more true, next null, in the v0.1.0 order")

# ---- read, log show, ctx history: --before walks back over every row exactly once ----
db = fresh("walk")
ok(db, "--as", "a", "join")
for i in range(10):
    ok(db, "--as", "a", "post", "m%d" % i, "--topic", "t" if i % 2 == 0 else "u")
    ok(db, "--as", "a", "ctx", "set", "k", "v%d" % i)
def walk(*cmd, limit=3, inject=None):
    pages, seen, cur, n = [], [], None, 0
    while True:
        args = [*cmd, "--limit", str(limit)] + (["--before", cur] if cur else [])
        r = shape(ok(db, *args))
        pages.append(r); seen.extend(ids(r))
        n += 1
        if n == 1 and inject:
            inject()   # a row lands between the first and second page
        if not r["has_more"]:
            assert r["next"] is None, r
            return pages, seen
        assert r["next"].startswith("v1."), r
        assert ids(r) == sorted(ids(r)), ("each page is shown by id ascending", ids(r))
        cur = r["next"]
for name, cmd, post in (("read", ("read",), lambda: ok(db, "--as", "a", "post", "late")),
                        ("ctx history", ("ctx", "history", "k"), lambda: ok(db, "--as", "a", "ctx", "set", "k", "late")),
                        ("log show", ("log", "show"), lambda: ok(db, "--as", "a", "log", "add", "late", "x"))):
    total = len(ids(shape(ok(db, *cmd, "--limit", "-1"))))
    pages, seen = walk(*cmd, inject=post)
    assert len(seen) == len(set(seen)), (name, "a row repeated", seen)
    all_old = set(ids(shape(ok(db, *cmd, "--limit", "-1")))) - set(seen)
    assert len(all_old) == 1, (name, "only the row inserted mid-walk may be missing", all_old)
    assert len(seen) == total, (name, len(seen), total)
    # pages came newest-first; together they cover the rows that existed when the walk started, once each
    assert [min(ids(p)) for p in pages] == sorted([min(ids(p)) for p in pages], reverse=True), name
read_topic = shape(ok(db, "read", "--topic", "t", "--limit", "2"))
assert read_topic["has_more"] is True
topic_pages, topic_seen = walk("read", "--topic", "t", limit=2)
assert len(topic_seen) == len(set(topic_seen)) == 5, topic_seen
print("PASS: read, log show and ctx history --before walk back over every row exactly once; a row inserted between pages is neither skipped nor repeated")

# ---- inbox: consuming pages, and --peek --after walking forward ----
db = fresh("inbox")
ok(db, "--as", "a", "join"); ok(db, "--as", "b", "join")
for i in range(7):
    ok(db, "--as", "a", "post", "m%d" % i, "--to", "b")
got, pages = [], 0
while True:
    r = shape(ok(db, "--as", "b", "inbox", "--limit", "3"))
    assert r["next"] is None, "a consuming inbox has no cursor"
    got.extend(ids(r)); pages += 1
    if not r["has_more"]:
        break
assert pages == 3 and len(got) == 7 and got == sorted(got) and len(set(got)) == 7, (pages, got)
assert shape(ok(db, "--as", "b", "inbox"))["items"] == []
for i in range(5):
    ok(db, "--as", "a", "post", "p%d" % i, "--to", "b")
seen, cur, injected = [], None, False
while True:
    args = ["--as", "b", "inbox", "--peek", "--limit", "2"] + (["--after", cur] if cur else [])
    r = shape(ok(db, *args)); seen.extend(ids(r))
    if not injected:
        ok(db, "--as", "a", "post", "mid-walk", "--to", "b"); injected = True
    if not r["has_more"]:
        break
    cur = r["next"]; assert cur.startswith("v1."), r
assert len(seen) == 6 and len(set(seen)) == 6 and seen == sorted(seen), seen
assert [m["body"] for m in ok(db, "--as", "b", "inbox", "--peek")["items"]][-1] == "mid-walk"
assert len(ok(db, "--as", "b", "inbox", "--peek")["items"]) == 6, "peek consumed nothing"
print("PASS: inbox consumes page by page and the last page has has_more false; inbox --peek --after walks forward and sees a row posted mid-walk at the end")

# ---- cursors: invalid, from another command, with other filters ----
db = fresh("cursors")
ok(db, "--as", "a", "join")
for i in range(6):
    ok(db, "--as", "a", "post", "m%d" % i, "--topic", "t"); ok(db, "--as", "a", "ctx", "set", "k", "v%d" % i)
good = ok(db, "read", "--limit", "2", "--topic", "t")["next"]
body = json.loads(base64.urlsafe_b64decode(good[3:] + "=" * (-len(good[3:]) % 4)))
assert set(body) == {"c", "f", "id"} and body["c"] == "read", body
other = ok(db, "ctx", "history", "k", "--limit", "2")["next"]
usage_error(db, "read", "--before", "garbage")
usage_error(db, "read", "--before", "v1.!!!")
usage_error(db, "read", "--before", "v1." + base64.urlsafe_b64encode(b"[1]").decode())
usage_error(db, "read", "--before", other)                       # from another command
usage_error(db, "read", "--before", good)                        # different filters (no --topic)
usage_error(db, "read", "--before", good, "--topic", "other")
usage_error(db, "ctx", "history", "k2", "--before", other)       # same command, other key
usage_error(db, "read", "--before", good, "--since", "1", "--topic", "t")   # --before with --since
usage_error(db, "--as", "a", "inbox", "--after", good)           # --after needs --peek
usage_error(db, "--as", "a", "inbox", "--peek", "--after", good) # from another command
assert ok(db, "read", "--before", good, "--topic", "t")["items"], "the right filters still work"
print("PASS: an invalid cursor, a cursor from another command and a cursor with different filters are bad_input and exit 2")

# ---- read --since: the next page after an id; has_more means more after ----
db = fresh("since")
ok(db, "--as", "a", "join")
for i in range(5):
    ok(db, "--as", "a", "post", "m%d" % i)
r = shape(ok(db, "read", "--since", "1", "--limit", "2"))
assert ids(r) == [2, 3] and r["has_more"] is True and r["next"] is None, r
r = shape(ok(db, "read", "--since", "3", "--limit", "2"))
assert ids(r) == [4, 5] and r["has_more"] is False, r
print("PASS: read --since returns the next page after an id; has_more means more after it")

# ---- status and watch --json: omitted counts equal the rows left out, per section ----
db = fresh("omit")
for n in "abcde":
    ok(db, "--as", n, "join")
    ok(db, "--as", n, "ctx", "set", "key-" + n, "v")
    ok(db, "--as", n, "claim", "res-" + n)
for i in range(15):
    ok(db, "--as", "a", "post", "m%d" % i)
st = ok(db, "status", "--limit", "2")
assert [len(st[k]) for k in ("agents", "context", "claims", "messages")] == [2, 2, 2, 10], st
assert st["omitted"] == {"agents": 3, "context": 3, "claims": 3, "messages": 5}, st["omitted"]
full = ok(db, "status", "--limit", "-1")
assert full["omitted"] == {"agents": 0, "context": 0, "claims": 0, "messages": 5}, full["omitted"]
print("PASS: status omitted counts equal rows left out per section")

# watch shows at most 200 per section: plant 205 rows in each directly, as another tool could
con = sqlite3.connect(db)
now = "2099-01-01T00:00:00Z"
con.executemany("INSERT INTO agents(name,joined_at,last_seen) VALUES(?,?,?)", [("x%d" % i, now, now) for i in range(205)])
con.executemany("INSERT INTO claims(resource,agent,claimed_at,expires_at) VALUES(?,?,?,?)", [("r/%d" % i, "a", now, now) for i in range(205)])
con.executemany("INSERT INTO context(key,value,updated_by,updated_at) VALUES(?,?,?,?)", [("f%d" % i, "v", "a", now) for i in range(205)])
con.executemany("INSERT INTO messages(ts,sender,body) VALUES(?,?,?)", [(now, "a", "bulk") for i in range(205)])
con.commit(); con.close()
w = ok(db, "watch")
shown = {k: len(w[k]) for k in ("agents", "claims", "context", "messages")}
assert shown == {"agents": 200, "claims": 200, "context": 200, "messages": 200}, shown
assert w["omitted"] == {"agents": 10, "claims": 10, "context": 10, "messages": 20}, (w["omitted"], w["counts"])
print("PASS: watch --json omitted counts equal rows left out per section")

# ---- human output keeps its truncation hints ----
p = run(db, "who", "--limit", "1")
assert p.returncode == 0 and p.stdout.rstrip().endswith("... 209 more (use --limit)"), p.stdout[-80:]
print("PASS: human listings keep their '... N more (use --limit)' hint")
PY
echo "All pagination tests passed"
