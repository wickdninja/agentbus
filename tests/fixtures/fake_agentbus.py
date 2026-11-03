"""A stand-in for the NEW agentbus a stub installer "installs", for tests/test_update.sh: it logs its argument
list and working folder to $FAKE_LOG and answers the three calls `agentbus update` makes of the new executable
(--version, upgrade DIR --json, setup TARGET --refresh --json). $FAKE_SETUP is a file of the JSON setup prints."""
__version__ = "0.0.0"
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("ARGV: %s\nCWD: %s\n" % (" ".join(args), os.getcwd()))
if args == ["--version"]:
    print("agentbus " + __version__)
elif args[:1] == ["upgrade"]:
    d = [a for a in args[1:] if not a.startswith("--")][-1]
    print(json.dumps({"directory": d, "old": "0.2.0", "new": __version__, "schema_old": 1, "schema_new": 1, "backup": None}))
elif args[:1] == ["setup"]:
    p = os.environ.get("FAKE_SETUP", "")
    print(open(p).read() if p and os.path.exists(p) else json.dumps({"target": args[1], "scope": "user", "dry_run": False, "changes": []}))
else:
    sys.exit(2)
