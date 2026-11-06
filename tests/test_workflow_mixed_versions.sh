#!/bin/bash
set -euo pipefail
# Workflow: two versions of the tool use one bus. The v0.1.0 copy (tests/fixtures/legacy/agentbus-0.1.0)
# and the current tool take turns on a bus the other made. Proves each reads and writes what
# the other wrote, nothing is lost either way, the v0.1.0 copy still prints bare JSON arrays, and (once the
# envelope exists) the current tool prints an object with `items`. Cells that need later streams (schema
# versions, the stale notice, hooks against an older or newer bus) are added by those streams and are
# printed as skipped until their command exists. Runs on the source script, a mutation copy
# (AGENTBUS_BIN) and an installed command (AGENTBUS_CMD).
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/workflow_lib.sh"
wf_setup
mkdir "$T/shim"; ln -s "$(command -v "$PY")" "$T/shim/python3"
LEGACY="$T/legacy-agentbus-0.1.0"
legacy_copy "$LEGACY" || skip_test "tests/fixtures/legacy/agentbus-0.1.0 is not in this tree"
old() { PATH="$T/shim:$PATH" "$PY" "$LEGACY" "$@"; }   # the v0.1.0 tool, on the bus found from the current folder
# json_shape: "array" when stdin is a JSON array, "object" when it is an object.
json_shape() { python3 -c 'import json,sys; print({list: "array", dict: "object"}[type(json.load(sys.stdin))])'; }

echo "CELL 1: the v0.1.0 copy on a bus the current tool made"
old --as legacy join --tool old >/dev/null
agentbus --as current join --tool new >/dev/null
old --as legacy post "from the old copy" --to current --kind note >/dev/null
say "#1 legacy -> current [note] · <time>
  from the old copy" agentbus --as current inbox
agentbus --as current post "from the new tool" --to legacy --kind answer --reply-to 1 >/dev/null
say "#2 current -> legacy [answer] re #1 · <time>
  from the new tool" old --as legacy inbox
is_equal "both sides' rows are in one table" "1|legacy|current|note|~
2|current|legacy|answer|1" "$(sql "SELECT id, sender, recipient, kind, reply_to FROM messages ORDER BY id")"
ok "each version reads what the other wrote"

echo "CELL 2: claims and facts written by one version are enforced and shown by the other"
old --as legacy claim src/a.py --purpose "old claim" >/dev/null
refuse 1 "agentbus: src/a.py is claimed by legacy since <TS> until <TS> (purpose: \"old claim\"). If you share a checkout with legacy, wait or ask: agentbus --as current post QUESTION --to legacy --kind question. On a separate branch, post what you are touching; the merge decides. legacy was last seen <ago>." \
  agentbus --as current claim src/a.py
agentbus --as current claim src/b.py --purpose "new claim" >/dev/null
refuse 1 "agentbus: src/b.py is claimed by current until <TS> (new claim). Do not edit it yet. Ask current with post --to current --kind question, or choose another resource." \
  old --as legacy claim src/b.py
agentbus --as current ctx set stage "from new" >/dev/null
old --as legacy ctx set stage "from old" >/dev/null
is_equal "fact history across versions" "stage|current|from new
stage|legacy|from old" "$(sql "SELECT key, updated_by, value FROM context_history ORDER BY id")"
is_equal "claims" "src/a.py|legacy
src/b.py|current" "$(sql "SELECT resource, agent FROM claims ORDER BY resource")"
ok "claims refuse across versions, facts keep both authors"

echo "CELL 3: JSON shapes"
is_equal "the v0.1.0 copy prints a bare array" "array" "$(old --json claims | json_shape)"
# The current tool prints the envelope {"contract":1,"items":[...],"has_more":...,"next":...}; the old copy keeps its bare array.
is_equal "the current tool prints the envelope" "object" "$(agentbus --json claims | json_shape)"
is_equal "the envelope's items are the old array" "$(old --json claims | python3 -c 'import json,sys; print([c["resource"] for c in json.load(sys.stdin)])')" \
  "$(agentbus --json claims | python3 -c 'import json,sys; print([c["resource"] for c in json.load(sys.stdin)["items"]])')"
ok "the current tool wraps in an envelope the rows the old copy prints as a bare array"

echo "CELL 4: cells that need later streams (run once their commands exist)"
if agentbus upgrade --help 2>&1 | grep -q -- '--all'; then   # ws01's marker: schema versions exist
  v=$(sql "PRAGMA user_version")
  [ "$v" != 0 ] || fail "the current tool left user_version 0 on a bus it wrote to"
  ok "bus schema version is $v after the current tool wrote to a v0.1.0-shape bus"
else
  skip_part "schema versions (ws01) do not exist in this build"
fi
all_passed "All workflow mixed versions tests passed"
