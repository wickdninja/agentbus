#!/bin/bash
set -euo pipefail
# init / upgrade. Temp repos and a temp HOME; the real home is never touched.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
trap 'rm -rf "$T"' EXIT
R="$T/repo"; mkrepo "$R"

echo "TEST 1: init creates the layout and the gitignore line"
agentbus init "$R" > "$T/out1"
[ -x "$R/.agentbus/bin/agentbus" ] && [ "$(mode "$R/.agentbus/bin/agentbus")" = 700 ] && [ "$(mode "$R/.agentbus")" = 700 ] && [ "$(mode "$R/.agentbus/bin")" = 700 ] || fail "layout/modes"
[ -s "$R/.agentbus/VERSION" ] && cmp -s "$BIN" "$R/.agentbus/bin/agentbus" || fail "VERSION or copy"
grep -qx '.agentbus/' "$R/.git/info/exclude" && grep -q 'optional: add .* to .gitignore to share that rule' "$T/out1" || fail "exclude line / hint"
[ ! -e "$R/.gitignore" ] && [ -z "$(git -C "$R" status --porcelain)" ] || fail "init dirtied the repo"
[ "$(mode "$R/.agentbus/VERSION")" = 600 ] || fail "VERSION mode"
[ ! -e "$R/.agentbus/bus.db" ] || fail "init opened a bus"
[ ! -e "$HOME/.agentbus" ] || fail "init wrote ~/.agentbus"
agentbus init "$R" > "$T/out1b"
[ "$(grep -c '^.agentbus/$' "$R/.git/info/exclude")" = 1 ] && ! grep -q 'added' "$T/out1b" || fail "not idempotent"
ok "layout, modes, VERSION, gitignore, idempotent, no bus opened, HOME untouched"

echo "TEST 2: a worktree's call finds the main checkout's bus"
W="$T/wt"; git -C "$R" worktree add -q "$W" -b wt
(cd "$R" && "$PY" .agentbus/bin/agentbus --as a1 join --tool t --model t --role r >/dev/null)
# SQLite may delete -wal when the last connection closes, so check the modes while a post holds
# the bus open (paused just after it opened bus.db and -wal).
P2="$T/pause2"; mkdir -p "$P2"
(cd "$W" && AGENTBUS_TEST_PAUSE="after-open=$P2" "$PY" "$R/.agentbus/bin/agentbus" --as a2 post "from wt" >/dev/null) & POST=$!
wait_for "$P2/after-open.reached"
[ -f "$R/.agentbus/bus.db" ] && [ ! -e "$W/.agentbus" ] || fail "bus location"
[ -e "$R/.agentbus/bus.db-wal" ] || fail "no wal file to check"
for f in "$R/.agentbus"/bus.db*; do [ "$(mode "$f")" = 600 ] || fail "mode of $f"; done
touch "$P2/after-open.go"; wait $POST || fail "post failed"
[ -z "$(git -C "$R" status --porcelain)" ] || fail "repo dirty after use"
o=$(cd "$R" && outof "$PY" .agentbus/bin/agentbus --json read); grep -q '"from wt"' <<<"$o" || fail "post missing"; ok "worktree post on main checkout bus"

echo "TEST 3: upgrade replaces and reports versions"
# 0.0.9: an older release's VERSION (init and upgrade show only the formats agentbus writes).
echo "# stale" >> "$R/.agentbus/bin/agentbus"; echo "0.0.9" > "$R/.agentbus/VERSION"
agentbus upgrade "$W" > "$T/out3"
grep -q ': 0.0.9 -> ' "$T/out3" && cmp -s "$BIN" "$R/.agentbus/bin/agentbus" && ! grep -qx 0.0.9 "$R/.agentbus/VERSION" || fail "upgrade"
ok "upgrade: $(sed "s#$T/##" "$T/out3")"

echo "TEST 4: a repo-local copy refuses upgrade and init"
expect_fail "not a project copy" "$PY" "$R/.agentbus/bin/agentbus" init "$R"
expect_fail "this is a project copy" "$PY" "$R/.agentbus/bin/agentbus" upgrade "$R"
ok "repo-local copy refused"


echo "TEST 5: init in a workspace creates the copy, with no git exclude"
WS="$T/workspace"; mkdir -p "$WS"
(cd "$WS" && agentbus init > "$T/ws-init")
[ -x "$WS/.agentbus/bin/agentbus" ] && [ -s "$WS/.agentbus/VERSION" ] || fail "workspace copy missing"
[ ! -e "$WS/.git" ] && [ ! -e "$WS/.agentbus/bus.db" ] || fail "init created git metadata or opened the bus"
WSR=$(cd "$WS" && pwd -P); grep -qF "into $WSR/.agentbus/" "$T/ws-init" && grep -qx "next: cd $WSR" "$T/ws-init" || fail "init did not name its copy and the next step: $(cat "$T/ws-init")"
ok "non-repo init installs without an exclude or a database"

echo "TEST 6: nested init names the outer bus, and targets exactly DIR"
N="$WS/repo"; mkrepo "$N"
agentbus init "$N" > "$T/nested"
grep -qxF "outer bus: $(cd "$WS" && pwd -P)" "$T/nested" || fail "nested init did not name the outer bus"
grep -qxF '.agentbus/' "$N/.git/info/exclude" || fail "nested repo exclude missing"
mkdir "$N/sub"
before=$(cat "$N/.git/info/exclude")
agentbus init "$N/sub" > "$T/sub-init"
[ -x "$N/sub/.agentbus/bin/agentbus" ] || fail "subdirectory init did not target DIR"
[ "$(cat "$N/.git/info/exclude")" = "$before" ] || fail "subdirectory init wrote an exclude"
grep -qxF "outer bus: $(cd "$N" && pwd -P)" "$T/sub-init" || fail "subdirectory init did not name nearest outer bus"
ok "nested init names the nearest outer bus; non-top-level init writes no exclude"
echo "All init tests passed"
