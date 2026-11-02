#!/bin/bash
set -euo pipefail
# A sandboxed lane can write the bus folder and race the brain: swap bus.db or a sidecar for a
# symlink or hard link to a victim file between the brain's checks and SQLite's own open. Bug it
# catches: SQLite following the swapped link and writing the brain's rows (or WAL frames, or a
# truncated -shm) into the victim. The victim must stay byte-identical in every case.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME" "$T/bus" "$T/p"
trap 'touch "$T/stop" 2>/dev/null || true; rm -rf "$T"' EXIT
export AGENTBUS_DB="$T/bus/bus.db"
agentbus --as brain join --tool t >/dev/null
AGENTBUS_DB="$T/victim.db" agentbus --as v join --tool t >/dev/null
AGENTBUS_DB="$T/victim.db" agentbus --as v post "victim row" >/dev/null
cp "$T/victim.db" "$T/victim.orig"
sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
VSHA=$(sha "$T/victim.orig")
nmsg() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from messages").fetchone()[0])' "$1"; }

# swap_at POINT FILE KIND: pause the brain's post at POINT, plant FILE as a KIND (sym|hard) link to
# the victim, let it go, then put the folder back.
swap_at() {
  local point=$1 f=$2 kind=$3
  rm -f "$T/p"/*; cp "$T/victim.orig" "$T/victim.db"
  AGENTBUS_TEST_PAUSE="$point=$T/p" agentbus --as brain post "x $point $f $kind" >"$T/out" 2>"$T/err" &
  local pid=$!
  local w=0; while [ ! -e "$T/p/$point.reached" ]; do sleep 0.02; w=$((w+1)); [ $w -lt 500 ] || fail "pause point $point never reached"; done
  [ -e "$T/bus/$f" ] && mv "$T/bus/$f" "$T/aside"
  if [ "$kind" = sym ]; then ln -s "$T/victim.db" "$T/bus/$f"; else ln "$T/victim.db" "$T/bus/$f"; fi
  touch "$T/p/$point.go"
  local rc=0; wait $pid || rc=$?
  rm -f "$T/bus/$f"; [ -e "$T/aside" ] && mv "$T/aside" "$T/bus/$f"
  grep -q Traceback "$T/err" && fail "traceback: $(cat "$T/err")"
  [ "$(sha "$T/victim.db")" = "$VSHA" ] || fail "victim changed: $point $f $kind (rc $rc: $(cat "$T/err"))"
  echo "$rc"
}

echo "TEST 1: bus.db swapped after the checks, before SQLite opens it"
for k in sym hard; do
  rc=$(swap_at before-connect bus.db $k); [ "$rc" != 0 ] || fail "post succeeded through a $k link"
  grep -q "changed while opening" "$T/err" || fail "unexpected error: $(cat "$T/err")"
done
ok "a swapped main file is refused before any read or write"

echo "TEST 2: -wal, -shm, -journal swapped before SQLite opens them"
for f in bus.db-wal bus.db-journal; do for k in sym hard; do swap_at before-first-read $f $k >/dev/null; done; done
rc=$(swap_at before-first-read bus.db-shm sym); [ "$rc" = 0 ] || fail "post failed with a -shm link: $(cat "$T/err")"
rc=$(swap_at before-first-read bus.db-shm hard); [ "$rc" = 0 ] || fail "post failed with a -shm hard link"
ok "sidecar links never reach the victim (-shm is never opened: exclusive locking)"

echo "TEST 2b: header bytes 18-19 flipped to rollback mode plus a hard-linked -journal"
# Bug it catches: the CLI read the header itself, saw WAL, skipped the in-memory journal, and
# SQLite then converted through an on-disk -journal that was the victim.
for point in before-first-read before-wal-convert; do
  rm -f "$T/p"/*; cp "$T/victim.orig" "$T/victim.db"
  AGENTBUS_TEST_PAUSE="$point=$T/p" agentbus --as brain post "flip $point" >"$T/out" 2>"$T/err" &
  pid=$!
  wait_for "$T/p/$point.reached"
  python3 -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek(18); f.write(b"\x01\x01"); f.close()' "$T/bus/bus.db"
  ln "$T/victim.db" "$T/bus/bus.db-journal"
  touch "$T/p/$point.go"
  rc=0; wait $pid || rc=$?
  rm -f "$T/bus/bus.db-journal"
  grep -q Traceback "$T/err" && fail "traceback: $(cat "$T/err")"
  [ "$(sha "$T/victim.db")" = "$VSHA" ] || fail "victim changed: header flip + hard-linked -journal at $point (rc $rc)"
done
ok "a flipped header never makes SQLite write an on-disk journal"

echo "TEST 2c: a hard link swapped in after the checks never has its outside target chmodded"
# Bug it catches: chmod_nofollow checked type and owner on the opened fd but not the link count or
# identity, so a hard link planted between check_node and the open got fchmod 0600 on its target.
echo keep > "$T/modevictim"; chmod 644 "$T/modevictim"
for f in bus.db bus.db-wal; do for k in hard sym; do
  rm -f "$T/p"/*; [ "$f" = bus.db-wal ] && : > "$T/bus/bus.db-wal"
  AGENTBUS_TEST_PAUSE="before-chmod-$f=$T/p" agentbus --as brain post "chmod $f $k" >"$T/out" 2>"$T/err" &
  pid=$!
  wait_for "$T/p/before-chmod-$f.reached"
  mv "$T/bus/$f" "$T/aside"
  if [ "$k" = sym ]; then ln -s "$T/modevictim" "$T/bus/$f"; else ln "$T/modevictim" "$T/bus/$f"; fi
  touch "$T/p/before-chmod-$f.go"
  rc=0; wait $pid || rc=$?
  rm -f "$T/bus/$f"; mv "$T/aside" "$T/bus/$f"; [ "$f" = bus.db-wal ] && rm -f "$T/bus/bus.db-wal"
  grep -q Traceback "$T/err" && fail "traceback: $(cat "$T/err")"
  [ "$(mode "$T/modevictim")" = 644 ] || fail "$k link at $f: outside target chmodded to $(mode "$T/modevictim")"
  [ "$rc" != 0 ] || fail "$k link at $f: post succeeded"
  grep -qE "refusing .*$f: (it has 2 hard links|changed while opening|Too many levels)" "$T/err" || fail "unexpected error: $(cat "$T/err")"
  [ "$(cat "$T/modevictim")" = keep ] || fail "victim content changed"
done; done
ok "a link swapped in before the chmod is refused, its target's mode unchanged"

echo "TEST 2d: a -wal that another connection's close deletes (or recreates) mid-check is not an error"
# Bug it catches: the WAL vanished between check_node's lstat and chmod_nofollow's open, and the
# CLI died with "No such file or directory" before its retry loop instead of checking again.
# unlinked-open: deleted after chmod_nofollow opened it, so its fd shows 0 links (seen on 3.14).
for how in vanish recreate unlinked-open; do
  rm -f "$T/p"/*; : > "$T/bus/bus.db-wal"
  point=before-chmod-bus.db-wal; [ "$how" = unlinked-open ] && point=after-chmod-open-bus.db-wal
  AGENTBUS_TEST_PAUSE="$point=$T/p" agentbus --as brain post "wal $how" >"$T/out" 2>"$T/err" &
  pid=$!
  wait_for "$T/p/$point.reached"
  rm "$T/bus/bus.db-wal"; [ "$how" = recreate ] && : > "$T/bus/bus.db-wal"
  touch "$T/p/$point.go"
  rc=0; wait $pid || rc=$?
  [ "$rc" = 0 ] || fail "post failed after a -wal $how: $(cat "$T/err")"
  grep -q "posted #" "$T/out" || fail "no post id: $(cat "$T/out")"
done
ok "a vanished or recreated -wal restarts the checks inside the retry budget"

echo "TEST 3: a lane swapping bus.db and -wal in a loop while the brain posts N times"
N=${AGENTBUS_RACE_N:-300}
python3 - "$T/bus" "$T/victim.db" "$T/stop" <<'PY' &
import os, sys, time, random
d, victim, stop = sys.argv[1:]
bus, wal = os.path.join(d, "bus.db"), os.path.join(d, "bus.db-wal")
hold = os.path.join(d, ".hold")
while not os.path.exists(stop):
    for target in (bus, wal):
        try:
            os.rename(target, hold)
        except OSError:
            continue
        try:
            if random.random() < 0.5:
                os.symlink(victim, target)
            else:
                os.link(victim, target)
            time.sleep(random.uniform(0, 0.004))
            os.unlink(target)
        except OSError:
            pass
        os.rename(hold, target)
    time.sleep(random.uniform(0, 0.01))
PY
LANE=$!
okc=0; failc=0
for i in $(seq 1 "$N"); do
  if agentbus --as brain post "race $i" >/dev/null 2>"$T/err"; then okc=$((okc+1)); else
    failc=$((failc+1)); grep -q Traceback "$T/err" && { touch "$T/stop"; fail "traceback: $(cat "$T/err")"; }
  fi
done
touch "$T/stop"; wait $LANE || true
[ -e "$T/bus/.hold" ] && mv "$T/bus/.hold" "$T/bus/bus.db"
[ "$(sha "$T/victim.db")" = "$VSHA" ] || fail "victim changed during the race"
[ "$(nmsg "$T/victim.db")" = 1 ] || fail "rows landed in the victim"
got=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from messages where body like ?",("race %",)).fetchone()[0])' "$T/bus/bus.db")
# A lane that hides bus.db while a post opens it makes that post create a fresh bus, which the
# lane then replaces: the same power as deleting rows, which a lane with write access has anyway.
# What must hold: nothing that was refused landed, and nothing reached the victim.
[ "$got" -le "$okc" ] || fail "$got posts on the bus but only $okc reported success"
[ "$okc" -gt 0 ] && [ "$failc" -gt 0 ] || fail "the race never interleaved ($okc landed, $failc refused); the test proved nothing"
ok "$N posts under a swapping lane: $okc reported success ($got on the bus), $failc refused, 0 in the victim"
echo "TEST 2e: a sidecar seen mid-unlink (0 links) is retried, not refused"
# Bug it catches: under concurrent joins, lstat of -wal returned st_nlink 0 while another connection's
# last close was deleting it, and check_node refused "it has 0 hard links" instead of retrying.
D2e=$(mktemp -d); AGENTBUS_DB="$D2e/b.db" agentbus --as z join --tool t >/dev/null
out=$(AGENTBUS_DB="$D2e/b.db" "$PY" - "$BIN" <<'PY'
import os, runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_t")
real, hits = os.lstat, []
class FakeSt:
    def __init__(self, st): self._st = st
    def __getattr__(self, k): return 0 if k == "st_nlink" else getattr(self._st, k)
def lstat(p, *a, **k):
    st = real(p, *a, **k)
    if str(p).endswith("-wal") and not hits:
        hits.append(p); return FakeSt(st)
    return st
os.lstat = lstat
open(os.environ["AGENTBUS_DB"] + "-wal", "ab").close()
try:
    m["check_bus"](os.environ["AGENTBUS_DB"], False)
    print("no-raise")
except m["_Vanished"]:
    print("vanished")
except SystemExit as e:
    print("died:", e)
PY
)
[ "$out" = vanished ] || fail "a 0-link sidecar was not retried: $out"
ok "a sidecar seen with 0 links raises _Vanished (retried inside open_bus)"

echo "TEST 9: a FIFO swapped in after the checks is refused at once, never waited on"
# Bug it catches: chmod_nofollow and read_small opened lane-writable paths (bus.db and its
# sidecars, VERSION, info/exclude) with O_RDONLY and no O_NONBLOCK, so a FIFO swapped in after
# check_node blocked the open forever, before any fstat, with the whole command stuck behind it.
# fifo_swap POINT FILE CMD...: pause CMD at POINT, put a FIFO where FILE was, let it go; prints
# "rc seconds" (seconds from the go to the exit; 99 when it was still blocked after 10 s).
cat > "$T/fifo_swap.py" <<'PY'
import os, subprocess, sys, time
point, f, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
d = os.environ["P"]
for x in os.listdir(d):
    os.unlink(os.path.join(d, x))
env = dict(os.environ, AGENTBUS_TEST_PAUSE=f"{point}={d}")
p = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=open(os.environ["ERR"], "w"))
deadline = time.time() + 30
while not os.path.exists(os.path.join(d, point + ".reached")):
    if time.time() > deadline or p.poll() is not None:
        sys.exit("pause point %s never reached (rc %s)" % (point, p.poll()))
    time.sleep(0.02)
os.rename(f, f + ".aside")
os.mkfifo(f, 0o600)
t0 = time.monotonic()
open(os.path.join(d, point + ".go"), "w").close()
try:
    rc = p.wait(timeout=10)
    took = time.monotonic() - t0
except subprocess.TimeoutExpired:
    p.kill(); p.wait(); rc, took = -9, 99
os.unlink(f)
os.rename(f + ".aside", f)
print(rc, "%.2f" % took)
PY
export P="$T/p" ERR="$T/err"
FR="$T/fiforepo"; mkrepo "$FR"; agentbus init "$FR" >/dev/null
for c in "before-chmod-bus.db $T/bus/bus.db ${AB[*]} --as brain who" \
         "before-chmod-bus.db $T/bus/bus.db ${AB[*]} --as brain post fifo" \
         "before-read-VERSION $FR/.agentbus/VERSION ${AB[*]} upgrade $FR" \
         "before-read-exclude $FR/.git/info/exclude ${AB[*]} init $FR"; do
  # shellcheck disable=SC2086
  read -r rc took <<<"$(python3 "$T/fifo_swap.py" $c)"
  grep -q Traceback "$T/err" && fail "traceback: $(cat "$T/err")"
  [ "$rc" != 0 ] && [ "$rc" != -9 ] || fail "not refused (rc $rc, ${took}s): $c: $(cat "$T/err")"
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)' "$took" || fail "took ${took}s to refuse: $c"
  grep -q "not a regular file" "$T/err" || fail "unexpected error: $c: $(cat "$T/err")"
done
outof agentbus --as brain post "after the fifo" >/dev/null
ok "a FIFO swapped for bus.db, VERSION or info/exclude is refused in under a second"

echo "TEST 10: a FIFO planted at bus.db-journal or -wal after the checks never hangs a command"
# Bug it catches: SQLite opens a hot -journal (and -wal) itself, by name and blocking, after the
# CLI's checks and before its first read. A FIFO planted there made that open block forever, with
# the exclusive lock held, so every other agent then failed busy; the 30 s query budget cannot
# interrupt a blocking open(). The open phases now run under a watchdog that ends the command.
# fifo_at POINT FILE: pause a post at POINT, plant a FIFO at FILE, let it go; prints "rc seconds"
# (seconds from the go to the exit; 99 when it was still running 6 s after the 2 s budget).
cat > "$T/fifo_at.py" <<'PY'
import os, subprocess, sys, time
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
point, f = sys.argv[1:3]
d = os.environ["P"]
for x in os.listdir(d):
    os.unlink(os.path.join(d, x))
env = dict(os.environ, AGENTBUS_TEST_PAUSE=f"{point}={d}", AGENTBUS_TEST_OPEN_BUDGET="2")
p = subprocess.Popen([*agentbus_argv(), "--as", "brain", "post", "fifo at " + os.path.basename(f)], env=env,
                     stdout=subprocess.DEVNULL, stderr=open(os.environ["ERR"], "w"))
deadline = time.time() + 30
while not os.path.exists(os.path.join(d, point + ".reached")):
    if time.time() > deadline or p.poll() is not None:
        sys.exit("pause point %s never reached (rc %s)" % (point, p.poll()))
    time.sleep(0.02)
aside = os.path.lexists(f)
if aside:  # an empty -wal an earlier command left: put it back afterwards
    os.rename(f, f + ".aside")
os.mkfifo(f, 0o600)
t0 = time.monotonic()
open(os.path.join(d, point + ".go"), "w").close()
try:
    rc = p.wait(timeout=2 + 6)
    took = time.monotonic() - t0
except subprocess.TimeoutExpired:
    p.kill(); p.wait(); rc, took = -9, 99
if os.path.lexists(f):  # some SQLite builds remove a -wal they could not use
    os.unlink(f)
if aside:
    os.rename(f + ".aside", f)
print(rc, "%.2f" % took)
PY
for f in bus.db-journal bus.db-wal; do
  read -r rc took <<<"$(python3 "$T/fifo_at.py" before-connect "$T/bus/$f")"
  grep -q Traceback "$T/err" && fail "$f: traceback: $(cat "$T/err")"
  [ "$rc" = 1 ] || fail "$f: a FIFO planted before the connect did not end the command (rc $rc, ${took}s): $(cat "$T/err")"
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 2 + 3 else 1)' "$took" || fail "$f: took ${took}s with a 2 s budget"
  # A hot -journal is opened blocking, so the watchdog ends it. SQLite refuses a FIFO at -wal by
  # itself (3.54 on macOS: "unable to open database file"; Homebrew's builds: "disk I/O error");
  # a build that opened and read it would block and be ended by the watchdog too.
  case "$f" in
    *-journal) want="opening the bus did not finish within 2 s" ;;
    *) want="opening the bus did not finish within 2 s\|unable to open database file\|disk I/O error" ;;
  esac
  tr -d '\n' < "$T/err" | sed 's/  */ /g' | grep -q "$want" || fail "$f: unexpected error: $(cat "$T/err")"
  outof agentbus --as brain post "after a fifo at $f" >/dev/null
done
# Hook-free, as a lane would do it: a loop creating and removing a FIFO at bus.db-journal as fast
# as it can while 30 commands run. Each must end (refused, stopped or done) within the budget plus
# slack; none may hang.
cat > "$T/fifo_loop.py" <<'PY'
import os, subprocess, sys, threading, time
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
db = sys.argv[1]
stop = []
def loop():
    j = db + "-journal"
    while not stop:
        try:
            os.mkfifo(j, 0o600)
        except OSError:
            pass
        time.sleep(0.0005)
        try:
            os.unlink(j)
        except OSError:
            pass
threading.Thread(target=loop, daemon=True).start()
env = dict(os.environ, AGENTBUS_TEST_OPEN_BUDGET="2")
bad, stopped = [], 0
for i in range(30):
    t0 = time.monotonic()
    p = subprocess.Popen([*agentbus_argv(), "--as", "brain", "post", "loop %d" % i], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        _, err = p.communicate(timeout=2 + 6)
    except subprocess.TimeoutExpired:
        p.kill(); p.communicate(); bad.append("command %d hung" % i); continue
    took, err = time.monotonic() - t0, err.decode("utf-8", "replace")
    if took > 2 + 4:
        bad.append("command %d took %.1fs" % (i, took))
    if "Traceback" in err or (p.returncode != 0 and not err.startswith("agentbus: ")):
        bad.append("command %d: rc %s %r" % (i, p.returncode, err[:200]))
    stopped += "did not finish within" in err
stop.append(1)
time.sleep(0.05)
try:
    os.unlink(db + "-journal")
except OSError:
    pass
print("\n".join(bad) if bad else "ok %d" % stopped)
PY
# The loop asserts only that no command hangs or fails. Whether a command meets the FIFO at the
# one moment it blocks is a race that depends on the machine (CI runners, macOS ones included, can
# go many batches without it), so how many the watchdog stopped is printed, not required. The
# deterministic -journal case above is what proves the watchdog ends a command blocked on a FIFO.
r=$(python3 "$T/fifo_loop.py" "$AGENTBUS_DB")
case "$r" in ok*) ;; *) fail "the FIFO loop: $r" ;; esac
echo "the FIFO loop: ${r#ok } of 30 commands stopped by the watchdog (informational)"
outof agentbus --as brain post "after the fifo loop" >/dev/null
ok "a FIFO at -journal or -wal ends the command within the open budget; 30 commands beside a FIFO loop neither hang nor fail"

echo "TEST 11: a FIFO swapped for info/exclude between its read and the append never hangs"
# Bug it catches: ensure_exclude appended to info/exclude with a plain O_WRONLY open (no
# O_NONBLOCK, no fstat), so a FIFO swapped in after the read blocked the command forever; and a
# refused exclude killed every ordinary command, though the rule is a convenience (a notice).
ER="$T/exrepo"; mkrepo "$ER"
for cmd in "init $ER" "--as x who"; do
  rm -rf "$ER/.agentbus"; mkdir "$ER/.agentbus"; : > "$ER/.git/info/exclude"
  # shellcheck disable=SC2086
  read -r rc took <<<"$(cd "$ER" && env -u AGENTBUS_DB python3 "$T/fifo_swap.py" before-exclude-append "$ER/.git/info/exclude" "${AB[@]}" $cmd)"
  grep -q Traceback "$T/err" && fail "$cmd: traceback: $(cat "$T/err")"
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)' "$took" || fail "$cmd: took ${took}s (rc $rc): $(cat "$T/err")"
  case "$cmd" in
    init*) [ "$rc" != 0 ] && grep -q "refusing .*exclude" "$T/err" || fail "init: not refused (rc $rc): $(cat "$T/err")" ;;
    *) [ "$rc" = 0 ] && grep -q "could not add .agentbus/ to .*exclude" "$T/err" || fail "$cmd: not a notice (rc $rc): $(cat "$T/err")" ;;
  esac
done
ok "a FIFO at info/exclude: init refuses, an ordinary command carries on with a notice, both at once"

echo "All race tests passed"
