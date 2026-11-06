#!/usr/bin/env python3
"""python3 check.py PROJECT SEED   Decide Bob's ticket: does PROJECT's feed/parse.py read the seed's carrier feed correctly?
Exit 0 and `pass` when it does, 1 and `fail` with what held otherwise. Keep this file out of the project it checks."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario  # noqa: E402


def main(argv):
    if len(argv) != 3 or not argv[2].lstrip("-").isdigit():
        print(__doc__.strip(), file=sys.stderr)
        return 2
    ok, detail = scenario.check(os.path.abspath(argv[1]), int(argv[2]))
    print(("pass " if ok else "fail ") + json.dumps(detail, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
