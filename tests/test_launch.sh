#!/bin/bash
set -euo pipefail
# hooks/launch.py: what the plugin's hooks run. A script is compiled from source on every run and bin/agentbus is
# one large file, so the launcher loads it like an import and keeps the bytecode in a private per-user folder.
# Bugs this file catches: a launcher that does not cache (every hook pays the compile again), one that caches where
# a project or another user can write, one that trusts a .pyc planted in a folder anyone else could reach, one that
# serves old code after the file changed, one that dies when the cache cannot be used, and one that behaves unlike
# the script (name, exit status, output).
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TREAL=$(cd "$T" && pwd -P); CHECKOUT=$(cd "$TESTS_DIR/.." && pwd -P)
case "$TREAL/" in "$CHECKOUT"/*) fail "the test folder $T is inside the checkout; set TMPDIR elsewhere" ;; esac
export HOME="$T/home"; mkdir -p "$HOME"
unset AGENTBUS_HOOKS AGENTBUS_HOOK_DEBUG CLAUDE_ENV_FILE CLAUDE_CONFIG_DIR CLAUDE_PID CLAUDE_PLUGIN_ROOT XDG_CACHE_HOME
dups=$(grep -oE '(^|[^_a-z])fail "[^"$]*"' "${BASH_SOURCE[0]}" | sed 's/^[^f]*//' | sort | uniq -d)
[ -z "$dups" ] || fail "FAIL texts used by more than one assertion: $dups"
LAUNCH="$CHECKOUT/hooks/launch.py"
CACHE="$HOME/.cache/agentbus/pycache"
# L ARGS...: the launcher as hooks.json starts it. lib.sh sets PYTHONDONTWRITEBYTECODE for the whole suite; a user
# who runs the plugin has not, so it is dropped here (TEST 7 sets it on purpose).
L() { env -u PYTHONDONTWRITEBYTECODE "$PY" "$LAUNCH" "$@"; }
# pycs DIR: the .pyc files under DIR, one per line.
pycs() { { find "$1" -name '*.pyc' 2>/dev/null || true; } | sort; }   # a missing folder holds none (find fails; set -e must not end the test silently)
# mode PATH: its permission bits, as Python's oct() prints them.
mode() { "$PY" -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

# beside_state: the .pyc files that already sit beside the source or in the project, with their checksums. CI compiles
# bin/agentbus with py_compile before the suite, which leaves bin/__pycache__; only a file the launcher adds or changes counts.
beside_state() { { find "$CHECKOUT/bin" "$CHECKOUT/hooks" "$P/.agentbus" -name '*.pyc' -exec cksum {} + 2>/dev/null || true; } | sort; }
P="$T/proj"; BESIDE_BEFORE=$(beside_state)

# The plugin's own files, copied so a test can change the source: PL/bin/agentbus and PL/hooks/launch.py.
PL="$TREAL/plugin"; mkdir -p "$PL/bin" "$PL/hooks"; cp "$CHECKOUT/bin/agentbus" "$PL/bin/agentbus"; cp "$LAUNCH" "$PL/hooks/launch.py"
LP="$PL/hooks/launch.py"
LV() { env -u PYTHONDONTWRITEBYTECODE "$PY" "$LP" "$@"; }
# plant SRC CACHE_ROOT SENTINEL: a .pyc for SRC that records SRC's real modification time and size, so Python's own check
# passes, and whose code creates SENTINEL and exits 0. Only the folder it sits in can tell it from a genuine one.
plant() {
  "$PY" -I - "$@" <<'PY'
import importlib.util, marshal, os, sys
src, root, sentinel = sys.argv[1:4]
st = os.stat(src)
code = compile("open(%r, 'w').close()\nraise SystemExit(0)\n" % sentinel, src, "exec")
sys.pycache_prefix = root
pyc = importlib.util.cache_from_source(src)
os.makedirs(os.path.dirname(pyc), exist_ok=True)
header = importlib.util.MAGIC_NUMBER + (0).to_bytes(4, "little") + int(st.st_mtime).to_bytes(4, "little") + (st.st_size & 0xFFFFFFFF).to_bytes(4, "little")
open(pyc, "wb").write(header + marshal.dumps(code))
PY
}
SRC="$PL/bin/agentbus"

echo "TEST 1: the launcher is the script: same version text, same exit status, same output for a hook"
want=$("$PY" "$CHECKOUT/bin/agentbus" --version); got=$(L --version)
[ "$want" = "$got" ] || fail "launcher --version differs from the script: '$got' vs '$want'"
rc=0; L no-such-command >"$T/o1" 2>"$T/e1" || rc=$?; rc2=0; "$PY" "$CHECKOUT/bin/agentbus" no-such-command >"$T/o2" 2>"$T/e2" || rc2=$?
[ "$rc" = "$rc2" ] && [ "$rc" != 0 ] || fail "launcher exit status $rc for a bad command, the script's is $rc2"
P="$T/proj"; mkdir -p "$P"; git -C "$P" init -q; (cd "$P" && "$PY" "$CHECKOUT/bin/agentbus" init . >/dev/null && "$PY" "$CHECKOUT/bin/agentbus" who >/dev/null) || fail "init failed"
SID=aaaaaaaa-0000-4000-8000-000000000001
NAME=$("$PY" -c 'import hashlib,sys; print("claude-"+hashlib.sha256(sys.argv[1].encode()).hexdigest()[:8])' "$SID")
"$PY" -I - "$P/.agentbus/bus.db" "$NAME" <<'PY'
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1])
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
for who in ("peer", sys.argv[2]):
    con.execute("INSERT INTO agents(name,tool,joined_at,last_seen) VALUES(?,?,?,?)", (who, "t", now, now))
con.execute("INSERT INTO messages(ts,sender,recipient,kind,body) VALUES(?,?,?,?,?)", (now, "peer", sys.argv[2], "note", "b"))
con.commit(); con.close()
PY
"$PY" -I - "$CHECKOUT/tests/fixtures/claude_hooks/user_prompt_submit.json" "$P" "$SID" >"$T/pl" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().replace("/home/user/proj", sys.argv[2])); d["session_id"] = sys.argv[3]; print(json.dumps(d))
PY
(cd "$P" && "$PY" "$CHECKOUT/bin/agentbus" hook claude UserPromptSubmit <"$T/pl") >"$T/h1"
(cd "$P" && L hook claude UserPromptSubmit <"$T/pl") >"$T/h2"
[ -s "$T/h1" ] && grep -q "1 unread message for you" "$T/h1" || fail "the script printed no unread notice, the test bus is wrong: $(cat "$T/h1")"
cmp -s "$T/h1" "$T/h2" || fail "launcher hook output differs from the script's: $(cat "$T/h2")"
ok "--version, a bad command's status, and a hook's output match the script"

echo
echo "TEST 2: the bytecode lands in the private per-user folder, one file, and nowhere else"
rm -rf "$HOME/.cache"; L --version >/dev/null; L --version >/dev/null
n=$(pycs "$CACHE" | wc -l | tr -d ' ')
[ "$n" = 1 ] || fail "the cache folder holds $n .pyc files, not exactly the agentbus one: $(pycs "$CACHE")"
case "$(pycs "$CACHE")" in */agentbus*.pyc) ;; *) fail "the cached file is not agentbus's: $(pycs "$CACHE")" ;; esac
[ "$(mode "$CACHE")" = 0o700 ] || fail "the cache folder is not 0700"
[ "$(mode "$HOME/.cache/agentbus")" = 0o700 ] || fail "the cache's parent folder is not 0700"
[ "$(beside_state)" = "$BESIDE_BEFORE" ] || fail "bytecode was written beside the source or in the project's .agentbus"
ok "one .pyc under ~/.cache/agentbus/pycache (0700); none in the checkout or the project"

echo
echo "TEST 3: the second run reads the cached code instead of compiling"
out=$(env -u PYTHONDONTWRITEBYTECODE "$PY" -v "$LAUNCH" --version 2>&1) || fail "launcher -v failed"
grep -q "code object from '.*/agentbus[^']*\.pyc'" <<<"$out" || fail "the launcher did not load agentbus from its cached .pyc"
ok "agentbus loaded from the cached .pyc"

echo
echo "TEST 4: a changed source is never served from an old cache"
rm -rf "$HOME/.cache"; v1=$(LV --version); LV --version >/dev/null
"$PY" -I - "$SRC" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s2 = re.sub(r'^__version__ = "([^"]*)"', lambda m: '__version__ = "9.9.9.dev00"', s, count=1, flags=re.M)
assert s2 != s
open(sys.argv[1], "w").write(s2)
PY
v2=$(LV --version)
[ "$v1" != "$v2" ] && grep -q "9.9.9.dev00" <<<"$v2" || fail "after the source changed the launcher still ran the old code: '$v2'"
cp "$CHECKOUT/bin/agentbus" "$SRC"
ok "an edited bin/agentbus is recompiled"

echo
echo "TEST 5: a .pyc planted where the folder is not private is never run"
# The positive control comes first: the same plant in a proper private folder does run, so the refusals below
# are the folder check and not a badly made file.
rm -rf "$HOME/.cache"; mkdir -p "$HOME/.cache"; rm -f "$T/pwned"
LV --version >/dev/null; rm -rf "$CACHE"; mkdir -p "$CACHE"; chmod 700 "$CACHE"; plant "$SRC" "$CACHE" "$T/pwned"
LV --version >/dev/null 2>&1 || true
[ -e "$T/pwned" ] || fail "control: the planted .pyc did not run in a private folder, so the refusals prove nothing"
# (a) the cache folder is a link to a private folder that holds the plant
rm -rf "$HOME/.cache" "$T/pwned" "$T/real"; mkdir -p "$HOME/.cache/agentbus" "$T/real"; chmod 700 "$HOME/.cache/agentbus" "$T/real"
plant "$SRC" "$T/real" "$T/pwned"; ln -s "$T/real" "$CACHE"
v=$(LV --version); [ ! -e "$T/pwned" ] || fail "a .pyc behind a linked cache folder was run"
grep -q "agentbus" <<<"$v" || fail "the launcher did not fall back to the source behind a linked folder: $v"
# (b) the cache folder is open to the group
rm -rf "$HOME/.cache" "$T/pwned"; mkdir -p "$HOME/.cache/agentbus"; chmod 700 "$HOME/.cache/agentbus"
plant "$SRC" "$CACHE" "$T/pwned"; chmod 770 "$CACHE"
v=$(LV --version); [ ! -e "$T/pwned" ] || fail "a .pyc in a group-writable cache folder was run"
grep -q "agentbus" <<<"$v" || fail "the launcher did not fall back to the source for an open folder: $v"
# (c) the folder above it is open
rm -rf "$HOME/.cache" "$T/pwned"; mkdir -p "$HOME/.cache/agentbus"
plant "$SRC" "$CACHE" "$T/pwned"; chmod 700 "$CACHE"; chmod 755 "$HOME/.cache/agentbus"
v=$(LV --version); [ ! -e "$T/pwned" ] || fail "a .pyc under an open parent folder was run"
grep -q "agentbus" <<<"$v" || fail "the launcher did not fall back to the source for an open parent: $v"
chmod 700 "$HOME/.cache/agentbus"
ok "linked, group-writable and open-parent cache folders are ignored; the control plant runs in a private one"

echo
echo "TEST 6: a folder owned by another user is not trusted"
"$PY" -I - "$LAUNCH" "$T/xdg" <<'PY' || fail "the cache folder check accepted a folder owned by someone else"
import os, runpy, sys
m = runpy.run_path(sys.argv[1], run_name="launch")
os.environ["XDG_CACHE_HOME"] = sys.argv[2]
mine = m["cache_folder"]()
assert mine and os.path.isdir(mine), mine
real = os.geteuid
os.geteuid = lambda: real() + 1   # the folder now looks like it belongs to another user
try:
    assert m["cache_folder"]() is None
finally:
    os.geteuid = real
PY
ok "cache_folder() returns None when the owner is not the running user"

echo
echo "TEST 7: no usable cache is not an error: a relative or unwritable cache location, PYTHONDONTWRITEBYTECODE, a damaged .pyc"
v=$(cd "$T" && HOME=rel LV --version) && grep -q "agentbus" <<<"$v" || fail "the launcher failed with a relative home"
mkdir -p "$T/ro"; chmod 500 "$T/ro"
v=$(XDG_CACHE_HOME="$T/ro/sub" LV --version) && grep -q "agentbus" <<<"$v" || fail "the launcher failed with an unwritable cache location"
chmod 700 "$T/ro"
rm -rf "$HOME/.cache"; PYTHONDONTWRITEBYTECODE=1 "$PY" "$LP" --version >/dev/null
[ -z "$(pycs "$HOME/.cache")" ] || fail "PYTHONDONTWRITEBYTECODE was set and a .pyc was written"
LV --version >/dev/null; f=$(pycs "$CACHE" | head -1)
"$PY" -I - "$f" <<'PY'
import sys
b = open(sys.argv[1], "rb").read()
open(sys.argv[1], "wb").write(b[:16] + b"\x00garbage" * 40)   # a valid header, then data marshal cannot read
PY
v=$(LV --version) && grep -q "agentbus" <<<"$v" || fail "the launcher failed with a damaged .pyc"
ok "each case runs the program"

echo
echo "TEST 8: a cached run does not compile agentbus (counted with an audit hook, so no timing is involved)"
# runs PROGRAM ARGS... in this Python with an audit hook that logs each compile of a file named bin/agentbus, then prints the count.
compiles() {
  local log="$T/compiles"; : >"$log"
  # Not -I: isolated mode also turns bytecode writing off, and the first run would never fill the cache. From $T so
  # nothing in the checkout is on sys.path.
  (cd "$T" && env -u PYTHONDONTWRITEBYTECODE "$PY" - "$log" "$@") <<'PY' >/dev/null 2>&1 || true
import runpy, sys
log, program = sys.argv[1:3]
def watch(event, args):
    if event == "compile" and str(args[1]).endswith("bin/agentbus"):
        with open(log, "a") as f:
            f.write("compile\n")
sys.addaudithook(watch)
sys.argv = [program] + sys.argv[3:]
try:
    runpy.run_path(program, run_name="__main__")
except SystemExit:
    pass
PY
  wc -l <"$log" | tr -d ' '
}
rm -rf "$HOME/.cache"
cold=$(compiles "$LAUNCH" --version); warm=$(compiles "$LAUNCH" --version); script=$(compiles "$CHECKOUT/bin/agentbus" --version)
[ "$script" -ge 1 ] || fail "control: the audit hook saw no compile of the script run directly ($script), so a count of 0 proves nothing"
[ "$cold" -ge 1 ] || fail "control: the first launcher run, with no cache, compiled nothing ($cold)"
[ "$warm" = 0 ] || fail "the launcher compiled agentbus on a run that had its cache ($warm compiles)"
ok "the script compiles ($script), the first launcher run compiles ($cold), the next launcher run does not ($warm)"

all_passed "All launcher tests passed"
