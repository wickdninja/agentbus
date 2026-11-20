#!/bin/bash
set -euo pipefail
# The roster and log requirements of docs/protocol.md (P-ID-1 to P-ID-3, P-ID-5 to P-ID-11, P-LOG-1, P-LOG-2), one section
# each, every check printing its own FAIL line. tests/test_identity.sh, tests/test_control_chars.sh and tests/test_inbox.sh
# pin the wording and the paths around them; this file pins the rules, so a mutation of one rule (tests/mutations.json,
# field "must") fails here for that rule's reason. Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/rules.db"
cd "$T"

# sql STATEMENT [ARG...]: one write straight into the bus, as a tool that planted rows would.
sql() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2], sys.argv[3:]); c.commit()' "$AGENTBUS_DB" "$@"; }
# rows STATEMENT [ARG...]: the first column of every row, one per line.
rows() { python3 -c 'import sqlite3,sys; [print(r[0]) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2], sys.argv[3:])]' "$AGENTBUS_DB" "$@"; }
# one STATEMENT [ARG...]: the first column of the first row.
one() { rows "$@" | head -1; }
# stamp MINUTES: the time MINUTES ago (negative: in the future) as the bus writes it.
stamp() { python3 -c 'import sys,datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
# field JSON KEY: one key of a JSON object.
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
# jfail CODE cmd...: the command exits non-zero with this JSON error code on stderr.
jfail() {
  local want=$1; shift
  local e; e=$(mktemp)
  if "$@" >/dev/null 2>"$e"; then fail "expected $want but succeeded: $*"; fi
  python3 - "$want" "$e" <<'PY' || fail "wrong error from: $* ($(cat "$e"))"
import json, sys
assert json.load(open(sys.argv[2]))["error"]["code"] == sys.argv[1]
PY
}
count() { one "SELECT COUNT(*) FROM $1"; }
logs() { one "SELECT COUNT(*) FROM log WHERE action=?" "$1"; }

echo "TEST P-ID-1: a name join accepts matches [A-Za-z0-9._-]{1,40}; an older name that does not match keeps working"
# Bug it catches (mutation): the length limit off by one either way, a character class widened, the check skipped.
long40=$(printf 'n%.0s' $(seq 1 40)); long41=${long40}n
for good in a A.b_c-9 "$long40" 0 ..; do
  agentbus --as "$good" join >/dev/null || fail "a valid name was refused by join: $good"
done
before=$(count agents)
for bad in "has space" "$long41" "slash/x" "caf$(printf '\303\251')" "a:b" "a,b" "a*"; do
  jfail bad_input "${AB[@]}" --json --as "$bad" join
done
[ "$(count agents)" = "$before" ] || fail "a refused name joined the roster"
sql "INSERT INTO agents(name,joined_at,last_seen) VALUES('old name','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')"
sql "INSERT INTO agents(name,joined_at,last_seen) VALUES(?, '2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')" "$long41"
agentbus --as "old name" post "from an older name" >/dev/null || fail "a name on the roster that does not match the rule could not post"
agentbus --as "$long41" claim "older/long.py" >/dev/null || fail "a 41-character name on the roster could not claim"
ok "40 characters and the class accepted, 41 and outside the class refused, older names keep working"

echo "TEST P-ID-2: control and bidi characters are refused with bad_input in the name, recipient, topic, fact key and resource"
# Bug it catches (mutation): one of the inputs left unchecked, DEL or a C1 character accepted, a bidi character off the list.
agentbus --as ca join >/dev/null
n=$(count messages)
# every character of the list, through one input; every input, through one character
while IFS= read -r -d '' c; do
  jfail bad_input "${AB[@]}" --json --as ca post "x" --topic "t${c}x"
done < <(python3 -c '
import sys
for c in "\n\t\x7f\x85\u061c\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069":
    sys.stdout.buffer.write(c.encode() + b"\0")')
c=$'\n'
jfail bad_input "${AB[@]}" --json --as "ca${c}x" post "x"
jfail bad_input "${AB[@]}" --json --as ca post "x" --to "r${c}x"
jfail bad_input "${AB[@]}" --json --as ca read --topic "t${c}x"
jfail bad_input "${AB[@]}" --json --as ca ctx set "k${c}x" v
jfail bad_input "${AB[@]}" --json --as ca claim "r${c}x"
jfail bad_input "${AB[@]}" --json --as ca release "r${c}x"
AGENTBUS_AGENT="ca${c}x" jfail bad_input "${AB[@]}" --json post "x"
[ "$(count messages)" = "$n" ] || fail "a refused input stored a message"
# an older name that holds one of the characters can no longer be passed as the caller's name
sql "INSERT INTO agents(name,joined_at,last_seen) VALUES(?, '2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')" "old"$'\t'"tab"
jfail bad_input "${AB[@]}" --json --as "old"$'\t'"tab" post "x"
AGENTBUS_AGENT="old"$'\t'"tab" jfail bad_input "${AB[@]}" --json post "x"
agentbus --as ca post "free text may hold a tab	and a bell" --kind note >/dev/null || fail "a body with a tab was refused: bodies are free text"
agentbus --as ca ctx set freekey $'a value\nwith a newline' >/dev/null || fail "a value with a newline was refused: values are free text"
agentbus --as ca log add free $'detail\nwith a newline' >/dev/null || fail "a log detail with a newline was refused: details are free text"
ok "each of the eight inputs refuses a control character, and all 16 characters are refused; free text may hold them"

echo "TEST P-ID-3: post, claim, ctx set, goal and log add refuse a name that is not on the roster and write nothing; release and leave need no entry"
# Bug it catches (mutation): one write that skips the roster check, or a name that could never join told to join.
before="$(count messages)/$(count claims)/$(count context)/$(count context_history)/$(count log)"
jfail not_on_roster "${AB[@]}" --json --as outsider post "x"
jfail not_on_roster "${AB[@]}" --json --as outsider claim some/file.py
jfail not_on_roster "${AB[@]}" --json --as outsider ctx set k v
jfail not_on_roster "${AB[@]}" --json --as outsider goal "a goal"
jfail not_on_roster "${AB[@]}" --json --as outsider log add act detail
jfail bad_input "${AB[@]}" --json --as "not a name!" post "x"
jfail bad_input "${AB[@]}" --json --as "not a name!" claim x.py
[ "$(count messages)/$(count claims)/$(count context)/$(count context_history)/$(count log)" = "$before" ] \
  || fail "a refused write from a name off the roster changed the bus"
sql "INSERT INTO claims VALUES('outsider/f.py','outsider',NULL,'2020-01-01T00:00:00Z','2999-01-01T00:00:00Z')"
agentbus --as outsider release outsider/f.py >/dev/null || fail "release by a name off the roster was refused"
[ "$(one "SELECT COUNT(*) FROM claims WHERE resource='outsider/f.py'")" = 0 ] || fail "release by a name off the roster did not let go of its claim"
agentbus --as outsider leave >/dev/null 2>&1 || fail "leave by a name off the roster was refused"
ok "five writes refused with not_on_roster, an impossible name with bad_input, release and leave need no entry"

echo "TEST P-ID-5: join refuses a name seen in the last 30 minutes with name_active, unless --takeover or the environment names it"
# Bug it catches (mutation): the window wrong either way, a future last_seen locking the name, --takeover or the environment not lifting the refusal.
agentbus --as live join --tool t1 >/dev/null
jfail name_active "${AB[@]}" --json --as live join
sql "UPDATE agents SET last_seen=? WHERE name='live'" "$(stamp 29)"
jfail name_active "${AB[@]}" --json --as live join
agentbus --as live join --takeover --tool t2 >/dev/null || fail "--takeover did not lift name_active"
AGENTBUS_AGENT=live agentbus join >/dev/null || fail "a session whose environment names the name was refused as another session"
sql "UPDATE agents SET last_seen=? WHERE name='live'" "$(stamp 31)"
agentbus --as live join >/dev/null || fail "a name idle for 31 minutes was refused"
sql "UPDATE agents SET last_seen=? WHERE name='live'" "$(stamp -600)"
agentbus --as live join >/dev/null || fail "a name with a last_seen in the future locked the name"
ok "29 minutes refused, 31 minutes and a future time allowed, takeover and the environment lift it"

echo "TEST P-ID-6: join writes the entry with last_seen now; a rejoin keeps joined_at and replaces cwd and branch; --takeover keeps tool, model and role not given"
# Bug it catches (mutation): joined_at reset, cwd or branch kept, tool/model/role replaced with takeover or kept without it, last_seen not refreshed.
agentbus --as rj join --tool t1 --model m1 --role r1 --branch b1 --cwd /one >/dev/null
sql "UPDATE agents SET joined_at='2020-01-01T00:00:00Z', last_seen='2020-01-01T00:00:00Z' WHERE name='rj'"
agentbus --as rj join --tool t2 --branch b2 --cwd /two >/dev/null
[ "$(one "SELECT tool||'|'||COALESCE(model,'-')||'|'||COALESCE(role,'-')||'|'||branch||'|'||cwd||'|'||joined_at FROM agents WHERE name='rj'")" = "t2|-|-|b2|/two|2020-01-01T00:00:00Z" ] \
  || fail "a rejoin without --takeover stored: $(one "SELECT tool||'|'||COALESCE(model,'-')||'|'||COALESCE(role,'-')||'|'||branch||'|'||cwd||'|'||joined_at FROM agents WHERE name='rj'")"
[ "$(one "SELECT last_seen > '2026' FROM agents WHERE name='rj'")" = 1 ] || fail "a rejoin did not refresh last_seen"
sql "UPDATE agents SET last_seen='2020-01-01T00:00:00Z' WHERE name='rj'"
agentbus --as rj join --tool t3 --model m3 --role r3 --branch b3 --cwd /three >/dev/null || fail "setup rejoin failed"
sql "UPDATE agents SET last_seen='2020-01-01T00:00:00Z' WHERE name='rj'"
agentbus --as rj join --takeover --tool t4 >/dev/null
[ "$(one "SELECT tool||'|'||COALESCE(model,'-')||'|'||COALESCE(role,'-')||'|'||COALESCE(branch,'-') FROM agents WHERE name='rj'")" = "t4|m3|r3|-" ] \
  || fail "--takeover stored: $(one "SELECT tool||'|'||COALESCE(model,'-')||'|'||COALESCE(role,'-')||'|'||COALESCE(branch,'-') FROM agents WHERE name='rj'") (want t4|m3|r3|-)"
agentbus --as rj join --takeover >/dev/null
[ "$(one "SELECT tool||'|'||model||'|'||role FROM agents WHERE name='rj'")" = "t4|m3|r3" ] || fail "--takeover with nothing given dropped tool, model or role"
agentbus --as rj claim rj/keep.py >/dev/null
agentbus --as rj join --takeover >/dev/null
[ "$(one "SELECT COUNT(*) FROM claims WHERE agent='rj'")" = 1 ] || fail "a rejoin dropped the name's claims"
ok "joined_at kept, cwd and branch replaced, takeover keeps what it is not given, claims kept"

echo "TEST P-ID-7: join creates a cursor only when there is none: last_read_id 0, broadcasts from the highest id at that moment"
# Bug it catches (mutation): a new name starting its direct mail at the newest message, broadcasts from the start, or a rejoin resetting the cursor.
agentbus --as poster join >/dev/null
d1=$(agentbus --json --as poster post "direct before" --to newbie | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
b1=$(agentbus --json --as poster post "broadcast before" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
agentbus --as newbie join >/dev/null
[ "$(one "SELECT last_read_id||'|'||bcast_from FROM cursors WHERE agent='newbie'")" = "0|$b1" ] \
  || fail "a new name's cursor is $(one "SELECT last_read_id||'|'||bcast_from FROM cursors WHERE agent='newbie'"), want 0|$b1"
agentbus --as poster post "broadcast after" >/dev/null
got=$(agentbus --json --as newbie inbox --peek | python3 -c 'import json,sys; print("|".join(r["body"] for r in json.load(sys.stdin)["items"]))')
[ "$got" = "direct before|broadcast after" ] || fail "a new name's first inbox held: $got (want the direct mail from before it joined and the broadcast after)"
agentbus --as newbie inbox >/dev/null
sql "UPDATE agents SET last_seen='2020-01-01T00:00:00Z' WHERE name='newbie'"
agentbus --as newbie join >/dev/null
got=$(one "SELECT last_read_id||'|'||bcast_from FROM cursors WHERE agent='newbie'")
[ "$got" != "0|$b1" ] && [ "${got%%|*}" -gt "$d1" ] || fail "a rejoin reset the cursor to $got"
[ "$got" = "$(one "SELECT last_read_id||'|'||bcast_from FROM cursors WHERE agent='newbie'")" ] && [ "$(agentbus --json --as newbie inbox --peek | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["items"]))')" = 0 ] \
  || fail "a rejoin delivered read messages again"
ok "direct mail from before the first join, broadcasts from after, a rejoin keeps the cursor"

echo "TEST P-ID-8: join with --request-id returns duplicate true without writing when the flags match, and request_id_reused when they differ"
# Bug it catches (mutation): a repeat that writes again, flags not compared, any token taken as the same, duplicate not flagged, the goal frozen.
agentbus --as tk join --tool t --branch b --request-id J1 >/dev/null
jn=$(logs join)
sql "UPDATE agents SET last_seen=? WHERE name='tk'" "$(stamp 5)"
seen=$(one "SELECT last_seen FROM agents WHERE name='tk'")
agentbus --as poster goal "the goal after the first join" >/dev/null
r=$(json_ok agentbus --json --as tk join --tool t --branch b --request-id J1 --cwd /elsewhere --takeover)
[ "$(field "$r" duplicate)" = True ] || fail "a repeat of a join with the same token was not flagged duplicate: $r"
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["goal"]["goal"])' "$r")" = "the goal after the first join" ] || fail "a repeated join did not show the current goal: $r"
[ "$(logs join)" = "$jn" ] || fail "a repeated join wrote a log row"
[ "$(one "SELECT last_seen FROM agents WHERE name='tk'")" = "$seen" ] || fail "a repeated join refreshed last_seen"
for flags in "--tool other --branch b" "--tool t --branch other" "--tool t --branch b --model m" "--tool t --branch b --role r"; do
  # shellcheck disable=SC2086
  jfail request_id_reused "${AB[@]}" --json --as tk join $flags --request-id J1
done
jfail name_active "${AB[@]}" --json --as tk join --tool t --branch b --request-id J2
jfail name_active "${AB[@]}" --json --as tk join --tool t --branch b
[ "$(logs join)" = "$jn" ] || fail "a refused join wrote a log row"
ok "duplicate without writing, a changed flag refused, another token is another session"

echo "TEST P-ID-9 and P-ID-10: leave deletes the claims and the roster entry together and logs it; it keeps the cursor, messages and todos; a second leave writes nothing"
# Bug it catches (mutation): claims kept, the roster entry kept, the cursor or messages or todos removed, a second leave logging, a leave that changed only claims unlogged.
lvrows() { one "SELECT COUNT(*) FROM log WHERE action='leave' AND agent='lv'"; }
agentbus --as lv join >/dev/null
agentbus --as lv claim lv/a.py lv/b.py >/dev/null
todo=$(agentbus --json --as lv post "my job" --kind todo | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
agentbus --as lv inbox >/dev/null
msgs=$(count messages)
agentbus --as lv leave >/dev/null
[ "$(one "SELECT COUNT(*) FROM claims WHERE agent='lv'")" = 0 ] || fail "leave kept claims"
[ "$(one "SELECT COUNT(*) FROM agents WHERE name='lv'")" = 0 ] || fail "leave kept the roster entry"
[ "$(lvrows)" = 1 ] || fail "leave wrote $(lvrows) leave rows, want 1"
[ "$(one "SELECT COUNT(*) FROM cursors WHERE agent='lv'")" = 1 ] || fail "leave deleted the cursor"
[ "$(one "SELECT COUNT(*) FROM messages WHERE reply_to=$todo")" = 0 ] || fail "leave closed the name's todo"
[ "$(count messages)" -ge "$msgs" ] || fail "leave deleted messages"
l=$(count log)
agentbus --as lv leave >/dev/null
[ "$(count log)" = "$l" ] || fail "a second leave wrote a log row"
sql "INSERT INTO claims VALUES('lv/only.py','lv',NULL,'2020-01-01T00:00:00Z','2999-01-01T00:00:00Z')"
agentbus --as lv leave >/dev/null
[ "$(lvrows)" = 2 ] || fail "a leave that only released a claim wrote no leave row"
ok "claims and entry gone and logged, cursor, messages and todos kept, a second leave silent"

echo "TEST P-ID-11: who lists every roster entry"
# Bug it catches (mutation): who hiding entries that are idle, have no tool, or are old.
sql "INSERT INTO agents(name,joined_at,last_seen) VALUES('ancient','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')"
agentbus --as notool join >/dev/null
want=$(rows "SELECT name FROM agents ORDER BY name" | tr '\n' ' ')
got=$(agentbus --json who --limit -1 | python3 -c 'import json,sys; print("".join(r["name"]+" " for r in sorted(json.load(sys.stdin)["items"], key=lambda r: r["name"])))')
[ "$got" = "$want" ] || fail "who lists: $got (the roster is: $want)"
ok "every entry listed, idle, old and without a tool"

echo "TEST P-LOG-1: join, leave, claim, auto-release, release, --from and a goal change append a log row; post and ctx set write none"
# Bug it catches (mutation): one of the operations that stops logging, a duplicate join or a repeated goal that logs, a post or ctx set that logs.
agentbus --as lg join --tool tl >/dev/null
[ "$(one "SELECT COUNT(*) FROM log WHERE agent='lg' AND action='join'")" = 1 ] || fail "join wrote no join row"
agentbus --as lg join --tool tl --request-id LG >/dev/null 2>&1 || true
before=$(count log)
agentbus --as lg post "a post" >/dev/null
agentbus --as lg ctx set logkey "a fact" >/dev/null
[ "$(count log)" = "$before" ] || fail "a post or a ctx set wrote a log row"
g=$(logs goal)
agentbus --as lg goal "log goal" >/dev/null
[ "$(logs goal)" = $((g + 1)) ] || fail "a goal change wrote no goal row"
g=$(logs goal)
agentbus --as lg goal "log goal" >/dev/null
[ "$(logs goal)" = "$g" ] || fail "an unchanged goal wrote a goal row"
agentbus --as lg claim lg/a.py lg/b.py lg/c.py >/dev/null
[ "$(one "SELECT COUNT(*) FROM log WHERE agent='lg' AND action='claim'")" = 3 ] || fail "three new claims did not write three claim rows"
r0=$(logs release)
agentbus --as lg release lg/a.py >/dev/null
[ "$(logs release)" = $((r0 + 1)) ] || fail "a release wrote no release row"
[ "$(one "SELECT detail FROM log WHERE action='release' ORDER BY id DESC LIMIT 1")" = "lg/a.py" ] || fail "the release row does not name the resource: $(one "SELECT detail FROM log WHERE action='release' ORDER BY id DESC LIMIT 1")"
agentbus --as lg release --all >/dev/null
[ "$(logs release)" = $((r0 + 2)) ] || fail "release --all wrote $(( $(logs release) - r0 - 1 )) rows, want 1"
d=$(one "SELECT detail FROM log WHERE action='release' ORDER BY id DESC LIMIT 1")
case "$d" in *lg/b.py*lg/c.py*) ;; *) fail "the release --all row does not name every resource: $d" ;; esac
agentbus --as lg claim lg/x.py >/dev/null
agentbus --as lg2 join >/dev/null
agentbus --as lg2 claim lg/x.py --from lg >/dev/null
[ "$(logs claim_taken)" = 1 ] || fail "a --from move wrote no claim_taken row"
agentbus --as lg2 leave >/dev/null
[ "$(one "SELECT COUNT(*) FROM log WHERE action='leave' AND agent='lg2'")" = 1 ] || fail "leave wrote no row"
ok "each operation logs, post and ctx set do not, repeats do not"

echo "TEST P-LOG-2: log add appends one row with the caller's name, the action word and the detail, every time"
# Bug it catches (mutation): the action or detail changed, another name as the caller, or a repeat of the same row dropped.
l=$(count log)
agentbus --as lg log add myaction "the detail text" >/dev/null
agentbus --as lg log add myaction "the detail text" >/dev/null
[ "$(count log)" = $((l + 2)) ] || fail "two log adds wrote $(( $(count log) - l )) rows"
[ "$(one "SELECT agent||'|'||action||'|'||detail FROM log WHERE action='myaction' ORDER BY id DESC LIMIT 1")" = "lg|myaction|the detail text" ] \
  || fail "the log row is $(one "SELECT agent||'|'||action||'|'||detail FROM log WHERE action='myaction' ORDER BY id DESC LIMIT 1")"
ok "two adds, two rows, as given"

echo "All roster rule tests passed"
