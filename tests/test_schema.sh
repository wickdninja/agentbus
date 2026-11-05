#!/usr/bin/env bash
# Schema versions and open modes: PRAGMA user_version is the bus's schema version; a write open
# stamps, adopts or refuses; migrate=False and read-only opens never write; busy_wait bounds the wait.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
OLD="$TESTS_DIR/fixtures/legacy/agentbus-0.1.0"
# seed DIR TEXT: a bus in DIR where agent a has joined and posted TEXT (a write needs a joined name).
seed() { AGENTBUS_DB="$1/bus.db" agentbus --as a join >/dev/null; AGENTBUS_DB="$1/bus.db" agentbus --as a post "$2" >/dev/null; }
# In-process cases load the module itself (a mutation copy when AGENTBUS_BIN names one).
export MOD="${AGENTBUS_BIN:-$BIN}"
# Python helpers every case below imports: load the module, snapshot a bus without touching it.
cat > "$T/h.py" <<'PY'
import hashlib, importlib.machinery, importlib.util, os, sqlite3, sys
from urllib.parse import quote

def load():
    loader = importlib.machinery.SourceFileLoader("agentbus_mod", os.environ["MOD"])
    spec = importlib.util.spec_from_loader("agentbus_mod", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m

def sha(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except FileNotFoundError:
        return None

def ro(db):
    # immutable: no lock, no -shm, no -wal; the bus file is read as it is on disk.
    return sqlite3.connect("file:" + quote(db) + "?mode=ro&immutable=1", uri=True)

def dump(db):
    c = ro(db)
    try:
        tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        rows = {t: c.execute(f'SELECT * FROM "{t}" ORDER BY rowid').fetchall() for t in tables}
        return {"user_version": c.execute("PRAGMA user_version").fetchone()[0],
                "schema": c.execute("SELECT type, name, sql FROM sqlite_master ORDER BY type, name").fetchall(), "rows": rows}
    finally:
        c.close()

def state(db):
    """Everything a write could change: the bytes of the bus and its sidecars, and every row."""
    return {"db": sha(db), "wal": sha(db + "-wal"), "shm": sha(db + "-shm"), "dump": dump(db) if os.path.exists(db) else None}

def logical(db):
    """What a read-only command must leave as it was: every row, the schema, user_version, and the
    bus folder's listing apart from SQLite's own -wal and -shm (a read may finish a crashed writer's
    recovery, which folds the -wal into bus.db)."""
    import shutil, tempfile
    d = os.path.dirname(db)
    names = sorted(n for n in os.listdir(d) if not n.endswith(("-wal", "-shm")))
    # Read a copy (with its -wal), so this check itself opens nothing in the bus folder.
    tmp = tempfile.mkdtemp()
    for suffix in ("", "-wal"):
        if os.path.exists(db + suffix):
            shutil.copyfile(db + suffix, os.path.join(tmp, "bus.db" + suffix))
    c = sqlite3.connect(os.path.join(tmp, "bus.db"))
    try:
        tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        rows = {t: c.execute(f'SELECT * FROM "{t}" ORDER BY rowid').fetchall() for t in tables}
        return {"names": names, "user_version": c.execute("PRAGMA user_version").fetchone()[0],
                "schema": c.execute("SELECT type, name, sql FROM sqlite_master ORDER BY type, name").fetchall(), "rows": rows}
    finally:
        c.close()
        shutil.rmtree(tmp, ignore_errors=True)

def refused(fn):
    """The error code and message of a die() inside fn, or None when fn returned."""
    try:
        fn()
    except SystemExit as e:
        return e.code.code, e.code.msg
    return None
PY
export PYTHONPATH="$T"
uv() { "$PY" -c 'import sys,h; print(h.dump(sys.argv[1])["user_version"])' "$1"; }

# A v0.1.0 bus with rows in every table: two agents, a direct message, a broadcast, a read cursor,
# a claim, a fact and its history.
make_v010() {
  mkdir -p "$1"
  AGENTBUS_DB="$1/bus.db" "$PY" "$OLD" --as claude join --role lead >/dev/null
  AGENTBUS_DB="$1/bus.db" "$PY" "$OLD" --as codex join --role hand >/dev/null
  AGENTBUS_DB="$1/bus.db" "$PY" "$OLD" --as claude post "to codex" --to codex --kind handoff >/dev/null
  AGENTBUS_DB="$1/bus.db" "$PY" "$OLD" --as claude post "to everyone" >/dev/null
  AGENTBUS_DB="$1/bus.db" "$PY" "$OLD" --as codex inbox >/dev/null
  AGENTBUS_DB="$1/bus.db" "$PY" "$OLD" --as claude post "unread" --to codex >/dev/null
  AGENTBUS_DB="$1/bus.db" "$PY" "$OLD" --as codex claim src/app.py --purpose fix >/dev/null
  AGENTBUS_DB="$1/bus.db" "$PY" "$OLD" --as claude ctx set style "stdlib only" >/dev/null
}

echo "TEST 1: a new bus is stamped schema 1"
mkdir -p "$T/new"
AGENTBUS_DB="$T/new/bus.db" agentbus --as a join >/dev/null
[ "$(uv "$T/new/bus.db")" = 1 ] || fail "a new bus has user_version $(uv "$T/new/bus.db"), not 1"
ok "a new bus is stamped schema 1"

echo "TEST 2: a v0.1.0 bus is adopted: rows, cursors and claims identical, version 1, no backup"
make_v010 "$T/v010"
[ "$(uv "$T/v010/bus.db")" = 0 ] || fail "the v0.1.0 fixture copy stamped a version"
"$PY" -c 'import json,sys,h; json.dump(h.dump(sys.argv[1]), open(sys.argv[2], "w"))' "$T/v010/bus.db" "$T/before.json"
AGENTBUS_DB="$T/v010/bus.db" agentbus claims >/dev/null   # any write open adopts it (who, status and read only read)
"$PY" - "$T/v010/bus.db" "$T/before.json" <<'PY' || fail "adoption changed more than the version stamp"
import json, sys, h
before = json.load(open(sys.argv[2]))
after = json.loads(json.dumps(h.dump(sys.argv[1])))
assert after["user_version"] == 1, after["user_version"]
assert after["rows"] == before["rows"], "rows changed"
assert after["schema"] == before["schema"], "schema objects changed"
assert len(after["rows"]["claims"]) == 1 and len(after["rows"]["cursors"]) >= 1
PY
[ ! -e "$T/v010/backups" ] || fail "adoption made a backups directory"
o=$(AGENTBUS_DB="$T/v010/bus.db" outof agentbus --as codex inbox --peek)
grep -qF "unread" <<<"$o" || fail "the adopted bus lost codex's unread message: $o"
ok "a v0.1.0 bus is adopted with only the version stamp written"

echo "TEST 3: a bus at version 1 opens with no write"
"$PY" -c 'import json,sys,h; json.dump(h.state(sys.argv[1]), open(sys.argv[2], "w"))' "$T/v010/bus.db" "$T/s1.json"
AGENTBUS_DB="$T/v010/bus.db" agentbus who >/dev/null
AGENTBUS_DB="$T/v010/bus.db" agentbus claims >/dev/null
"$PY" - "$T/v010/bus.db" "$T/s1.json" <<'PY' || fail "a current bus was written by a read command"
import json, sys, h
before, after = json.load(open(sys.argv[2])), json.loads(json.dumps(h.state(sys.argv[1])))
assert before == after, "bytes or rows changed"
PY
ok "a current bus is opened without a write"

echo "TEST 3b: on a clean current bus, watch and who, status and read without a name leave bus.db byte-identical and create no -shm"
CB="$T/current"; mkdir -p "$CB"; agentbus init "$CB" >/dev/null
(cd "$CB" && agentbus --as a join >/dev/null && agentbus --as a post "hello" >/dev/null && agentbus --as a claim x >/dev/null)
# A clean bus (every writer closed, so nothing waits in -wal): a read has no crashed writer's journal to
# recover, so bus.db keeps its bytes; the logical comparison is only for that crashed-writer case (TEST 5b).
bytes_state() { "$PY" -c 'import os,sys,h; print(h.sha(sys.argv[1]), os.path.lexists(sys.argv[1] + "-shm"), os.listdir(os.path.dirname(sys.argv[1])))' "$1"; }
[ ! -e "$CB/.agentbus/bus.db-shm" ] || fail "the fixture already has a -shm"
before=$(bytes_state "$CB/.agentbus/bus.db")
for cmd in "watch --once" "watch --json" who status read; do
  (cd "$CB" && "${AB[@]}" $cmd >/dev/null 2>"$T/err") || fail "$cmd failed: $(cat "$T/err")"
  [ "$(bytes_state "$CB/.agentbus/bus.db")" = "$before" ] || fail "$cmd changed bus.db's bytes or the folder (a -shm?): $before -> $(bytes_state "$CB/.agentbus/bus.db")"
done
ok "watch, and who, status and read without a name, leave a clean current bus byte-identical, with no -shm"

echo "TEST 4: a bus with user_version 2 is refused as schema_newer on every open mode, and is unchanged"
mkdir -p "$T/newer"
seed "$T/newer" hello
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=2"); c.close()' "$T/newer/bus.db"
"$PY" -c 'import json,sys,h; json.dump(h.state(sys.argv[1]), open(sys.argv[2], "w"))' "$T/newer/bus.db" "$T/n.json"
rc=0; err=$(AGENTBUS_DB="$T/newer/bus.db" "${AB[@]}" --as a --json who 2>&1 >/dev/null) || rc=$?
[ "$rc" = 3 ] || fail "a newer bus: exit $rc, not 3 (the bus is unavailable): $err"
printf '%s' "$err" > "$T/err.json"
"$PY" - "$T/err.json" "$T/newer" <<'PY' || fail "schema_newer JSON error: $err"
import json, sys
e = json.load(open(sys.argv[1]))["error"]
bus = sys.argv[2] + "/bus.db"
assert e["code"] == "schema_newer", e
assert e["message"] == ("this bus is newer than this copy of agentbus (schema 2, this copy knows 1). "
                        f"Use a newer agentbus: agentbus upgrade {sys.argv[2]} from an up-to-date install"), e["message"]
assert e["bus"] == bus and e["bus_schema"] == 2 and e["tool_schema"] == 1, e
PY
"$PY" - "$T/newer/bus.db" "$T/n.json" <<'PY' || fail "migrate=False or read-only on a newer bus"
import json, sys, h
m = h.load()
db = sys.argv[1]
for kw in ({}, {"migrate": False}, {"read_only": True}):
    r = h.refused(lambda: m.open_bus(db, **kw).close())
    assert r and r[0] == "schema_newer", (kw, r)
assert json.load(open(sys.argv[2])) == json.loads(json.dumps(h.state(db))), "a refused newer bus changed"
PY
ok "schema_newer: refused with the exact message and fields by write, migrate=False and read-only opens; bus unchanged"

echo "TEST 4b: a user_version no agentbus writes (negative, or absurdly large) is refused as schema_corrupt, not as newer"
for v in -1 2147483647; do
  d="$T/garbage$v"; mkdir -p "$d"; seed "$d" hello
  "$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=%d" % int(sys.argv[2])); c.close()' "$d/bus.db" "$v"
  "$PY" -c 'import json,sys,h; json.dump(h.state(sys.argv[1]), open(sys.argv[2], "w"))' "$d/bus.db" "$T/g.json"
  "$PY" - "$d/bus.db" "$v" <<'PY' || fail "user_version $v"
import sys, h
m = h.load()
for kw in ({}, {"migrate": False}, {"read_only": True}):
    r = h.refused(lambda: m.open_bus(sys.argv[1], **kw).close())
    assert r and r[0] == "schema_corrupt", (kw, r)
    assert f"schema version {sys.argv[2]}" in r[1] and "newer" not in r[1], r[1]
PY
  "$PY" -c 'import json,sys,h; assert json.load(open(sys.argv[2])) == json.loads(json.dumps(h.state(sys.argv[1])))' "$d/bus.db" "$T/g.json" || fail "user_version $v: the bus changed"
done
ok "a negative or absurd user_version is schema_corrupt on every open mode, and the bus is unchanged"

echo "TEST 5: a read-only open of a clean bus keeps bus.db's bytes and makes no -shm, on a current bus, a v0.1.0 bus and a claim that needs normalizing; a bus that needs migration is refused"
make_v010 "$T/ro_v010"
mkdir -p "$T/ro_cur"; seed "$T/ro_cur" current
make_v010 "$T/ro_norm"
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO claims VALUES(?,?,?,?,?)", ("./lib//x.py","codex","p","2026-01-01T00:00:00Z","2999-01-01T00:00:00Z")); c.commit(); c.close()' "$T/ro_norm/bus.db"
mkdir -p "$T/ro_mig"; seed "$T/ro_mig" "needs migration"
"$PY" - "$T" <<'PY' || fail "read-only open wrote"
import json, sys, h
T = sys.argv[1]
m = h.load()
import os
for name in ("ro_cur", "ro_v010", "ro_norm"):
    db = f"{T}/{name}/bus.db"
    # clean buses (no crashed writer): bus.db's bytes stay and no -shm appears. ro_norm was last written by
    # Python's sqlite3, which on macOS's system SQLite leaves its own -shm behind; that one must stay as it was.
    before = json.loads(json.dumps(h.logical(db))), h.sha(db), h.sha(db + "-shm")
    con = m.open_bus(db, read_only=True)
    try:
        n = con.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        assert n >= 1, (name, n)
        w = h.refused(lambda: con.execute("INSERT INTO log(ts,agent,action) VALUES('t','x','y')"))
    except Exception as e:
        w = e
    finally:
        con.close()
    assert "readonly" in str(w).replace(" ", "").lower() or "query_only" in str(w).lower() or "attempt to write" in str(w), (name, w)
    after = json.loads(json.dumps(h.logical(db))), h.sha(db), h.sha(db + "-shm")
    assert before == after, f"{name}: bus.db's bytes, a -shm, rows, schema, version or files changed"
# A bus that needs a migration: the version-1 bus, opened by a tool that knows version 2.
m.SCHEMA_VERSION = 2
m.MIGRATIONS[1] = ["ALTER TABLE log ADD COLUMN extra TEXT"]
db = f"{T}/ro_mig/bus.db"
before = json.loads(json.dumps(h.state(db)))
for kw in ({"read_only": True}, {"migrate": False}):
    r = h.refused(lambda: m.open_bus(db, **kw).close())
    assert r and r[0] == "schema_older", (kw, r)
    assert r[1] == ("this bus is older than this agentbus (schema 1, needs 2). Any agentbus command that is not watch "
                    f"upgrades it after taking a backup, or run: agentbus upgrade {T}/ro_mig"), r[1]
    assert json.loads(json.dumps(h.state(db))) == before, f"{kw}: a bus that needs migration was written"
PY
ok "read-only opens leave bytes and rows as they were and refuse writes; read-only and migrate=False refuse a bus that needs migration as schema_older"

echo "TEST 5b: a crashed writer's committed rows are read by watch --once, who, status, read and --dry-run, which change no row, schema, version or file"
# A writer that commits a row into -wal and exits without checkpointing (os._exit, autocheckpoint off).
cat > "$T/walwriter.py" <<'PY'
import os, sqlite3, sys
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("INSERT INTO agents(name,joined_at,last_seen) VALUES('walwriter','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
c.execute("INSERT INTO messages(ts,sender,body) VALUES('2026-01-01T00:00:00Z','walwriter','in the wal')")
os._exit(0)
PY
wal_bus() {  # wal_bus DIR: a v0.1.0 bus, then a crashed writer's frames in its -wal
  mkdir -p "$1"; "$PY" "$OLD" init "$1" >/dev/null; (cd "$1" && "$PY" .agentbus/bin/agentbus --as a post "first" >/dev/null)
  "$PY" "$T/walwriter.py" "$1/.agentbus/bus.db"
  rm -f "$1/.agentbus/bus.db-shm"   # agentbus writers never make one
  [ -s "$1/.agentbus/bus.db-wal" ] || fail "the writer left no -wal frames"
}
logical_state() { "$PY" -c 'import json,sys,h; print(json.dumps(h.logical(sys.argv[1])))' "$1"; }
PB="$T/pending"; wal_bus "$PB"
before=$(logical_state "$PB/.agentbus/bus.db")
for cmd in "watch --once" who status read; do
  o=$(cd "$PB" && "${AB[@]}" $cmd 2>"$T/err") || fail "$cmd over a crashed writer's -wal failed: $(cat "$T/err")"
  case $cmd in who) want=walwriter ;; *) want="in the wal" ;; esac
  grep -qF "$want" <<<"$o" || fail "$cmd does not show the crashed writer's committed rows: $o"
  [ "$(logical_state "$PB/.agentbus/bus.db")" = "$before" ] || fail "$cmd changed rows, schema, version or files"
done
o=$(cd "$T" && "${AB[@]}" upgrade --all "$PB" --dry-run 2>&1) || fail "dry-run failed: $o"
grep -qF "would upgrade 1, current 0, skipped 0, failed 0" <<<"$o" || fail "dry-run: $o"
[ "$(logical_state "$PB/.agentbus/bus.db")" = "$before" ] || fail "--dry-run changed rows, schema, version or files"
[ ! -e "$PB/.agentbus/bus.db-shm" ] || fail "a read created bus.db-shm"
ok "a crashed writer's rows are read; no row, schema, version or file (other than SQLite's -wal) changes"

echo "TEST 5c: a hard link or symlink at bus.db-wal or bus.db-shm is refused for reads exactly as for writes, and a victim is never written"
for at in wal shm; do
  for how in hard sym; do
    HB="$T/plant-$at-$how"; mkdir -p "$HB"; (cd "$HB" && "$PY" "$OLD" init . >/dev/null && "$PY" .agentbus/bin/agentbus --as a post x >/dev/null)
    head -c 4000 /dev/urandom > "$T/victim-$at-$how"; v0=$(shasum -a 256 "$T/victim-$at-$how")
    rm -f "$HB/.agentbus/bus.db-$at"
    if [ $how = hard ]; then ln "$T/victim-$at-$how" "$HB/.agentbus/bus.db-$at"; else ln -s "$T/victim-$at-$how" "$HB/.agentbus/bus.db-$at"; fi
    for cmd in "--json read" "--json watch --once" "--json --as a post y"; do
      rc=0; (cd "$HB" && "${AB[@]}" $cmd >/dev/null 2>"$T/err") || rc=$?
      [ "$rc" != 0 ] || fail "$cmd accepted a $how link at bus.db-$at"
      "$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="bus_unavailable" and ("bus.db-"+sys.argv[2]) in e["message"], e' "$T/err" "$at" \
        || fail "$cmd, $how link at -$at: $(cat "$T/err")"
    done
    [ "$(shasum -a 256 "$T/victim-$at-$how")" = "$v0" ] || fail "the victim behind a $how link at bus.db-$at was written"
  done
done
ok "links at -wal and -shm: reads and writes refuse them alike (bus_unavailable, named); victims untouched"

echo "TEST 5d: a lane swapping a hard link to a victim in at bus.db-shm or bus.db-wal never gets the victim written"
for at in shm wal; do
  HB="$T/hard-$at"; wal_bus "$HB"
  head -c 40000 /dev/urandom > "$T/victim-$at"; v0=$(shasum -a 256 "$T/victim-$at")
  "$PY" - "$HB/.agentbus/bus.db-$at" "$T/victim-$at" "$T/stop-$at" <<'PY' & LANE=$!
import os, sys, time
target, victim, stop = sys.argv[1:]
saved = target + ".saved"
if os.path.exists(target):
    os.rename(target, saved)
while not os.path.exists(stop):
    try:
        os.link(victim, target + ".x"); os.rename(target + ".x", target)
        time.sleep(0.0005)
        os.unlink(target)
        if os.path.exists(saved):
            os.link(saved, target)
        time.sleep(0.0005)
        if os.path.exists(saved):
            os.unlink(target)
    except OSError:
        pass
PY
  for i in $(seq 30); do
    (cd "$HB" && "${AB[@]}" --json read >/dev/null 2>"$T/err") || true
    grep -q Traceback "$T/err" && fail "a traceback beside the $at swap: $(cat "$T/err")"
  done
  touch "$T/stop-$at"; wait $LANE
  [ "$(shasum -a 256 "$T/victim-$at")" = "$v0" ] || fail "the victim linked in at bus.db-$at was written"
done
ok "hard links swapped in at -shm and -wal: the victims are byte-identical"

echo "TEST 5e: 100 reads beside a posting loop: no read and no post fails"
RB="$T/readloop"; mkdir -p "$RB"; agentbus init "$RB" >/dev/null; (cd "$RB" && agentbus --as w join >/dev/null)
(cd "$RB" && for i in $(seq 60); do "${AB[@]}" --as w post "p$i" >/dev/null 2>>"$T/post.err" || echo "post $i failed" >>"$T/post.fail"; done) & POSTER=$!
fails=0
for i in $(seq 100); do
  (cd "$RB" && "${AB[@]}" read >/dev/null 2>>"$T/read.err") || fails=$((fails+1))
done
wait $POSTER
[ "$fails" = 0 ] || fail "$fails of 100 reads failed beside the posting loop: $(tail -3 "$T/read.err")"
[ ! -e "$T/post.fail" ] || fail "posts failed beside the reads: $(cat "$T/post.fail") $(tail -3 "$T/post.err")"
ok "100 reads and 60 posts side by side, zero errors"

echo "TEST 5g: a file a lane hard-linked or swapped is reported as bus_unavailable naming it, not as an internal error"
LK="$T/linked"; mkdir -p "$LK"; (cd "$LK" && "$PY" "$OLD" init . >/dev/null && "$PY" .agentbus/bin/agentbus --as a post x >/dev/null)
printf x > "$LK/.agentbus/bus.db-shm"; ln "$LK/.agentbus/bus.db-shm" "$T/shm-second-link"
rc=0; (cd "$LK" && "${AB[@]}" --json read >/dev/null 2>"$T/err") || rc=$?
[ "$rc" = 3 ] || fail "a hard-linked -shm: exit $rc, not 3 (bus_unavailable)"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="bus_unavailable" and "bus.db-shm" in e["message"] and "hard links" in e["message"], e' "$T/err" || fail "hard link: $(cat "$T/err")"
ok "a refused bus file is bus_unavailable, named"

echo "TEST 6: read-only open never creates a bus; watch on a bus folder nothing wrote yet shows it empty and creates nothing"
mkdir -p "$T/none"
"$PY" - "$T/none/bus.db" "$T/gone/bus.db" <<'PY' || fail "read-only open of a missing bus"
import os, sys, h
m = h.load()
none, gone = sys.argv[1:]
before = sorted(os.listdir(os.path.dirname(none)))
for db in (none, gone):
    r = h.refused(lambda: m.open_bus(db, read_only=True).close())
    assert r and r[0] == "no_bus", r
assert sorted(os.listdir(os.path.dirname(none))) == before == [], "files appeared in the bus folder"
assert not os.path.lexists(os.path.dirname(gone)), "the missing folder was created"
PY
o=$(AGENTBUS_DB="$T/none/bus.db" outof agentbus watch --once)
grep -qF "no one yet" <<<"$o" || fail "watch on an unwritten bus: $o"
[ -z "$(ls -A "$T/none")" ] || fail "watch created files: $(ls -A "$T/none")"
ok "a missing bus is no_bus to a read-only open and is never created, by watch either"

echo "TEST 7: busy_wait 0.3 gives busy within 1 s while a connection holds the bus, for writes and reads alike"
mkdir -p "$T/busy"; seed "$T/busy" x
"$PY" - "$T/busy/bus.db" "$T" <<'PY' || fail "busy_wait"
import os, sqlite3, subprocess, sys, time, h
db, T = sys.argv[1:]
m = h.load()
def hold(exclusive_mode, mark):
    code = ("import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1], isolation_level=None); "
            + ("c.execute('PRAGMA locking_mode=EXCLUSIVE'); " if exclusive_mode else "")
            + "c.execute('BEGIN EXCLUSIVE'); c.execute(\"INSERT INTO log(ts,agent,action) VALUES('t','holder','x')\"); "
            "open(sys.argv[2],'w').close(); time.sleep(30)")
    p = subprocess.Popen([sys.executable, "-c", code, db, mark])
    for _ in range(200):
        if os.path.exists(mark):
            break
        time.sleep(0.05)
    return p
def timed(kw):
    t0 = time.monotonic()
    r = h.refused(lambda: m.open_bus(db, busy_wait=0.3, hold=1.0, **kw).close())
    return r, time.monotonic() - t0
# A sqlite3 shell's write transaction (shared locking): writers wait, readers read.
p = hold(False, T + "/held1")
try:
    r, took = timed({})
    assert r and r[0] == "busy" and "stayed busy for 0.3 seconds" in r[1] and took < 1.0, (r, took)
    r, took = timed({"read_only": True})
    assert r and r[0] == "busy" and took < 1.0, (r, took)  # reads open as writers do
finally:
    p.kill(); p.wait()
# Another agentbus command (exclusive locking holds the file): both wait, then busy.
p = hold(True, T + "/held2")
try:
    for kw in ({"read_only": True}, {}):
        r, took = timed(kw)
        assert r and r[0] == "busy" and "stayed busy for 0.3 seconds" in r[1] and took < 1.0, (kw, r, took)
finally:
    p.kill(); p.wait()
PY
ok "busy_wait 0.3 gives busy in under a second, for writes and reads alike"

echo "TEST 7b: the busy wait runs on the monotonic clock: a wall clock that jumps forward or back neither ends it early nor extends it"
mkdir -p "$T/busy7b"; seed "$T/busy7b" x
"$PY" - "$T/busy7b/bus.db" "$T" <<'PY' || fail "busy wait on a jumping wall clock"
import os, sqlite3, subprocess, sys, time, h
db, T = sys.argv[1:]
m = h.load()
def hold(seconds, mark):
    code = ("import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1], isolation_level=None); c.execute('BEGIN EXCLUSIVE'); "
            "open(sys.argv[2],'w').close(); time.sleep(float(sys.argv[3]))")
    p = subprocess.Popen([sys.executable, "-c", code, db, mark, str(seconds)])
    for _ in range(200):
        if os.path.exists(mark):
            return p
        time.sleep(0.05)
    p.kill(); raise AssertionError("the holder never took the bus")
real = time.time
def jumping(offset):
    """time.time() that reads true on its first call and `offset` seconds off on every call after."""
    calls = [0]
    def fake():
        calls[0] += 1
        return real() if calls[0] == 1 else real() + offset
    return fake
try:
    # forward an hour: a wall-clock deadline is past at once and the open gives up busy, with the bus free in 1.5 s
    p = hold(1.5, T + "/h-fwd"); time.time = jumping(3600); t0 = real()
    con = m.open_bus(db, busy_wait=8.0, hold=4.0)
    took = real() - t0; con.close()
    assert 1.0 < took < 6.0, took
    p.wait()
    # back an hour: a wall-clock deadline never comes and the open waits for the 3 s holder; busy_wait 0.3 must give up busy
    p = hold(3, T + "/h-back"); time.time = jumping(-3600); t0 = real()
    r = h.refused(lambda: m.open_bus(db, busy_wait=0.3, hold=1.0).close())
    took = real() - t0
    assert r and r[0] == "busy" and took < 1.0, (r, took)
    p.kill(); p.wait()
finally:
    time.time = real
PY
ok "the busy wait counts monotonic time: an hour's jump of the wall clock, either way, changes nothing"

echo "TEST 7c: every open sets PRAGMA synchronous=FULL itself, whatever default the SQLite build has"
mkdir -p "$T/sync7c"; seed "$T/sync7c" x
"$PY" - "$T/sync7c/bus.db" <<'PY' || fail "synchronous pragma"
import sqlite3, sys, h
db = sys.argv[1]
m = h.load()
seen = []
execute = sqlite3.Connection.execute
def spy(self, sql, *a, **k):
    if isinstance(sql, str) and sql.upper().startswith("PRAGMA SYNCHRONOUS"):
        seen.append(sql)
    return execute(self, sql, *a, **k)
m.Bus.execute = spy
for kw in ({}, {"read_only": True}):
    del seen[:]
    con = m.open_bus(db, **kw)
    try:
        assert seen == ["PRAGMA synchronous=FULL"], (kw, seen)
        assert con.execute("PRAGMA synchronous").fetchone()[0] == 2, kw
    finally:
        con.close()
PY
ok "a write open and a read-only open both set synchronous=FULL"

echo "TEST 8: hold bounds how long an open may keep the bus"
"$PY" - "$T/busy/bus.db" <<'PY' || fail "hold"
import subprocess, sys, time, h
db = sys.argv[1]
code = ("import sys,time,h; m=h.load(); c=m.open_bus(sys.argv[1], read_only=True, busy_wait=0.3, hold=1.0); time.sleep(10)")
t0 = time.monotonic()
p = subprocess.run([sys.executable, "-c", code, db], capture_output=True, text=True, timeout=30)
took = time.monotonic() - t0
assert p.returncode != 0, p
assert "held the bus for 1 s" in p.stderr, p.stderr
assert took < 4, took
PY
ok "a read-only open with hold 1.0 is stopped after 1 s"

# ---- migrations, backups and restore ----
# The synthetic cases inject into the loaded module exactly what a release that changes the schema
# would ship: a new SCHEMA, SCHEMA_VERSION and a MIGRATIONS entry (or a HISTORY entry). v2.py is that
# tool as a command: this checkout's agentbus, one schema version ahead.
cat >> "$T/h.py" <<'PY'

def v2(m):
    """Version 2: log gains a column."""
    old = "action TEXT NOT NULL, detail TEXT);"
    assert old in m.SCHEMA
    m.SCHEMA = m.SCHEMA.replace(old, "action TEXT NOT NULL, detail TEXT, extra TEXT);")
    m.SCHEMA_VERSION = 2
    m.MIGRATIONS[1] = ["ALTER TABLE log ADD COLUMN extra TEXT"]
    m.reference_shapes.cache_clear()
    m.reference_indexes.cache_clear()
    return m

# The shape before v0.1.0 (no messages.request_id, no cursors.bcast_from), as upgrade_bus.py found it,
# and its statements. Synthetic: built here from SCHEMA, never shipped.
def pre010_schema(m):
    s = m.SCHEMA.replace(", request_id TEXT);", ");").replace(",\n  bcast_from INTEGER NOT NULL DEFAULT 0);", ");")
    s = "\n".join(l for l in s.split("\n") if "idx_messages_request" not in l)
    assert "request_id" not in s and "bcast_from" not in s, s
    return s

PRE010_STEPS = ["ALTER TABLE cursors ADD COLUMN bcast_from INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE messages ADD COLUMN request_id TEXT",
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_request ON messages(sender, request_id) WHERE request_id IS NOT NULL"]

def with_pre010(m, base):
    """base: the module before any synthetic change, whose SCHEMA the old shape is cut from."""
    m.HISTORY.append({"name": "pre-0.1.0", "schema": pre010_schema(base), "steps": PRE010_STEPS})
    return m

def backups(db):
    d = os.path.join(os.path.dirname(db), "backups")
    return sorted(n for n in os.listdir(d) if n.endswith(".db")) if os.path.isdir(d) else []

def migrate_rows(db):
    c = ro(db)
    try:
        return c.execute("SELECT detail FROM log WHERE agent='agentbus' AND action='migrate'").fetchall()
    finally:
        c.close()
PY
cat > "$T/v2.py" <<'PY'
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import h
m = h.v2(h.load())
if os.environ.get("WITH_PRE010"):
    h.with_pre010(m, h.load())
sys.argv = ["agentbus"] + sys.argv[1:]
m.cli()
PY
V2=("$PY" "$T/v2.py")
v1_bus() { mkdir -p "$1"; AGENTBUS_DB="$1/bus.db" agentbus --as a join >/dev/null; AGENTBUS_DB="$1/bus.db" agentbus --as a post "before" >/dev/null; }

echo "TEST 9: HISTORY has exactly the shapes PROVENANCE.md lists, each captured shape migrates, and SCHEMA_V1 is v0.1.0's SCHEMA"
"$PY" - "$TESTS_DIR/fixtures/schema" "$T" <<'PY' || fail "captured shapes"
import glob, os, re, sqlite3, sys, h
m = h.load()
fixtures = sorted(glob.glob(sys.argv[1] + "/*.sql"))
assert sorted(e["name"] for e in m.HISTORY) == sorted(os.path.basename(f)[:-4] for f in fixtures), "HISTORY and the fixtures differ"
prov = open(sys.argv[1] + "/PROVENANCE.md").read()
# Both ways: a row in PROVENANCE.md's Shapes table with no fixture file is a shape that never runs (0 fixtures passes only
# while the table lists none).
shapes = prov.split("## Shapes", 1)[1].split("\n## ", 1)[0]
listed = re.findall(r"^\| `([^`]+\.sql)` \|", shapes, re.M)
assert sorted(listed) == sorted(os.path.basename(f) for f in fixtures), ("PROVENANCE.md's Shapes table and the fixtures differ", listed)
for f in fixtures:
    name = os.path.basename(f)
    assert f"`{name}`" in prov, f"{name} is not in PROVENANCE.md"
    db = f"{sys.argv[2]}/hist-{name}/bus.db"
    os.makedirs(os.path.dirname(db))
    c = sqlite3.connect(db); c.executescript(open(f).read()); c.execute("PRAGMA journal_mode=WAL"); c.close()
    con = m.open_bus(db)
    try:
        assert m.user_version(con) == m.SCHEMA_VERSION and con.migrated and con.migrated["backup"], name
    finally:
        con.close()
# With no captured shape (HISTORY ships empty until one is dumped) the loop above runs nothing, and nothing is claimed for
# it; the historical migration path itself runs in TEST 10 on a synthetic shape.
if fixtures:
    print(f"{len(fixtures)} captured shape(s) migrated")
# Version 1 is v0.1.0's shape, kept as SCHEMA_V1 however SCHEMA changes later.
loader = __import__("importlib.machinery").machinery.SourceFileLoader("agentbus_010", sys.argv[1] + "/../legacy/agentbus-0.1.0")
spec = __import__("importlib.util").util.spec_from_loader("agentbus_010", loader)
old = __import__("importlib.util").util.module_from_spec(spec); loader.exec_module(old)
assert m.SCHEMA_V1 == old.SCHEMA, "SCHEMA_V1 is not v0.1.0's SCHEMA"
PY
ok "HISTORY, the fixture files and PROVENANCE.md's Shapes table name the same shapes, and SCHEMA_V1 is v0.1.0's SCHEMA"

echo "TEST 10: a historical shape migrates, keeps every row, leaves a 0600 backup of the old rows, and every agent's inbox is the one the old delivery rule gives"
mkdir -p "$T/pre"
"$PY" - "$T/pre/bus.db" <<'PY' || fail "building the pre-0.1.0 bus"
import sqlite3, sys, h
m = h.load()
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.executescript(h.pre010_schema(m))
c.execute("PRAGMA journal_mode=WAL")
t = "2026-10-01T00:00:00Z"
for n in ("lead", "hand", "late"):
    c.execute("INSERT INTO agents(name,joined_at,last_seen) VALUES(?,?,?)", (n, t, t))
msgs = [("lead", "*"), ("lead", "hand"), ("hand", "lead"), ("lead", "*"), ("hand", "*"), ("lead", "late"), ("late", "*"), ("lead", "hand")]
for i, (s, r) in enumerate(msgs, 1):
    c.execute("INSERT INTO messages(ts,sender,recipient,kind,body) VALUES(?,?,?,?,?)", (t, s, r, "note", f"m{i}"))
c.executemany("INSERT INTO cursors(agent,last_read_id) VALUES(?,?)", [("lead", 3), ("hand", 1), ("late", 6)])
c.execute("INSERT INTO claims VALUES('src/a.py','hand','p',?, '2999-01-01T00:00:00Z')", (t,))
c.execute("INSERT INTO context VALUES('k','v','lead',?)", (t,))
c.close()
PY
"$PY" -c 'import json,sys,h; json.dump(h.dump(sys.argv[1]), open(sys.argv[2], "w"))' "$T/pre/bus.db" "$T/pre.json"
# Expected inboxes by the delivery rule before bcast_from: unread (id > last_read_id), not one's own,
# addressed to the agent or to everyone.
for n in lead hand late; do
  "$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(" ".join(str(r[0]) for r in c.execute("SELECT id FROM messages WHERE id > (SELECT last_read_id FROM cursors WHERE agent=?) AND sender<>? AND recipient IN (?, \"*\") ORDER BY id", (sys.argv[2],)*3)))' "$T/pre/bus.db" $n > "$T/want-$n"
done
expect_fail "schema_refused" env AGENTBUS_DB="$T/pre/bus.db" "${AB[@]}" --json who   # this release ships no such HISTORY entry
rc=0; AGENTBUS_DB="$T/pre/bus.db" WITH_PRE010=1 "${V2[@]}" who >/dev/null 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "migration failed: $(cat "$T/err")"
"$PY" - "$T/pre/bus.db" "$T/pre.json" <<'PY' || fail "after the migration"
import json, os, stat, sqlite3, sys, h
db = sys.argv[1]
before, after = json.load(open(sys.argv[2])), json.loads(json.dumps(h.dump(db)))
assert after["user_version"] == 2, after["user_version"]
for t in ("agents", "claims", "context", "context_history"):
    assert after["rows"][t] == before["rows"][t], t
assert [r[:8] for r in after["rows"]["messages"]] == before["rows"]["messages"], "messages changed"
assert all(r[8] is None for r in after["rows"]["messages"]), "request_id not empty"
assert [r[:2] for r in after["rows"]["cursors"]] == before["rows"]["cursors"] and all(r[2] == 0 for r in after["rows"]["cursors"])
assert before["rows"]["log"] == [tuple(r[:5]) for r in after["rows"]["log"][:len(before["rows"]["log"])]]
b = h.backups(db)
assert len(b) == 1 and b[0].startswith("bus-v0-"), b
path = os.path.join(os.path.dirname(db), "backups", b[0])
st = os.lstat(path)
assert stat.S_IMODE(st.st_mode) == 0o600 and stat.S_ISREG(st.st_mode) and st.st_nlink == 1, oct(st.st_mode)
assert stat.S_IMODE(os.lstat(os.path.dirname(path)).st_mode) == 0o700
assert json.loads(json.dumps(h.dump(path))) == before, "the backup does not hold the old bus"
assert h.migrate_rows(db) == [(f"v0 -> v2, backup {b[0]}",)], h.migrate_rows(db)
PY
for n in lead hand late; do
  got=$(AGENTBUS_DB="$T/pre/bus.db" WITH_PRE010=1 "${V2[@]}" --json --as $n inbox --peek | "$PY" -c 'import json,sys; print(" ".join(str(m["id"]) for m in json.load(sys.stdin)["items"]))')
  [ "$got" = "$(cat "$T/want-$n")" ] || fail "$n's inbox after the migration: [$got], old rule: [$(cat "$T/want-$n")]"
done
ok "the pre-0.1.0 shape migrates with its rows, a 0600 backup of them, one log row, and the same inboxes"

echo "TEST 11: an unknown shape (extra column, planted trigger, dropped table) is refused, byte-identical, with no backups"
for kind in column trigger table; do
  d="$T/unknown-$kind"; mkdir -p "$d"
  AGENTBUS_DB="$d/bus.db" "$PY" "$OLD" --as a post "x" >/dev/null
  case $kind in
    column) sql="ALTER TABLE claims ADD COLUMN extra TEXT" ;;
    trigger) sql="CREATE TRIGGER t AFTER INSERT ON messages BEGIN DELETE FROM messages; END" ;;
    table) sql="DROP TABLE context_history" ;;
  esac
  "$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2]); c.commit(); c.close()' "$d/bus.db" "$sql"
  "$PY" -c 'import json,sys,h; json.dump(h.state(sys.argv[1]), open(sys.argv[2], "w"))' "$d/bus.db" "$T/u.json"
  for tool in AB V2; do
    if [ $tool = AB ]; then cmd=("${AB[@]}"); else cmd=("${V2[@]}"); fi
    expect_fail "bus schema is not agentbus's" env AGENTBUS_DB="$d/bus.db" WITH_PRE010=1 "${cmd[@]}" --as a post "y"
  done
  "$PY" -c 'import json,sys,h; assert json.load(open(sys.argv[2])) == json.loads(json.dumps(h.state(sys.argv[1])))' "$d/bus.db" "$T/u.json" || fail "$kind: the refused bus changed"
  [ ! -e "$d/backups" ] || fail "$kind: a refused bus got a backups directory"
done
ok "unknown shapes are refused as today, unchanged, with no backup"

echo "TEST 12: a synthetic MIGRATIONS[1] runs through the mechanism: backup, ALTER, verify, stamp 2"
v1_bus "$T/m1"
"$PY" -c 'import json,sys,h; json.dump(h.dump(sys.argv[1]), open(sys.argv[2], "w"))' "$T/m1/bus.db" "$T/m1.json"
o=$(AGENTBUS_DB="$T/m1/bus.db" outof "${V2[@]}" --json who)
"$PY" - "$T/m1/bus.db" "$T/m1.json" <<'PY' || fail "synthetic migration"
import json, sqlite3, sys, h
db = sys.argv[1]
after = h.dump(db)
assert after["user_version"] == 2
c = h.ro(db); cols = [r[1] for r in c.execute("PRAGMA table_info(log)")]; c.close()
assert cols[-1] == "extra", cols
b = h.backups(db)
assert len(b) == 1 and b[0].startswith("bus-v1-"), b
assert json.loads(json.dumps(h.dump(f"{sys.argv[1][:-7]}/backups/{b[0]}"))) == json.load(open(sys.argv[2]))
assert h.migrate_rows(db) == [(f"v1 -> v2, backup {b[0]}",)]
PY
ok "MIGRATIONS[1]: one backup of the version-1 bus, the column added, version 2, one log row"

echo "TEST 13: two simultaneous first opens make one backup and one migrate log row"
v1_bus "$T/race"
P="$T/pause-race"; mkdir -p "$P"
AGENTBUS_DB="$T/race/bus.db" agentbus --as b join >/dev/null
AGENTBUS_DB="$T/race/bus.db" AGENTBUS_TEST_PAUSE="after-checkpoint=$P" "${V2[@]}" --as a post one >/dev/null 2>"$T/e1" & A=$!
wait_for "$P/after-checkpoint.reached"
AGENTBUS_DB="$T/race/bus.db" "${V2[@]}" --as b post two >/dev/null 2>"$T/e2" & B=$!
sleep 0.5
touch "$P/after-checkpoint.go"
wait $A || fail "first opener failed: $(cat "$T/e1")"
wait $B || fail "second opener failed: $(cat "$T/e2")"
"$PY" -c 'import sys,h; db=sys.argv[1]; b=h.backups(db); r=h.migrate_rows(db); assert len(b)==1 and len(r)==1, (b, r)' "$T/race/bus.db" || fail "race: more than one backup or log row"
ok "concurrent first opens: one backup, one migration"

echo "TEST 14: only the newest 5 backups are kept, never the one just taken; a stale .partial is removed"
v1_bus "$T/keep"; B="$T/keep/backups"; mkdir -m 700 "$B"
planted="20200101T000001Z 20200101T000002Z 20200101T000003Z 20200101T000004Z 20200101T000005Z 20200101T000006Z"
for s in $planted; do (umask 077; printf x > "$B/bus-v1-$s.db"); done
(umask 077; printf x > "$B/bus-v1-20200101T000000Z.db.partial"; printf x > "$B/bus-v1-20990101T000000Z.db.partial"; printf x > "$B/notes.txt")
touch -t 202001010000 "$B/bus-v1-20200101T000000Z.db.partial"
ln -s "$T/victim" "$B/bus-v1-20000101T000000Z.db"; printf keep > "$T/victim"
for s in 20200101T000001Z 20200101T000003Z; do (umask 077; printf c > "$B/agentbus-$s"; printf v > "$B/VERSION-$s"); done
AGENTBUS_DB="$T/keep/bus.db" "${V2[@]}" who >/dev/null || fail "migration with old backups failed"
[ ! -e "$B/agentbus-20200101T000001Z" ] && [ ! -e "$B/VERSION-20200101T000001Z" ] || fail "a pruned backup's kept copy stayed"
[ -e "$B/agentbus-20200101T000003Z" ] && [ -e "$B/VERSION-20200101T000003Z" ] || fail "a kept backup lost its copy"
got=$(cd "$B" && ls | tr '\n' ' ')
# The backup this run took: the one regular bus-v1-*.db file that was not planted.
fresh=$("$PY" -c 'import os,sys; p=sys.argv[2].split(); print("\n".join(n for n in sorted(os.listdir(sys.argv[1])) if n.startswith("bus-v1-") and n.endswith(".db") and not os.path.islink(os.path.join(sys.argv[1], n)) and n[7:-3] not in p))' "$B" "$planted")
[ "$(printf '%s\n' "$fresh" | grep -c .)" = 1 ] || fail "not exactly one fresh backup: [$fresh] in $got"
for f in "$fresh" bus-v1-20200101T000003Z.db bus-v1-20200101T000004Z.db bus-v1-20200101T000005Z.db bus-v1-20200101T000006Z.db \
         bus-v1-20990101T000000Z.db.partial notes.txt; do
  [ -e "$B/$f" ] || fail "$f was removed: $got"
done
[ -L "$B/bus-v1-20000101T000000Z.db" ] || fail "a planted link was removed: $got"
for f in bus-v1-20200101T000001Z.db bus-v1-20200101T000002Z.db bus-v1-20200101T000000Z.db.partial; do
  [ ! -e "$B/$f" ] || fail "$f was kept: $got"
done
[ "$(cat "$T/victim")" = keep ] || fail "a link in backups/ was followed"
# Five backups stamped later than now (a clock that was ahead, or copied in): the one just taken
# still stays, and the migrate log row names a file that exists.
v1_bus "$T/later"; L="$T/later/backups"; mkdir -m 700 "$L"
for s in 20990101T000001Z 20990101T000002Z 20990101T000003Z 20990101T000004Z 20990101T000005Z; do (umask 077; printf x > "$L/bus-v1-$s.db"); done
AGENTBUS_DB="$T/later/bus.db" "${V2[@]}" who >/dev/null || fail "migration beside later-stamped backups failed"
"$PY" - "$T/later/bus.db" <<'PY' || fail "the backup just taken was pruned: $(ls "$L")"
import os, sys, h
db = sys.argv[1]
rows = h.migrate_rows(db)
assert len(rows) == 1, rows
name = rows[0][0].rsplit("backup ", 1)[1]
path = os.path.join(os.path.dirname(db), "backups", name)
assert os.path.isfile(path) and h.dump(path)["user_version"] == 1, (name, sorted(os.listdir(os.path.dirname(path))))
assert len([n for n in os.listdir(os.path.dirname(path)) if n.endswith(".db")]) == 5
PY
ok "newest 5 kept and never the one just taken; an hour-old .partial removed; fresh partials, other files and links left alone"

echo "TEST 14b: a migration stopped by Ctrl-C before its commit keeps every backup that was there (pruning waits for the commit)"
# Bug it catches: old backups were pruned while the backup was taken, before the migration committed, so a stopped
# upgrade (rolled back, bus still at schema 1) had already deleted the oldest backup and nothing could bring it back.
"$PY" - "$T" "$PY" "$T/v2.py" <<'PY' || fail "a stopped migration pruned an old backup"
import json, os, signal, sqlite3, subprocess, sys, time
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
T = sys.argv[1]
V2 = tuple(sys.argv[2:4])
d = os.path.join(T, "prune-intr"); os.makedirs(d)
run = lambda args, cwd: subprocess.run([*agentbus_argv(), *args], cwd=cwd, capture_output=True, text=True, timeout=60)
assert run(["init", d], T).returncode == 0 and run(["--as", "a", "join"], d).returncode == 0 and run(["--as", "a", "post", "before"], d).returncode == 0
b = os.path.join(d, ".agentbus", "backups"); os.mkdir(b, 0o700)
planted = ["bus-v1-2026010%dT000000Z.db" % i for i in range(1, 6)]
for i, n in enumerate(planted):
    fd = os.open(os.path.join(b, n), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, b"backup %d" % i); os.close(fd)
before = sorted(os.listdir(b))
pause = os.path.join(T, "pause-prune"); os.mkdir(pause)
p = subprocess.Popen([*V2, "--json", "upgrade", d], cwd=T, env=dict(os.environ, AGENTBUS_TEST_PAUSE="before-commit=" + pause),
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
end = time.time() + 30
while not os.path.exists(os.path.join(pause, "before-commit.reached")):
    assert time.time() < end and p.poll() is None, ("never reached", p.communicate())
    time.sleep(0.02)
p.send_signal(signal.SIGINT)
out, err = p.communicate(timeout=30)
e = json.loads(err)["error"]
assert p.returncode == 130 and out == "" and e["code"] == "interrupted" and e["committed"] is False, (p.returncode, out, err)
c = sqlite3.connect(os.path.join(d, ".agentbus", "bus.db")); v = c.execute("PRAGMA user_version").fetchone()[0]; c.close()
assert v == 1, v
assert sorted(os.listdir(b)) == before, ("backups changed", before, sorted(os.listdir(b)))
# The rerun commits, and only then prunes: its own backup and the newest four planted ones stay.
r = subprocess.run([*V2, "upgrade", d], cwd=T, capture_output=True, text=True, timeout=60)
assert r.returncode == 0, r.stderr
left = sorted(n for n in os.listdir(b) if n.endswith(".db"))
assert len(left) == 5 and planted[0] not in left and set(planted[1:]) <= set(left), left
PY
ok "Ctrl-C before the commit: exit 130, committed false, schema 1, all five old backups kept; the rerun prunes after its commit"

echo "TEST 15: backup safety: a link planted at the backup name is never followed; backups/ swapped for a link mid-copy writes nothing into its target"
v1_bus "$T/link"; mkdir -m 700 "$T/link/backups"; printf victim > "$T/victim2"
"$PY" - "$T/link/backups" "$T/victim2" <<'PY'
import os, sys, time
t = time.time()
for k in range(-2, 8):
    s = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(t + k))
    for suffix in (".db", ".db.partial"):
        os.symlink(sys.argv[2], f"{sys.argv[1]}/bus-v1-{s}{suffix}")
PY
AGENTBUS_DB="$T/link/bus.db" "${V2[@]}" who >/dev/null || fail "migration beside planted links failed"
[ "$(cat "$T/victim2")" = victim ] || fail "a planted link at the backup name was followed"
[ "$("$PY" -c 'import sys,h; print(len([b for b in h.backups(sys.argv[1]) if not __import__("os").path.islink(sys.argv[1][:-6]+"backups/"+b)]))' "$T/link/bus.db")" = 1 ] || fail "no real backup beside the links"
v1_bus "$T/swap"; mkdir -p "$T/target"; P="$T/pause-swap"; mkdir -p "$P"
AGENTBUS_DB="$T/swap/bus.db" AGENTBUS_TEST_PAUSE="mid-copy=$P" "${V2[@]}" who >/dev/null 2>"$T/e" & A=$!
wait_for "$P/mid-copy.reached"
mv "$T/swap/backups" "$T/swap/backups.moved"; ln -s "$T/target" "$T/swap/backups"
touch "$P/mid-copy.go"
rc=0; wait $A || rc=$?
[ "$rc" = 0 ] || fail "the migration with backups/ swapped mid-copy failed: $(cat "$T/e")"
[ -z "$(ls -A "$T/target")" ] || fail "the copy wrote into the swapped-in link's target: $(ls -A "$T/target")"
[ "$(cd "$T/swap/backups.moved" && ls bus-v1-*.db | wc -l | tr -d ' ')" = 1 ] || fail "the backup is not in the folder that was opened: $(ls -A "$T/swap/backups.moved")"
ok "planted links are not followed; a swapped backups/ cannot redirect the copy"

echo "TEST 16: backup failure (ENOSPC, not enough free space) leaves the bus byte-identical, no partial, code backup_failed"
for how in enospc space; do
  v1_bus "$T/fail-$how"
  "$PY" -c 'import json,sys,h; json.dump(h.state(sys.argv[1]), open(sys.argv[2], "w"))' "$T/fail-$how/bus.db" "$T/f.json"
  rc=0; AGENTBUS_DB="$T/fail-$how/bus.db" AGENTBUS_TEST_BACKUP_FAIL=$how "${V2[@]}" --json --as a post x >/dev/null 2>"$T/err" || rc=$?
  [ "$rc" = 3 ] || fail "$how: exit $rc, not 3 (backup_failed); did the migration go ahead?"
  "$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="backup_failed" and e["reason"], e' "$T/err" || fail "$how: $(cat "$T/err")"
  [ $how != space ] || grep -qF "not enough free space for a backup; free" "$T/err" || fail "space: $(cat "$T/err")"
  "$PY" -c 'import json,sys,h; assert json.load(open(sys.argv[2])) == json.loads(json.dumps(h.state(sys.argv[1])))' "$T/fail-$how/bus.db" "$T/f.json" || fail "$how: the bus changed"
  [ -z "$(ls -A "$T/fail-$how/backups" 2>/dev/null)" ] || fail "$how: left $(ls -A "$T/fail-$how/backups")"
done
ok "a failed backup changes nothing and says backup_failed"

echo "TEST 16b: a backup is published only if it is the file that was written and checked, byte for byte"
# A copy that differs from the bus (a bad write) is refused, not published.
v1_bus "$T/corrupt"
"$PY" -c 'import json,sys,h; json.dump(h.state(sys.argv[1]), open(sys.argv[2], "w"))' "$T/corrupt/bus.db" "$T/c.json"
rc=0; AGENTBUS_DB="$T/corrupt/bus.db" AGENTBUS_TEST_BACKUP_FAIL=corrupt "${V2[@]}" --json who >/dev/null 2>"$T/err" || rc=$?
[ "$rc" = 3 ] || fail "a corrupted copy: exit $rc, not 3 (backup_failed); was it accepted as the backup?"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="backup_failed" and "does not match" in e["message"], e' "$T/err" || fail "corrupt: $(cat "$T/err")"
"$PY" -c 'import json,sys,h; assert json.load(open(sys.argv[2])) == json.loads(json.dumps(h.state(sys.argv[1])))' "$T/corrupt/bus.db" "$T/c.json" || fail "corrupt: the bus changed"
[ -z "$(ls "$T/corrupt/backups" | grep -v partial || true)" ] || fail "corrupt: a backup was published: $(ls "$T/corrupt/backups")"
# The partial swapped for garbage mid-copy, and a good file planted at the final name: the garbage is
# never published over it, and nothing is migrated.
v1_bus "$T/bind"; P="$T/pause-bind"; mkdir -p "$P"
AGENTBUS_DB="$T/bind/bus.db" AGENTBUS_TEST_PAUSE="mid-copy=$P" "${V2[@]}" --json who >/dev/null 2>"$T/err" & A=$!
wait_for "$P/mid-copy.reached"
part=$(cd "$T/bind/backups" && ls *.partial)
mv "$T/bind/backups/$part" "$T/bind/real.partial"
(umask 077; printf garbage > "$T/bind/backups/$part"; printf GOOD > "$T/bind/backups/${part%.partial}")
touch "$P/mid-copy.go"
rc=0; wait $A || rc=$?
[ "$rc" != 0 ] || fail "a swapped partial was published and the migration went ahead"
[ "$(cat "$T/bind/backups/${part%.partial}")" = GOOD ] || fail "the file at the backup name was replaced"
"$PY" -c 'import sys,h; d=h.dump(sys.argv[1]); assert d["user_version"]==1 and not h.migrate_rows(sys.argv[1]), d["user_version"]' "$T/bind/bus.db" || fail "bind: the bus was migrated without its backup"
ok "a copy that differs from the bus, or a partial swapped mid-copy, is never published and nothing is migrated"

echo "TEST 17: kill -9 at after-checkpoint, mid-copy, after-backup and before-commit: the next open migrates, one valid backup, no log row from the dead run"
for point in after-checkpoint mid-copy after-backup before-commit; do
  v1_bus "$T/kill-$point"; P="$T/pause-$point"; mkdir -p "$P"
  AGENTBUS_DB="$T/kill-$point/bus.db" AGENTBUS_TEST_PAUSE="$point=$P" "${V2[@]}" --as a post x >/dev/null 2>&1 & A=$!
  wait_for "$P/$point.reached"
  kill -9 $A; wait $A 2>/dev/null || true
  AGENTBUS_DB="$T/kill-$point/bus.db" "${V2[@]}" who >/dev/null || fail "$point: the next open failed"
  "$PY" - "$T/kill-$point/bus.db" <<'PY' || fail "after kill at $point"
import sys, h
db = sys.argv[1]
d = h.dump(db)
assert d["user_version"] == 2, d["user_version"]
b = h.backups(db)
assert len(b) == 1, b
assert h.dump(f"{db[:-7]}/backups/{b[0]}")["user_version"] == 1
assert len(h.migrate_rows(db)) == 1, h.migrate_rows(db)
assert [r for r in d["rows"]["messages"] if r[6] == "x"] == [], "the dead run's post was kept"
PY
done
ok "a migration killed at any point is redone once, from one valid backup"

echo "TEST 18: the backup budget: AGENTBUS_TEST_DEADLINE shortens MIGRATE_BUDGET_S and the migration fails closed"
v1_bus "$T/budget"
"$PY" -c 'import json,sys,h; json.dump(h.state(sys.argv[1]), open(sys.argv[2], "w"))' "$T/budget/bus.db" "$T/b.json"
rc=0; AGENTBUS_DB="$T/budget/bus.db" AGENTBUS_TEST_DEADLINE=0.5 AGENTBUS_TEST_SLOW=1 "${V2[@]}" --json who >/dev/null 2>"$T/err" || rc=$?
[ "$rc" = 3 ] || fail "the budget: exit $rc, not 3 (backup_failed); did the migration run past it?"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="backup_failed" and "did not finish within 0.5 s" in e["message"], e' "$T/err" || fail "budget: $(cat "$T/err")"
"$PY" -c 'import json,sys,h; assert json.load(open(sys.argv[2])) == json.loads(json.dumps(h.state(sys.argv[1])))' "$T/budget/bus.db" "$T/b.json" || fail "budget: the bus changed"
[ -z "$(ls -A "$T/budget/backups" 2>/dev/null)" ] || fail "budget: left $(ls -A "$T/budget/backups")"
ok "past its budget the migration stops before writing, with no partial left"

echo "TEST 18b: a migration never holds the bus longer than other agents wait for it"
"$PY" -c 'import h; m=h.load(); t=m.MIGRATE_BUDGET_S + m.HOLD_GRACE_S + m.UNDO_LOCK_WAIT_S + m.EXIT_GRACE_S; assert t + 1 < m.BUSY_WAIT_S, (t, m.BUSY_WAIT_S)' \
  || fail "a stopped migration (budget, hold grace, undo lock wait, exit grace) does not end at least 1 s inside BUSY_WAIT_S"
v1_bus "$T/slowmig"; AGENTBUS_DB="$T/slowmig/bus.db" agentbus --as b join >/dev/null
P="$T/pause-slow"; mkdir -p "$P"
AGENTBUS_DB="$T/slowmig/bus.db" AGENTBUS_TEST_SLOW=60 AGENTBUS_TEST_PAUSE="after-checkpoint=$P" "${V2[@]}" who >/dev/null 2>"$T/e1" & A=$!
wait_for "$P/after-checkpoint.reached"
touch "$P/after-checkpoint.go"
start=$SECONDS
rc=0; AGENTBUS_DB="$T/slowmig/bus.db" "${V2[@]}" --as b post "waited" >/dev/null 2>"$T/e2" || rc=$?
took=$((SECONDS-start))
wait $A 2>/dev/null || true
[ "$rc" = 0 ] || fail "an agent waiting on a slow migration gave up after ${took}s: $(cat "$T/e2")"
grep -qF "did not finish within" "$T/e1" || fail "the slow migration was not stopped by its budget: $(cat "$T/e1")"
"$PY" -c 'import sys,h; db=sys.argv[1]; assert h.dump(db)["user_version"] == 2 and len(h.migrate_rows(db)) == 1' "$T/slowmig/bus.db" || fail "the waiting agent did not migrate the bus once"
ok "a slow migration is stopped inside the 15 s others wait; the waiting agent then migrates and posts"

echo "TEST 18c: the watchdog never undoes a migration that has committed"
"$PY" - "$T" <<'PY' || fail "undo after commit"
import os, sys, h
m = h.load()
d = os.path.join(sys.argv[1], "undo-check"); os.makedirs(d)
open(os.path.join(d, "bus-v1-x.db"), "w").close()
u = m._Undo(); u.dfd = os.open(d, os.O_RDONLY); u.names = ["bus-v1-x.db"]
with u.lock:
    u.committed = True
u.run()
assert os.path.exists(os.path.join(d, "bus-v1-x.db")), "a committed migration's backup was removed"
u.committed = False
u.run()
assert not os.path.exists(os.path.join(d, "bus-v1-x.db")), "an uncommitted migration's backup stayed"
u.close()
# Ctrl-C arriving while COMMIT runs: the commit and its flag still land together, so the undo that
# follows the KeyboardInterrupt keeps the backup of the migrated bus.
import signal, sqlite3
class C(sqlite3.Connection):
    def execute(self, sql, *a):
        r = super().execute(sql, *a)
        if sql == "COMMIT":
            os.kill(os.getpid(), signal.SIGINT)
        return r
con = sqlite3.connect(os.path.join(d, "db"), isolation_level=None, factory=C)
con.execute("CREATE TABLE t(x)")
open(os.path.join(d, "bus-v1-y.db"), "w").close()
u = m._Undo(); u.dfd = os.open(d, os.O_RDONLY); u.names = ["bus-v1-y.db"]
try:
    with m.immediate(con, guard=u):
        con.execute("PRAGMA user_version=2")
except KeyboardInterrupt:
    pass
if not u.committed:
    u.run()
u.close()
assert sqlite3.connect(os.path.join(d, "db")).execute("PRAGMA user_version").fetchone()[0] == 2
assert u.committed and os.path.exists(os.path.join(d, "bus-v1-y.db")), "Ctrl-C during COMMIT lost the backup of a migrated bus"
PY
ok "undo after COMMIT removes nothing, also when Ctrl-C arrives during COMMIT; before COMMIT it removes the run's files"

echo "TEST 18d: Ctrl-C once upgrade's migration has committed is the interrupted error naming the migration, its backup and the rerun"
"$PY" - "$T" "$PY" "$T/v2.py" <<'PY' || fail "Ctrl-C after a committed migration under upgrade"
import json, os, signal, subprocess, sys, time
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
T = sys.argv[1]
V2 = tuple(sys.argv[2:4])  # this checkout's agentbus with schema 2 (v2.py), under $PY
def run(args, cwd, **env):
    return subprocess.run([*agentbus_argv(), *args], cwd=cwd, env=dict(os.environ, **env), capture_output=True, text=True, timeout=60)
# point: where the SIGINT lands. commit: while the migration's COMMIT is held (Ctrl-C is delivered after it);
# before-install: after the commit, before the copy is replaced.
for point in ("commit", "before-install"):
    for js in (True, False):
        d = os.path.join(T, "intr-%s-%d" % (point, js)); os.makedirs(d)
        assert run(["init", d], T).returncode == 0
        assert run(["--as", "a", "join"], d).returncode == 0 and run(["--as", "a", "post", "before"], d).returncode == 0
        pause = os.path.join(T, "pause-%s-%d" % (point, js)); os.makedirs(pause)
        env = dict(os.environ, AGENTBUS_TEST_PAUSE="%s=%s" % (point, pause))
        p = subprocess.Popen([*V2, *(["--json"] if js else []), "upgrade", d], cwd=T, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
        end = time.time() + 30
        while not os.path.exists(os.path.join(pause, point + ".reached")):
            assert time.time() < end and p.poll() is None, (point, "never reached", p.communicate())
            time.sleep(0.02)
        p.send_signal(signal.SIGINT)
        time.sleep(0.3)
        open(os.path.join(pause, point + ".go"), "w").close()
        out, err = p.communicate(timeout=30)
        backups = sorted(n for n in os.listdir(os.path.join(d, ".agentbus", "backups")) if n.endswith(".db"))
        assert len(backups) == 1 and backups[0].startswith("bus-v1-"), backups
        backup = os.path.join(os.path.realpath(d), ".agentbus", "backups", backups[0])
        rerun = "agentbus upgrade " + os.path.realpath(d)
        assert p.returncode == 130 and out == "", (point, js, p.returncode, out, err)
        assert "schema 1 -> 2" in err and backup in err and "Run: " + rerun + " to finish" in err, (point, js, err)
        if js:
            e = json.loads(err)["error"]
            assert e["code"] == "interrupted" and e["committed"] is True and e["retryable"] is False, e
            assert e["backup"] == backup and e["rerun"] == rerun and e["directory"] == os.path.realpath(d), e
            assert e["migrations"] == [{"directory": os.path.realpath(d), "schema_old": 1, "schema_new": 2, "backup": backup}], e
        else:
            assert "Traceback" not in err and "The command's change was saved before this." in err, err
        # the bus is migrated; running the named command again finishes the job and migrates nothing twice
        r = subprocess.run([*V2, "upgrade", d], cwd=T, capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, r.stderr
        assert sorted(n for n in os.listdir(os.path.join(d, ".agentbus", "backups")) if n.endswith(".db")) == backups
PY
ok "a Ctrl-C at or after the migration's commit: exit 130, committed true, the migration, its backup and the rerun named, in both modes"

echo "TEST 19: restore, following docs/how-to/upgrade.md word for word after a real upgrade"
DOC="$(cd "$TESTS_DIR/.." && pwd)/docs/how-to/upgrade.md"
R="$T/restore"; mkdir -p "$R" "$T/oc"; cp "$OLD" "$T/oc/agentbus"; "$PY" "$T/oc/agentbus" init "$R" >/dev/null
(cd "$R" && "$PY" .agentbus/bin/agentbus --as a join >/dev/null && "$PY" .agentbus/bin/agentbus --as a post "pre-migration" >/dev/null)
(cd "$R" && "${AB[@]}" claims >/dev/null)   # adopted (a write open): version 1, the folder's copy is still 0.1.0
"$PY" -c 'import json,sys,h; d=h.dump(sys.argv[1]); json.dump(d["rows"], open(sys.argv[2], "w"))' "$R/.agentbus/bus.db" "$T/r.json"
(cd "$R" && "$PY" .agentbus/bin/agentbus --json status > "$T/status-before.json")
cp "$R/.agentbus/bin/agentbus" "$T/copy.before"; cp "$R/.agentbus/VERSION" "$T/version.before"
(cd "$T" && "${V2[@]}" upgrade "$R" >/dev/null) || fail "the upgrade failed"   # copy replaced, bus migrated with a backup
! cmp -s "$R/.agentbus/bin/agentbus" "$T/copy.before" || fail "upgrade did not replace the copy"
(cd "$R" && "${V2[@]}" --as a post "after the backup" >/dev/null)
name=$(cd "$R/.agentbus/backups" && ls bus-v*.db)
N=$(printf '%s' "$name" | sed -n 's/^bus-v\([0-9]*\)-.*\.db$/\1/p'); STAMP=$(printf '%s' "$name" | sed -n 's/^bus-v[0-9]*-\(.*\)\.db$/\1/p')
[ "$N" = 1 ] && [ -n "$STAMP" ] || fail "backup name: $name"
# Every command in the doc's restore section, in order, with only N and STAMP filled in.
"$PY" - "$DOC" > "$T/restore.sh" <<'PY'
import re, sys
section = open(sys.argv[1]).read().split("## Restore a backup", 1)[1]
cmds = [l.strip() for block in re.findall(r"```\n(.*?)```", section, re.S) for l in block.splitlines() if l.strip()]
assert any("bus-vN-STAMP.db" in c for c in cmds) and any("agentbus-STAMP" in c for c in cmds), cmds
assert any("bus.db-wal" in c for c in cmds) and any("bus.db-shm" in c for c in cmds), "the -wal and -shm are not moved aside"
print("\n".join(cmds))
PY
sed -e "s/bus-vN-STAMP/bus-v$N-$STAMP/g" -e "s/STAMP/$STAMP/g" "$T/restore.sh" > "$T/restore1.sh"
(umask 077; printf 'stale' > "$R/.agentbus/bus.db-shm")   # as a foreign tool's connection would leave one
(cd "$R" && bash -e "$T/restore1.sh" >/dev/null) || fail "the documented restore failed: $(cat "$T/restore1.sh")"
[ ! -e "$R/.agentbus/bus.db-shm" ] && [ "$(cat "$R/.agentbus/bus.db.broken-shm")" = stale ] || fail "the -shm was not moved aside"
cmp -s "$R/.agentbus/bin/agentbus" "$T/copy.before" && cmp -s "$R/.agentbus/VERSION" "$T/version.before" || fail "the copy that wrote the backup is not back"
(cd "$R" && "$PY" .agentbus/bin/agentbus --json status > "$T/status-after.json") || fail "the restored copy cannot read the restored bus"
cmp -s "$T/status-before.json" "$T/status-after.json" || fail "status differs after restore: $(diff "$T/status-before.json" "$T/status-after.json")"
"$PY" -c 'import json,sys,h; assert json.loads(json.dumps(h.dump(sys.argv[1])["rows"])) == json.load(open(sys.argv[2]))' "$R/.agentbus/bus.db" "$T/r.json" || fail "restored rows differ"
"$PY" -c 'import sys,h; assert any("after the backup" in str(r) for r in h.dump(sys.argv[1])["rows"]["messages"])' "$R/.agentbus/bus.db.broken" || fail "the row written after the backup is not in bus.db.broken"
# The folder's copy keeps using the restored bus; nothing migrates it again.
(cd "$R" && "$PY" .agentbus/bin/agentbus --as a post "on the restored bus" >/dev/null) || fail "the restored copy cannot write"
"$PY" -c 'import sys,h; db=sys.argv[1]; assert h.dump(db)["user_version"] == 1 and len(h.backups(db)) == 1' "$R/.agentbus/bus.db" || fail "the restored bus was migrated again by its own copy"
# A newer agentbus migrates it again on its next write, with a new backup.
(cd "$R" && "${V2[@]}" who >/dev/null) || fail "the new tool cannot migrate the restored bus"
"$PY" -c 'import sys,h; db=sys.argv[1]; assert h.dump(db)["user_version"] == 2 and len(h.backups(db)) == 2 and len(h.migrate_rows(db)) == 1' "$R/.agentbus/bus.db" || fail "the restored bus was not migrated afresh"
ok "the doc's restore, run as written after a real upgrade, brings back the bus and the copy that wrote it; later rows stay in bus.db.broken"

echo "All schema tests passed"
