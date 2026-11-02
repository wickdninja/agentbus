#!/bin/bash
set -euo pipefail
# The bus is exclusively locked while a command has it open, so a command must never wait on
# anything outside the bus while it holds it. Bug it catches: stdin read (post -, ctx set, log add)
# and stdout written with the lock held, so one slow pipe made every other agent fail "busy".
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
trap 'exec 3>&- 4<&- 2>/dev/null || true; touch "$T/release" 2>/dev/null || true; rm -rf "$T"' EXIT
export AGENTBUS_DB="$T/bus.db"
agentbus --as a join --tool t >/dev/null
agentbus --as b join --tool t >/dev/null

# other_post_while ALIVE_PID: a second agent's post must land while ALIVE_PID is still blocked.
other_post_while() {
  local blocked=$1 what=$2
  agentbus --as b post "other agent during $what" >"$T/o2" 2>"$T/e2" & local p2=$!
  local w=0
  while kill -0 "$p2" 2>/dev/null; do
    sleep 0.05; w=$((w+1)); [ $w -lt 200 ] || break   # 10 s, well inside the 15 s busy limit
  done
  kill -0 "$blocked" 2>/dev/null || fail "$what: the blocked command finished early; the test proved nothing"
  local rc=0; kill -0 "$p2" 2>/dev/null && { kill "$p2"; rc=124; }
  wait "$p2" || rc=$?
  [ "$rc" = 0 ] || fail "$what: another agent's post failed while it was blocked (rc $rc): $(cat "$T/e2")"
}

echo "TEST 1: post - reading a stalled FIFO does not hold the bus"
n=0
for cmd in "post -" "ctx set k -" "log add note -"; do
  rm -f "$T/in"; mkfifo "$T/in"
  n=$((n+1)); P="$T/pause1-$n"; mkdir -p "$P"; touch "$P/before-stdin-read.go"   # mark, never stop
  AGENTBUS_TEST_PAUSE="before-stdin-read=$P" agentbus --as a $cmd <"$T/in" >"$T/o1" 2>"$T/e1" & P1=$!
  exec 3>"$T/in"          # a writer that has sent nothing yet
  # Proof the command is at its stdin read: anything it opened before reading is open now.
  wait_for "$P/before-stdin-read.reached"
  other_post_while $P1 "$cmd from a stalled stdin"
  printf 'late input for %s\n' "$cmd" >&3; exec 3>&-
  wait $P1 || fail "$cmd failed after its input arrived: $(cat "$T/e1")"
done
[ "$(outof agentbus --json read | python3 -c 'import json,sys; print(sum(r["body"]=="late input for post -" for r in json.load(sys.stdin)["items"]))')" = 1 ] || fail "stdin body not posted"
[ "$(outof agentbus --json ctx get k | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')" = "late input for ctx set k -" ] || fail "stdin ctx value not set"
ok "stdin is read before the bus is opened"

echo "TEST 2: a reader whose stdout is not being drained does not hold the bus"
python3 -c 'print("x" * 300000)' | agentbus --as a post - >/dev/null   # more than a pipe buffer
for cmd in read "--json read" status; do
  rm -f "$T/outp"; mkfifo "$T/outp"
  n=$((n+1)); P="$T/pause2-$n"; mkdir -p "$P"; touch "$P/before-stdout-write.go"
  AGENTBUS_TEST_PAUSE="before-stdout-write=$P" agentbus $cmd >"$T/outp" 2>"$T/e1" & P1=$!
  exec 4<"$T/outp"        # a consumer that is not reading yet
  # Proof the command is at its stdout write (which blocks: the output exceeds a pipe buffer).
  wait_for "$P/before-stdout-write.reached"
  other_post_while $P1 "$cmd into a full pipe"
  cat <&4 >/dev/null; exec 4<&-
  wait $P1 || fail "$cmd failed: $(cat "$T/e1")"
done
ok "output is printed after the bus is closed"

echo "TEST 3: an idle plain SQLite connection is named as the cause, not another agentbus"
# Bug it catches: the busy error blamed "another agentbus" when a sqlite3 shell or dashboard held a
# connection, sending the reader looking for an agent that does not exist.
python3 - "$AGENTBUS_DB" "$T/held" "$T/release" <<'PY2' & HOLD=$!
import os, sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("SELECT COUNT(*) FROM agents").fetchone()
open(sys.argv[2], "w").close()
deadline = time.time() + 60   # never outlives a failed test
while not os.path.exists(sys.argv[3]) and os.path.isdir(os.path.dirname(sys.argv[3])) and time.time() < deadline:
    time.sleep(0.05)
PY2
wait_for "$T/held"
expect_fail "stayed busy for 15 seconds. Close any sqlite3 shell or dashboard holding it open, then retry." agentbus claims   # a write open (who only reads, beside it)
touch "$T/release"; wait $HOLD
outof agentbus who >/dev/null
ok "busy error names any process, and the bus works once the client closes"

echo "TEST 4: a listing a lane inflated is capped, and formatting it never holds the bus"
# Bug it catches: who, claims, ctx, log and status formatted every row with the exclusive lock held
# and the 30 s budget covers SQL only, so 200k agents a lane added held the lock for 20 s and more:
# every other agent's post failed busy meanwhile.
python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
t = "2026-01-01T00:00:00Z"
c.executemany("INSERT INTO agents(name,tool,model,cwd,branch,role,joined_at,last_seen) VALUES(?,?,?,?,?,?,?,?)",
              [("lane-%06d" % i, "t", "m" * 40, "/", "b" * 40, "r" * 60, t, t) for i in range(200000)])
c.commit()
PY
total=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM agents").fetchone()[0])' "$AGENTBUS_DB")
P="$T/pause4"; mkdir -p "$P"; touch "$P/after-open.go"   # mark when the bus is held, never stop
start=$(python3 -c 'import time; print(time.time())')
AGENTBUS_TEST_PAUSE="after-open=$P" agentbus status >"$T/o4" 2>"$T/e4" & S4=$!
wait_for "$P/after-open.reached"
agentbus --as b post "posted while status ran" >/dev/null 2>"$T/e2" || fail "a post failed while status had 200k agents: $(cat "$T/e2")"
wait $S4 || fail "status failed: $(cat "$T/e4")"
took=$(python3 -c 'import sys,time; print("%.1f" % (time.time() - float(sys.argv[1])))' "$start")
# The proof is the cap (below) and the post that landed while status held the bus (above). The
# time bound is only a backstop, with ample headroom for a loaded machine: capped, status takes
# well under 1 s here; the old code took 5 s and more (20 s and more with longer rows).
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 15 else 1)' "$took" || fail "status with 200k agents took ${took}s"
grep -qx "  ... $((total - 500)) more (use --limit)" "$T/o4" || fail "status did not cap the agents at 500: $(grep -c '' "$T/o4") lines"
[ "$(sed -n '/^== agents$/,/^$/p' "$T/o4" | grep -c '^  ')" = 501 ] || fail "status did not show 500 agents and the more row"
grep -q '^== last 10 messages$' "$T/o4" || fail "status lost its later sections"
o=$(outof agentbus who --limit 3)
[ "$(grep -c '^  ' <<<"$o")" = 4 ] && grep -qx "  ... $((total - 3)) more (use --limit)" <<<"$o" || fail "who --limit 3: $o"
[ "$(njson env AGENTBUS_DB="$AGENTBUS_DB" "${AB[@]}" --json who 2>"$T/e4")" = 500 ] || fail "--json who not capped at 500"
[ "$(env AGENTBUS_DB="$AGENTBUS_DB" "${AB[@]}" --json who 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["has_more"])')" = True ] || fail "--json who did not say rows were left out"
[ "$(njson env AGENTBUS_DB="$AGENTBUS_DB" "${AB[@]}" --json who --limit -1 2>/dev/null)" = "$total" ] || fail "--limit -1 is not every row"
ok "status with $total agents took ${took}s, capped at 500 rows, while another agent posted"

echo "TEST 5: a --json notice into a stderr nobody drains does not hold the bus"
# Bug it catches: under --json, who and status wrote "N more not shown" to stderr while the bus was
# still open, so a full stderr pipe held the exclusive lock indefinitely and every other agent
# failed busy.
D5="$T/b5"; mkdir -p "$D5"; AGENTBUS_DB="$D5/bus.db" agentbus --as b join --tool t >/dev/null
python3 - "$D5/bus.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executemany("INSERT INTO agents(name,tool,model,cwd,branch,role,joined_at,last_seen) VALUES(?,?,?,?,?,?,?,?)",
              [("lane-%03d" % i, "t", "m", "/", "b", "r", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z") for i in range(500)])
c.commit()
PY
cat > "$T/fullerr.py" <<'PY'
import fcntl, os, subprocess, sys, threading, time
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
db, pdir = sys.argv[1:3]
env = dict(os.environ, AGENTBUS_DB=db, AGENTBUS_TEST_PAUSE="after-open=" + pdir)
open(os.path.join(pdir, "after-open.go"), "w").close()   # mark when the bus is held, never stop
bad = []
# post to an absent name is the --json command that still writes a stderr notice (listings carry has_more instead)
for args in (["--json", "--as", "a", "post", "x", "--to", "nobody"],):
    r, w = os.pipe()
    fl = fcntl.fcntl(w, fcntl.F_GETFL)
    fcntl.fcntl(w, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    try:
        while True:
            os.write(w, b"x" * 4096)
    except BlockingIOError:
        pass
    fcntl.fcntl(w, fcntl.F_SETFL, fl)       # full, and blocking again, as a real pipe is
    reached = os.path.join(pdir, "after-open.reached")
    if os.path.exists(reached):
        os.unlink(reached)
    p = subprocess.Popen(agentbus_argv() + args, env=env, stdout=subprocess.DEVNULL, stderr=w)
    os.close(w)
    deadline = time.time() + 20
    while not os.path.exists(reached):
        if time.time() > deadline or p.poll() is not None:
            sys.exit("%s never held the bus (rc %s)" % (args, p.poll()))
        time.sleep(0.02)
    time.sleep(0.5)                          # past the listing, at its notice
    q = subprocess.run([*agentbus_argv(), "--as", "b", "post", "while %s was stuck on stderr" % args[3]],
                       env=dict(os.environ, AGENTBUS_DB=db), capture_output=True, timeout=30)
    if p.poll() is not None:
        bad.append("%s was not stuck on its stderr, so this proved nothing (rc %s)" % (args, p.returncode))
    if q.returncode != 0:
        bad.append("post while %s waited on stderr: rc %s %s" % (args, q.returncode, q.stderr.decode()[:200]))
    threading.Thread(target=lambda: [None for _ in iter(lambda: os.read(r, 1 << 16), b"")], daemon=True).start()
    p.wait(timeout=30)
print("\n".join(bad) if bad else "ok")
PY
P="$T/pause5"; mkdir -p "$P"
r=$(python3 "$T/fullerr.py" "$D5/bus.db" "$P")
[ "$r" = ok ] || fail "a post failed (or the stuck command was not stuck) while a --json notice waited on a full stderr: $r"
ok "--json post with a stderr notice and a full stderr: another agent's post landed meanwhile"

echo "TEST 6: nothing is written, cleaned or formatted while a bus is open"
# Bug it catches: show() cleaned its fields when called (a 100k ctx value cleaned with the lock
# held), die() cleaned its message before the bus closed, and note() wrote while the bus was open.
# Every command below runs in-process; any write to stdout or stderr, and any clean(), made while
# a Bus connection exists is reported.
D6="$T/b6"; mkdir -p "$D6/home"
HOME="$D6/home" "$PY" - "$BIN" "$D6" <<'PY' || fail "something ran with the bus open"
import io, os, sqlite3, subprocess, sys
sys.dont_write_bytecode = True
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
loader = SourceFileLoader("agentbus_under_test", sys.argv[1])
m = module_from_spec(spec_from_loader("agentbus_under_test", loader))
loader.exec_module(m)
d = sys.argv[2]
db = os.path.join(d, "bus.db")
open_now, bad = [0], []
init, close = m.Bus.__init__, m.Bus.close
def counted_init(self, *a, **k):
    init(self, *a, **k)
    open_now[0] += 1
    self._counted = True
def counted_close(self):
    if getattr(self, "_counted", False):
        self._counted = False
        open_now[0] -= 1
    close(self)
m.Bus.__init__, m.Bus.close = counted_init, counted_close
clean = m.clean
def watched_clean(*a, **k):
    if open_now[0]:
        bad.append(("clean() with the bus open", str(a[0])[:40] if a else ""))
    return clean(*a, **k)
m.clean = watched_clean
# Formatting lane text (a listing row, a message, a wrapped line, a JSON value) is spied on too,
# by name, so a helper that formats before the bus closes is caught even if it never calls clean().
def spied(name, fn):
    def wrapper(*a, **k):
        if open_now[0]:
            bad.append(("%s() with the bus open" % name, str(a[0])[:40] if a else ""))
        return fn(*a, **k)
    return wrapper
for name in ("clean_row", "col0", "wrap_line", "wrap_output", "diag", "fmt_who", "fmt_msg", "fmt_ctx",
             "fmt_claim", "jsonable"):
    if hasattr(m, name):
        setattr(m, name, spied(name, getattr(m, name)))
# A write straight to fd 1 or 2 (os.write, as exit_now does) is not seen by the Spy streams.
real_write = os.write
def watched_write(fd, data):
    if open_now[0] and fd in (1, 2) and data:
        bad.append(("os.write to fd %d with the bus open" % fd, bytes(data[:60])))
    return real_write(fd, data)
os.write = watched_write
class Spy(io.TextIOBase):
    def __init__(self, name):
        self.name, self.text = name, []
    def write(self, s):
        if open_now[0] and s:
            bad.append(("write to %s with the bus open" % self.name, s[:60]))
        self.text.append(s)
        return len(s)
    def fileno(self):
        raise io.UnsupportedOperation
    def flush(self):
        pass
def run(*args, env=None):
    sys.argv = ["agentbus"] + list(args)
    old = dict(os.environ)
    os.environ.pop("AGENTBUS_DB", None)
    os.environ.update(env or {"AGENTBUS_DB": db})
    out, err = Spy("stdout"), Spy("stderr")
    sys.stdout, sys.stderr = out, err
    try:
        m.main()
    except SystemExit as e:
        if e.code not in (None, 0):
            err.write(str(e.code))   # what Python prints at exit
    finally:
        sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__
        os.environ.clear(); os.environ.update(old)
    return "".join(out.text), "".join(err.text)
run("--as", "a", "join", "--tool", "t")
run("--as", "b", "join", "--tool", "t")
c = sqlite3.connect(db)
c.executemany("INSERT INTO agents(name,tool,model,cwd,branch,role,joined_at,last_seen) VALUES(?,?,?,?,?,?,?,?)",
              [("lane-%03d" % i, "t", "m", "/", "b", "r", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z") for i in range(600)])
c.executemany("INSERT INTO claims(resource,agent,purpose,claimed_at,expires_at) VALUES(?,?,?,?,?)",
              [("planted/%04d" % i, "b", "p", "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z") for i in range(700)]
              + [("./odd//%d" % i, "b", "p", "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z") for i in range(5)])
c.executemany("INSERT INTO messages(ts,sender,recipient,kind,body) VALUES(?,?,?,?,?)",
              [("2026-01-01T00:00:00Z", "b", "a", "note", "m%d" % i) for i in range(600)])
c.commit(); c.close()
big = "v" * 100000
for args in (["--json", "who"], ["who"], ["--json", "status"], ["status"], ["--as", "a", "ctx", "set", "k", big],
             ["ctx", "get", "k"], ["ctx", "get"], ["--json", "ctx", "history", "k"], ["--as", "a", "inbox"],
             ["--json", "--as", "a", "inbox"], ["--as", "b", "claim", "x", "--purpose", big],
             ["--as", "a", "claim", "x"], ["--as", "a", "post", "--reply-to", "999999", "hi"],
             ["claims"], ["--json", "claims"], ["log", "show"], ["read"], ["--as", "a", "post", big],
             ["--as", "b", "release", "--all"], ["--as", "b", "leave"], ["ctx", "get", "missing"]):
    o, e = run(*args)
    if "Traceback" in e:
        bad.append((args, e[-300:]))
# The post notice must use the same deferred stderr path as listing notices.
o, e = run("--as", "a", "post", "queued handoff", "--to", "absent", "--kind", "handoff")
if "to absent [handoff]" not in o or e != "agentbus: absent is not on the roster; the message waits for that name.\n":
    bad.append(("off-roster post output", o, e))
for b in bad[:10]:
    print(b)
sys.exit(1 if bad else 0)
PY
ok "no write to stdout or stderr, and no clean(), while a bus was open, across every command"

echo "TEST 7: leave, release --all and inbox are capped; the inbox cursor never passes an unshown message"
# Bug it catches: leave and release --all printed and logged every claim (400k planted claims
# printed 400001 lines and made a 6.8 MB log row), and inbox had no cap at all.
D7="$T/b7"; mkdir -p "$D7"; export AGENTBUS_DB="$D7/bus.db"
agentbus --as c join --tool t >/dev/null; agentbus --as d join --tool t >/dev/null; agentbus --as e join --tool t >/dev/null
plant() {  # plant AGENT N: N claims held by AGENT
  python3 - "$AGENTBUS_DB" "$1" "$2" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executemany("INSERT INTO claims(resource,agent,purpose,claimed_at,expires_at) VALUES(?,?,?,?,?)",
              [("%s/%06d" % (sys.argv[2], i), sys.argv[2], "p", "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z")
               for i in range(int(sys.argv[3]))])
c.commit()
PY
}
logrow() { python3 -c 'import sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute("SELECT detail FROM log WHERE agent=? AND action=? ORDER BY id DESC LIMIT 1", (sys.argv[2], sys.argv[3])).fetchone()[0]; print(len(r), r.endswith(", and 19500 more"))' "$AGENTBUS_DB" "$1" "$2"; }
plant c 20000
o=$(outof agentbus --as c leave)
[ "$(head -1 <<<"$o")" = "left as c, released 20000 claims" ] || fail "leave header: $(head -1 <<<"$o")"
[ "$(grep -c '^  c/' <<<"$o")" = 500 ] && [ "$(tail -1 <<<"$o")" = "  ... 19500 more" ] && [ "$(grep -c '' <<<"$o")" = 502 ] || fail "leave printed $(grep -c '' <<<"$o") lines, not 500 and a more row"
read -r len tail_ok <<<"$(logrow c leave)"
[ "$tail_ok" = True ] && [ "$len" -lt 20000 ] || fail "leave log row is $len chars (ends with the count: $tail_ok)"
plant d 20000
o=$(json_ok agentbus --json --as d release --all)
python3 -c 'import json,sys; j=json.loads(sys.argv[1]); assert len(j["released"]) == 500 and j["released_count"] == 20000, (len(j["released"]), j.get("released_count"))' "$o" || fail "release --all --json not capped"
read -r len tail_ok <<<"$(logrow d release)"
[ "$tail_ok" = True ] && [ "$len" -lt 20000 ] || fail "release --all log row is $len chars"
plant d 20000
o=$(outof agentbus --as d release --all)
[ "$(grep -c '' <<<"$o")" = 502 ] && [ "$(tail -1 <<<"$o")" = "  ... 19500 more" ] || fail "release --all printed $(grep -c '' <<<"$o") lines"
[ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM claims").fetchone()[0])' "$AGENTBUS_DB")" = 0 ] || fail "claims left after leave and release --all"
# inbox: 600 messages for e, then one broadcast. The cursor moves only past what was shown.
python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executemany("INSERT INTO messages(ts,sender,recipient,kind,body) VALUES(?,?,?,?,?)",
              [("2026-01-01T00:00:00Z", "d", "e", "note", "to e %03d" % i) for i in range(600)])
c.commit()
PY
o=$(outof agentbus --as e inbox)
[ "$(grep -c '^  to e ' <<<"$o")" = 500 ] && grep -qx '  ... 100 more unread; run inbox again' <<<"$o" || fail "inbox not capped at 500: $(grep -c '^  to e ' <<<"$o") shown"
grep -q '^  to e 499$' <<<"$o" && ! grep -q '^  to e 500$' <<<"$o" || fail "inbox did not show the oldest 500"
o=$(outof agentbus --as e inbox --limit 30)
[ "$(grep -c '^  to e ' <<<"$o")" = 30 ] && grep -q '^  to e 500$' <<<"$o" && grep -q '^  to e 529$' <<<"$o" || fail "second inbox did not start at the first unshown message"
o=$(json_ok agentbus --json --as e inbox --peek)
[ "$(python3 -c 'import json,sys; j=json.loads(sys.argv[1])["items"]; print(len(j), j[0]["body"])' "$o")" = "70 to e 530" ] || fail "--peek after the capped reads: $o"
o=$(outof agentbus --as e inbox --limit -1)
[ "$(grep -c '^  to e ' <<<"$o")" = 70 ] || fail "inbox --limit -1 did not show the remaining 70"
[ "$(outof agentbus --as e inbox)" = "inbox empty" ] || fail "inbox not empty after every message was shown"
ok "leave and release --all list and log 500 of 20000 claims; inbox shows the oldest 500 and keeps the rest unread"

echo "TEST 8: 400k stored claims do not slow every open"
# Bug it catches: normalize_stored_claims read every claim into Python on every open, with the lock
# held and outside the SQL budget: 400k claims added 0.6 s to every command, and 400k claims
# needing normalisation 8 s, all of it in one open.
D8="$T/b8"; mkdir -p "$D8"
for db in empty plain odd; do AGENTBUS_DB="$D8/$db.db" agentbus --as a join --tool t >/dev/null; done
python3 - "$D8" <<'PY'
import sqlite3, sys
for name, pre in (("plain", "src/f"), ("odd", "./src//f")):
    c = sqlite3.connect("%s/%s.db" % (sys.argv[1], name))
    c.executemany("INSERT INTO claims(resource,agent,purpose,claimed_at,expires_at) VALUES(?,?,?,?,?)",
                  [(pre + "%06d" % i, "b", "p", "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z") for i in range(400000)])
    c.commit()
PY
# best of 3 `who` runs, in seconds
best() { python3 - "$1" <<'PY'
import os, subprocess, sys, time
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
ts = []
for _ in range(3):
    t0 = time.monotonic()
    subprocess.run([*agentbus_argv(), "who"], env=dict(os.environ, AGENTBUS_DB=sys.argv[1]),
                   stdout=subprocess.DEVNULL, check=True)
    ts.append(time.monotonic() - t0)
print("%.3f" % min(ts))
PY
}
te=$(best "$D8/empty.db"); tp=$(best "$D8/plain.db")
python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 0.3 else 1)' "$te" "$tp" || fail "400k normal claims added $(python3 -c "print(round($tp-$te,2))")s to an open (${te}s without)"
nodd() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM claims WHERE resource GLOB ?", ("./*",)).fetchone()[0])' "$D8/odd.db"; }
t0=$(python3 -c 'import time; print(time.time())')
AGENTBUS_DB="$D8/odd.db" agentbus ctx get >/dev/null
took=$(python3 -c 'import sys,time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$t0")
[ "$(nodd)" = 399500 ] || fail "one open normalised $((400000 - $(nodd))) claims, not at most 500"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.5 else 1)' "$took" || fail "an open with 400k claims to normalise took ${took}s"
AGENTBUS_DB="$D8/odd.db" agentbus ctx get >/dev/null
[ "$(nodd)" = 399000 ] || fail "the next open did not normalise the next 500"
ok "an open with 400k claims costs ${tp}s (${te}s with none); 400k to normalise: 500 per open, ${took}s"
export AGENTBUS_DB="$T/bus.db"

echo "All lock-hold tests passed"
