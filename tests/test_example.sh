#!/bin/bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"
export HOME="$T/home"; mkdir -p "$HOME"
EXAMPLE="$(cd "$(dirname "$BIN")/.." && pwd)/examples/two-agent-handoff.sh"   # a logical path: a mutation copy of the tree has symlinked directories
# Poison every bus setting, including a test hook: the demo must discard them all.
out=$(AGENTBUS="${AB[*]}" AGENTBUS_DB="$T/forbidden.db" AGENTBUS_AGENT=forbidden AGENTBUS_TEST_DEADLINE=0 bash "$EXAMPLE") || fail "example failed"
printf '%s\n' "$out" > "$T/transcript"
"$PY" - "$T/transcript" <<'PY' || fail "the example's transcript is not the tour it promises (run on the named agentbus, never the project copy)"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r'^#1 claude -> codex \[handoff\] · [0-9]{2}:[0-9]{2}$', text, re.M), text
assert re.search(r'^#2 codex -> claude \[answer\] re #1 · [0-9]{2}:[0-9]{2}$', text, re.M), text
assert re.search(r'^  src/api/ +codex +for 2h \(until (?:[A-Z][a-z]{2} [0-9]{1,2} )?[0-9]{2}:[0-9]{2}\) +demo review$', text, re.M), text
# Every command runs the agentbus the caller named (AGENTBUS), never the project's copy: no shipped example teaches that.
ran = [l for l in text.splitlines() if l.startswith('+ ') and 'agentbus' in l]
assert len(ran) >= 13 and not any('.agentbus/bin/agentbus' in l for l in ran), ran
def at(rest):
    return next(i for i, l in enumerate(ran) if l.endswith('agentbus ' + rest + ' '))
assert at('claims') < at('--as codex release src/api/'), text
for name in ('codex', 'claude'):
    assert f'left as {name}, released 0 claims' in text, text
assert at('watch --once') == len(ran) - 1, text
assert 'Messages  2' in text, text
assert re.search(r'^Agents  0\s*$', text, re.M), text
assert re.search(r'^Claims  0\s*$', text, re.M), text
match = re.search(r'^Demo directory: (.+)$', text, re.M)
assert match, text
assert not pathlib.Path(match[1]).exists(), match[1]
assert f'Removed demo directory: {match[1]}' in text, text
PY
[ ! -e "$T/forbidden.db" ] || fail "example used inherited bus"
ok "example: addressed handoff and reply, no claims or agents, temporary directory removed"
out=$(KEEP=1 AGENTBUS="${AB[*]}" bash "$EXAMPLE") || fail "KEEP example failed"
kept=$(printf '%s\n' "$out" | sed -n 's/^Kept demo directory: //p')
[ -n "$kept" ] && [ -f "$kept/repo/.agentbus/bus.db" ] || fail "KEEP did not retain demo bus"
rm -rf "$kept"
ok "KEEP retains the isolated demo"
# The README's form from a clone: AGENTBUS="python3 bin/agentbus" bash examples/two-agent-handoff.sh. A relative path in
# AGENTBUS must still work after the script changes directory (it resolved against the demo folder and failed).
mkdir -p "$T/clone/bin" "$T/clone/examples"
cp "$BIN" "$T/clone/bin/agentbus"; cp "$EXAMPLE" "$T/clone/examples/"
out=$(cd "$T/clone" && AGENTBUS="$PY bin/agentbus" bash examples/two-agent-handoff.sh 2>&1) || fail "the relative AGENTBUS form failed: $out"
grep -q '^Messages  2' <<<"$out" || fail "the relative AGENTBUS form did not finish the tour: $out"
ok "a relative AGENTBUS (python3 bin/agentbus) works"
