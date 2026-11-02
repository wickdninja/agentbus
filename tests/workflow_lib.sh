# Helpers for the end-to-end workflow tests (tests/test_workflow_*.sh). Source after lib.sh.
# A workflow test replays a whole multi-agent session through "${AB[@]}" (so AGENTBUS_CMD runs it
# against an installed command) and fails when any step's exit status, stdout or stderr differs from
# the documented text. State is asserted by reading the bus with sql(), not only from command output.
# This file is not a test: run_all.sh runs tests/test_*.sh only.

# wf_setup: a throwaway HOME and git repo with a bus (agentbus init). Sets T, R (the repo) and DB.
wf_setup() {
  T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
  unset CODEX_HOME CLAUDE_CONFIG_DIR   # setup writes there: only the temp HOME, never the caller's config
  trap 'rm -rf "$T"' EXIT
  R="$T/repo"; mkrepo "$R"
  RREAL=$(cd "$R" && pwd -P)
  "${AB[@]}" init "$R" >/dev/null 2>"$T/init.err" || { cat "$T/init.err" >&2; fail "agentbus init failed"; }
  DB="$R/.agentbus/bus.db"
  cd "$R"
}

# norm: stdin to stdout with what changes between runs replaced: the repo paths, UTC timestamps and
# the local time a message header shows ("01:27", "Nov 1 23:40"), time left on a claim, how long ago an agent was seen,
# and the copy version a buses row ends with.
norm() {
  WF_R="$R" WF_RREAL="${RREAL:-$R}" WF_T="$T" python3 -c '
import os, re, sys
s = sys.stdin.read()
for k, v in (("WF_RREAL", "<REPO>"), ("WF_R", "<REPO>")):
    s = s.replace(os.environ[k], v)
s = re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", "<TS>", s)
s = re.sub(r"· (?:[A-Z][a-z]{2} \d{1,2} )?\d\d:\d\d", "· <time>", s)
s = re.sub(r"\b(?:\d+h \d\dm|\d+m) left\b", "<left>", s)
s = re.sub(r"seen (?:just now|\d+[smhd] ago)", "seen <ago>", s)
s = re.sub(r"active (?:less than a minute|\d+ min) ago", "active <ago> ago", s)
s = re.sub(r"(?m)  copy \S+(?: \+dirty)?$", "  copy <copy>", s)  # a buses row: the version or commit of the folder copy
sys.stdout.write(s)'
}

# say WANT cmd...: cmd exits 0, writes nothing to stderr, and its normalized stdout is exactly WANT
# (WANT has no trailing newline).
say() {
  local want="$1"; shift
  local rc=0; "$@" >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" = 0 ] || { cat "$T/err" >&2; fail "exit $rc, wanted 0: $*"; }
  [ ! -s "$T/err" ] || { echo "stderr was:" >&2; cat "$T/err" >&2; fail "unexpected stderr from: $*"; }
  local got; got=$(norm <"$T/out")
  [ "$got" = "$want" ] || { printf 'wanted:\n%s\ngot:\n%s\n' "$want" "$got" >&2; fail "stdout differs from: $*"; }
}

# refuse RC WANT cmd...: cmd exits RC, writes nothing to stdout, and its normalized stderr is exactly WANT.
refuse() {
  local rc_want="$1" want="$2"; shift 2
  local rc=0; "$@" >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" = "$rc_want" ] || { cat "$T/err" >&2; fail "exit $rc, wanted $rc_want: $*"; }
  [ ! -s "$T/out" ] || { echo "stdout was:" >&2; cat "$T/out" >&2; fail "unexpected stdout from: $*"; }
  local got; got=$(norm <"$T/err")
  [ "$got" = "$want" ] || { printf 'wanted:\n%s\ngot:\n%s\n' "$want" "$got" >&2; fail "stderr differs from: $*"; }
}

# sql [-d DB] QUERY: the rows QUERY returns from the bus, columns joined by "|", one row per line
# (NULL prints as "~"). Reads the file directly, so it checks what is stored, not what a command says. It only
# SELECTs; it opens the file normally because a read-only open of a WAL bus without its -shm file fails on some builds.
sql() {
  local db="$DB"; if [ "$1" = -d ]; then db="$2"; shift 2; fi
  python3 -c '
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=30)   # not mode=ro: a WAL bus with no -shm file cannot be opened read-only
for row in c.execute(sys.argv[2]):
    print("|".join("~" if v is None else str(v) for v in row))' "$db" "$1"
}

# sql_write [-d DB] STATEMENT: change the bus behind the CLI's back, to age a claim or clear a roster
# row the way a crash or a long gap would.
sql_write() {
  local db="$DB"; if [ "$1" = -d ]; then db="$2"; shift 2; fi
  python3 -c '
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2]); c.commit()' "$db" "$1"
}

# legacy_copy DEST: the v0.1.0 script, copied from tests/fixtures/legacy/agentbus-0.1.0 (ws01 commits it).
# Returns 1 when the fixture is not in this tree.
legacy_copy() {
  local fixture="$TESTS_DIR/fixtures/legacy/agentbus-0.1.0"
  [ -f "$fixture" ] || return 1
  cp "$fixture" "$1"
}

# jcall KEY AGENTBUS-ARGS...: run `agentbus --json ARGS` as a step of the story, require exit 0 and an empty stderr, keep the
# reply as $T/replies/N (KEY, the schema command name, is listed in $T/replies/index) and print it. Steps that run this
# way have their replies checked against `schema --json` at the end of the story.
jcall() {
  local key=$1; shift
  mkdir -p "$T/replies"
  local n; n=$(($(wc -l <"$T/replies/index" 2>/dev/null || echo 0) + 1))
  local rc=0; "${AB[@]}" --json "$@" >"$T/replies/$n" 2>"$T/err" || rc=$?
  [ "$rc" = 0 ] || { cat "$T/err" >&2; fail "exit $rc, wanted 0: --json $*"; }
  [ ! -s "$T/err" ] || { cat "$T/err" >&2; fail "unexpected stderr from: --json $*"; }
  printf '%s|%s\n' "$key" "$T/replies/$n" >>"$T/replies/index"
  cat "$T/replies/$n"
}
# jis NAME EXPR: the JSON on stdin, as `r`, must satisfy the python expression EXPR. Listings are the envelope
# `{"v":1,"items":[...],"has_more":...,"next":...}`, so list expressions read r["items"].
jis() {
  python3 -c '
import json, sys
r = json.load(sys.stdin)
assert eval(sys.argv[1]), r' "$2" || fail "$1"
}

# is_equal NAME WANT GOT: both strings must match exactly; the failure shows both.
is_equal() {
  [ "$2" = "$3" ] || { printf 'wanted:\n%s\ngot:\n%s\n' "$2" "$3" >&2; fail "$1"; }
}
