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
