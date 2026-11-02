#!/bin/bash
set -euo pipefail
# tests/schema_check.py is what the workflow tests validate `--json` replies with, so it must reject a wrong reply:
# a missing key, a wrong type, a value outside an enum, below a minimum, a bad item, no anyOf branch, a bad $ref.
. "$(dirname "$0")/lib.sh"
"$PY" -I -B - "$TESTS_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from schema_check import validate, check_schema
objects = {"Msg": {"type": "object", "required": ["id", "kind"], "properties": {"id": {"type": "integer", "minimum": 1}, "kind": {"enum": ["note", "done"]}, "topic": {"type": ["string", "null"]}}}}
env = {"type": "object", "required": ["v", "items"], "properties": {"v": {"type": "integer"}, "items": {"type": "array", "items": {"$ref": "#/objects/Msg"}}, "next": {"anyOf": [{"type": "string"}, {"type": "null"}]}}}
failures = []
def want(label, instance, errors_expected, schema=env):
    got = validate(instance, schema, objects)
    if bool(got) != errors_expected:
        failures.append("%s: expected %s, got %r" % (label, "errors" if errors_expected else "none", got))
good = {"v": 1, "items": [{"id": 1, "kind": "note", "topic": None, "extra": True}], "next": None}
want("a valid reply (extra keys allowed)", good, False)
want("a missing required key", {"items": []}, True)
want("a wrong type", dict(good, v="1"), True)
want("a bool is not an integer", dict(good, v=True), True)
want("a value outside an enum", dict(good, items=[{"id": 1, "kind": "alert"}]), True)
want("below a minimum", dict(good, items=[{"id": 0, "kind": "note"}]), True)
want("a bad item in an array", dict(good, items=[{"id": 1, "kind": "note"}, {"kind": "note"}]), True)
want("no anyOf branch matches", dict(good, next=5), True)
want("a nullable string", dict(good, items=[{"id": 2, "kind": "done", "topic": "t"}]), False)
want("an unknown $ref", good, True, {"$ref": "#/objects/Nope"})
want("an array where an object is wanted", [], True)
if check_schema(env, objects) != []: failures.append("check_schema flagged a schema inside the subset")
if not check_schema({"type": "wat", "format": "x"}, objects): failures.append("check_schema accepted a keyword and a type outside the subset")
if failures:
    print("\n".join("FAIL: " + f for f in failures)); sys.exit(1)
PY
ok "schema_check accepts a valid reply and rejects each kind of wrong one"
echo "All schema check tests passed"
