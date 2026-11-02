#!/bin/bash
set -euo pipefail
# Workflow: buses made by the v0.1.0 copy are brought to the current schema by `upgrade --all`. Proves, for
# every bus under a parent folder: no row is lost, the schema version is set, the bus passes SQLite's integrity
# check, and no bus gets a backup it did not need: a v0.1.0 bus already has the version-1 shape and is adopted
# by the version stamp alone (ws01's rule: one backup per migrated bus, none for adopted or current ones).
# A migration that rewrites tables, its backup and the restore from it are ws01's tests/test_schema.sh (TEST 10
# and 19, with a schema-2 build), as are the failure cases (kill -9 mid-backup, a full disk, a swapped backups
# folder). Needs ws01's `upgrade --all`; until it exists the test says so and skips.
# Runs on the source script, a mutation copy (AGENTBUS_BIN) and an installed command (AGENTBUS_CMD).
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/workflow_lib.sh"
wf_setup
if ! agentbus upgrade --help 2>&1 | grep -q -- '--all'; then
  skip_test "upgrade --all (ws01) does not exist in this build"
fi
mkdir "$T/shim"; ln -s "$(command -v "$PY")" "$T/shim/python3"
LEGACY="$T/legacy-agentbus-0.1.0"
legacy_copy "$LEGACY" || fail "tests/fixtures/legacy/agentbus-0.1.0 is missing"
P="$T/parent"; mkdir "$P"
TABLES="agents messages cursors context context_history claims log"
counts() { for t in $TABLES; do printf '%s=%s ' "$t" "$(sql -d "$1" "SELECT COUNT(*) FROM $t")"; done; }

echo "STEP 1: two v0.1.0 buses with data, and one bus the current tool made"
for n in one two; do
  mkrepo "$P/$n"; "$PY" "$LEGACY" init "$P/$n" >/dev/null
  b() { (cd "$P/$n" && PATH="$T/shim:$PATH" "$P/$n/.agentbus/bin/agentbus" "$@"); }  # its own bus, not the one at $R
  b --as a join >/dev/null; b --as b join >/dev/null
  b --as a post "unread for b" --to b --kind handoff >/dev/null
  b --as a claim "src/$n.py" --purpose "keep" >/dev/null
  b --as a ctx set k v >/dev/null
done
mkrepo "$P/current"; agentbus init "$P/current" >/dev/null; (cd "$P/current" && agentbus --as a join >/dev/null)
BEFORE_ONE=$(counts "$P/one/.agentbus/bus.db"); BEFORE_TWO=$(counts "$P/two/.agentbus/bus.db")
is_equal "v0.1.0 buses have schema version 0" "0
0" "$(sql -d "$P/one/.agentbus/bus.db" 'PRAGMA user_version'; sql -d "$P/two/.agentbus/bus.db" 'PRAGMA user_version')"
ok "fixtures built"

echo "STEP 2: upgrade --all migrates each bus that needs it"
agentbus upgrade --all "$P" >"$T/all.out" 2>"$T/all.err" || { cat "$T/all.out" "$T/all.err" >&2; fail "upgrade --all failed"; }
for n in one two current; do grep -q "$n" "$T/all.out" || fail "upgrade --all did not report $n: $(cat "$T/all.out")"; done
for n in one two; do
  db="$P/$n/.agentbus/bus.db"
  v=$(sql -d "$db" 'PRAGMA user_version'); [ "$v" != 0 ] || fail "$n: schema version still 0"
  is_equal "$n: integrity" "ok" "$(sql -d "$db" 'PRAGMA integrity_check')"
done
is_equal "one: rows after" "$BEFORE_ONE" "$(counts "$P/one/.agentbus/bus.db")"
is_equal "two: rows after" "$BEFORE_TWO" "$(counts "$P/two/.agentbus/bus.db")"
ok "no rows lost, versions set"

echo "STEP 3: a v0.1.0 bus is adopted by the stamp alone: schema 1, no backup; the current bus gets none either"
for n in one two current; do
  is_equal "$n: schema version" "1" "$(sql -d "$P/$n/.agentbus/bus.db" 'PRAGMA user_version')"
  [ -z "$(find "$P/$n/.agentbus" -path '*/backups/*' -type f 2>/dev/null)" ] || fail "$n needed no migration and got a backup"
done
ok "adopted and current buses have no backup"
# kill -9 mid-backup, a full disk and a swapped backups folder are ws01's tests/test_schema.sh.
echo "All workflow migration recovery tests passed"
