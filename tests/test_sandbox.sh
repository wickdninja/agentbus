#!/bin/bash
set -euo pipefail
# The residual race (see docs/sandboxed-agents.md) closes at the sandbox: a lane that cannot create
# links (symbolic or hard) in the bus folder cannot plant one. This proves the documented sandbox-exec profile does
# that and still lets the lane use the bus. macOS only; elsewhere it exits 77 (a platform skip).
. "$(dirname "$0")/lib.sh"
[ "$(uname)" = Darwin ] || skip_platform not-macos "sandbox-exec is macOS only"
[ -x /usr/bin/sandbox-exec ] || skip_platform no-sandbox-exec "/usr/bin/sandbox-exec is missing"
# A short private root, whatever TMPDIR is: a unix socket's path must fit in 104 bytes, and macOS's own TMPDIR
# (/var/folders/.../T/, nested further by the runner) made every bind here fail with "AF_UNIX path too long".
T=$(command mktemp -d /tmp/abs.XXXXXX); T=$(cd "$T" && pwd -P); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
# sockop bind|connect PATH [TEXT]: exit 0 when it worked, 1 when the sandbox refused it (EPERM or EACCES),
# 2 for any other error. A probe counts as denied only on 1, so a path that is too long fails the test
# instead of passing it as a denial.
cat > "$T/sockop.py" <<'PY'
import socket, sys
op, path = sys.argv[1], sys.argv[2]
if len(path.encode()) >= 104:
    sys.stderr.write("sockop: socket path too long (%d bytes): %s\n" % (len(path.encode()), path)); sys.exit(2)
try:
    c = socket.socket(socket.AF_UNIX); c.settimeout(3)
    if op == "bind":
        c.bind(path)
    else:
        c.connect(path)
        if len(sys.argv) > 3:
            c.sendall(sys.argv[3].encode())
except PermissionError:
    sys.exit(1)
except OSError as e:
    sys.stderr.write("sockop: %s %s: %s\n" % (op, path, e)); sys.exit(2)
PY
# sock_denied PROFILE OP PATH [TEXT]: true when the sandbox refused the socket op; fails the test on any
# other error.
sock_denied() {
  local rc=0; /usr/bin/sandbox-exec -f "$1" "$PY" "$T/sockop.py" "${@:2}" 2>"$T/sockop.err" || rc=$?
  [ "$rc" != 2 ] || fail "socket probe broke, not refused: $(cat "$T/sockop.err")"
  [ "$rc" = 1 ]
}
# The probe itself: a path too long for a socket is an error (2), never a refusal (1). Bug it catches: under a
# long TMPDIR every socket probe failed on the path, and a denial check would have passed on that failure.
long="$T/$(printf 'x%.0s' $(seq 120))"; rc=0; "$PY" "$T/sockop.py" bind "$long" 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "sockop: a too-long socket path gave $rc, not 2"
[ "${#T}" -lt 40 ] || fail "the test root $T is too long for socket paths under it"
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
mksock() { "$PY" "$T/sockop.py" bind "$1" || fail "could not make the test's own socket $1"; }
for d in "$B" "$LT"; do
  if lane mkfifo "$d/bus.db-journal" 2>/dev/null; then fail "FIFO created in $d"; fi
  [ ! -e "$d/bus.db-journal" ] || fail "$d/bus.db-journal exists after a refused mkfifo"
  sock_denied "$T/lane.sb" bind "$d/sock" || fail "socket created in $d"
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
# narrow [no-dir-rule|no-sti-rule|no-socket-rule|no-dns-allow]: the recipe's profile, or it without one rule
# (the negative controls below).
narrow() {
  local dir="(deny file-write-create (require-all (subpath \"$B3\") (vnode-type DIRECTORY)))"
  local sti='(deny file-ioctl (ioctl-command TIOCSTI))'
  local sock='(deny network-outbound (remote unix-socket))'
  local dns='(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))'
  case "${1:-}" in no-dir-rule) dir='';; no-sti-rule) sti='';; no-socket-rule) sock=''; dns='';; no-dns-allow) dns='';; esac
  cat <<SB
(version 1)
(allow default)
(deny file-write*)
$DEV_RULE
(allow file-write* (subpath "$LT"))
(deny file-write* (subpath "$B3"))
(allow file-write* (regex #"^$B3RE/bus\.db(-wal|-shm)?\$"))
$dir
(deny file-write-create (vnode-type SYMLINK))
(deny file-write-create (vnode-type FIFO SOCKET CHARACTER-DEVICE BLOCK-DEVICE))
(deny file-link (subpath "$B3"))
$sti
$sock
$dns
SB
}
narrow > "$T/narrow.sb"
for c in no-dir-rule no-sti-rule no-socket-rule no-dns-allow; do narrow $c > "$T/narrow-$c.sb"; done
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
left=$(find "$B3" \( -type l -o -type p -o -type s -o -type b -o -type c -o \( -type f -links +1 \) -o \( -type d -name 'bus.db*' \) \) -print)
[ -z "$left" ] || fail "narrow: the sweep found $left"
ok "narrow grant: join, claim, post, release, read, leave work; journal, VERSION, bin/, backups/, new files, links and FIFOs denied"

echo "TEST: no directory can be made or moved in at a granted name"
# Bug it catches: the regex grants bus.db-shm as a path, not as a file, so a lane could mkdir it or move a
# directory there (one holding a hard-linked pair); the CLI then refused the bus for every agent.
mkdir "$LT/carry"; echo a > "$LT/carry/a"; ln "$LT/carry/a" "$LT/carry/b"
if nl mkdir "$B3/bus.db-shm" 2>/dev/null; then fail "narrow: a directory made at bus.db-shm"; fi
if nl mv "$LT/carry" "$B3/bus.db-shm" 2>/dev/null; then fail "narrow: a directory moved in at bus.db-shm"; fi
[ ! -e "$B3/bus.db-shm" ] || fail "narrow: bus.db-shm exists"
AGENTBUS_DB="$B3/bus.db" agentbus --as lead post "after the directory probes" >/dev/null || fail "narrow: the lead cannot post after the directory probes"
# Negative control: without the rule the move succeeds, the sweep sees it, and the bus is refused.
/usr/bin/sandbox-exec -f "$T/narrow-no-dir-rule.sb" mv "$LT/carry" "$B3/bus.db-shm" || fail "control: the directory move failed even without the rule"
left=$(find "$B3" \( -type l -o -type p -o -type s -o -type b -o -type c -o \( -type f -links +1 \) -o \( -type d -name 'bus.db*' \) \) -print)
grep -q "bus.db-shm$" <<<"$left" && grep -q "bus.db-shm/a$" <<<"$left" && grep -q "bus.db-shm/b$" <<<"$left" \
  || fail "control: the sweep did not list the directory and both names of the hard-linked pair: $left"
if AGENTBUS_DB="$B3/bus.db" agentbus --as lead post x >/dev/null 2>&1; then fail "control: the bus was used with a directory at bus.db-shm"; fi
rm -r "$B3/bus.db-shm"
ok "a directory at a granted name is denied, made or moved in; without the rule the sweep lists it and the bus is refused"

echo "TEST: the lane cannot push input into its controlling terminal (TIOCSTI)"
# Bug it catches: inside the profile, ioctl(/dev/tty, TIOCSTI) queued "echo INJECTED" as terminal input, which
# the shell that started the lane would run after the lane exits. ctty.py gives the sandboxed child a fresh pty
# as its controlling terminal (setsid, TIOCSCTTY) and never touches the terminal this test runs in; every
# wait has a deadline.
cat > "$T/ctty.py" <<'PY'
import fcntl, os, select, signal, sys, termios, time
PROFILE, MODE = sys.argv[1], sys.argv[2]
CHILD = {
    "sti": "import fcntl, os, termios\nfd = os.open('/dev/tty', os.O_RDWR)\n"
           "for c in b'echo INJECTED\\n': fcntl.ioctl(fd, termios.TIOCSTI, bytes([c]))\n",
    "tty-ok": "import fcntl, os, termios, tty\nfd = os.open('/dev/tty', os.O_RDWR)\n"
              "fcntl.ioctl(fd, termios.TIOCGWINSZ, b'\\0' * 8)\n"
              "old = termios.tcgetattr(fd); tty.setraw(fd); termios.tcsetattr(fd, termios.TCSANOW, old)\n",
}[MODE]
m, s = os.openpty()
pid = os.fork()
if pid == 0:
    # The session leader stands in for the user's shell: it outlives the sandboxed child, then reads one
    # line of its terminal's input, which is what a shell would run next.
    code = 2
    try:
        os.close(m); os.setsid(); fcntl.ioctl(s, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(s, fd)
        kid = os.fork()
        if kid == 0:
            try:
                os.execv("/usr/bin/sandbox-exec", ["sandbox-exec", "-f", PROFILE, sys.executable, "-c", CHILD])
            finally:
                os._exit(2)
        kcode = os.waitstatus_to_exitcode(os.waitpid(kid, 0)[1])
        if MODE == "tty-ok":
            code = 0 if kcode == 0 else 1
        else:
            r, _, _ = select.select([0], [], [], 1.0)
            code = 0 if r and b"INJECTED" in os.read(0, 4096) else 1
    finally:
        os._exit(code)
os.close(s)
deadline, status, log = time.monotonic() + 20, None, b""
while status is None:
    if select.select([m], [], [], 0.1)[0]:
        try:
            log += os.read(m, 4096)
        except OSError:
            pass
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
    elif time.monotonic() > deadline:
        os.killpg(pid, signal.SIGKILL); os.waitpid(pid, 0)
        sys.exit("ctty: timeout; terminal output %r" % log)
code = os.waitstatus_to_exitcode(status)
if code not in (0, 1):
    sys.exit("ctty: harness exit %d; terminal output %r" % (code, log))
sys.exit(code)
PY
rc=0; "$PY" "$T/ctty.py" "$T/narrow.sb" sti || rc=$?
[ "$rc" != 0 ] || fail "TIOCSTI pushed input into the lane's controlling terminal"
[ "$rc" = 1 ] || fail "the TIOCSTI probe did not finish (rc $rc)"
"$PY" "$T/ctty.py" "$T/narrow.sb" tty-ok || fail "the window size or raw mode does not work under the profile"
"$PY" "$T/ctty.py" "$T/narrow-no-sti-rule.sb" sti || fail "control: no input pushed even without the TIOCSTI rule"
ok "TIOCSTI denied, the window size and raw mode still work; without the rule the input reaches the shell"

echo "TEST: the lane cannot connect to a unix socket outside the grant; DNS's socket stays open"
# Bug it catches: a lane connected to a listening socket outside the grant (ssh-agent, Docker, tmux and terminal
# multiplexers all act outside the sandbox). The listener here is the test's own, in a dir the lane cannot write.
mkdir "$T/out"
cat > "$T/listen.py" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5); s.settimeout(0.5)
end = time.time() + 30
while time.time() < end:
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    c.settimeout(2)
    try:
        data = c.recv(100)
    except OSError:
        data = b""
    with open(sys.argv[2], "ab") as f:
        f.write(data + b"\n")
    c.close()
PY
"$PY" "$T/listen.py" "$T/out/sock" "$T/out/got" & LISTENER=$!
for _ in $(seq 100); do [ -S "$T/out/sock" ] && break; sleep 0.05; done
[ -S "$T/out/sock" ] || fail "the test's listener did not start"
sock_denied "$T/narrow.sb" connect "$T/out/sock" from-lane || fail "a lane connected to a unix socket outside the grant"
/usr/bin/sandbox-exec -f "$T/narrow-no-socket-rule.sb" "$PY" "$T/sockop.py" connect "$T/out/sock" from-control || fail "control: no connect even without the socket rule"
for _ in $(seq 60); do grep -q from-control "$T/out/got" 2>/dev/null && break; sleep 0.05; done
kill "$LISTENER" 2>/dev/null || true; wait "$LISTENER" 2>/dev/null || true
grep -q from-control "$T/out/got" || fail "control: the listener got nothing"
! grep -q from-lane "$T/out/got" || fail "the listener got the lane's message"
# DNS on macOS goes through mDNSResponder's socket: the profile keeps it, and without the allow it is refused.
nl "$PY" "$T/sockop.py" connect /private/var/run/mDNSResponder || fail "the profile refuses mDNSResponder's socket (DNS)"
sock_denied "$T/narrow-no-dns-allow.sb" connect /private/var/run/mDNSResponder || fail "control: mDNSResponder reachable without the allow"
nl "${AB[@]}" --as worker join >/dev/null || fail "narrow: join again after leaving (a write needs a name on the roster)"
nl "${AB[@]}" --as worker post "after the socket probes" >/dev/null || fail "narrow: post after the socket probes"
ok "unix-socket connect outside the grant denied, mDNSResponder allowed; without the rule the connect works"
