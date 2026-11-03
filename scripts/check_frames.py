#!/usr/bin/env python3
"""Check the frames in a design document (issue #7).

Every fenced block whose first line is `[frame NAME WxH]` must have at most H rows after that line
and no row wider than W terminal columns (East Asian Wide and Fullwidth characters count 2,
combining marks 0, everything else 1, as bin/agentbus counts them). A document with no frame fails.

    python3 scripts/check_frames.py FILE...    ends: all frames within width   (exit 0), else exit 1
"""
import re
import sys
import unicodedata

LABEL = re.compile(r"^\[frame (\S+) (\d+)x(\d+)\]$")


def width(s):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def frames(text):
    """(name, cols, rows, body lines, 1-based line of the first body row) for each labelled fenced block."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        if not lines[i].startswith("```"):
            i += 1
            continue
        j = i + 1
        while j < len(lines) and not lines[j].startswith("```"):
            j += 1
        m = LABEL.match(lines[i + 1]) if i + 1 < j else None
        if m:
            yield m.group(1), int(m.group(2)), int(m.group(3)), lines[i + 2:j], i + 3
        i = j + 1


def main(paths):
    bad = n = 0
    for path in paths:
        text = open(path, encoding="utf-8").read()
        for name, cols, rows, body, at in frames(text):
            n += 1
            if len(body) > rows:
                bad += 1
                print(f"{path}:{at}: frame {name} has {len(body)} rows, more than {rows}")
            for k, line in enumerate(body):
                if width(line) > cols:
                    bad += 1
                    print(f"{path}:{at + k}: frame {name} row is {width(line)} columns, wider than {cols}")
    if n == 0:
        print("no frames found")
        return 1
    if bad:
        print(f"{bad} problems in {n} frames")
        return 1
    print(f"{n} frames checked")
    print("all frames within width")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) if sys.argv[1:] else (print(__doc__) or 2))
