#!/bin/bash
set -euo pipefail
# The CLI's own inputs: bytes that are not UTF-8, empty bodies, ids at SQLite's limit, and the
# connection settings every command runs under. Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
trap 'rm -rf "$T"' EXIT
cd "$T"
export AGENTBUS_DB="$T/bus.db"
agentbus --as a join --tool t >/dev/null
count() { python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$AGENTBUS_DB" "$1"; }

echo "TEST: empty context keys refuse before any write; omitted get lists; missing objects give next steps"
"$PY" - "$AGENTBUS_DB" <<'PY'
import json, os, sqlite3, subprocess, sys, tempfile
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
db = sys.argv[1]
def run(*args):
    with tempfile.TemporaryDirectory() as cwd:
        return subprocess.run([*agentbus_argv(), *args], cwd=cwd, capture_output=True, text=True, timeout=30)
def snapshot():
    c = sqlite3.connect(db)
    try:
        return list(c.iterdump())
    finally:
        c.close()
before = snapshot()
for args in [('ctx', 'set', '', 'value'), ('ctx', 'get', ''), ('ctx', 'history', '')]:
    p = run('--as', 'a', *args)
    assert p.returncode == 2 and p.stdout == '', (args, p)  # a usage error: exit 2
    assert p.stderr == 'agentbus: KEY must not be empty. List facts with: agentbus ctx get\n', p.stderr
    assert snapshot() == before, (args, 'changed bus')
    # A missing bus must not be created by an invalid key either.
    with tempfile.TemporaryDirectory() as d:
        os.environ['AGENTBUS_DB'] = os.path.join(d, 'missing.db')
        p = run('--as', 'a', *args)
        assert p.returncode == 2 and not os.listdir(d), (args, p.stderr, os.listdir(d))
    os.environ['AGENTBUS_DB'] = db
assert run('--as', 'a', 'ctx', 'set', 'key', 'value').returncode == 0
p = run('ctx', 'get', '--json')
assert p.returncode == 0, p.stderr
rows = json.loads(p.stdout)['items']
assert len(rows) == 1 and rows[0]['key'] == 'key' and rows[0]['value'] == 'value', rows
for args, message in [
    (('ctx', 'get', 'missing'), 'no fact named missing. List facts with: agentbus ctx get'),
    (('post', 'reply', '--reply-to', '99999'), 'no message #99999 to reply to. See recent ids with: agentbus read'),
    (('release', 'missing'), 'you do not hold missing. See your claims with: agentbus claims'),
]:
    before = snapshot()
    for flags in [[], ['--json']]:
        p = run('--as', 'a', *flags, *args)
        assert p.returncode == 1 and p.stdout == '', (args, p)
        if flags:
            code, field, value, nxt = {'ctx': ('no_context_key', 'key', 'missing', 'agentbus ctx get'), 'post': ('no_message', 'id', 99999, 'agentbus read'), 'release': ('not_held', 'resource', 'missing', 'agentbus claims')}[args[0]]
            assert json.loads(p.stderr) == {'error': {'code': code, 'message': message, 'retryable': False, 'committed': False, 'next': nxt, field: value}}, p.stderr
            assert len(p.stderr.splitlines()) == 1, p.stderr
        else:
            assert p.stderr == 'agentbus: ' + message + '\n', p.stderr
        assert snapshot() == before, (args, 'changed bus')
PY
ok "empty keys write nothing, omitted get lists, and exact missing-object errors explain recovery"

echo "TEST 1: an argument or environment value that is not UTF-8 is refused by name, never a traceback"
# Bug it catches: post $'caf\xff', --as $'\xff', AGENTBUS_AGENT=$'\xff' and the rest crashed with
# UnicodeEncodeError (surrogates not allowed) when SQLite or the terminal met the text.
X=$'\xff'
expect_fail "body is not valid UTF-8" agentbus --as a post "caf$X"
expect_fail "--as is not valid UTF-8" agentbus --as "$X" post hi
expect_fail "AGENTBUS_AGENT is not valid UTF-8" env AGENTBUS_AGENT="$X" "${AB[@]}" post hi
expect_fail "key is not valid UTF-8" agentbus --as a ctx set "k$X" v
expect_fail "value is not valid UTF-8" agentbus --as a ctx set k "v$X"
expect_fail "key is not valid UTF-8" agentbus ctx get "k$X"
expect_fail "resource is not valid UTF-8" agentbus --as a claim "a$X"
expect_fail "resource is not valid UTF-8" agentbus --as a release "a$X"
expect_fail "--topic is not valid UTF-8" agentbus --as a post hi --topic "t$X"
expect_fail "--topic is not valid UTF-8" agentbus read --topic "t$X"
expect_fail "--to is not valid UTF-8" agentbus --as a post hi --to "b$X"
expect_fail "--role is not valid UTF-8" agentbus --as b join --tool t --role "r$X"
expect_fail "--purpose is not valid UTF-8" agentbus --as a claim x --purpose "p$X"
expect_fail "what is not valid UTF-8" agentbus --as a log add "w$X" detail
expect_fail "detail is not valid UTF-8" agentbus --as a log add w "d$X"
expect_fail "AGENTBUS_DB is not valid UTF-8" env AGENTBUS_DB="$T/b$X.db" "${AB[@]}" who
[ "$(count 'select count(*) from messages')" = 0 ] || fail "a refused input still wrote a message"
ok "every argument and environment value that is not UTF-8 refused cleanly"

echo "TEST 2: a stdin body with bytes that are not UTF-8 is stored with U+FFFD"
# Bug it catches: sys.stdin.read() raised UnicodeDecodeError on a \xff byte.
printf 'caf\xff ok' | agentbus --as a post - >/dev/null || fail "stdin body with a \\xff byte refused"
printf 'v\xff' | agentbus --as a ctx set sk - >/dev/null || fail "ctx set from stdin with a \\xff byte"
printf 'd\xff' | agentbus --as a log add w - >/dev/null || fail "log add from stdin with a \\xff byte"
outof agentbus --json read | python3 -c 'import json,sys; assert any(m["body"] == "caf� ok" for m in json.load(sys.stdin)["items"])' || fail "body not stored with U+FFFD"
# ctx get KEY prints the value as a row, indented like every row that starts with bus text.
[ "$(outof agentbus ctx get sk)" = "  v�" ] || fail "ctx value not stored with U+FFFD"
ok "stdin read as bytes, decoded with replacement"

echo "TEST 3: an empty body never reads stdin"
# Bug it catches: post "" (an agent passing an empty variable) read stdin instead, so it hung on a
# terminal or posted whatever stdin held.
for args in 'post ""' 'post' 'ctx set ek ""' 'log add w ""' 'post "   "'; do
  eval "set -- $args"
  echo "from stdin" > "$T/in"
  case "$1" in
    post) usage='post "text", or pipe text to post -.' ;;
    ctx) usage='ctx set KEY needs a value. Use: agentbus --as NAME ctx set KEY "VALUE", or pipe text to ctx set KEY -.' ;;
    log) usage='log add ACTION needs a detail. Use: agentbus --as NAME log add ACTION "DETAIL", or pipe text to log add ACTION -.' ;;
  esac
  case "$1" in post) usage="empty message. Use $usage" ;; esac
  expect_fail "$usage" agentbus --as a "$@" < "$T/in"
done
[ "$(count "select count(*) from messages where body like '%from stdin%'")" = 0 ] || fail "an empty body posted stdin"
[ "$(count "select count(*) from context where key='ek'")" = 0 ] || fail "an empty ctx value read stdin"
[ "$(count "select count(*) from log where detail like '%from stdin%'")" = 0 ] || fail "an empty log detail read stdin"
echo "piped" | agentbus --as a post - >/dev/null || fail "post - no longer reads stdin"
[ "$(count "select count(*) from messages where body='piped'")" = 1 ] || fail "post - did not store stdin"
ok "only - reads stdin; empty bodies fail with usage"

echo "TEST 4: an id at 2**63-1 gives a clear error, not 'database or disk is full'"
# Bug it catches: a lane inserted a message with id 2**63-1; AUTOINCREMENT then failed every post
# with "database or disk is full", which points at the disk.
python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO messages(id,ts,sender,recipient,kind,body) VALUES(?,?,?,?,?,?)",
          (2 ** 63 - 1, "2026-01-01T00:00:00Z", "lane", "*", "note", "at the limit"))
c.commit()
PY
expect_fail "table messages has reached id 9223372036854775807 (2**63-1), the largest SQLite allows" agentbus --as a post "after the limit"
outof agentbus read | grep -q "at the limit" || fail "read broken by an id at the limit"
agentbus --as a ctx set still works >/dev/null || fail "an unrelated write failed"
python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("DELETE FROM messages WHERE id=?", (2 ** 63 - 1,))
c.execute("INSERT INTO log(id,ts,agent,action) VALUES(?,?,?,?)", (2 ** 63 - 1, "t", "lane", "x"))
c.commit()
PY
# messages is still at the limit through sqlite_sequence; both tables are named.
expect_fail "tables messages, log have reached id 9223372036854775807" agentbus --as a post "seq still at the limit"
expect_fail "tables messages, log have reached id 9223372036854775807" agentbus --as c join --tool t
ok "an exhausted id is named, with its table"

echo "TEST 5: every connection runs with trusted_schema OFF"
# Bug it catches: with trusted_schema ON (SQLite's default), a view or trigger a lane added could
# run functions with side effects inside the brain's commands.
got=$("$PY" - "$BIN" "$AGENTBUS_DB" <<'PY'
import sys
sys.dont_write_bytecode = True
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
loader = SourceFileLoader("agentbus_under_test", sys.argv[1])
m = module_from_spec(spec_from_loader("agentbus_under_test", loader))
loader.exec_module(m)
con = m.open_bus(sys.argv[2])
try:
    print(con.execute("PRAGMA trusted_schema").fetchone()[0])
finally:
    con.close()
PY
) || fail "could not open the bus through the module"
[ "$got" = 0 ] || fail "trusted_schema is $got on an opened connection"
ok "trusted_schema reads 0"

echo "TEST 6: post - with stdin closed is a clean error"
# Bug it catches: sys.stdin is None when fd 0 is closed, and read_body raised AttributeError.
D6=$(mktemp -d); AGENTBUS_DB="$D6/b.db" agentbus --as s6 join --tool t >/dev/null
errf=$(mktemp); if AGENTBUS_DB="$D6/b.db" "${AB[@]}" --as s6 post - <&- 2>"$errf"; then fail "post - with closed stdin succeeded"; fi
grep -q Traceback "$errf" && fail "traceback on closed stdin"
grep -qF "stdin is closed" "$errf" || fail "no clean closed-stdin message"
ok "post - with stdin closed fails cleanly"

echo "TEST 7: an exhausted id is named whatever type its sqlite_sequence entry is stored as"
# Bug it catches: id_exhausted only recognised an integer seq, so a lane that stored 2**63-1 in
# sqlite_sequence as TEXT, REAL or BLOB brought back the bare "database or disk is full".
for typ in integer text real blob null; do
  D7=$(mktemp -d); AGENTBUS_DB="$D7/b.db" agentbus --as s7 join --tool t >/dev/null
  AGENTBUS_DB="$D7/b.db" agentbus --as s7 post first >/dev/null
  python3 - "$D7/b.db" "$typ" <<'PY'
import sqlite3, sys
v = {"integer": 2 ** 63 - 1, "text": str(2 ** 63 - 1), "real": 9.3e18, "blob": str(2 ** 63 - 1).encode(), "null": None}[sys.argv[2]]
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE sqlite_sequence SET seq=? WHERE name='messages'", (v,))
c.commit()
assert c.execute("SELECT typeof(seq) FROM sqlite_sequence WHERE name='messages'").fetchone()[0] == sys.argv[2]
PY
  if [ "$typ" = null ]; then
    AGENTBUS_DB="$D7/b.db" agentbus --as s7 post after >/dev/null || fail "a NULL seq broke posting"
  else
    expect_fail "table messages has reached id 9223372036854775807" env AGENTBUS_DB="$D7/b.db" "${AB[@]}" --as s7 post after
    expect_fail "table messages has reached id 9223372036854775807" env AGENTBUS_DB="$D7/b.db" "${AB[@]}" --json --as s7 post after
  fi
  rm -rf "$D7"
done
ok "seq at the limit as INTEGER, TEXT, REAL or BLOB is named; NULL posts"

echo "TEST 8: stdout closed or cut off is a clean error, never a traceback"
# Bug it catches: with fd 1 closed sys.stdout is None, and writing the output after the command
# committed raised AttributeError; a reader that went away (| head) raised BrokenPipeError.
D8=$(mktemp -d); AGENTBUS_DB="$D8/b.db" agentbus --as s8 join --tool t >/dev/null
for j in "" --json; do
  errf=$(mktemp)
  if AGENTBUS_DB="$D8/b.db" "${AB[@]}" $j --as s8 post "posted with stdout closed$j" >&- 2>"$errf"; then fail "post with stdout closed exited 0"; fi
  grep -q Traceback "$errf" && { cat "$errf" >&2; fail "traceback with stdout closed"; }
  grep -qF "stdout is closed" "$errf" || fail "no clean closed-stdout message: $(cat "$errf")"
  rm -f "$errf"
  outof env AGENTBUS_DB="$D8/b.db" "${AB[@]}" read | grep -qF "posted with stdout closed$j" || fail "the post itself did not run"
done
# A listing cuts each body at 2 KB, so it takes 600 long messages (1.2 MB) to pass a pipe and the first block a reader can take.
plant_big_messages "$D8/b.db" "*" 600 s8
errf=$(mktemp)
{ AGENTBUS_DB="$D8/b.db" "${AB[@]}" read 2>"$errf" || true; } | head -c 10 >/dev/null
grep -q Traceback "$errf" && { cat "$errf" >&2; fail "traceback when the reader closed the pipe"; }
grep -qF "the reader closed stdout" "$errf" || fail "no clean broken-pipe message: $(cat "$errf")"
rm -f "$errf"; rm -rf "$D8"
ok "stdout closed or cut off: clean message on stderr, the command's own work done"

echo "TEST 9: --help and --version into a reader that went away exit cleanly"
# Bug it catches: argparse wrote --help / --version into stdout's buffer and Python's flush at exit
# hit the closed pipe: "Exception ignored ... BrokenPipeError" on stderr and exit status 120. With
# python -u (unbuffered) the write itself failed inside argparse: an uncaught BrokenPipeError
# traceback on 3.9, and from 3.11 a silent exit 0 with nothing shown.
"$PY" - <<'PY' || fail "help or version into a closed pipe"
import os, subprocess, sys
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
bad = []
for args in [u + a for u in ([], ["-u"]) for a in (["--help"], ["--version"], ["post", "--help"], ["-h"])]:
    if args[0] == "-u":
        args = args[1:]
        cmd = agentbus_argv()
        env = dict(os.environ, PYTHONUNBUFFERED="1")   # the -u flag, which an installed command cannot take
    else:
        cmd = agentbus_argv()
        env = dict(os.environ, PYTHONUNBUFFERED="")
    r, w = os.pipe()
    os.close(r)                      # the reader is gone before anything is written
    p = subprocess.run(cmd + args, stdout=w, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, timeout=60, env=env)
    os.close(w)
    err = p.stderr.decode("utf-8", "replace")
    if p.returncode != 1 or "Exception ignored" in err or "Traceback" in err or not err.startswith("agentbus: "):
        bad.append((cmd[-1:] + args, p.returncode, err[:200]))
    # With a reader, the same commands still print and exit 0.
    q = subprocess.run(cmd + args, capture_output=True, timeout=60, env=env)
    if q.returncode != 0 or not q.stdout:
        bad.append((args, "with a reader", q.returncode, q.stderr[:200]))
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
ok "--help and --version into a closed pipe, buffered or not (-u): a one-line agentbus error, exit 1, no traceback"
echo "All input tests passed"
