#!/bin/bash
set -euo pipefail
# `agentbus hook claude EVENT`: the Claude Code hooks, part of the old tests/test_hooks_claude.sh (issue #31): a .agentbus that git tracks (index versions, split, submodule, worktree), skipHash, the index cache, a 1,000,000-entry index and the SessionEnd shortcut.
# Payloads are the captured ones in tests/fixtures/claude_hooks (docs/design/claude-hook-contract.md), with the project path swapped in.
# Every run is in a throwaway project and HOME. Bugs this file catches: a hook that exits non-zero (Claude Code
# blocks the tool call on 2), runs a bus copy found in the project, waits on a busy bus, writes to a bus it only
# reads, prints text a peer wrote, or acts under a name that belongs to another live session.
. "$(dirname "$0")/lib.sh"
. "$TESTS_DIR/hooks_claude_lib.sh"

echo "TEST 24: a .agentbus that git tracks is refused whatever the index (v2, v3, v4, split, a submodule, a linked worktree); an untracked one works; nothing runs git"
index_version() { "$PY" -c 'import struct,sys; print(struct.unpack(">I", open(sys.argv[1],"rb").read(8)[4:8])[0])' "$P/.git/index"; }
# mkindexed KIND NAME: project P (a git repository with a bus, an untracked .agentbus) whose index is of KIND.
mkindexed() {
  newbus "$2"; printf x >"$P/f.txt"; printf y >"$P/g.txt"
  case "$1" in v4) git -C "$P" config index.version 4 ;; split) git -C "$P" config core.splitIndex true ;; esac
  gitq "$P" add f.txt g.txt; gitq "$P" commit -qm base
  case "$1" in
    v3) printf z >"$P/h.txt"; gitq "$P" add -N h.txt ;;
    v4) gitq "$P" update-index --index-version 4 ;;
    split) gitq "$P" update-index --split-index ;;
  esac
}
# track: put .agentbus in the index of P (force-added, as a clone's committed bus would be)
track() {
  gitq "$P" add -f .agentbus
  if [ "$1" = split ]; then
    gitq "$P" update-index --no-split-index; gitq "$P" update-index --split-index; printf q >"$P/k.txt"; gitq "$P" add k.txt
    ls "$P"/.git/sharedindex.* >/dev/null 2>&1 || fail "the split index test made no shared index"
  fi
}
for kind in v2 v3 v4 split; do
  want=2; [ "$kind" = v3 ] && want=3; [ "$kind" = v4 ] && want=4
  mkindexed "$kind" "p24-$kind-free"
  [ "$(index_version)" = "$want" ] || fail "the $kind index test wrote index version $(index_version)"
  SS; [ -n "$OUT" ] || fail "an untracked bus with a $kind index was refused: rc $RC err $ERR"
  mkindexed "$kind" "p24-$kind-tracked"; track "$kind"
  [ "$(index_version)" = "$want" ] || fail "the tracked $kind index test wrote index version $(index_version)"
  grep -qx '.agentbus/' "$P/.git/info/exclude" || fail "init wrote no exclude rule in the $kind test"   # and the bus is refused anyway
  before=$(sha "$P/.agentbus/bus.db")
  SS; quiet || fail "a tracked bus with a $kind index was used: rc $RC out $OUT err $ERR"
  UPS; quiet || fail "a tracked bus ($kind), UserPromptSubmit: out $OUT"
  PRE x.txt; quiet || fail "a tracked bus ($kind), PreToolUse: out $OUT"
  [ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a tracked bus ($kind index)"
done
# a clone of a repository with a committed bus, after one ordinary command (which writes the exclude rule)
mkindexed v2 p24-src; gitq "$P" add -f .agentbus; gitq "$P" commit -qm bus; SRC=$P
git clone -q "$SRC" "$T/p24-clone"; P="$T/p24-clone"
(cd "$P" && "${AB[@]}" status >/dev/null 2>&1)
grep -q agentbus "$P/.git/info/exclude" || fail "the ordinary command wrote no exclude rule in the clone"
before=$(sha "$P/.agentbus/bus.db"); SS; quiet || fail "a clone's committed bus was used after an ordinary command: rc $RC out $OUT"
[ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a clone's committed bus"
# an index git did not write, or cannot be read: silent
for damage in truncated garbage checksum symlink fifo; do
  mkindexed v2 "p24-bad-$damage"; IDX="$P/.git/index"
  case "$damage" in
    truncated) head -c 100 "$IDX" >"$IDX.t"; mv "$IDX.t" "$IDX" ;;
    garbage) printf 'not an index at all' >"$IDX" ;;
    checksum) "$PY" -c 'import sys; b=bytearray(open(sys.argv[1],"rb").read()); b[40]^=1; open(sys.argv[1],"wb").write(bytes(b))' "$IDX" ;;
    symlink) mv "$IDX" "$IDX.real"; ln -s "$IDX.real" "$IDX" ;;
    fifo) rm "$IDX"; mkfifo "$IDX" ;;
  esac
  before=$(sha "$P/.agentbus/bus.db"); SS; quiet || fail "an unreadable index ($damage): the hook spoke: rc $RC out $OUT err $ERR"
  [ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "an unreadable index ($damage): bus.db changed"
done
# a submodule: its .git is a file pointing at the real git dir
mkindexed v2 p24-subsrc; SUBSRC=$P
newbus p24-outer; gitq "$P" commit -q --allow-empty -m first; gitq "$P" submodule add -q "$SUBSRC" sub; gitq "$P" commit -qm sub
[ -f "$P/sub/.git" ] || fail "the submodule test made no .git file"
P="$P/sub"; (cd "$P" && "${AB[@]}" init . >/dev/null && "${AB[@]}" who >/dev/null)
SS; [ -n "$OUT" ] || fail "an untracked bus in a submodule was refused: rc $RC err $ERR"
gitq "$P" add -f .agentbus; before=$(sha "$P/.agentbus/bus.db")
SS; quiet || fail "a tracked bus in a submodule was used: rc $RC out $OUT"
[ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a submodule's tracked bus"
# a linked worktree finds the main checkout's bus, and honours that checkout's index
mkindexed v2 p24-main; MAIN=$P; gitq "$MAIN" worktree add -q "$T/p24-wt"
HCWD="$T/p24-wt" SS; [ -n "$OUT" ] || fail "a linked worktree did not reach the main checkout's bus: rc $RC err $ERR"
gitq "$MAIN" add -f .agentbus
HCWD="$T/p24-wt" SS; quiet || fail "a linked worktree used the main checkout's tracked bus: rc $RC out $OUT"
# nothing here runs git: a git first on PATH and a repository config that names a program (core.fsmonitor) stay idle
mkindexed v2 p24-nogit
mkdir -p "$T/fakebin"; printf '#!/bin/sh\ntouch "%s"\nexec /usr/bin/git "$@"\n' "$T/canary-git" >"$T/fakebin/git"; chmod +x "$T/fakebin/git"
printf '[core]\n\tfsmonitor = touch %s/canary-fsmonitor\n' "$T" >>"$P/.git/config"
PATH="$T/fakebin:$PATH" git -C "$P" status >/dev/null 2>&1 || true
[ -e "$T/canary-git" ] || fail "the control failed: the stub git was not found first on PATH"
rm -f "$T/canary-git" "$T/canary-fsmonitor"
PATH="$T/fakebin:$PATH" SS; [ -n "$OUT" ] || fail "a repository with a fsmonitor setting: the hook said nothing: rc $RC err $ERR"
PATH="$T/fakebin:$PATH" UPS; PATH="$T/fakebin:$PATH" PRE x.txt; PATH="$T/fakebin:$PATH" STOP; PATH="$T/fakebin:$PATH" END
[ ! -e "$T/canary-git" ] && [ ! -e "$T/canary-fsmonitor" ] || fail "a hook ran git (or what a repository's config named)"
ok "tracked or unreadable index: silent and unwritten, for every format; untracked: works; no git run"

echo
echo "TEST 32: an index written with index.skipHash (no checksum) is read: untracked works, tracked is refused"
newbus p32; printf x >"$P/f.txt"; git -C "$P" config index.skipHash true; gitq "$P" add f.txt; gitq "$P" commit -qm base
"$PY" -c 'import sys; b=open(sys.argv[1],"rb").read(); sys.exit(0 if b[-20:]==bytes(20) else 1)' "$P/.git/index" || fail "the skipHash index test did not write a zero checksum"
SS; [ -n "$OUT" ] || fail "an untracked bus with a skipHash index was refused: rc $RC err $ERR"
gitq "$P" add -f .agentbus; before=$(sha "$P/.agentbus/bus.db")
SS; quiet || fail "a tracked bus with a skipHash index was used: rc $RC out $OUT"
[ "$(sha "$P/.agentbus/bus.db")" = "$before" ] || fail "a hook wrote to a tracked bus (skipHash index)"
ok "all-zero checksum accepted for the untracked and the tracked case"

echo
echo "TEST 33: a changed index is read again; an unchanged one is not (cache keyed on the file's identity)"
newbus p33; mkgenindex "$P/.git/index" 2000
SS; [ -n "$OUT" ] || fail "an untracked bus with a generated index was refused: rc $RC err $ERR"
UPS; ab --as peer join --tool t >/dev/null; ab --as peer post "x" --to "$(dname "$SID1")" --kind note >/dev/null 2>&1; UPS
[ -n "$OUT" ] || fail "an unchanged index: UserPromptSubmit said nothing"
# Only a cache hit can answer now: the index file is overwritten in place with bytes that are not an index, and given
# back its size and modification time (so its device, inode, size and mtime_ns are what they were).
"$PY" -I - "$P/.git/index" <<'PY'
import os, sys
st = os.stat(sys.argv[1])
with open(sys.argv[1], "r+b") as f:
    f.write(b"X" * st.st_size)
os.utime(sys.argv[1], ns=(st.st_atime_ns, st.st_mtime_ns))
after = os.stat(sys.argv[1])
assert (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) == (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
PY
UPS; [ -n "$OUT" ] || fail "a cached answer was not used: an unchanged-identity index was read again"
mkgenindex "$P/.git/index" 2000 .agentbus/bus.db      # the same file (opened for writing, so the same inode), now longer: a new size and time
UPS
# The silence must be the tracked answer, not just silence: the stored candidates for this index now hold the bus folder, under the new stamp.
"$PY" -I - "${TMPDIR:-/tmp}/agentbus-hooks-$(id -u)" "$P/.git/index" <<'PY' || fail "a changed index that now tracks the bus was served from the cache (no stored tracked answer for its new stamp, or the hook spoke): out $OUT"
import glob, json, os, sys
st = os.lstat(sys.argv[2]); stamp = [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns]
answers = [json.load(open(f)) for f in glob.glob(sys.argv[1] + "/idx-*.json")]
assert any(a["stamp"] == stamp and b".agentbus".hex() in a["cands"] for a in answers), answers
PY
[ -z "$OUT" ] || fail "a changed index that now tracks the bus was served from the cache: out $OUT"
mkgenindex "$P/.git/index" 2000
UPS; [ -n "$OUT" ] || fail "an index that no longer tracks the bus was served from the cache"
mkgenindex "$P/.git/index" 0
UPS; [ -n "$OUT" ] || fail "an index with no entries was taken for a damaged one"
STATE="${TMPDIR:-/tmp}/agentbus-hooks-$(id -u)"; ls "$STATE"/idx-*.json >/dev/null 2>&1 || fail "no index answer was remembered"
ok "tracked flips are seen; the answer is remembered while the index file is unchanged"

echo
echo "TEST 34: a 1,000,000-entry index: SessionStart joins, the next events and SessionEnd fit their budgets"
newbus p34; N=$(dname "$SID1"); mkgenindex "$P/.git/index" 1000000
ab --as peer join --tool t >/dev/null; ab --as peer post "x" --to "$N" --kind note >/dev/null 2>&1
# These are budgets (Claude Code cuts a hook at its limit), and a wall clock under load measures the machine, not the hook: a
# run that was descheduled for seconds "took" seconds. So each is held to the CPU time the hook used (its own and its
# children's, from getrusage), which load barely moves. CPU time alone cannot see a hook that waits (a sleep, a lock, a
# blocked read), so each also gets a WALL ceiling, far looser than the CPU budget and judged on the best of up to 3 runs:
# one descheduled run cannot fail it, but a wait that is in every run does. The ceilings are 6 to 10 times the wall seen on
# an idle machine (SessionStart 0.5 s, UserPromptSubmit 0.15 s, SessionEnd 0.15 s with a 1M-entry index) and stay under
# the hook's own watchdog (HOOK_LIMIT_S 4 s, HOOK_END_LIMIT_S 1.2 s: a hook that waits is cut off there, so a ceiling
# above them could never fail): SessionStart 3 s, UserPromptSubmit 1.5 s, SessionEnd 1.0 s. A time.sleep(3) in any of
# them fails, a loaded runner does not. A retry must measure the run it repeats, not a warmer one: SessionStart caches
# the index answer and SessionEnd leaves, so each retry starts from the state the first run started from (the bus folder
# and the hooks' memory folder are copied before it and put back), and the first run's resulting state is restored after
# the last retry, so every check below judges the first run alone. What the hooks must DO carries no clock: SessionStart
# must have joined, UserPromptSubmit must have said something valid, and SessionEnd must have left (all checked below).
timed1() {  # timed1 EVENT FIXTURE WALL_CEILING: "cpu_seconds exit stdout_bytes valid best_wall" (cpu and the rest from the first run)
  payload "$2" session_id="\"$SID1\"" >"$T/pl"
  "$PY" -I - "$T/pl" "$P" "$1" "$3" "${AB[@]}" <<'PY'
import json, os, resource, shutil, subprocess, sys, tempfile, time
pl, cwd, ev, ceiling, argv = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5:]
state = [os.path.join(cwd, ".agentbus"), os.path.join(tempfile.gettempdir(), "agentbus-hooks-%d" % os.getuid())]
snaps = tempfile.mkdtemp()
def save(tag):
    for i, d in enumerate(state):
        if os.path.isdir(d):
            shutil.copytree(d, os.path.join(snaps, "%s%d" % (tag, i)), symlinks=True)
def load(tag):
    for i, d in enumerate(state):
        shutil.rmtree(d, ignore_errors=True)
        if os.path.isdir(os.path.join(snaps, "%s%d" % (tag, i))):
            shutil.copytree(os.path.join(snaps, "%s%d" % (tag, i)), d, symlinks=True)
save("before")
best = None
for attempt in range(3):
    if attempt:
        load("before")               # the same cold state the first run had: no cached index answer, still on the roster
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.monotonic()
    p = subprocess.run([*argv, "hook", "claude", ev], stdin=open(pl), capture_output=True, cwd=cwd, timeout=60)
    wall = time.monotonic() - t0
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    if attempt == 0:
        took = r1.ru_utime + r1.ru_stime - r0.ru_utime - r0.ru_stime
        code, size = p.returncode, len(p.stdout)
        if not p.stdout:
            valid = 0                    # nothing said
        else:
            try:
                d = json.loads(p.stdout)
                valid = 1 if isinstance(d, dict) and "hookSpecificOutput" in d and d["hookSpecificOutput"].get("additionalContext") else -1
            except ValueError:
                valid = -1
        save("after")
    best = wall if best is None else min(best, wall)
    if best < ceiling:
        break
if attempt:
    load("after")                    # the checks after this judge what the first run did
shutil.rmtree(snaps)
print("%.2f %d %d %d %.2f" % (took, code, size, valid, best))
PY
}
set -- $(timed1 SessionStart session_start_startup_print 3)
[ "$2" = 0 ] && [ "$4" = 1 ] || fail "SessionStart with a 1M-entry index: exit $2, $3 bytes, hook JSON valid=$4 (1 wanted) within $1 s"
"$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 4.5 else 1)' "$1" || fail "SessionStart with a 1M-entry index used $1 s of CPU, past its 4.5 s budget"
"$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3 else 1)' "$5" || fail "SessionStart with a 1M-entry index took $5 s of wall time at best of 3 (CPU $1 s): it waits on something"
[[ " $(roster) " == *" $N "* ]] || fail "SessionStart with a 1M-entry index did not put $N on the roster: $(roster)"
set -- $(timed1 UserPromptSubmit user_prompt_submit 1.5)
[ "$2" = 0 ] && [ "$4" = 1 ] || fail "UserPromptSubmit with an unchanged 1M-entry index: exit $2, $3 bytes, hook JSON valid=$4 (1 wanted)"
"$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)' "$1" || fail "UserPromptSubmit re-read an unchanged 1M-entry index (used $1 s of CPU, past its 1 s budget)"
"$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.5 else 1)' "$5" || fail "UserPromptSubmit with an unchanged 1M-entry index took $5 s of wall time at best of 3 (CPU $1 s): it waits on something"
# The shortcut itself, on every system: a session leaving the very bus.db it joined never asks the full check, here made to
# refuse. Changing the index cannot show this on Linux (no creation time: a changed index gets the full check on purpose,
# TEST 41) and an unchanged one cannot either (the full check answers from the same remembered list, and leaves too).
SS "$SID2"; N34=$(dname "$SID2"); [[ " $(roster) " == *" $N34 "* ]] || fail "setup: SessionStart did not join $N34"
payload session_end_other session_id="\"$SID2\"" reason="other" >"$T/pl"
(cd "$P" && "$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$T/pl" <<'PY') || fail "the in-process SessionEnd crashed"
import json, runpy, sys
g = runpy.run_path(sys.argv[1], run_name="agentbus_shortcut")["hook_session_end"].__globals__
g["HOOK_STATE"]["dialect"] = "claude"
g["hook_untracked"] = lambda directory: False
g["hook_session_end"](json.load(open(sys.argv[2])))
PY
[[ " $(roster) " != *" $N34 "* ]] || fail "SessionEnd with a 1M-entry index did not leave without the full check: $(roster)"
[ "$BIRTH" = 0 ] || printf garbage >"$P/.git/index"      # git rewrites the index all the time (here: into something unreadable); with a creation time SessionEnd must not depend on it
set -- $(timed1 SessionEnd session_end_other 1.0); [ "$2" = 0 ] && [ "$4" = 0 ] || fail "SessionEnd with a 1M-entry index: exit $2, valid=$4 (0: no output wanted)"
"$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.5 else 1)' "$1" || fail "SessionEnd with a 1M-entry index used $1 s of CPU, past its 1.5 s budget"
"$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)' "$5" || fail "SessionEnd with a 1M-entry index took $5 s of wall time at best of 3 (CPU $1 s): it waits on something"
[ "$(roster)" = "peer" ] || fail "SessionEnd with a 1M-entry index did not leave: $(roster)"
ok "1M entries: join within the limit, warm events under 1 s, SessionEnd under 1.5 s (all CPU time) and left"

echo
echo "TEST 35: SessionEnd leaves only the very bus.db its own SessionStart joined"
newbus p35a; PA35="$P"; N=$(dname "$SID1"); SS
[[ " $(roster) " == *" $N "* ]] || fail "setup: SessionStart did not join $N in project A"
newbus p35b; PB35="$P"; ab --as "$N" join --tool t >/dev/null      # project B holds the same name, as an older session might
gitq "$PB35" add -f .agentbus
before=$(sha "$PB35/.agentbus/bus.db")
HCWD="$PB35" END other                                              # the session's working directory is now project B
[ "$(sha "$PB35/.agentbus/bus.db")" = "$before" ] || fail "SessionEnd wrote to a tracked bus in another project"
[[ " $(HCWD="$PB35" roster) " == *" $N "* ]] || fail "SessionEnd removed the name from a tracked bus in another project"
unset HCWD
# a lane replaces project A's bus.db with a link to project B's tracked bus.db, then the session ends with its directory in B
newbus p35c; PC35="$P"; SS
newbus p35d; PD35="$P"; ab --as "$N" join --tool t >/dev/null; gitq "$PD35" add -f .agentbus
before=$(sha "$PD35/.agentbus/bus.db")
rm -f "$PC35/.agentbus/bus.db" "$PC35/.agentbus/bus.db-wal" "$PC35/.agentbus/bus.db-shm"; ln -s "$PD35/.agentbus/bus.db" "$PC35/.agentbus/bus.db"
HCWD="$PD35" END other
[ "$(sha "$PD35/.agentbus/bus.db")" = "$before" ] || fail "SessionEnd wrote to a tracked bus reached through a link planted at the recorded bus.db"
[[ " $(HCWD="$PD35" roster) " == *" $N "* ]] || fail "SessionEnd emptied a tracked bus reached through a planted link"
unset HCWD
# a bus.db that was recreated (a new inode at the same path) is not the one that was joined: the full check runs, and an unreadable index is silence
newbus p35e; PE35="$P"; SS
cp "$P/.agentbus/bus.db" "$P/.agentbus/bus.db.new" && mv "$P/.agentbus/bus.db.new" "$P/.agentbus/bus.db"
printf garbage >"$P/.git/index"
END other
[[ " $(roster) " == *" $N "* ]] || fail "SessionEnd trusted a recreated bus.db (a new inode at the same path)"
# a recorded creation time that differs means another file with a reused inode number (forced here on any system: where the
# system records no creation time the live value is None, which differs from the recorded one just the same)
newbus p35g; SS; STATE35="${TMPDIR:-/tmp}/agentbus-hooks-$(id -u)"
"$PY" -I - "$STATE35/$(printf '%s' "$SID1" | tr -c 'A-Za-z0-9_-' '_').bus" <<'PY' || fail "could not edit the recorded bus identity"
import json, sys
d = json.load(open(sys.argv[1])); assert len(d) == 3, d
d[2] = 1
json.dump(d, open(sys.argv[1], "w"))
PY
printf garbage >"$P/.git/index"; END other
[[ " $(roster) " == *" $N "* ]] || fail "SessionEnd trusted a bus.db whose recorded creation time differs (a reused inode number)"
# the very same file reached through another spelling of the directory still counts, and then needs no index at all
newbus p35f; PF35="$P"; SS; ln -s "$PF35" "$T/p35-link"
[ "$BIRTH" = 0 ] || printf garbage >"$PF35/.git/index"
HCWD="$T/p35-link" END other
[ -z "$(HCWD="$PF35" roster)" ] || fail "SessionEnd did not leave the bus it joined when reached through a linked directory"
unset HCWD
ok "another project, a planted link and a recreated bus.db get the full check; the same file by another spelling does not"


echo
echo "TEST 99: every output this file made is built from the documented templates"
check_templates 10
ok "every output is a template with digits, kinds and the agent's own name only"

all_passed "All claude hook tests passed (index)"
