#!/bin/bash
set -euo pipefail
# The Claude Code plugin: the repo root is the plugin root (.claude-plugin/, hooks/, skills/, bin/agentbus).
# Bugs this file catches: a manifest that drifted from __version__, a marketplace that installs whatever main
# holds, a hook command that searches for a tool instead of running the plugin's own, one that can exit
# non-zero, an event the real Claude Code never verified, and a hook that cannot run without python3.
# `claude plugin validate .` runs when claude is installed and is skipped (exit 77) only without claude and without CI.
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
echo "TEST 2: the marketplace plugin source is a git source with a ref that exists: main between releases, the release tag in a release"
cat >"$T/source_check.py" <<'PY'
import json, re, sys
def problem(market, dev):
    """Why a marketplace would install the wrong tree (or fail to), else None. dev: __version__ is a .devN build."""
    for p in market["plugins"]:
        s = p.get("source")
        if not isinstance(s, dict):
            return f"source {s!r} is a path"
        if s.get("source") not in ("github", "url", "git"):
            return f"source kind {s.get('source')!r}"
        ref = s.get("ref")
        if not isinstance(ref, str) or not (re.fullmatch(r"v\d+\.\d+\.\d+(rc\d+)?", ref) or (dev and ref == "main")):
            return f"ref {ref!r} is not a release tag" + (" or main" if dev else "")
    return None
if __name__ == "__main__":
    bad = problem(json.load(open(sys.argv[1])), sys.argv[2] == "dev")
    if bad:
        print(bad); sys.exit(1)
PY
KIND=release; case "$VERSION" in *.dev*) KIND=dev ;; esac
"$PY" -I "$T/source_check.py" "$ROOT/.claude-plugin/marketplace.json" "$KIND" || fail "the marketplace source is not a pinned git source: $("$PY" -I "$T/source_check.py" "$ROOT/.claude-plugin/marketplace.json" "$KIND")"
# negative controls: the checker itself must reject a path source, a missing ref, a branch, and main in a release
"$PY" -I - "$T" <<'PY' || fail "the source checker accepted a bad marketplace"
import sys
sys.path.insert(0, sys.argv[1])
from source_check import problem
def m(source): return {"plugins": [{"name": "agentbus", "source": source}]}
tag = {"source": "github", "repo": "wickdninja/agentbus", "ref": "v0.2.0"}
assert problem(m(tag), False) is None and problem(m(tag), True) is None
assert problem(m(dict(tag, ref="main")), True) is None and problem(m(dict(tag, ref="main")), False)
for source in ("./", {"source": "github", "repo": "wickdninja/agentbus"}, dict(tag, ref="feature"), dict(tag, ref=3), {"source": "npm", "package": "x", "ref": "v1.0.0"}):
    assert problem(m(source), True), source
    assert problem(m(source), False), source
PY
ok "github source with a ref that exists; ./, no ref, a branch, a non-git source and main in a release are rejected"

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
    # SessionEnd hooks share a 1.5 s budget that no plugin timeout raises (docs/design/claude-hook-contract.md, section 6)
    assert h["type"] == "command" and h["timeout"] == (2 if event == "SessionEnd" else 5), h
    want = 'python3 "${CLAUDE_PLUGIN_ROOT}/bin/agentbus" hook claude %s 2>/dev/null || true' % event
    assert h["command"] == want, (event, h["command"])
assert hooks["SessionStart"][0]["matcher"] == "startup|resume|clear|compact|fork"  # the matcher values the contract lists
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
newproj() { P="$T/proj"; rm -rf "$P"; mkdir -p "$P"; (cd "$P" && "${AB[@]}" init . >/dev/null && "${AB[@]}" who >/dev/null) || fail "init failed"; }
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
echo "TEST 7: claude plugin validate passes (runs when claude is installed; skips only without claude and without CI)"
if command -v claude >/dev/null 2>&1; then
  out=$(cd "$ROOT" && claude plugin validate . 2>&1) || fail "claude plugin validate failed: $out"
  grep -qF "Validation passed" <<<"$out" || fail "claude plugin validate did not say Validation passed: $out"
  ok "claude plugin validate ."
elif [ -n "${CI:-}" ]; then
  fail "claude is not on PATH in CI: claude plugin validate cannot run"
else
  skip_part "claude is not installed; claude plugin validate was not run"
fi

all_passed "All plugin manifest tests passed"
