#!/bin/bash
set -euo pipefail

# scripts/wave_review.py on a fixture bus built with the real CLI, and on a JSON export.

. "$(dirname "$0")/lib.sh"
TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export AGENTBUS_DB="$TMP/bus.db"
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/wave_review.py"
cd "$TMP"
CLI="$PY $BIN"
review() { "$PY" -I "$S" --cli "$CLI" "$@"; }
want() { grep -qF -- "$2" <<<"$1" || { echo "FAIL: missing '$2' in:"; echo "$1"; exit 1; }; ok "$2"; }

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

out=$(review --append "$TMP/waves.txt")
want "$out" "messages 9 since #0"
want "$out" "lane to lane 3, to brain 1, from brain 1, to everyone 4"
want "$out" "decisions: 1"
want "$out" "questions: 2, answered with reply_to 1, unanswered 1 (answers without reply_to: 1)"
want "$out" "coordinator unread: 5"
want "$out" "  join-name 3"
want "$out" "  unkeyed 1"
want "$out" "rule: every key at 3 or more gets an issue -> join-name"
[ "$(wc -l <"$TMP/waves.txt")" -eq 1 ] || { echo "FAIL: --append should add one line"; exit 1; }
ok "append one line"

out=$(review --since 5)
want "$out" "messages 4 since #5"
! grep -q "join-name" <<<"$out" || { echo "FAIL: key counted before --since"; exit 1; }
ok "since cuts older friction"

out=$(review --coordinator nobody)
want "$out" "coordinator unread: n/a"

agentbus --json read --limit -1 >"$TMP/export.json"
out=$(review --json "$TMP/export.json")
want "$out" "messages 9 since #0"
want "$out" "claim refusals logged: n/a"
want "$out" "coordinator unread: n/a"
echo "ALL PASS"
