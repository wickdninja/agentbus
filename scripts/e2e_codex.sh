#!/bin/bash
# bash scripts/e2e_codex.sh   a real `codex exec` run with this checkout's hooks installed by `setup codex`.
# Needs the codex CLI, signed in (auth.json is COPIED from $CODEX_AUTH_FROM, default ~/.codex/auth.json, into a scratch
# CODEX_HOME that is deleted afterwards; the real ~/.codex is never written), on the supported version recorded in
# docs/design/codex-hook-contract.md. It makes one short model call and is not part of tests/run_all.sh.
# Ends with `codex e2e passed` or a failure line. E2E_TRANSCRIPT=FILE keeps what codex printed (for the issue).
# It shows, on a real run: setup codex's hooks.json is loaded and its commands run through Codex's login shell; the
# SessionStart text reaches the model (it reports the name it was given); that name is on the bus roster after the
# first prompt; a PreToolUse claim note reaches the model for a file another name holds; the hook's wall time through
# the login shell stays under 250 ms at p95 and the login shell itself prints nothing (it would corrupt the hook's JSON).
# The trust step itself (/hooks in the TUI) is interactive and is not what this script checks: it runs codex with
# --dangerously-bypass-hook-trust, which makes Codex treat the hooks as trusted for this one scratch run.
# Run by hand on codex-cli 0.166.0 for docs/evals/live-acceptance-0.2.0.md. The prompt forbids shell commands: left free, the
# model follows the AGENTS.md block, claims the file itself (refused), reads the refusal, answers CLAIMNOTE=yes without any
# hook note, and runs `leave`, which removes it from the roster the script then checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v codex >/dev/null 2>&1 || { echo "FAIL: codex is not on PATH"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is not on PATH"; exit 2; }
AUTH="${CODEX_AUTH_FROM:-$HOME/.codex/auth.json}"
[ -f "$AUTH" ] || { echo "FAIL: no auth file at $AUTH (set CODEX_AUTH_FROM)"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
case "$(cd "$T" && pwd -P)" in "$HOME/src"*|/Users/*/src*) echo "FAIL: the scratch folder $T is under ~/src; set TMPDIR elsewhere"; exit 2 ;; esac
unset AGENTBUS_DB AGENTBUS_AGENT AGENTBUS_HOOKS
export CODEX_HOME="$T/codex-home"; mkdir -p "$CODEX_HOME"
( umask 077; cp "$AUTH" "$CODEX_HOME/auth.json" )
P="$T/proj"; mkdir -p "$P"
git -C "$P" init -q
python3 "$ROOT/bin/agentbus" init "$P" >/dev/null
BUS="$P/.agentbus/bin/agentbus"
python3 "$ROOT/bin/agentbus" setup codex >/dev/null || { echo "FAIL: setup codex failed"; exit 1; }
[ -f "$CODEX_HOME/hooks.json" ] && [ -f "$CODEX_HOME/AGENTS.md" ] || { echo "FAIL: setup codex did not write hooks.json and AGENTS.md under the scratch CODEX_HOME"; exit 1; }
VERSION=$(codex --version 2>&1 | head -n 1)
echo "$VERSION, hooks from $ROOT, scratch project $P"
# another name holds hello.txt, so a PreToolUse note is due
(cd "$P" && "$BUS" --as peer join >/dev/null && "$BUS" --as peer claim hello.txt --purpose e2e >/dev/null)
LAST="$T/last.txt"; LOG="$T/codex.log"
(
  cd "$P"
  codex exec --dangerously-bypass-hook-trust -s workspace-write -o "$LAST" \
    "Do not run any shell command. Use the apply_patch tool to create hello.txt containing the word hi. Then reply with exactly one line: NAME=<the agentbus name your context told you to use> CLAIMNOTE=<yes if a hook told you a claim under a different name covers the file, else no>" \
    </dev/null >"$LOG" 2>&1
) || { echo "FAIL: codex exec failed: $(tail -n 5 "$LOG")"; exit 1; }
[ -z "${E2E_TRANSCRIPT:-}" ] || cp "$LOG" "$E2E_TRANSCRIPT"
python3 -I - "$LAST" "$P" "$BUS" <<'PY' || exit 1
import json, re, subprocess, sys
last, proj, bus = sys.argv[1:4]
said = open(last).read()
m = re.search(r"NAME=(\S+)\s+CLAIMNOTE=(\w+)", said)
assert m, ("no NAME= line in the final message", said)
name, note = m.group(1).strip("`'\".,"), m.group(2).lower()
assert re.fullmatch(r"codex-[0-9a-f]{8}", name), ("the model was not told a codex-<8 hex> name", name)
who = json.loads(subprocess.run([bus, "--json", "who"], cwd=proj, capture_output=True, text=True, check=True).stdout)
names = [r["name"] for r in who["items"]]
assert name in names, ("the name the model reported is not on the roster", name, names)
assert note == "yes", ("the PreToolUse claim note did not reach the model", said)
print("roster:", " ".join(names), "| model reported", name)
PY
# the cost of one hook through Codex's own path: the recorded command in a login shell, 10 runs
python3 -I - "$CODEX_HOME/hooks.json" "$P" <<'PY' || exit 1
import json, os, subprocess, sys, time
hooks = json.load(open(sys.argv[1]))["hooks"]
cmd = hooks["UserPromptSubmit"][0]["hooks"][0]["command"]
payload = json.dumps({"session_id": "e2e-latency", "cwd": sys.argv[2], "hook_event_name": "UserPromptSubmit", "prompt": "x"})
times = []
for _ in range(10):
    t0 = time.time()
    p = subprocess.run([os.environ.get("SHELL", "/bin/sh"), "-lc", cmd], input=payload, capture_output=True, text=True, cwd=sys.argv[2])
    times.append(time.time() - t0)
    assert p.returncode == 0, p
    # Codex reads the hook's stdout as JSON: a login profile that prints would put text in front of it. This prompt has
    # nothing unread, so the hook prints nothing and the whole stdout is what the profile wrote.
    assert p.stdout == "", ("the login shell printed text in front of the hook's output", len(p.stdout))
times.sort()
print("hook through the login shell: p95 %.0f ms" % (times[9] * 1000))
assert times[9] <= 0.25, "hook p95 over 250 ms through the login shell"
PY
echo "codex e2e passed ($VERSION)"
