#!/usr/bin/env bash
# The second DX/AX pass (issue #22): brief shows what waits between other agents, did-you-mean for flags,
# commands and names, a `next` on every JSON error, one version field on every result, a schema CMD that is
# only that command's, `claim` that says it renewed, and the help tags for status and brief.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/bus/bus.db"; mkdir -p "$T/bus"
cd "$T"
# pyj 'CODE': runs CODE with d = the JSON on stdin.
# The failure names the check: LABEL when given, else the first line of CODE.
pyj() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" || fail "JSON check failed: ${2:-$(sed -n '/./{p;q;}' <<<"$1")}"; }
# gets TEXT FILE: FILE contains TEXT, else fails with FAIL_TEXT naming the missing behaviour.
has() { grep -qF -- "$2" "$3" || fail "$1: no '$2' in: $(cat "$3")"; }

for n in alpha beta gamma; do agentbus --as "$n" join >/dev/null; done

echo "TEST 1: brief shows questions and handoffs pending between other agents"
agentbus --as beta post "Can I edit api/schema.py or are you in it right now?" --to alpha --kind question >/dev/null
agentbus --as beta post "branch feat/x is ready; tests pass" --to alpha --kind handoff >/dev/null
agentbus --as gamma brief >"$T/o" 2>&1
has "pending between others missing" "pending between others (2):" "$T/o"
has "pending between others missing the question" "#1 beta -> alpha: Can I edit api/schema.py" "$T/o"
has "pending between others missing the handoff" "#2 beta -> alpha [handoff]: branch feat/x" "$T/o"
has "pending between others missing its next" "next: agentbus read --id 1" "$T/o"
has "open questions must stay about gamma" "open questions: none" "$T/o"
agentbus --as gamma --json brief | pyj '
p = d["pending_others"]
assert [m["id"] for m in p["items"]] == [1, 2] and p["next"] == "agentbus read --id 1", p
assert d["omitted"]["pending_others"] == 0 and d["questions"]["items"] == [], d' "the JSON has no pending_others"
# the two others' own view: beta sent them, alpha got them (open questions and unread), so neither is "between others"
agentbus --as alpha brief >"$T/o" 2>&1; has "alpha must see it as unread, not pending" "pending between others: none" "$T/o"
agentbus --as beta brief >"$T/o" 2>&1; has "the sender must not see its own as pending" "pending between others: none" "$T/o"
# answered and read: no longer pending
agentbus --as alpha post "wait" --to beta --reply-to 1 --kind answer >/dev/null
agentbus --as alpha inbox >/dev/null
agentbus --as gamma brief >"$T/o" 2>&1
has "an answered, read pair is still pending" "pending between others: none" "$T/o"
# capped, with the count of the rest and the command that shows more
for i in 1 2 3 4 5 6 7; do agentbus --as beta post "q$i" --to alpha --kind question >/dev/null; done
agentbus --as gamma brief >"$T/o" 2>&1
has "pending between others is not capped" "... 2 more (agentbus --as gamma brief --limit 20)" "$T/o"
ok "brief lists what waits between other agents, capped, with a next"

echo "TEST 2: did-you-mean for flags, commands and names"
agentbus --as gamma post hi --kynd note >/dev/null 2>"$T/e" && fail "an unknown flag was accepted" || true
has "unknown flag has no did-you-mean" "Did you mean --kind?" "$T/e"
agentbus --as gamma post hi --tpo alpha --kynd note >/dev/null 2>"$T/e" && fail "two unknown flags were accepted" || true
has "two unknown flags have no did-you-mean" "Did you mean --to (for --tpo), --kind (for --kynd)?" "$T/e"
agentbus --as gamma --json post hi --kynd note >/dev/null 2>"$T/e" && fail "an unknown flag was accepted under --json" || true
pyj 'assert "Did you mean --kind?" in d["error"]["message"] and d["error"]["next"] == "agentbus post --help", d' <"$T/e"
agentbus lgo >/dev/null 2>"$T/e" && fail "an unknown command ran" || true
has "unknown command has no did-you-mean" "Did you mean log?" "$T/e"
has "unknown command lacks the command list" "Commands: join, leave, who, post," "$T/e"
agentbus --json lgo >/dev/null 2>"$T/e" && fail "an unknown command ran under --json" || true
pyj 'e = d["error"]; assert e["code"] == "bad_input" and "Did you mean log?" in e["message"] and "Commands: join," in e["message"] and e["next"] == "agentbus --help", d' <"$T/e"
agentbus --as alpa post hi >/dev/null 2>"$T/e" && fail "post from a typo'd name was accepted" || true
has "--as typo has no did-you-mean" "alpa is not on the roster. Did you mean alpha? On the roster: alpha, beta, gamma. To join as alpa: agentbus --as alpa join" "$T/e"
agentbus --as alpa --json post hi >/dev/null 2>"$T/e" && fail "post from a typo'd name was accepted under --json" || true
pyj 'e = d["error"]; assert e["code"] == "not_on_roster" and e["did_you_mean"] == ["alpha"] and e["roster"] == ["alpha", "beta", "gamma"] and e["next"] == "agentbus --as alpa join", d' <"$T/e"
agentbus --as zzzz post hi >/dev/null 2>"$T/e" && fail "post from an unknown name was accepted" || true
has "a far name must keep the plain error" "zzzz is not on the roster. Run: agentbus --as zzzz join" "$T/e"
if grep -q "Did you mean" "$T/e"; then fail "did-you-mean shown when nothing is close"; fi
agentbus --as alpha post hi --to gama >/dev/null 2>"$T/e"
has "--to warning lacks the roster" "gama is not on the roster; the message waits for that name. Did you mean gamma? On the roster: alpha, beta, gamma." "$T/e"
agentbus --as alpha --json post hi --to gama 2>/dev/null | pyj '
w = d["warnings"][0]
assert w["did_you_mean"] == ["gamma"] and w["roster"] == ["alpha", "beta", "gamma"] and w["roster_total"] == 3, d' "the JSON warning lacks the roster"
# the roster is capped
for i in $(seq 1 12); do agentbus --as "agent$i" join >/dev/null; done
agentbus --as alpha --json post hi --to nobody-here 2>/dev/null | pyj 'w = d["warnings"][0]; assert len(w["roster"]) == 10 and w["roster_total"] == 15, d'
ok "flags, commands and names say what was meant, and the roster"

echo "TEST 3: every JSON error has next, the command its message gives"
# errcase LABEL CODE ARGS...: ARGS (no --json) fail with CODE; as JSON the error's `next` is a string that is also in the text error.
ERR_CWD=$T; ERR_ENV=(X_UNUSED=1)
errcase() {
  local label=$1 code=$2; shift 2
  (cd "$ERR_CWD" && env "${ERR_ENV[@]}" "${AB[@]}" --json "$@" >/dev/null 2>"$T/ej") && fail "$label: succeeded under --json"
  (cd "$ERR_CWD" && env "${ERR_ENV[@]}" "${AB[@]}" "$@" >/dev/null 2>"$T/et") && fail "$label: succeeded in text"
  python3 - "$T/ej" "$T/et" "$label" "$code" <<'PY' || fail "$label: next does not match the message"
import json, sys
err = json.load(open(sys.argv[1]))["error"]
text = " ".join(open(sys.argv[2]).read().split())
label, code = sys.argv[3:5]
assert err["code"] == code, (label, err)
assert isinstance(err.get("next"), str) and err["next"], ("next is missing", label, err)
assert err["next"] in text, ("next is not the command in the message", label, err["next"], text)
print("next", code, err["next"][:70])
PY
}
mkdir -p "$T/empty"
agentbus --as alpha claim src/a.py --purpose "edit" >/dev/null
agentbus --as alpha ctx set stage one >/dev/null
agentbus --as alpha post hi --request-id tok >/dev/null
ERR_CWD=$T/empty; ERR_ENV=(-u AGENTBUS_DB)
errcase "no bus" no_bus who
errcase "no outer bus" no_bus --up 5 who
ERR_CWD=$T; ERR_ENV=(X_UNUSED=1)
errcase "not on roster" not_on_roster --as ghost ctx set k v
errcase "claim conflict" claim_conflict --as beta claim src/a.py
errcase "no message" no_message read --id 999
errcase "no fact" no_context_key ctx get nope
errcase "not held" not_held --as beta release src/a.py
errcase "name active" name_active --as alpha join
errcase "no identity" bad_input post hi
errcase "usage error" bad_input --as alpha post hi --kynd note
errcase "unknown command" bad_input lgo
# the Codex hooks printer refuses a project copy and names the command to run from the installed tool
agentbus init "$T/hk" >/dev/null
AB_INSTALLED=("${AB[@]}"); AB=("$PY" "$T/hk/.agentbus/bin/agentbus")
errcase "hooks from a project copy" bad_input hooks codex
AB=("${AB_INSTALLED[@]}")
# a code with no command to run says so with null (the key is always there)
agentbus --json --as alpha post other --request-id tok >/dev/null 2>"$T/e" && fail "a reused request id was accepted" || true
pyj 'e = d["error"]; assert e["code"] == "request_id_reused" and "next" in e and e["next"] is None, d' <"$T/e"
# a newer bus: the fix is the upgrade command, named as the message names it
python3 - "$T/bus/bus.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=99"); c.commit(); c.close()
PY
errcase "newer bus" schema_newer --as alpha who
python3 - "$T/bus/bus.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=1"); c.commit(); c.close()
PY
agentbus --json schema | pyj 'f = d["error_fields"]["next"]; assert f["type"] == ["string", "null"], f'
ok "12 errors across 9 codes carry the message's own command as next, and a code with none says null"

echo "TEST 4: one version field, contract, on every command's result"
agentbus init "$T/proj" >/dev/null
printf '{"v":1,"checked_at":%s,"ok":true,"reason":null,"retry_after":null,"stable":"0.9.0","pre":null,"notified":null}' "$(date +%s)" >"$T/cache.json"
CACHE=$(python3 - <<'PY'
import os, sys
print(os.path.join(os.environ["HOME"], "Library/Caches/agentbus" if sys.platform == "darwin" else ".cache/agentbus"))
PY
)
mkdir -p -m 700 "$CACHE"; cp "$T/cache.json" "$CACHE/release-check.json"; chmod 600 "$CACHE/release-check.json"
export AB_JSON; AB_JSON=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "${AB[@]}")
agentbus --json schema >"$T/schema.json"
python3 - "$T" <<'PY' || fail "a result lacks contract: $?"
import json, os, subprocess, sys
T = sys.argv[1]
schema = json.load(open(T + "/schema.json"))
want = schema["contract"]
tool = [*json.loads(os.environ["AB_JSON"])]
table = {
    "join": ["--as", "delta", "join"], "leave": ["--as", "delta", "leave"], "who": ["who"],
    "post": ["--as", "alpha", "post", "hello"], "inbox": ["--as", "beta", "inbox", "--peek"], "wait": ["--as", "beta", "wait", "--timeout", "1"], "read": ["read"],
    "ctx set": ["--as", "alpha", "ctx", "set", "k", "v"], "ctx get": ["ctx", "get", "k"], "ctx history": ["ctx", "history", "k"],
    "claim": ["--as", "alpha", "claim", "src/b.py"], "release": ["--as", "alpha", "release", "src/b.py"], "claims": ["claims"],
    "log add": ["--as", "alpha", "log", "add", "act", "detail"], "log show": ["log", "show"], "status": ["status"],
    "goal": ["goal"], "watch": ["watch", "--once"], "buses": ["buses"], "init": ["init", T + "/proj2"],
    "upgrade": ["upgrade", T + "/proj"], "update": ["update", "--check"], "schema": ["schema", "post"], "skill": ["skill"],
    "help": ["help", "post"], "completion": ["completion", "bash"], "setup": ["setup", "claude", "--dry-run"],
    "doctor": ["doctor"], "brief": ["--as", "alpha", "brief"], "demo": ["demo"], "hooks": ["hooks", "codex"],
}
extra = [["read", "--id", "1"], ["ctx", "get"], ["goal"], ["--as", "alpha", "goal", "ship it"], ["goal"], ["schema", "--index"],
         ["schema"], ["help"], ["skill", "--agents-md"], ["upgrade", "--all", T + "/proj", "--dry-run"], ["--as", "alpha", "claim", "src/b.py"],
         ["--as", "alpha", "claim", "src/b.py"], ["setup", "codex", "--dry-run"], ["hooks", "claude"]]
assert set(table) == set(schema["commands"]), ("the table and the registry differ", set(table) ^ set(schema["commands"]))
for args in list(table.values()) + extra:
    p = subprocess.run([*tool, "--json", *args], capture_output=True, text=True, cwd=T, timeout=120)
    assert p.returncode in (0, 1), (args, p.returncode, p.stderr[:300])
    r = json.loads(p.stdout)
    assert isinstance(r, dict) and list(r)[0] == "contract" and r["contract"] == want == 1, (args, "no contract first", str(r)[:200])
print("contract on", len(table) + len(extra), "results")
PY
agentbus --json schema | pyj '
for name, c in d["commands"].items():
    r = c["result"]
    branches = r["anyOf"] if "anyOf" in r else [r]
    for b in branches:
        req = b["required"] if "required" in b else b["allOf"][1]["required"]
        assert "contract" in req, (name, b)' "the registry does not require contract"
agentbus --as alpha --json goal | pyj 'assert d == {"contract": 1, "goal": "ship it", "set_by": "alpha", "set_at": d["set_at"]}, d'
ok "every command's --json result starts with contract, and the registry requires it"

echo "TEST 5: schema CMD is that command's own"
agentbus --json schema post >"$T/s"
pyj '
assert set(d["errors"]) == {"no_message", "not_on_roster", "request_id_reused"}, list(d["errors"])
assert "bad_input" in d["common_errors"] and "internal" in d["common_errors"], d["common_errors"]
for k in ("global_args", "env", "exit_codes"):
    assert k not in d, k
assert list(d["warnings"]) == ["recipient_not_on_roster"], list(d["warnings"])' "schema post carries more than its own" <"$T/s"
n=$(wc -c <"$T/s" | tr -d " "); [ "$n" -lt 6000 ] || fail "schema post is $n bytes without --full; it was 8,564"
agentbus --json schema post --full >"$T/sf"
pyj '
for k in ("global_args", "env", "exit_codes"):
    assert k in d, k
assert "bad_input" in d["errors"] and "no_message" in d["errors"] and "common_errors" not in d, list(d)' "schema post --full lacks the shared parts" <"$T/sf"
agentbus --json schema | pyj 'assert {"global_args", "env", "exit_codes"} <= set(d) and "bad_input" in d["errors"] and "common_errors" not in d, list(d)' "the whole schema lost its shared parts"
agentbus --json schema who | pyj 'assert list(d["warnings"]) == [] and "no_message" not in d["errors"], d'
ok "schema post is $n bytes (8,564 before), the full one has the shared parts"

echo "TEST 6: claim says when it renewed, and shows a purpose change"
agentbus --as gamma claim src/g.py >"$T/o"; [ "$(cat "$T/o")" = "$(sed 's/^renewed/claimed/' "$T/o")" ] && grep -q '^claimed src/g.py ' "$T/o" || fail "a first claim must say claimed: $(cat "$T/o")"
agentbus --as gamma claim src/g.py >"$T/o"; grep -q '^renewed src/g.py ' "$T/o" || fail "a repeat claim must say renewed: $(cat "$T/o")"
agentbus --as gamma claim src/g.py --purpose one >"$T/o"; grep -q '^renewed src/g.py for .*; purpose now "one"$' "$T/o" || fail "renewed must show the new purpose: $(cat "$T/o")"
agentbus --as gamma claim src/g.py --purpose two >"$T/o"; grep -q '; purpose was "one", now "two"$' "$T/o" || fail "renewed must show the purpose change: $(cat "$T/o")"
agentbus --as gamma --json claim src/g.py --purpose three | pyj 'assert d["renewed"] is True and d["previous_purpose"] == "two" and d["purpose"] == "three", d'
agentbus --as gamma --json claim src/g.py | pyj 'assert d["renewed"] is True and "previous_purpose" not in d, d'
agentbus --as gamma --json claim src/h.py | pyj 'assert d["renewed"] is False and "previous_purpose" not in d, d'
python3 - "$T/bus/bus.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("UPDATE claims SET expires_at='2001-01-01T00:00:00Z' WHERE resource='src/h.py'"); c.commit(); c.close()
PY
agentbus --as gamma --json claim src/h.py | pyj 'assert d["renewed"] is False, d'
ok "claim: claimed, renewed (still held), and the purpose change; an expired claim is taken again, not renewed"

echo "TEST 7: --help tags status as the overview for people and brief as the agent's first call"
agentbus --help >"$T/o"
grep -q '^    brief  *Your first call: ' "$T/o" || fail "agentbus --help does not tag brief as the first call: $(grep -n brief "$T/o")"
grep -q '^    status  *The overview for people; agents start with brief' "$T/o" || fail "agentbus --help does not tag status as the overview for people"
agentbus status --help >"$T/o"; grep -q 'The overview for people' "$T/o" || fail "status --help does not say it is for people"
agentbus brief --help >"$T/o"; grep -q "The agent's first call" "$T/o" || fail "brief --help does not say it is the first call"
ok "help tags"

all_passed "All dx2 tests passed"
