#!/bin/bash
# bash scripts/e2e_claude.sh   a real `claude -p` run with this checkout loaded as the plugin (--plugin-dir).
# Needs the claude CLI, signed in, and a supported Claude Code version; it makes one short model call. Not part of
# tests/run_all.sh (no model calls in the suite). Ends with `claude e2e passed` or a failure line.
# It shows, on a real run, that: the SessionStart hook fired and its text names the session's agent; the agent is on
# the bus roster after the first prompt (the agent runs `who` itself); the session's end left the bus again.
# E2E_TRANSCRIPT=FILE keeps the stream-json transcript (for the issue).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v claude >/dev/null 2>&1 || { echo "FAIL: claude is not on PATH"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is not on PATH"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TREAL=$(cd "$T" && pwd -P)
case "$TREAL/" in "$ROOT"/*|"${AGENTBUS_TEST_FORBIDDEN_ROOT:-/nonexistent-root}"/*) echo "FAIL: the scratch folder $T is inside the checkout or AGENTBUS_TEST_FORBIDDEN_ROOT; set TMPDIR elsewhere"; exit 2 ;; esac
unset AGENTBUS_DB AGENTBUS_AGENT AGENTBUS_HOOKS
P="$T/proj"; mkdir -p "$P"
git -C "$P" init -q
python3 "$ROOT/bin/agentbus" init "$P" >/dev/null
BUS="$P/.agentbus/bin/agentbus"
STREAM="$T/stream.jsonl"
echo "claude $(claude --version 2>&1 | head -n 1), plugin from $ROOT, scratch project $P"
(
  cd "$P"
  claude -p "Run exactly this command with the Bash tool and then reply with the single word done: .agentbus/bin/agentbus who" \
    --model haiku --plugin-dir "$ROOT" --setting-sources project --strict-mcp-config \
    --permission-mode acceptEdits --allowedTools "Bash(.agentbus/bin/agentbus:*)" \
    --output-format stream-json --verbose --include-hook-events >"$STREAM" 2>"$T/claude.err"
) || { echo "FAIL: claude -p failed: $(tail -n 5 "$T/claude.err")"; exit 1; }
[ -z "${E2E_TRANSCRIPT:-}" ] || cp "$STREAM" "$E2E_TRANSCRIPT"
python3 -I - "$STREAM" <<'PY' || exit 1
import json, re, sys
events = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line:
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
text = json.dumps(events)
m = re.search(r"agentbus: you are on this folder's bus as (claude-[0-9a-f]{8})\. 1 agent is on it, no unread messages for you\. Use --as \1 on every command\.", text)
if not m:
    sys.exit("FAIL: the SessionStart text is not in the transcript (did the hook fire?)")
name = m.group(1)
# the agent's own `who` ran as that name's bus: the tool result lists it
results = [b.get("content") for e in events if e.get("type") == "user" for b in (e.get("message", {}).get("content") or []) if isinstance(b, dict) and b.get("type") == "tool_result"]
if not any(name in json.dumps(r) for r in results):
    sys.exit(f"FAIL: no tool result lists {name} on the roster; results: {json.dumps(results)[:400]}")
print(f"SessionStart named {name}; `who` listed it")
open(sys.argv[1] + ".name", "w").write(name)
PY
NAME=$(cat "$STREAM.name")
LOG=$(cd "$P" && python3 "$ROOT/bin/agentbus" --json log show --limit 50)
python3 -I - "$NAME" "$LOG" <<'PY' || exit 1
import json, sys
name, log = sys.argv[1], json.loads(sys.argv[2])
actions = [r["action"] for r in log["items"] if r["agent"] == name]
if actions[:1] != ["join"] or "leave" not in actions:
    sys.exit(f"FAIL: expected join then leave for {name} in the bus log, got {actions}")
print(f"the bus log shows {name}: {actions}")
PY
WHO=$(cd "$P" && python3 "$ROOT/bin/agentbus" --json who)
python3 -I - "$NAME" "$WHO" <<'PY' || exit 1
import json, sys
if any(r["name"] == sys.argv[1] for r in json.loads(sys.argv[2])["items"]):
    sys.exit(f"FAIL: {sys.argv[1]} is still on the roster after the session ended")
PY
echo "claude e2e passed"
