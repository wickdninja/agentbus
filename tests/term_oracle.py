"""An emulated wrapping terminal for the output tests, independent of bin/agentbus: character widths
come from the C library's wcwidth (through ctypes, in a UTF-8 locale), never from Python's
unicodedata tables or any code copied from the CLI. wcwidth -1 (unknown, unprintable) counts as 2,
the widest any terminal draws one character.

    from term_oracle import width, rows
    rows(line, columns) -> the physical rows a terminal shows for one output line
"""
import ctypes
import ctypes.util
import locale

for _loc in ("en_US.UTF-8", "C.UTF-8", "C.utf8", "UTF-8"):
    try:
        locale.setlocale(locale.LC_CTYPE, _loc)
        break
    except locale.Error:
        continue
else:
    raise SystemExit("term_oracle: no UTF-8 locale, so wcwidth cannot be trusted")

_libc = ctypes.CDLL(ctypes.util.find_library("c"))
_libc.wcwidth.argtypes = [ctypes.c_int32]
_libc.wcwidth.restype = ctypes.c_int
# The locale took: a CJK ideograph is 2 columns and a combining grave accent 0.
if (_libc.wcwidth(0x6F22), _libc.wcwidth(0x61), _libc.wcwidth(0x300)) != (2, 1, 0):
    raise SystemExit("term_oracle: wcwidth does not see a UTF-8 locale")

_cache = {}


def width(ch):
    w = _cache.get(ch)
    if w is None:
        w = _libc.wcwidth(ord(ch))
        w = 2 if w < 0 else w
        _cache[ch] = w
    return w


def rows(line, columns):
    """One output line as a terminal at `columns` shows it: a character that does not fit on the
    current row starts the next one at column 0 (zero-width characters stay where they are)."""
    out, row, col = [], [], 0
    for ch in line:
        w = width(ch)
        if w and col + w > columns:
            out.append("".join(row))
            row, col = [], 0
        row.append(ch)
        col += w
    out.append("".join(row))
    return out


# ---- a terminal session under a pty, for the live tests (watch, and the workflow tests that reuse it) ----

class PtySession:
    """One process on a fresh pty, in its own session and process group, so signals reach only it.

        s = PtySession(argv, env, cols=100, rows=30)
        s.until(lambda text: "Agents" in text, 10, "the first frame")   # bounded wait on content, never a sleep
        s.send(b"q"); rc = s.wait(10)
        assert s.termios_now() == s.before                             # modes as they were before it started

    The slave's modes are read before the start (after priming macOS's PENDIN state the way a cbreak program
    leaves it), so `before` is what the terminal must be again after any exit. close() kills the process
    group it started (and only that one) if it is still running."""

    def __init__(self, argv, env, cols=100, rows=30, preexec=None):
        import fcntl, pty, struct, subprocess, termios, tty
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        initial = termios.tcgetattr(self.slave)
        tty.setcbreak(self.slave)
        termios.tcsetattr(self.slave, termios.TCSANOW, initial)
        self.before = termios.tcgetattr(self.slave)

        def pre():
            import os
            os.setsid()
            if preexec:
                preexec()
        self.p = subprocess.Popen(argv, stdin=self.slave, stdout=self.slave, stderr=self.slave, env=env, preexec_fn=pre)
        self.buf = b""

    def pump(self, seconds=0.05):
        import os, select
        r, _, _ = select.select([self.master], [], [], seconds)
        if r:
            try:
                data = os.read(self.master, 65536)
            except OSError:
                return False
            self.buf += data
            return bool(data)
        return False

    @property
    def text(self):
        return plain(self.buf).decode("utf-8", "replace")

    def until(self, cond, seconds, what, since=0):
        """Read until cond(text after byte `since`, SGR removed) holds; fail after `seconds`."""
        import time
        end = time.monotonic() + seconds
        while True:
            if cond(plain(self.buf[since:]).decode("utf-8", "replace")):
                return
            if time.monotonic() > end:
                raise AssertionError(f"timed out waiting for {what}: ...{self.buf[-800:]!r}")
            self.pump(0.02)

    def mark(self):
        return len(self.buf)

    def send(self, data):
        import os
        os.write(self.master, data)

    def frames(self, since=0, raw=False):
        """The complete frames drawn after byte `since`, each a list of rows (SGR removed unless raw)."""
        out = []
        for part in self.buf[since:].split(b"\x1b[H")[1:]:
            end = part.find(b"\x1b[J")
            if end < 0:
                continue
            body = part[:end]
            rows = body.replace(b"\r\n", b"\n").split(b"\x1b[K\n")
            if rows and rows[-1].endswith(b"\x1b[K"):
                rows[-1] = rows[-1][:-3]
            out.append([(r if raw else plain(r)).decode("utf-8", "replace") for r in rows])
        return out

    def frame_after(self, since, cond, seconds, what):
        """The first complete frame after `since` for which cond(rows) holds."""
        import time
        end = time.monotonic() + seconds
        while True:
            for f in self.frames(since):
                if cond(f):
                    return f
            if time.monotonic() > end:
                fs = self.frames(since)
                raise AssertionError(f"timed out waiting for {what}: last frame {fs[-1] if fs else None}")
            self.pump(0.02)

    def resize(self, cols, rows):
        import fcntl, os, signal, struct, termios
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.killpg(self.p.pid, signal.SIGWINCH)

    def signal(self, sig):
        import os
        os.killpg(self.p.pid, sig)

    def wait(self, seconds):
        """Keep draining (a full pty would block its writes) until the process exits; its exit status."""
        import time
        end = time.monotonic() + seconds
        while self.p.poll() is None:
            if time.monotonic() > end:
                raise AssertionError(f"process still running after {seconds}s: ...{self.buf[-600:]!r}")
            self.pump(0.02)
        while self.pump(0.02):
            pass
        return self.p.returncode

    def termios_now(self):
        import termios
        return termios.tcgetattr(self.slave)

    def close(self):
        import os, signal
        if self.p.poll() is None:
            try:
                os.killpg(self.p.pid, signal.SIGKILL)
            except OSError:
                pass
            self.p.wait(5)
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass


def plain(b):
    """Terminal output without SGR colour codes."""
    import re
    return re.sub(rb"\x1b\[[0-9;]*m", b"", b)
