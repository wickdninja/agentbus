#!/usr/bin/env python3
"""python3 make_project.py DIR   Write the first-handoff project into DIR (created if missing, must be empty). Prints the path."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario  # noqa: E402


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    dest = argv[1]
    if os.path.exists(dest) and os.listdir(dest):
        print("make_project: %s is not empty" % dest, file=sys.stderr)
        return 2
    os.makedirs(dest, exist_ok=True)
    scenario.make_project(dest)
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
