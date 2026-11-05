#!/usr/bin/env bash
# The stale-copy notice: the installed tool says on stderr when a bus folder's copy is older than
# itself, and how to upgrade it; never under --json, never from the bus's own copy.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
MOD="${AGENTBUS_BIN:-$BIN}"
# The v0.1.0 file outside any checkout, so the copy it installs records VERSION 0.1.0.
mkdir -p "$T/old"; cp "$TESTS_DIR/fixtures/legacy/agentbus-0.1.0" "$T/old/agentbus"
# A tool one release newer than the 0.1.0 copy: this checkout's file stamped 0.2.0 (not possible
# for an installed command, which carries its own version).
mkdir -p "$T/tool"; sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$MOD" > "$T/tool/agentbus"
W="$(cd "$T" && pwd -P)/src"; mkdir -p "$W/proj"
"$PY" "$T/old/agentbus" init "$W/proj" >/dev/null
[ "$(cat "$W/proj/.agentbus/VERSION")" = 0.1.0 ] || fail "the fixture copy did not install VERSION 0.1.0"
NOTICE="agentbus: this bus's copy is 0.1.0; the installed agentbus is 0.2.0. Run: agentbus upgrade $W/proj"

echo "TEST 1: installed tool join on a 0.1.0 copy prints the notice on stderr and nothing on stdout"
(cd "$W/proj" && "$PY" "$T/tool/agentbus" --as a join >"$T/out" 2>"$T/err") || fail "join failed: $(cat "$T/err")"
grep -qxF "$NOTICE" "$T/err" || fail "no notice on stderr: $(cat "$T/err")"
if grep -qF "this bus's copy" "$T/out"; then fail "the notice reached stdout"; fi
for cmd in status buses; do
  (cd "$W/proj" && "$PY" "$T/tool/agentbus" $cmd >"$T/out" 2>"$T/err") || fail "$cmd failed: $(cat "$T/err")"
  grep -qxF "$NOTICE" "$T/err" || fail "$cmd printed no notice: $(cat "$T/err")"
done
(cd "$W/proj" && "$PY" "$T/tool/agentbus" who >/dev/null 2>"$T/err") || fail "who failed"
[ ! -s "$T/err" ] || fail "who printed a notice: $(cat "$T/err")"
ok "join, status and buses print the notice on stderr only"

echo "TEST 2: --json prints no notice; buses --json carries copy_version and stale"
for cmd in "--as j2 join" status; do
  (cd "$W/proj" && "$PY" "$T/tool/agentbus" --json $cmd >/dev/null 2>"$T/err") || fail "$cmd --json failed"
  [ ! -s "$T/err" ] || fail "$cmd --json printed: $(cat "$T/err")"
done
(cd "$W/proj" && "$PY" "$T/tool/agentbus" --json buses >"$T/out" 2>"$T/err") || fail "buses --json failed"
[ ! -s "$T/err" ] || fail "buses --json printed: $(cat "$T/err")"
"$PY" -c 'import json,sys; r=json.load(open(sys.argv[1]))["items"][0]; assert r["copy_version"]=="0.1.0" and r["stale"] is True, r' "$T/out" || fail "buses --json: $(cat "$T/out")"
o=$(cd "$W/proj" && outof "$PY" "$T/tool/agentbus" buses 2>/dev/null)
grep -qF "copy 0.1.0" <<<"$o" || fail "buses row lacks the copy version: $o"
ok "no notice under --json; buses shows and reports the copy version"

echo "TEST 3: the bus's own copy prints no notice"
# The 0.2.0 code as the folder's own copy, its VERSION still 0.1.0: only being the copy keeps it quiet.
cp "$W/proj/.agentbus/bin/agentbus" "$T/copy.saved"; cp "$T/tool/agentbus" "$W/proj/.agentbus/bin/agentbus"
(cd "$W/proj" && "$PY" .agentbus/bin/agentbus --as b join >/dev/null 2>"$T/err") || fail "own copy join failed"
[ ! -s "$T/err" ] || fail "the bus's own copy printed: $(cat "$T/err")"
cp "$T/copy.saved" "$W/proj/.agentbus/bin/agentbus"
ok "the bus's own copy is silent"

echo "TEST 4: AGENTBUS_NO_UPDATE_NOTICE=1 silences it"
(cd "$W/proj" && AGENTBUS_NO_UPDATE_NOTICE=1 "$PY" "$T/tool/agentbus" --as j4 join >/dev/null 2>"$T/err") || fail "join failed"
[ ! -s "$T/err" ] || fail "the notice ignored AGENTBUS_NO_UPDATE_NOTICE=1: $(cat "$T/err")"
ok "AGENTBUS_NO_UPDATE_NOTICE=1 silences it"

echo "TEST 5: a VERSION that is not a release version, or not older, prints no notice"
for v in "0123456789abcdef0123456789abcdef01234567 2026-11-01T10:00:00Z" "garbage #99" "0.2.0" "0.3.0"; do
  printf '%s\n' "$v" > "$W/proj/.agentbus/VERSION"
  (cd "$W/proj" && "$PY" "$T/tool/agentbus" status >/dev/null 2>"$T/err") || fail "status failed with VERSION $v"
  [ ! -s "$T/err" ] || fail "VERSION '$v' printed: $(cat "$T/err")"
done
ok "a commit, junk, the same or a newer VERSION prints nothing"

echo "TEST 6: the command this suite runs gives the notice for a copy older than itself"
printf '0.0.1\n' > "$W/proj/.agentbus/VERSION"
v=$("${AB[@]}" --version | awk '{print $2}')
(cd "$W/proj" && "${AB[@]}" --as j6 join >/dev/null 2>"$T/err") || fail "join failed"
grep -qxF "agentbus: this bus's copy is 0.0.1; the installed agentbus is $v. Run: agentbus upgrade $W/proj" "$T/err" \
  || fail "no notice from the tested command: $(cat "$T/err")"
ok "the tested command gives the notice too"

echo "TEST 7: release order 0.1.0 < 0.2.0.dev0 < 0.2.0rc1 < 0.2.0: a dev build flags a 0.1.0 copy, never an rc or final one, and never downgrades them"
"$PY" - "$MOD" <<'PY' || fail "release order"
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_order")
k = m["release_key"]
order = ["0.1.0", "0.2.0.dev0", "0.2.0.dev1", "0.2.0rc1", "0.2.0", "0.2.0.post1", "0.2.1.dev0"]
assert [k(v) for v in order] == sorted(k(v) for v in order) and len({k(v) for v in order}) == len(order), [k(v) for v in order]
# The tree's own version sorts after every release (tests/released_commands.txt): a build of main is never taken
# for the release before it, so its copies are not flagged stale by that release's tool, nor refused as equal.
# The one exception is the release-prep commit itself, whose tree IS the newest release: equal to it, after all the others.
import os, re
released = re.findall(r"^v(\S+):", open(os.path.join(os.environ["TESTS_DIR"], "released_commands.txt")).read(), re.M)
assert released and all(k(m["__version__"]) > k(v) or m["__version__"] == v == max(released, key=k) for v in released), (m["__version__"], released)
PY
sed 's/^__version__ = .*/__version__ = "0.2.0.dev0"/' "$MOD" > "$T/tool/agentbus-dev"
printf '0.1.0\n' > "$W/proj/.agentbus/VERSION"
(cd "$W/proj" && "$PY" "$T/tool/agentbus-dev" status >/dev/null 2>"$T/err") || fail "status failed"
grep -qxF "agentbus: this bus's copy is 0.1.0; the installed agentbus is 0.2.0.dev0. Run: agentbus upgrade $W/proj" "$T/err" \
  || fail "a 0.2.0.dev0 tool gave no notice for a 0.1.0 copy: $(cat "$T/err")"
for v in 0.2.0rc1 0.2.0; do
  printf '%s\n' "$v" > "$W/proj/.agentbus/VERSION"
  (cd "$W/proj" && "$PY" "$T/tool/agentbus-dev" status >/dev/null 2>"$T/err") || fail "status failed with VERSION $v"
  [ ! -s "$T/err" ] || fail "a 0.2.0.dev0 tool called a $v copy stale: $(cat "$T/err")"
  rc=0; (cd "$T" && "$PY" "$T/tool/agentbus-dev" --json upgrade "$W/proj" >/dev/null 2>"$T/err") || rc=$?
  [ "$rc" = 1 ] || fail "upgrade by 0.2.0.dev0 over a $v copy: exit $rc: $(cat "$T/err")"
  "$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="copy_newer" and e["copy_version"]==sys.argv[2] and e["tool_version"]=="0.2.0.dev0", e' "$T/err" "$v" \
    || fail "a $v copy was not refused as newer: $(cat "$T/err")"
  [ "$(cat "$W/proj/.agentbus/VERSION")" = "$v" ] || fail "the $v copy was downgraded"
done
ok "a dev build is newer than 0.1.0 and older than its rc and final"

echo "All stale notice tests passed"
