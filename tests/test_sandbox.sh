#!/bin/bash
set -euo pipefail
# The residual race (see docs/sandboxed-agents.md) closes at the sandbox: a lane that cannot create
# links (symbolic or hard) in the bus folder cannot plant one. This proves the documented sandbox-exec profile does
# that and still lets the lane use the bus. macOS only; elsewhere it exits 77 (a platform skip).
. "$(dirname "$0")/lib.sh"
[ "$(uname)" = Darwin ] || skip_platform not-macos "sandbox-exec is macOS only"
[ -x /usr/bin/sandbox-exec ] || skip_platform no-sandbox-exec "/usr/bin/sandbox-exec is missing"
T=$(mktemp -d); T=$(cd "$T" && pwd -P); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
R="$T/repo"; mkrepo "$R"; agentbus init "$R" >/dev/null
B="$R/.agentbus"; echo keep > "$T/victim"
LT="$T/lanetmp"; mkdir -p "$LT"   # a real lane always has some writable dir outside the bus
# The /dev files a lane may write: never all of /dev, which holds every other terminal of this user.
DEV_RULE='(allow file-write* (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (literal "/dev/dtracehelper") (regex #"^/dev/fd/"))'
# other_tty PROFILE: exits 0 when a lane under PROFILE wrote to another terminal (a pty this test opens).
other_tty() { "$PY" "$T/tty.py" "$1"; }
cat > "$T/tty.py" <<'PY'
import os, select, subprocess, sys
m, s = os.openpty(); name = os.ttyname(s)  # s stays open: the pty lives as long as this test holds it
r = subprocess.run(["/usr/bin/sandbox-exec", "-f", sys.argv[1], "/bin/sh", "-c", 'printf x > "$0"', name],
                   stderr=subprocess.DEVNULL)
got = os.read(m, 16) if select.select([m], [], [], 2)[0] else b""
sys.exit(0 if r.returncode == 0 and got == b"x" else 1)
PY
# profile BUSDIR [no-symlink-rule|no-special-rule|dev-subpath]: the documented folder-grant lane profile for
# that bus folder (the second argument drops one rule, or grants all of /dev, for the negative controls below).
profile() {
  local sym='(deny file-write-create (vnode-type SYMLINK))'; [ "${2:-}" = no-symlink-rule ] && sym=''
  local special='(deny file-write-create (vnode-type FIFO SOCKET CHARACTER-DEVICE BLOCK-DEVICE))'
  [ "${2:-}" = no-special-rule ] && special=''
  local dev="$DEV_RULE"; [ "${2:-}" = dev-subpath ] && dev='(allow file-write* (subpath "/dev"))'
  cat <<SB
(version 1)
(allow default)
(deny file-write*)
$dev
(allow file-write* (subpath "$LT"))
(allow file-write* (subpath "$1"))
(deny file-write* (literal "$1"))
(deny file-write* (subpath "$1/bin"))
(deny file-write* (subpath "$1/backups"))
$sym
$special
(deny file-link (subpath "$1"))
SB
}
profile "$B" > "$T/lane.sb"
lane() { AGENTBUS_DB="$B/bus.db" /usr/bin/sandbox-exec -f "$T/lane.sb" "$@"; }
lane "${AB[@]}" --as lane join --tool t >/dev/null || fail "join under the profile"
lane "${AB[@]}" --as lane post "from the sandbox" >/dev/null || fail "post under the profile"
o=$(lane "${AB[@]}" --as lane read) || fail "read under the profile"; grep -q "from the sandbox" <<<"$o" || fail "read missing the post"
if lane ln -s "$T/victim" "$B/bus.db-wal.planted" 2>/dev/null; then fail "symlink created in the bus folder"; fi
if lane ln "$T/victim" "$B/hard" 2>/dev/null; then fail "hard link to an outside file created"; fi
echo inside > "$B/inside"
if lane ln "$B/inside" "$B/inside-link" 2>/dev/null; then fail "hard link inside the bus folder created"; fi
[ ! -e "$B/inside-link" ] || fail "hard link inside the bus folder exists"
# The case the CLI alone cannot close: a hard-linked -journal planted before the CLI connects.
if lane ln "$T/victim" "$B/bus.db-journal" 2>/dev/null; then fail "hard-linked -journal planted"; fi
[ ! -e "$B/bus.db-journal" ] || fail "-journal exists after a refused link"
lane sh -c "echo x > '$B/plain' && mv '$B/plain' '$B/plain2' && rm '$B/plain2'" || fail "ordinary create, rename, delete in the bus folder"
lane "${AB[@]}" --as lane post "after the link probes" >/dev/null || fail "post after the link probes"
if lane sh -c "echo x > '$B/bin/agentbus'" 2>/dev/null; then fail "bin/agentbus writable"; fi
# Bug these catch: with only folder-scoped rules, a lane moved the whole .agentbus into its own tmp
# dir, rewrote bin/agentbus there and moved it back; the brain then ran the lane's code.
if lane mv "$B" "$LT/ab" 2>/dev/null; then lane mv "$LT/ab" "$B" 2>/dev/null || true; fail "the bus folder itself can be moved"; fi
if lane mv "$B/bin" "$LT/bin" 2>/dev/null; then fail "bin/ can be moved out"; fi
# A symlink made anywhere the lane can write could be swapped into the folder (renamex_np), so none may be made.
if lane ln -s "$T/victim" "$LT/s" 2>/dev/null; then fail "symlink created in the lane's own tmp dir"; fi
echo own > "$LT/own"; lane ln "$LT/own" "$LT/own2" 2>/dev/null || true
if [ -e "$LT/own2" ] && lane mv "$LT/own2" "$B/bus.db-journal" 2>/dev/null; then fail "a hard link made outside moved into the bus folder"; fi
lane mkdir "$LT/d" && lane mv "$LT/d" "$B/d" || fail "moving a plain directory into the bus folder"
lane "${AB[@]}" --as lane post "after the move probes" >/dev/null || fail "post after the move probes"
[ "$(sed -n 2p "$B/bin/agentbus")" = "$(sed -n 2p "$BIN")" ] || fail "bin/agentbus changed"
# Bug these catch: backups/ was lane-writable, and the upgrade guide restores the tool copy from it into bin/,
# which the brain then runs unsandboxed. backups/ is made here as `upgrade` makes it, by the unsandboxed CLI.
mkdir -m 700 "$B/backups"; cp -p "$B/bin/agentbus" "$B/backups/agentbus-STAMP"
if lane sh -c "echo x > '$B/backups/agentbus-STAMP'" 2>/dev/null; then fail "backups/ copy writable"; fi
if lane sh -c "echo x > '$B/backups/agentbus-NEW'" 2>/dev/null; then fail "a file can be created in backups/"; fi
if lane mv "$B/backups" "$B/backups2" 2>/dev/null; then fail "backups/ can be renamed"; fi
if lane rm "$B/backups/agentbus-STAMP" 2>/dev/null; then fail "a backup can be deleted"; fi
cmp -s "$B/bin/agentbus" "$B/backups/agentbus-STAMP" || fail "the backup copy changed"
rm -r "$B/backups"
# Bug it catches: the profile allowed writes to all of /dev, so a lane could type escape sequences into
# another of the user's terminals. The control shows the probe can see a write.
if other_tty "$T/lane.sb"; then fail "a lane can write to another terminal"; fi
profile "$B" dev-subpath > "$T/devsub.sb"; other_tty "$T/devsub.sb" || fail "control: no write to the pty even with all of /dev"
if lane sh -c "echo x > '$R/elsewhere'" 2>/dev/null; then fail "write outside the grant"; fi
[ "$(cat "$T/victim")" = keep ] || fail "victim changed"
ok "profile: bus works; no symlink anywhere, no hard link in the bus folder (a planted -journal included), the folder, bin/ and backups/ cannot be moved or written, no other terminal"

echo "TEST: a symlink made before the sandbox started cannot be swapped into the bus folder"
# renamex_np(RENAME_SWAP) exchanges two names without creating either, so a create rule on the
# folder alone never sees it. The global symlink rule is what refuses it; the control shows that.
cat > "$T/swap.py" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
RENAME_SWAP = 2
if libc.renamex_np(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), RENAME_SWAP) != 0:
    e = ctypes.get_errno(); sys.exit("renamex_np: " + os.strerror(e))
PY
ln -s "$T/victim" "$LT/pre-link"   # made by the test, outside any sandbox
echo bus > "$B/swapme"
if lane "$PY" "$T/swap.py" "$LT/pre-link" "$B/swapme" 2>/dev/null; then fail "RENAME_SWAP put a symlink into the bus folder"; fi
[ -f "$B/swapme" ] && [ ! -L "$B/swapme" ] && [ -L "$LT/pre-link" ] || fail "swap partly happened"
if lane mv "$LT/pre-link" "$B/moved-link" 2>/dev/null; then fail "a symlink made before the sandbox was moved into the bus folder"; fi
[ ! -e "$B/moved-link" ] && [ ! -L "$B/moved-link" ] || fail "moved symlink exists in the bus folder"
# What the profile does not stop: a directory moved in whole carries a symlink made before the
# sandbox with it. It cannot be moved on to a bus file's name, but it is why the dispatcher's sweep
# after the lane must be recursive (docs/sandboxed-agents.md).
mkdir "$LT/carrier"; ln -s "$T/victim" "$LT/carrier/inner"
lane mv "$LT/carrier" "$B/carrier" || fail "moving a directory into the bus folder"
[ -L "$B/carrier/inner" ] || fail "expected the nested symlink to arrive with its directory"
if lane mv "$B/carrier/inner" "$B/bus.db-wal" 2>/dev/null; then fail "a nested symlink was moved to a bus file name"; fi
[ ! -L "$B/bus.db-wal" ] || fail "bus.db-wal is a symlink"
rm -r "$B/carrier"
# Negative control: the same swap, under the profile without the global symlink rule, succeeds.
CB="$T/control/.agentbus"; mkdir -p "$CB"; echo bus > "$CB/swapme"; profile "$CB" no-symlink-rule > "$T/control.sb"
/usr/bin/sandbox-exec -f "$T/control.sb" "$PY" "$T/swap.py" "$LT/pre-link" "$CB/swapme" || fail "control: the swap failed even without the symlink rule"
[ -L "$CB/swapme" ] || fail "control: no symlink in the folder after the swap"
rm "$B/swapme"
ok "RENAME_SWAP and rename of a pre-existing symlink into the bus folder denied; allowed without the global symlink rule"

echo "TEST: no FIFO, socket or device node can be made anywhere, or moved into the bus folder"
# Bug it catches: the profile allowed mkfifo, and a lane looping mkfifo/rm at bus.db-journal made
# SQLite's own open of a hot journal block forever with the bus locked (10 of 30 commands hung).
mksock() { "$PY" -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
for d in "$B" "$LT"; do
  if lane mkfifo "$d/bus.db-journal" 2>/dev/null; then fail "FIFO created in $d"; fi
  [ ! -e "$d/bus.db-journal" ] || fail "$d/bus.db-journal exists after a refused mkfifo"
  if lane "$PY" -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$d/sock" 2>/dev/null; then fail "socket created in $d"; fi
  [ ! -e "$d/sock" ] || fail "$d/sock exists after a refused bind"
done
# Device nodes need root before any sandbox rule is reached, so only the rule's presence is
# checked for them: sandbox-exec refuses a profile naming a vnode type it does not know.
/usr/bin/sandbox-exec -f "$T/lane.sb" /usr/bin/true || fail "the profile with the FIFO/SOCKET/device rule does not load"
# Made before the sandbox started, outside it: cannot be moved into the folder.
mkfifo "$LT/pre-fifo"; mksock "$LT/pre-sock"
if lane mv "$LT/pre-fifo" "$B/bus.db-journal" 2>/dev/null; then fail "a FIFO made before the sandbox was moved into the bus folder"; fi
if lane mv "$LT/pre-sock" "$B/bus.db-wal" 2>/dev/null; then fail "a socket made before the sandbox was moved into the bus folder"; fi
if lane "$PY" "$T/swap.py" "$LT/pre-fifo" "$B/VERSION" 2>/dev/null; then fail "RENAME_SWAP put a FIFO into the bus folder"; fi
[ -f "$B/VERSION" ] && [ ! -p "$B/VERSION" ] && [ ! -e "$B/bus.db-journal" ] && [ ! -S "$B/bus.db-wal" ] || fail "a special file reached the bus folder: $(ls -la "$B")"
lane "${AB[@]}" --as lane post "after the FIFO probes" >/dev/null || fail "post after the FIFO probes"
# Negative control: without the rule, the same profile lets a lane make a FIFO in the bus folder.
profile "$B" no-special-rule > "$T/nospecial.sb"
/usr/bin/sandbox-exec -f "$T/nospecial.sb" mkfifo "$B/control-fifo" || fail "control: mkfifo failed even without the rule"
[ -p "$B/control-fifo" ] || fail "control: no FIFO after mkfifo"; rm "$B/control-fifo"
ok "FIFO and socket creation denied in the bus folder and the lane's tmp dir, and moving one in; allowed without the rule"

echo "TEST: a lane uses the bus when info/exclude lacks the rule (it cannot write .git)"
# Bug it catches: every command under AGENTBUS_DB tried to add .agentbus/ to .git/info/exclude,
# which the sandbox denies, so the lane could not join at all, even with the rule in .gitignore.
for gi in no-gitignore gitignore; do
  R2="$T/repo-$gi"; mkrepo "$R2"; agentbus init "$R2" >/dev/null
  if [ "$gi" = gitignore ]; then printf '.agentbus/\n' > "$R2/.gitignore"; fi
  grep -v '^\.agentbus/$' "$R2/.git/info/exclude" > "$T/ex" || true; cat "$T/ex" > "$R2/.git/info/exclude"
  ! grep -q agentbus "$R2/.git/info/exclude" || fail "$gi: the rule is still in exclude"
  before=$(cksum < "$R2/.git/info/exclude")
  B2="$R2/.agentbus"; profile "$B2" > "$T/lane-$gi.sb"
  lane2() { AGENTBUS_DB="$B2/bus.db" /usr/bin/sandbox-exec -f "$T/lane-$gi.sb" "$@"; }
  lane2 "${AB[@]}" --as lane join --tool t >/dev/null 2>"$T/err-$gi" || fail "$gi: join under the profile: $(cat "$T/err-$gi")"
  lane2 "${AB[@]}" --as lane post "sandboxed $gi" >/dev/null 2>>"$T/err-$gi" || fail "$gi: post under the profile"
  o=$(lane2 "${AB[@]}" --as lane read 2>>"$T/err-$gi") || fail "$gi: read under the profile"
  grep -q "sandboxed $gi" <<<"$o" || fail "$gi: read missing the post"
  ! grep -q Traceback "$T/err-$gi" || fail "$gi: traceback: $(cat "$T/err-$gi")"
  [ "$(cksum < "$R2/.git/info/exclude")" = "$before" ] || fail "$gi: exclude changed under the sandbox"
  if [ "$gi" = gitignore ]; then
    [ ! -s "$T/err-$gi" ] || fail "gitignore: a notice although .gitignore has the rule: $(cat "$T/err-$gi")"
  else
    grep -q "could not add .agentbus/ to .*info/exclude" "$T/err-$gi" || fail "no-gitignore: no notice about the exclude: $(cat "$T/err-$gi")"
  fi
done
ok "join, post and read work under the profile with no exclude rule, with and without the .gitignore rule"

echo "TEST: the narrow grant (bus.db, -wal and -shm only) runs the bus and denies the rest of the folder"
# The recommended macOS grant in docs/sandboxed-agents.md. Bug it catches: a grant of the whole folder lets a
# lane create bus.db-journal, new files and dirs, and rename or delete what the brain made there.
R3="$T/repo-narrow"; mkrepo "$R3"; agentbus init "$R3" >/dev/null; B3="$R3/.agentbus"
AGENTBUS_DB="$B3/bus.db" agentbus --as lead join >/dev/null   # the brain makes bus.db before the lane starts
B3RE=$(printf '%s' "$B3" | sed 's/[][\\.*^$+?(){}|]/\\&/g')
cat > "$T/narrow.sb" <<SB
(version 1)
(allow default)
(deny file-write*)
$DEV_RULE
(allow file-write* (subpath "$LT"))
(deny file-write* (subpath "$B3"))
(allow file-write* (regex #"^$B3RE/bus\.db(-wal|-shm)?\$"))
(deny file-write-create (vnode-type SYMLINK))
(deny file-write-create (vnode-type FIFO SOCKET CHARACTER-DEVICE BLOCK-DEVICE))
(deny file-link (subpath "$B3"))
SB
nl() { AGENTBUS_DB="$B3/bus.db" /usr/bin/sandbox-exec -f "$T/narrow.sb" "$@"; }
nl "${AB[@]}" --as worker join >/dev/null || fail "narrow: join"
nl "${AB[@]}" --as worker claim src/a.py >/dev/null || fail "narrow: claim"
nl "${AB[@]}" --as worker post "narrow grant" --to lead >/dev/null || fail "narrow: post"
nl "${AB[@]}" --as worker release src/a.py >/dev/null || fail "narrow: release"
o=$(AGENTBUS_DB="$B3/bus.db" agentbus --as lead inbox) || fail "narrow: lead inbox"
grep -q "narrow grant" <<<"$o" || fail "narrow: the lead did not get the post"
nl "${AB[@]}" --as worker read >/dev/null || fail "narrow: read"
nl "${AB[@]}" --as worker leave >/dev/null || fail "narrow: leave"
mkdir -m 700 "$B3/backups"; echo copy > "$B3/backups/agentbus-STAMP"
for w in "$B3/bus.db-journal" "$B3/VERSION" "$B3/bin/agentbus" "$B3/backups/agentbus-STAMP" "$B3/new"; do
  if nl sh -c "echo x > '$w'" 2>/dev/null; then fail "narrow: $w writable"; fi
done
if nl mkdir "$B3/d" 2>/dev/null; then fail "narrow: mkdir in the bus folder"; fi
if nl rm "$B3/VERSION" 2>/dev/null; then fail "narrow: VERSION deleted"; fi
if nl mv "$B3" "$LT/ab3" 2>/dev/null; then fail "narrow: the bus folder moved"; fi
if nl ln "$B3/bus.db" "$B3/bus.db-shm" 2>/dev/null; then fail "narrow: hard link at a granted name"; fi
if nl ln -s "$T/victim" "$B3/bus.db-shm" 2>/dev/null; then fail "narrow: symlink at a granted name"; fi
if nl mkfifo "$B3/bus.db-shm" 2>/dev/null; then fail "narrow: FIFO at a granted name"; fi
if other_tty "$T/narrow.sb"; then fail "narrow: a lane can write to another terminal"; fi
left=$(find "$B3" \( -type l -o -type p -o -type s -o -type b -o -type c -o \( -type f -links +1 \) \) -print)
[ -z "$left" ] || fail "narrow: the sweep found $left"
ok "narrow grant: join, claim, post, release, read, leave work; journal, VERSION, bin/, backups/, new files and dirs, links and FIFOs denied"
