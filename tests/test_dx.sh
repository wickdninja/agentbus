#!/bin/bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
export AGENTBUS_DB="$T/bus.db"
agentbus --as claude join >/dev/null
agentbus join --as codex >/dev/null
[ "$(agentbus --as claude post handoff --to codex --kind handoff 2>"$T/err")" = 'posted #1 to codex [handoff]' ] || fail "addressed confirmation"
[ ! -s "$T/err" ] || fail "on-roster notice"
[ "$(agentbus post broadcast --as claude --kind answer)" = 'posted #2 to everyone [answer]' ] || fail "broadcast confirmation"
[ "$(agentbus --as claude post queued --to absent 2>"$T/err")" = 'posted #3 to absent [note]' ] || fail "off-roster confirmation"
[ "$(cat "$T/err")" = 'agentbus: absent is not on the roster; the message waits for that name. On the roster: claude, codex.' ] || fail "off-roster notice: $(cat "$T/err")"
[ "$(json_ok agentbus --as claude post json --to codex --json | "$PY" -c 'import json,sys; assert json.load(sys.stdin)=={"contract":1,"id":4,"warnings":[]}; print("ok")')" = ok ] || fail "post JSON changed"
ok "post names recipients and kinds; absent names get a stderr notice; JSON retains id"

before=$(agentbus --as codex --json inbox --peek)
after=$(agentbus inbox --peek --as codex --json)
[ -n "$before" ] && [ "$before" = "$after" ] || fail "identity placement differs"
printf '%s' "$after" | "$PY" -c 'import json,sys; r=json.load(sys.stdin)["items"]; assert [m["id"] for m in r]==[1,2,4]' || fail "wrong identity inbox"
unset AGENTBUS_DB
agentbus init "$T" >/dev/null
mkdir "$T/inner"; agentbus init "$T/inner" >/dev/null
cd "$T/inner"
agentbus --up 1 --as worker join >/dev/null
before=$(agentbus --up 1 --as worker --json who)
after=$(agentbus who --up 1 --as worker --json)
# last_seen can tick between calls, so compare stable roster fields.
printf '%s\n%s' "$before" "$after" > "$T/rosters"
"$PY" - "$T/rosters" "$T" <<'PY'
import json, pathlib, sys
text=pathlib.Path(sys.argv[1]).read_text(); dec=json.JSONDecoder()
a, end=dec.raw_decode(text); b=dec.decode(text[end:])
a, b = a['items'], b['items']
assert len(a)==len(b)==1 and a[0]['name']=='worker'
for row in (a[0], b[0]): row.pop('last_seen')
assert a==b
assert (pathlib.Path(sys.argv[2])/'.agentbus/bus.db').is_file()
PY
agentbus ctx --up 1 --as worker set k value >/dev/null
[ "$(agentbus ctx get k --up 1 --as worker)" = '  value' ] || fail "nested flags overwrite globals"
agentbus log --up 1 --as worker add check detail >/dev/null
outof agentbus log show --up 1 --json | "$PY" -c 'import json,sys; assert any(r["detail"]=="detail" for r in json.load(sys.stdin)["items"])' || fail "nested log flags"
ok "identity and bus level before and after commands, including ctx/log actions"

export AGENTBUS_DB="$T/bus.db"
agentbus --as claude claim src/api/ --purpose review >/dev/null
# the message names the expiry in local time (HH:MM today, Mon D HH:MM another day), worked out here from the stored ISO time
when() { agentbus --json claims | "$PY" -c '
import json, os, sys, time
from datetime import datetime, timezone
t = datetime.strptime(json.load(sys.stdin)["items"][0][sys.argv[1]], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone()
pin = os.environ.get("AGENTBUS_TEST_NOW")   # a test-only hook: the clock starts at this UTC time
today = (datetime.strptime(pin, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone() if pin else datetime.now()).date()
print(t.strftime("%H:%M") if t.date() == today else t.strftime("%b ") + str(t.day) + t.strftime(" %H:%M"))' "$1"; }
exp=$(when expires_at); since=$(when claimed_at)
refusal_rest() { echo "In a shared checkout, leave it until claude answers or releases it; ask: agentbus --as codex post QUESTION --to claude --kind question. On a separate branch, post what you are touching; the merge decides."; }
expect_fail "src/api/ is claimed by claude since $since until $exp (purpose: \"review\"). $(refusal_rest)" agentbus --as codex claim src/api/
expect_fail "src/api/a.py overlaps src/api/, claimed by claude since $since until $exp (purpose: \"review\"). $(refusal_rest)" agentbus --as codex claim src/api/a.py
ok "claim conflicts name holder, expiry, and recovery"

"$PY" - <<'PY'
import subprocess, sys, tempfile
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
def help_(*args):
    with tempfile.TemporaryDirectory() as cwd:
        p = subprocess.run([*agentbus_argv(), *args, '--help'], cwd=cwd, capture_output=True, text=True)
    assert p.returncode == 0 and p.stdout, (args, p.stderr)
    text = ' '.join(p.stdout.split())
    assert text.index('--as') < text.index('--json') < text.index('--up'), text
    return text
checks = {
    (): ['Coordinate agents in one local workspace: messages, file claims, and shared facts.', 'Your agent identity; overrides AGENTBUS_AGENT.', 'Select the Nth outer bus (default 0). AGENTBUS_DB takes precedence.', 'Print successful command results as JSON. Check exit status; errors use stderr.', 'Start:', 'Loop:', 'Finish:', 'Humans: agentbus watch', 'Env: AGENTBUS_AGENT', 'AGENTBUS_DB'],
    ('post',): ['A name not on the roster still gets the message, with a warning.', 'does not choose the recipient.', 'Message kind: note, question, answer, handoff, decision, alert, done. Default: note.', 'Optional topic label, filterable with read --topic.'],
    ('join',): ['Tool running this session.', 'Model running this session.', 'Working directory for this session.', 'Branch for this session.', 'What you do here (shown in who/watch).', 'Rejoin a name active'],
    ('release',): ['Resource to release; use the spelling from claims.'],
    ('ctx','set'): ['Set a shared fact and record its history.'],
    ('ctx','get'): ['Get a fact, or list all facts.'],
    ('ctx','history'): ['Show the history of a fact.'],
    ('log','add'): ['Append an activity log entry.'],
    ('log','show'): ['Show recent activity log entries.'],
    ('claim',): ['Claim lifetime in minutes: 1-10080; default 120. Claim again to renew.'],
    ('read',): ['Maximum messages; default 50. Use -1 for all.', 'Show this one message, whole (a listing cuts a body at 2 KB).'],
    ('status',): ['At most this many rows in each section (agents, facts, claims, the latest messages); default 20. Use -1 for all.'],
    ('init',): ['Directory to initialize, created (with its parents) if missing; default current directory. Run from the installed tool or source clone.'],
}
for args, expected in checks.items():
    text = help_(*args)
    for phrase in expected: assert phrase in text, (args, phrase, text)
for args in [('who',), ('inbox',), ('claims',), ('ctx', 'get'), ('ctx', 'history'), ('log', 'show'), ('status',)]:
    assert 'Use -1 for all.' in help_(*args), args
for args, usage in [(('ctx','set'),'KEY VALUE'), (('ctx','get'),'[KEY]'), (('ctx','history'),'KEY'), (('log','add'),'ACTION DETAIL'), (('log','show'),'')]:
    assert ('usage: agentbus ' + ' '.join(args) + ' ' + usage).strip() in help_(*args), args
PY
ok "help describes routing, limits, identity, installation, and action-specific usage"

out=$(agentbus lgo 2>&1 >/dev/null || true)
case "$out" in "agentbus: unknown command 'lgo'. Did you mean log? Commands: join, leave, who, "*", brief, demo. See: agentbus --help") ;; *) fail "unknown command hint: $out" ;; esac
expect_fail "unknown kind 'fyi'; use one of: note, question, answer, handoff, decision, alert, done" agentbus --as claude post hi --kind fyi
expect_fail "claude was active less than a minute ago" agentbus --as claude join
ok "typos get concise suggestions, invalid kinds echo their value, and a recent join reads naturally"
