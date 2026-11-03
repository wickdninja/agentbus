#!/bin/bash
set -euo pipefail
# Every parser subcommand must produce one strict JSON value, with exact populated shapes.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
cd "$T"
export AGENTBUS_DB="$T/bus.db"; unset XDG_CACHE_HOME XDG_STATE_HOME   # update --check reads the cache under HOME
"$PY" - "$BIN" "$T" <<'PY'
import argparse, json, os, pathlib, runpy, subprocess, sys, tempfile
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
bin_, tmp = sys.argv[1:]
json_module = runpy.run_path(bin_, run_name='agentbus_test')
parser = json_module['build_parser']()
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
def listing(r, **fields):
    """A listing is an envelope: the contract version, the rows, whether rows were left out, a cursor."""
    assert type(r) is dict and set(r) == {'v', 'items', 'has_more', 'next'} and r['v'] == 1, r
    assert r['has_more'] is False and r['next'] is None, r
    array(r['items'], **fields)
    return r['items']
null = type(None)
fact = dict(key=str, value=str, updated_by=str, updated_at=str)
agent = dict(name=str, tool=(str, null), model=(str, null), cwd=str, branch=(str, null), role=(str, null), joined_at=str, last_seen=str)
message = dict(id=int, ts=str, sender=str, recipient=str, kind=str, topic=(str, null), body=str, reply_to=(int, null))
claim = dict(resource=str, agent=str, purpose=(str, null), claimed_at=str, expires_at=str, state=str)
for name in ('a', 'b'):
    joined = shape(j('--as', name, 'join', '--tool', 't'), joined=str, bus=str, goal=(dict, null), agentbus=str, contract=int)
    assert joined['contract'] == 1
shape(j('--as', 'a', 'post', 'hello'), id=int)
qid = shape(j('--as', 'a', 'post', 'q', '--to', 'b', '--kind', 'question'), id=int)['id']
shape(j('--as', 'b', 'post', 'ans', '--to', 'a', '--reply-to', str(qid), '--kind', 'answer'), id=int)
listing(j('--as', 'b', 'inbox'), **message)
assert j('--as', 'b', 'inbox')['items'] == []
listing(j('who'), **agent)
listing(j('read'), **message)
shape(j('--as', 'a', 'ctx', 'set', 'k', 'sha-old'), unchanged=bool, **fact)
shape(j('--as', 'b', 'ctx', 'set', 'k', 'sha-new'), unchanged=bool, **fact)
latest = shape(j('ctx', 'get', 'k'), **fact)
assert (latest['value'], latest['updated_by']) == ('sha-new', 'b'), latest
listing(j('ctx', 'get'), **fact)
history = listing(j('ctx', 'history', 'k'), id=int, **fact)
assert [(r['key'], r['value'], r['updated_by']) for r in history] == [('k', 'sha-old', 'a'), ('k', 'sha-new', 'b')], history
assert history[0]['id'] < history[1]['id'], history
for resource in ('src/a.py', 'issue:1'):
    shape(j('--as', 'a', 'claim', resource), resource=str, agent=str, purpose=null, claimed_at=str, expires_at=str,
          auto_released=list, auto_released_count=int)
listing(j('claims'), **claim)
assert j('claims', '--stale')['items'] == []
assert j('goal') is None
goal = shape(j('--as', 'a', 'goal', 'ship it'), goal=str, set_by=str, set_at=str, unchanged=bool)
assert goal['goal'] == 'ship it' and goal['set_by'] == 'a', goal
assert shape(j('goal'), goal=str, set_by=str, set_at=str)['goal'] == 'ship it'
status = shape(j('status'), bus=str, goal=dict, agents=list, context=list, claims=list, messages=list, omitted=dict)
shape(status['omitted'], agents=int, context=int, claims=int, messages=int)
array(status['agents'], **agent); array(status['context'], **fact)
array(status['claims'], **claim); array(status['messages'], **message)
for args, expected in [(('src/a.py',), ['src/a.py']), (('--all',), ['issue:1']), (('--all',), [])]:
    released = shape(j('--as', 'a', 'release', *args), released=list, released_count=int)
    assert released == {'released': expected, 'released_count': len(expected)}, released
entry = shape(j('--as', 'a', 'log', 'add', 'note', 'detail'), id=int, logged=bool, agent=str, action=str, detail=str)
assert entry['logged'] is True and entry['id'] > 0
logs = listing(j('log', 'show'), id=int, ts=str, agent=str, action=str, detail=(str, null))
assert [(r['agent'], r['action'], r['detail']) for r in logs if r['id'] == entry['id']] == [('a', 'note', 'detail')]
shape(j('--as', 'a', 'leave'), left=str, released=list, released_count=int)
repo = pathlib.Path(tmp)/'install'; repo.mkdir()
shape(j('init', str(repo)), directory=str, copy=str, old=str, new=str, exclude_added=bool, gitignore_rule=bool, outer=null)
shape(j('upgrade', str(repo)), directory=str, old=str, new=str, schema_old=(int, type(None)), schema_new=(int, type(None)), backup=(str, type(None)))
# update --check answers from a good cache entry under an hour old (no request)
ucache = pathlib.Path(os.environ['HOME'])/('Library/Caches/agentbus' if sys.platform == 'darwin' else '.cache/agentbus')
ucache.mkdir(parents=True, mode=0o700)
(ucache/'release-check.json').write_text(json.dumps({'v': 1, 'checked_at': int(__import__('time').time()), 'ok': True, 'reason': None,
                                                     'retry_after': None, 'stable': '0.9.0', 'pre': None, 'notified': None}))
(ucache/'release-check.json').chmod(0o600)
upd = shape(j('update', '--check'), running=str, latest=(str, null), update_available=bool, install=dict, argv=null, commands=list, download=(dict, null), notes=(str, null))
assert upd['update_available'] is True and upd['latest'] == '0.9.0' and set(upd['install']) == {'method', 'url'}, upd   # a clone here, another method when run installed
schema = shape(j('schema'), contract=int, agentbus=str, commands=dict, global_args=list, objects=dict, error_fields=dict, errors=dict, exit_codes=dict, env=dict)
assert schema['contract'] == 1 and 'post' in schema['commands']
shape(j('schema', 'post'), contract=int, agentbus=str, commands=dict, global_args=list, objects=dict, error_fields=dict, errors=dict, exit_codes=dict, env=dict)
listing(j('buses'), level=int, directory=str, exists=bool, copy_version=(str, null), stale=bool)
assert shape(j('skill'), text=str)['text'].startswith('---\nname: agentbus\n')
assert shape(j('skill', '--agents-md'), text=str)['text'].startswith('## agentbus\n')
setup = shape(j('setup', 'claude', '--dry-run'), target=str, scope=str, dry_run=bool, changes=list)
array(setup['changes'], path=str, action=str, detail=str)
doctor = shape(j('doctor'), agentbus=str, path=str, contract=int, checks=list, fail=int, warn=int)
assert doctor['checks'], doctor
for check in doctor['checks']:   # scope is there for the checks of a user or project file
    shape(check, id=str, status=str, detail=str, fix=(str, null), hint=(str, null), **({'scope': str} if 'scope' in check else {}))
j('--as', 'b', 'claim', 'watch-fixture')
for after in (False, True):
    for once in ((), ('--once',)):
        snap = shape(j('watch', *once, after=after), bus=str, directory=str, goal=dict, agents=list, claims=list, context=list, messages=list, unread=dict, counts=dict, omitted=dict)
        shape(snap['omitted'], agents=int, context=int, claims=int, messages=int)
        shape(snap['counts'], agents=int, claims=int, messages=int)
        array(snap['agents'], name=str, role=(str, null), last_seen=str, joined_at=str)
        array(snap['claims'], resource=str, agent=str, purpose=null, expires_at=str)
        array(snap['context'], **fact)
        array(snap['messages'], **message)  # topic too (watch v2, additive)
        assert snap['unread'] == {'b': 0}, snap['unread']
        assert any(m['body'] == 'ans' and m['reply_to'] == qid for m in snap['messages'])
visible = inventory(parser) - {(h,) for h in json_module['CONTRACT']['hidden']}  # hidden commands (hook) have no JSON result
assert seen == visible, ('untested parser commands', visible - seen, 'extra', seen - visible)
print('PASS: every parser subcommand prints one JSON value with exact keys and types')
# Both shared-option placements must work, including nested actions.
shape(j('--as', 'a', 'join', after=True), joined=str, bus=str, goal=dict, agentbus=str, contract=int)
for args in [('who',), ('read',), ('status',), ('claims',), ('log', 'show'), ('ctx', 'get'), ('--as', 'a', 'inbox'),
             ('--as', 'a', 'post', 'after'), ('--as', 'a', 'ctx', 'set', 'k2', 'v'), ('upgrade', str(repo)), ('buses',), ('schema',)]:
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
echo "All JSON tests passed"
