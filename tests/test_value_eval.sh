#!/bin/bash
set -euo pipefail
# The value eval (docs/evals/value-protocol.md) with a stand-in agent: no tokens, no model. Hidden tests, graders and analysis
# are proved both ways in tests/value_eval_cases.py; here the runner goes end to end, and each leak the isolation checks exist
# for is planted, to prove the check fires. Real agents are the pilot's job, not this file's.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.claude" "$T/tmp"; export TMPDIR="$T/tmp"
echo '{}' > "$HOME/.claude/settings.json"
SCRIPTS="$ROOT/scripts/value-eval"
RUN=("$PY" -B "$SCRIPTS/run.py")
STUB="$ROOT/tests/fixtures/value_stub"
export AGENTBUS_CMD="$(printf '%q ' "${AB[@]}")"
# stub ARGS...: the runner with the stand-in; output in $T/log, status in $rc.
stub() { rc=0; env VALUE_STUB_DIR="$STUB" "${RUN[@]}" --time-cap 60 --snap-every 0.2 "$@" >"$T/log" 2>&1 || rc=$?; }
grades() { "$PY" -B "$SCRIPTS/grade.py" "$1" >/dev/null; }
# field OUT PY-EXPR: evaluates EXPR for each manifest row with r (the row) and g (its grade), prints one line each
field() { "$PY" -B - "$1" "$2" <<'PY'
import json, os, sys
out, expr = sys.argv[1:3]
for line in open(os.path.join(out, "manifest.jsonl")):
    r = json.loads(line)
    p = os.path.join(out, r["id"], "grade.json")
    g = json.load(open(p)) if os.path.exists(p) else {}
    print(eval(expr))
PY
}

echo "TEST 1: hidden tests, graders and analysis, each proved on fixtures it must pass and must fail"
"$PY" -B "$ROOT/tests/value_eval_cases.py" "$SCRIPTS" || fail "value_eval_cases.py"
ok "cases pass"

echo "TEST 2: the plan is counted first, real runs need --go, and builtin has no Claude plus Codex cell"
rc=0; out=$("${RUN[@]}" --out "$T/p" --dry-run --seeds 1 2) || rc=$?
[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "value eval: 70 runs" ] || fail "plan: rc $rc: $(sed -n 1p <<<"$out")"
grep -q 'builtin cx' <<<"$out" && fail "a builtin cx cell was planned"
[ "$("${RUN[@]}" --out "$T/p" --dry-run --seeds 1 2)" = "$out" ] || fail "one order seed gave two plans"
[ "$("${RUN[@]}" --out "$T/p" --dry-run --seeds 1 2 --order-seed 9)" != "$out" ] || fail "the order seed changes nothing"
rc=0; out=$("${RUN[@]}" --out "$T/p" --tasks control --conditions none --pairings cc 2>&1) || rc=$?
[ "$rc" = 3 ] && grep -q -- '--go' <<<"$out" || fail "no --go: rc $rc: $out"
rc=0; out=$("${RUN[@]}" --out "$T/p" --go --claude-launcher /bin/false --tasks control --conditions none --pairings cx 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "Codex needs --codex-route exec" <<<"$out" || fail "Codex with no route must refuse before any run: rc $rc: $out"
[ ! -e "$T/p" ] || fail "a refused batch made its output folder"
ok "plans are counted, repeatable and paired; a real run needs --go; Codex with no route never starts"

echo "TEST 3: a good stand-in passes every task in every cell, and each cell really has its channel"
stub --seeds 1 --out "$T/good"
[ "$rc" = 0 ] || { tail -5 "$T/log"; fail "good stand-in: rc $rc"; }
grades "$T/good"
[ "$(field "$T/good" 'r["id"]' | wc -l | tr -d ' ')" = 35 ] || fail "wanted 35 runs"
[ -z "$(field "$T/good" '"" if g["pass"] else r["task"]+" "+r["condition"]+" "+r["pairing"]+" "+str(g["features"])' | grep .)" ] || fail "a reference run failed its hidden tests"
"$PY" -B - "$T/good" <<'PY' || fail "channel use"
import json, os, sys
out = sys.argv[1]
for line in open(os.path.join(out, "manifest.jsonl")):
    r = json.loads(line)
    cost = json.load(open(os.path.join(out, r["id"], "cost.json")))
    used = sum(c["channel_calls"] for c in cost.values())
    assert (used == 0) == (r["condition"] == "none"), r
    run = json.load(open(os.path.join(out, r["id"], "run.json")))
    assert "condition" not in json.dumps(run), "run.json knows the condition"
    harnesses = set(run["harnesses"].values())
    assert harnesses == ({"claude"} if r["pairing"] == "cc" else {"claude", "codex"}), (r, harnesses)
    final = os.path.join(out, r["id"], "final")
    names = {n for _d, ds, fs in os.walk(final) for n in ds + fs}
    assert not names & {".agentbus", "COORDINATION.md", ".claude", "AGENTS.md", ".git"}, names
    assert not any(n.startswith("hidden_") for n in names), names
PY
ok "35 cells pass; a channel is used only where one exists; the graders' files never name the condition"

echo "TEST 4: recovery's kill fires on files, and the runner lets the session die"
[ -z "$(field "$T/good" '"" if r["task"]!="recovery" or (g["kill_fired"] and len(g["killed_with"])>=3) else r["id"]' | grep .)" ] || fail "a recovery kill did not fire on 3 files"
ok "the kill fires at 3 files in every cell"

echo "TEST 5: a lost edit shows up, whichever agent lost it"
env VALUE_STUB_MODE=clobber VALUE_STUB_CLOBBER_AFTER=2 VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks overlap-shared --conditions none --pairings cc --seeds 2 --snap-every 0.2 --time-cap 60 --out "$T/lost" >"$T/log" 2>&1 || { tail -5 "$T/log"; fail "clobber run"; }
grades "$T/lost"
[ "$(field "$T/lost" 'g["pass"]')" = False ] || fail "the clobbered run passed"
[ "$(field "$T/lost" '",".join(g["lost_features"])')" = "discount,tax" ] || fail "lost features: $(field "$T/lost" 'g["lost_features"]')"
[ "$(field "$T/lost" '",".join(g["paths_edited_by_both"])' | grep -c pipeline.py)" = 1 ] || fail "the shared edit was not seen"
ok "bob's overwrite reads as lost discount and tax features, a failed run, and a path both edited"

echo "TEST 5b: separate worktrees meet at the merge; a conflict is recorded and fails the run; the bus stays one bus"
env VALUE_STUB_MODE=conflict VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks overlap --conditions agentbus --pairings cc --seeds 2 --time-cap 60 --out "$T/conflict" >"$T/log" 2>&1 || { tail -5 "$T/log"; fail "conflict run"; }
grades "$T/conflict"
[ "$(field "$T/conflict" '",".join(g["merge_conflicts"])')" = VERSION ] || fail "merge conflicts: $(field "$T/conflict" 'g["merge_conflicts"]')"
[ "$(field "$T/conflict" 'g["pass"]')" = False ] || fail "a conflicted merge passed"
[ "$(field "$T/good" '"" if r["task"]!="overlap" or g["merge_conflicts"]==[] else r["id"]' | grep -c .)" = 0 ] || fail "identical lanes must merge clean"
ok "a real conflict reads as one conflicted file and a failed run; identical lanes merge clean"

echo "TEST 6: an agent that does nothing fails"
env VALUE_STUB_MODE=lazy VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions ledger --pairings cc --seeds 1 --out "$T/lazy" >"$T/log" 2>&1 || fail "lazy run"
grades "$T/lazy"
[ "$(field "$T/lazy" 'g["pass"]')" = False ] || fail "a run with no work passed"
[ "$(field "$T/lazy" 'r["infra"]')" = "{}" ] || fail "an idle agent was excused as infra"
ok "no work is a failed run, not an excused one"

echo "TEST 7: every planted leak stops the batch"
leak() { # MODE CONDITION WANTED
  rc=0; env VALUE_STUB_MODE="$1" VALUE_STUB_REAL_SETTINGS="$HOME/.claude/settings.json" VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions "$2" --pairings cc --seeds 1 3 --out "$T/leak$RANDOM" >"$T/log" 2>&1 || rc=$?
  [ "$rc" = 5 ] || { cat "$T/log"; fail "$1: the batch did not stop (rc $rc)"; }
  grep -q "$3" "$T/log" || { cat "$T/log"; fail "$1: stopped for another reason (wanted: $3)"; }
  grep -q 'run 1 of 2' "$T/log" && fail "$1: the batch went on after a failed check"
  return 0
}
leak hook-leak none "hook events in a none run"
leak plugin-leak ledger "plugins loaded"
leak settings-write none "settings.json changed"
leak bus-in-none none "a bus exists in a none run"
ok "a hook, a plugin, a change to the real settings and a stray bus each stop the batch"

echo "TEST 8: the agent gets the allowlist and no more; agentbus is on PATH only where it belongs"
export AUTH0_CLIENT_SECRET=planted CLAUDE_CODE_SESSION_ID=planted GITHUB_TOKEN=planted AGENTBUS_DB=/planted/bus.db
env VALUE_STUB_MODE=env-dump VALUE_STUB_ENV_OUT="$T/env" VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cc --seeds 1 --out "$T/env-out" >"$T/log" 2>&1 || { cat "$T/log"; fail "env run"; }
unset AUTH0_CLIENT_SECRET CLAUDE_CODE_SESSION_ID GITHUB_TOKEN AGENTBUS_DB
for planted in AUTH0_CLIENT_SECRET CLAUDE_CODE_SESSION_ID GITHUB_TOKEN AGENTBUS_DB; do grep -qx "$planted" "$T/env" && fail "$planted reached the agent"; done
grep -qx HOME "$T/env" && grep -qx PATH "$T/env" || fail "the agent has no HOME or PATH"
"$PY" -B - "$SCRIPTS" <<'PY' || fail "path or tools"
import sys, types
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import run
assert "SendMessage" not in run.allowed_tools("none") and "ListAgents" not in run.allowed_tools("agentbus"), "a hidden channel is on"
assert "SendMessage" in run.allowed_tools("builtin")
settings = run.claude_settings("/tmp/x", "none")
assert settings["sandbox"]["enabled"] and settings["sandbox"]["allowUnsandboxedCommands"] is False and settings["autoMemoryEnabled"] is False, settings
assert "crossSessionInbound" not in settings and run.claude_settings("/tmp/x", "builtin")["crossSessionInbound"] == "accept"
assert run.harness_of("cc", "bob", 1) == "claude"
assert {run.harness_of("cx", "alice", 1), run.harness_of("cx", "alice", 2)} == {"claude", "codex"}, "roles do not alternate"
assert run.harness_of("cx", "alice", 1) != run.harness_of("cx", "bob", 1)
PY
ok "planted secrets stay out; messaging tools are off outside builtin; the sandbox cannot be left; roles alternate"

echo "TEST 9: caps end a run, and a capped run still counts"
rc=0; env VALUE_STUB_MODE=hang VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cc --seeds 1 --time-cap 3 --out "$T/hang" >"$T/log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$T/log"; fail "hang: rc $rc"; }
grades "$T/hang"
[ "$(field "$T/hang" '",".join(g["stops"])')" = time_cap ] && [ "$(field "$T/hang" 'g["pass"]')" = False ] && [ "$(field "$T/hang" 'r["infra"]')" = "{}" ] || fail "a time cap: $(field "$T/hang" 'g')"
rc=0; env VALUE_STUB_MODE=spam VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cc --seeds 1 --tool-cap 5 --time-cap 60 --out "$T/spam" >"$T/log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$T/log"; fail "spam: rc $rc"; }
grades "$T/spam"
[ "$(field "$T/spam" '",".join(g["stops"])')" = tool_cap ] || fail "a tool cap: $(field "$T/spam" 'g')"
ok "time and tool caps end the agent; the run is scored and stays in"

echo "TEST 10: a sign-in failure is infrastructure, listed and left out of the numbers"
env VALUE_STUB_MODE=auth-fail VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cc --seeds 1 --out "$T/auth" >"$T/log" 2>&1 || true
[ "$(field "$T/auth" 'sorted(r["infra"])')" != "[]" ] || fail "a sign-in failure was not marked"
grades "$T/auth"
out=$("$PY" -B "$SCRIPTS/analyze.py" "$T/auth" --cost)
grep -q 'dropped under the protocol.s rule: 1' <<<"$out" && grep -q '^runs 0' <<<"$out" || fail "analysis: $out"
ok "marked, listed and dropped"

echo "TEST 11: no contrast prints until every cell has its n runs"
rc=0; out=$("$PY" -B "$SCRIPTS/analyze.py" "$T/good" --n 2) || rc=$?
[ "$rc" = 3 ] && grep -q 'Pilot numbers are not results' <<<"$out" || fail "a short batch: rc $rc: $out"
grep -qE 'minus|P1|P2' <<<"$out" && fail "a contrast printed from a short batch: $out"
out=$("$PY" -B "$SCRIPTS/analyze.py" "$T/good" --cost)
grep -qE 'agentbus|ledger|builtin' <<<"$out" && fail "the cost report names a condition: $out"
out=$("$PY" -B "$SCRIPTS/analyze.py" "$T/good" --n 1)
grep -q '^P1 agentbus minus ledger, cx' <<<"$out" && grep -q '^P2 ' <<<"$out" && grep -q '^P3 control tokens' <<<"$out" || fail "a full batch prints the primaries: $out"
ok "short batches print nothing to compare; the cost report splits by no condition; a full batch prints P1, P2 and P3"

echo "TEST 12: a run refuses to live under the checkout or the forbidden root"
mkdir -p "$T/forbidden"
rc=0; env VALUE_FORBIDDEN_ROOT="$T/forbidden" VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cc --out "$T/forbidden/out" >"$T/log" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q "a run lives in mktemp" "$T/log" || { cat "$T/log"; fail "output under the forbidden root: rc $rc"; }
rc=0; env TMPDIR="$T/forbidden" VALUE_FORBIDDEN_ROOT="$T/forbidden" VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cc --out "$T/fine" >"$T/log" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q "a run lives in mktemp" "$T/log" || { cat "$T/log"; fail "a run root under the forbidden root: rc $rc"; }
ok "both are refused"

echo "TEST 12b: Codex gets a private copy of its sign-in, and a leak or a refresh stops the batch"
printf '{"auth_mode":"chatgpt","tokens":{"access_token":"%s"}}' "tok_$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5)" > "$T/auth.json"
real_auth=$(cksum < "$T/auth.json")
codex_stub() { rc=0; env VALUE_STUB_MODE="$1" VALUE_STUB_ENV_OUT="$T/authreport" VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cx --seeds 1 3 --codex-auth "$T/auth.json" --time-cap 60 --out "$T/cx$RANDOM" >"$T/log" 2>&1 || rc=$?; }
codex_stub auth-report
[ "$rc" = 0 ] || { cat "$T/log"; fail "a clean Codex run: rc $rc"; }
[ "$(cat "$T/authreport")" = "False 600" ] || fail "the sign-in copy: $(cat "$T/authreport")"
env VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cx --seeds 1 --codex-auth "$T/auth.json" --time-cap 60 --keep-tree --out "$T/kept" >"$T/log" 2>&1 || { cat "$T/log"; fail "a kept Codex run"; }
[ -z "$(find "$TMPDIR" -path '*/codex-home/auth.json' | head -1)" ] || fail "a kept tree holds a copy of the sign-in"
find "$TMPDIR" -maxdepth 1 -name 'value-run-*' -exec rm -rf {} +
codex_stub leak-token
[ "$rc" = 5 ] && grep -q 'a Codex credential is in' "$T/log" || { cat "$T/log"; fail "a token in a trace did not stop the batch (rc $rc)"; }
grep -q 'tok_x' "$T/log" && fail "the check printed the token"
codex_stub auth-refresh
[ "$rc" = 5 ] && grep -q 'refreshed its copy' "$T/log" || { cat "$T/log"; fail "a refreshed token did not stop the batch (rc $rc)"; }
[ "$(cksum < "$T/auth.json")" = "$real_auth" ] || fail "a run changed the real sign-in"
ok "the copy is private and not a link; a token in a trace or a refresh stops the batch, and the real file never changes"

codex_stub codex-hooks
[ "$rc" = 5 ] && grep -q 'hooks.json in a none run' "$T/log" || { cat "$T/log"; fail "a planted Codex hook did not stop the batch (rc $rc)"; }
codex_stub codex-skill
[ "$rc" = 5 ] && grep -q 'a Codex skill beyond its own' "$T/log" || { cat "$T/log"; fail "a planted Codex skill did not stop the batch (rc $rc)"; }
codex_stub codex-state
[ "$rc" = 0 ] || { cat "$T/log"; fail "Codex's own state stopped the batch (rc $rc)"; }
ok "a planted hook or skill in CODEX_HOME stops the batch; Codex's own state does not"

env VALUE_STUB_ROLLOUT=1 VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks recovery --conditions none --pairings cx --seeds 1 --time-cap 60 --snap-every 0.2 --out "$T/killed" >"$T/log" 2>&1 || { cat "$T/log"; fail "a killed Codex run"; }
"$PY" -B - "$T/killed" <<'CHECK' || fail "a killed Codex session's tokens were lost"
import glob, json, sys
cost = json.load(open(glob.glob(sys.argv[1] + "/r*/cost.json")[0]))
assert cost["alice"]["usage"]["cache_read"] == 900 and cost["alice"]["complete"] is False, cost["alice"]
CHECK
ok "a killed Codex session keeps its tokens, from its rollout"

echo "TEST 12c: the batch halts when Codex use passes the budget"
rc=0; env VALUE_STUB_QUOTA_FILE="$T/quota" VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cx --seeds 1 2 3 4 --time-cap 60 --out "$T/budget" >"$T/log" 2>&1 || rc=$?
[ "$rc" = 6 ] && grep -q 'Codex budget stop' "$T/log" || { cat "$T/log"; fail "no budget stop (rc $rc)"; }
[ "$(wc -l < "$T/budget/manifest.jsonl" | tr -d ' ')" = 3 ] || fail "the batch went on past the budget: $(wc -l < "$T/budget/manifest.jsonl") runs"
ok "30 points a run halts on the run that passes 40"

echo "TEST 14: the ledger gets hooks on the same events, in both harnesses; none and builtin get none"
: > "$T/hooks"
for c in ledger none builtin; do env VALUE_STUB_MODE=settings-report VALUE_STUB_ENV_OUT="$T/hooks" VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions $c --pairings cc --seeds 1 --out "$T/h-$c" >"$T/log" 2>&1 || { cat "$T/log"; fail "$c settings run"; }; done
env VALUE_STUB_MODE=settings-report VALUE_STUB_ENV_OUT="$T/hooks" VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks overlap --conditions ledger --pairings cx --seeds 1 --codex-auth "$T/auth.json" --out "$T/h-cx" >"$T/log" 2>&1 || { cat "$T/log"; fail "cx ledger settings run"; }
"$PY" -B - "$T/hooks" <<'CHECK' || fail "ledger hooks"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
claude = [r for r in rows if r["harness"] == "claude"]
led = [r for r in claude if r["ledger_hook"]]
assert len(led) == 3 and all(r["events"] == ["PreToolUse", "SessionStart"] for r in led), led
assert all(r["name"] == r["role"] for r in led), "LEDGER_NAME"
assert sum(1 for r in claude if not r["events"]) == 4, "none and builtin must have no hooks: %s" % claude
codex = [r for r in rows if r["harness"] == "codex"]
assert codex and "hooks.json" in codex[0]["codex_home"] and codex[0]["argv_trust"] and codex[0]["name"] == codex[0]["role"], codex
CHECK
ok "ledger hooks install for Claude and Codex, named; none and builtin stay hookless"

echo "TEST 15: a hook that ran and failed is an outcome; hooks that never loaded are infrastructure"
env VALUE_STUB_MODE=hook-fail VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions ledger --pairings cc --seeds 1 --out "$T/hf" >"$T/log" 2>&1 || { cat "$T/log"; fail "hook-fail run"; }
[ "$(field "$T/hf" 'r["infra"]')" = "{}" ] && [ "$(field "$T/hf" 'r["isolation"]')" = "[]" ] || fail "a failed hook was excused: $(field "$T/hf" 'r')"
"$PY" -B -c "import glob,json,sys; c=json.load(open(glob.glob(sys.argv[1]+'/r*/cost.json')[0])); assert c['alice']['hooks']['failed']==1, c" "$T/hf" || fail "a failed hook was not recorded"
rc=0; env VALUE_STUB_MODE=no-hooks VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions agentbus --pairings cc --seeds 1 3 --out "$T/nh" >"$T/log" 2>&1 || rc=$?
[ "$rc" = 0 ] && grep -q 'hooks did not load' "$T/nh/manifest.jsonl" && [ "$(wc -l < "$T/nh/manifest.jsonl" | tr -d ' ')" = 2 ] || { cat "$T/log"; fail "hooks that never loaded (rc $rc)"; }
ok "a failed hook is recorded and the run counts; unloaded hooks are infrastructure and the batch goes on"

echo "TEST 16: ledger edits are not project edits, and a broken ledger link is recorded"
env VALUE_STUB_MODE=break-link VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks overlap --conditions ledger --pairings cc --seeds 1 --out "$T/bl" >"$T/log" 2>&1 || { cat "$T/log"; fail "break-link run"; }
grades "$T/bl"
"$PY" -B - "$T/bl" <<'CHECK' || fail "ledger link"
import glob, json, sys
d = glob.glob(sys.argv[1] + "/r*/")[0]
cost = json.load(open(d + "cost.json"))
assert cost["bob"]["ledger_link_broken"] is True and cost["alice"]["ledger_link_broken"] is False, cost
assert not [e for e in json.load(open(d + "edits.json")) if "COORDINATION" in e["path"]], "a ledger edit reached the graders"
CHECK
ok "bob's broken link is a recorded failure mode; ledger writes never count as edits"

echo "TEST 17: the analysis prints the registered corrections and every measure"
out=$("$PY" -B "$SCRIPTS/analyze.py" "$T/good" --n 1)
for want in "Holm" "without overlap" "channel bytes back" "channel writes" "S8" "fresh tokens, secondary" "hook failures" "Protocol steps"; do
  grep -q "$want" <<<"$out" || fail "the analysis lacks: $want"
done
ok "Holm, the sensitivity rows, channel cost, S8 and protocol steps all print"

echo "TEST 18: a usage limit stops the batch at once, even mid-run, and the run is infrastructure"
for after in 0 3; do
  rc=0; env VALUE_STUB_MODE=usage-limit VALUE_STUB_LIMIT_AFTER=$after VALUE_STUB_LIMIT_ROLE=bob VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions ledger --pairings cc --seeds 1 2 3 --time-cap 60 --out "$T/ul$after" >"$T/log" 2>&1 || rc=$?
  [ "$rc" = 7 ] && grep -q 'usage limit: batch stopped' "$T/log" || { cat "$T/log"; fail "after $after tool calls: no usage stop (rc $rc)"; }
  [ "$(wc -l < "$T/ul$after/manifest.jsonl" | tr -d ' ')" = 1 ] || fail "after $after tool calls: the batch burned more runs"
  [ "$(field "$T/ul$after" 'r["infra"].get("bob")')" = "usage limit" ] || fail "after $after tool calls: not infrastructure: $(field "$T/ul$after" 'r["infra"]')"
done
ok "a limit before or after tool calls stops the batch on that run and marks it infrastructure"

echo "TEST 18b: an expired sign-in stops the batch at once, in the stream or on stderr, and the run is infrastructure"
for mode in stream stderr; do
  stderr_only=""; [ "$mode" = stderr ] && stderr_only=1
  rc=0; env VALUE_STUB_AUTH_STDERR="$stderr_only" VALUE_STUB_MODE=auth-expired VALUE_STUB_LIMIT_ROLE=bob VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions ledger --pairings cc --seeds 1 2 3 --time-cap 60 --out "$T/ae$mode" >"$T/log" 2>&1 || rc=$?
  [ "$rc" = 9 ] && grep -q 'authentication failed: batch stopped' "$T/log" || { cat "$T/log"; fail "$mode: no sign-in stop (rc $rc)"; }
  [ "$(wc -l < "$T/ae$mode/manifest.jsonl" | tr -d ' ')" = 1 ] || fail "$mode: the batch burned more runs"
  [ "$(field "$T/ae$mode" 'r["infra"].get("bob")')" = "authentication failed" ] || fail "$mode: not infrastructure: $(field "$T/ae$mode" 'r["infra"]')"
done
ok "an expired sign-in, in the stream or on stderr, stops the batch on that run and marks it infrastructure"

echo "TEST 19: --rerun-infra replaces exactly the infrastructure runs, once, and leaves the rest alone"
stub --tasks control overlap --conditions agentbus ledger --pairings cc --seeds 1 --out "$T/re"
[ "$rc" = 0 ] || fail "rerun base"
env VALUE_STUB_MODE=no-hooks VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control overlap --conditions agentbus ledger --pairings cc --seeds 2 --time-cap 60 --out "$T/re" >"$T/log" 2>&1 || true
cp "$T/re/manifest.jsonl" "$T/before.jsonl"
out=$("${RUN[@]}" --out "$T/re" --rerun-infra --dry-run)
[ "$(sed -n 1p <<<"$out")" = "value eval: 4 runs (replacing infrastructure failures)" ] || fail "rerun plan: $out"
a=$("${RUN[@]}" --out "$T/re" --rerun-infra --dry-run --shard 1/2 | tail -n +2); b=$("${RUN[@]}" --out "$T/re" --rerun-infra --dry-run --shard 2/2 | tail -n +2)
[ "$(printf '%s\n%s\n' "$a" "$b" | sort)" = "$(tail -n +2 <<<"$out" | sort)" ] && [ -z "$(comm -12 <(sort <<<"$a") <(sort <<<"$b"))" ] || fail "shards overlap or miss runs"
stub --out "$T/re" --rerun-infra
[ "$rc" = 0 ] || { cat "$T/log"; fail "rerun: rc $rc"; }
[ "$(head -c "$(wc -c < "$T/before.jsonl")" "$T/re/manifest.jsonl" | cksum)" = "$(cksum < "$T/before.jsonl")" ] || fail "the rerun changed earlier rows"
"$PY" -B - "$T/re" <<'CHECK' || fail "replacements"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1] + "/manifest.jsonl")]
bad = {r["id"]: r for r in rows if r["infra"]}
new = [r for r in rows if r.get("replaces")]
assert len(bad) == 4 and len(new) == 4 and {r["replaces"] for r in new} == set(bad), (len(bad), len(new))
for r in new:
    old = bad[r["replaces"]]
    assert (r["task"], r["seed"], r["condition"], r["pairing"]) == (old["task"], old["seed"], old["condition"], old["pairing"]) and not r["infra"], r
CHECK
grades "$T/re"
out=$("$PY" -B "$SCRIPTS/analyze.py" "$T/re" --n 2)
grep -q '^P2 agentbus minus ledger\|^P2 ' <<<"$out" || grep -q 'Primary' <<<"$out" || fail "a replaced batch did not reach the analysis: $out"
grep -q "4 runs: hooks did not load" <<<"$out" || fail "the dropped summary: $out"
[ "$("${RUN[@]}" --out "$T/re" --rerun-infra --dry-run | sed -n 1p)" = "value eval: 0 runs (replacing infrastructure failures)" ] || fail "a second rerun would replace again"
ok "4 failures replaced with the same task, seed, condition and pairing; earlier rows untouched; shards disjoint; a second rerun finds nothing"

echo "TEST 19b: --skip-done plans only the combinations the output has no row for, so no run is made twice"
out=$("${RUN[@]}" --tasks control overlap --conditions agentbus ledger --pairings cc --seeds 1 2 3 --out "$T/re" --skip-done --dry-run)
[ "$(sed -n 1p <<<"$out")" = "value eval: 4 runs" ] && [ "$(tail -n +2 <<<"$out" | grep -c 'seed 3 ')" = 4 ] || fail "skip-done plan: $out"
[ "$("${RUN[@]}" --tasks control overlap --conditions agentbus ledger --pairings cc --seeds 1 2 --out "$T/re" --skip-done --dry-run | sed -n 1p)" = "value eval: 0 runs" ] || fail "skip-done planned a done run"
[ "$("${RUN[@]}" --tasks control overlap --conditions agentbus ledger --pairings cc --seeds 1 2 3 --out "$T/none" --skip-done --dry-run | sed -n 1p)" = "value eval: 12 runs" ] || fail "skip-done with no manifest"
ok "skip-done drops every combination already in the manifest (infrastructure or not) and keeps the rest in plan order"

echo "TEST 20: the batch stops when a Claude plan's usage passes its stop, before the first run as well as during"
printf '#!/bin/sh\nf=%s/use; n=$(cat "$f" 2>/dev/null || echo %s); echo $((n+%s)) > "$f"; echo "$n"\n' "$T" 50 20 > "$T/usage.sh"; chmod +x "$T/usage.sh"
rc=0; env VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cc --seeds 1 2 3 4 --claude-usage-cmd "$T/usage.sh" --claude-usage-stop 85 --time-cap 60 --out "$T/cu" >"$T/log" 2>&1 || rc=$?
[ "$rc" = 8 ] && grep -q 'Claude usage stop' "$T/log" && [ "$(wc -l < "$T/cu/manifest.jsonl" | tr -d ' ')" = 2 ] || { cat "$T/log"; fail "no Claude usage stop mid-batch (rc $rc)"; }
echo 95 > "$T/use"
rc=0; env VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks control --conditions none --pairings cc --seeds 1 --claude-usage-cmd "$T/usage.sh" --claude-usage-stop 85 --out "$T/cu2" >"$T/log" 2>&1 || rc=$?
[ "$rc" = 8 ] && [ ! -e "$T/cu2/manifest.jsonl" ] || { cat "$T/log"; fail "a plan already past its stop started a run (rc $rc)"; }
ok "50, 70, then 90 halts before the third run; a plan already at 95 never starts"

echo "TEST 21: livehold (follow-up fix1): bob starts on alice's first edit; taking her live claim fails, waiting for it passes, on both channels"
for mode in good live-steal live-wait; do
  env VALUE_STUB_MODE=$mode VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks livehold --conditions agentbus ledger --pairings cc --seeds 1 --time-cap 60 --snap-every 0.2 --out "$T/lh-$mode" >"$T/log" 2>&1 || { cat "$T/log"; fail "livehold $mode run"; }
  grades "$T/lh-$mode"
  "$PY" -B "$SCRIPTS/channel_grade.py" "$T/lh-$mode" >/dev/null || fail "livehold $mode: channel grade"
done
"$PY" -B - "$T" <<'CHECK' || fail "livehold"
import glob, json, os, sys
for mode, want in (("good", True), ("live-steal", False), ("live-wait", True)):
    rows = [json.loads(l) for l in open(os.path.join(sys.argv[1], "lh-" + mode, "manifest.jsonl"))]
    assert {r["condition"] for r in rows} == {"agentbus", "ledger"}, rows
    for r in rows:
        d = os.path.join(sys.argv[1], "lh-" + mode, r["id"])
        g, c, run = (json.load(open(os.path.join(d, n))) for n in ("grade.json", "channel.json", "run.json"))
        assert g["pass"], (mode, r["condition"], "the hidden tests must pass in every mode", g["features"])
        first = min(e["ts"] for e in json.load(open(os.path.join(d, "edits.json"))) if e["agent"] == "alice" and e["path"] == "src/rates.py")
        assert run["late_start"]["why"] == "changed" and run["agents"]["bob"]["t_start"] >= first, ("bob started before alice's first edit", run, first)
        assert c["live"]["live_ok"] is want, ("a live takeover was graded wrong", mode, r["condition"], c["live"])
        if mode == "live-steal":
            assert c["live"]["takeovers_while_alive"] == 1 and c["live"]["edits_under_live_claim"] >= 1, ("a live takeover was not counted", r["condition"], c["live"])
        kept = os.listdir(os.path.join(d, "channel"))
        assert ("bus.db" in kept) if r["condition"] == "agentbus" else ({"COORDINATION.md", "ledger-watch.jsonl"} <= set(kept)), ("no channel kept", kept)
        names = {n for _d, ds, fs in os.walk(os.path.join(d, "final")) for n in ds + fs}
        assert not names & {".agentbus", "COORDINATION.md", "channel"}, names
CHECK
rc=0; out=$("$PY" -B "$SCRIPTS/analyze_fix1.py" "$T/lh-good" --n 1) || rc=$?
[ "$rc" = 3 ] && grep -q 'no contrasts: 6 cells' <<<"$out" || fail "the follow-up analysis must refuse a batch missing cells: $out"
ok "bob waits for alice's first edit; a live takeover fails on the bus and the ledger, waiting passes; the channel is kept beside final/, never in it"

echo "TEST 22: abandoned (follow-up): alice dies once her first item passes; bob's OPEN.md and his work are graded apart; finished hands over nothing"
for mode in good say-only; do
  env VALUE_STUB_MODE=$mode VALUE_STUB_DIR="$STUB" "${RUN[@]}" --tasks abandoned finished --conditions agentbus ledger none --pairings cc --seeds 1 --time-cap 120 --snap-every 0.5 --out "$T/ab-$mode" >"$T/log" 2>&1 || { cat "$T/log"; fail "abandoned $mode run"; }
  grades "$T/ab-$mode"
  "$PY" -B "$SCRIPTS/channel_grade.py" "$T/ab-$mode" >/dev/null || fail "abandoned $mode: channel grade"
done
"$PY" -B - "$T" <<'CHECK' || fail "abandoned"
import json, os, sys
for mode in ("good", "say-only"):
    out = os.path.join(sys.argv[1], "ab-" + mode)
    rows = [json.loads(l) for l in open(os.path.join(out, "manifest.jsonl"))]
    assert len(rows) == 6 and all(not r["infra"] for r in rows), rows
    for r in rows:
        d = os.path.join(out, r["id"])
        g, c, run = (json.load(open(os.path.join(d, n))) for n in ("grade.json", "channel.json", "run.json"))
        if r["task"] == "abandoned":
            assert run["kill"]["fired"] and run["kill"]["done"] == ["first"], ("the kill must land after the first item only", run["kill"])
            assert run["handover"]["open"] == ["second", "validation"], run["handover"]
            assert run["agents"]["alice"]["stop"] == "task_kill", run["agents"]
        else:
            assert not run["kill"]["fired"] and run["handover"]["open"] == [], (run["kill"], run["handover"])
        assert g["discovered"], ("the stand-in names exactly what was open", mode, r["task"], g)
        want = mode == "good" or r["task"] == "finished"
        assert g["recovered"] is want and g["pass"] is want, ("saying what is open is not recovery", mode, r["task"], g["features"])
        if r["condition"] != "none":
            a = c["roles"]["alice"]
            assert a["named_all"] and a["todos_all"], ("alice's three todos were not seen", r["condition"], a)
            assert a["closed_all"] is (r["task"] == "finished"), ("alice's closes", r["task"], r["condition"], a)
CHECK
rc=0; out=$("${RUN[@]}" --out "$T/pin" --go --claude-launcher /bin/false --tasks abandoned --conditions agentbus --pairings cc 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "is not the pinned $("$PY" -B -c "import sys; sys.path.insert(0, '$SCRIPTS'); import run; print(run.TODO_TOOL[0])")" <<<"$out" || fail "abandoned ran with the v0.3.0 tool: rc $rc: $out"
rc=0; out=$("${RUN[@]}" --out "$T/pin" --go --claude-launcher /bin/false --tasks abandoned recovery --conditions agentbus --pairings cc 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "mixes tasks that test different builds" <<<"$out" || fail "a batch with two pins started: rc $rc: $out"
rc=0; out=$(env AGENTBUS_CMD=/bin/true "${RUN[@]}" --out "$T/pin" --go --claude-launcher /bin/false --tasks control --conditions none --pairings cc 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "AGENTBUS_CMD is set" <<<"$out" || fail "a real run took AGENTBUS_CMD: rc $rc: $out"
[ ! -e "$T/pin" ] || fail "a refused batch made its output folder"
ok "the kill lands after the first item; OPEN.md alone discovers but does not recover; finished hands over nothing; the todo pin, one pin per batch and no AGENTBUS_CMD are enforced"

echo "TEST 13: a run leaves nothing behind"
[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'value-run-*' | grep -v forbidden || true)" ] || fail "run folders left: $(ls "$TMPDIR")"
ok "the mktemp folders are gone"
echo "All value eval tests passed"
