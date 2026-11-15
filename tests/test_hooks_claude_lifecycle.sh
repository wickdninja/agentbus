#!/bin/bash
set -euo pipefail
# `agentbus hook claude EVENT`: the Claude Code hooks, part of the old tests/test_hooks_claude.sh (issue #31): /clear, fork and compact, a real claude -p sequence, off and doubled hooks, old agents and memory, dead processes, the hook budgets and the open todo count.
# Payloads are the captured ones in tests/fixtures/claude_hooks (docs/design/claude-hook-contract.md), with the project path swapped in.
# Every run is in a throwaway project and HOME. Bugs this file catches: a hook that exits non-zero (Claude Code
# blocks the tool call on 2), runs a bus copy found in the project, waits on a busy bus, writes to a bus it only
# reads, prints text a peer wrote, or acts under a name that belongs to another live session.
. "$(dirname "$0")/lib.sh"
. "$TESTS_DIR/hooks_claude_lib.sh"

echo "TEST 27: /clear, fork and compact keep the process's name, claims and mail; without CLAUDE_PID each session has its own"
newbus p27; SIDA=aaaaaaaa-0000-4000-8000-000000000011; SIDB=aaaaaaaa-0000-4000-8000-000000000012; SIDC=aaaaaaaa-0000-4000-8000-000000000013
SIDD=aaaaaaaa-0000-4000-8000-000000000014; SIDE=aaaaaaaa-0000-4000-8000-000000000015
N=$(dname "$SIDA"); export CLAUDE_PID=4242 CLAUDE_ENV_FILE="$T/env27"
SS "$SIDA"
ab --as peer join --tool t >/dev/null; ab --as peer post "a question" --to "$N" --kind question >/dev/null; ab --as "$N" claim keep.txt >/dev/null
END clear "$SIDA"; [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "SessionEnd clear: rc $RC out $OUT"
[[ " $(roster) " == *" $N "* ]] && ab --json claims | grep -qF keep.txt || fail "SessionEnd clear released the name or its claims mid-task: $(roster)"
hook SessionStart "$(payload session_start_clear session_id="\"$SIDB\"")"
grep -qF "as $N. " <<<"$(text_of)" && grep -qF "1 unread message for you (1 question)" <<<"$(text_of)" || fail "SessionStart after /clear did not keep the name and its mail: $OUT"
[ "$(tail -n 1 "$T/env27")" = "export AGENTBUS_AGENT=$N" ] || fail "the new session's environment file does not name $N"
UPS "$SIDB"; grep -qF "1 unread message" <<<"$(text_of)" || fail "UserPromptSubmit in the cleared session did not use the process's name: out $OUT"
PRE keep.txt "$SIDB"; quiet || fail "the cleared session's own claim is held by another name: out $OUT"
hook SessionStart "$(payload session_start_startup_print session_id="\"$SIDC\"" source=fork)"
grep -qF "as $N. " <<<"$(text_of)" || fail "a forked session got another name: $OUT"
hook SessionStart "$(payload session_start_startup_print session_id="\"$SIDC\"" source=compact)"
grep -qF "as $N. " <<<"$(text_of)" || fail "a compacted session got another name: $OUT"
[ "$(roster)" = "$N peer" ] || fail "the roster after clear, fork and compact: $(roster)"
END other "$SIDC"
[ "$(roster)" = "peer" ] && ! ab --json claims | grep -qF keep.txt || fail "the process ending did not leave: $(roster)"
unset CLAUDE_PID CLAUDE_ENV_FILE
newbus p27b; SS "$SIDD"; hook SessionStart "$(payload session_start_clear session_id="\"$SIDE\"")"
grep -qF "as $(dname "$SIDE"). " <<<"$(text_of)" || fail "without CLAUDE_PID a cleared session should have its own derived name: $OUT"
ok "one name per Claude process across /clear, fork and compact; the old name is not stranded"

echo
echo "TEST 28: the real claude -p sequence: SessionEnd other releases a derived name's claims; AGENTBUS_AGENT keeps them"
newbus p28; N=$(dname "$SID1"); SS
ab --as "$N" claim step1.txt >/dev/null
END other; hook SessionStart "$(payload session_start_resume session_id="\"$SID1\"")"
grep -qF "as $N. " <<<"$(text_of)" || fail "a resumed -p session got another name: $OUT"
! ab --json claims | grep -qF step1.txt || fail "a derived name kept its claim across SessionEnd other"
AGENTBUS_AGENT=lane-p SS; ab --as lane-p claim step1.txt >/dev/null
AGENTBUS_AGENT=lane-p END other; AGENTBUS_AGENT=lane-p hook SessionStart "$(payload session_start_resume session_id="\"$SID1\"")"
ab --json claims | grep -qF step1.txt && [[ " $(roster) " == *" lane-p "* ]] || fail "AGENTBUS_AGENT lane lost its claim across a -p run: $(roster)"
grep -qF "AGENTBUS_AGENT" "$DOCS_CC" && grep -qF "claude -p" "$DOCS_CC" || fail "docs/how-to/claude-code.md does not tell -p workers to set AGENTBUS_AGENT"
ok "claims survive a -p run only under AGENTBUS_AGENT, and the how-to says so"

echo
echo "TEST 29: hooks that are off or doubled are said once: a duplicate install shows a notice"
newbus p29; N=$(dname "$SID1")
mkdir -p "$HOME/.claude"; printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x hook claude Stop # agentbus:managed"}]}]}}' >"$HOME/.claude/settings.json"
SS; "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); assert list(d)==["hookSpecificOutput"], d' "$OUT" || fail "a setup entry without the plugin gave a notice: $OUT"
CLAUDE_PLUGIN_ROOT=/x hook SessionStart "$(payload session_start_startup_print session_id="\"$SID2\"")"
"$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["systemMessage"]=="agentbus: the plugin and agentbus setup both register hooks, so every hook runs twice. Run: agentbus setup claude --uninstall" and "hookSpecificOutput" in d, d' "$OUT" || fail "the duplicate notice is missing or wrong: $OUT"
CLAUDE_PLUGIN_ROOT=/x hook SessionStart "$(payload session_start_startup_print session_id="\"$SID2\"")"
! grep -q systemMessage <<<"$OUT" || fail "the duplicate notice repeated in the same session: $OUT"
SIDD=aaaaaaaa-0000-4000-8000-000000000042; ln -s "$T/nowhere-29" "$(memname "$P/.agentbus/bus.db" "$SIDD")"
CLAUDE_PLUGIN_ROOT=/x hook SessionStart "$(payload session_start_startup_print session_id="\"$SIDD\"")"
grep -qF "you are on this folder's bus as" <<<"$(text_of)" && grep -qF "every hook runs twice" <<<"$OUT" || fail "a memory file that is a link silenced SessionStart's duplicate notice: rc $RC out $OUT"
forget "$SIDD"
rm -f "$HOME/.claude/settings.json"
CLAUDE_PLUGIN_ROOT=/x hook SessionStart "$(payload session_start_startup_print session_id="\"$SID3\"")"
! grep -q systemMessage <<<"$OUT" || fail "a notice without a duplicate: $OUT"
ok "duplicate install: one visible notice per session, only from the plugin's copy of the hook"

echo
echo "TEST 30: agents not seen within 30 minutes are not counted, and old per-session memory is pruned"
newbus p30; N=$(dname "$SID1")
for i in 1 2 3; do ab --as "old$i" join --tool t >/dev/null; done
sql "$P/.agentbus/bus.db" "UPDATE agents SET last_seen='2020-01-01T00:00:00Z' WHERE name LIKE 'old%'"
STATE="${TMPDIR:-/tmp}/agentbus-hooks-$(id -u)"; mkdir -p "$STATE"; chmod 700 "$STATE"
touch -t 202001010000 "$STATE/stale.seen" "$STATE/stale.name"; touch "$STATE/fresh.seen"
SS; grep -qF "1 agent is on it" <<<"$(text_of)" || fail "stale agents were counted: $OUT"
[ ! -e "$STATE/stale.seen" ] && [ ! -e "$STATE/stale.name" ] && [ -e "$STATE/fresh.seen" ] || fail "per-session memory was not pruned by age: $(ls "$STATE")"
ok "live agents only; memory older than a week is removed"

echo
echo "TEST 31: dead processes' names are pruned, a linked name file is not trusted, the memory file is locked and dropped, pruning reads every entry"
newbus p31; SIDF=aaaaaaaa-0000-4000-8000-000000000021; SIDG=aaaaaaaa-0000-4000-8000-000000000022; SIDH=aaaaaaaa-0000-4000-8000-000000000023
STATE="${TMPDIR:-/tmp}/agentbus-hooks-$(id -u)"; mkdir -p "$STATE"; chmod 700 "$STATE"
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" || true
printf 'claude-aaaaaaaa' >"$STATE/proc-$DEAD.name"; printf 'claude-bbbbbbbb' >"$STATE/proc-$$.name"
for i in $(seq 1 600); do : >"$STATE/bulk-$i.seen"; done; : >"$STATE/zz-old.seen"; touch -t 202001010000 "$STATE/zz-old.seen"
SS "$SIDF"
[ ! -e "$STATE/proc-$DEAD.name" ] && [ -e "$STATE/proc-$$.name" ] || fail "a dead process's name was kept, or a live one's removed"
[ ! -e "$STATE/zz-old.seen" ] && [ -e "$STATE/bulk-600.seen" ] || fail "pruning did not reach the 600th entry, or removed fresh ones"
ab --as peer join --tool t >/dev/null; ab --as peer post "for g" --to "$(dname "$SIDG")" --kind note >/dev/null 2>&1
printf 'claude-deadbeef\n' >"$T/evil.name"; ln -s "$T/evil.name" "$STATE/$SIDG.name"
UPS "$SIDG"; grep -qF "1 unread message" <<<"$(text_of)" || fail "a linked name file was followed: out $OUT"
SS "$SIDH"
# Two hooks, one session, the interleaving forced (no luck): A holds the memory file between its read and its write; B comes
# to the lock while A holds it. With the lock, B waits and then adds its path to A's; without it, B finishes alone and A's
# write, made from its stale read, erases B's path.
payload pre_tool_use_write session_id="\"$SIDH\"" tool_input.file_path="\"$P/seen-a.txt\"" >"$T/seen-a.json"
payload pre_tool_use_write session_id="\"$SIDH\"" tool_input.file_path="\"$P/seen-b.txt\"" >"$T/seen-b.json"
PA="$T/pause-a"; PB="$T/pause-b"; mkdir -p "$PA" "$PB"
( cd "$P" && AGENTBUS_TEST_PAUSE="hook-seen-read=$PA" "${AB[@]}" hook claude PreToolUse <"$T/seen-a.json" >"$T/seen-a.out" 2>/dev/null ) & PIDA=$!
wait_for "$PA/hook-seen-read.reached"
touch "$PB/hook-seen-wrote.go"                 # B only marks that its update is saved, never stops there
( cd "$P" && AGENTBUS_TEST_PAUSE="hook-seen-lock=$PB;hook-seen-wrote=$PB" "${AB[@]}" hook claude PreToolUse <"$T/seen-b.json" >"$T/seen-b.out" 2>/dev/null ) & PIDB=$!
# B is at the lock point (it gets there before it tries the lock, in both builds). Event-driven: wait for it, up to 60 s.
for i in $(seq 1 1200); do [ -e "$PB/hook-seen-lock.reached" ] && break; sleep 0.05; done
[ -e "$PB/hook-seen-lock.reached" ] || fail "the second hook never reached the lock point within 60 s"
touch "$PB/hook-seen-lock.go"
# Without a lock B saves its update and says so (hook-seen-wrote); with it B cannot get past the lock while A holds the file,
# so the mark never comes. That absence is the one bounded wait here: up to 4 s after B was let go (B's work from the lock
# to the mark is a few milliseconds), so only a B that stalls for seconds right then could hide a missing lock.
for i in $(seq 1 80); do [ -e "$PB/hook-seen-wrote.reached" ] && break; sleep 0.05; done
touch "$PA/hook-seen-read.go"
wait "$PIDA" "$PIDB" || true
[ -s "$T/seen-a.out" ] && [ -s "$T/seen-b.out" ] || fail "the forced-interleaving hooks did not both answer: a=$(cat "$T/seen-a.out") b=$(cat "$T/seen-b.out")"
MEMH=$(memfile "$SIDH"); [ "$(grep -c 'seen-[ab].txt' "$MEMH")" = 2 ] || fail "parallel hooks lost memory updates: kept $(tr '\n' ' ' <"$MEMH")"
# find -quit, not `ls | grep -q`: under pipefail grep -q quits at the first match, ls dies of SIGPIPE writing the rest of
# this 600-file listing, and the negated pipeline then passes with the file still there (907 of 1000 runs on one Linux CPU).
END other "$SIDH"; [ -z "$(find "$STATE" -maxdepth 1 -name "$SIDH.*" -print -quit)" ] || fail "the memory file outlived the session"
rm -f "$STATE"/bulk-*.seen "$STATE/proc-$$.name"
# The memory folder replaced by a link: SessionEnd still leaves.
SIDK=aaaaaaaa-0000-4000-8000-000000000024; NK=$(dname "$SIDK"); SS "$SIDK"
[[ " $(roster) " == *" $NK "* ]] || fail "31: setup: $NK did not join"
mv "$STATE" "$STATE.real"; ln -s "$STATE.real" "$STATE"
END other "$SIDK"
rm "$STATE"; mv "$STATE.real" "$STATE"
[[ " $(roster) " != *" $NK "* ]] || fail "SessionEnd with the memory folder a link left the name on the roster: $(roster)"
ok "dead pids pruned, links ignored, two forced-interleaved updates both kept, memory dropped at SessionEnd"

echo
echo "TEST 22: handler p95 under 250 ms over 20 runs on a 50-agent bus; the whole hook within fixed CPU and wall bounds"
newbus p22; N=$(dname "$SID1"); SS
"$PY" -I - "$P/.agentbus/bus.db" "$N" <<'PY'
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1])
fresh = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
for i in range(50):
    con.execute("INSERT INTO agents(name,tool,joined_at,last_seen) VALUES(?,?,?,?)", (f"peer{i}", "t", fresh, fresh))
    con.execute("INSERT INTO messages(ts,sender,recipient,kind,body) VALUES(?,?,?,?,?)", (fresh, f"peer{i}", sys.argv[2], "note", "b"))
con.commit(); con.close()
PY
payload user_prompt_submit session_id="\"$SID1\"" >"$T/pl"
# Under scripts/mutate.py (it sets AGENTBUS_MUTATION_RUN=1) both bounds are printed, not enforced: there up to four copies
# of this file share the runner and the mutated copy is compiled on every run, so a miss measures the runner, and it
# failed entries whose own assertion comes later in this file (issue #73). No entry is meant to be killed by a bound;
# the test jobs run without the variable and enforce both. The handler's answer and the exit status are checked always.
# Both are budgets, and a wall clock under load measures the machine (issue #31: failed at a load of 500 to 900), so:
# the handler is held to the CPU time it used (time.process_time), which load barely moves, and the process to its CPU and
# wall bounds in the best of 3 rounds of 20 (a round that load spoiled proves nothing: a hook that is really too slow
# spoils every round; on an idle machine it is one round).
# The handler itself, in this process, 20 times: the plan's 250 ms of CPU (it excludes starting Python).
"$PY" -I - "${AGENTBUS_BIN:-$BIN}" "$P" "$T/pl" <<'PY' || fail "handler p95 over the 250 ms budget"
import json, os, runpy, sys, time
m = runpy.run_path(sys.argv[1], run_name="agentbus_hook")
os.chdir(sys.argv[2]); payload = json.load(open(sys.argv[3]))
times = []
for _ in range(20):
    t0 = time.process_time()
    result = m["hook_user_prompt"](payload)
    times.append(time.process_time() - t0)
    assert result and result[0].startswith("agentbus: 50 unread messages for you"), result
times.sort()
print("handler p95 %.0f ms of CPU" % (times[18] * 1000))
sys.exit(0 if times[18] <= 0.25 or os.environ.get("AGENTBUS_MUTATION_RUN") == "1" else 1)
PY
# The whole process, 20 runs: CPU (child user+system) at most 250 ms and wall at most 1 s at the 95th percentile, wall in the best of 3 rounds.
# It is the process the plugin starts, hooks/launch.py as hooks/hooks.json names it: run as a script, bin/agentbus is
# compiled from source on every run (half the CPU), and the launcher keeps the bytecode. An installed command or a
# mutation copy under test (AGENTBUS_CMD, AGENTBUS_BIN) is run as given. The first of the 20 fills the cache (the 95th
# percentile of 20 leaves the slowest out); the user's PYTHONDONTWRITEBYTECODE and XDG_CACHE_HOME are not passed on.
if [ -n "${AGENTBUS_CMD:-}" ] || [ -n "${AGENTBUS_BIN:-}" ]; then HB=("${AB[@]}"); else HB=("$PY" "$CHECKOUT/hooks/launch.py"); fi
"$PY" -I - "$T/pl" "$P" "${HB[@]}" <<'PY' || fail "hook process p95 over its CPU or wall bound"
import os, resource, subprocess, sys, time
pl, cwd, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
env = {k: v for k, v in os.environ.items() if k not in ("PYTHONDONTWRITEBYTECODE", "XDG_CACHE_HOME")}
for attempt in range(3):
    wall, cpu = [], []
    for _ in range(20):
        r0, t0 = resource.getrusage(resource.RUSAGE_CHILDREN), time.time()
        p = subprocess.run([*argv, "hook", "claude", "UserPromptSubmit"], stdin=open(pl), capture_output=True, cwd=cwd, env=env, timeout=60)
        r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
        wall.append(time.time() - t0); cpu.append(r1.ru_utime + r1.ru_stime - r0.ru_utime - r0.ru_stime)
        assert p.returncode == 0 and p.stdout, (p.returncode, p.stdout, p.stderr)
    wall.sort(); cpu.sort()
    print("process p95 wall %.0f ms, cpu %.0f ms (round %d)" % (wall[18] * 1000, cpu[18] * 1000, attempt + 1))
    if cpu[18] <= 0.25 and wall[18] <= 1.0 or os.environ.get("AGENTBUS_MUTATION_RUN") == "1":
        sys.exit(0)
sys.exit(1)
PY
ok "UserPromptSubmit: handler and process inside their bounds"

echo
echo "TEST 60: SessionStart says how many todos are open, only when there are some"
# Bug it catches: a promise recorded before a crash was invisible to the next session until it ran brief, so nothing
# prompted it to.
newbus p24; N=$(dname "$SID1")
ab --as a join --tool t >/dev/null
SS; ! grep -q "open todo" <<<"$(text_of)" || fail "SessionStart mentions todos when none are open: $OUT"
t1=$(ab --as a --json post "validate X" --kind todo | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["id"])')
t2=$(ab --as a --json post "validate Y" --to gone --kind todo | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["id"])')
ab --as a post "validate Z" --kind todo >/dev/null
ab --as a post "Y not needed" --kind dropped --reply-to "$t2" >/dev/null
SS "$SID2"; got=$(text_of)
grep -qF ", 2 open todos, " <<<"$got" || grep -qF ", 2 open todos." <<<"$got" || fail "SessionStart does not count the 2 open todos: $got"
[ ${#got} -le 600 ] || fail "SessionStart text is ${#got} characters with todos"
ab --as a post "X validated" --kind done --reply-to "$t1" >/dev/null
SIDT=aaaaaaaa-0000-4000-8000-0000000000a3; SS "$SIDT"; grep -qF ", 1 open todo" <<<"$(text_of)" || fail "SessionStart does not count 1 open todo: $OUT"
! grep -qF "1 open todos" <<<"$(text_of)" || fail "SessionStart says '1 open todos'"
ok "SessionStart: the open todo count, nothing when none, singular for one"

echo
echo "TEST 60b: on a bus of 100,000 messages SessionStart still counts the open todos inside the hook's budget"
# Bug it catches: a per-todo scan of the table (no index on reply_to) took longer than the 0.5 s SQL budget at this size, the
# query was interrupted and the hook printed nothing. The count must arrive as a number, not as 'run brief'.
newbus p24b; N=$(dname "$SID1")
ab --as a join --tool t >/dev/null
"$PY" -I - "$P/.agentbus/bus.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
rows = [(i, "2026-11-01T00:00:00Z", "a", "*", "todo" if i % 20 == 1 else "note", "b") for i in range(1, 100001)]
con.executemany("INSERT INTO messages(id,ts,sender,recipient,kind,body) VALUES(?,?,?,?,?,?)", rows)
todos = [r[0] for r in rows if r[4] == "todo"]
notes = [r[0] for r in rows if r[4] == "note"]
con.executemany("UPDATE messages SET kind='done', reply_to=? WHERE id=?", [(t, notes[-1 - i]) for i, t in enumerate(todos[:4999])])
con.commit(); con.close()
PY
SS; got=$(text_of)
grep -qF ", 1 open todo" <<<"$got" && ! grep -qF "run brief" <<<"$got" || fail "SessionStart on 100,000 messages did not count the 1 open todo within budget: rc $RC out $OUT"
ok "SessionStart counts open todos among 100,000 messages"


echo
echo "TEST 99: every output this file made is built from the documented templates"
check_templates 15
ok "every output is a template with digits, kinds and the agent's own name only"

all_passed "All claude hook tests passed (lifecycle)"
