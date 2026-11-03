#!/usr/bin/env bash
# upgrade --all DIR: every bus folder under DIR gets this tool's copy and a migrated or stamped
# database; each is reported; a failure never stops the rest.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$(cd "$T" && pwd -P)/home"; mkdir -p "$HOME"
cd "$T"
mkdir -p "$T/old"; cp "$TESTS_DIR/fixtures/legacy/agentbus-0.1.0" "$T/old/agentbus"
OLD="$T/old/agentbus"
counts() {  # counts DB: messages claims facts
  "$PY" -c 'import sqlite3,sys; c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro&immutable=1", uri=True); print(*[c.execute(f"select count(*) from {t}").fetchone()[0] for t in ("messages","claims","context")])' "$1"
}
uv() { "$PY" -c 'import sqlite3,sys; c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro&immutable=1", uri=True); print(c.execute("pragma user_version").fetchone()[0])' "$1"; }
# A bus made by the v0.1.0 copy, with rows: the copy installed by init, data written by that copy.
old_bus() {
  mkdir -p "$1"; "$PY" "$OLD" init "$1" >/dev/null
  (cd "$1" && "$PY" .agentbus/bin/agentbus --as a join >/dev/null && "$PY" .agentbus/bin/agentbus --as a post "hello from $(basename "$1")" >/dev/null \
    && "$PY" .agentbus/bin/agentbus --as a claim src/x.py --purpose p >/dev/null \
    && "$PY" .agentbus/bin/agentbus --as a ctx set k v >/dev/null)
}
tree_sum() { (cd "$1" && find . -print0 | sort -z | xargs -0 ls -ld | awk '{print $1, $5, $NF}'; find . -type f -print0 | sort -z | xargs -0 shasum) ; }

W="$HOME/src"
old_bus "$W/alpha"
old_bus "$W/beta"
old_bus "$W/beta/nested"                       # a bus inside another bus's folder
mkdir -p "$W/cur"; agentbus init "$W/cur" >/dev/null; (cd "$W/cur" && agentbus --as a join >/dev/null && agentbus --as a post "current" >/dev/null)
old_bus "$W/linked"; mv "$W/linked/.agentbus/bin/agentbus" "$T/elsewhere"; ln -s "$T/elsewhere" "$W/linked/.agentbus/bin/agentbus"
old_bus "$W/locked"
mkdir -p "$W/node_modules/dep"; old_bus "$W/node_modules/dep"   # skipped folder: never walked
before_alpha=$(counts "$W/alpha/.agentbus/bus.db")

echo "TEST 1: --dry-run leaves the tree byte-identical and says what it would do"
tree_sum "$W" > "$T/t1"
rc=0; o=$(agentbus upgrade --all "$W" --dry-run 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "--dry-run with a failing bus exited $rc: $o"
tree_sum "$W" > "$T/t2"
cmp -s "$T/t1" "$T/t2" || fail "--dry-run changed the tree: $(diff "$T/t1" "$T/t2" | head)"
grep -qF "~/src/alpha" <<<"$o" && grep -qF "would upgrade" <<<"$o" || fail "--dry-run output: $o"
ok "--dry-run changes nothing"

echo "TEST 2: a tree of buses (two at 0.1.0 with data, one nested, one current, one with a symlinked bin/agentbus, one held busy) reports each, upgrades the rest and exits 1"
"$PY" -c "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1], isolation_level=None); c.execute('BEGIN EXCLUSIVE'); open(sys.argv[2],'w').close(); time.sleep(60)" \
  "$W/locked/.agentbus/bus.db" "$T/held" & HOLDER=$!
while [ ! -e "$T/held" ]; do sleep 0.05; done
start=$SECONDS
rc=0; agentbus upgrade --all "$W" >"$T/out" 2>"$T/err" || rc=$?
took=$((SECONDS-start))
kill $HOLDER 2>/dev/null || true; wait $HOLDER 2>/dev/null || true
[ "$took" -lt 12 ] || fail "upgrade --all waited ${took}s on a busy bus (each bus gets 5 s)"
[ "$rc" = 1 ] || fail "upgrade --all exited $rc with a failed bus: $(cat "$T/out" "$T/err")"
o=$(cat "$T/out")
line() { grep -E "^$(printf '%s' "$1" | sed 's/[.[\*^$/]/\\&/g') +" <<<"$o" || fail "no line for $1: $o"; }
line "~/src/alpha" | grep -qE "(0\.1\.0 -> .+|current \(.*\))   schema 0 -> 1$" || fail "alpha: $(line '~/src/alpha')"
line "~/src/beta" | grep -qE "schema 0 -> 1$" || fail "beta: $o"
line "~/src/beta/nested" | grep -qE "schema 0 -> 1$" || fail "nested: $o"
line "~/src/cur" | grep -qE "current \(" || fail "cur: $o"
line "~/src/linked" | grep -qF "failed: refusing" || fail "linked: $o"
line "~/src/locked" | grep -qF "failed: busy. Close any sqlite3 shell or dashboard holding it, then retry." || fail "locked: $o"
if grep -qF node_modules <<<"$o"; then fail "walked into node_modules: $o"; fi
[ "$(tail -n 1 <<<"$o")" = "upgraded 3, current 1, skipped 0, failed 2" ] || fail "summary: $(tail -n 1 <<<"$o")"
for b in alpha beta beta/nested; do
  [ "$(uv "$W/$b/.agentbus/bus.db")" = 1 ] || fail "$b not stamped"
  cmp -s "$W/$b/.agentbus/bin/agentbus" "${AGENTBUS_BIN:-$BIN}" || [ -n "${AGENTBUS_CMD:-}" ] || fail "$b copy not replaced"
  [ ! -e "$W/$b/.agentbus/backups" ] || fail "$b: an adopted bus got a backup"
done
[ "$(counts "$W/alpha/.agentbus/bus.db")" = "$before_alpha" ] || fail "row counts changed"
[ "$(uv "$W/locked/.agentbus/bus.db")" = 0 ] || fail "the busy bus was written"
[ -L "$W/linked/.agentbus/bin/agentbus" ] && cmp -s "$T/elsewhere" "$OLD" || fail "the symlinked copy or its target was written"
ok "every bus reported; adopted ones stamped with no backup; the busy and the linked one failed without a write; exit 1"

echo "TEST 3: --json parses and its counts equal the human summary; a second run finds them current"
rc=0; o=$(agentbus upgrade --all "$W" --json 2>"$T/err") || rc=$?
[ "$rc" = 1 ] || fail "--json run exited $rc"
printf '%s' "$o" > "$T/j"
"$PY" - "$T/j" "$W" <<'PY' || fail "--json: $o"
import json, sys
j = json.load(open(sys.argv[1]))
st = {r["directory"][len(sys.argv[2]) + 1:]: r for r in j["buses"]}
assert set(st) == {"alpha", "beta", "beta/nested", "cur", "linked", "locked"}, sorted(st)
for k in ("upgraded", "current", "skipped", "failed"):
    assert j[k] == sum(1 for r in j["buses"] if r["status"] == k), k
assert (j["upgraded"], j["current"], j["skipped"], j["failed"]) == (1, 4, 0, 1), j
for r in j["buses"]:
    assert set(r) == {"directory", "status", "old", "new", "schema_old", "schema_new", "backup", "error"}, r
    assert r["error"] is None or set(r["error"]) >= {"code", "message"}, r
assert st["locked"]["status"] == "upgraded" and st["locked"]["schema_old"] == 0 and st["locked"]["schema_new"] == 1
assert st["linked"]["status"] == "failed" and st["linked"]["error"]["code"] == "bus_unavailable"
assert st["alpha"]["status"] == "current" and st["alpha"]["schema_old"] == 1 == st["alpha"]["schema_new"]
PY
ok "--json counts match its rows; current buses report current"

echo "TEST 4: a bus whose copy is newer is skipped, not downgraded"
mkdir -p "$W/newer"; old_bus "$W/newer"; printf '99.0.0\n' > "$W/newer/.agentbus/VERSION"
cp "$W/newer/.agentbus/bin/agentbus" "$T/newer.copy"
o=$(agentbus upgrade --all "$W/newer" 2>&1 || true)
grep -qF "skipped: copy is newer (99.0.0)" <<<"$o" || fail "newer copy: $o"
cmp -s "$W/newer/.agentbus/bin/agentbus" "$T/newer.copy" || fail "a newer copy was replaced"
[ "$(uv "$W/newer/.agentbus/bus.db")" = 0 ] || fail "a skipped bus was written"
ok "a newer copy is left alone"

echo "TEST 5: --depth limits the walk; upgrade --all refuses from a project copy"
mkdir -p "$W/deep/a/b/c"; old_bus "$W/deep/a/b/c"
o=$(agentbus upgrade --all "$W/deep" --depth 2 --dry-run) || fail "--depth 2: $o"
[ "$o" = "would upgrade 0, current 0, skipped 0, failed 0" ] || fail "--depth 2 found a bus 3 levels down, or printed something else: $o"
o=$(outof agentbus upgrade --all "$W/deep" --depth 3 --dry-run)
grep -qF "~/src/deep/a/b/c" <<<"$o" || fail "--depth 3 missed it: $o"
expect_fail "this is a project copy" "$PY" "$W/cur/.agentbus/bin/agentbus" upgrade --all "$W"
ok "--depth bounds the walk; a project copy refuses"

echo "TEST 6: the first-time developer's transcript: a 0.1.0 folder upgraded by a 0.2.0 tool, then a migration with its backup"
# This checkout's file stamped 0.2.0, outside any git checkout (so the copy it installs says 0.2.0),
# and the same tool one schema version ahead (log gains a column), as a release that migrates would be.
mkdir -p "$T/tool"; sed 's/^__version__ = .*/__version__ = "0.2.0"/' "${AGENTBUS_BIN:-$BIN}" > "$T/tool/agentbus"
cat > "$T/tool/v2.py" <<'PY'
import importlib.machinery, importlib.util, os, sys
here = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("agentbus_v2", os.path.join(here, "agentbus"))
spec = importlib.util.spec_from_loader("agentbus_v2", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m.SCHEMA = m.SCHEMA.replace("action TEXT NOT NULL, detail TEXT);", "action TEXT NOT NULL, detail TEXT, extra TEXT);")
m.SCHEMA_VERSION = 2
m.MIGRATIONS[1] = ["ALTER TABLE log ADD COLUMN extra TEXT"]
m.reference_shapes.cache_clear(); m.reference_indexes.cache_clear()
sys.argv = ["agentbus"] + sys.argv[1:]
m.cli()
PY
D="$HOME/dx"; old_bus "$D/app"
o=$(cd "$T" && "$PY" "$T/tool/agentbus" upgrade --all "$D") || fail "upgrade --all: $o"
want=$(printf '%s\n' "~/dx/app   0.1.0 -> 0.2.0   schema 0 -> 1" "upgraded 1, current 0, skipped 0, failed 0")
[ "$o" = "$want" ] || fail "transcript: got
$o
want
$want"
o=$(cd "$T" && "$PY" "$T/tool/v2.py" upgrade --all "$D") || fail "v2 upgrade --all: $o"
b=$(ls "$D/app/.agentbus/backups")
[ "$(printf '%s\n' "$b" | wc -l | tr -d ' ')" = 1 ] || fail "a migrated bus has backups: $b"
grep -qxF "~/dx/app   current (0.2.0)   schema 1 -> 2   backup .agentbus/backups/$b" <<<"$o" || fail "migrated line: $o"
case "$b" in bus-v1-[0-9]*T[0-9]*Z.db) ;; *) fail "backup name: $b" ;; esac
o=$(cd "$T" && "$PY" "$T/tool/v2.py" upgrade --all "$D") || fail "v2 again: $o"
grep -qxF "~/dx/app   current (0.2.0)" <<<"$o" || fail "second run: $o"
[ "$(ls "$D/app/.agentbus/backups")" = "$b" ] || fail "a current bus got another backup"
old_bus "$D/one"
o=$(cd "$T" && "$PY" "$T/tool/v2.py" upgrade "$D/one") || fail "upgrade DIR: $o"
b=$(cd "$D/one/.agentbus/backups" && ls bus-v*.db)
grep -qxF "~/dx/one: 0.1.0 -> 0.2.0   schema 0 -> 2   backup ~/dx/one/.agentbus/backups/$b" <<<"$o" || fail "upgrade DIR line: $o"
st=${b#bus-v0-}; st=${st%.db}
cmp -s "$D/one/.agentbus/backups/agentbus-$st" "$OLD" && [ "$(cat "$D/one/.agentbus/backups/VERSION-$st")" = 0.1.0 ]   || fail "the replaced 0.1.0 copy was not kept beside its backup: $(ls "$D/one/.agentbus/backups")"
ok "0.1.0 -> 0.2.0 with schema 0 -> 1 and no backup; a migration shows its one backup; upgrade DIR prints the same line"

echo "TEST 7: no path downgrades a copy: upgrade DIR, upgrade --all and init leave a newer copy, or a copy whose bus is newer, as it was"
N="$HOME/nodown"
check_untouched() {  # check_untouched DIR WHAT: the copy, VERSION and bus.db bytes are as saved
  cmp -s "$1/.agentbus/bin/agentbus" "$T/nd.copy" && cmp -s "$1/.agentbus/VERSION" "$T/nd.version" \
    && cmp -s "$1/.agentbus/bus.db" "$T/nd.db" || fail "$2 changed a newer copy or its bus"
}
for case in release schema; do
  rm -rf "$N"; old_bus "$N"
  printf '#!/bin/sh\necho newer-copy\n' > "$N/.agentbus/bin/agentbus"
  if [ $case = release ]; then printf '99.0.0\n' > "$N/.agentbus/VERSION"
  else "$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=2"); c.close()' "$N/.agentbus/bus.db"; fi
  cp "$N/.agentbus/bin/agentbus" "$T/nd.copy"; cp "$N/.agentbus/VERSION" "$T/nd.version"; cp "$N/.agentbus/bus.db" "$T/nd.db"
  rc=0; agentbus upgrade "$N" >"$T/o" 2>"$T/e" || rc=$?
  [ "$rc" != 0 ] || fail "$case: upgrade DIR succeeded over a newer copy: $(cat "$T/o")"
  check_untouched "$N" "$case: upgrade DIR"
  if [ $case = release ]; then grep -qF "is newer" "$T/e" || fail "release: $(cat "$T/e")"
  else grep -qF "this bus is newer than this copy of agentbus" "$T/e" || fail "schema: $(cat "$T/e")"; fi
  rc=0; agentbus upgrade --all "$N" >"$T/o" 2>&1 || rc=$?
  check_untouched "$N" "$case: upgrade --all"
  rc=0; agentbus init "$N" >"$T/o" 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "$case: init succeeded over a newer copy"
  check_untouched "$N" "$case: init"
done
ok "a newer copy, or one whose bus is newer, is never replaced by upgrade DIR, upgrade --all or init"

echo "TEST 8: a bus folder swapped for a link to another bus during upgrade --all is refused, and the outside bus is untouched"
R="$HOME/race"; old_bus "$R/a"; old_bus "$R/b"; old_bus "$HOME/outside"
cp "$HOME/outside/.agentbus/bin/agentbus" "$T/out.copy"; cp "$HOME/outside/.agentbus/bus.db" "$T/out.db"
P="$T/pause-swap"; mkdir -p "$P"
AGENTBUS_TEST_PAUSE="before-upgrade-b=$P" "${AB[@]}" upgrade --all "$R" >"$T/out" 2>&1 & A=$!
wait_for "$P/before-upgrade-b.reached"
mv "$R/b" "$R/b.moved"; ln -s "$HOME/outside" "$R/b"
touch "$P/before-upgrade-b.go"
rc=0; wait $A || rc=$?
[ "$rc" = 1 ] || fail "upgrade --all with a swapped folder exited $rc: $(cat "$T/out")"
cmp -s "$HOME/outside/.agentbus/bin/agentbus" "$T/out.copy" && cmp -s "$HOME/outside/.agentbus/bus.db" "$T/out.db" \
  || fail "upgrade --all wrote a bus outside DIR through a swapped-in link"
grep -E '^~/race/b +failed: .*(link|outside)' "$T/out" >/dev/null || fail "the swapped folder was not reported: $(cat "$T/out")"
grep -qE '^~/race/a +.*schema 0 -> 1$' "$T/out" || fail "the first bus was not upgraded: $(cat "$T/out")"
ok "a folder swapped for a link mid-run is refused; nothing outside DIR is written"

echo "TEST 9: an upgrade DIR whose migration runs out of time leaves the folder exactly as it was, then a full run keeps the old copy"
folder_state() { "$PY" -c 'import hashlib,os,sys
for root, dirs, files in sorted(os.walk(sys.argv[1])):
    dirs.sort()
    print("D", os.path.relpath(root, sys.argv[1]))
    for f in sorted(files):
        p = os.path.join(root, f); print("F", os.path.relpath(p, sys.argv[1]), hashlib.sha256(open(p,"rb").read()).hexdigest())' "$1"; }
for how in killed stopped; do
  U="$HOME/budget-$how"; old_bus "$U"; (cd "$U" && agentbus claims >/dev/null)   # adopted: version 1, copy 0.1.0
  folder_state "$U" > "$T/fs-before"
  if [ $how = killed ]; then slow=5; else slow=1; fi   # killed: the watchdog ends it mid-copy; stopped: the copy loop sees the deadline
  rc=0; (cd "$T" && AGENTBUS_TEST_DEADLINE=0.5 AGENTBUS_TEST_SLOW=$slow "$PY" "$T/tool/v2.py" upgrade "$U" >"$T/o" 2>"$T/e") || rc=$?
  [ "$rc" != 0 ] || fail "$how: an over-budget migration succeeded"
  grep -qF "within 0.5 s" "$T/e" || fail "$how: $(cat "$T/e")"
  folder_state "$U" > "$T/fs-after"
  cmp -s "$T/fs-before" "$T/fs-after" || fail "$how: the folder changed: $(diff "$T/fs-before" "$T/fs-after")"
done
U="$HOME/budget-killed"
(cd "$T" && "$PY" "$T/tool/v2.py" upgrade "$U" >/dev/null) || fail "the full-budget retry failed"
st=$(cd "$U/.agentbus/backups" && ls bus-v*.db | sed 's/^bus-v[0-9]*-\(.*\)\.db$/\1/')
cmp -s "$U/.agentbus/backups/agentbus-$st" "$OLD" && [ "$(cat "$U/.agentbus/backups/VERSION-$st")" = 0.1.0 ] || fail "the kept copy is not the 0.1.0 copy that wrote the backup"
ok "out of time, by the watchdog or the deadline: folder byte-identical; the retry keeps the 0.1.0 copy beside its backup"

echo "TEST 10: a kept copy cut short (ENOSPC) is never left or later taken as the kept copy"
U="$HOME/keep-enospc"; old_bus "$U"; (cd "$U" && agentbus claims >/dev/null)
folder_state "$U" > "$T/fs-before"
rc=0; (cd "$T" && AGENTBUS_TEST_BACKUP_FAIL=keep-enospc "$PY" "$T/tool/v2.py" upgrade "$U" >"$T/o" 2>"$T/e") || rc=$?
[ "$rc" != 0 ] && grep -qF "could not back up" "$T/e" || fail "a failed kept copy was not a backup failure: rc $rc, $(cat "$T/e")"
folder_state "$U" > "$T/fs-after"
cmp -s "$T/fs-before" "$T/fs-after" || fail "the failed upgrade changed the folder: $(diff "$T/fs-before" "$T/fs-after")"
(cd "$T" && "$PY" "$T/tool/v2.py" upgrade "$U" >/dev/null) || fail "the retry failed"
st=$(cd "$U/.agentbus/backups" && ls bus-v*.db | sed 's/^bus-v[0-9]*-\(.*\)\.db$/\1/')
cmp -s "$U/.agentbus/backups/agentbus-$st" "$OLD" || fail "the kept copy is not the whole 0.1.0 copy"
ok "a kept copy cut short fails the backup and is removed; the retry keeps the whole copy"

echo "TEST 11: a copy that cannot be installed after the bus migrated says so: the migration, the backup, and to run upgrade again"
U="$HOME/inst-fail"; old_bus "$U"; (cd "$U" && agentbus claims >/dev/null)
P="$T/pause-inst"; mkdir -p "$P"
(cd "$T" && AGENTBUS_TEST_PAUSE="before-install=$P" "$PY" "$T/tool/v2.py" upgrade "$U" >"$T/o" 2>"$T/e") & A=$!
wait_for "$P/before-install.reached"
ln "$U/.agentbus/bin/agentbus" "$T/extra-link"
touch "$P/before-install.go"
rc=0; wait $A || rc=$?
[ "$rc" != 0 ] || fail "the install over a hard-linked copy succeeded"
b=$(cd "$U/.agentbus/backups" && ls bus-v*.db)
for want in "schema 1 -> 2" "$U/.agentbus/backups/$b" "Run: agentbus upgrade $U again"; do
  grep -qF "$want" "$T/e" || fail "the error lacks '$want': $(cat "$T/e")"
done
rm "$T/extra-link"
(cd "$T" && "$PY" "$T/tool/v2.py" upgrade "$U" >/dev/null) || fail "the retry failed"
ok "an install that fails after the migration names the migration and backup and says to run upgrade again"

echo "TEST 11b: an install that fails with an OS error after the bus migrated also names the migration and backup"
U="$HOME/inst-oserr"; old_bus "$U"; (cd "$U" && agentbus claims >/dev/null)
rc=0; (cd "$T" && AGENTBUS_TEST_INSTALL_FAIL=eperm "$PY" "$T/tool/v2.py" --json upgrade "$U" >"$T/o" 2>"$T/e") || rc=$?
[ "$rc" != 0 ] || fail "the install with EPERM succeeded"
b=$(cd "$U/.agentbus/backups" && ls bus-v*.db)
for want in "schema 1 -> 2" "$U/.agentbus/backups/$b" "Run: agentbus upgrade $U again"; do
  grep -qF "$want" "$T/e" || fail "the error lacks '$want': $(cat "$T/e")"
done
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"] != "internal", e' "$T/e" || fail "an OS error is still internal: $(cat "$T/e")"
(cd "$T" && "$PY" "$T/tool/v2.py" upgrade "$U" >/dev/null) || fail "the retry failed"
ok "an OS error installing the copy after the migration names the migration and backup and says to run upgrade again"

echo "TEST 11c: upgrade --all whose copy cannot be replaced after the migration: bus_unavailable with the path (never internal), an items_failed error, and a rerun recovers the folder"
# Bug it catches: the rerun reported the same failure as {"code": "internal", "message": "Operation not permitted"}, a bug
# code with no path, and upgrade --all failures exited 1 with no error object to branch on.
U="$HOME/all-eperm"; old_bus "$U/a"; (cd "$U/a" && agentbus claims >/dev/null)
for run in first again; do
  rc=0; (cd "$T" && AGENTBUS_TEST_INSTALL_FAIL=eperm "$PY" "$T/tool/v2.py" --json upgrade --all "$U" >"$T/o" 2>"$T/e") || rc=$?
  [ "$rc" = 1 ] || fail "$run: exit $rc: $(cat "$T/o" "$T/e")"
  "$PY" - "$T/o" "$T/e" "$U/a" "$run" <<'PY' || fail "$run: $(cat "$T/o" "$T/e")"
import json, sys
o, e = json.load(open(sys.argv[1])), json.loads(open(sys.argv[2]).read())["error"]
row = o["buses"][0]
assert row["status"] == "failed" and row["error"]["code"] == "bus_unavailable", row
assert sys.argv[3] + "/.agentbus" in row["error"]["message"], row
if sys.argv[4] == "first":
    assert "the bus was migrated (schema 1 -> 2, backup " in row["error"]["message"] and "Run: agentbus upgrade" in row["error"]["message"], row
else:
    assert row["error"]["file"].startswith(sys.argv[3] + "/.agentbus/"), row
assert e["code"] == "items_failed" and e["failed"] == [row], e
assert e["committed"] is (sys.argv[4] == "first"), e   # the first run migrated the bus: that change was saved
PY
done
o=$(cd "$T" && "$PY" "$T/tool/v2.py" upgrade --all "$U") || fail "the rerun without the fault failed: $o"
grep -qxF "~/all-eperm/a   0.1.0 -> 0.2.0" <<<"$o" && cmp -s "$U/a/.agentbus/bin/agentbus" "$T/tool/agentbus" || fail "the rerun did not replace the copy: $o"
ok "the copy-replace failure is bus_unavailable naming the file, the run's error is items_failed, the rerun finishes the folder"

echo "TEST 11d: upgrade DIR --json reports the schema change and the backup"
U="$HOME/one-json"; old_bus "$U"; (cd "$U" && agentbus claims >/dev/null)
o=$(cd "$T" && "$PY" "$T/tool/v2.py" --json upgrade "$U") || fail "upgrade --json: $o"
"$PY" - "$U" "$o" <<'PY' || fail "upgrade DIR --json: $o"
import json, os, sys
r = json.loads(sys.argv[2])
b = r["backup"]
assert (r["schema_old"], r["schema_new"]) == (1, 2) and b and os.path.dirname(b) == sys.argv[1] + "/.agentbus/backups" and os.path.isfile(b), r
PY
o=$(cd "$T" && "$PY" "$T/tool/v2.py" --json upgrade "$U") || fail "upgrade --json again: $o"
"$PY" -c 'import json,sys; r=json.load(sys.stdin); assert (r["schema_old"], r["schema_new"], r["backup"]) == (2, 2, None), r' <<<"$o" || fail "a current bus: $o"
ok "upgrade DIR --json carries schema_old, schema_new and the backup"

echo "TEST 11e: upgrade --all on a bus.db that is not a database: bus_unavailable naming the file, as upgrade DIR says it"
# Bug it catches: the row said {"code": "internal", "message": "file is not a database"}, a bug code with no path.
U="$HOME/all-garbage"; old_bus "$U/a"; "$PY" -c 'import os,sys; open(sys.argv[1],"wb").write(os.urandom(8192))' "$U/a/.agentbus/bus.db"
rm -f "$U/a/.agentbus/bus.db-wal" "$U/a/.agentbus/bus.db-shm"
rc=0; agentbus --json upgrade --all "$U" >"$T/o" 2>"$T/e" || rc=$?
[ "$rc" = 1 ] || fail "garbage bus: exit $rc: $(cat "$T/o" "$T/e")"
"$PY" - "$T/o" "$U/a/.agentbus/bus.db" <<'PY' || fail "garbage bus row: $(cat "$T/o")"
import json, sys
row = json.load(open(sys.argv[1]))["buses"][0]
assert row["status"] == "failed" and row["error"]["code"] == "bus_unavailable", row
assert row["error"]["file"] == sys.argv[2] and sys.argv[2] in row["error"]["message"], row
PY
rc=0; agentbus --json upgrade "$U/a" >/dev/null 2>"$T/e1" || rc=$?
grep -qF '"code": "bus_unavailable"' "$T/e1" || fail "upgrade DIR on the same bus: $rc $(cat "$T/e1")"
ok "a bus.db that is not a database fails its row as bus_unavailable with the file, like upgrade DIR"

echo "TEST 12: a migration stopped while it writes the kept copy leaves the folder as it was"
U="$HOME/keep-stall"; old_bus "$U"; (cd "$U" && agentbus claims >/dev/null)
folder_state "$U" > "$T/fs-before"
rc=0; (cd "$T" && AGENTBUS_TEST_DEADLINE=0.5 AGENTBUS_TEST_BACKUP_FAIL=keep-stall "$PY" "$T/tool/v2.py" upgrade "$U" >"$T/o" 2>"$T/e") || rc=$?
[ "$rc" != 0 ] || fail "a stalled kept copy succeeded"
folder_state "$U" > "$T/fs-after"
cmp -s "$T/fs-before" "$T/fs-after" || fail "the stopped migration left something: $(diff "$T/fs-before" "$T/fs-after")"
ok "a watchdog stop mid kept-copy write leaves no .tmp and no backups folder"

echo "TEST 13: Ctrl-C after upgrade --all replaced a copy, or after init installed one, says committed true and names the files"
# Bug it catches: committed was tracked for database rows only, so an interrupted upgrade --all that had already replaced
# a folder's copy said "committed": false, and init the same after writing its copy.
"$PY" - "$T" <<'PY' || fail "Ctrl-C after a copy was written"
import json, os, signal, subprocess, sys, time
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
T = sys.argv[1]; H = os.environ["HOME"]
def interrupt(args, point, cwd):
    pause = os.path.join(T, "pause-" + point); os.makedirs(pause, exist_ok=True)
    for n in os.listdir(pause):
        os.unlink(os.path.join(pause, n))
    p = subprocess.Popen([*agentbus_argv(), *args], cwd=cwd, env=dict(os.environ, AGENTBUS_TEST_PAUSE=point + "=" + pause),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    end = time.time() + 30
    while not os.path.exists(os.path.join(pause, point + ".reached")):
        assert time.time() < end and p.poll() is None, (point, "never reached", p.communicate())
        time.sleep(0.02)
    p.send_signal(signal.SIGINT)
    out, err = p.communicate(timeout=30)
    assert p.returncode == 130 and out == "", (args, p.returncode, out, err)
    return err
R = os.path.join(H, "intr")
for n in ("a", "b"):
    d = os.path.join(R, n); os.makedirs(d)
    assert subprocess.run([*agentbus_argv(), "init", d], cwd=T, capture_output=True).returncode == 0
    open(os.path.join(d, ".agentbus", "VERSION"), "w").write("0.1.0\n")
a = os.path.join(R, "a")
for js in (True, False):
    for n in ("a", "b"):
        open(os.path.join(R, n, ".agentbus", "VERSION"), "w").write("0.1.0\n")
    err = interrupt(["--json"] * js + ["upgrade", "--all", R], "before-upgrade-b", T)
    assert open(os.path.join(R, "a", ".agentbus", "VERSION")).read() != "0.1.0\n", "a was not replaced first"
    assert open(os.path.join(R, "b", ".agentbus", "VERSION")).read() == "0.1.0\n", "b was replaced"
    assert "the copy of agentbus was replaced in " + a in err and "Run: agentbus upgrade --all " + R + " to finish" in err, err
    if js:
        e = json.loads(err)["error"]
        # only files changed (no migration): upgrade is safe to repeat, so it stays retryable
        assert e["code"] == "interrupted" and e["committed"] is True and e["retryable"] is True, e
        assert e["directory"] == a and e["rerun"] == "agentbus upgrade --all " + R and e["migrations"] == [], e
        assert a + "/.agentbus/bin/agentbus" in e["changed"] and a + "/.agentbus/VERSION" in e["changed"], e
    else:
        assert "The command's change was saved before this." in err and "Traceback" not in err, err
# init in a git checkout: Ctrl-C after the copy is written, before the exclude rule is added
g = os.path.join(H, "intr-init"); os.makedirs(g)
subprocess.run(["git", "init", "-q", g], check=True)
err = interrupt(["--json", "init", g], "before-exclude-append", T)
e = json.loads(err)["error"]
assert e["code"] == "interrupted" and e["committed"] is True and g + "/.agentbus/bin/agentbus" in e["changed"], e
assert g + "/.agentbus/bin/agentbus" in e["message"], e
# init is safe to repeat: still retryable, and the error names the command that finishes it
assert e["retryable"] is True and e["rerun"] == "agentbus init " + g and "Run: agentbus init " + g + " to finish" in e["message"], e
PY
ok "an interrupted upgrade --all or init that had written a copy says committed true, names the files and the rerun"

echo "All upgrade tests passed"
