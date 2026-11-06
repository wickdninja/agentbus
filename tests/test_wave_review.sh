#!/bin/bash
set -euo pipefail

# scripts/wave_review.py on a fixture bus built with the real CLI, and on a JSON export.
# Bugs it catches: the review moved the coordinator's last-seen (it ran a command as it), a question that replied to a
# question counted as answered, a coordinator past the first 50 agents (or past watch's 200) was missed, refused claims
# went uncounted, and `log show` normalised a planted claim and logged it (an ordinary open writes).

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
# state: every table that a write could touch, the schema and its version
state() { "$PY" -I -c '
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for t in ("claims", "log", "cursors", "agents", "messages", "context"):
    print(t, c.execute("SELECT * FROM %s ORDER BY rowid" % t).fetchall())
print(c.execute("SELECT type, name, sql FROM sqlite_master ORDER BY name").fetchall(), c.execute("PRAGMA user_version").fetchone())' "$AGENTBUS_DB"; }

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
# 210 agents that joined before late-brain and were seen after it: it is past who's first page of 50 (newest seen
# first) and past watch's 200 (first joined first)
"$PY" -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executemany("INSERT INTO agents(name,tool,joined_at,last_seen) VALUES(?,?,?,?)", (("z%d" % i, "t", "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z") for i in range(210))); c.commit()' "$AGENTBUS_DB"
agentbus --as late-brain join >/dev/null
agentbus --as a post "for late" --to late-brain >/dev/null

# A claim stored as an older tool or a lane could write it: an ordinary open rewrites it and logs that.
"$PY" -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO claims(resource,agent,purpose,claimed_at,expires_at) VALUES(?,?,?,?,?)", ("./odd//path.txt","a","p","2026-01-01T00:00:00Z","2099-01-01T00:00:00Z")); c.commit()' "$AGENTBUS_DB"
before=$(agents); before_all=$(state)
out=$(AGENTBUS_AGENT=claude-brain review --coordinator claude-brain,late-brain,nobody --append "$TMP/waves.txt")
[ "$(agents)" = "$before" ] || { echo "FAIL: the review changed the agents table"; exit 1; }
[ "$(state)" = "$before_all" ] || { echo "FAIL: the review changed the bus (claims, log, cursors or schema)"; diff <(echo "$before_all") <(state) | head -5; exit 1; }
ok "read-only: agents, claims, log, cursors and schema are unchanged"
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
echo "All wave_review tests passed"
