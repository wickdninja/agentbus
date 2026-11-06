#!/bin/bash
set -euo pipefail

# scripts/wave_review.py on a fixture bus built with the real CLI, and on a JSON export.
# Bugs it catches: the review moved the coordinator's last-seen (it ran a command as it), a question that replied to a
# question counted as answered, a coordinator past the first 50 agents was missed, refused claims went uncounted.

. "$(dirname "$0")/lib.sh"
TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export AGENTBUS_DB="$TMP/bus.db"
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/wave_review.py"
cd "$TMP"
CLI=$(printf '%q ' "${AB[@]}")   # the suite's own CLI (AGENTBUS_CMD, AGENTBUS_BIN or the checkout's)
review() { "$PY" -I "$S" --cli "$CLI" "$@"; }
want() { grep -qF -- "$2" <<<"$1" || { echo "FAIL: missing '$2' in:"; echo "$1"; exit 1; }; ok "$2"; }
agents() { "$PY" -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT * FROM agents ORDER BY name").fetchall())' "$AGENTBUS_DB"; }

for n in claude-brain a b; do agentbus --as $n join >/dev/null; done
agentbus --as a post "[join-name] join takes no name" --topic friction >/dev/null
agentbus --as b post "+1 [join-name]" --topic friction >/dev/null
agentbus --as b post "[join-name] again" --topic friction >/dev/null
agentbus --as a post "no key here" --topic friction >/dev/null
agentbus --as a post "q1" --kind question --to b >/dev/null          # id 5, answered
agentbus --as b post "a1" --kind answer --to a --reply-to 5 >/dev/null
agentbus --as a post "q2" --kind question --to claude-brain >/dev/null   # id 7, unanswered
agentbus --as claude-brain post "go" --kind decision >/dev/null
agentbus --as b post "loose answer" --kind answer --to a >/dev/null
agentbus --as b post "q2 back?" --kind question --to a --reply-to 7 >/dev/null   # id 10: a question, not an answer to 7
agentbus --as a claim x.txt >/dev/null
! agentbus --as b claim x.txt >/dev/null 2>&1 || { echo "FAIL: setup: a held claim was granted"; exit 1; }
for i in $(seq 1 55); do agentbus --as "z$i" join >/dev/null; done
agentbus --as late-brain join >/dev/null   # the 59th agent: past who's default page of 50
agentbus --as a post "for late" --to late-brain >/dev/null

before=$(agents)
out=$(AGENTBUS_AGENT=claude-brain review --coordinator claude-brain,late-brain,nobody --append "$TMP/waves.txt")
[ "$(agents)" = "$before" ] || { echo "FAIL: the review changed the agents table"; exit 1; }
ok "read-only: the agents table is unchanged"
want "$out" "messages 11 since #0"
want "$out" "lane to lane 4, to brain 2, from brain 1, to everyone 4"
want "$out" "decisions: 1"
want "$out" "questions: 3, answered with reply_to 1, unanswered 2 (answers without reply_to: 1)"
want "$out" "claim refusals logged: 1"
want "$out" "coordinator unread: claude-brain 5, late-brain 1, nobody n/a"
want "$out" "  join-name 3"
want "$out" "  unkeyed 1"
want "$out" "rule: every key at 3 or more gets an issue -> join-name"
[ "$(wc -l <"$TMP/waves.txt")" -eq 1 ] || { echo "FAIL: --append should add one line"; exit 1; }
grep -qF "unread=claude-brain:5,late-brain:1,nobody:n/a" "$TMP/waves.txt" || { echo "FAIL: the appended line lacks the unread counts: $(cat "$TMP/waves.txt")"; exit 1; }
ok "append one line"

out=$(review --coordinator claude-brain --since 5)
want "$out" "messages 6 since #5"
! grep -q "join-name" <<<"$out" || { echo "FAIL: key counted before --since"; exit 1; }
ok "since cuts older friction"

! review >/dev/null 2>&1 || { echo "FAIL: no --coordinator was accepted"; exit 1; }
ok "--coordinator is required"

agentbus --json read --limit -1 >"$TMP/export.json"
out=$(review --coordinator claude-brain --json "$TMP/export.json")
want "$out" "messages 11 since #0"
want "$out" "claim refusals logged: n/a"
want "$out" "coordinator unread: claude-brain n/a"
echo "ALL PASS"
