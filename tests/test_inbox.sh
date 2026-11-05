#!/bin/bash
set -euo pipefail
# inbox marks read only what it really wrote. Bug it catches: the cursor moved inside the read
# transaction, before the output was written. Only a detected write failure prevents marking;
# successful pipe writes do not prove downstream consumption. Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
export AGENTBUS_DB="$T/bus.db"
agentbus --as a join --tool t >/dev/null
# Each test reads the inbox of its own name, so any one of them can run alone.
for n in b c d e f g; do agentbus --as $n join --tool t >/dev/null; done
unread() { njson agentbus --json --as "${1:-b}" inbox --peek --limit -1; }
# big NAME N: N long messages to NAME (plant_big_messages, tests/lib.sh), so the output is well past a pipe buffer.
big() { plant_big_messages "$AGENTBUS_DB" "$1" "$2"; }

echo "TEST 1: inbox with stdout closed fails and marks nothing read"
for i in 1 2 3; do agentbus --as a post "short $i" --to b >/dev/null; done
expect_fail "stdout is closed" bash -c '"$@" --as b inbox >&-' _ "${AB[@]}"
[ "$(unread)" = 3 ] || fail "inbox >&- marked messages read: $(unread) unread"
expect_fail "stdout is closed" bash -c '"$@" --json --as b inbox >&-' _ "${AB[@]}"
[ "$(unread)" = 3 ] || fail "inbox --json >&- marked messages read"
outof agentbus --as b inbox >/dev/null
[ "$(unread)" = 0 ] || fail "a written inbox did not mark read"
ok "inbox >&- marks nothing read"

echo "TEST 2: inbox | head -1 beyond the pipe buffer fails and marks nothing read"
# A listing cuts each body at 2 KB, so it takes 600 messages (1.2 MB) to pass the pipe buffer plus the first block a reader
# can take before it leaves (a 126 KB output fitted in them on CI, where head reads 64 KB at once).
big c 600
rc=0; agentbus --as c inbox --limit -1 2>"$T/e2" | head -1 >/dev/null || rc=$?
[ "$(unread c)" = 600 ] || fail "inbox | head -1 marked $((600 - $(unread c))) unshown messages read"
grep -q "reader closed stdout" "$T/e2" || fail "no error for the cut-off reader: $(cat "$T/e2")"
! grep -q Traceback "$T/e2" || fail "traceback: $(cat "$T/e2")"
ok "inbox | head -1: all 600 still unread"

echo "TEST 3: a reader killed mid-output: nothing marked read"
big d 600
rc=0; ( agentbus --as d inbox --limit -1 2>"$T/e3" | python3 -c 'import os, sys; sys.stdin.buffer.read(1000); os.kill(os.getpid(), 9)' ) 2>/dev/null || rc=$?
[ "$(unread d)" = 600 ] || fail "a reader killed mid-output: $((600 - $(unread d))) messages marked read"
grep -q "reader closed stdout" "$T/e3" || fail "no error for the killed reader: $(cat "$T/e3")"
outof agentbus --as d inbox --limit -1 >/dev/null
[ "$(unread d)" = 0 ] || fail "the full inbox did not mark everything read"
ok "a killed reader leaves every message unread"

echo "TEST 4: two overlapping inboxes under one name never move the cursor back"
# A shows the oldest 2 and is held before it marks them read; B shows 5 and marks them; then A
# marks its 2. The cursor must stay at the 5th (MAX), or messages 3-5 would be delivered again.
for i in $(seq 1 8); do agentbus --as a post "c$i" --to e >/dev/null; done
P="$T/p4"; mkdir -p "$P"
AGENTBUS_TEST_PAUSE="before-mark-read=$P" agentbus --as e inbox --limit 2 >"$T/oa" 2>"$T/ea" & PA=$!
wait_for "$P/before-mark-read.reached"
outof agentbus --as e inbox --limit 5 >"$T/ob"
touch "$P/before-mark-read.go"; wait $PA || fail "the held inbox failed: $(cat "$T/ea")"
grep -q '^  c1$' "$T/oa" && grep -q '^  c2$' "$T/oa" || fail "A did not show c1 and c2: $(cat "$T/oa")"
grep -q '^  c5$' "$T/ob" || fail "B did not show c5: $(cat "$T/ob")"
o=$(json_ok agentbus --json --as e inbox --peek)
[ "$(python3 -c 'import json,sys; print(" ".join(r["body"] for r in json.loads(sys.argv[1])["items"]))' "$o")" = "c6 c7 c8" ] \
  || fail "after two overlapping inboxes the unread are not c6-c8: $o"
ok "overlapping inboxes: cursor at the furthest shown (at least once, never backwards)"

echo "TEST 5: inbox --limit 0 says how many wait, not 'inbox empty'"
for i in 1 2 3; do agentbus --as a post "f$i" --to f >/dev/null; done
o=$(outof agentbus --as f inbox --limit 0)
[ "$o" = $'  ... 3 more unread\n  next: agentbus --as f inbox --limit 20' ] || fail "inbox --limit 0 printed: $o"
[ "$(unread f)" = 3 ] || fail "inbox --limit 0 marked messages read"
outof agentbus --as f inbox >/dev/null
[ "$(outof agentbus --as f inbox)" = "inbox empty" ] || fail "an empty inbox did not say so"
ok "--limit 0 shows only the count"

echo "TEST 6: inbox leaves out your own messages, to you or to everyone"
agentbus --as g post "g to all" >/dev/null
agentbus --as g post "g to self" --to g >/dev/null
agentbus --as a post "a to g" --to g >/dev/null
o=$(json_ok agentbus --json --as g inbox --peek)
[ "$(python3 -c 'import json,sys; print("|".join(r["body"] for r in json.loads(sys.argv[1])["items"]))' "$o")" = "a to g" ] \
  || fail "inbox showed g its own messages: $o"
ok "own messages left out"
echo "TEST 7: --peek consumes none; --limit 1 consumes exactly the first message"
for i in 1 2 3; do agentbus --as a post "bounded $i" --to bounded >/dev/null; done
"$PY" - <<'PY'
import json, subprocess, sys, tempfile
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
def inbox(*args):
    with tempfile.TemporaryDirectory() as cwd:
        p = subprocess.run([*agentbus_argv(), '--as', 'bounded', 'inbox', '--json', *args], cwd=cwd, capture_output=True, text=True, check=True)
    return [r['body'] for r in json.loads(p.stdout)['items']]
assert inbox('--peek') == ['bounded 1', 'bounded 2', 'bounded 3']
assert inbox('--peek', '--limit', '1') == ['bounded 1']
assert inbox('--peek') == ['bounded 1', 'bounded 2', 'bounded 3']
assert inbox('--limit', '1') == ['bounded 1']
assert inbox('--peek') == ['bounded 2', 'bounded 3']
assert inbox() == ['bounded 2', 'bounded 3']
assert inbox('--peek') == []
PY
ok "peek preserves all unread messages and limit 1 consumes exactly one"
echo "All inbox tests passed"
