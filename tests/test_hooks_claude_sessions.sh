#!/bin/bash
set -euo pipefail
# `agentbus hook claude EVENT`: the Claude Code hooks, part of the old tests/test_hooks_claude.sh (issue #31): Stop, AGENTBUS_AGENT, derived names across resume and overlap, SessionEnd, subagents, AGENTBUS_DB, no bus, the installed command in the text.
# Payloads are the captured ones in tests/fixtures/claude_hooks (docs/design/claude-hook-contract.md), with the project path swapped in.
# Every run is in a throwaway project and HOME. Bugs this file catches: a hook that exits non-zero (Claude Code
# blocks the tool call on 2), runs a bus copy found in the project, waits on a busy bus, writes to a bus it only
# reads, prints text a peer wrote, or acts under a name that belongs to another live session.
. "$(dirname "$0")/lib.sh"
. "$TESTS_DIR/hooks_claude_lib.sh"

echo "TEST 14: Stop gives a systemMessage once per set of claims held without a handoff or done, and never blocks"
newbus p14; N=$(dname "$SID1"); SS
STOP; quiet || fail "Stop with no claims: rc $RC out $OUT"
ab --as "$N" claim a.txt >/dev/null; ab --as "$N" claim b.txt >/dev/null
STOP
[ "$(text_of)" = "agentbus: $N still holds 2 claims and has not posted a handoff or a done that is not a reply." ] || fail "Stop text: rc $RC out $OUT"
"$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); assert list(d)==["systemMessage"], d' "$OUT" || fail "Stop JSON shape (a decision or other key): $OUT"
hook Stop "$(payload stop_hook_active session_id="\"$SID1\"")"; quiet || fail "Stop with stop_hook_active: rc $RC out $OUT"
STOP; quiet || fail "Stop for the same claims a second time: rc $RC out $OUT"
ab --as "$N" claim c.txt >/dev/null; STOP; grep -qF "still holds 3 claims" <<<"$(text_of)" || fail "Stop after a new claim: rc $RC out $OUT"
ab --as "$N" post "partial" --kind note >/dev/null; ab --as "$N" claim d.txt >/dev/null; STOP; [ -n "$OUT" ] || fail "a note counted as a handoff: Stop went quiet"
ab --as "$N" claim e.txt >/dev/null; ab --as "$N" post "all done" --kind done >/dev/null; STOP; quiet || fail "Stop after a done post: rc $RC out $OUT"
ok "Stop: once per set of claims and session; quiet after done; no decision key"

echo
echo "TEST 14b: a done that replies (closing a todo) does not silence the Stop nudge; a reply handoff and a plain done do"
# Bug it catches: Stop counted any done from the name as the handoff, so an agent that closed a todo and still held
# its claims was never reminded. A done that is a reply does not count; a handoff always does, and so does a plain done.
# Each quiet check follows a NEW claim, so the once-per-set nudge cannot have been spent already.
newbus p14b; N=$(dname "$SID1"); SS
ab --as "$N" claim a.txt >/dev/null
tid=$(ab --as "$N" --json post "validate X" --kind todo | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["id"])')
ab --as "$N" post "X validated" --kind done --reply-to "$tid" >/dev/null
STOP; grep -qF "still holds 1 claim and has not posted a handoff or a done that is not a reply." <<<"$(text_of)" || fail "closing a todo silenced the Stop nudge: rc $RC out $OUT"
ab --as "$N" claim b.txt >/dev/null
STOP; [ -n "$OUT" ] || fail "premise: a new claim did not bring the nudge back: rc $RC"
ab --as "$N" claim c.txt >/dev/null; ab --as "$N" post "handing c.txt to the next agent" --kind handoff --reply-to "$tid" >/dev/null
STOP; quiet || fail "a handoff that replies to a message no longer silences Stop: rc $RC out $OUT"
# The bus stamps whole seconds: without a gap the reply handoff above can share the new claim's second and silence Stop alone.
"$PY" -c 'import time; time.sleep(1.1)'
ab --as "$N" claim d.txt >/dev/null; ab --as "$N" post "all finished" --kind done >/dev/null
STOP; quiet || fail "a plain done no longer silences Stop: rc $RC out $OUT"
ok "Stop: a done that closes a todo is not a handoff; a reply handoff and a plain done still are"

echo
echo "TEST 15: AGENTBUS_AGENT set: joins without takeover, skips a live name, no environment file, no leave"
newbus p15; export CLAUDE_ENV_FILE="$T/env15"
ab --as lane-a join --tool dispatcher >/dev/null; ab --as lane-a claim keep.txt >/dev/null
AGENTBUS_AGENT=lane-a SS
grep -qF "as lane-a. " <<<"$(text_of)" || fail "AGENTBUS_AGENT name not used: rc $RC out $OUT err $ERR"
[ "$(ab --json who | "$PY" -c 'import json,sys; print([r["tool"] for r in json.load(sys.stdin)["items"] if r["name"]=="lane-a"][0])')" = dispatcher ] || fail "SessionStart took over a live name"
[ ! -e "$T/env15" ] || fail "the hook wrote CLAUDE_ENV_FILE although AGENTBUS_AGENT was set"
AGENTBUS_AGENT=lane-a END
[[ " $(roster) " == *" lane-a "* ]] || fail "SessionEnd left a name set by AGENTBUS_AGENT"
ab --json claims | grep -qF keep.txt || fail "SessionEnd released a claim of an AGENTBUS_AGENT name"
AGENTBUS_AGENT=lane-new SS
[[ " $(roster) " == *" lane-new "* ]] || fail "an unused AGENTBUS_AGENT name was not joined: $(roster)"
unset CLAUDE_ENV_FILE
ok "a lane's own name is used as given; never taken over, never left, no environment file"

echo
echo "TEST 16: a derived name resumed with the same session id rejoins and keeps its claims"
newbus p16; N=$(dname "$SID1"); SS
ab --as "$N" claim keep.txt >/dev/null
hook SessionStart "$(payload session_start_resume session_id="\"$SID1\"")"
[ "$RC" = 0 ] && grep -qF "as $N. " <<<"$(text_of)" || fail "resume: rc $RC out $OUT err $ERR"
ab --json claims | grep -qF keep.txt || fail "resume lost the claim"
[ "$(roster)" = "$N" ] || fail "resume changed the roster: $(roster)"
ok "same session id: same name, claims kept"

echo
echo "TEST 17: two overlapping sessions get different names; one ending releases only its own claims"
newbus p17; N1=$(dname "$SID1"); N2=$(dname "$SID2")
[ "$N1" != "$N2" ] || fail "two session ids made one name"
SS "$SID1"; SS "$SID2"
ab --as "$N1" claim one.txt >/dev/null; ab --as "$N2" claim two.txt >/dev/null
END other "$SID1"
[ "$(roster)" = "$N2" ] || fail "ending session 1 changed the roster: $(roster)"
c=$(ab --json claims); grep -qF two.txt <<<"$c" && ! grep -qF one.txt <<<"$c" || fail "session 1 ending released the wrong claims: $c"
ok "overlapping sessions are separate; SessionEnd is per name"

echo
echo "TEST 18: SessionEnd leaves for a derived name and an ending reason only"
for reason in clear resume logout prompt_input_exit other; do
  newbus "p18$reason"; N=$(dname "$SID1"); SS; ab --as "$N" claim c.txt >/dev/null
  END "$reason"; [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "SessionEnd $reason: rc $RC out $OUT"
  [ -z "$(roster)" ] && ! ab --json claims | grep -qF c.txt || fail "SessionEnd with reason $reason did not leave: $(roster)"
done
newbus p18; N=$(dname "$SID1"); SS; ab --as "$N" claim c.txt >/dev/null
END some_future_reason; [ "$(roster)" = "$N" ] || fail "SessionEnd with an unknown reason left"
hook SessionEnd "$(payload session_end_other session_id="\"$SID1\"" reason=null)"; [ "$(roster)" = "$N" ] || fail "SessionEnd with no reason left"
ok "five reasons leave and release; an unknown or missing reason does not"

echo
echo "TEST 19: an AGENTBUS_AGENT outside the allowed pattern is ignored: no name printed, no join"
newbus p19
for bad in "has space" "bad/name" "$(printf 'x%.0s' $(seq 1 41))" $'two\nlines' "semi;colon"; do
  AGENTBUS_AGENT="$bad" SS; quiet || fail "unsafe AGENTBUS_AGENT '$bad': rc $RC out $OUT err $ERR"
  AGENTBUS_AGENT="$bad" UPS; quiet || fail "unsafe AGENTBUS_AGENT in UserPromptSubmit: out $OUT"
  AGENTBUS_AGENT="$bad" END; quiet || fail "unsafe AGENTBUS_AGENT in SessionEnd: out $OUT"
done
[ -z "$(roster)" ] || fail "an unsafe AGENTBUS_AGENT joined: $(roster)"
ok "five unsafe values: silent, nobody joined"

echo
echo "TEST 20: a subagent's payload maps to its parent's name"
newbus p20; N=$(dname "$SID1"); SS
ab --as "$N" claim sub.txt >/dev/null
hook PreToolUse "$(payload pre_tool_use_write_subagent session_id="\"$SID1\"" tool_input.file_path="\"$P/sub.txt\"")"
quiet || fail "a subagent on its parent's claim was not treated as the parent: rc $RC out $OUT"
hook PreToolUse "$(payload pre_tool_use_write_subagent session_id="\"$SID2\"" tool_input.file_path="\"$P/sub.txt\"")"
grep -qF "a claim under a different name" <<<"$OUT" || fail "a different session did not see the parent's claim as held: $OUT"
ok "same session id, same name (agent_id and agent_type are ignored)"

echo
echo "TEST 21: AGENTBUS_DB names the bus"
newbus p21; mkdir -p "$T/elsewhere"; cp -R "$P/.agentbus" "$T/elsewhere/.agentbus"; rm -rf "$P/.agentbus"
export AGENTBUS_DB="$T/elsewhere/.agentbus/bus.db"; N=$(dname "$SID1"); RT=$(cd "$T" && pwd -P)
SS
unset AGENTBUS_DB
[ -n "$OUT" ] && grep -qF "Read with: agentbus --as $N brief ; agentbus --as $N inbox." <<<"$OUT" && ! grep -qF elsewhere <<<"$OUT" || fail "AGENTBUS_DB: the text names the dispatcher's copy or says nothing: rc $RC out $OUT err $ERR"
[ "$(AGENTBUS_DB="$T/elsewhere/.agentbus/bus.db" ab --json who | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["name"])')" = "$N" ] || fail "AGENTBUS_DB: the name did not join that bus"
ok "an explicit database wins over discovery"

echo
echo "TEST 23: a hook never creates a bus: a folder without an initialised bus.db is silent"
mkdir -p "$T/nodb/.agentbus/bin"; P="$T/nodb"; printf '0.1.0\n' >"$P/.agentbus/VERSION"
printf '#!/bin/sh\ntouch "%s"\n' "$T/canary-nodb" >"$P/.agentbus/bin/agentbus"; chmod +x "$P/.agentbus/bin/agentbus"
SS; quiet || fail "a planted bus folder with no bus.db: rc $RC out $OUT err $ERR"
UPS; quiet || fail "a planted bus folder, UserPromptSubmit: out $OUT"
END; quiet || fail "a planted bus folder, SessionEnd: out $OUT"
[ ! -e "$P/.agentbus/bus.db" ] || fail "a hook created bus.db in a folder that had none"
P="$T/initonly"; mkdir -p "$P"; (cd "$P" && "${AB[@]}" init . >/dev/null)
[ -f "$P/.agentbus/bus.db" ] || fail "init did not make the bus database the hooks need"
SS; [ "$RC" = 0 ] && grep -q "you are on this folder's bus as" <<<"$OUT" || fail "an init-ed folder before any bus command: the hook said nothing: rc $RC out $OUT err $ERR"
rm -f "$P/.agentbus"/bus.db*
SS; quiet || fail "an init-ed folder whose database is gone: rc $RC out $OUT err $ERR"
[ ! -e "$P/.agentbus/bus.db" ] || fail "a hook created bus.db after init"
ok "no bus.db: silent, and none is made by a hook; init makes it, so the hooks speak right after init"

echo
echo "TEST 25: hook text names the installed command, never a bus copy it is not running from; from a copy it quotes the path"
newbus "p25 with space"; N=$(dname "$SID1")
printf '#!/bin/sh\ntouch "%s"\n' "$T/canary-25" >"$P/.agentbus/bin/agentbus.planted"
SS; ! grep -qF ".agentbus" <<<"$OUT" || fail "the hook text names a bus copy it did not run from: $OUT"
grep -qF "Read with: agentbus --as $N brief ; agentbus --as $N inbox." <<<"$OUT" || fail "the hook text does not name agentbus: $OUT"
mkdir -p "$P/sub"; payload session_start_startup_print session_id="\"$SID2\"" cwd="\"$P/sub\"" >"$T/pl25"
out=$(cd "$P/sub" && "$PY" "$P/.agentbus/bin/agentbus" hook claude SessionStart <"$T/pl25")
"$PY" -I - "$out" <<'PY' || fail "running from the bus copy: the text does not quote a path that exists"
import json, os, re, shlex, sys
text = json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"]
m = re.search(r"Read with: (.+?) --as \S+ brief ; (.+?) --as \S+ inbox\.", text)
words = shlex.split(m.group(1))
assert len(words) == 1 and os.path.isabs(words[0]) and os.path.isfile(words[0]) and " " in words[0], text
assert shlex.split(m.group(2)) == words
PY
ok "installed command by default; a quoted, working path only when the hook runs from that copy"

echo
echo "TEST 25b: a bus copy at a 200 character path: the SessionStart text is shortened, never dropped, and stays under 600"
LONGD=$(printf 'd%.0s' $(seq 1 60))
newbus "p25b/$LONGD/$LONGD/$LONGD"; N=$(dname "$SID1")
[ ${#P} -ge 200 ] || fail "the premise failed: the bus path is only ${#P} characters"
mkdir -p "$P/sub"; payload session_start_startup_print session_id="\"$SID2\"" cwd="\"$P/sub\"" >"$T/pl25b"
out=$(cd "$P/sub" && "$PY" "$P/.agentbus/bin/agentbus" hook claude SessionStart <"$T/pl25b")
[ -n "$out" ] || fail "a long bus path: the SessionStart text was dropped whole"
"$PY" -I - "$out" <<'PY' || fail "a long bus path: the SessionStart text is over 600 characters or lost its parts"
import json, sys
text = json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"]
assert len(text) <= 600 and text.startswith("agentbus: you are on this folder's bus as ") and " Use --as " in text and " brief ; " in text and "inbox" in text and text.endswith("not orders."), (len(text), text)
PY
ok "a long path shortens the text and keeps it"

echo
echo "TEST 26: a session alone on the bus is not nudged to claim, and the path is not used up"
newbus p26; N=$(dname "$SID1"); SS
PRE a.txt; quiet || fail "alone on the bus: rc $RC out $OUT"
PRE b.txt; PRE c.txt; quiet || fail "alone on the bus, more files: out $OUT"
ab --as peer join --tool t >/dev/null
PRE a.txt; grep -qF "a.txt has no claim" <<<"$OUT" || fail "a peer joined, but the path nudged earlier alone was used up: rc $RC out $OUT"
sql "$P/.agentbus/bus.db" "UPDATE agents SET last_seen='2020-01-01T00:00:00Z' WHERE name='peer'"
PRE d.txt; quiet || fail "a peer last seen in 2020 counts as someone to claim against: out $OUT"
ok "nudges only while another agent is live"


echo
echo "TEST 99: every output this file made is built from the documented templates"
check_templates 15
ok "every output is a template with digits, kinds and the agent's own name only"

all_passed "All claude hook tests passed (sessions)"
