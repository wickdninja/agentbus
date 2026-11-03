#!/bin/bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"
export HOME="$T/home"; mkdir -p "$HOME"
EXAMPLE="$(dirname "$BIN")/../examples/two-agent-handoff.sh"
# Poison every bus setting, including a test hook: the demo must discard them all.
out=$(AGENTBUS="${AB[*]}" AGENTBUS_DB="$T/forbidden.db" AGENTBUS_AGENT=forbidden AGENTBUS_TEST_DEADLINE=0 bash "$EXAMPLE") || fail "example failed"
printf '%s\n' "$out" > "$T/transcript"
"$PY" - "$T/transcript" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r'^#1 claude -> codex \[handoff\] · [0-9]{2}:[0-9]{2}$', text, re.M), text
assert re.search(r'^#2 codex -> claude \[answer\] re #1 · [0-9]{2}:[0-9]{2}$', text, re.M), text
assert re.search(r'^  src/api/ +codex +for 2h \(until [0-9]{2}:[0-9]{2}\) +demo review$', text, re.M), text
assert '+ .agentbus/bin/agentbus claims ' in text, text
assert text.index('+ .agentbus/bin/agentbus claims ') < text.index('+ .agentbus/bin/agentbus --as codex release '), text
for name in ('codex', 'claude'):
    assert f'left as {name}, released 0 claims' in text, text
assert '+ .agentbus/bin/agentbus watch --once ' in text, text
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
