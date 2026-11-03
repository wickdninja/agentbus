#!/bin/bash
set -euo pipefail
# agentbus doctor: what is installed, which version each piece is, what is wrong and the command that fixes
# it. It writes no data, executes nothing it finds, and starts no process but git (read-only lookups, like every
# command). Everything runs in a temp HOME and a temp workspace; output lines are asserted with grep -F or compared whole.
. "$(dirname "$0")/lib.sh"
SELF="$TESTS_DIR/$(basename "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR CODEX_HOME AGENTBUS_TEST_SETUP_FAIL AGENTBUS_TEST_SETUP_JSON AGENTBUS_NO_UPDATE_NOTICE
T=$(cd "$T" && pwd -P); export HOME="$T/home"
cd "$T"
# Every fixed FAIL text in this file belongs to one assertion, so a FAIL line (and a mutation's expect in
# tests/mutations.json) points at exactly one place.
dups=$(grep -vE '^ *(doctor_row|row) ' "$SELF" | grep -oE '(^|[^_a-z])fail "[^"$]*"' | sed 's/^[^f]*//' | sort | uniq -d)
[ -z "$dups" ] || fail "FAIL texts used by more than one assertion: $dups"
MOD="${AGENTBUS_BIN:-$BIN}"
export MOD
# The tool under test is this checkout's file stamped 0.2.0 outside any checkout (an installed command carries its own
# version); the v0.1.0 fixture is the old bus copy. TOOLH adds one hash to the skill and AGENTS.md history (below).
mkdir -p "$T/tool"; sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$MOD" > "$T/tool/agentbus"
DOC=("$PY" "$T/tool/agentbus")
export TOOLFILE="$T/tool/agentbus"
# outside any checkout, so the copy it installs records VERSION 0.1.0 and not a commit
mkdir -p "$T/old"; cp "$TESTS_DIR/fixtures/legacy/agentbus-0.1.0" "$T/old/agentbus"
OLD=("$PY" "$T/old/agentbus")
W="$T/ws"

cat > "$T/h.py" <<'PY'
import contextlib, hashlib, importlib.machinery, importlib.util, io, os, sys

def load():
    loader = importlib.machinery.SourceFileLoader("agentbus_mod", os.environ["MOD"])
    spec = importlib.util.spec_from_loader("agentbus_mod", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    m.__version__ = "0.2.0"  # the same stamp as the tool the CLI cases run...
    m.self_path = lambda: os.environ["TOOLFILE"]   # ...and the same file, so the bus copies (made by that tool) compare equal
    return m

def run(m, argv):
    """The CLI in this process: (exit status, stdout, stderr)."""
    out, err, old, rc = io.StringIO(), io.StringIO(), sys.argv, 0
    sys.argv = ["agentbus"] + argv
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            m.contract_main()
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 0
    finally:
        sys.argv = old
    return rc, out.getvalue(), err.getvalue()

def tree(*roots, skip=()):
    """Every path under the roots with its type, mode, size, mtime, link target and content hash (names in skip left out)."""
    h = hashlib.sha256()
    for root in roots:
        for d, dirs, files in os.walk(root):
            dirs.sort()
            for n in sorted(files + dirs):
                if n in skip:
                    continue
                p = os.path.join(d, n)
                st = os.lstat(p)
                # SQLite makes an empty bus.db-wal when it opens a WAL database, and on some builds leaves it: that
                # empty file is the read-only open's own doing (CHANGELOG, "Read-only opens"), so it is not counted.
                # Folders are listed by name, not mtime, for the same reason. Every other file: mode, mtime and bytes.
                if n.endswith("-wal") and st.st_size == 0:
                    continue
                h.update(p.encode()); h.update(oct(st.st_mode).encode())
                if not os.path.isdir(p) or os.path.islink(p):
                    h.update(str(st.st_mtime_ns).encode())
                if os.path.islink(p):
                    h.update(os.readlink(p).encode())
                elif os.path.isfile(p):
                    h.update(open(p, "rb").read())
    return h.hexdigest()

def logical(db):
    """Every row, the schema and user_version, read from a copy of the bus and its -wal (so this reads nothing in the bus folder)."""
    import shutil, sqlite3, tempfile
    tmp = tempfile.mkdtemp()
    for suffix in ("", "-wal"):
        if os.path.exists(db + suffix):
            shutil.copyfile(db + suffix, os.path.join(tmp, "bus.db" + suffix))
    c = sqlite3.connect(os.path.join(tmp, "bus.db"))
    try:
        tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        return (c.execute("PRAGMA user_version").fetchone()[0], c.execute("SELECT type, name, sql FROM sqlite_master ORDER BY type, name").fetchall(),
                {t: c.execute(f'SELECT * FROM "{t}" ORDER BY rowid').fetchall() for t in tables})
    finally:
        c.close(); shutil.rmtree(tmp)
PY
export PYTHONPATH="$T"
snap() { "$PY" -c 'import sys, h; print(h.tree(*sys.argv[1:]))' "$@"; }

# world: a fresh HOME and workspace with one bus (copy 0.2.0, schema 1), the user-scope skill and AGENTS.md block.
world() {
  rm -rf "$HOME" "$W"; mkdir -p "$HOME" "$W/app"
  "${DOC[@]}" init "$W/app" >/dev/null 2>&1
  (cd "$W/app" && "${DOC[@]}" --as a join >/dev/null 2>&1)
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  (cd "$W/app" && "${DOC[@]}" setup claude >/dev/null && "${DOC[@]}" setup codex >/dev/null)
}
# doc [DIR] ARGS...: doctor from DIR (default the bus folder); OUT, ERR, RC.
doc() {
  local dir="$W/app"; if [ -d "${1:-}" ]; then dir="$1"; shift; fi
  RC=0; (cd "$dir" && "${DOC[@]}" "$@" >"$T/out" 2>"$T/err") || RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
# norm: the temp paths in OUT replaced, so a transcript can be written down.
norm() { sed -e "s|$W|<WS>|g" -e "s|$T/tool/agentbus|<TOOL>|g" -e "s|$T|<T>|g" <<<"$OUT"; }
has() { grep -qxF -- "$1" <<<"$OUT" || { echo "output was:" >&2; echo "$OUT" >&2; fail "missing line: $1"; }; }
hasf() { grep -qF -- "$1" <<<"$OUT" || { echo "output was:" >&2; echo "$OUT" >&2; fail "output lacks: $1"; }; }
# row ID STATUS DETAIL-FRAGMENT FIX [SCOPE]: the --json entry for ID (first with that scope) has that status, detail containing the
# fragment and exactly that fix ("" for none). The human line for the same entry is checked by the caller where it matters.
row() {
  "$PY" - "$T/out" "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" <<'PY' || { echo "json was:" >&2; cat "$T/out" >&2; fail "row $1: status $2, detail with '$3', fix '$4' not found"; }
import json, sys
path, id, status, frag, fix, scope, hint = sys.argv[1:]
rows = [c for c in json.load(open(path))["checks"] if c["id"] == id and (not scope or c.get("scope") == scope)]
assert rows, "no entry " + id
c = rows[0]
assert c["status"] == status, c
assert frag in c["detail"], c
assert (c["fix"] or "") == fix, c
assert "hint" in c and (hint in (c["hint"] or "") if hint else True), c
assert not (c["fix"] and c["hint"]), "a fix and a hint on one entry: " + repr(c)   # a command, or prose, never both
PY
}

# hooks_row STATUS DETAIL-FRAGMENT FIX: some hooks entry of the --json output in $T/out (hooks has several rows) has them, in the user scope.
hooks_row() {
  "$PY" - "$T/out" "$1" "$2" "$3" <<'PY' || { echo "json was:" >&2; cat "$T/out" >&2; fail "hooks row: status $1, detail with '$2', fix '$3' not found"; }
import json, sys
path, status, frag, fix = sys.argv[1:]
rows = [c for c in json.load(open(path))["checks"] if c["id"] == "hooks" and c["status"] == status and c.get("scope") == "user" and frag in c["detail"] and (c["fix"] or "") == fix and not c["hint"]]
assert len(rows) == 1, rows
PY
}

echo "TEST 1: doctor writes nothing: HOME and the project are equal, byte for byte, before and after, in every state, run from a bus folder and from a folder with none"
states=(current fresh-bus v010-shape stale-copy edited-skill old-link unmanaged damaged-markers newer-bus no-claude-dir no-codex-dir bare-home)
for state in "${states[@]}"; do
  world
  mkdir -p "$W/none"
  (cd "$W/app" && "${DOC[@]}" setup claude --scope project >/dev/null && "${DOC[@]}" setup codex --scope project >/dev/null)
  case $state in
    fresh-bus) rm -f "$W/app/.agentbus/bus.db"* ;;
    v010-shape) rm -rf "$W/app/.agentbus"; "${OLD[@]}" init "$W/app" >/dev/null 2>&1; (cd "$W/app" && "${OLD[@]}" --as o join >/dev/null 2>&1) ;;
    stale-copy) printf '0.1.0\n' > "$W/app/.agentbus/VERSION" ;;
    edited-skill) printf 'my edit\n' >> "$HOME/.claude/skills/agentbus/SKILL.md" ;;
    old-link) rm -rf "$HOME/.claude/skills/agentbus"; ln -s "$T/gone/skill" "$HOME/.claude/skills/agentbus" ;;
    unmanaged) printf 'mine\n' > "$HOME/.claude/skills/agentbus/SKILL.md" ;;
    damaged-markers) printf '<!-- agentbus:begin -->\nx\n' > "$HOME/.codex/AGENTS.md" ;;
    newer-bus) "$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=7"); c.commit()' "$W/app/.agentbus/bus.db" ;;
    no-claude-dir) rm -rf "$HOME/.claude" ;;
    no-codex-dir) rm -rf "$HOME/.codex" ;;
    bare-home) rm -rf "$HOME"; mkdir -p "$HOME" ;;
  esac
  # a git repository whose exclude file lacks the rule: the commands add it, doctor must not (and .git is in the snapshot)
  mkrepo "$W/app"; : > "$W/app/.git/info/exclude"
  before=$(snap "$HOME" "$W")
  for dir in "$W/app" "$W/none"; do
    for args in "" "--json" "--scope user" "--scope project" "--json --scope all"; do
      # shellcheck disable=SC2086
      doc "$dir" doctor $args
      [ "$RC" = 0 ] || [ "$RC" = 1 ] || { echo "$ERR" >&2; fail "doctor exited $RC in state $state"; }
    done
  done
  [ "$(snap "$HOME" "$W")" = "$before" ] || fail "doctor changed a file under HOME or the project (state $state)"
done
ok "twelve states, ten invocations each: not a byte, mode or mtime changed (nothing created either)"

echo "TEST 1b: a crashed writer's journal: the open may let SQLite fold it in, so rows, schema and version stay and every other file is byte-identical"
world
"$PY" - "$W/app/.agentbus/bus.db" <<'PY' || fail "could not leave committed frames in the journal"
import os, sqlite3, sys
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("INSERT INTO log(ts,agent,action) VALUES('t','crashed','x')")
os._exit(0)   # no checkpoint, no close: the committed row lives only in the -wal
PY
[ -s "$W/app/.agentbus/bus.db-wal" ] || fail "the crashed-writer state has no journal frames to fold in"
logical_before=$("$PY" -c 'import sys, h; print(h.logical(sys.argv[1]))' "$W/app/.agentbus/bus.db")
others=$("$PY" -c 'import sys, h; print(h.tree(*sys.argv[1:], skip=("bus.db", "bus.db-wal", "bus.db-shm")))' "$HOME" "$W")
doc doctor; [ "$RC" = 0 ] || fail "doctor failed on a bus with a crashed writer's journal: $ERR"
doc doctor --json
is_same() { [ "$2" = "$3" ] || fail "$1"; }
is_same "doctor changed a row, the schema or the version of a bus with a journal to fold in" "$logical_before" "$("$PY" -c 'import sys, h; print(h.logical(sys.argv[1]))' "$W/app/.agentbus/bus.db")"
is_same "doctor changed a file other than the bus's database files after a crash" "$others" "$("$PY" -c 'import sys, h; print(h.tree(*sys.argv[1:], skip=("bus.db", "bus.db-wal", "bus.db-shm")))' "$HOME" "$W")"
grep -q crashed <<<"$logical_before" || fail "the crashed row was not in the state compared"
ok "rows, schema and version unchanged; the checkpoint is the only thing the open may do"

echo "TEST 2: doctor executes nothing it finds; the only process it starts is git, with read-only arguments"
world
mkrepo "$W/app"
mkdir -p "$T/fakebin"
REALGIT=$(command -v git)
# A git on PATH that logs its arguments and runs the real one: every command trusts PATH for git, so doctor may run it, but only as below.
printf '#!/bin/sh\necho "$*" >> "%s/git.log"\nexec "%s" "$@"\n' "$T" "$REALGIT" > "$T/fakebin/git"; chmod 755 "$T/fakebin/git"
# The bus's own copy is planted code: doctor reads it as bytes, it does not run the file.
cp "$W/app/.agentbus/bin/agentbus" "$T/real-copy"
printf '#!/bin/sh\necho ran >> "%s/canary-copy"\n' "$T" > "$W/app/.agentbus/bin/agentbus"; chmod 755 "$W/app/.agentbus/bin/agentbus"
printf '0.1.0\n' > "$W/app/.agentbus/VERSION"
RC=0; (cd "$W/app" && PATH="$T/fakebin:$PATH" "${DOC[@]}" doctor >"$T/out" 2>"$T/err") || RC=$?; OUT=$(cat "$T/out")
[ "$RC" = 0 ] || fail "doctor failed beside planted code: $(cat "$T/err")"
[ ! -e "$T/canary-copy" ] || fail "doctor ran the bus folder's copy of agentbus"
[ -s "$T/git.log" ] || fail "doctor did not use git for discovery (the control for the git log is empty)"
"$PY" - "$T/git.log" <<'PY' || fail "doctor ran git with arguments other than discovery's read-only ones"
import sys
for line in open(sys.argv[1]).read().splitlines():
    t = line.split()
    while t and t[0] in ("-C", "--git-dir"):
        t = t[2:]
    assert t and (t[0] in ("--version", "rev-parse") or (t[0] == "config" and "--get" in t)), line
PY
hasf "0.1.0 here, 0.2.0 installed"
cp "$T/real-copy" "$W/app/.agentbus/bin/agentbus"
# In process: every other way to start a process is replaced by a recorder that raises; Popen passes only git's read-only calls.
"$PY" - "$W/app" <<'PY' || fail "doctor started a subprocess or an executable"
import os, pty, subprocess, sys, h
m = h.load()
calls, gits = [], []
def trap(name):
    def f(*a, **k):
        calls.append(name)
        raise AssertionError("process started: " + name)
    return f
real_popen = subprocess.Popen
def popen(args, *a, **k):
    t = list(args) if isinstance(args, (list, tuple)) else None
    ok = t and t[0] == "git" and not k.get("shell")
    if ok:
        while len(t) > 1 and t[1] in ("-C", "--git-dir"):
            del t[1:3]
        ok = len(t) > 1 and (t[1] in ("--version", "rev-parse") or (t[1] == "config" and "--get" in t))
    if not ok:
        calls.append("subprocess.Popen " + repr(args))
        raise AssertionError("process started: " + repr(args))
    gits.append(args)
    return real_popen(args, *a, **k)
OS = ["system", "popen", "fork", "forkpty", "posix_spawn", "posix_spawnp",
      "execl", "execle", "execlp", "execlpe", "execv", "execve", "execvp", "execvpe",
      "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve", "spawnvp", "spawnvpe"]
for n in OS:
    if hasattr(os, n):
        setattr(os, n, trap("os." + n))
for n in ("spawn", "fork"):
    setattr(pty, n, trap("pty." + n))
subprocess.Popen = popen
os.chdir(sys.argv[1])
# controls: each trap is live, and git still gets through
for fn in (lambda: os.posix_spawnp("true", ["true"], {}), lambda: os.system("true"), lambda: os.fork(), lambda: pty.spawn("true"),
           lambda: subprocess.run(["true"]), lambda: subprocess.Popen("true", shell=True), lambda: os.execv("/usr/bin/true", ["true"])):
    try:
        fn()
    except AssertionError:
        continue
    raise SystemExit("a trap did not fire")
assert len(calls) == 7, calls
m.repo_info()
assert gits, "git did not get through the guard"
del calls[:], gits[:]
for argv in (["doctor"], ["--json", "doctor"], ["doctor", "--scope", "project"]):
    rc, out, err = h.run(m, argv)
    assert rc == 0 and out, (argv, rc, err)
    assert not calls, (argv, calls)
assert gits, "doctor's discovery did not run git through the guard"
PY
ok "a planted copy never ran; git ran only as rev-parse, --version or config --get; every other spawn API is trapped and tested live"

echo "TEST 3: a recorded executable is read as text: its __version__ line is found, nothing runs"
world
printf '#!/bin/sh\necho ran >> "%s/canary-hook"\n__version__ = "9.8.7"\n' "$T" > "$T/planted-hook"; chmod 755 "$T/planted-hook"
"$PY" - "$T/planted-hook" "$T/nope" "$T" <<'PY' || fail "doctor_executable_info"
import os, sys, h
m = h.load()
assert m.doctor_executable_info(sys.argv[1]) == (True, "9.8.7")
assert m.doctor_executable_info(sys.argv[2]) == (False, None)
os.symlink(sys.argv[1], sys.argv[3] + "/link-to-hook")
assert m.doctor_executable_info(sys.argv[3] + "/link-to-hook") == (True, None), "a link must not be followed"
assert m.doctor_executable_info(sys.argv[3]) == (True, None), "a folder has no version"
PY
[ ! -e "$T/canary-hook" ] || fail "reading a recorded executable's version ran it"
ok "version read as text; a missing path, a link and a folder have none; the canary file never appeared"

echo "TEST 4: with everything installed and current the output is the documented block"
world
printf '0.1.0\n' > "$W/app/.agentbus/VERSION"; rm -rf "$HOME/.codex"
doc doctor
[ "$RC" = 0 ] || fail "exit $RC, wanted 0 for a warning: $ERR"
want="agentbus 0.2.0 (<TOOL>)
  ok    bus        <WS>/app (schema 1)
  warn  copy       0.1.0 here, 0.2.0 installed. Run: agentbus upgrade <WS>/app
  ok    skill      ~/.claude/skills/agentbus/SKILL.md is current
  n/a   agents-md  no ~/.codex found
  ok    hooks      ~/.claude/settings.json has the current hooks
  ok    hooks      the hooks run <TOOL> (0.2.0)
1 warning."
got=$(norm)
[ "$got" = "$want" ] || { printf 'wanted:\n%s\ngot:\n%s\n' "$want" "$got" >&2; fail "the documented block differs"; }
[ -z "$ERR" ] || fail "a warning wrote to stderr: $ERR"
ok "header, five rows in table order, the summary; exit 0"
doc doctor --scope project
[ "$RC" = 0 ] || fail "doctor --scope project: exit $RC, wanted 0 for a warning: $ERR"
hasf "has no agentbus hooks. Run: agentbus setup claude --scope project"
doc doctor --json
case "$OUT" in *"has no agentbus hooks"*) fail "the default scope warned that a project never set up has no hooks: $OUT";; esac
ok "a project that never ran setup is silent for hooks by default and named when --scope project asks"

echo "TEST 5: tool: a copy run from a project says so, names the installed tool and does not compare itself; the installed tool prints the header only"
world
RC=0; (cd "$W/app" && "$PY" .agentbus/bin/agentbus doctor >"$T/out" 2>"$T/err") || RC=$?; OUT=$(cat "$T/out")
[ "$RC" = 0 ] || fail "doctor from a project copy failed: $(cat "$T/err")"
hasf "  warn  tool       this is the folder's own copy at $W/app/.agentbus/bin/agentbus, not the installed agentbus, so it cannot be compared with itself. Run: agentbus doctor"
hasf "  n/a   copy       this is the folder's own copy; run the installed agentbus doctor to compare it. Run: agentbus doctor"
hasf "  ok    bus        $W/app (schema 1)"
(cd "$W/app" && "$PY" .agentbus/bin/agentbus --json doctor >"$T/out" 2>/dev/null) || fail "doctor --json from a project copy failed"
row tool warn "this is the folder's own copy at" "agentbus doctor"
row copy n/a "this is the folder's own copy" "" "" "Run: agentbus doctor"
doc doctor
! grep -q '^  [a-z/]* *tool ' <<<"$OUT" || fail "the installed tool printed a tool row beside the header"
ok "doctor from a project copy runs, names the installed command as the fix, and does not call a copy current by comparing it with itself"

echo "TEST 6: bus: one case per state, each with the documented text and fix"
world; rm -rf "$W/none"; mkdir -p "$W/none"
doc "$W/none" doctor --json
[ "$RC" = 0 ] || fail "no bus must not be a failure (exit $RC)"
row bus n/a "no bus here or in any parent folder" "agentbus init ."
row copy n/a "no bus" ""
doc "$W/none" doctor; has "Nothing to fix, but there is no bus here."
! grep -qF "No problems." <<<"$OUT" || fail "a folder with no bus printed No problems."
doc "$W/none" doctor --json
row skill ok "is current" ""
doc "$W/none" doctor
has "  n/a   bus        no bus here or in any parent folder. Run: agentbus init ."
ok "no bus: n/a with 'agentbus init .', and the other checks still ran"
# a fresh init: the folder and copy exist, the first command makes the database
mkdir -p "$W/fresh"; "${DOC[@]}" init "$W/fresh" >/dev/null 2>&1
doc "$W/fresh" doctor --json
row bus ok "no database yet; the first command creates it" ""
row copy ok "0.2.0, same as the installed agentbus" ""
ok "a fresh init is ok, not a problem"
# the v0.1.0 shape without the stamp
mkdir -p "$W/legacy"; "${OLD[@]}" init "$W/legacy" >/dev/null 2>&1; (cd "$W/legacy" && "$PY" .agentbus/bin/agentbus --as a join >/dev/null 2>&1)
doc "$W/legacy" doctor --json
row bus ok "schema 0, the v0.1.0 shape; the next write stamps it 1" ""
row copy warn "0.1.0 here, 0.2.0 installed" "agentbus upgrade $W/legacy"
[ "$("$PY" -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA user_version").fetchone()[0])' "$W/legacy/.agentbus/bus.db")" = 0 ] || fail "doctor stamped a v0.1.0 bus"
ok "a v0.1.0 bus is ok and stays unstamped"
# older: a tool one schema version ahead would migrate it
cat > "$T/v2.py" <<'PY'
import sys, h
m = h.load()
m.SCHEMA = m.SCHEMA.replace("action TEXT NOT NULL, detail TEXT);", "action TEXT NOT NULL, detail TEXT, extra TEXT);")
m.SCHEMA_VERSION = 2
m.MIGRATIONS[1] = ["ALTER TABLE log ADD COLUMN extra TEXT"]
m.reference_shapes.cache_clear(); m.reference_indexes.cache_clear()
m.__version__ = "0.2.0"
sys.argv = ["agentbus"] + sys.argv[1:]
m.cli()
PY
RC=0; (cd "$W/app" && "$PY" "$T/v2.py" doctor --json >"$T/out" 2>"$T/err") || RC=$?
[ "$RC" = 0 ] || fail "an older bus is a warning, not a failure (exit $RC): $(cat "$T/err")"
row bus warn "(schema 1) is older than this agentbus; the next write migrates it after a backup" "agentbus upgrade $W/app"
[ ! -d "$W/app/.agentbus/backups" ] || fail "doctor migrated a bus (a backups folder appeared)"
ok "older: warn, names agentbus upgrade DIR, migrates nothing"
# newer
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=7"); c.commit()' "$W/app/.agentbus/bus.db"
doc doctor --json
[ "$RC" = 1 ] || fail "a newer bus must exit 1, got $RC"
row bus fail "(schema 7) is newer than this agentbus (it knows 1)" "uv tool upgrade agentbus"
ok "newer: fail, names the upgrade of the tool"
# corrupt: a version no agentbus writes
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=99999"); c.commit()' "$W/app/.agentbus/bus.db"
doc doctor --json
[ "$RC" = 1 ] || fail "a corrupt version must exit 1, got $RC"
row bus fail "records schema version 99999, which no agentbus writes" "" "" "Restore a backup"
ok "corrupt: fail"
# refused: tables that are not agentbus's shape
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=0"); c.execute("ALTER TABLE log ADD COLUMN extra TEXT"); c.commit()' "$W/app/.agentbus/bus.db"
doc doctor --json
[ "$RC" = 1 ] || fail "a bus with another shape must exit 1, got $RC"
row bus fail "$W/app" "" "" "Restore a backup"
ok "refused: fail, with a hint and no fix"
# garbage: not an SQLite file at all; the hint names that, not permissions
"$PY" -c 'import sys; open(sys.argv[1], "wb").write(b"not a database " * 40)' "$W/app/.agentbus/bus.db"; rm -f "$W/app/.agentbus/bus.db-wal" "$W/app/.agentbus/bus.db-shm"
doc doctor --json
[ "$RC" = 1 ] || fail "a bus.db that is not a database must exit 1, got $RC"
row bus fail "SQLite cannot use $W/app/.agentbus/bus.db (file is not a database)" "" "" "Restore a backup"
! grep -q permissions "$T/out" || fail "a garbage bus.db was blamed on permissions"
ok "garbage: fail, SQLite's reason, a restore hint (not permissions)"

echo "TEST 7: a bus held by a sqlite3 shell: bus is warn busy within 1 s"
world
"$PY" - "$W/app/.agentbus/bus.db" "$T" "${DOC[*]}" <<'PY' || fail "busy"
import json, os, subprocess, sys, time
db, T, doc = sys.argv[1], sys.argv[2], sys.argv[3].split()
code = ("import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1], isolation_level=None); c.execute('PRAGMA locking_mode=EXCLUSIVE'); "
        "c.execute('BEGIN EXCLUSIVE'); c.execute(\"INSERT INTO log(ts,agent,action) VALUES('t','holder','x')\"); open(sys.argv[2],'w').close(); time.sleep(30)")
mark = T + "/held"
p = subprocess.Popen([sys.executable, "-c", code, db, mark])
try:
    for _ in range(200):
        if os.path.exists(mark):
            break
        time.sleep(0.05)
    t0 = time.monotonic()
    r = subprocess.run(doc + ["doctor", "--json"], cwd=os.path.dirname(os.path.dirname(db)), capture_output=True, text=True)
    took = time.monotonic() - t0
finally:
    p.kill(); p.wait()
assert r.returncode == 0, r
bus = [c for c in json.loads(r.stdout)["checks"] if c["id"] == "bus"][0]
assert bus["status"] == "warn" and "is busy: another process holds it" in bus["detail"], bus
assert bus["fix"] is None and bus["hint"] == "Close it, then run agentbus doctor again.", bus
assert took < 1.0, took
PY
ok "busy is a warning with a hint (no command), in under a second"

echo "TEST 8: copy: one case per state, and the copy's bytes are compared with the installed agentbus's"
world
CP="$W/app/.agentbus/bin/agentbus"; cp "$CP" "$T/good-copy"
printf '9.9.9\n' > "$W/app/.agentbus/VERSION"; doc doctor --json
row copy warn "9.9.9 here is newer than the installed 0.2.0" "uv tool upgrade agentbus"
rm "$W/app/.agentbus/VERSION"; doc doctor --json
row copy warn "has no VERSION, so its copy's version is unknown" "agentbus upgrade $W/app"
printf '0123456789abcdef0123456789abcdef01234567 2026-11-01T10:00:00Z\n' > "$W/app/.agentbus/VERSION"; doc doctor --json
row copy ok "0123456, same as the installed agentbus" ""
printf '# edited\n' >> "$CP"; doc doctor --json
row copy n/a "the copy is from source (0123456), not a release; its contents differ from the installed agentbus" "" "" "agentbus upgrade $W/app"
printf '0.2.0\n' > "$W/app/.agentbus/VERSION"; doc doctor --json
row copy warn "0.2.0 here has the installed version's number but not its contents (damaged, edited or empty)" "agentbus upgrade $W/app"
: > "$CP"; doc doctor --json
row copy warn "has the installed version's number but not its contents" "agentbus upgrade $W/app"
doc doctor; has "  warn  copy       0.2.0 here has the installed version's number but not its contents (damaged, edited or empty). Run: agentbus upgrade $W/app"
cp "$T/good-copy" "$CP"; doc doctor --json
row copy ok "0.2.0, same as the installed agentbus" ""
rm -f "$CP"; doc doctor --json
row copy warn "has no copy of agentbus (bin/agentbus is missing); agents cannot run it" "agentbus init $W/app"
ok "newer, no VERSION, a source commit (same and different bytes), edited and empty copies under the right version, no copy"

echo "TEST 9: skill and agents-md: each state names its text and fix"
world
SK="$HOME/.claude/skills/agentbus"; AG="$HOME/.codex/AGENTS.md"
doc doctor --json; row skill ok "$SK/SKILL.md is current" "" user; row agents-md ok "$AG has the current block" "" user
rm -rf "$SK"; doc doctor --json
row skill warn "$SK/SKILL.md is not installed; agents do not know the protocol" "agentbus setup claude" user
doc doctor; has "  warn  skill      ~/.claude/skills/agentbus/SKILL.md is not installed; agents do not know the protocol. Run: agentbus setup claude"
# an older skill: a managed file whose hash is in SKILL_SHA256_HISTORY (a tool whose history holds this text's hash)
mkdir -p "$SK"; printf 'old skill text\n\n<!-- agentbus:managed -->\n' > "$SK/SKILL.md"
hash=$("$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SK/SKILL.md")
ahash=$("$PY" -c 'import hashlib; print(hashlib.sha256(b"older block\n").hexdigest())')
"$PY" - "$T/tool/agentbus" "$T/tool-hist" "$hash" "$ahash" <<'PY'
import os, sys
src, dst, h1, h2 = sys.argv[1:]
s = open(src).read()
s = s.replace("SKILL_SHA256_HISTORY = (\n", 'SKILL_SHA256_HISTORY = (\n    "%s",\n' % h1, 1).replace("AGENTS_SHA256_HISTORY = (\n", 'AGENTS_SHA256_HISTORY = (\n    "%s",\n' % h2, 1)
os.makedirs(dst, exist_ok=True); open(dst + "/agentbus", "w").write(s)
PY
DOC_H=("$PY" "$T/tool-hist/agentbus")
RC=0; (cd "$W/app" && "${DOC_H[@]}" doctor --json >"$T/out" 2>/dev/null) || RC=$?
row skill warn "$SK/SKILL.md is an older version of the skill" "agentbus setup claude" user
doc doctor --json
row skill warn "$SK/SKILL.md was edited, or comes from a newer agentbus; setup saves it as a .bak file before replacing it" "agentbus setup claude" user
printf 'mine\n' > "$SK/SKILL.md"; doc doctor --json
row skill warn "$SK/SKILL.md was not written by agentbus" "" user "setup will not change it. Inspect it, and move it aside if it is yours to move"
doc doctor; has "  warn  skill      ~/.claude/skills/agentbus/SKILL.md was not written by agentbus. setup will not change it. Inspect it, and move it aside if it is yours to move."
# the old README install line: a link to a folder (alive, with an agentbus skill, or gone)
rm -rf "$SK"; mkdir -p "$T/clone/skill"; printf -- '---\nname: agentbus\n---\n' > "$T/clone/skill/SKILL.md"; ln -s "$T/clone/skill" "$SK"
doc doctor --json
row skill warn "$SK is a link to $T/clone/skill (the old install line); it breaks when that folder moves" "agentbus setup claude" user
rm -rf "$T/clone"; doc doctor --json
row skill warn "$SK is a link to $T/clone/skill (the old install line)" "agentbus setup claude" user
rm "$SK"; mkdir -p "$T/other"; printf -- '---\nname: other\n---\n' > "$T/other/SKILL.md"; ln -s "$T/other" "$SK"; doc doctor --json
row skill warn "is a link to $T/other, which is not an agentbus skill" "" user "setup will not change it"
rm "$SK"; (cd "$W/app" && "${DOC[@]}" setup claude >/dev/null)
ok "skill: missing, older, edited, unmanaged, old install-line link (alive and dangling), foreign link"
# AGENTS.md
rm "$AG"; doc doctor --json
row agents-md warn "$AG does not exist; Codex has no agentbus block" "agentbus setup codex" user
printf 'my own notes\n' > "$AG"; doc doctor --json
row agents-md warn "$AG has no agentbus block" "agentbus setup codex" user
printf '<!-- agentbus:begin -->\nonly the start\n' > "$AG"; doc doctor --json
row agents-md warn "$AG has damaged agentbus markers" "" user "Repair the <!-- agentbus:begin --> and <!-- agentbus:end --> lines by hand"
printf '<!-- agentbus:begin -->\nolder block\n<!-- agentbus:end -->\n' > "$AG"
RC=0; (cd "$W/app" && "${DOC_H[@]}" doctor --json >"$T/out" 2>/dev/null) || RC=$?
row agents-md warn "$AG has an older agentbus block" "agentbus setup codex" user
doc doctor --json
row agents-md warn "$AG has an edited agentbus block, or one from a newer agentbus" "agentbus setup codex" user
rm "$AG"; (cd "$W/app" && "${DOC[@]}" setup codex >/dev/null); mv "$AG" "$T/real-agents"; ln -s "$T/real-agents" "$AG"; doc doctor --json
row agents-md ok "has the current block (through a symlink; setup will not write through it)" "" user
printf 'my own notes\n' > "$T/real-agents"; doc doctor --json
row agents-md warn "$AG has no agentbus block" "" user "setup will not write through a symlink. Edit the file it points to."
rm "$AG"; mv "$T/real-agents" "$AG"
ok "agents-md: missing file, no block, damaged markers, older, edited, current through a symlink, a symlink that needs a block (hint, no setup)"

echo "TEST 10: exit 0 with only warnings, 1 with a fail; the summary line counts both"
world
printf '0.1.0\n' > "$W/app/.agentbus/VERSION"; rm -rf "$SK"
doc doctor; [ "$RC" = 0 ] || fail "two warnings must exit 0, got $RC"
has "2 warnings."
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=7"); c.commit()' "$W/app/.agentbus/bus.db"
doc doctor; [ "$RC" = 1 ] || fail "a fail must exit 1, got $RC"
has "1 problem, 2 warnings."
grep -qF "doctor found 1 problem: bus" <<<"$ERR" || fail "a fail left no one-line reason on stderr: $ERR"
doc doctor --json; [ "$RC" = 1 ] || fail "a fail under --json must exit 1, got $RC"
"$PY" - "$T/out" "$T/err" <<'PY' || fail "a failing doctor --json: stdout is not the full result, or stderr is not the items_failed error"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["fail"] == 1 and r["warn"] == 2 and len(r["checks"]) >= 6, r
e = json.loads(open(sys.argv[2]).read())["error"]
assert e["code"] == "items_failed" and e["failed"][0]["id"] == "bus" and e["retryable"] is False, e
bus = [c for c in r["checks"] if c["id"] == "bus"][0]
assert e["failed"][0] == bus and "fix" in e["failed"][0] and "hint" in e["failed"][0], (e["failed"][0], bus)   # null keys kept, like stdout
PY
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=99999"); c.commit()' "$W/app/.agentbus/bus.db"
doc doctor --json
"$PY" - "$T/out" "$T/err" <<'PY' || fail "a failed entry without a fix does not keep its null fix beside its hint, as stdout does"
import json, sys
r = json.load(open(sys.argv[1])); e = json.loads(open(sys.argv[2]).read())["error"]
f = e["failed"][0]
assert f["fix"] is None and f["hint"].startswith("Restore a backup") and f == [c for c in r["checks"] if c["id"] == "bus"][0], f
PY
world
doc doctor; [ "$RC" = 0 ] || fail "a clean doctor must exit 0, got $RC"
has "No problems."
ok "summary: 'No problems.', '2 warnings.', '1 problem, 2 warnings.'; exit 0, 0, 1; --json keeps stdout whole"

echo "TEST 11: --json parses, validates against 'schema doctor' and has one entry per check"
world
doc doctor --json
"${DOC[@]}" schema --json > "$T/schema.json"
"$PY" - "$T/out" "$T/schema.json" "$TESTS_DIR" <<'PY' || fail "doctor --json does not match its schema"
import json, sys
sys.path.insert(0, sys.argv[3])
from schema_check import validate
r = json.load(open(sys.argv[1], "rb"), parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))
s = json.load(open(sys.argv[2]))
errors = validate(r, s["commands"]["doctor"]["result"], s["objects"])
assert not errors, errors
# hooks has a row for the entries and one for the tool they run (both ok here); every other check is one row
assert [c["id"] for c in r["checks"]] == ["tool", "bus", "copy", "skill", "agents-md", "hooks", "hooks"], [c["id"] for c in r["checks"]]
assert r["agentbus"] == "0.2.0" and r["contract"] == 1 and r["fail"] == 0 and r["warn"] == 0 and r["path"].endswith("tool/agentbus"), r
assert all(c["status"] in ("ok", "warn", "fail", "n/a") and "fix" in c and "hint" in c for c in r["checks"]), r
assert "checks of doctor" in s["errors"]["items_failed"]["meaning"], s["errors"]["items_failed"]
assert "hint" in s["objects"]["DoctorCheck"]["properties"] and "hint" in s["objects"]["DoctorCheck"]["required"], s["objects"]["DoctorCheck"]
bad = {"agentbus": "x", "checks": [{"id": "bus", "status": "fine", "detail": "", "fix": None}], "fail": 0, "warn": 0, "path": "p", "contract": 1}
assert validate(bad, s["commands"]["doctor"]["result"], s["objects"]), "an unknown status passed the schema"
PY
ok "valid against the registry; ids in table order; an unknown status fails the schema"

echo "TEST 12: scope: user, project and all"
world
doc doctor --scope project --json
row skill warn "$W/app/.claude/skills/agentbus/SKILL.md is not installed" "agentbus setup claude --scope project" project
row agents-md warn "$W/app/AGENTS.md does not exist" "agentbus setup codex --scope project" project
doc doctor --json
"$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); assert [c.get("scope") for c in r["checks"] if c["id"] in ("skill","agents-md")] == ["user","user"], r' "$T/out" || fail "all scope listed a project piece that is not installed"
(cd "$W/app" && "${DOC[@]}" setup claude --scope project >/dev/null && "${DOC[@]}" setup codex --scope project >/dev/null)
doc doctor --json
"$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); assert [c.get("scope") for c in r["checks"] if c["id"] in ("skill","agents-md")] == ["user","project","user","project"], r' "$T/out" || fail "all scope did not list the installed project pieces"
doc doctor --scope user --json
"$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); assert {c.get("scope") for c in r["checks"]} <= {None,"user"}, r' "$T/out" || fail "user scope listed a project row"
mkdir -p "$HOME/p"; (cd "$HOME/p" && "${DOC[@]}" init . >/dev/null 2>&1 && "${DOC[@]}" setup claude >/dev/null)
doc "$HOME" doctor --json
"$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); assert [c.get("scope") for c in r["checks"] if c["id"]=="skill"] == ["user"], r' "$T/out" || fail "run from HOME the user and project scopes are one folder and must be listed once"
ok "all lists installed project pieces only; project names what is missing; HOME is not listed twice"

echo "TEST 13: a linked worktree finds its main checkout's bus, as every command does"
world
mkrepo "$W/main"; "${DOC[@]}" init "$W/main" >/dev/null 2>&1
git -C "$W/main" worktree add -q "$W/wt" 2>/dev/null || git -C "$W/main" worktree add -q -b wtb "$W/wt"
mkdir -p "$W/wt/sub"
doc "$W/wt/sub" doctor --json
row bus ok "$W/main" ""
real=$(cd "$W/wt/sub" && "${DOC[@]}" --json buses | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["directory"])')
[ "$real" = "$W/main" ] || fail "buses disagrees with the test's own expectation: $real"
ok "doctor and buses name the same bus from a linked worktree"

echo "TEST 14: AGENTBUS_DB selects the bus; a missing one is n/a"
world
RC=0; (cd "$T" && AGENTBUS_DB="$W/app/.agentbus/bus.db" "${DOC[@]}" doctor --json >"$T/out" 2>"$T/err") || RC=$?
[ "$RC" = 0 ] || fail "AGENTBUS_DB run failed: $(cat "$T/err")"
row bus ok "$W/app (schema 1)" ""
RC=0; (cd "$T" && AGENTBUS_DB="$T/nowhere/.agentbus/bus.db" "${DOC[@]}" doctor --json >"$T/out" 2>"$T/err") || RC=$?
[ "$RC" = 0 ] || fail "a missing AGENTBUS_DB bus must not fail (exit $RC)"
row bus n/a "no bus at $T/nowhere/.agentbus/bus.db" "" "" "AGENTBUS_DB names a bus that does not exist yet"
mkdir -p "$T/there"
RC=0; (cd "$T" && AGENTBUS_DB="$T/there/.agentbus/bus.db" "${DOC[@]}" doctor --json >"$T/out" 2>"$T/err") || RC=$?
row bus n/a "no bus at $T/there/.agentbus/bus.db" "agentbus init $T/there"
mkdir -p "$T/plain"; RC=0; (cd "$T" && AGENTBUS_DB="$T/plain/bus.db" "${DOC[@]}" --as a join >/dev/null 2>&1 && AGENTBUS_DB="$T/plain/bus.db" "$PY" "$T/v2.py" doctor --json >"$T/out" 2>"$T/err") || RC=$?
row bus warn "$T/plain (schema 1) is older than this agentbus" "" "" "Run any agentbus command that writes, with this AGENTBUS_DB"
ok "explicit database honoured; a missing one names the init command only where init works, else a hint; an older one outside .agentbus gets a hint, not an upgrade DIR that cannot work"

echo "TEST 15: text from files is escaped, and long lines wrap"
world
rm -rf "$SK"; ln -s "$(printf '%s/x\033[31mred\033[0m' "$T/gone")" "$SK"
doc doctor
! grep -q $'\033' "$T/out" || fail "an escape character from a link target reached the terminal"
hasf '\x1b[31mred'
doc doctor --json
"$PY" -c 'import json,sys; assert "\x1b[31m" in json.load(open(sys.argv[1]))["checks"][3]["detail"]' "$T/out" || fail "--json must carry the real target text"
rm "$SK"; (cd "$W/app" && "${DOC[@]}" setup claude >/dev/null)
RC=0; (cd "$W/app" && COLUMNS=60 "${DOC[@]}" doctor >"$T/out" 2>&1) || RC=$?
"$PY" -c 'import sys; w=max(len(l) for l in open(sys.argv[1]).read().splitlines()); assert w <= 60, w' "$T/out" || fail "a doctor line is wider than COLUMNS"
ok "escapes shown, JSON raw, rows wrapped at COLUMNS"

echo "TEST 16: extension points: a registered check and hook checks show up, and read-only still holds"
world
mkdir -p "$T/hookcfg"
printf '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/old/path/agentbus hook start 2>/dev/null || true # agentbus:managed"}]}]}}\n' > "$T/hookcfg/settings.json"
"$PY" - "$W/app" "$T/hookcfg/settings.json" <<'PY' || fail "extension points"
import os, sys, h
m = h.load()
os.chdir(sys.argv[1])
before = h.tree(os.environ["HOME"], os.path.dirname(sys.argv[1]))
# The merged build ships the Claude hooks piece; take it out so this test starts from "no hook pieces".
m.SETUP_TARGETS["claude"] = [p for p in m.SETUP_TARGETS["claude"] if not isinstance(p, m.JsonEntriesPiece)]
# 1. No hook pieces and no registered checks: hooks is n/a with the documented text.
rc, out, err = h.run(m, ["doctor"])
assert "  n/a   hooks      not installed by this version" in out.splitlines(), out
# 2. A hook piece in SETUP_TARGETS is checked through its own check(); a missing/stale/problem entry is warn/warn/fail.
path = sys.argv[2]
piece = m.JsonEntriesPiece("claude_hooks", lambda scope: path,
                           lambda scope: [("SessionStart", None, {"type": "command", "command": "/new/agentbus hook start 2>/dev/null || true " + m.MANAGED_TAG})])
m.SETUP_TARGETS["claude"].append(piece)
rc, out, err = h.run(m, ["--json", "doctor", "--scope", "user"])
import json
checks = [c for c in json.loads(out)["checks"] if c["id"] == "hooks"]
assert len(checks) == 1 and checks[0]["status"] == "warn" and checks[0]["fix"] == "agentbus setup claude" and checks[0]["scope"] == "user", checks
assert "needs the agentbus hooks" in checks[0]["detail"], checks
open(path, "w").write("not json")
rc, out, err = h.run(m, ["--json", "doctor", "--scope", "user"])
checks = [c for c in json.loads(out)["checks"] if c["id"] == "hooks"]
assert rc == 1 and checks[0]["status"] == "fail" and checks[0]["fix"] is None and "setup will not change a file it cannot parse" in checks[0]["hint"], (rc, checks)
# 3. A check registered by a hook stream is appended to hooks; a check with a new id is a new row after the others.
m.SETUP_TARGETS["claude"].remove(piece)
m.DOCTOR_HOOK_CHECKS.append(lambda ctx: [m.doctor_result("hooks", "fail", "runs /old/path/agentbus, which does not exist", "agentbus setup claude")])
m.register_doctor_check("plugin", lambda ctx: [m.doctor_result("plugin", "n/a", "no plugin installed")])
rc, out, err = h.run(m, ["doctor"])
lines = out.splitlines()
assert "  fail  hooks      runs /old/path/agentbus, which does not exist. Run: agentbus setup claude" in lines, out
assert lines[-2].startswith("  n/a   plugin     no plugin installed") and lines[-1] == "1 problem.", out
assert rc == 1, rc
# 4. A check that raises is a fail row for that check; the others still ran.
m.register_doctor_check("boom", lambda ctx: 1 / 0)
rc, out, err = h.run(m, ["--json", "doctor"])
r = json.loads(out)
boom = [c for c in r["checks"] if c["id"] == "boom"][0]
assert boom["status"] == "fail" and "ZeroDivisionError" in boom["detail"], boom
assert [c["id"] for c in r["checks"]][:3] == ["tool", "bus", "copy"], r
assert h.tree(os.environ["HOME"], os.path.dirname(sys.argv[1])) == before, "doctor changed HOME or the project"
PY
ok "hook pieces map ok/missing/stale/problem; DOCTOR_HOOK_CHECKS and register_doctor_check add rows; a broken check is a fail row"

echo "TEST 17: the Claude hooks piece and the hook command exist, so doctor checks them (the n/a placeholder is only for a build with neither; test 16 covers that state)"
"$PY" - <<'PY' || fail "hook piece"
import h
m = h.load()
assert any(isinstance(p, m.ClaudeHooksPiece) for p in m.SETUP_TARGETS["claude"]), "the Claude hooks piece is not in SETUP_TARGETS"
assert "hook" in m.EARLY_COMMANDS, "the hook command is gone"
PY
ok "the Claude hooks piece is registered and the hook command exists"

echo "TEST 18: the release-cache check of the update story has its marked place, and doctor makes no network call"
grep -q 'DOCTOR_UPDATE_CHECK_SLOT' "$MOD" || fail "the marked place for the release-cache check is gone"
sed -n '/^# ==== doctor ====/,/^COMMANDS = {/p' "$MOD" > "$T/doctor-region.py"
[ -s "$T/doctor-region.py" ] || fail "the doctor region markers are gone"
! grep -qE '\b(socket|urllib|http\.client|urlopen|requests)\b' "$T/doctor-region.py" || fail "the doctor region uses the network"
ok "the slot is marked; the doctor region has no network code"

echo "TEST 19: doctor finds the bus as every command does, and a state where commands fail is never 'No problems.'"
world
# a bare repository's linked worktree under a folder that has an outer bus: join refuses (no main checkout git can name)
mkdir -p "$W/outer"; "${DOC[@]}" init "$W/outer" >/dev/null 2>&1
mkrepo "$W/outer/src"; git -C "$W/outer" clone -q --bare "$W/outer/src" "$W/outer/bare.git"; git -C "$W/outer/bare.git" worktree add -q "$W/outer/bwt" >/dev/null 2>&1 || git -C "$W/outer/bare.git" worktree add -q -b wt2 "$W/outer/bwt"
RC=0; (cd "$W/outer/bwt" && "${DOC[@]}" --as a join >/dev/null 2>"$T/err") || RC=$?
[ "$RC" = 3 ] && grep -q "cannot find the main checkout" "$T/err" || fail "the premise failed: join from a bare repository's worktree must refuse (rc $RC): $(cat "$T/err")"
doc "$W/outer/bwt" doctor; [ "$RC" = 1 ] || fail "doctor must exit 1 where join exits 3 (got $RC)"
hasf "cannot find the main checkout for this worktree"
! grep -qF "No problems." <<<"$OUT" || fail "doctor said No problems. where every command fails"
grep -qF "1 problem" <<<"$OUT" || fail "doctor did not count the failed bus"
# --up is honoured, as for commands
mkdir -p "$W/outer/inner"; "${DOC[@]}" init "$W/outer/inner" >/dev/null 2>&1
doc "$W/outer/inner" doctor --json
row bus ok "$W/outer/inner" ""
RC=0; (cd "$W/outer/inner" && "${DOC[@]}" --up 1 doctor --json >"$T/out" 2>"$T/err") || RC=$?
row bus ok "$W/outer " ""
RC=0; (cd "$W/outer/inner" && "${DOC[@]}" --up 5 doctor --json >"$T/out" 2>"$T/err") || RC=$?
[ "$RC" = 1 ] || fail "--up 5 names no bus and every command fails there, so doctor must exit 1 (got $RC)"
ok "same discovery as the commands (find_bus_path); a refused discovery is a fail, never a clean bill"

echo "TEST 20: a config path that cannot be read is a warning on its scope with a hint, not a crash"
world
# A path that fails for every user, root included (a mode-000 folder would not for root): skills is a file, so the skill's path is ENOTDIR.
rm -rf "$HOME/.claude/skills"; printf 'not a folder\n' > "$HOME/.claude/skills"
doc doctor --json
[ "$RC" = 0 ] || fail "an unreadable skill path must be a warning (exit $RC): $ERR"
row skill warn "cannot be read (Not a directory)" "" user "Check the permissions of that path"
doc doctor; hasf "~/.claude/skills/agentbus"
ok "unreadable paths name the path, the scope and what to check (also as root)"

echo "TEST 21: hooks: the plugin and setup both registering is a fail with the command that removes setup's entries; a hook running a missing executable is a fail with the setup command"
world
mkdir -p "$HOME/.claude/plugins"
"$PY" - "$HOME/.claude/plugins/installed_plugins.json" "$TESTS_DIR/fixtures/claude_hooks/installed_plugins.json" <<'PY' || fail "plugin fixture"
import json, sys
d = json.load(open(sys.argv[2])); entry = next(iter(d["plugins"].values()))
json.dump({"version": d.get("version", 2), "plugins": {"agentbus@agentbus": entry}}, open(sys.argv[1], "w"))
PY
doc doctor --json
[ "$RC" = 1 ] || fail "a plugin and setup both registering hooks must exit 1 (got $RC)"
hooks_row fail "the agentbus plugin and setup both register hooks" "agentbus setup claude --uninstall"
ok "plugin plus setup: a fail whose fix is setup claude --uninstall"
world
"$PY" - "$HOME/.claude/settings.json" <<'PY' || fail "settings edit"
import json, re, sys
d = json.load(open(sys.argv[1]))
for groups in d["hooks"].values():
    for g in groups:
        for hk in g["hooks"]:
            hk["command"] = re.sub(r"^('[^']*' ?)+(?= hook)", "'/nonexistent/agentbus'", hk["command"])
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
doc doctor --json
[ "$RC" = 1 ] || fail "a hook running a missing executable must exit 1 (got $RC)"
hooks_row fail "which is not an agentbus executable" "agentbus setup claude"
ok "a hook command that names a missing executable: a fail whose fix is setup claude"

echo "TEST 22: tool: doctor shows the cached latest release and the cache's age, warns when a newer release is cached, and makes no request"
world
unset XDG_CACHE_HOME
UC="$HOME/.cache/agentbus"; [ "$(uname)" != Darwin ] || UC="$HOME/Library/Caches/agentbus"
seed_cache() {  # AGE-SECONDS OK STABLE
  mkdir -p "$UC"; chmod 700 "$UC"
  "$PY" -I - "$UC/release-check.json" "$1" "$2" "$3" <<'PY2'
import json, sys, time
path, age, ok, stable = sys.argv[1:]
json.dump({"v": 1, "checked_at": int(time.time()) - int(age), "ok": ok == "true", "reason": None, "retry_after": None,
           "stable": stable or None, "pre": None, "notified": None}, open(path, "w"))
PY2
  chmod 600 "$UC/release-check.json"
}
doc doctor --json
case "$OUT" in *"latest "*) fail "doctor named a latest release with no cache";; esac
seed_cache 259200 true 0.2.0
doc doctor --json
row tool ok "; latest 0.2.0, checked " ""
case "$OUT" in *"(3 days ago)"*) ;; *) fail "doctor did not say how old the cached answer is: $OUT";; esac
seed_cache 259200 true 0.3.0
doc doctor --json
row tool warn "a newer release is available: latest 0.3.0, checked " "agentbus update"
doc doctor
hasf "  warn  tool       0.2.0 at $T/tool/agentbus; a newer release is available: latest 0.3.0, checked "
seed_cache 864000 true 0.3.0
doc doctor --json
row tool ok "0.2.0 at " ""
case "$OUT" in *"latest "*) fail "doctor showed a cached answer more than a week old";; esac
seed_cache 100 true 0.3.0
before=$(find "$UC" -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum <"$f")"; done | cksum)
AGENTBUS_TEST_RELEASES_URL=https://127.0.0.1:1/releases doc doctor --json
after=$(find "$UC" -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum <"$f")"; done | cksum)
[ "$before" = "$after" ] || fail "doctor changed the release cache"
ok "the cache's latest release and age on the tool row; a newer one is a warning with the fix agentbus update; nothing is refreshed"

all_passed "All doctor tests passed"
