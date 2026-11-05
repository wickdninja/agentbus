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
[ -f "$R/.agentbus/bus.db" ] && [ "$(mode "$R/.agentbus/bus.db")" = 600 ] || fail "init did not make a private bus database"
[ "$("$PY" -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA user_version").fetchone()[0])' "$R/.agentbus/bus.db")" = 1 ] || fail "the database init made has no schema version"
[ ! -e "$R/.agentbus/bus.db-journal" ] || fail "init left a journal"
[ ! -e "$HOME/.agentbus" ] || fail "init wrote ~/.agentbus"
agentbus init "$R" > "$T/out1b"
[ "$(grep -c '^.agentbus/$' "$R/.git/info/exclude")" = 1 ] && ! grep -q 'added' "$T/out1b" || fail "not idempotent"
ok "layout, modes, VERSION, gitignore, idempotent, the database made, HOME untouched"

echo "TEST 2: a worktree's call finds the main checkout's bus"
W="$T/wt"; git -C "$R" worktree add -q "$W" -b wt
(cd "$R" && "$PY" .agentbus/bin/agentbus --as a1 join --tool t --model t --role r >/dev/null)
(cd "$W" && "$PY" "$R/.agentbus/bin/agentbus" --as a2 join >/dev/null)
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
[ ! -e "$WS/.git" ] && [ -f "$WS/.agentbus/bus.db" ] || fail "init created git metadata or no bus database"
WSR=$(cd "$WS" && pwd -P); grep -qF "into $WSR/.agentbus/" "$T/ws-init" && grep -qx "next: cd $WSR" "$T/ws-init" || fail "init did not name its copy and the next step: $(cat "$T/ws-init")"
ok "non-repo init installs with a database and without an exclude"

echo "TEST 6: nested init names the outer bus, and targets exactly DIR"
N="$WS/repo"; mkrepo "$N"
agentbus init "$N" > "$T/nested"
grep -qxF "outer bus: $(cd "$WS" && pwd -P)" "$T/nested" || fail "nested init did not name the outer bus"
grep -qxF '.agentbus/' "$N/.git/info/exclude" || fail "nested repo exclude missing"
mkdir "$N/sub"
before=$(cat "$N/.git/info/exclude")
agentbus init "$N/sub" > "$T/sub-init" || fail "a subfolder of a main checkout was refused"
[ -x "$N/sub/.agentbus/bin/agentbus" ] || fail "subdirectory init did not target DIR"
[ "$(cat "$N/.git/info/exclude")" = "$before" ] || fail "subdirectory init wrote an exclude"
grep -qxF "outer bus: $(cd "$N" && pwd -P)" "$T/sub-init" || fail "subdirectory init did not name nearest outer bus"
ok "nested init names the nearest outer bus; non-top-level init writes no exclude"

echo "TEST: init on a folder that does not exist creates it (mkdir -p); a path it cannot create is refused with nothing made"
agentbus init "$T/new/deep/dir" > "$T/mk-out" || fail "init on a missing folder failed instead of creating it"
[ -x "$T/new/deep/dir/.agentbus/bin/agentbus" ] || fail "init did not create the missing folder and its parents"
grep -q "^created " "$T/mk-out" || fail "init did not say it created the folder"
agentbus init "$T/new/deep/dir" > "$T/mk-out2"
grep -q "^created " "$T/mk-out2" && fail "a second init claims to have created the folder"
mkdir "$T/ro"; chmod 555 "$T/ro"
if [ -w "$T/ro" ]; then echo "NOTE: running as a user that ignores directory modes; the unwritable-parent case was not exercised"; else
  rc=0; agentbus init "$T/ro/x/y" 2> "$T/ro-err" || rc=$?
  [ "$rc" = 2 ] || fail "unwritable parent: exit $rc, want 2"
  grep -q "is not writable" "$T/ro-err" || fail "unwritable parent: unclear message: $(cat "$T/ro-err")"
  [ ! -e "$T/ro/x" ] || fail "unwritable parent: something was created"
fi
chmod 755 "$T/ro"
: > "$T/afile"
rc=0; agentbus init "$T/afile" 2> "$T/f-err" || rc=$?
[ "$rc" = 2 ] && grep -q "not a directory" "$T/f-err" || fail "init on a file was not refused as not a directory"
rc=0; agentbus init "$T/afile/sub" 2> "$T/f-err" || rc=$?
[ "$rc" = 2 ] && grep -q "not a directory" "$T/f-err" || fail "init under a file was not refused"
ok "missing folders are created; unwritable parent, a file, and a path under a file are refused with exit 2"
echo "TEST: one repo, one bus: init refuses a folder of linked worktrees whose repo already has a bus, unless --second-bus"
# Bug it catches: `init ~/src/wt`, a plain folder of worktrees of a repo that has its own bus, made a second bus nobody
# there would find, and the lanes were then told to set AGENTBUS_DB to it. The worktrees' own commands use the repo's bus.
rl() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
O="$T/one"; mkdir -p "$O"; OAPP="$O/app"; mkrepo "$OAPP"; agentbus init "$OAPP" >/dev/null
OWT="$O/wts"; mkdir -p "$OWT"; git -C "$OAPP" worktree add -q "$OWT/lane-a" -b one-a; git -C "$OAPP" worktree add -q "$OWT/lane-b" -b one-b
mkdir -p "$OWT/notes"
expect_fail "holds worktrees of $(rl "$OAPP"), whose bus is $(rl "$OAPP")/.agentbus; agents there use that bus, not one here" agentbus init "$OWT"
[ ! -e "$OWT/.agentbus" ] || fail "the refused init left a bus folder"
rc=0; agentbus --json init "$OWT" >"$T/one-out" 2>"$T/one-err" || rc=$?
python3 - "$T/one-err" "$rc" "$(rl "$OAPP")" <<'PYT' || fail "the refusal is not a bad_input error with next and the flag"
import json, sys
e = json.loads(open(sys.argv[1]).read())["error"]
assert sys.argv[2] == "2" and e["code"] == "bad_input", e
assert e["next"] and "buses" in e["next"], e
assert "--second-bus" in e["message"] and sys.argv[3] in e["message"], e
PYT
[ ! -s "$T/one-out" ] || fail "the refused init printed a result"
agentbus init "$OWT" --second-bus >/dev/null || fail "--second-bus did not allow the deliberate second bus"
[ -x "$OWT/.agentbus/bin/agentbus" ] || fail "--second-bus made no bus"
agentbus init "$OWT" >/dev/null || fail "re-running init on a folder that already has a bus was refused"
ok "a folder of linked worktrees of a repo with a bus is refused (bad_input, next, nothing made); --second-bus and a re-run work"

echo "TEST: one repo, one bus: what is not refused"
# A workspace of independent repos (nested and workspace buses are a feature), a workspace holding the repo's main checkout
# beside its worktree (its bus is an outer bus of the repo), a repo with no bus yet, and git files that name nothing.
OW="$T/one-ws"; mkdir -p "$OW"; mkrepo "$OW/r1"; mkrepo "$OW/r2"; agentbus init "$OW/r1" >/dev/null
agentbus init "$OW" >/dev/null || fail "a workspace of independent repos was refused"
OW2="$T/one-ws2"; mkdir -p "$OW2"; mkrepo "$OW2/app"; agentbus init "$OW2/app" >/dev/null; git -C "$OW2/app" worktree add -q "$OW2/app-wt" -b one-ws2
agentbus init "$OW2" >/dev/null || fail "a workspace holding the main checkout beside its worktree was refused"
OB="$T/one-nobus"; mkdir -p "$OB"; mkrepo "$OB/app"; mkdir -p "$T/one-nobus-wts"; git -C "$OB/app" worktree add -q "$T/one-nobus-wts/w1" -b one-nb
agentbus init "$T/one-nobus-wts" >/dev/null || fail "worktrees of a repo with no bus were refused"
OJ="$T/one-junk"; mkdir -p "$OJ/a" "$OJ/b" "$OJ/c"; printf 'gitdir: %s\n' "$T/does/not/exist" > "$OJ/a/.git"; head -c 20000 /dev/zero | tr '\0' x > "$OJ/b/.git"; mkdir "$OJ/c/.git"
for i in $(seq 1 250); do mkdir -p "$OJ/many/d$i"; done
agentbus init "$OJ" >/dev/null || fail "git files that name nothing refused an init"
ok "independent repos, main checkout beside its worktree, no bus yet, and junk git files all init"

echo "TEST: one repo, one bus: a workspace bus counts as the repo's bus, and no program a repository names is run"
OS="$T/one-wsbus"; mkdir -p "$OS"; mkrepo "$OS/app"; agentbus init "$OS" >/dev/null
OSW="$T/one-wsbus-wts"; mkdir -p "$OSW"; git -C "$OS/app" worktree add -q "$OSW/w1" -b one-sw1
M="$T/one-marker"; printf '#!/bin/sh\ntouch "%s"\n' "$M" > "$T/one-hook.sh"; chmod +x "$T/one-hook.sh"
git -C "$OS/app" config core.fsmonitor "$T/one-hook.sh"; git -C "$OS/app" config core.sshCommand "$T/one-hook.sh"; git -C "$OS/app" config core.pager "$T/one-hook.sh"
expect_fail "holds worktrees of $(rl "$OS/app"), whose bus is $(rl "$OS")/.agentbus" agentbus init "$OSW"
[ ! -e "$M" ] || fail "init ran a program the repository's config names"
[ ! -e "$OSW/.agentbus" ] || fail "the workspace-bus refusal made a bus"
ok "worktrees of a repo covered by a workspace bus are refused too; the repo's config programs are never run"
echo "TEST 20: init's join step is the installed agentbus; from a clone it says to install it first and never names the copy"
# Bug it catches: init said .agentbus/bin/agentbus, the project copy an agent must never pick for itself.
nj() { git init -q "$1"; }
nj "$T/j1"; out=$(cd "$T" && "${AB[@]}" init "$T/j1")
if [ -n "${AGENTBUS_CMD:-}" ]; then   # an installed command is the tool-install branch; the fake install below proves it for a source run
  grep -qx 'next: agentbus --as YOUR_NAME join' <<<"$out" || fail "an installed command should name agentbus on PATH: $out"
else
  grep -qx 'next: install agentbus so your agents have it on PATH (see the README), then agentbus --as YOUR_NAME join' <<<"$out" || fail "a run from a clone should say to install agentbus, then join: $out"
fi
! grep -q 'next: .agentbus/bin/agentbus' <<<"$out" || fail "a run from a clone still names the project copy: $out"
FE="$T/fakeenv"; mkdir -p "$FE/bin"; printf '#!%s\nraise SystemExit(0)\n' "$(command -v "$PY")" >"$FE/bin/agentbus"; chmod 755 "$FE/bin/agentbus"
nj "$T/j2"; out=$(cd "$T" && "$PY" -c 'import runpy, sys; sys.prefix = sys.argv[1]; sys.argv = [sys.argv[2], "init", sys.argv[3]]; runpy.run_path(sys.argv[0], run_name="__main__")' "$FE" "$BIN" "$T/j2")
grep -qx 'next: agentbus --as YOUR_NAME join' <<<"$out" || fail "a tool install should name agentbus on PATH: $out"
! grep -q 'next: .agentbus/bin/agentbus' <<<"$out" || fail "a tool install still names the project copy: $out"
ok "init names agentbus for a tool install, and says to install it first from a clone"

echo "TEST 21: init inside a subfolder of a linked worktree is refused: discovery never reaches a bus made there"
# Bug it catches: only the worktree's top was refused; a bus in wt/sub is one nothing finds, since discovery starts from main/sub.
FM="$T/f-main"; mkrepo "$FM"; FW="$T/f-wt"; git -C "$FM" worktree add -q "$FW" -b f-wt; mkdir -p "$FW/sub/deep"
expect_fail "is inside a linked worktree of $(rl "$FM"); its commands use the main checkout's bus" agentbus init "$FW/sub"
[ ! -e "$FW/sub/.agentbus" ] || fail "the refusal with no repo bus made a bus"
agentbus init "$FM" >/dev/null
expect_fail "is inside a linked worktree of $(rl "$FM"), whose bus is $(rl "$FM")/.agentbus; agents there use that bus, not one here" agentbus init "$FW/sub"
[ ! -e "$FW/sub/.agentbus" ] || fail "the refusal made a bus"
expect_fail "is inside a linked worktree" agentbus init "$FW/sub/deep"
expect_fail "is inside a linked worktree" agentbus init "$FW/new/folder"
[ ! -e "$FW/new" ] || fail "the refusal made the folder it refused"
(cd "$FW/sub" && expect_fail "agentbus init $(rl "$FW")/sub --second-bus" agentbus init .)
(cd "$FW/sub" && agentbus --json init . >"$T/f-json" 2>"$T/f-err") && fail "init --json in a worktree subfolder was not refused"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="bad_input" and e["next"]=="agentbus buses", e' "$T/f-err" || fail "the refusal's JSON is not bad_input naming agentbus buses: $(cat "$T/f-err")"
expect_fail "is a linked worktree" agentbus init "$FW"
agentbus init "$FW/sub" --second-bus >/dev/null || fail "--second-bus did not make the bus"
[ -d "$FW/sub/.agentbus" ] || fail "--second-bus made no bus"
agentbus init "$FW/sub" >/dev/null || fail "re-running init on a worktree subfolder that has a bus was refused"
mkdir -p "$FM/sub"; agentbus init "$FM/sub" >/dev/null || fail "with worktrees, a subfolder of the main checkout was refused: discovery does find a bus there"
ok "refused with the repo's bus named, or the checkout to init when it has none; nothing made; --second-bus and a re-run work; the main checkout's subfolder stays allowed"

echo "TEST 22: a recovery command that names a folder holding a space and a ; runs as one command on that folder"
# Bug it catches: hints pasted the path in as it is (`agentbus init {root}`), so a folder named "q dir;touch CANARY" gave a
# command that, run in a shell, ran agentbus on "q" and then touch. Each printed or JSON command below is run through sh -c in
# an empty folder, with agentbus on PATH a recorder of its arguments: it must get exactly the folder, and nothing else may run.
Q="$T/q dir;touch CANARY"; mkdir -p "$Q"; QR=$(rl "$Q")
QH="$HOME/q dir;touch CANARY"; mkdir -p "$QH"
REC="$T/rec-bin"; mkdir -p "$REC"
printf '#!/bin/sh\nfor w in "$@"; do printf "%%s\\n" "$w"; done >"$ARGS"\n' >"$REC/agentbus"; chmod 755 "$REC/agentbus"
# runs CMD WHAT WORD...: CMD through sh -c in an empty folder; agentbus got exactly WORD... and no CANARY was made anywhere.
runs() {
  local cmd=$1 what=$2 box; shift 2; box=$(mktemp -d); rm -f "$T/args"
  (cd "$box" && ARGS="$T/args" PATH="$REC:$PATH" sh -c "$cmd") >/dev/null 2>&1 || fail "$what: the command failed in sh: $cmd"
  [ -z "$(find "$T" "$box" -name CANARY)" ] || fail "$what: the command ran a second one (CANARY made): $cmd"
  printf '%s\n' "$@" | cmp -s - "$T/args" || fail "$what: agentbus got other words than the folder: $cmd -> $(cat "$T/args" 2>/dev/null)"
}
jnext() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["error"]["next"])' "$1"; }
runline() { sed -n "s/.*$1//p" "$2" | head -1; }   # the text after a marker (Run: , next: ) on the first line holding it
# upgrade of a folder with no bus: the JSON next and the message's Run: are both agentbus init <the folder>
(cd "$T" && agentbus --json upgrade "$Q" >/dev/null 2>"$T/q-err") && fail "upgrade of a folder with no bus succeeded"
runs "$(jnext "$T/q-err")" "upgrade's JSON next" init "$QR"
(cd "$T" && agentbus upgrade "$Q" >/dev/null 2>"$T/q-err2") && fail "upgrade of a folder with no bus succeeded (text)"
runs "$(runline 'Run: ' "$T/q-err2")" "upgrade's Run: line" init "$QR"
# the real command, run as printed, makes the bus in that folder and nowhere else
SHIMREAL="$T/real-bin"; mkdir -p "$SHIMREAL"; printf '#!/bin/sh\nexec %s "$@"\n' "$(printf '%q ' "${AB[@]}")" >"$SHIMREAL/agentbus"; chmod 755 "$SHIMREAL/agentbus"
box=$(mktemp -d); (cd "$box" && PATH="$SHIMREAL:$PATH" sh -c "$(jnext "$T/q-err")") >/dev/null 2>&1 || fail "the printed init did not run"
[ -x "$Q/.agentbus/bin/agentbus" ] && [ ! -e "$box/q dir" ] && [ ! -e "$box/q" ] && [ -z "$(find "$T" "$box" -name CANARY)" ] || fail "the printed init did not make the bus in the folder it names, or ran something else"
# init's next: cd line, for a folder under HOME (shown with ~)
(cd "$T" && agentbus init "$QH" >"$T/qh-init") || fail "init of a folder under HOME failed"
cdline=$(runline 'next: cd ' "$T/qh-init"); [ -n "$cdline" ] || fail "init printed no next: cd line: $(cat "$T/qh-init")"
got=$(cd "$T" && sh -c "cd $cdline && pwd -P") || fail "init's next: cd line does not run in sh: cd $cdline"
[ "$got" = "$(rl "$QH")" ] && [ -z "$(find "$T" -name CANARY)" ] || fail "init's next: cd line does not reach the folder as one word: cd $cdline -> $got"
# a bus that is newer than this agentbus: schema_newer's next and the stale-copy notice
(cd "$Q" && agentbus who >/dev/null) || fail "the first command on the new bus failed"
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=99"); c.commit()' "$Q/.agentbus/bus.db"
(cd "$Q" && agentbus --json who >/dev/null 2>"$T/q-new") && fail "a newer bus was not refused"
runs "$(jnext "$T/q-new")" "schema_newer's JSON next" upgrade "$QR"
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=1"); c.commit()' "$Q/.agentbus/bus.db"
"$PY" - "$BIN" "$QR" "$T/q-old" <<'PY' || fail "schema_older's next could not be read"
import importlib.machinery, importlib.util, os, sys
bin_, root, out = sys.argv[1:4]
bin_ = os.environ.get("AGENTBUS_BIN") or bin_
loader = importlib.machinery.SourceFileLoader("agentbus_mod", bin_)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("agentbus_mod", loader)); loader.exec_module(m)
try:
    m.schema_older(os.path.join(root, ".agentbus", "bus.db"), 0)
except SystemExit as e:
    open(out, "w").write(e.code.next + "\n")
PY
runs "$(cat "$T/q-old")" "schema_older's next" upgrade "$QR"
printf '0.1.0\n' >"$Q/.agentbus/VERSION"   # the copy's recorded release, older than this agentbus
(cd "$Q" && AGENTBUS_NO_UPDATE_NOTICE= agentbus status >/dev/null 2>"$T/q-stale") || fail "status beside a stale copy failed"
runs "$(runline 'Run: ' "$T/q-stale")" "the stale-copy notice's Run: line" upgrade "$QR"
# doctor's fix for a missing copy, in JSON and as shown (~ for HOME)
(cd "$T" && agentbus init "$QH" >/dev/null); (cd "$QH" && agentbus who >/dev/null); rm -f "$QH/.agentbus/bin/agentbus"
(cd "$QH" && agentbus --json doctor >"$T/qh-doc" 2>/dev/null) || true
fix=$("$PY" -c 'import json,sys; print(next(r["fix"] for r in json.load(open(sys.argv[1]))["checks"] if r["id"]=="copy"))' "$T/qh-doc") || fail "doctor --json has no copy fix: $(cat "$T/qh-doc")"
runs "$fix" "doctor's JSON copy fix" init "$(rl "$QH")"
(cd "$QH" && agentbus doctor >"$T/qh-doc2" 2>/dev/null) || true
shown=$(grep -F 'has no copy of agentbus' "$T/qh-doc2" | sed -n 's/.*Run: //p'); [ -n "$shown" ] || fail "doctor shows no copy fix: $(cat "$T/qh-doc2")"
runs "$shown" "doctor's shown copy fix" init "$HOME/q dir;touch CANARY"
# init --second-bus in a linked worktree of a checkout in such a folder: the main checkout to init instead
QM="$T/qm dir;touch CANARY"; mkrepo "$QM"; git -C "$QM" worktree add -q "$T/qm-wt" -b qm-wt
(cd "$T" && agentbus --json init --second-bus "$T/qm-wt" >/dev/null 2>"$T/qm-err") && fail "init --second-bus of a linked worktree was not refused"
runs "$(jnext "$T/qm-err")" "the linked worktree refusal's next" init "$(rl "$QM")"
ok "init, upgrade, schema, stale-copy, doctor and worktree recovery commands name the folder as one shell word"

echo "All init tests passed"
