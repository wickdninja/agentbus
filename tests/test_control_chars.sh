#!/bin/bash
set -euo pipefail
# Identifiers (agent names, topics, context keys, claim resources) refuse control characters at every
# input path with bad_input (exit 2, the field named, the character shown as U+XXXX); rows an older bus
# already holds are still read and shown escaped. Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
trap 'rm -rf "$T"' EXIT
cd "$T"
export AGENTBUS_DB="$T/bus.db"
agentbus() { "${AB[@]}" "$@"; }
agentbus --as a join >/dev/null
rows() { "$PY" -c "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);print(sum(c.execute('select count(*) from '+t).fetchone()[0] for t in ('agents','messages','context','claims')))" "$AGENTBUS_DB"; }

echo "TEST: every identifier path refuses a control character, names the field, writes nothing"
ESC=$'\e'; NL=$'\n'; uni() { "$PY" -c 'import sys;sys.stdout.write(sys.argv[1].encode().decode("unicode_escape"))' "$1"; }  # no locale needed
BIDI=$(uni '\u202e'); C1=$(uni 'k\x85x')
before=$(rows)
check() {  # FIELD CODEPOINT -- args...
  local field=$1 cp=$2; shift 3
  local rc=0 err
  err=$("$@" 2>&1 >/dev/null) || rc=$?
  [ "$rc" = 2 ] || fail "$field: exit $rc, want 2 ($*)"
  case "$err" in "agentbus: $field must not contain control characters (found U+$cp)"*) ;; *) fail "$field: message was: $err" ;; esac
  rc=0; err=$("$@" --json 2>&1 >/dev/null) || rc=$?
  [ "$rc" = 2 ] || fail "$field --json: exit $rc"
  echo "$err" | "$PY" -c "import json,sys;e=json.load(sys.stdin)['error'];assert e['code']=='bad_input' and e['field']==sys.argv[1] and e['committed'] is False, e" "$field" || fail "$field: JSON error was $err"
}
check --as 001B -- agentbus --as "ev${ESC}]52;c;x" join
check --as 001B -- agentbus --as "ev${ESC}x" inbox
check --as 000A -- agentbus --as "a${NL}b" post hi
check --as 202E -- agentbus --as "a${BIDI}b" ctx set k v
check --as 001B -- agentbus --as "a${ESC}" claim some/file
check --as 001B -- agentbus --as "a${ESC}" who
check --as 001B -- agentbus --as "a${ESC}" watch --once
check AGENTBUS_AGENT 001B -- env "AGENTBUS_AGENT=ev${ESC}x" "${AB[@]}" join
check AGENTBUS_AGENT 000A -- env "AGENTBUS_AGENT=ev${NL}x" "${AB[@]}" post hi
check --to 001B -- agentbus --as a post --to "n${ESC}x" hi
check --to 202E -- agentbus --as a post --to "n${BIDI}x" hi
check --topic 000A -- agentbus --as a post --topic "t${NL}x" hi
check --topic 001B -- agentbus --as a read --topic "t${ESC}x"
check KEY 001B -- agentbus --as a ctx set "k${ESC}x" v
check KEY 007F -- agentbus --as a ctx get $'k\x7fx'
check KEY 0085 -- agentbus --as a ctx history "$C1"
check RESOURCE 001B -- agentbus --as a claim "f${ESC}x"
check RESOURCE 0007 -- agentbus --as a claim $'issue:\a1'
check RESOURCE 0009 -- agentbus --as a release $'f\tx'
[ "$(rows)" = "$before" ] || fail "a refused input changed the bus"
ok "18 input paths refused, nothing written"

echo "TEST: plain names, keys, resources and unicode letters are still accepted"
agentbus --as "sam-2.x" join >/dev/null
agentbus --as a ctx set "name é/ü" v >/dev/null
agentbus --as a claim "src/日本.py" >/dev/null
ok "accepted"

echo "TEST: an older bus that already holds control characters is read, never crashed on"
"$PY" - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
t = "2026-01-01T00:00:00Z"
c.execute("insert into agents(name,joined_at,last_seen) values(?,?,?)", ("ev\x1b]52;c;QQ==\x07", t, t))
c.execute("insert into context(key,value,updated_by,updated_at) values(?,?,?,?)", ("k\x1b[2Jey", "v", "ev\x1b", t))
c.execute("insert into context_history(key,value,updated_by,updated_at) values(?,?,?,?)", ("k\x1b[2Jey", "v", "ev\x1b", t))
c.execute("insert into claims(resource,agent,purpose,claimed_at,expires_at) values(?,?,?,?,?)", ("f\x1b]52;c;QQ==\x07", "ev\x1b", None, t, "2999-01-01T00:00:00Z"))
c.execute("insert into messages(ts,sender,recipient,kind,topic,body) values(?,?,?,?,?,?)", (t, "ev\x1b", "a", "note", "t\u202eop", "hello"))
c.commit()
PY
for args in "who" "claims" "ctx get" "ctx history k" "read" "inbox --peek" "status" "watch --once" "claim other/file" "post fine"; do
  out=$(agentbus --as a $args 2>&1) || fail "'$args' failed on an old bus: $out"
  case "$out" in *$'\e'*|*$'\a'*|*"$BIDI"*) fail "'$args' printed a raw control character" ;; esac
done
for args in "who" "claims" "ctx get" "read" "inbox --peek"; do
  agentbus --as a --json $args >/dev/null 2>&1 || fail "'$args --json' failed on an old bus"
done
agentbus --as a claims | grep -qF 'f\x1b]52;c;QQ==\x07' || fail "an old claim was not shown escaped"
agentbus --as a ctx get | grep -qF 'k\x1b[2Jey' || fail "an old key was not shown escaped"
ok "old rows are shown escaped on every reader, human and JSON"
echo "All control-character tests passed"
