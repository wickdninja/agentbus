#!/bin/bash
set -euo pipefail
# `agentbus hook claude EVENT`: the Claude Code hooks, part of the old tests/test_hooks_claude.sh (issue #31): a bus that git tracks under other spellings, hard links and symlinks, a pause point, identity rules, HFS+, SHA-256, index flag bytes and checksum sizes.
# Payloads are the captured ones in tests/fixtures/claude_hooks (docs/design/claude-hook-contract.md), with the project path swapped in.
# Every run is in a throwaway project and HOME. Bugs this file catches: a hook that exits non-zero (Claude Code
# blocks the tool call on 2), runs a bus copy found in the project, waits on a busy bus, writes to a bus it only
# reads, prints text a peer wrote, or acts under a name that belongs to another live session.
. "$(dirname "$0")/lib.sh"
. "$TESTS_DIR/hooks_claude_lib.sh"

echo "TEST 36: a test pause point is honoured only for an existing absolute folder"
newbus p36; N=$(dname "$SID1"); SS; ab --as peer join --tool t >/dev/null; mkdir -p "$P/rel"; n=0
for spec in "hook-seen-lock=" "hook-seen-lock=rel" "hook-seen-read=" "hook-seen-read=rel" "hook-seen-lock=$T/does-not-exist"; do
  n=$((n+1)); rm -f "$P"/*.reached "$P"/rel/*.reached
  payload pre_tool_use_write session_id="\"$SID1\"" tool_input.file_path="\"$P/pause-probe-$n.txt\"" >"$T/pl36"   # a new path each time, so each hook nudges
  "$PY" -I - "$T/pl36" "$P" "$spec" "${AB[@]}" <<'PY' || fail "a pause spec '$spec' stopped or broke the hook"
import os, subprocess, sys
pl, cwd, spec, argv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
p = subprocess.run([*argv, "hook", "claude", "PreToolUse"], stdin=open(pl), capture_output=True, cwd=cwd,
                   env=dict(os.environ, AGENTBUS_TEST_PAUSE=spec), timeout=30)
sys.exit(0 if p.returncode == 0 and p.stdout else 1)
PY
  ! ls "$P"/*.reached "$P"/rel/*.reached >/dev/null 2>&1 || fail "a pause spec '$spec' wrote a .reached file into the project"
done
ok "empty, relative and missing folders: the hook runs on, nothing is written into the project"

echo
echo "TEST 39: the name and identity rules, shown directly (they do not depend on the file system folding names)"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T" <<'PY' || fail "the name and identity rules"
import os, runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_names")
cands = m["hook_index_candidate_paths"]
long_s, up, lo = "ſ".encode(), "Ä".encode(), "ä".encode()
got = cands([(b".agentbu" + long_s + b"/bus.db", 0o100644), (lo + b"/.agentbus/bus.db", 0o100644), (b"x/.AgentBus/y", 0o100644),
             (b"src/main.c", 0o100644), (b"docs/agentbus.md", 0o100644), (b"sparse/", 0o040000), (up + b"/readme", 0o100644)])
assert b".agentbu" + long_s in got, got                  # folds to .agentbus
assert lo + b"/.agentbus" in got and b"x/.AgentBus" in got and b"sparse" in got, got
assert not any(g in got for g in (b"src/main.c", b"docs/agentbus.md", up + b"/readme")), got
# a bus folder whose entry name on disk is not exactly .agentbus is foreign
d = sys.argv[2] + "/names"; os.makedirs(d + "/.agentbus")
real = os.listdir
os.listdir = lambda p: [os.fsencode(".AgentBu") + long_s] if os.fsdecode(p) == os.path.realpath(d) else real(p)
assert m["hook_untracked"](d) is False
os.listdir = real
assert m["hook_untracked"](d) is True
PY
# a big index is read in one go (appending 1 MiB chunks to one bytes object copied the file once per chunk: 0.8 s for 87 MB)
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T/bigread" <<'PY' || fail "a big file was read in many small reads"
import os, runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_read")
with open(sys.argv[2], "wb") as f:
    f.write(os.urandom(1 << 20) * 9)
calls = []
real = os.read
os.read = lambda fd, n: (calls.append(n), real(fd, n))[1]
try:
    data = m["hook_read_file_exact"](sys.argv[2])
finally:
    os.read = real
assert len(data) == 9 << 20 and len(calls) <= 2, (len(data), calls)
PY
# the scan of a plain index keeps long-s names as candidates, and says none when there is no bus-looking path
mkdir -p "$T/quick/.git"; mkgenindex "$T/quick/.git/index" 3 "$(printf '.agentbu\xc5\xbf/bus.db')"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T/quick" <<'PY' || fail "the index scan lost a long-s bus folder name"
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_quick")
cands, shared = m["hook_index_scan"]({"gitdir": sys.argv[2] + "/.git", "common": sys.argv[2] + "/.git"})
assert cands == [b".agentbu\xc5\xbf"] and shared is None, cands
PY
mkgenindex "$T/quick/.git/index" 3 "src/linker.c" "src/sdir/link.h"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T/quick" <<'PY' || fail "paths called link or sdir were taken for index extensions, or a plain index gave candidates"
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_quick")
cands, shared = m["hook_index_scan"]({"gitdir": sys.argv[2] + "/.git", "common": sys.argv[2] + "/.git"})
assert cands == [] and shared is None, cands
data = open(sys.argv[2] + "/.git/index", "rb").read()
names, link, sparse = m["hook_index_walk"](data, 20)
assert link is None and sparse is False and b"src/linker.c" in names, (link, sparse)
PY
# every character HFS+ ignores (git's list) is dropped by the fold, in any position; its neighbours are not
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" <<'PY' || fail "the fold does not drop every character HFS+ ignores"
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_fold")
fold = m["hook_fold"]
ignorable = [c for r in ((0x200c, 0x200f), (0x202a, 0x202e), (0x206a, 0x206f), (0xfeff, 0xfeff)) for c in map(chr, range(r[0], r[1] + 1))]
assert len(ignorable) == 4 + 5 + 6 + 1 and set(ignorable) == m["HOOK_IGNORABLE"], len(ignorable)
for c in ignorable:
    for name in (".agent%sbus" % c, "%s.agentbus" % c, ".agentbus%s" % c, ".a%sg%se%sn%st%sb%su%ss" % ((c,) * 7)):
        assert fold(name.encode()) == ".agentbus", (hex(ord(c)), name)
for c in ("\u200b", "\u2060", "\u00ad", "\u200a", "\u2029", "\ufeff"[:0] + "x"):
    assert fold((".agent%sbus" % c).encode()) != ".agentbus", hex(ord(c))   # neighbours of the set are not ignorable
assert m["HOOK_IGNORABLE_RE"].search("\u200c".encode()) and not m["HOOK_IGNORABLE_RE"].search("\u200b".encode())
for c in ignorable:
    assert m["HOOK_IGNORABLE_RE"].search(c.encode()), hex(ord(c))
PY
# paths called link or sdir are paths, not extensions; a plain index is read once and hashed once
mkgenindex "$T/quick/.git/index" 3 "src/linker.c" "src/sdir/link.h"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T/quick" <<'PY' || fail "paths called link or sdir were taken for extensions, or a plain index was hashed more than once"
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_ext")
data = open(sys.argv[2] + "/.git/index", "rb").read()
names, link, sparse, size = m["hook_index_read"](data)
assert link is None and sparse is False and size == 20 and b"src/linker.c" in names, (link, sparse, size)
calls = []
real1, real2 = m["hashlib"].sha1, m["hashlib"].sha256
m["hashlib"].sha1 = lambda *a, **k: (calls.append(1), real1(*a, **k))[1]
m["hashlib"].sha256 = lambda *a, **k: (calls.append(2), real2(*a, **k))[1]
cands, shared = m["hook_index_scan"]({"gitdir": sys.argv[2] + "/.git", "common": sys.argv[2] + "/.git"})
assert cands == [] and len(calls) == 1, (cands, calls)
PY
# real git indexes (version 2 and version 4) holding a disguised name, and the same name in a plain list
for ver in 2 4; do
  rm -rf "$T/disg$ver"; mkdir -p "$T/disg$ver"; git -C "$T/disg$ver" init -q
  [ "$ver" = 2 ] || git -C "$T/disg$ver" config index.version 4
  printf x >"$T/disg-blob"; BL=$(git -C "$T/disg$ver" hash-object -w "$T/disg-blob")
  for nm in "$(printf '.agent\xe2\x80\x8cbus/bus.db')" "$(printf 'pkg/\xef\xbb\xbf.agentbus/VERSION')" "$(printf 'src/%.0s' 1 2 3)main.c" "src/linker.c"; do
    gitq "$T/disg$ver" update-index --add --cacheinfo "100644,$BL,$nm"
  done
  [ "$ver" = 2 ] || gitq "$T/disg$ver" update-index --index-version 4
  "$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T/disg$ver" "$ver" <<'PY' || fail "a disguised bus folder name (version $ver index) was not picked as a candidate"
import runpy, struct, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_disguise")
g = sys.argv[2] + "/.git"
assert struct.unpack(">I", open(g + "/index", "rb").read(8)[4:8])[0] == int(sys.argv[3])
cands, shared = m["hook_index_scan"]({"gitdir": g, "common": g})
want = [".agent\u200cbus".encode(), "pkg/\ufeff.agentbus".encode()]
assert sorted(cands) == sorted(want), cands
PY
done
ok "folded and HFS+-disguised spellings are candidates (v2 and v4); look-alikes are not; link and sdir only count as extensions; a foreign spelling is refused"

echo
echo "TEST 37: a bus tracked under another spelling of its name (case- and normalization-insensitive file systems) is refused"
# Probe the file system, never the platform: does it find "ProbeDir" as "probedir"?
mkdir -p "$T/ProbeCase"; CI_FS=0; [ -d "$T/probecase" ] && CI_FS=1
LONGS=$(printf '.agentbu\xc5\xbf'); mkdir -p "$T/lsprobe/$LONGS"; LS_FS=0; [ -d "$T/lsprobe/.agentbus" ] && LS_FS=1
if [ "$LS_FS" = 1 ]; then
  # the repo commits ".agentbu<U+017F>/" (long s); on this file system ".agentbus" resolves to it
  mkdir -p "$T/p37-src"; P="$T/p37-src"; git -C "$P" init -q; (cd "$P" && "${AB[@]}" init . >/dev/null && "${AB[@]}" who >/dev/null && "${AB[@]}" --as peer join --tool t >/dev/null)
  mkdir -p "$T/p37-o/$LONGS"; git -C "$T/p37-o" init -q; cp -R "$P/.agentbus/." "$T/p37-o/$LONGS/"; gitq "$T/p37-o" add -f "$LONGS"; gitq "$T/p37-o" commit -qm bus
  git clone -q "$T/p37-o" "$T/p37-c"; P="$T/p37-c"
  [ -d "$P/.agentbus" ] || fail "the long-s clone does not resolve .agentbus on this file system"
  before=$(sha "$P/.agentbus/bus.db"); SS; quiet || fail "a bus tracked as .agentbu<long s> was used: rc $RC out $OUT"
  [ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a bus tracked as .agentbu<long s>"
  [ -z "$(git -C "$P" status --short | grep -v '^??')" ] || fail "the long-s bus shows modified in git status"
else
  echo "this file system does not fold the long s to s; the identity comparison is exercised by the plain cases above"
fi
if [ "$CI_FS" = 1 ]; then
  # the index records "<a umlaut>/.agentbus/..." while the folder on disk is "<A umlaut>"
  UP=$(printf '\xc3\x84'); LO=$(printf '\xc3\xa4')
  mkdir -p "$T/p37u-x"; P="$T/p37u-x"; git -C "$P" init -q; (cd "$P" && "${AB[@]}" init . >/dev/null && "${AB[@]}" who >/dev/null && "${AB[@]}" --as peer join --tool t >/dev/null)
  mkdir -p "$T/p37u-o"; git -C "$T/p37u-o" init -q; printf hi >"$T/p37u-readme"
  gitq "$T/p37u-o" update-index --add --cacheinfo "100644,$(git -C "$T/p37u-o" hash-object -w "$T/p37u-readme"),$UP/readme"
  for f in VERSION bin/agentbus bus.db; do m=100644; [ "$f" = bin/agentbus ] && m=100755
    gitq "$T/p37u-o" update-index --add --cacheinfo "$m,$(git -C "$T/p37u-o" hash-object -w "$P/.agentbus/$f"),$LO/.agentbus/$f"; done
  gitq "$T/p37u-o" commit -qm bus; git clone -q "$T/p37u-o" "$T/p37u-c" 2>/dev/null || true
  P="$T/p37u-c/$UP"; [ -d "$P/.agentbus" ] || fail "the umlaut clone has no .agentbus on this file system"
  before=$(sha "$P/.agentbus/bus.db"); SS; quiet || fail "a bus tracked under a differently cased parent folder was used: rc $RC out $OUT"
  [ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a bus tracked under a differently cased parent folder"
else
  echo "this file system is case-sensitive; the differently cased parent folder cannot occur here"
fi
# controls: a plain tracked .agentbus is refused, an untracked one works (any file system)
newbus p37plain; gitq "$P" add -f .agentbus; before=$(sha "$P/.agentbus/bus.db"); SS; quiet || fail "a plain tracked .agentbus was used: out $OUT"
[ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a plain tracked .agentbus"
newbus p37free; SS; [ -n "$OUT" ] || fail "an untracked .agentbus was refused: rc $RC err $ERR"
# a bus folder under any other spelling of the name is foreign, even untracked (init always makes the exact name)
if [ "$CI_FS" = 1 ]; then
  newbus p37spell; mv "$P/.agentbus" "$P/.AgentBus"
  [ -d "$P/.agentbus" ] || fail "setup: the renamed folder does not resolve as .agentbus on this file system"
  SS; quiet || fail "a bus folder spelled .AgentBus on disk was used: rc $RC out $OUT"
fi
ok "tracked or foreign spellings are refused whatever the file system folds; a plain tracked bus is refused; an untracked one works"

echo
echo "TEST 38: a hard link to the joined bus.db in another project does not pass for the joined bus"
newbus p38a; PA38="$P"; N=$(dname "$SID1"); SS
[[ " $(roster) " == *" $N "* ]] || fail "setup: SessionStart did not join $N"
newbus p38b; PB38="$P"; rm -f "$PB38/.agentbus/bus.db" "$PB38/.agentbus/bus.db-wal" "$PB38/.agentbus/bus.db-shm"
ln "$PA38/.agentbus/bus.db" "$PB38/.agentbus/bus.db"; gitq "$PB38" add -f .agentbus
before=$(sha "$PA38/.agentbus/bus.db")
HCWD="$PB38" END other
unset HCWD; rm -f "$PB38/.agentbus/bus.db"          # A's own link count is back to 1, so A's bus can be read again
P="$PA38"; [ "$(sha "$PA38/.agentbus/bus.db")" = "$before" ] || fail "SessionEnd wrote through a hard link into a tracked project"
[[ " $(roster) " == *" $N "* ]] || fail "SessionEnd left through a hard link (the inode matched, nothing else stopped it)"
# Untracked, so no index stops it on any system: on Linux the tracked case above is refused by the index before the link count is looked at.
newbus p38c; PC38="$P"; N=$(dname "$SID2"); SS "$SID2"
[[ " $(roster) " == *" $N "* ]] || fail "setup: SessionStart did not join $N in p38c"
newbus p38d; PD38="$P"; rm -f "$PD38/.agentbus/bus.db" "$PD38/.agentbus/bus.db-wal" "$PD38/.agentbus/bus.db-shm"
ln "$PC38/.agentbus/bus.db" "$PD38/.agentbus/bus.db"
before=$(sha "$PC38/.agentbus/bus.db")
HCWD="$PD38" END other "$SID2"
unset HCWD; rm -f "$PD38/.agentbus/bus.db"
P="$PC38"; [ "$(sha "$PC38/.agentbus/bus.db")" = "$before" ] || fail "SessionEnd wrote through an untracked hard link"
[[ " $(roster) " == *" $N "* ]] || fail "SessionEnd left through an untracked hard link (the link count is all that stops it)"
ok "a hard-linked bus.db is refused by the link count even though its inode matches, tracked or not"

echo
echo "TEST 40: a tracked symlinked .agentbus is refused, and it is the link that is looked at, not what it points to"
newbus p40src; mv "$P/.agentbus" "$P/real"; ln -s real "$P/.agentbus"; gitq "$P" add -f real .agentbus; gitq "$P" commit -qm s
git clone -q "$P" "$T/p40c"; P="$T/p40c"
[ -L "$P/.agentbus" ] || fail "the clone has no .agentbus link"
before=$(sha "$P/real/bus.db"); SS; quiet || fail "a tracked symlinked .agentbus was used: rc $RC out $OUT"
[ "$(sha "$P/real/bus.db")" = "$before" ] || fail "a hook wrote through a tracked symlinked .agentbus"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$P" <<'PY' || fail "hook_untracked took a symlinked .agentbus for the user's"
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_link")
assert m["hook_untracked"](sys.argv[2]) is False
PY
# outside any repository a linked .agentbus is no more the user's
mkdir -p "$T/p40plain/real"; ln -s real "$T/p40plain/.agentbus"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T/p40plain" <<'PY' || fail "hook_untracked took a symlinked .agentbus outside a repository for the user's"
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_link")
assert m["hook_untracked"](sys.argv[2]) is False
PY
ok "a link is never the user's bus"

echo
echo "TEST 41: with no creation time (Linux) the SessionEnd shortcut holds only while the remembered answer for the unchanged index is empty"
newbus p41; N=$(dname "$SID1"); mkgenindex "$P/.git/index" 50; SS
[[ " $(roster) " == *" $N "* ]] || fail "setup: SessionStart did not join $N"
STATE41="${TMPDIR:-/tmp}/agentbus-hooks-$(id -u)"; BUSF="$STATE41/$(printf '%s' "$SID1" | tr -c 'A-Za-z0-9_-' '_').bus"
nobirth() { "$PY" -I - "$BUSF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[2] = None
json.dump(d, open(sys.argv[1], "w"))
PY
}
nobirth
printf garbage >"$P/.git/index"; END other                    # the index changed since the answer was remembered
[[ " $(roster) " == *" $N "* ]] || fail "SessionEnd trusted dev and inode alone although the index had changed (no creation time)"
newbus p41b; mkgenindex "$P/.git/index" 50; SS; nobirth
END other                                                    # nothing changed, nothing bus-looking in the index
[ -z "$(roster)" ] || fail "SessionEnd with no creation time and an unchanged empty-answer index did not leave: $(roster)"
ok "dev and inode alone are trusted only against an unchanged index that holds no bus-looking path"

echo
echo "TEST 42: HFS+ ignores some characters in names, so a tracked .agent<ZWNJ>bus is the bus on disk (macOS disk image)"
if command -v hdiutil >/dev/null 2>&1 && hdiutil create -quiet -size 64m -fs HFS+ -volname hfsx "$T/hfs.dmg" 2>/dev/null; then
  DMGMNT="$T/hfsmnt"; mkdir -p "$DMGMNT"; hdiutil attach -quiet -nobrowse -mountpoint "$DMGMNT" "$T/hfs.dmg" || fail "could not attach the HFS+ image"
  M="$DMGMNT"; ZN=$(printf '.agent\xe2\x80\x8cbus')
  mkdir "$M/evil"; git -C "$M/evil" init -q; (cd "$M/evil" && "${AB[@]}" init . >/dev/null && "${AB[@]}" who >/dev/null && "${AB[@]}" --as mallory join --tool t >/dev/null)
  git init -q "$M/up"; gitq "$M/up" commit -q --allow-empty -m base; git clone -q "$M/up" "$M/user"
  (cd "$M/user" && "${AB[@]}" init . >/dev/null && "${AB[@]}" who >/dev/null && "${AB[@]}" --as nate join --tool t >/dev/null)
  mkdir -p "$M/up/$ZN"; cp "$M/evil/.agentbus/bus.db" "$M/up/$ZN/bus.db"; gitq "$M/up" add -f "$ZN/bus.db"; gitq "$M/up" commit -qm add
  (cd "$M/user" && git fetch -q 2>/dev/null; git reset -q --hard origin/HEAD 2>/dev/null || git reset -q --hard origin/main 2>/dev/null || git reset -q --hard origin/master) || true
  P="$M/user"
  git -C "$P" -c core.quotepath=off ls-files | grep -q "$(printf '\xe2\x80\x8c')" || fail "the HFS+ test did not put the disguised name in the index"
  before=$(sha "$P/.agentbus/bus.db"); SS; quiet || fail "a bus tracked as .agent<ZWNJ>bus (HFS+) was used: rc $RC out $OUT"
  [ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a bus tracked as .agent<ZWNJ>bus"
  cd "$T"; hdiutil detach -quiet -force "$DMGMNT" || true; DMGMNT=""
  ok "the disguised name is folded to .agentbus and the bus refused"
else
  skip_part "platform: not-macos (no hdiutil, or no HFS+ images: the HFS+ disguise test did not run)"
fi

echo
echo "TEST 43: chance bytes in the hashes and times of an index do not hide a disguised name (all three ignorable prefixes, in any order)"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T/disg-chance" <<'PY' || fail "a disguised .agentbus entry was hidden by byte pairs in an earlier entry's hash and times"
import hashlib, os, runpy, struct, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_chance")
d = sys.argv[2]; os.makedirs(d + "/.git", exist_ok=True)
names = [b".agen\xe2\x81\xaatbus/bus.db", b"src/a.c", b"z/.agent\xef\xbb\xbfbus/VERSION", b"zz1.c", b"zz2.c"]   # sorted
assert names == sorted(names)
out = [b"DIRC", struct.pack(">II", 2, len(names))]
# Byte pairs that look like the first ignorable prefix sit in the hash and time fields of the entries AFTER the disguised
# names (as chance puts them in a big index). A search that remembers how far one prefix got and skips the others loses the
# disguised names before them.
junk = b"\xe2\x80\x8c"
for i, b in enumerate(names):
    j = junk if i >= 1 else b"\x01\x02\x03"
    head = os.urandom(8).replace(b"\xe2", b"\x01") + bytes(8) + os.urandom(8).replace(b"\xe2", b"\x01") + struct.pack(">I", 0o100644) + bytes(12)
    head += j + os.urandom(17).replace(b"\xe2", b"\x01") + struct.pack(">H", len(b))
    assert len(head) == 62, len(head)
    e = head + b
    out.append(e + bytes(8 - len(e) % 8))
body = b"".join(out)
open(d + "/.git/index", "wb").write(body + hashlib.sha1(body).digest())
cands, shared = m["hook_index_scan"]({"gitdir": d + "/.git", "common": d + "/.git"})
want = [b".agen\xe2\x81\xaatbus", b"z/.agent\xef\xbb\xbfbus"]
assert sorted(cands) == sorted(want), cands
PY
ok "disguised names are found whatever bytes come before them"

echo
echo "TEST 44: SHA-256 repositories: with or without a checksum (index.skipHash), the size is the one whose layout parses"
if git init -q --object-format=sha256 "$T/sha256probe" 2>/dev/null; then
  for skip in false true; do
    newbus "p44$skip"; rm -rf "$P/.git"; git init -q --object-format=sha256 "$P"; printf x >"$P/f.txt"; git -C "$P" config index.skipHash "$skip"
    gitq "$P" add f.txt; gitq "$P" commit -qm base
    if [ "$skip" = true ]; then "$PY" -c 'import sys; b=open(sys.argv[1],"rb").read(); sys.exit(0 if b[-32:]==bytes(32) else 1)' "$P/.git/index" || fail "the skipHash SHA-256 test wrote a checksum"; fi
    (cd "$P" && "${AB[@]}" init . >/dev/null && "${AB[@]}" who >/dev/null)
    SS; [ -n "$OUT" ] || fail "an untracked bus in a SHA-256 repository (skipHash $skip) was refused: rc $RC err $ERR"
    gitq "$P" add -f .agentbus; before=$(sha "$P/.agentbus/bus.db")
    SS2=$(printf '{"session_id":"%s","cwd":"%s","source":"startup"}' "$SID2" "$P"); hook SessionStart "$SS2"
    quiet || fail "a tracked bus in a SHA-256 repository (skipHash $skip) was used: rc $RC out $OUT"
    [ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a tracked bus in a SHA-256 repository (skipHash $skip)"
  done
  ok "SHA-256 with and without a checksum: untracked works, tracked refused"
else
  echo "this git cannot make SHA-256 repositories; the size rule is shown by the unit checks above"
fi
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" <<'PY' || fail "the checksum size was chosen by the first checksum that matched"
import hashlib, runpy, struct, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_size")
def index(size, zero, names):
    out = [b"DIRC", struct.pack(">II", 2, len(names))]
    for b in names:
        e = bytes(40) + bytes(size) + struct.pack(">H", len(b)) + b
        out.append(e + bytes(8 - len(e) % 8))
    body = b"".join(out)
    return body + (bytes(size) if zero else (hashlib.sha1 if size == 20 else hashlib.sha256)(body).digest())
for size in (20, 32):
    for zero in (False, True):
        data = index(size, zero, [b".agentbus/bus.db", b"a.c"])
        names, link, sparse, got = m["hook_index_read"](data, (20, 32))
        assert got == size and names == [b".agentbus/bus.db", b"a.c"], (size, zero, got)
        assert m["hook_index_read"](data, (32, 20))[3] == size
try:
    m["hook_index_read"](index(20, False, [b"a"])[:-1] + b"\x01")
    raise SystemExit("a wrong checksum was accepted")
except ValueError:
    pass
PY
ok "a zero trailer fits either size; only the size whose layout parses is taken"

echo
echo "TEST 45: an answer remembered by an older scan is not trusted"
newbus p45; mkgenindex "$P/.git/index" 50 ".agentbus/bus.db"; before=$(sha "$P/.agentbus/bus.db")
STATE45="${TMPDIR:-/tmp}/agentbus-hooks-$(id -u)"; rm -f "$STATE45"/idx-*.json
SS; quiet || fail "setup: a tracked bus (generated index) was used: out $OUT"
ls "$STATE45"/idx-*.json >/dev/null 2>&1 || fail "setup: the first SessionStart remembered no answer"
setcache() {  # setcache VERSION|none : the answer the hook remembered for this index, rewritten as an empty list under that version
  "$PY" -I - "$1" "$STATE45" <<'PY' || fail "could not rewrite the remembered answer"
import glob, json, sys
files = glob.glob(sys.argv[2] + "/idx-*.json"); assert len(files) == 1, files
d = json.load(open(files[0])); d["cands"] = []
if sys.argv[1] == "none": d.pop("v", None)
else: d["v"] = int(sys.argv[1])
json.dump(d, open(files[0], "w"))
PY
}
CURV=$("$PY" -I -c 'import runpy,sys; print(runpy.run_path(sys.argv[1], run_name="v")["HOOK_SCAN_VERSION"])' "${AGENTBUS_BIN:-$BIN}")
setcache none
SS; quiet || fail "an answer stored with no version was trusted: a tracked bus was used: out $OUT"
setcache $((CURV - 1))
SS; quiet || fail "an answer stored by an older scan was trusted: a tracked bus was used: out $OUT"
[ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a tracked bus after reading an older scan's answer"
ok "no version, or another version: a miss"

echo
echo "TEST 46: version 4 indexes with the two extra flag bytes (intent-to-add, skip-worktree), from real git"
newbus p46; mkdir -p "$P/src"; printf a >"$P/src/a.c"; printf b >"$P/src/b.c"; printf c >"$P/src/c.c"; printf d >"$P/new.c"
git -C "$P" config index.version 4; gitq "$P" add src; gitq "$P" commit -qm base
gitq "$P" update-index --skip-worktree src/b.c; gitq "$P" add -N new.c; gitq "$P" add -f .agentbus
"$PY" -I -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); sys.exit(0 if struct.unpack(">I", d[4:8])[0]==4 else 1)' "$P/.git/index" || fail "the test did not make a version 4 index"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$P" <<'PY' || fail "a version 4 index with intent-to-add and skip-worktree entries was misread"
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_v4ext")
g = sys.argv[2] + "/.git"
data = open(g + "/index", "rb").read()
names, link, sparse, size = m["hook_index_read"](data)
want = {b"src/a.c", b"src/b.c", b"src/c.c", b"new.c", b".agentbus/VERSION", b".agentbus/bus.db", b".agentbus/bin/agentbus"}
assert want <= set(names) and len(names) == len(set(names)), sorted(names)      # (the bus may also have a -wal file)
cands, shared = m["hook_index_scan"]({"gitdir": g, "common": g})
assert cands == [b".agentbus"], cands
PY
before=$(sha "$P/.agentbus/bus.db"); SS; quiet || fail "a tracked bus in a version 4 index with extended flags was used: rc $RC out $OUT"
[ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a tracked bus in a version 4 index with extended flags"
ok "extended flags are two bytes in version 4 too; the tracked bus is refused"

echo
echo "TEST 47: when more than one checksum size fits, every one counts; the config only orders the sizes"
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T" <<'PY' || fail "the checksum size rules"
import hashlib, os, runpy, struct, sys
m = runpy.run_path(sys.argv[1], run_name="agentbus_both")
cfg = m["hook_config_hash"]
cases = {
  "[core]\n\tbare = false\n": "sha1",
  "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tobjectformat = sha256\n": "sha256",
  '[extensions]\n\tObjectFormat = "sha256"  # note\n': "sha256",
  "[Extensions]\n objectformat=SHA256\n": "sha256",
  "[extensions] objectformat = sha256\n": "sha256",
  "[core]\n\tobjectformat = sha256\n": "sha1",                # not the [extensions] section
  '[remote "origin"]\n\turl = x\n': "sha1",
  "[include]\n\tpath = other\n": None,
  '[includeIf "gitdir:/x/"]\n\tpath = y\n': None,
  "[core]\n\tx = a \\\n b\n": None,
  "this is not a config\n": None,
  "[extensions]\n\tobjectformat = blake3\n": None,
}
for text, want in cases.items():
    assert cfg(text.encode()) == want, (text, cfg(text.encode()), want)
d = sys.argv[2] + "/plan"; os.makedirs(d, exist_ok=True)
repo = {"gitdir": d, "common": d}
def plan(text):
    open(d + "/config", "w").write(text)
    return m["hook_hash_plan"](repo)
assert plan("[core]\n\tbare = false\n") == ((20, 32), False)
assert plan("[extensions]\n\tobjectformat = sha256\n") == ((32, 20), False)
assert plan("[include]\n\tpath = x\n") == ((20, 32), True)           # unknown: both sizes
assert plan("junk\n") == ((20, 32), True)
# a trailer of 32 zero bytes is the one both checksums could accept: every size that parses is returned
def index(size, names):
    out = [b"DIRC", struct.pack(">II", 2, len(names))]
    for b in names:
        e = bytes(40) + bytes(size) + struct.pack(">H", len(b)) + b
        out.append(e + bytes(8 - len(e) % 8))
    return b"".join(out) + bytes(size)
data = index(32, [b".agentbus/bus.db"])
reads = m["hook_index_reads"](data, (20, 32))
assert [r[3] for r in reads] == [32], [r[3] for r in reads]
# both sizes parse (the layout check is replaced here, since no real file satisfies both): every one is taken, nothing is dropped
calls = []
G = m["hook_index_reads"].__globals__      # the functions look names up here (runpy hands back a copy of it)
real = G["hook_index_walk"]
def walk(data, size):
    calls.append(size)
    return ([b"a.c"] if size == 20 else [".agent\u200cbus/x".encode()]), None, False
G["hook_index_walk"] = walk
two = m["hook_index_reads"](data, (20, 32))
assert calls == [20, 32] and [r[3] for r in two] == [20, 32], (calls, two)
calls.clear()
one = m["hook_index_reads"](index(20, [b"a"])[:-20] + hashlib.sha1(index(20, [b"a"])[:-20]).digest())   # a real checksum: the search stops at the first fit
assert calls == [20] and len(one) == 1, calls
calls.clear()
m["hook_index_reads"](index(20, [b"a"])[:-20] + hashlib.sha1(index(20, [b"a"])[:-20]).digest(), (20, 32), True)    # an unknown config: every size is tried
assert calls == [20], calls    # (the sha256 checksum does not fit, so it is not walked)
G["hook_index_walk"] = real
PY
ok "config text read narrowly; unknown config or a zero trailer: every size that fits counts"

echo
echo "TEST 48: a bus that becomes tracked during a session is not left from (no creation time needed)"
newbus p48; N=$(dname "$SID1"); SS
[[ " $(roster) " == *" $N "* ]] || fail "setup: SessionStart did not join $N"
STATE48="${TMPDIR:-/tmp}/agentbus-hooks-$(id -u)"; "$PY" -I - "$STATE48/$(printf '%s' "$SID1" | tr -c 'A-Za-z0-9_-' '_').bus" <<'PY' || fail "could not clear the recorded creation time"
import json, sys
d = json.load(open(sys.argv[1])); d[2] = None
json.dump(d, open(sys.argv[1], "w"))
PY
gitq "$P" add -f .agentbus                                    # the index changed: the remembered answer is stale
before=$(sha "$P/.agentbus/bus.db"); END other
[ "$(sha "$P/.agentbus/bus.db")" = "$before" ] && [[ " $(roster) " == *" $N "* ]] || fail "SessionEnd with no creation time left a bus that is now tracked (the index changed since the join)"
ok "inode alone does not carry SessionEnd past a changed index"


echo
echo "TEST 99: every output this file made is built from the documented templates"
check_templates 5
ok "every output is a template with digits, kinds and the agent's own name only"

all_passed "All claude hook tests passed (tracked)"
