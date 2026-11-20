#!/bin/bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/usage/collect.py"

# One foreground Python owns the WAL writer while it launches the collector.
# No real home inputs, bus CLI calls, background jobs, or external dependencies.
"$PY" - "$S" "$T" <<'PYTEST' || fail "collector fixtures, metrics or privacy"
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import sqlite3
import subprocess
import sys
from urllib.parse import quote

script, temp = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("usage_collect", script)
collect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collect)
leaks = ["ClientZephyrConfidential", "sk-syntheticTokenSecret987654321", "private.person@example.test", "/secret/customer/project"]
private = " ".join(leaks)
root = temp / leaks[0]
claude, codex, retired = root / "claude", root / "codex", root / "retired"
for folder in (claude, codex, retired):
    folder.mkdir(parents=True)
personal_cwd = str(root / "personal")
work_cwd = str(root / "work" / leaks[0])
ts = "2026-01-01T00:00:00Z"
end = "2026-01-01T01:00:00Z"
schema = """
CREATE TABLE messages(id INTEGER PRIMARY KEY, ts TEXT, sender TEXT, recipient TEXT, kind TEXT, topic TEXT, body TEXT, reply_to INTEGER);
CREATE TABLE agents(name TEXT PRIMARY KEY, cwd TEXT, joined_at TEXT, last_seen TEXT);
CREATE TABLE claims(resource TEXT, agent TEXT, purpose TEXT, claimed_at TEXT, expires_at TEXT);
CREATE TABLE log(id INTEGER PRIMARY KEY, ts TEXT, agent TEXT, action TEXT, detail TEXT);
CREATE TABLE cursors(agent TEXT, last_read_id INTEGER);
"""

def db_at(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(path))
    db.executescript(schema)
    return db

bus_path = root / "personal" / ".agentbus" / "bus.db"
db = db_at(bus_path)
msgs = [
    (1, ts, "a", "b", "question", leaks[0], private, None),
    (2, "2026-01-01T00:02:00Z", "b", "a", "answer", leaks[1], private, 1),
    (3, ts, "a", "brain", "handoff", leaks[2], private, None),
    (4, "2026-01-01T00:03:00Z", "brain", "a", "done", leaks[3], private, 3),
    (5, ts, "a", "*", "decision", "ruling", private, None),
    (6, ts, "a", "b", "question", leaks[0], private, None),
    # A reply that is another question is not an answer.
    (7, ts, "b", "a", "question", leaks[1], private, 6),
    # A linked answer from the wrong sender is not an answer from b.
    (8, ts, "stranger", "a", "answer", leaks[2], private, 6),
]
db.executemany("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?)", msgs)
for name, cwd in (("a", personal_cwd), ("b", personal_cwd + "-other"), ("brain", private)):
    db.execute("INSERT INTO agents VALUES(?,?,?,?)", (name, cwd, ts, end))
db.execute("INSERT INTO agents VALUES(?,?,?,?)", (private, private, ts, end))
db.execute("INSERT INTO claims VALUES(?,?,?,?,?)", (private, "a", private, ts, "2025-12-31T00:00:00Z"))
db.execute("INSERT INTO claims VALUES(?,?,?,?,?)", (leaks[3], private, private, ts, "2027-01-01T00:00:00Z"))
db.execute("INSERT INTO cursors VALUES('brain',4)")
logs = [
    (1, ts, "a", "join", json.dumps({"cwd": personal_cwd, "role": private})),
    (2, ts, "b", "join", json.dumps({"cwd": personal_cwd + "-other", "role": private})),
    (3, ts, "a", "claim", private),
    (4, ts, "a", "claim_refused", json.dumps({"conflicts": [{"resource": private, "holder": "b"}]})),
]
db.executemany("INSERT INTO log VALUES(?,?,?,?,?)", logs)
db.commit()
prefix = db_at(retired / leaks[1] / "bus.db")
prefix.executemany("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?)", msgs[:2])
prefix.commit()
prefix.close()
duplicate_path = root / "copy" / "bus.db"
duplicate_path.parent.mkdir()
duplicate = sqlite3.connect(str(duplicate_path))
db.backup(duplicate)
duplicate.close()

# A checkpointed main file followed by a committed WAL-only message.
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA wal_autocheckpoint=0")
db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
db.execute("INSERT INTO messages VALUES(9,?,?,?,?,?,?,NULL)", (end, "a", "*", "note", leaks[0], private))
db.commit()
wal = Path(str(bus_path) + "-wal")
assert wal.stat().st_size > 0
immutable = sqlite3.connect("file:" + quote(str(bus_path)) + "?immutable=1", uri=True)
assert immutable.execute("SELECT count(*) FROM messages").fetchone()[0] == 8
immutable.close()

work_db = db_at(root / "work" / ".agentbus" / "bus.db")
work_db.execute("INSERT INTO messages VALUES(1,?,?,?,?,?,?,NULL)", (ts, private, private, "note", private, private))
work_db.commit()
work_db.close()
# Empty buses have no evidence of shared lineage and must both survive.
for name in ("empty-one", "empty-two"):
    empty = db_at(root / name / "bus.db")
    empty.close()
# No messages table: a corrupt/unrelated database is counted as an error.
broken = root / "broken" / "bus.db"
broken.parent.mkdir()
broken.write_bytes(b"not sqlite " + private.encode())

rows = []
counter = 0

def claude_row(typ, **fields):
    global counter
    counter += 1
    row = dict(type=typ, timestamp=ts, sessionId="claude-main", cwd=personal_cwd, uuid="uuid-%d" % counter)
    row.update(fields)
    rows.append(row)

def shell(command, output, tid=None):
    tid = tid or "tool-%d" % counter
    claude_row("assistant", message={"content": [{"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": command}}]})
    claude_row("user", message={"content": [{"type": "tool_result", "tool_use_id": tid, "content": output}]})

def inject(event, text, **extra):
    attachment = dict(type="hook_additional_context", hookEvent=event, content=[text])
    attachment.update(extra)
    claude_row("attachment", attachment=attachment)

inject("SessionStart", "agentbus: you are on " + private + " as a.", hookName="SessionStart:compact")
shell("agentbus --as a claim target.py --purpose " + shlex.quote(private), "claimed target.py")
claude_row("assistant", message={"content": [{"type": "tool_use", "id": "edit-one", "name": "Edit", "input": {"file_path": personal_cwd + "/target.py", "old_string": private}}]})
inject("PreToolUse", "agentbus: held under a different name " + private, toolUseID="edit-one")
note = "agentbus: 2 unread messages " + private
inject("UserPromptSubmit", note)
shell("agentbus --as a inbox", private)
inject("UserPromptSubmit", note)
shell("agentbus --as a inbox | tail -5", "agentbus: note: " + private)
shell("agentbus --as b claim " + shlex.quote(leaks[3]), "agentbus: " + leaks[3] + " is claimed by a " + private)
claude_row("assistant", message={"content": [{"type": "tool_use", "id": "edit-refused", "name": "Write", "input": {"file_path": leaks[3], "content": private}}]})
shell("agentbus --as a " + shlex.quote(leaks[0]), "agentbus: unknown command '" + private + "'")
shell("AB='agentbus --as a'; $AB read --topic " + shlex.quote(private), "x" * 40)
shell("agentbus claims", "  file a expired " + private + "\n  other b for 2h " + private)
claude_row("attachment", attachment={"type": "hook_cancelled", "hookEvent": "UserPromptSubmit", "command": "agentbus hook claude " + private, "durationMs": 6000})
claude_row("attachment", attachment={"type": "hook_success", "hookEvent": "Stop", "command": "agentbus hook claude " + private, "durationMs": 123})
claude_row("system", subtype="stop_hook_summary", hookInfos=[{"command": "agentbus hook claude " + private, "durationMs": 123}])
claude_row("user", message={"content": "typed prompt " + private})
# A new prompt ends the unread action window.
inject("UserPromptSubmit", "agentbus: unread messages last " + private)
claude_row("user", message={"content": "another prompt " + private})
shell("agentbus --as a brief", "ok")

def jsonl(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r) for r in records) + "\n")

jsonl(claude / leaks[0] / "main.jsonl", rows)
jsonl(claude / leaks[0] / "duplicate.jsonl", rows)
jsonl(claude / leaks[0] / "main" / "subagents" / "sub.jsonl", [
    dict(type="assistant", timestamp=ts, cwd=personal_cwd, sessionId="parent", message={"content": [{"type": "tool_use", "id": "sub-tool", "name": "Bash", "input": {"command": "agentbus --as a who"}}]}),
    dict(type="user", timestamp=ts, message={"content": [{"type": "tool_result", "tool_use_id": "sub-tool", "content": private}]}),
])
jsonl(claude / leaks[0] / "no-bus.jsonl", [dict(type="assistant", timestamp=ts, cwd=work_cwd, sessionId="no-bus", message={"content": [{"type": "text", "text": private}]})])
(claude / leaks[0] / "malformed.jsonl").write_text("{bad " + private + "\n[]\n")

claims_out = json.dumps({"items": [
    {"resource": private, "agent": private, "expires_at": "2025-01-01T00:00:00Z", "state": "expired"},
    {"resource": leaks[3], "agent": leaks[1], "expires_at": "2027-01-01T00:00:00Z", "state": "held"},
]})
codex_rows = [dict(type="session_meta", timestamp=ts, payload={"id": "codex-main", "cwd": work_cwd})]

def completed(command, output, item_id):
    codex_rows.append(dict(type="event_msg", timestamp=ts, payload={"type": "item_completed", "item": {"type": "CommandExecution", "id": item_id, "cwd": work_cwd, "command": ["/bin/zsh", "-c", command], "aggregated_output": output, "exit_code": 0}}))

codex_rows.append(dict(type="response_item", timestamp=ts, payload={"type": "message", "role": "user", "content": [{"type": "input_text", "text": "## Agentbus\nYou are a on the " + private + " bus\n---"}]}))
# The request and completion are the same call, and must not both count.
codex_rows.append(dict(type="response_item", timestamp=ts, payload={"type": "function_call", "name": "exec_command", "call_id": "request", "arguments": json.dumps({"cmd": "agentbus claims"})}))
completed("agentbus --as a claims", claims_out, "ce-1")
completed("agentbus --as a post " + shlex.quote(private) + " --kind invented", "agentbus: kind must be one of " + private, "ce-2")
completed("agentbus --as a claim " + shlex.quote(leaks[3]), "agentbus: " + leaks[3] + " is claimed by b " + private, "ce-3")
codex_rows.extend([
    dict(type="response_item", timestamp=ts, payload={"type": "hook", "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "agentbus: unread direct messages " + private}}),
    dict(type="response_item", timestamp=ts, payload={"type": "function_call", "name": "exec_command", "call_id": "mixed", "arguments": json.dumps({"cmd": "agentbus --as a brief " + shlex.quote(private)})}),
    dict(type="response_item", timestamp=ts, payload={"type": "function_call_output", "call_id": "mixed", "output": json.dumps({"output": private})}),
])
codex_rows.append(dict(type="event_msg", timestamp=ts, payload={"type": "item_completed", "item": {"type": "FileChange", "changes": {leaks[3]: {"text": private}}}}))
jsonl(codex / "nested" / "rollout.jsonl", codex_rows)
jsonl(codex / "copy.jsonl", codex_rows)
# Current function-call rollouts without item_completed records.
jsonl(codex / "modern.jsonl", [
    dict(type="session_meta", timestamp=ts, payload={"id": "modern", "cwd": personal_cwd}),
    dict(type="response_item", timestamp=ts, payload={"type": "function_call", "name": "exec_command", "call_id": "modern-call", "arguments": json.dumps({"cmd": "agentbus --as a watch " + shlex.quote(private)})}),
    dict(type="response_item", timestamp=ts, payload={"type": "function_call_output", "call_id": "modern-call", "output": json.dumps({"output": private, "original_token_count": 100})}),
])
jsonl(codex / "script.jsonl", [
    dict(type="session_meta", timestamp=ts, payload={"id": "js", "cwd": personal_cwd}),
    dict(type="response_item", timestamp=ts, payload={"type": "custom_tool_call", "name": "functions.exec", "call_id": "js-call", "input": "await tools.exec_command({cmd: " + json.dumps("agentbus doctor " + shlex.quote(private)) + "});"}),
    dict(type="response_item", timestamp=ts, payload={"type": "custom_tool_call_output", "call_id": "js-call", "output": private}),
])
history = root / leaks[0] / ".zsh_history"
history.parent.mkdir(parents=True)
history.write_text("\n".join([
    ": 1767225600:0;agentbus watch " + shlex.quote(private),
    "agentbus " + leaks[1],
    ": 1767225601:0;agentbus --as human watch " + "\\",
    " --once # " + private,
    "echo " + shlex.quote(private + " agentbus claim x"),
]) + "\n")

args = ["--cycle", "7", "--bus-root", str(root), "--retired-root", str(retired), "--claude-root", str(claude), "--codex-root", str(codex), "--history", str(history), "--work-pattern", "*/work/*", "--work-pattern", "*/work", "--brain-name", "brain"]

def digest_inputs():
    # Lock bookkeeping may change shm; database/WAL contents must never change.
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file() and not p.name.endswith("-shm")}

before = digest_inputs()
command = [sys.executable, str(script)] + args + ["--output", "-"]
run = subprocess.run(command, capture_output=True, text=True, timeout=15)
assert run.returncode == 0, run.stderr
assert run.stderr == "", run.stderr
data = json.loads(run.stdout)
collect.validate_cycle(data)
assert digest_inputs() == before, "collector changed a source"
assert subprocess.check_output(command, text=True, timeout=15) == run.stdout, "not deterministic"
assert all(secret not in run.stdout for secret in leaks), "private input escaped into cycle"
print("PASS: every source remains unchanged, committed WAL counted, deterministic output contains no synthetic secrets")

p, w = data["workspaces"]["personal"], data["workspaces"]["work"]
assert data["sources"]["bus_files"] == 7, data["sources"]
assert data["sources"]["deduplicated_buses"] == 2
assert data["sources"]["bus_read_errors"] == 1
assert p["peer"]["messages"] == 9, p["peer"]
assert w["peer"]["messages"] == 1
assert p["buses"] == 3  # live and two independently empty buses
assert p["peer"]["directed_asks"] == 3
assert p["peer"]["answered_asks"] == 1
assert p["peer"]["answer_rate"] == 1 / 3
assert p["peer"]["answer_minutes_p50"] == 2
assert p["peer"]["handoff_pickup_rate"] == 1
assert p["peer"]["brain_handoffs_answered"] == 1
assert p["peer"]["handoffs_cursor_covered"] == 1
assert p["peer"]["broadcasts_per_ruling"] == 2
assert p["claims"]["refusals"] == 1
assert p["claims"]["cross_worktree_share"] == 1
assert p["claims"]["expired_at_end"] == 1
print("PASS: prefix dedupe, peer answer/handoff attribution, claim snapshots and classified worktree refusals")

cv, xv = p["verbs"]["claude"], w["verbs"]["codex"]
assert cv["inbox"]["calls"] == 2
assert cv["claim"]["calls"] == 2
assert cv["claim"]["failures"] == 1
assert cv["unknown"]["failures_by_text"]["unknown_command"] == 1
assert cv["read"]["output_bytes_p50"] == 40
assert cv["read"]["output_bytes_p90"] == 40
assert xv["claims"]["calls"] == 1, xv["claims"]
assert xv["claims"]["output_bytes"] == len(claims_out.encode())
assert xv["post"]["failures_by_text"]["bad_kind"] == 1
assert xv["brief"]["calls"] == 1
assert w["hooks"]["events"]["PostToolUse"]["injections"] == 1
assert w["hooks"]["events"]["PostToolUse"]["actions"] == 1
assert p["verbs"]["codex"]["watch"]["calls"] == 1
assert p["verbs"]["codex"]["doctor"]["calls"] == 1
assert p["claims"]["expired_output_share"] == .5
assert w["claims"]["expired_output_share"] == .5
assert p["claims"]["edits_after_refusal"] == 1
assert w["claims"]["edits_after_refusal"] == 1
assert p["adoption"]["claude"]["sessions"] == 2
assert p["adoption"]["claude"]["subagents_using_bus"] == 1
assert w["adoption"]["claude"]["not_using_bus"] == 1
assert p["identity"]["reused_names"] >= 1
assert p["hooks"]["types"]["unread"]["injections"] == 3
assert p["hooks"]["types"]["unread"]["repeats"] == 1
assert p["hooks"]["types"]["unread"]["actions"] == 2
assert p["hooks"]["runs"]["Stop"] == 1
assert p["hooks"]["wall_ms"]["Stop"] == 123
assert p["hooks"]["timeouts"]["UserPromptSubmit"] == 1
assert p["hooks"]["compact_orientations"] == 1
assert p["hooks"]["own_claim_warnings"] == 1
assert p["human"]["commands"]["watch"] == 2
assert p["human"]["commands"]["unknown"] == 1
assert p["human"]["commands"]["claim"] == 0
print("PASS: Claude, subagent and both Codex formats, output bytes, text failures, hooks, identity, adoption and human history")

def rejected(value):
    try:
        collect.validate_cycle(value)
    except ValueError:
        return
    raise AssertionError("schema accepted forbidden data")

for secret in leaks:
    for level in ("root", "nested", "verb"):
        bad = copy.deepcopy(data)
        target = bad if level == "root" else bad["workspaces"]["personal"] if level == "nested" else bad["workspaces"]["personal"]["verbs"]["claude"]
        target[secret] = 1
        rejected(bad)
    bad = copy.deepcopy(data)
    bad["workspaces"]["personal"]["peer"]["messages"] = secret
    rejected(bad)
for value in (True, None, [], {}, float("nan"), float("inf")):
    bad = copy.deepcopy(data)
    bad["cycle"] = value
    rejected(bad)
bad = copy.deepcopy(data)
bad["post"] = 1  # a key allowed elsewhere is forbidden at the root
rejected(bad)
bad = copy.deepcopy(data)
del bad["cycle"]
rejected(bad)
print("PASS: closed schema rejects all extra keys, string values, missing keys, booleans and nonfinite numbers")

# Audit the implementation's connection mode, and prove writes are refused even
# when the caller tries one. The real collection below still sees the WAL row.
real_connect = collect.sqlite3.connect
opened = []

def readonly_connect(database, *positional, **kwargs):
    assert database.startswith("file:") and "?mode=ro" in database
    assert "immutable" not in database and kwargs.get("uri") is True
    con = real_connect(database, *positional, **kwargs)
    try:
        con.execute("CREATE TABLE must_not_write(x)")
    except sqlite3.Error:
        pass
    else:
        raise AssertionError("input connection allowed a write")
    opened.append(database)
    return con

collect.sqlite3.connect = readonly_connect
in_process = collect.Collector(collect.arguments(args)).collect()
assert in_process == data
assert len(opened) == 7  # SQLite opens a corrupt file, then errors on its first query
collect.sqlite3.connect = real_connect
assert digest_inputs() == before
print("PASS: every bus connection uses mode=ro, uri=True, no immutable, and refuses writes")

# Boundaries are inclusive; old calls, questions and undated history are excluded.
window_cmd = command + ["--start", end, "--end", end]
window = json.loads(subprocess.check_output(window_cmd, text=True, timeout=15))
assert window["workspaces"]["personal"]["peer"]["messages"] == 1
assert window["workspaces"]["personal"]["human"]["commands"]["unknown"] == 0
assert window["workspaces"]["personal"]["verbs"]["claude"]["claim"]["calls"] == 0
assert window["window"]["start"] == window["window"]["end"]

# Explicit roots replace defaults: populate all default home locations with data
# that would change the metrics if an override accidentally added them.
home = Path(os.environ["HOME"])
jsonl(home / ".claude/projects/default/main.jsonl", rows)
jsonl(home / ".codex/sessions/default.jsonl", codex_rows)
jsonl(home / ".claude/codex-lanes/lane/sessions/default.jsonl", codex_rows)
(home / ".zsh_history").write_text("agentbus watch\n" + private)
assert subprocess.check_output(command, text=True, timeout=15) == run.stdout
defaults = json.loads(subprocess.check_output([sys.executable, str(script), "--cycle", "8", "--bus-root", str(root), "--retired-root", str(retired), "--output", "-"], text=True, timeout=15))
assert defaults["sources"]["claude_files"] == 1
assert defaults["sources"]["codex_files"] == 2
assert defaults["sources"]["history_files"] == 1
assert defaults["workspaces"]["personal"]["verbs"]["codex"]["claims"]["calls"] == 1
assert defaults["workspaces"]["personal"]["human"]["commands"]["watch"] == 1

default_out = temp / "output"
default_out.mkdir()
subprocess.run([sys.executable, str(script)] + args, cwd=default_out, check=True, timeout=15)
assert json.loads((default_out / "docs/usage/cycles/0007.json").read_text()) == data
refused = subprocess.run([sys.executable, str(script)] + args + ["--output", str(bus_path)], capture_output=True, timeout=15)
assert refused.returncode != 0 and digest_inputs() == before
print("PASS: inclusive time windows, isolated input roots, default cycle file and input overwrite protection")

examples = [
    ("agentbus --as x inbox 2>&1 | tail -5", ["inbox"]),
    ("AB='agentbus --as y'; $AB claim foo; $AB post hi", ["claim", "post"]),
    ('ab() { agentbus --as z "$@"; }; ab brief', ["brief"]),
    ("cat <<'EOF'\nagentbus claim fake\nEOF\nagentbus leave", ["leave"]),
    ("grep agentbus file; echo 'agentbus claim fake'", []),
    ("env -u AGENTBUS_DB python3 bin/agentbus --as a join", ["join"]),
    ("for i in 1 2; do agentbus wait --timeout 1; done", ["wait"]),
    ("x=$(agentbus --as k --json inbox)", ["inbox"]),
    ("agentbus inbox --as k", ["inbox"]),
]
for command_text, wanted in examples:
    assert [c["verb"] for c in collect.parse(command_text)] == wanted, command_text
assert collect.parse("AGENTBUS_AGENT=hidden agentbus inbox")[0]["name"] == "hidden"
# Rule: a trailing "\" makes shlex fall back to split(), which keeps quotes; the
# quoted alias must still resolve (cycle 0 counted these 9 invocations).
continued = 'B="agentbus --as x" && \\\n$B post "a b" --kind note && \\\n$B post "c" --kind answer'
assert [c["verb"] for c in collect.parse(continued)] == ["post", "post"]
print("PASS: cycle-0 parser handles quotes, heredocs, aliases, wrappers and substitutions")

# Rule: scripted populations leave every metric. --exclude-pattern matches the
# transcript path or any recorded cwd (fixtures avoid real tmp roots: mktemp is under them); --exclude-entrypoint matches Claude's entrypoint.
scripted = temp / "scripted"
def tool_rows(sid, cwd, entry, tid):
    base = dict(timestamp=ts, sessionId=sid, cwd=cwd, entrypoint=entry)
    return [dict(base, type="assistant", uuid=tid + "-a", message={"content": [{"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": "agentbus --as a post hi"}}]}),
            dict(base, type="user", uuid=tid + "-u", message={"content": [{"type": "tool_result", "tool_use_id": tid, "content": "ok"}]})]
jsonl(scripted / "claude" / "-tmp-value-run-x-proj" / "trial.jsonl", tool_rows("trial", personal_cwd, "cli", "t1"))
jsonl(scripted / "claude" / "-real" / "eval.jsonl", tool_rows("eval", "/eval-tmp/x", "cli", "t2"))
jsonl(scripted / "claude" / "-real" / "sdk.jsonl", tool_rows("sdk", personal_cwd, "sdk-cli", "t3"))
jsonl(scripted / "claude" / "-real" / "kept.jsonl", tool_rows("kept", personal_cwd, "cli", "t4"))
base_args = ["--cycle", "1", "--bus-root", str(scripted), "--claude-root", str(scripted / "claude"), "--codex-root", str(scripted / "none"), "--history", str(scripted / "none"), "--output", "-"]
def posts(*extra):
    out = json.loads(subprocess.check_output([sys.executable, str(script)] + base_args + list(extra), text=True, timeout=15))
    return out["workspaces"]["personal"]["verbs"]["claude"]["post"]["calls"], out["sources"]["excluded_sessions"]
assert posts() == (4, 0)
assert posts("--exclude-pattern", "*value-run*") == (3, 1)
assert posts("--exclude-pattern", "/eval-tmp/*") == (3, 1)
assert posts("--exclude-entrypoint", "sdk-cli") == (3, 1)
assert posts("--exclude-pattern", "*value-run*", "--exclude-pattern", "/eval-tmp/*", "--exclude-entrypoint", "sdk-cli") == (1, 3)
print("PASS: scripted-run exclusion by transcript path, cwd and entrypoint")

# Rule: the codex-lane "## Agentbus" brief is prompt text, not a hook injection.
assert sum(data["workspaces"][b]["hooks"]["events"]["SessionStart"]["injections"] for b in ("personal", "work")) == 1  # the Claude one only
print("PASS: Codex prompt brief is not counted as a SessionStart hook")

# Rule: with a stop_hook_summary, Stop runs come from the summary only, but a
# hook_cancelled Stop still counts as a timeout (cycle 0: 16 real Stop timeouts).
# Rule: an own claim is any earlier claim attempt under the session's names, even
# one the bus refused (cycle 0 counted attempts).
hooked = temp / "hooked"
hb = dict(timestamp=ts, sessionId="hooked", cwd=personal_cwd)
jsonl(hooked / "claude" / "p" / "s" / "subagents" / "lane.jsonl", [
    dict(hb, type="system", uuid="h1", subtype="stop_hook_summary", hookInfos=[{"command": "agentbus hook claude", "durationMs": 50}]),
    dict(hb, type="attachment", uuid="h2", attachment={"type": "hook_cancelled", "hookEvent": "Stop", "command": "agentbus hook claude", "durationMs": 6000}),
    dict(hb, type="assistant", uuid="h3", message={"content": [{"type": "tool_use", "id": "c1", "name": "Bash", "input": {"command": "agentbus --as lane-x claim src/a.py"}}]}),
    dict(hb, type="user", uuid="h4", message={"content": [{"type": "tool_result", "tool_use_id": "c1", "content": "agentbus: src/a.py is claimed by other until later"}]}),
    dict(hb, type="assistant", uuid="h5", message={"content": [{"type": "tool_use", "id": "e1", "name": "Edit", "input": {"file_path": "/w/src/a.py"}}]}),
    dict(hb, type="attachment", uuid="h6", attachment={"type": "hook_additional_context", "hookEvent": "PreToolUse", "toolUseID": "e1", "content": ["agentbus: a claim under a different name covers this file"]}),
])
hooks = json.loads(subprocess.check_output([sys.executable, str(script), "--cycle", "1", "--bus-root", str(hooked), "--claude-root", str(hooked / "claude"), "--codex-root", str(hooked / "none"), "--history", str(hooked / "none"), "--output", "-"], text=True, timeout=15))["workspaces"]["personal"]["hooks"]
assert hooks["runs"]["Stop"] == 1 and hooks["timeouts"]["Stop"] == 1 and hooks["wall_ms"]["Stop"] == 50, hooks["runs"]
assert hooks["own_claim_warnings"] == 1
print("PASS: Stop timeouts beside summaries, own-claim warnings count refused attempts")

# Rule: only a typed prompt ends an unread action window; a task notification or a
# slash-command echo does not (cycle 0 measured 1,033 notes after notifications).
typed = temp / "typed"
tb = dict(timestamp=ts, sessionId="typed", cwd=personal_cwd)
jsonl(typed / "claude" / "p" / "main.jsonl", [
    dict(tb, type="attachment", uuid="p1", attachment={"type": "hook_additional_context", "hookEvent": "UserPromptSubmit", "content": ["agentbus: 1 unread message"]}),
    dict(tb, type="user", uuid="p2", message={"content": "<task-notification>lane finished</task-notification>"}),
    dict(tb, type="user", uuid="p3", message={"content": "<command-name>/clear</command-name>"}),
    dict(tb, type="assistant", uuid="p4", message={"content": [{"type": "tool_use", "id": "i1", "name": "Bash", "input": {"command": "agentbus --as a inbox"}}]}),
    dict(tb, type="attachment", uuid="p5", attachment={"type": "hook_additional_context", "hookEvent": "UserPromptSubmit", "content": ["agentbus: 2 unread messages"]}),
    dict(tb, type="user", uuid="p6", message={"content": "a typed prompt"}),
    dict(tb, type="assistant", uuid="p7", message={"content": [{"type": "tool_use", "id": "i2", "name": "Bash", "input": {"command": "agentbus --as a inbox"}}]}),
])
unread = json.loads(subprocess.check_output([sys.executable, str(script), "--cycle", "1", "--bus-root", str(typed), "--claude-root", str(typed / "claude"), "--codex-root", str(typed / "none"), "--history", str(typed / "none"), "--output", "-"], text=True, timeout=15))["workspaces"]["personal"]["hooks"]["types"]["unread"]
assert unread["injections"] == 2 and unread["actions"] == 1, unread
print("PASS: task notifications and command echoes do not end an action window")
db.close()
PYTEST
ok "usage collector fixture suite"
echo "All usage collector tests passed"
