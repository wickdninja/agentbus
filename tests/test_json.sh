#!/bin/bash
set -euo pipefail
# Every parser subcommand must produce one strict JSON value, with exact populated shapes.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
cd "$T"
export AGENTBUS_DB="$T/bus.db"
"$PY" - "$BIN" "$T" <<'PY'
import argparse, json, os, pathlib, runpy, subprocess, sys, tempfile
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
bin_, tmp = sys.argv[1:]
parser = runpy.run_path(bin_, run_name='agentbus_test')['build_parser']()
def inventory(p, prefix=()):
    result = set()
    for action in p._actions:
        if isinstance(action, argparse._SubParsersAction):
            for name, child in action.choices.items():
                path = prefix + (name,)
                result.add(path)
                result.update(inventory(child, path))
    return result
seen = set()
def bad_constant(value):
    raise AssertionError('not strict JSON: ' + value)
def j(*args, after=False):
    parsed = parser.parse_args(list(args))
    path = (parsed.cmd,)
    seen.add(path)
    if hasattr(parsed, 'action'):
        seen.add(path + (parsed.action,))
    argv = [*args, '--json'] if after else ['--json', *args]
    with tempfile.TemporaryDirectory() as cwd:
        p = subprocess.run([*agentbus_argv(), *argv], cwd=cwd, capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, (args, p.stderr)
    return json.loads(p.stdout, parse_constant=bad_constant)
def shape(row, **fields):
    assert type(row) is dict and set(row) == set(fields), (row, fields)
    for key, typ in fields.items():
        assert type(row[key]) in (typ if isinstance(typ, tuple) else (typ,)), (key, row[key], typ)
    return row
def array(rows, **fields):
    assert type(rows) is list and rows, rows
    for row in rows:
        shape(row, **fields)
null = type(None)
fact = dict(key=str, value=str, updated_by=str, updated_at=str)
agent = dict(name=str, tool=(str, null), model=(str, null), cwd=str, branch=(str, null), role=(str, null), joined_at=str, last_seen=str)
message = dict(id=int, ts=str, sender=str, recipient=str, kind=str, topic=(str, null), body=str, reply_to=(int, null))
claim = dict(resource=str, agent=str, purpose=(str, null), claimed_at=str, expires_at=str, state=str)
for name in ('a', 'b'):
    shape(j('--as', name, 'join', '--tool', 't'), joined=str, bus=str, goal=(dict, null))
shape(j('--as', 'a', 'post', 'hello'), id=int)
qid = shape(j('--as', 'a', 'post', 'q', '--to', 'b', '--kind', 'question'), id=int)['id']
shape(j('--as', 'b', 'post', 'ans', '--to', 'a', '--reply-to', str(qid), '--kind', 'answer'), id=int)
array(j('--as', 'b', 'inbox'), **message)
assert j('--as', 'b', 'inbox') == []
array(j('who'), **agent)
array(j('read'), **message)
shape(j('--as', 'a', 'ctx', 'set', 'k', 'sha-old'), **fact)
shape(j('--as', 'b', 'ctx', 'set', 'k', 'sha-new'), **fact)
latest = shape(j('ctx', 'get', 'k'), **fact)
assert (latest['value'], latest['updated_by']) == ('sha-new', 'b'), latest
array(j('ctx', 'get'), **fact)
history = j('ctx', 'history', 'k')
array(history, id=int, **fact)
assert [(r['key'], r['value'], r['updated_by']) for r in history] == [('k', 'sha-old', 'a'), ('k', 'sha-new', 'b')], history
assert history[0]['id'] < history[1]['id'], history
for resource in ('src/a.py', 'issue:1'):
    shape(j('--as', 'a', 'claim', resource), resource=str, agent=str, purpose=null, claimed_at=str, expires_at=str,
          auto_released=list, auto_released_count=int)
array(j('claims'), **claim)
assert j('claims', '--stale') == []
assert j('goal') is None
goal = shape(j('--as', 'a', 'goal', 'ship it'), goal=str, set_by=str, set_at=str)
assert goal['goal'] == 'ship it' and goal['set_by'] == 'a', goal
assert shape(j('goal'), goal=str, set_by=str, set_at=str)['goal'] == 'ship it'
status = shape(j('status'), bus=str, goal=dict, agents=list, context=list, claims=list, messages=list)
array(status['agents'], **agent); array(status['context'], **fact)
array(status['claims'], **claim); array(status['messages'], **message)
for args, expected in [(('src/a.py',), ['src/a.py']), (('--all',), ['issue:1']), (('--all',), [])]:
    released = shape(j('--as', 'a', 'release', *args), released=list, released_count=int)
    assert released == {'released': expected, 'released_count': len(expected)}, released
entry = shape(j('--as', 'a', 'log', 'add', 'note', 'detail'), id=int, logged=bool, agent=str, action=str, detail=str)
assert entry['logged'] is True and entry['id'] > 0
logs = j('log', 'show')
array(logs, id=int, ts=str, agent=str, action=str, detail=(str, null))
assert [(r['agent'], r['action'], r['detail']) for r in logs if r['id'] == entry['id']] == [('a', 'note', 'detail')]
shape(j('--as', 'a', 'leave'), left=str, released=list, released_count=int)
repo = pathlib.Path(tmp)/'install'; repo.mkdir()
shape(j('init', str(repo)), directory=str, copy=str, old=str, new=str, exclude_added=bool, gitignore_rule=bool, outer=null)
shape(j('upgrade', str(repo)), directory=str, old=str, new=str)
array(j('buses'), level=int, directory=str, exists=bool)
j('--as', 'b', 'claim', 'watch-fixture')
for after in (False, True):
    for once in ((), ('--once',)):
        snap = shape(j('watch', *once, after=after), bus=str, directory=str, goal=dict, agents=list, claims=list, context=list, messages=list, counts=dict)
        shape(snap['counts'], agents=int, claims=int, messages=int)
        array(snap['agents'], name=str, role=(str, null), last_seen=str, joined_at=str)
        array(snap['claims'], resource=str, agent=str, purpose=null, expires_at=str)
        array(snap['context'], **fact)
        array(snap['messages'], **{k: v for k, v in message.items() if k != 'topic'})
        assert any(m['body'] == 'ans' and m['reply_to'] == qid for m in snap['messages'])
assert seen == inventory(parser), ('untested parser commands', inventory(parser) - seen, 'extra', seen - inventory(parser))
print('PASS: every parser subcommand prints one JSON value with exact keys and types')
# Both shared-option placements must work, including nested actions.
shape(j('--as', 'a', 'join', after=True), joined=str, bus=str, goal=dict)
for args in [('who',), ('read',), ('status',), ('claims',), ('log', 'show'), ('ctx', 'get'), ('--as', 'a', 'inbox'),
             ('--as', 'a', 'post', 'after'), ('--as', 'a', 'ctx', 'set', 'k2', 'v'), ('upgrade', str(repo)), ('buses',)]:
    j(*args, after=True)
with tempfile.TemporaryDirectory() as cwd:
    p = subprocess.run([*agentbus_argv(), 'who'], cwd=cwd, capture_output=True, text=True, check=True)
try:
    json.loads(p.stdout)
except ValueError:
    pass
else:
    raise AssertionError('plain who printed JSON')
print('PASS: --json before or after the subcommand')
PY
