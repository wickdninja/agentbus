#!/bin/bash
set -euo pipefail
# Which bus a call opens: precedence, odd repo layouts, relative paths, nesting and git versions.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
busof() { agentbus --json status | python3 -c 'import json,sys,os; print(os.path.realpath(json.load(sys.stdin)["bus"]))'; }
real() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }


echo "TEST 1: repo subfolders and two repos in a workspace find the nearest bus"
WS="$T/workspace"; mkdir -p "$WS"; agentbus init "$WS" >/dev/null
R="$WS/repo"; R2="$WS/repo2"; mkrepo "$R"; mkrepo "$R2"
mkdir -p "$R/src/deep" "$R2/src"
for d in "$R/src/deep" "$R2/src"; do
  got=$(cd "$d" && busof)
  [ "$got" = "$(real "$WS")/.agentbus/bus.db" ] || fail "workspace discovery from $d: $got"
done
(cd "$R" && agentbus --as a post "shared workspace" >/dev/null)
got=$(cd "$R2" && agentbus --json read | python3 -c 'import json,sys; print("|".join(r["body"] for r in json.load(sys.stdin)))')
[ "$got" = "shared workspace" ] || fail "repos did not share messages"
[ ! -e "$R/.agentbus" ] && [ ! -e "$R2/.agentbus" ] || fail "discovery created a repo bus"
ok "repo subfolders share their workspace bus"

echo "TEST 2: a linked worktree outside the workspace maps its relative spot to the main checkout"
W="$T/outside"; git -C "$R" worktree add -q "$W" -b outside
mkdir -p "$W/src/deep"
got=$(cd "$W/src/deep" && busof)
[ "$got" = "$(real "$WS")/.agentbus/bus.db" ] || fail "external worktree discovery: $got"
# A bus below the checkout root proves the relative spot is preserved.
agentbus init "$R/src" >/dev/null
got=$(cd "$W/src/deep" && busof)
[ "$got" = "$(real "$R/src")/.agentbus/bus.db" ] || fail "relative worktree spot lost: $got"
[ ! -e "$W/.agentbus" ] && [ ! -e "$W/src/.agentbus" ] || fail "worktree got a separate bus"
ok "external worktree maps to the same relative directory"

echo "TEST 3: nested buses, --up on either side, and a chain that does not create databases"
agentbus init "$R" > "$T/nested-init"
grep -qxF "outer bus: $(real "$WS")" "$T/nested-init" || fail "outer bus notice missing"
o=$(cd "$R" && json_ok agentbus buses --json)
python3 -c 'import json,sys; rows=json.loads(sys.argv[1]); assert rows == [
 {"level":0,"directory":sys.argv[2],"exists":False},
 {"level":1,"directory":sys.argv[3],"exists":True}], rows' "$o" "$(real "$R")" "$(real "$WS")" || fail "buses chain: $o"
[ ! -e "$R/.agentbus/bus.db" ] || fail "buses created a database"
o=$(cd "$R" && outof agentbus buses)
grep -qxF "  0  $(real "$R")  bus.db not created" <<<"$o" || fail "nearest human row missing: $o"
grep -qxF "  1  $(real "$WS")  bus.db exists" <<<"$o" || fail "outer human row missing: $o"
mkdir "$R/other"
got=$(cd "$R/other" && busof)
[ "$got" = "$(real "$R")/.agentbus/bus.db" ] || fail "nested repo did not win: $got"
for args in "--up 1 --json status" "--json status --up 1"; do
  got=$(cd "$R/other" && agentbus $args | python3 -c 'import json,sys; print(json.load(sys.stdin)["bus"])')
  [ "$got" = "$(real "$WS")/.agentbus/bus.db" ] || fail "--up did not reach workspace"
done
(cd "$R" && expect_fail "no such outer bus" agentbus who --up 2)
(cd "$R" && expect_fail "must be at least 0" agentbus --up -1 who)
(cd "$R" && expect_fail "not an integer" agentbus who --up nope)
(cd "$R" && agentbus --as a join >/dev/null && agentbus --as a claim same/path >/dev/null)
(cd "$R" && agentbus --up 1 --as b join >/dev/null && agentbus --as b claim same/path --up 1 >/dev/null)
[ "$(cd "$R" && njson agentbus --json read)" = 0 ] || fail "outer messages leaked in"
(cd "$R" && agentbus --as a post "repo only" >/dev/null)
got=$(cd "$R" && agentbus --up 1 --json read | python3 -c 'import json,sys; print("|".join(r["body"] for r in json.load(sys.stdin)))')
[ "$got" = "shared workspace" ] || fail "inner message leaked out"
ok "nearest wins, --up selects the outer bus, messages and claims stay separate"

echo "TEST 4: no bus refuses exactly; HOME is never a discovered bus"
O="$T/no-bus"; mkrepo "$O"
(cd "$O" && expect_fail "no bus here or in any parent folder" agentbus status)
rc=0; (cd "$O" && agentbus who) >"$T/no-out" 2>"$T/no-err" || rc=$?
[ "$rc" != 0 ] && [ ! -s "$T/no-out" ] || fail "missing bus did not fail"
[ "$(cat "$T/no-err")" = "agentbus: no bus here or in any parent folder. Run: agentbus init <dir>" ] || fail "wrong missing bus error"
[ ! -e "$O/.agentbus" ] || fail "missing bus created implicitly"
mkdir -p "$HOME/.agentbus" "$HOME/sub"
(cd "$HOME/sub" && expect_fail "no bus here or in any parent folder" agentbus who)
[ ! -e "$HOME/.agentbus/bus.db" ] || fail "HOME bus used"
rmdir "$HOME/.agentbus"; ln -s "$WS/.agentbus" "$HOME/.agentbus"
(cd "$HOME/sub" && expect_fail "no bus here or in any parent folder" agentbus buses)
ok "missing bus refuses; HOME folder and symlink are skipped"

echo "TEST 5: a planted parent bus is refused, never skipped in favour of an outer bus"
P="$WS/planted"; mkdir -p "$P/sub"
ln -s "$WS/.agentbus" "$P/.agentbus"
(cd "$P/sub" && expect_fail "is a symlink" agentbus who)
(cd "$P/sub" && expect_fail "is a symlink" agentbus --up 1 who)
(cd "$P/sub" && expect_fail "is a symlink" agentbus buses)
rm "$P/.agentbus"; printf bad > "$P/.agentbus"
(cd "$P/sub" && expect_fail "not a directory" agentbus who)
rm "$P/.agentbus"; mkdir "$P/.agentbus"; ln -s "$WS/.agentbus/VERSION" "$P/.agentbus/VERSION"
(cd "$P/sub" && expect_fail "VERSION: it is a symlink" agentbus who)
# Exercise another-owner refusal without requiring chown privileges.
(cd "$P/sub" && "$PY" - "$BIN" "$P/.agentbus" <<'PY'
import os, runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_test")
owned = m["_owned"]
target = os.lstat(sys.argv[2]).st_ino
m["walk_buses"].__globals__["_owned"] = lambda st: st.st_ino != target and owned(st)
try:
    next(m["walk_buses"](os.getcwd()))
except SystemExit as e:
    assert "owned by another user" in str(e), str(e)
    print("other owner refused")
else:
    raise AssertionError("another owner's bus was accepted")
PY
) || fail "another owner's parent bus was not refused"
ok "symlinks, wrong types and another owner's bus refuse"

echo "TEST 6: removed options are unknown; the old environment setting is ignored"
for args in "who --project name" "init . --from-legacy name"; do
  (cd "$O" && expect_fail "unrecognized arguments:" agentbus $args)
done
(cd "$O" && expect_fail "unrecognized arguments: --project" agentbus --project who)
(cd "$R" && expect_fail "unrecognized arguments: --from-legacy" agentbus --from-legacy who)
got=$(cd "$R" && AGENTBUS_PROJECT=ignored busof)
[ "$got" = "$(real "$R")/.agentbus/bus.db" ] || fail "removed environment setting diverted discovery"
(cd "$O" && AGENTBUS_PROJECT=ignored expect_fail "no bus here or in any parent folder" agentbus who)
# Even invalid bytes in an unused environment setting are ignored.
got=$(cd "$R" && AGENTBUS_PROJECT=$'\xff' busof)
[ "$got" = "$(real "$R")/.agentbus/bus.db" ] || fail "unused environment setting validated"
ok "removed flags refused and unused environment ignored"

echo "TEST 7: explicit database overrides discovery and --up, including buses"
got=$(cd "$P/sub" && AGENTBUS_DB="$T/explicit.db" agentbus --up 99 --json status | python3 -c 'import json,sys; print(json.load(sys.stdin)["bus"])')
[ "$got" = "$T/explicit.db" ] || fail "explicit database did not win: $got"
o=$(cd "$P/sub" && AGENTBUS_DB="$T/explicit.db" json_ok agentbus buses --up 99 --json)
python3 -c 'import json,sys; assert json.loads(sys.argv[1]) == [{"level":0,"directory":sys.argv[2],"exists":True}]' "$o" "$T" || fail "explicit buses: $o"
ok "explicit database bypasses the planted parent and --up"

echo "TEST 8: concurrent first use after init"
RC="$T/conc"; mkrepo "$RC"; agentbus init "$RC" >/dev/null
pids=""; for i in $(seq 1 10); do (cd "$RC" && agentbus --as c$i join >/dev/null 2>"$T/c$i.err") & pids="$pids $!"; done
fails=0; for p in $pids; do wait $p || fails=$((fails+1)); done
[ "$fails" = 0 ] || fail "$fails concurrent first uses failed: $(cat "$T"/c*.err)"
[ "$(cd "$RC" && njson agentbus --json who)" = 10 ] || fail "not all 10 joined"
[ "$(mode "$RC/.agentbus")" = 700 ] || fail "bus directory mode"
ok "concurrent first use creates one bus with all ten agents"

echo "TEST 9: --separate-git-dir, submodules and their worktrees find their own main checkout"
git init -q --separate-git-dir="$T/gd" "$T/sep"; git -C "$T/sep" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
agentbus init "$T/sep" >/dev/null
got=$(cd "$T/sep" && busof); [ "$got" = "$(real "$T/sep")/.agentbus/bus.db" ] || fail "separate git dir: $got"
mkrepo "$T/subsrc"; mkrepo "$T/super"
git -C "$T/super" -c protocol.file.allow=always submodule add -q "$T/subsrc" s >/dev/null 2>&1
agentbus init "$T/super/s" >/dev/null
got=$(cd "$T/super/s" && busof); [ "$got" = "$(real "$T/super/s")/.agentbus/bus.db" ] || fail "submodule: $got"
git -C "$T/super/s" worktree add -q "$T/subwt" -b swt
got=$(cd "$T/subwt" && busof); [ "$got" = "$(real "$T/super/s")/.agentbus/bus.db" ] || fail "submodule worktree: $got"
ok "non-.git git dirs resolve"

echo "TEST 10: a relative AGENTBUS_DB works and is made absolute"
mkdir -p "$T/rel"; got=$(cd "$T/rel" && AGENTBUS_DB=sub/b.db agentbus --as a --json join --tool t | python3 -c 'import json,sys; print(json.load(sys.stdin)["bus"])')
[ "$got" = "$T/rel/sub/b.db" ] || [ "$got" = "$(real "$T/rel")/sub/b.db" ] || fail "relative AGENTBUS_DB: $got"
[ -f "$T/rel/sub/b.db" ] || fail "relative bus not created"
ok "relative AGENTBUS_DB"

echo "TEST 11: git older than 2.31 gets a clear error"
mkdir -p "$T/oldgit"; printf '#!/bin/sh\necho "git version 2.30.1"\n' > "$T/oldgit/git"; chmod +x "$T/oldgit/git"
(cd "$R" && PATH="$T/oldgit:$PATH" expect_fail "needs git 2.31 or newer" agentbus who)
PATH="$T/oldgit:$PATH" expect_fail "needs git 2.31 or newer" agentbus init "$R"
ok "old git refused clearly"
echo "TEST 12: an existing but unexcluded .agentbus, and AGENTBUS_DB pointing into it, get the exclude rule"
RX="$T/unexcl"; mkrepo "$RX"; mkdir -m 700 "$RX/.agentbus"
(cd "$RX" && agentbus --as x who >/dev/null 2>&1)
[ -z "$(git -C "$RX" status --porcelain)" ] || fail "existing .agentbus left unexcluded"
RY="$T/viaenv"; mkrepo "$RY"; mkdir -m 700 "$RY/.agentbus"
O=$(mktemp -d); (cd "$O" && AGENTBUS_DB="$RY/.agentbus/bus.db" agentbus --as x who >/dev/null); rmdir "$O"
[ -z "$(git -C "$RY" status --porcelain)" ] || fail "AGENTBUS_DB into a checkout's .agentbus left it unexcluded"
RZ="$T/linkex"; mkrepo "$RZ"; mkdir "$RZ/.agentbus"; echo keep > "$T/exvictim"; rm -f "$RZ/.git/info/exclude"; ln -s "$T/exvictim" "$RZ/.git/info/exclude"
# A refused exclude is a notice, never fatal (docs/sandboxed-agents.md): the command still runs.
(cd "$RZ" && agentbus --as x who >/dev/null 2>"$T/exerr") || fail "a symlinked info/exclude made the command fail: $(cat "$T/exerr")"
grep -q "could not add .agentbus/ to .*exclude (refusing .*exclude: it is a symlink)" "$T/exerr" || fail "no notice about the symlinked exclude: $(cat "$T/exerr")"
! grep -q Traceback "$T/exerr" || fail "traceback: $(cat "$T/exerr")"
[ "$(cat "$T/exvictim")" = keep ] || fail "wrote through a symlinked info/exclude"
ok "exclude rule repaired, never through a link; a refused exclude is a notice"

echo "TEST 13: worktrees git cannot map to a main checkout refuse clearly instead of guessing"
git init -q --separate-git-dir="$T/gd2" "$T/sep2"; git -C "$T/sep2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
git -C "$T/sep2" worktree add -q "$T/sep2wt" -b w2
(cd "$T/sep2wt" && expect_fail "records none" agentbus --as x who)
[ ! -e "$T/gd2/.agentbus" ] || fail "bus created inside the git dir"
git init -q --bare "$T/bare.git"
sha=$(git -C "$T/bare.git" -c user.email=t@t -c user.name=t commit-tree -m i 4b825dc642cb6eb9a060e54bf8d69288fbee4904)
git -C "$T/bare.git" update-ref refs/heads/main "$sha"; git -C "$T/bare.git" worktree add -q "$T/barewt" main
(cd "$T/barewt" && expect_fail "records none" agentbus --as x who)
[ ! -e "$T/bare.git/.agentbus" ] || fail "bus created inside the bare repo"
ok "unmappable worktrees refuse and point at AGENTBUS_DB"
echo "TEST 14: concurrent first uses write the exclude rule once"
# Bug it catches: two first uses both read info/exclude without the rule, then both appended it.
# Both are held after their read and released together; the append re-reads under a lock.
RS="$T/stampede"; mkrepo "$RS"; mkdir "$RS/.agentbus"; : > "$RS/.git/info/exclude"
mkdir -p "$T/s1" "$T/s2"
(cd "$RS" && AGENTBUS_TEST_PAUSE="before-exclude-append=$T/s1" agentbus --as s1 who >/dev/null 2>"$T/s1.err") & A=$!
(cd "$RS" && AGENTBUS_TEST_PAUSE="before-exclude-append=$T/s2" agentbus --as s2 who >/dev/null 2>"$T/s2.err") & B=$!
wait_for "$T/s1/before-exclude-append.reached"; wait_for "$T/s2/before-exclude-append.reached"
touch "$T/s1/before-exclude-append.go" "$T/s2/before-exclude-append.go"
wait $A || fail "first use 1 failed: $(cat "$T/s1.err")"; wait $B || fail "first use 2 failed: $(cat "$T/s2.err")"
[ "$(grep -c '^.agentbus/$' "$RS/.git/info/exclude")" = 1 ] || fail "the rule was written $(grep -c '^.agentbus/$' "$RS/.git/info/exclude") times"
[ -z "$(git -C "$RS" status --porcelain)" ] || fail "git status not clean after the stampede"
ok "two first uses past their read at once: one rule"
echo "TEST 15: upgrade works on a workspace folder, by path or by discovery; init refuses a linked worktree"
# Bugs it catches: upgrade only understood git repos, so a workspace bus (~/src/your-workspace) could
# never be upgraded; init in a linked worktree made a bus no command there would ever find.
UW="$T/up-ws"; mkdir -p "$UW/sub"; agentbus init "$UW" >/dev/null
echo "0.0.9" > "$UW/.agentbus/VERSION"
o=$(outof agentbus upgrade "$UW"); grep -qF "$(real "$UW"): 0.0.9 -> " <<<"$o" || fail "upgrade by path: $o"
echo "0.0.9" > "$UW/.agentbus/VERSION"
o=$(cd "$UW/sub" && outof agentbus upgrade); grep -qF "$(real "$UW"): 0.0.9 -> " <<<"$o" || fail "upgrade by discovery: $o"
cmp -s "$BIN" "$UW/.agentbus/bin/agentbus" || fail "upgrade did not replace the copy"
mkdir -p "$T/nobus"; expect_fail "has no .agentbus/bin/agentbus. Run: agentbus init" agentbus upgrade "$T/nobus"
UR="$T/up-repo"; mkrepo "$UR"; UWT="$T/up-wt"; git -C "$UR" worktree add -q "$UWT" -b up
expect_fail "is a linked worktree; its commands use the main checkout's bus. Run: agentbus init $(real "$UR")" agentbus init "$UWT"
[ ! -e "$UWT/.agentbus" ] || fail "init made a bus in the worktree"
ok "upgrade by path and by discovery on a workspace; init points a worktree at its main checkout"

echo "TEST 16: a new bus folder is private (0700)"
MR="$T/mode"; mkdir -p "$MR"; agentbus init "$MR" >/dev/null
[ "$(mode "$MR/.agentbus")" = 700 ] || fail ".agentbus is $(mode "$MR/.agentbus")"
(cd "$MR" && agentbus --as m join >/dev/null)
[ "$(mode "$MR/.agentbus/bus.db")" = 600 ] || fail "bus.db is $(mode "$MR/.agentbus/bus.db")"
ok ".agentbus is 0700 and bus.db 0600"
echo "All discovery tests passed"
