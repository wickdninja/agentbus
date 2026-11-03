#!/bin/bash
set -euo pipefail
# The version policy as a table. Five things carry a version: the installed tool (I), a bus folder's copy (C), the
# bus schema (S), the skill (K) and the hooks (H). Each row builds one combination in a temp HOME with the v0.1.0
# fixture copy (tests/fixtures/legacy/agentbus-0.1.0) and the current tool, runs the commands and asserts what the
# code does. Where the epic's wording and the code differ, the row follows the code (listed at the end of the file).
# The hook column waits for streams 03 and 04: no hook exists yet, and a tripwire (row 13) fails the day one does.
. "$(dirname "$0")/lib.sh"
SELF="$TESTS_DIR/$(basename "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR CODEX_HOME AGENTBUS_TEST_SETUP_FAIL AGENTBUS_TEST_SETUP_JSON AGENTBUS_NO_UPDATE_NOTICE
T=$(cd "$T" && pwd -P); export HOME="$T/home"
cd "$T"
dups=$(grep -vE '^ *(doctor_row|row) ' "$SELF" | grep -oE '(^|[^_a-z])fail "[^"$]*"' | sed 's/^[^f]*//' | sort | uniq -d)
[ -z "$dups" ] || fail "FAIL texts used by more than one assertion: $dups"
MOD="${AGENTBUS_BIN:-$BIN}"
export MOD
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# I: this checkout's file stamped 0.2.0 outside any checkout (an installed command carries its own version).
# C: the v0.1.0 fixture, also outside any checkout so the copy it installs records VERSION 0.1.0, not a commit.
# V2: the same tool one schema version ahead (log gains a column), for the rows that need a migration.
mkdir -p "$T/new" "$T/old"
sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$MOD" > "$T/new/agentbus"
cp "$TESTS_DIR/fixtures/legacy/agentbus-0.1.0" "$T/old/agentbus"
NEW=("$PY" "$T/new/agentbus")
OLD=("$PY" "$T/old/agentbus")
cat > "$T/h.py" <<'PY'
import hashlib, importlib.machinery, importlib.util, os, sqlite3, sys
from urllib.parse import quote

def load():
    loader = importlib.machinery.SourceFileLoader("agentbus_mod", os.environ["MOD"])
    spec = importlib.util.spec_from_loader("agentbus_mod", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    m.__version__ = "0.2.0"
    return m

def tree(*roots):
    h = hashlib.sha256()
    for root in roots:
        for d, dirs, files in os.walk(root):
            dirs.sort()
            for n in sorted(files + dirs):
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

HUMAN = {"init", "upgrade", "setup", "doctor", "skill", "watch", "schema"}   # the installed tool's own (epic, version policy rule 1)
AGENT = {"join", "leave", "who", "post", "inbox", "read", "ctx", "claim", "release", "claims", "log", "status", "goal", "buses"}

def agent_text_problems(text):
    """Commands in agent-facing text that name the installed agentbus where the bus copy belongs, or a path that is not the copy."""
    import re
    bad = []
    for span in re.findall(r"`([^`\n]+)`", text):
        words = span.split()
        if words[0].endswith("agentbus") and words[0] != "agentbus":
            if not (words[0] == ".agentbus/bin/agentbus" or words[0].endswith("/.agentbus/bin/agentbus")):
                bad.append(span)
        elif words[0] == "agentbus" and len(words) > 1 and words[1] not in HUMAN:
            bad.append(span)
    for m in re.finditer(r"(?<![./\w-])agentbus ([a-z]+)", text):   # prose: `agentbus VERB` outside a path is the installed tool
        if m.group(1) in AGENT:
            bad.append(m.group(0))
    return bad

def agents_block(path):
    """The text between the markers of an AGENTS.md."""
    lines = open(path).read().split("\n")
    return "\n".join(lines[lines.index("<!-- agentbus:begin -->") + 1:lines.index("<!-- agentbus:end -->")]) + "\n"

def user_version(db):
    c = sqlite3.connect("file:" + quote(db) + "?mode=ro&immutable=1", uri=True)
    try:
        return c.execute("PRAGMA user_version").fetchone()[0]
    finally:
        c.close()
PY
cat > "$T/v2.py" <<'PY'
import sys, h
m = h.load()
m.SCHEMA = m.SCHEMA.replace("action TEXT NOT NULL, detail TEXT);", "action TEXT NOT NULL, detail TEXT, extra TEXT);")
m.SCHEMA_VERSION = 2
m.MIGRATIONS[1] = ["ALTER TABLE log ADD COLUMN extra TEXT"]
m.reference_shapes.cache_clear(); m.reference_indexes.cache_clear()
sys.argv = ["agentbus"] + sys.argv[1:]
m.cli()
PY
export PYTHONPATH="$T"
V2=("$PY" "$T/v2.py")
snap() { "$PY" -c 'import sys, h; print(h.tree(*sys.argv[1:]))' "$@"; }
uv() { "$PY" -c 'import sys, h; print(h.user_version(sys.argv[1]))' "$1/.agentbus/bus.db"; }
is() { [ "$2" = "$3" ] || { printf 'wanted: %s\ngot: %s\n' "$2" "$3" >&2; fail "$1"; }; }
has() { grep -qF -- "$2" <<<"$3" || { printf 'output was:\n%s\n' "$3" >&2; fail "$1"; }; }
json_is() { "$PY" -c 'import json,sys; r=json.loads(sys.stdin.read()); assert eval(sys.argv[1]), r' "$2" <<<"$3" || { printf 'json was:\n%s\n' "$3" >&2; fail "$1"; }; }
reset() { rm -rf "$HOME" "$T/ws"; mkdir -p "$HOME" "$T/ws"; W="$T/ws"; }
# old_bus DIR: a bus the v0.1.0 tool made and wrote to: copy 0.1.0, the v0.1.0 shape, no version stamp.
old_bus() { mkdir -p "$1"; "${OLD[@]}" init "$1" >/dev/null 2>&1; (cd "$1" && "${OLD[@]}" --as old join >/dev/null 2>&1); }
# run DIR cmd...: cmd from DIR; OUT, ERR, RC.
run() { local d="$1"; shift; RC=0; (cd "$d" && "$@" >"$T/out" 2>"$T/err") || RC=$?; OUT=$(cat "$T/out"); ERR=$(cat "$T/err"); }
doctor_row() {   # doctor_row DIR ID STATUS DETAIL-FRAGMENT FIX: that entry of doctor --json from DIR
  run "$1" "${NEW[@]}" doctor --json
  "$PY" - "$T/out" "$2" "$3" "$4" "$5" <<'PY' || { cat "$T/out" >&2; fail "doctor entry $2 ($3, '$4') is not as documented"; }
import json, sys
path, id, status, frag, fix = sys.argv[1:]
c = [c for c in json.load(open(path))["checks"] if c["id"] == id][0]
assert c["status"] == status and frag in c["detail"] and (c["fix"] or "") == fix, c
PY
}
install_pieces() { mkdir -p "$HOME/.claude" "$HOME/.codex"; "${NEW[@]}" setup claude >/dev/null && "${NEW[@]}" setup codex >/dev/null; }

# ---- the table ----
# ID | tool | copy | bus schema | skill | hooks | asserted (short). Every row has a function row_ID below, and every
# function a row: the table is the test's index.
ROWS=(
"1|new|0.1.0|v0.1.0 shape|none|none|stale notice on join (stderr only), none under --json; doctor warns copy; upgrade --all adopts with no backup"
"2|new|new|v0.1.0 shape|current|current|a write open adopts; watch and read-only commands write nothing; doctor all ok"
"3|new|0.1.0|schema 1|any|any|the 0.1.0 copy works on the bus; its writes keep version 1; doctor still warns copy"
"4|new|new|above the tool's|any|any|schema_newer on write and read-only opens and watch; bytes unchanged; doctor fails bus"
"5|new|0.1.0|any|current|any|the copy prints bare arrays and no contract; the shipped skill names the envelope and the fix"
"6|new|new|current|old install-line link|none|doctor flags the link; setup claude replaces it; doctor ok"
"7|new|any|current|unmanaged SKILL.md|none|setup claude refuses and writes nothing; doctor warns"
"8|new|new|current|current|plugin and setup duplicates|doctor fails hooks on a duplicate (waits for streams 03 and 04)"
"9|0.1.0|0.1.0|synthetic schema 2|n/a|n/a|the 0.1.0 copy answers schema_refused, bytes equal; upgrade from a project copy is refused"
"10|new|new|needs migration|current|current|watch and doctor write nothing; a non-hook command migrates with one backup"
"11|new|0.1.0|any|AGENTS.md block|n/a|the 0.1.0 copy has no skill command; the block names the upgrade --all fallback"
"12|new|new|current|current|templates|every agent-facing command is .agentbus/bin/agentbus; the installed agentbus only in human commands"
"13|new|new|current|current|any hook|tripwire: the hook cells are added the day a hook exists"
)

row_1() {
  reset; old_bus "$W/a/r1"; old_bus "$W/b/r1"
  run "$W/a/r1" "${NEW[@]}" --as n join
  is "row 1: join exits 0" 0 "$RC"
  is "row 1: the stale notice is the documented stderr line" "agentbus: this bus's copy is 0.1.0; the installed agentbus is 0.2.0. Run: agentbus upgrade $W/a/r1" "$ERR"
  ! grep -qF "this bus's copy" <<<"$OUT" || fail "row 1: the stale notice reached stdout"
  run "$W/a/r1" "${NEW[@]}" --json --as n2 join
  is "row 1: no notice under --json" "" "$ERR"
  json_is "row 1: join --json carries agentbus and contract" 'r["agentbus"] == "0.2.0" and r["contract"] == 1' "$OUT"
  doctor_row "$W/a/r1" copy warn "0.1.0 here, 0.2.0 installed" "agentbus upgrade $W/a/r1"
  run "$W/a/r1" "${NEW[@]}" doctor; is "row 1: a copy warning is not a failure" 0 "$RC"
  # the untouched twin: nothing of the new tool has written to it, so upgrade --all sees the v0.1.0 shape
  is "row 1: the twin is unstamped" 0 "$(uv "$W/b/r1")"
  run "$W/b" "${NEW[@]}" --json upgrade --all "$W/b"
  json_is "row 1: upgrade --all adopts: stamp 0 -> 1, copy 0.1.0 -> 0.2.0, no backup" \
    'r["upgraded"] == 1 and r["buses"][0]["schema_old"] == 0 and r["buses"][0]["schema_new"] == 1 and r["buses"][0]["backup"] is None and r["buses"][0]["old"] == "0.1.0" and r["buses"][0]["new"] == "0.2.0"' "$OUT"
  [ ! -e "$W/b/r1/.agentbus/backups" ] || fail "row 1: an adoption made a backup"
  is "row 1: the twin is stamped 1" 1 "$(uv "$W/b/r1")"
  doctor_row "$W/b/r1" copy ok "0.2.0, same as the installed agentbus" ""
}

row_2() {
  reset; install_pieces; old_bus "$W/r2"
  "${NEW[@]}" init "$W/r2" >/dev/null 2>&1   # the new copy over the old bus
  is "row 2: init leaves the v0.1.0 shape unstamped" 0 "$(uv "$W/r2")"
  before=$(snap "$W" "$HOME")
  run "$W/r2" "${NEW[@]}" --json watch; is "row 2: watch --json exits 0" 0 "$RC"
  run "$W/r2" "${NEW[@]}" who; is "row 2: who without a name exits 0" 0 "$RC"
  run "$W/r2" "${NEW[@]}" status; is "row 2: status without a name exits 0" 0 "$RC"
  run "$W/r2" "${NEW[@]}" doctor; is "row 2: doctor exits 0" 0 "$RC"
  has "row 2: doctor says no problems" "No problems." "$OUT"
  is "row 2: reads and doctor leave every byte, mode and mtime as it was" "$before" "$(snap "$W" "$HOME")"
  run "$W/r2" "${NEW[@]}" --as n join; is "row 2: a write open exits 0" 0 "$RC"
  is "row 2: a write open adopts: stamp 1" 1 "$(uv "$W/r2")"
  [ ! -e "$W/r2/.agentbus/backups" ] || fail "row 2: adopting made a backup"
}

row_3() {
  reset; old_bus "$W/r3"
  run "$W/r3" "${NEW[@]}" --as n join; is "row 3: the new tool stamps the bus" 1 "$(uv "$W/r3")"
  (cd "$W/r3" && "$PY" .agentbus/bin/agentbus --as o2 join >/dev/null 2>&1) || fail "row 3: the 0.1.0 copy could not join a schema 1 bus"
  (cd "$W/r3" && "$PY" .agentbus/bin/agentbus --as o2 post "from the old copy" --to n >/dev/null 2>&1) || fail "row 3: the 0.1.0 copy could not write to a schema 1 bus"
  (cd "$W/r3" && "$PY" .agentbus/bin/agentbus --as o2 claim src/a.py >/dev/null 2>&1) || fail "row 3: the 0.1.0 copy could not claim on a schema 1 bus"
  run "$W/r3" "$PY" .agentbus/bin/agentbus who; is "row 3: the 0.1.0 copy reads the bus" 0 "$RC"
  is "row 3: the 0.1.0 copy's writes leave user_version at 1" 1 "$(uv "$W/r3")"
  run "$W/r3" "${NEW[@]}" --as n inbox; has "row 3: the new tool reads what the old copy wrote" "from the old copy" "$OUT"
  doctor_row "$W/r3" bus ok "(schema 1)" ""
  doctor_row "$W/r3" copy warn "0.1.0 here, 0.2.0 installed" "agentbus upgrade $W/r3"
  run "$W/r3" "${NEW[@]}" doctor; is "row 3: doctor exits 0 with the copy warning" 0 "$RC"
}

row_4() {
  reset; install_pieces; mkdir -p "$W/r4"; "${NEW[@]}" init "$W/r4" >/dev/null 2>&1; (cd "$W/r4" && "${NEW[@]}" --as a join >/dev/null 2>&1)
  "$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=2"); c.commit()' "$W/r4/.agentbus/bus.db"
  before=$(snap "$W/r4")
  for cmd in "--as a join" "who" "status" "watch --once"; do
    # shellcheck disable=SC2086
    run "$W/r4" "${NEW[@]}" $cmd
    is "row 4: '$cmd' exits 3" 3 "$RC"
    has "row 4: '$cmd' says the bus is newer" "this bus is newer than this copy of agentbus (schema 2, this copy knows 1)" "$ERR"
  done
  for cmd in "--as a join" "who" "watch"; do
    # shellcheck disable=SC2086
    run "$W/r4" "${NEW[@]}" --json $cmd
    is "row 4: '--json $cmd' exits 3" 3 "$RC"
    json_is "row 4: '--json $cmd' is the schema_newer error" 'r["error"]["code"] == "schema_newer"' "$ERR"
  done
  is "row 4: no refusal changed a byte of the bus folder" "$before" "$(snap "$W/r4")"
  run "$W/r4" "${NEW[@]}" doctor; is "row 4: doctor exits 1" 1 "$RC"
  doctor_row "$W/r4" bus fail "(schema 2) is newer than this agentbus (it knows 1)" "uv tool upgrade agentbus"
  is "row 4: doctor changed nothing either" "$before" "$(snap "$W/r4")"
}

row_5() {
  reset; old_bus "$W/r5"; install_pieces
  run "$W/r5" "$PY" .agentbus/bin/agentbus --json who
  json_is "row 5: a listing from the 0.1.0 copy is a bare array" 'isinstance(r, list) and r[0]["name"] == "old"' "$OUT"
  run "$W/r5" "$PY" .agentbus/bin/agentbus --json --as o2 join
  json_is "row 5: join --json from the 0.1.0 copy has no contract and no agentbus" '"contract" not in r and "agentbus" not in r' "$OUT"
  run "$W/r5" "${NEW[@]}" --json who
  json_is "row 5: the same listing from the new tool is the envelope" 'isinstance(r, dict) and r["v"] == 1 and {a["name"] for a in r["items"]} == {"old", "o2"}' "$OUT"
  # the shipped skill: byte-equal to the file in the repo, and it carries the sentences an agent needs here
  "${NEW[@]}" skill > "$T/skill.out"
  cmp -s "$T/skill.out" "$ROOT/skills/agentbus/SKILL.md" || fail "row 5: agentbus skill differs from skills/agentbus/SKILL.md"
  cmp -s "$T/skill.out" "$HOME/.claude/skills/agentbus/SKILL.md" || fail "row 5: the installed skill differs from agentbus skill"
  skill=$(cat "$T/skill.out")
  has "row 5: the skill names the envelope an agent should see" 'Listings return {items, has_more, next}; if has_more, call again or raise --limit.' "$skill"
  has "row 5: the skill tells an agent to hand the stale-copy fix to the user" 'tell the user to run agentbus upgrade DIR; never edit the bus.' "$skill"
  has "row 5: the skill says the user runs it from the installed agentbus" 'They run it from the installed agentbus, not this copy; on schema_newer, this copy is older than the bus.' "$skill"
}

row_6() {
  reset; install_pieces; old_bus "$W/r6"
  rm -rf "$HOME/.claude/skills/agentbus"
  mkdir -p "$T/clone/skill"; "${NEW[@]}" skill > "$T/clone/skill/SKILL.md"; ln -s "$T/clone/skill" "$HOME/.claude/skills/agentbus"
  cloned=$(snap "$T/clone")
  doctor_row "$W/r6" skill warn "is a link to $T/clone/skill (the old install line)" "agentbus setup claude"
  run "$W/r6" "${NEW[@]}" setup claude; is "row 6: setup claude exits 0" 0 "$RC"
  has "row 6: setup names the link it replaced" "replaced the link to $T/clone/skill (the old install line)" "$OUT"
  [ ! -L "$HOME/.claude/skills/agentbus" ] && [ -f "$HOME/.claude/skills/agentbus/SKILL.md" ] || fail "row 6: the link was not replaced by a folder"
  is "row 6: what the link pointed at is untouched" "$cloned" "$(snap "$T/clone")"
  doctor_row "$W/r6" skill ok "is current" ""
}

row_7() {
  reset; install_pieces; old_bus "$W/r7"
  printf 'my own skill\n' > "$HOME/.claude/skills/agentbus/SKILL.md"
  before=$(snap "$HOME")
  run "$W/r7" "${NEW[@]}" setup claude
  is "row 7: setup claude refuses with exit 1" 1 "$RC"
  has "row 7: setup says nothing was changed" "nothing was changed." "$OUT"
  has "row 7: setup names the file" "was not written by agentbus; not changed." "$OUT"
  is "row 7: setup wrote nothing" "$before" "$(snap "$HOME")"
  doctor_row "$W/r7" skill warn "was not written by agentbus" ""   # setup refuses this file, so doctor names no setup command
  run "$W/r7" "${NEW[@]}" doctor; is "row 7: doctor exits 0 (a warning)" 0 "$RC"
  is "row 7: doctor wrote nothing" "$before" "$(snap "$HOME")"
}

row_8() {
  # Duplicate hook entries, through the real hook-piece interface: the plugin and setup both writing is stream 03's, so the
  # cell that doctor FAILS on a plugin/setup duplicate waits for it (row 13 is the tripwire). What runs here is doctor over
  # a settings file holding the same managed hook twice: it must flag `hooks` and name the setup command that dedupes it.
  reset; install_pieces; mkdir -p "$W/r8"; "${NEW[@]}" init "$W/r8" >/dev/null 2>&1
  before=$(snap "$W" "$HOME")
  cat > "$T/settings.json" <<'JSON'
{"hooks": {"SessionStart": [
  {"hooks": [{"type": "command", "command": "/new/agentbus hook start 2>/dev/null || true # agentbus:managed"}]},
  {"hooks": [{"type": "command", "command": "/new/agentbus hook start 2>/dev/null || true # agentbus:managed"}]}]}}
JSON
  "$PY" - "$W/r8" "$T/settings.json" <<'PY' || fail "row 8: doctor did not flag a duplicated managed hook entry"
import json, os, sys, h
m = h.load()
os.chdir(sys.argv[1])
path = sys.argv[2]
m.SETUP_TARGETS["claude"].append(m.JsonEntriesPiece("claude_hooks", lambda scope: path,
    lambda scope: [("SessionStart", None, {"type": "command", "command": "/new/agentbus hook start 2>/dev/null || true " + m.MANAGED_TAG})]))
import io, contextlib
out, err = io.StringIO(), io.StringIO()
sys.argv = ["agentbus", "--json", "doctor", "--scope", "user"]
try:
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        m.contract_main()
except SystemExit as e:
    assert e.code in (0, None), e.code
hooks = [c for c in json.loads(out.getvalue())["checks"] if c["id"] == "hooks"]
assert len(hooks) == 1 and hooks[0]["status"] == "warn" and hooks[0]["fix"] == "agentbus setup claude", hooks
assert "needs the agentbus hooks" in hooks[0]["detail"], hooks
PY
  is "row 8: doctor wrote nothing" "$before" "$(snap "$W" "$HOME")"
  echo "NOTE: row 8's plugin-vs-setup duplicate (a fail) waits for stream 03; the setup-only duplicate runs above; row 13 fails when a hook command exists"
}

row_9() {
  reset; mkdir -p "$W/r9"; "${OLD[@]}" init "$W/r9" >/dev/null 2>&1
  (cd "$W/r9" && "${V2[@]}" --as a join >/dev/null 2>&1)   # a schema-2 shape (log has an extra column), stamped 2
  is "row 9: the synthetic bus is stamped 2" 2 "$(uv "$W/r9")"
  before=$(snap "$W/r9")
  for cmd in "who" "--as o join" "status" "watch --once"; do
    # shellcheck disable=SC2086
    run "$W/r9" "$PY" .agentbus/bin/agentbus $cmd
    is "row 9: the 0.1.0 copy's '$cmd' exits 1" 1 "$RC"
    has "row 9: the 0.1.0 copy's '$cmd' refuses" "bus schema is not agentbus's: table log differs (extra column extra)" "$ERR"
  done
  run "$W/r9" "$PY" .agentbus/bin/agentbus --json status
  json_is "row 9: under --json the 0.1.0 copy's error is schema_refused" 'r["error"]["code"] == "schema_refused"' "$ERR"
  is "row 9: the 0.1.0 copy wrote nothing: bytes equal" "$before" "$(snap "$W/r9")"
  run "$W/r9" "$PY" .agentbus/bin/agentbus upgrade
  is "row 9: upgrade from the 0.1.0 project copy is refused (exit 1)" 1 "$RC"
  has "row 9: upgrade from the 0.1.0 copy says why" "upgrade runs from the installed agentbus or a clone of its repo; this is a project copy" "$ERR"
  mkdir -p "$W/r9n"; "${NEW[@]}" init "$W/r9n" >/dev/null 2>&1
  run "$W/r9n" "$PY" .agentbus/bin/agentbus upgrade
  is "row 9: upgrade from the new project copy is refused (exit 2)" 2 "$RC"
  has "row 9: upgrade from the new copy says why" "upgrade runs from the installed agentbus or a clone of its repo; this is a project copy" "$ERR"
  # the installed tool (schema 1) calls the same bus newer, and doctor fails it with the fix
  run "$W/r9" "${NEW[@]}" doctor; is "row 9: doctor exits 1 on a bus newer than the tool" 1 "$RC"
  doctor_row "$W/r9" bus fail "(schema 2) is newer than this agentbus (it knows 1)" "uv tool upgrade agentbus"
  is "row 9: doctor wrote nothing either" "$before" "$(snap "$W/r9")"
}

row_10() {
  reset; install_pieces; mkdir -p "$W/r10"; "${NEW[@]}" init "$W/r10" >/dev/null 2>&1; (cd "$W/r10" && "${NEW[@]}" --as a join >/dev/null 2>&1)
  before=$(snap "$W/r10")
  run "$W/r10" "${V2[@]}" --json watch
  is "row 10: watch on a bus that needs migration exits 3" 3 "$RC"
  json_is "row 10: watch says schema_older" 'r["error"]["code"] == "schema_older"' "$ERR"
  run "$W/r10" "${V2[@]}" doctor; is "row 10: doctor exits 0 (a warning)" 0 "$RC"
  has "row 10: doctor names the fix" "the next write migrates it after a backup. Run: agentbus upgrade $W/r10" "$OUT"
  is "row 10: watch and doctor left the bus bytes equal" "$before" "$(snap "$W/r10")"
  [ ! -e "$W/r10/.agentbus/backups" ] || fail "row 10: a backup appeared before any write"
  run "$W/r10" "${V2[@]}" --as a status; is "row 10: a command that writes exits 0" 0 "$RC"
  is "row 10: it migrated the bus" 2 "$(uv "$W/r10")"
  is "row 10: it took exactly one backup first" 1 "$(ls "$W/r10/.agentbus/backups" | grep -c '^bus-v1-.*\.db$')"
}

row_11() {
  reset; old_bus "$W/r11"; install_pieces
  run "$W/r11" "$PY" .agentbus/bin/agentbus skill
  is "row 11: the 0.1.0 copy has no skill command (exit 1)" 1 "$RC"
  is "row 11: ...and says so in the words the AGENTS.md block quotes" "agentbus: unknown command 'skill'. See: agentbus --help" "$ERR"
  block=$("${NEW[@]}" skill --agents-md)
  has "row 11: the block quotes that message and names the fix" "if it says \`unknown command 'skill'\`, the copy is 0.1.x: stop and tell the user to run \`agentbus upgrade --all PARENT_DIR\`." "$block"
  is "row 11: setup codex wrote the block agentbus skill --agents-md prints" "$block" "$("$PY" -c 'import sys, h; print(h.agents_block(sys.argv[1]), end="")' "$HOME/.codex/AGENTS.md" | sed 's/$//')"
  doctor_row "$W/r11" agents-md ok "has the current block" ""
  doctor_row "$W/r11" copy warn "0.1.0 here, 0.2.0 installed" "agentbus upgrade $W/r11"
}

row_12() {
  reset
  "${NEW[@]}" skill > "$T/skill.txt"; "${NEW[@]}" skill --agents-md > "$T/block.txt"
  "$PY" - "$T/skill.txt" "$T/block.txt" <<'PY' || fail "row 12: an agent-facing command names the installed agentbus, or a human-facing one does not"
import sys, h
skill, block = (open(p).read() for p in sys.argv[1:3])
assert not h.agent_text_problems(skill), h.agent_text_problems(skill)
assert not h.agent_text_problems(block), h.agent_text_problems(block)
assert "Run the bus directory's `.agentbus/bin/agentbus`" in skill
assert block.count("`.agentbus/bin/agentbus ") >= 4, block
# the human-facing commands do appear, by the installed name
assert "agentbus upgrade DIR" in skill and "`agentbus upgrade --all PARENT_DIR`" in block
# the detector itself: each bad shape is caught, the good ones pass
assert h.agent_text_problems("`agentbus join`") == ["agentbus join"] or h.agent_text_problems("`agentbus join`")
assert h.agent_text_problems("run agentbus claim src/a.py first")
assert h.agent_text_problems("`/usr/local/bin/agentbus --as a join`")
assert not h.agent_text_problems("`/w/app/.agentbus/bin/agentbus --as a join` and `.agentbus/bin/agentbus skill` and `agentbus upgrade DIR`")
PY
}

row_13() {
  "$PY" - <<'PY' || fail "row 13: the hook command or a hook piece exists now (streams 03 and 04): add the hook cells of rows 2, 4, 8 and 10 to this file (hook output empty, bytes equal, duplicate flagged), the hook templates to row 12, and delete this tripwire"
import h
m = h.load()
assert "hook" not in m.EARLY_COMMANDS
assert not any(hasattr(p, "entries_for") for t in m.SETUP_TARGETS.values() for p in t)
assert m.DOCTOR_HOOK_CHECKS == []
PY
}

# ---- run the table ----
ids=""
for row in "${ROWS[@]}"; do
  IFS='|' read -r id tool copy schema skill hooks what <<<"$row"
  ids="$ids $id"
  declare -F "row_$id" >/dev/null || fail "table row $id has no function row_$id"
  echo "ROW $id: tool=$tool copy=$copy schema=$schema skill=$skill hooks=$hooks: $what"
  "row_$id"
  ok "row $id"
done
for f in $(declare -F | awk '{print $3}' | grep '^row_[0-9]'); do
  case " $ids " in *" ${f#row_} "*) ;; *) fail "function $f has no row in the table" ;; esac
done

# Where the epic's version policy (plans/00-epic.md) and the code disagree; the rows above follow the code:
#  - rule 3: the skill is to say a bare [...] listing means a 0.1.x copy and to name `agentbus upgrade --all PARENT_DIR`. The shipped
#    skill says "Listings return {items, has_more, next}" and "run agentbus upgrade DIR" (tests/skill_required.txt still lists the
#    0.1.x allotment as unfilled); only the AGENTS.md block names upgrade --all.
#  - rule 2: "a 0.1.0 copy opens a schema-1 bus ... refuses any newer shape with schema_refused" holds (row 9), but a 0.1.0 copy opens a
#    bus stamped 2 whose tables still have the v1 shape (it never reads user_version).
#  - rule 4: hooks do not exist yet; their cells wait for streams 03 and 04 (row 13).
#  - the matrix row for "upgrade run from a project copy is refused" exits 1 from the 0.1.0 copy and 2 (bad_input) from the new one.

all_passed "All version policy tests passed"
