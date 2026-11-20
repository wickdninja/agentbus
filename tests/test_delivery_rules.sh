#!/bin/bash
set -euo pipefail
# The delivery requirements of docs/protocol.md (P-DLV-1 to P-DLV-9, P-VER-3), one section each, every check printing its own
# FAIL line. tests/test_inbox.sh, tests/test_failure_phases.sh and tests/test_pagination.sh pin the wording and the paths around
# them; this file pins the rules, so a mutation of one rule (tests/mutations.json, field "must") fails here for that rule's
# reason. Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/rules.db"
cd "$T"

# sql STATEMENT [ARG...]: one write straight into the bus, as a tool that planted rows would.
sql() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2], sys.argv[3:]); c.commit()' "$AGENTBUS_DB" "$@"; }
rows() { python3 -c 'import sqlite3,sys; [print(r[0]) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2], sys.argv[3:])]' "$AGENTBUS_DB" "$@"; }
one() { rows "$@" | head -1; }
# post FROM ARGS...: post as FROM, print the new id.
post() { local from=$1; shift; json_ok agentbus --json --as "$from" post "$@" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
# ids JSON: the ids of a listing, on one line.
ids() { python3 -c 'import json,sys; print(" ".join(str(r["id"]) for r in json.loads(sys.argv[1])["items"]))' "$1"; }
# peeked NAME [ARGS...]: the ids NAME's inbox would show, without reading them.
peeked() { local n=$1; shift; ids "$(json_ok agentbus --json --as "$n" inbox --peek "$@")"; }
# cursor NAME: last_read_id|bcast_from, or none.
cursor() { local c; c=$(rows "SELECT last_read_id||'|'||bcast_from FROM cursors WHERE agent=?" "$1"); echo "${c:-none}"; }
for n in da db dc; do agentbus --as $n join --tool t >/dev/null; done

echo "TEST P-DLV-1: inbox returns, oldest first, the messages after last_read_id, not from the reader, addressed to it or broadcast after bcast_from"
# Bug it catches (mutation): broadcasts from before the join delivered, newest first, others' direct mail shown, a no-cursor name reading old broadcasts.
m1=$(post da "direct early" --to late)
m2=$(post da "broadcast early")
agentbus --as late join >/dev/null
m3=$(post da "broadcast after")
m4=$(post da "direct after" --to late)
m5=$(post da "to someone else" --to db)
m6=$(post late "from late itself")
m7=$(post late "late to db" --to db)
[ "$(peeked late)" = "$m1 $m3 $m4" ] || fail "late's inbox is $(peeked late), want $m1 $m3 $m4 (direct mail since the start, broadcasts since the join, oldest first, nothing from itself)"
[ "$(peeked db)" = "$m2 $m3 $m5 $m6 $m7" ] || fail "db's inbox is $(peeked db)"
agentbus --as late inbox >/dev/null
post da "after the first inbox" --to late >/dev/null
[ "$(peeked late | wc -w | tr -d ' ')" = 1 ] || fail "an inbox after the first delivered something already read: $(peeked late)"
# a name with no cursor reads as last_read_id 0 and bcast_from the highest id
b9=$(post da "broadcast before the stranger looks")
d9=$(post da "direct to a stranger" --to stranger)
[ "$(peeked stranger)" = "$d9" ] || fail "a name with no cursor saw: $(peeked stranger) (want only its direct mail $d9, not the broadcast $b9)"
ok "the unread view"

echo "TEST P-DLV-2: a consuming inbox acknowledges after its output was written, up to the last message shown"
# Bug it catches (mutation): the cursor moved before the output, left unmoved after it, or moved past what was shown.
fresh_target=$(post da "one for ack" --to ackr)
two=$(post da "two for ack" --to ackr)
rc=0; AGENTBUS_TEST_FAIL=emit "${AB[@]}" --json --as ackr inbox >/dev/null 2>"$T/e1" || rc=$?
[ "$rc" != 0 ] || fail "the injected output failure did not fail the inbox"
[ "$(peeked ackr)" = "$fresh_target $two" ] || fail "an inbox whose output failed marked messages read: $(peeked ackr)"
agentbus --as ackr inbox >/dev/null
[ "$(one "SELECT last_read_id FROM cursors WHERE agent='ackr'")" = "$two" ] || fail "the cursor is at $(one "SELECT last_read_id FROM cursors WHERE agent='ackr'") after an inbox that showed up to $two"
ok "acknowledged after the output, up to the last message shown"

echo "TEST P-DLV-3: two overlapping inbox calls under one name end with the cursor at the higher id"
# Bug it catches (mutation): the later acknowledgement winning, so a message already shown is delivered again.
for i in 1 2 3 4; do post da "ov$i" --to ovr >/dev/null; done
P="$T/pause"; mkdir -p "$P"
AGENTBUS_TEST_PAUSE="before-mark-read=$P" "${AB[@]}" --as ovr inbox --limit 1 >"$T/oa" 2>"$T/ea" & PA=$!
wait_for "$P/before-mark-read.reached"
agentbus --as ovr inbox --limit 3 >/dev/null
last=$(one "SELECT last_read_id FROM cursors WHERE agent='ovr'")
touch "$P/before-mark-read.go"; wait_exit "$PA" 20 "the held inbox"; [ "$WAIT_RC" = 0 ] || fail "the held inbox failed: $(cat "$T/ea")"
[ "$(one "SELECT last_read_id FROM cursors WHERE agent='ovr'")" = "$last" ] || fail "the cursor went from $last to $(one "SELECT last_read_id FROM cursors WHERE agent='ovr'") when the smaller inbox acknowledged late"
ok "the cursor stays at the higher id"

echo "TEST P-DLV-4: inbox --limit N acknowledges only the messages it showed"
# Bug it catches (mutation): the cursor moved past the page, so the rest are lost.
for i in 1 2 3 4 5; do post da "lim$i" --to limr >/dev/null; done
first3=$(peeked limr | cut -d' ' -f1-3)
got=$(ids "$(json_ok agentbus --json --as limr inbox --limit 3)")
[ "$got" = "$first3" ] || fail "inbox --limit 3 showed $got, want $first3"
[ "$(peeked limr | wc -w | tr -d ' ')" = 2 ] || fail "after inbox --limit 3 the unread are $(peeked limr), want the 2 not shown"
ok "the rest stay unread"

echo "TEST P-DLV-5: inbox --peek does not move or create a cursor"
# Bug it catches (mutation): a peek that acknowledges, or creates the cursor of a name without one.
post da "for the peeker" --to peeker >/dev/null
agentbus --as peeker inbox --peek >/dev/null
[ "$(cursor peeker)" = none ] || fail "a peek by a name with no cursor created one: $(cursor peeker)"
before=$(cursor limr)
agentbus --as limr inbox --peek >/dev/null
[ "$(cursor limr)" = "$before" ] || fail "a peek moved the cursor from $before to $(cursor limr)"
ok "peek leaves cursors alone"

echo "TEST P-DLV-6: a consuming inbox by a name with no cursor creates one, even when nothing is unread"
# Bug it catches (mutation): the cursor created only when something was shown, so a later broadcast from before is delivered.
top=$(one "SELECT MAX(id) FROM messages")
agentbus --as empty inbox >/dev/null
[ "$(cursor empty)" = "0|$top" ] || fail "an empty inbox left the cursor $(cursor empty), want 0|$top"
b=$(post da "broadcast after the empty inbox")
[ "$(peeked empty)" = "$b" ] || fail "the name's later broadcast was not delivered: $(peeked empty)"
ok "cursor created at the first consuming inbox"

echo "TEST P-DLV-7: read lists by id with --since (exclusive), --before, --topic and --id, changes no cursor, and --id of a missing message is no_message"
# Bug it catches (mutation): since inclusive, topic or before ignored, a read that acknowledges, a missing id that succeeds.
a1=$(post da "topic one" --topic tx); a2=$(post da "topic two" --topic ty); a3=$(post da "topic three" --topic tx)
before="$(cursor db)/$(cursor late)"
[ "$(ids "$(json_ok agentbus --json --as db read --since "$a1")")" = "$a2 $a3" ] || fail "read --since $a1 listed: $(ids "$(json_ok agentbus --json --as db read --since "$a1")") (exclusive: $a2 $a3)"
[ "$(ids "$(json_ok agentbus --json --as db read --topic tx --limit -1)" | tr ' ' '\n' | tail -2 | tr '\n' ' ')" = "$a1 $a3 " ] || fail "read --topic tx did not list exactly the tx messages"
[ "$(ids "$(json_ok agentbus --json --as db read --topic tx --limit -1)" | wc -w | tr -d ' ')" = 2 ] || fail "read --topic tx listed other topics: $(ids "$(json_ok agentbus --json --as db read --topic tx --limit -1)")"
page=$(json_ok agentbus --json --as db read --limit 2)
nxt=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["next"])' "$page")
older=$(ids "$(json_ok agentbus --json --as db read --limit 2 --before "$nxt")")
[ "$(ids "$page")" = "$a2 $a3" ] || fail "read --limit 2 showed $(ids "$page"), want the newest two $a2 $a3"
[ "$(echo "$older" | wc -w | tr -d ' ')" = 2 ] && [ "${older##* }" -lt "$a2" ] || fail "read --before listed $older (ids older than $a2, two of them)"
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["body"])' "$(json_ok agentbus --json --as db read --id "$a2")")" = "topic two" ] || fail "read --id did not return the message"
n=$(one "SELECT MAX(id) FROM messages")
rc=0; "${AB[@]}" --json --as db read --id $((n + 50)) >/dev/null 2>"$T/e7" || rc=$?
[ "$rc" != 0 ] && grep -q '"no_message"' "$T/e7" || fail "read --id of a missing message did not refuse with no_message: $(cat "$T/e7")"
[ "$before" = "$(cursor db)/$(cursor late)" ] || fail "read moved a cursor"
ok "filters and no cursor effect"

echo "TEST P-DLV-8: message ids increase strictly in commit order, and a second writer waits for the first to commit"
# Bug it catches (mutation): an id out of order, or a second writer that does not wait for the first to commit.
fresh=$(post da "s1"); s2=$(post db "s2"); s3=$(post da "s3")
[ "$fresh" -lt "$s2" ] && [ "$s2" -lt "$s3" ] || fail "ids did not increase: $fresh $s2 $s3"
[ "$(rows "SELECT id FROM messages ORDER BY id" | tr '\n' ' ')" = "$(rows "SELECT id FROM messages ORDER BY rowid" | tr '\n' ' ')" ] || fail "ids are not in insertion order"
P8="$T/pause8"; mkdir -p "$P8"
AGENTBUS_TEST_PAUSE="commit=$P8" "${AB[@]}" --json --as da post "held first" >"$T/o1" 2>"$T/e1" & P1=$!
wait_for "$P8/commit.reached"
"${AB[@]}" --json --as db post "waits behind" >"$T/o2" 2>"$T/e2" & P2=$!
sleep 1
touch "$P8/commit.go"
wait_exit "$P1" 20 "the held post"; [ "$WAIT_RC" = 0 ] || fail "the held post failed: $(cat "$T/e1")"
wait_exit "$P2" 20 "the waiting post"; [ "$WAIT_RC" = 0 ] || fail "a post made while another held the write lock failed: $(cat "$T/e2")"
i1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$T/o1"); i2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$T/o2")
[ "$i1" -lt "$i2" ] || fail "the post that held the lock first got id $i1, the one that waited got $i2"
ok "strictly increasing, one writer at a time"

echo "TEST P-DLV-9: delivery is at least once: a failure between the two steps delivers the same messages again"
# Bug it catches (mutation): the cursor moved before the output, so a failed acknowledgement or output loses the messages.
x1=$(post da "again one" --to twice); x2=$(post da "again two" --to twice)
rc=0; AGENTBUS_TEST_FAIL=ack "${AB[@]}" --json --as twice inbox >"$T/o9" 2>"$T/e9" || rc=$?
[ "$rc" != 0 ] && grep -q '"ack_failed"' "$T/e9" || fail "an acknowledgement failure was not reported as ack_failed: $(cat "$T/e9")"
[ "$(ids "$(cat "$T/o9")")" = "$x1 $x2" ] || fail "the messages were not delivered before the failed acknowledgement: $(cat "$T/o9")"
[ "$(ids "$(json_ok agentbus --json --as twice inbox)")" = "$x1 $x2" ] || fail "the messages were not delivered again after the failed acknowledgement"
[ "$(peeked twice)" = "" ] || fail "the second delivery was not acknowledged"
ok "delivered, ack failed, delivered again"

echo "TEST P-VER-3: a stored message of a kind the consumer does not know is delivered and acknowledged unchanged through inbox and read"
# Bug it catches (mutation): an unknown kind hidden from inbox or read, shown as another kind, or left unacknowledged.
agentbus --as da post "before the unknown kind" --to vk >/dev/null
sql "INSERT INTO messages(ts,sender,recipient,kind,topic,body) VALUES('2030-01-01T00:00:00Z','newer','vk','poke','tp','from a later version')"
pk=$(one "SELECT MAX(id) FROM messages")
o=$(json_ok agentbus --json --as vk inbox)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); r=[x for x in d["items"] if x["id"]==int(sys.argv[2])]; assert r and r[0]["kind"]=="poke" and r[0]["body"]=="from a later version" and r[0]["topic"]=="tp", d' "$o" "$pk" \
  || fail "inbox did not deliver the unknown kind unchanged: $o"
[ "$(peeked vk)" = "" ] || fail "the unknown kind was left unacknowledged: $(peeked vk)"
agentbus --as vk read --since $((pk - 1)) | grep -qF "[poke]" || fail "read did not show the unknown kind as it is stored"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert [x["kind"] for x in d["items"] if x["id"]==int(sys.argv[2])]==["poke"], d' "$(json_ok agentbus --json --as vk read --since $((pk - 1)))" "$pk" || fail "read --json did not return the unknown kind"
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["kind"])' "$(json_ok agentbus --json --as vk read --id "$pk")")" = poke ] || fail "read --id did not return the unknown kind"
ok "delivered, read and acknowledged as stored"

echo "All delivery rule tests passed"
