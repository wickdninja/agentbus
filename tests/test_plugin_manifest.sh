#!/bin/bash
set -euo pipefail
# The Claude Code plugin: the repo root is the plugin root (.claude-plugin/, hooks/, skills/, bin/agentbus).
# Bugs this file catches: a manifest that drifted from __version__, a marketplace that installs whatever main
# holds, a hook command that searches for a tool instead of running the plugin's own, one that can exit
# non-zero, an event the real Claude Code never verified, and a hook that cannot run without python3.
# `claude plugin validate .` is the release gate's; it runs here only with AGENTBUS_CLAUDE_VALIDATE=1 (the
# brain), because this file never starts the real claude.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
ROOT="$(cd "$(dirname "$BIN")/.." && pwd)"
dups=$(grep -oE '(^|[^_a-z])fail "[^"$]*"' "${BASH_SOURCE[0]}" | sed 's/^[^f]*//' | sort | uniq -d)
[ -z "$dups" ] || fail "FAIL texts used by more than one assertion: $dups"

echo "TEST 1: plugin.json and marketplace.json parse and carry __version__"
VERSION=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$BIN")
[ -n "$VERSION" ] || fail "no __version__ in bin/agentbus"
"$PY" -I - "$ROOT" "$VERSION" <<'PY' || fail "a manifest is missing a field or disagrees with __version__"
import json, sys
root, version = sys.argv[1:3]
plugin = json.load(open(root + "/.claude-plugin/plugin.json"))
market = json.load(open(root + "/.claude-plugin/marketplace.json"))
assert plugin["name"] == "agentbus", plugin["name"]
assert plugin["version"] == version, (plugin["version"], version)
for key in ("description", "author", "repository", "license", "homepage", "keywords"):
    assert plugin.get(key), key
assert market["name"] == "agentbus" and market["owner"]["name"] and market["description"], market
entries = [p for p in market["plugins"] if p["name"] == "agentbus"]
assert len(entries) == 1 and entries[0].get("description"), market["plugins"]
PY
ok "plugin.json is agentbus $VERSION; marketplace.json names one agentbus plugin"

echo
echo "TEST 2: the marketplace plugin source is a git source with a release ref, never a path"
cat >"$T/source_check.py" <<'PY'
import json, re, sys
def problem(market):
    """Why a marketplace would install whatever main holds (or fail to), else None."""
    for p in market["plugins"]:
        s = p.get("source")
        if not isinstance(s, dict):
            return f"source {s!r} is a path"
        if s.get("source") not in ("github", "url", "git"):
            return f"source kind {s.get('source')!r}"
        if not isinstance(s.get("ref"), str) or not re.fullmatch(r"v\d+\.\d+\.\d+(rc\d+)?", s["ref"]):
            return f"ref {s.get('ref')!r} is not a release tag"
    return None
if __name__ == "__main__":
    bad = problem(json.load(open(sys.argv[1])))
    if bad:
        print(bad); sys.exit(1)
PY
"$PY" -I "$T/source_check.py" "$ROOT/.claude-plugin/marketplace.json" || fail "the marketplace source is not a pinned git source: $("$PY" -I "$T/source_check.py" "$ROOT/.claude-plugin/marketplace.json")"
# negative controls: the checker itself must reject a path source, a missing ref and a branch ref
"$PY" -I - "$T" <<'PY' || fail "the source checker accepted a bad marketplace"
import sys
sys.path.insert(0, sys.argv[1])
from source_check import problem
good = {"plugins": [{"name": "agentbus", "source": {"source": "github", "repo": "wickdninja/agentbus", "ref": "v0.2.0"}}]}
assert problem(good) is None
for source in ("./", {"source": "github", "repo": "wickdninja/agentbus"}, {"source": "github", "repo": "a/b", "ref": "main"},
               {"source": "github", "repo": "a/b", "ref": 3}, {"source": "npm", "package": "x", "ref": "v1.0.0"}):
    assert problem({"plugins": [{"name": "agentbus", "source": source}]}), source
PY
ok "github source with a vX.Y.Z[rcN] ref; ./, no ref, a branch and a non-git source are rejected"

echo
echo "TEST 3: every command in hooks.json runs the plugin's own executable and ends with || true"
"$PY" -I - "$ROOT" <<'PY' || fail "a hooks.json command is not the plugin-root form"
import json, re, sys
doc = json.load(open(sys.argv[1] + "/hooks/hooks.json"))
hooks = doc["hooks"]
assert set(hooks) == {"SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "SessionEnd"}, sorted(hooks)
for event, groups in hooks.items():
    assert len(groups) == 1 and len(groups[0]["hooks"]) == 1, event
    h = groups[0]["hooks"][0]
    assert h["type"] == "command" and h["timeout"] == 5, h
    want = 'python3 "${CLAUDE_PLUGIN_ROOT}/bin/agentbus" hook claude %s 2>/dev/null || true' % event
    assert h["command"] == want, (event, h["command"])
assert hooks["SessionStart"][0]["matcher"] == "startup|resume|clear"
assert hooks["PreToolUse"][0]["matcher"] == "Edit|Write|MultiEdit|NotebookEdit"
assert all("matcher" not in hooks[e][0] for e in ("UserPromptSubmit", "Stop", "SessionEnd"))
PY
ok "five events, each: python3 \"\${CLAUDE_PLUGIN_ROOT}/bin/agentbus\" hook claude EVENT 2>/dev/null || true"

echo
echo "TEST 4: the hooks.json event names are in the verified list of the contract document, and no subagent event is registered"
"$PY" -I - "$ROOT" <<'PY' || fail "hooks.json names an event the contract document did not verify, or a subagent event"
import json, re, sys
root = sys.argv[1]
doc = open(root + "/docs/design/claude-hook-contract.md").read()
verified = set()
for line in doc.splitlines():
    m = re.match(r"\| ([A-Za-z]+) \|", line)
    if m and "VERIFIED-BY-RUN" in line:
        verified.add(m.group(1))
events = set(json.load(open(root + "/hooks/hooks.json"))["hooks"])
assert events <= verified, sorted(events - verified)
assert not any(e.startswith("Subagent") for e in events), events
PY
ok "SessionStart, UserPromptSubmit, PreToolUse, Stop and SessionEnd are VERIFIED-BY-RUN; no SubagentStart or SubagentStop"

echo
echo "TEST 5: the skill is in the plugin root, and the package ships the plugin files"
[ -s "$ROOT/skills/agentbus/SKILL.md" ] || fail "skills/agentbus/SKILL.md is missing from the plugin root"
[ -f "$ROOT/bin/agentbus" ] || fail "bin/agentbus is missing from the plugin root"
for part in '".claude-plugin/"' '"hooks/"' '"skills/"'; do
  grep -qF "$part" "$ROOT/pyproject.toml" || fail "the sdist does not include $part"
done
ok "SKILL.md, bin/agentbus; the sdist includes .claude-plugin/, hooks/ and skills/"

echo
echo "TEST 6: the registered commands run the hook, and exit 0 when python3 is not on PATH"
newproj() { P="$T/proj"; rm -rf "$P"; mkdir -p "$P"; (cd "$P" && "${AB[@]}" init . >/dev/null) || fail "init failed"; }
newproj
cmds=$("$PY" -I - "$ROOT" <<'PY'
import json, sys
for event, groups in json.load(open(sys.argv[1] + "/hooks/hooks.json"))["hooks"].items():
    print(event + "\t" + groups[0]["hooks"][0]["command"])
PY
)
SESSION=aaaaaaaa-0000-4000-8000-000000000001
printf '{"session_id":"%s","cwd":"%s","source":"startup","reason":"other","hook_event_name":"X"}' "$SESSION" "$P" >"$T/payload"
real_py=$(command -v python3)
while IFS=$'\t' read -r event cmd; do
  # Without python3 on PATH (a bare /bin/sh): the shell reports 127 for the missing command, and || true makes it 0.
  RC=0; out=$(cd "$P" && env -i HOME="$HOME" PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$cmd" <"$T/payload" 2>&1) || RC=$?
  [ "$RC" = 0 ] && [ -z "$out" ] || fail "$event without python3: exit $RC, output: $out"
  # The same command with python3 available runs the plugin's executable and exits 0.
  RC=0; out=$(cd "$P" && env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH="$(dirname "$real_py"):/usr/bin:/bin" CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$cmd" <"$T/payload" 2>/dev/null) || RC=$?
  [ "$RC" = 0 ] || fail "$event with python3: exit $RC"
  if [ "$event" = SessionStart ]; then
    grep -qF "you are on this folder's bus as claude-" <<<"$out" || fail "the registered SessionStart command printed no context: $out"
  fi
done <<<"$cmds"
ok "five registered commands: exit 0 without python3; SessionStart prints its context with it"

echo
echo "TEST 7: claude plugin validate passes (release gate; AGENTBUS_CLAUDE_VALIDATE=1)"
if [ "${AGENTBUS_CLAUDE_VALIDATE:-}" = 1 ]; then
  command -v claude >/dev/null || fail "AGENTBUS_CLAUDE_VALIDATE=1 but claude is not on PATH"
  out=$(cd "$ROOT" && claude plugin validate . 2>&1) || fail "claude plugin validate failed: $out"
  grep -qF "Validation passed" <<<"$out" || fail "claude plugin validate did not say Validation passed: $out"
  ok "claude plugin validate ."
else
  ok "not run here (the brain's release gate runs it with AGENTBUS_CLAUDE_VALIDATE=1)"
fi

all_passed "All plugin manifest tests passed"
