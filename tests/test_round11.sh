#!/bin/bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"
export HOME="$T/home"; mkdir -p "$HOME"
"$PY" - "$BIN" "$T" <<'PY'
import contextlib, datetime, io, json, os, pathlib, re, runpy, sqlite3, subprocess, sys, tempfile, time
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
bin_, tmp = sys.argv[1:]
sys.path.insert(0, os.environ['TESTS_DIR'])
from term_oracle import rows as physical_rows
base = dict(os.environ, COLUMNS='80', TZ='EST5')
failures = []
def run(*args, db=None, closed=False, json_=False):
    with tempfile.TemporaryDirectory() as cwd:
        env = dict(base, HOME=cwd)
        if db: env['AGENTBUS_DB'] = str(db)
        else: env.pop('AGENTBUS_DB', None)
        return subprocess.run([*agentbus_argv(), *(['--json'] if json_ else []), *args], cwd=cwd, env=env,
                              capture_output=True, text=True, timeout=30,
                              preexec_fn=(lambda: os.close(1)) if closed else None)
def ok(*args, **kw):
    p = run(*args, **kw)
    assert p.returncode == 0, (args, p.stderr)
    return p.stdout
def error(code, *args, **kw):
    p = run(*args, json_=True, **kw)
    assert p.returncode != 0 and p.stdout == '', (args, p)
    assert len(p.stderr.splitlines()) == 1, p.stderr
    obj = json.loads(p.stderr)
    assert set(obj) == {'error'}, obj
    assert obj['error']['code'] == code and obj['error']['message'], obj
    return obj['error']
def check(label, fn):
    try: fn()
    except Exception as e:
        failures.append(label)
        import traceback
        print('FAIL:', label, repr(e))
        traceback.print_exc()
    else: print('PASS:', label)
def fresh(name):
    db = pathlib.Path(tmp)/(name + '.db')
    ok('who', db=db)
    return db

def headers():
    os.environ['TZ'] = 'EST5'; time.tzset()
    m = runpy.run_path(bin_, run_name='round11')
    class Fixed(datetime.datetime):
        @classmethod
        def now(cls, tz=None):
            return cls(2026, 11, 2, 3, 30, tzinfo=datetime.timezone.utc).astimezone(tz)
    m['fmt_msg'].__globals__['datetime'] = Fixed
    row = dict(id=2, ts='2026-11-01T20:19:27Z', sender='codex', recipient='claude', kind='done',
               topic=None, reply_to=1, body='done')
    assert m['fmt_msg'](row).removeprefix(m['HEAD']) == '#2 codex -> claude [done] re #1 · 15:19\n  done'
    row.update(ts='2026-10-31T20:19:27Z', recipient='*', reply_to=None)
    assert m['fmt_msg'](row).removeprefix(m['HEAD']) == '#2 codex -> everyone [done] · Oct 31 15:19\n  done'
    db = fresh('headers'); ok('--as', 'a', 'post', 'hello', db=db)
    stored = json.loads(ok('read', db=db, json_=True))['items'][0]
    assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', stored['ts']), stored
    assert re.search(r'^#1 a -> everyone \[note\] · \d\d:\d\d$', ok('read', db=db), re.M)
check('1 local message headers and UTC JSON', headers)

def listings():
    db = fresh('rows')
    stamp = lambda d: d.strftime('%Y-%m-%dT%H:%M:%SZ')
    now = datetime.datetime.now(datetime.timezone.utc)
    with contextlib.closing(sqlite3.connect(db)) as c:
        for name, role in [('claude', 'planner'), ('codex', 'implementer'), ('reviewer-subagent-security', 'security'), ('nate', '')]:
            c.execute('INSERT INTO agents VALUES(?,?,?,?,?,?,?,?)', (name, 'codex', None, '/', None, role, stamp(now), stamp(now-datetime.timedelta(minutes=2))))
        for i, resource in enumerate(['src/api/', 'tests/', 'docs/']):
            c.execute('INSERT INTO claims VALUES(?,?,?,?,?)', (resource, 'codex', 'review', stamp(now), stamp(now+datetime.timedelta(minutes=120) if i < 2 else now-datetime.timedelta(minutes=1))))
        c.commit()
    for cmd, count in [('who', 4), ('claims', 3)]:
        text = ok(cmd, db=db)
        lines = text.splitlines()
        assert len(lines) == count, text
        assert all(l.startswith('  ') and len(physical_rows(l, 80)) == 1 for l in lines), text
        assert ('seen 2m ago' in text if cmd == 'who' else '1h 59m left' in text and text.count('expired') == 1), text
        section = ok('status', db=db).split('== '+('agents' if cmd == 'who' else 'claims')+'\n', 1)[1].split('\n\n', 1)[0]
        assert section.splitlines() == lines, (section, text)
    expected = {'  '+name.ljust(26)+'  '+role.ljust(11)+'  codex  seen 2m ago'
                for name, role in [('claude','planner'),('codex','implementer'),('reviewer-subagent-security','security'),('nate','')]}
    assert set(ok('who', db=db).splitlines()) == expected, 'columns must fit their data and omit model/branch'
check('2 compact roster and claims including status at 80 columns', listings)

def empty():
    db = fresh('empty')
    for args, text in [(('who',), 'no agents. Join with: agentbus --as NAME join'), (('claims',), 'no claims'),
                       (('claims','--stale'), 'no claims'), (('ctx','get'), 'no facts'), (('read',), 'no messages'), (('log','show'), 'log is empty')]:
        assert ok(*args, db=db) == '  '+text+'\n', args
        assert json.loads(ok(*args, db=db, json_=True)) == {'v': 1, 'items': [], 'has_more': False, 'next': None}, args
    status = ok('status', db=db)
    for text in ['no agents. Join with: agentbus --as NAME join', 'no claims', 'no facts', 'no messages']:
        assert '\n  '+text+'\n' in status, status
    obj = json.loads(ok('status', db=db, json_=True))
    assert all(obj[k] == [] for k in ('agents','claims','context','messages')), obj
check('3 explicit empty human listings and empty JSON arrays', empty)

def hints():
    db = fresh('hints')
    for n in ('a','b'): ok('--as', n, 'join', db=db)
    for i in range(3): ok('--as','a','post',str(i),'--to','b', db=db)
    text = ok('--as','b','inbox','--limit','1', db=db)
    assert text.endswith('  ... 2 more unread; run inbox again\n'), text
    text = ok('read','--limit','1', db=db)
    assert text.startswith('  ... 2 earlier (use --limit)\n#3 '), text
    text = ok('read','--since','0','--limit','1', db=db)
    assert text.startswith('#1 ') and text.endswith('  ... 2 more (use --limit)\n'), text
    text = ok('log','show','--limit','1', db=db)
    assert text.startswith('  ... 1 earlier (use --limit)\n'), text
    text = ok('who','--limit','1', db=db)
    assert text.endswith('  ... 1 more (use --limit)\n'), text
check('4 more hints name unread or earlier rows and appear on the correct side', hints)

def init():
    repo = (pathlib.Path(tmp)/'init').resolve(); repo.mkdir()
    subprocess.run(['git','init','-q',str(repo)], check=True)
    base['COLUMNS'] = '4096'
    text = ok('init',str(repo))
    assert re.search(r'^installed agentbus (?:[0-9a-f]{7}|0\.1\.0)(?: \+dirty)? into '+re.escape(str(repo))+r'/\.agentbus/$', text, re.M), text
    assert f'added .agentbus/ to {repo}/.git/info/exclude (local only; the repo stays clean)\n' in text, text
    assert 'optional: add `.agentbus/` to .gitignore to share that rule\n' in text
    # no Claude Code or Codex setup is detected (a fresh HOME), so the setup commands follow the two steps
    assert text.endswith(f'next: cd {repo}\nnext: .agentbus/bin/agentbus --as YOUR_NAME join\n'
                         'next: agentbus setup claude (teaches Claude Code the protocol)\nnext: agentbus setup codex (teaches Codex the protocol)\n'), text
    assert not re.search(r'[0-9a-f]{40}', text), text
    assert 'outer bus:' not in text
    nested = repo/'nested'; nested.mkdir()
    assert f'outer bus: {repo}\n' in ok('init', str(nested))
    base['COLUMNS'] = '80'
check('5 concise init with safe version and next step', init)

def errors():
    db = fresh('errors')
    hostile = 'lane\n#99 forged\x1b[31m'
    # Identifiers refuse control characters since 0.2 (tests/test_control_chars.sh), so a hostile name, key or
    # resource can only come from an older bus: the hostile rows below are planted with SQLite.
    e = error('not_on_roster','--as','ghost','claim','x',db=db); assert e['agent'] == 'ghost'
    e = error('no_context_key','ctx','get','nokey',db=db); assert e['key'] == 'nokey'
    e = error('no_message','--as','a','post','hi','--reply-to','99',db=db); assert e['id'] == 99
    e = error('not_held','--as','a','release','nothing',db=db); assert e['resource'] == 'nothing'
    error('no_bus','who')
    for args in [('lgo',), ('read','--limit','bad'), ('--as','a','post','hi','--kind','fyi'), ('--as','a','post',''),
                 ('--as','a','claim','../x'), ('--as','a','claim','x','--ttl-min','0')]:
        error('bad_input', *args, db=db)
    ok('--as','b','join',db=db)
    with contextlib.closing(sqlite3.connect(db)) as c:
        c.execute("INSERT INTO agents(name,joined_at,last_seen) VALUES(?,?,?)", (hostile,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'))
        c.execute("INSERT INTO claims(resource,agent,purpose,claimed_at,expires_at) VALUES('x',?,?,'2026-01-01T00:00:00Z','2999-01-01T00:00:00Z')", (hostile,hostile))
        c.commit()
    for resource in ('x','x/y'):
        e = error('claim_conflict','--as','b','claim',resource,db=db)
        assert e['resource'] == resource and e['holder'] == hostile and e['purpose'] == hostile
        assert '\\x0a#99' in e['message'] and '\x1b' not in e['message'], e['message']
        assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', e['expires_at']), e
    with contextlib.closing(sqlite3.connect(db)) as c:
        c.execute('CREATE TABLE foreign_table(x)')
        c.commit()
    error('schema_refused','who',db=db)
    db = fresh('busy')
    c = sqlite3.connect(db); c.execute('SELECT * FROM agents').fetchall()
    try: assert error('busy','claims',db=db)['bus'] == str(db)  # a write open; who reads beside it
    finally: c.close()
    # A failure after commit/output preparation must suppress queued off-roster notices.
    p = run('--as','a','post','committed','--to','absent',db=db,json_=True,closed=True)
    assert p.returncode != 0 and p.stdout == ''
    assert len(p.stderr.splitlines()) == 1 and json.loads(p.stderr)['error']['code'] == 'output_failed', p.stderr
check('7 structured errors: all codes, fields, status, empty stdout and hostile text', errors)

def late_error():
    db = fresh('late-error')
    for i in range(2): ok('--as','a','post',str(i),'--to','b',db=db)
    # Inbox must write before marking read. A later failure cannot retract stdout, but its
    # stderr must still be exactly one JSON error, without an earlier truncation notice.
    shim = '''import runpy,sys
g = runpy.run_path(sys.argv[1], run_name='late_error')['main'].__globals__
def fail_mark(*args): g['die']('injected mark failure')
g['mark_read'] = fail_mark
sys.argv = [sys.argv[1], '--json', '--as', 'b', 'inbox', '--limit', '1']
try: g['main']()
except SystemExit as e:
    print(str(e.code), file=sys.stderr)
    sys.exit(1)
'''
    with tempfile.TemporaryDirectory() as cwd:
        p = subprocess.run([sys.executable, '-c', shim, bin_], cwd=cwd,
                           env=dict(base, HOME=cwd, AGENTBUS_DB=str(db)), capture_output=True, text=True, timeout=30)
    assert p.returncode != 0 and len(json.loads(p.stdout)['items']) == 1, p
    assert len(p.stderr.splitlines()) == 1, p.stderr
    assert json.loads(p.stderr)['error']['code'] == 'ack_failed', p.stderr
    assert len(json.loads(ok('--as','b','inbox','--peek',json_=True,db=db))['items']) == 2
check('7b late inbox failure has one JSON diagnostic and leaves messages unread', late_error)

def retries():
    db = fresh('retries')
    args = ('--as','a','post','payload','--request-id','token')
    assert json.loads(ok(*args,db=db,json_=True)) == {'id':1}
    assert json.loads(ok(*args,db=db,json_=True)) == {'id':1,'duplicate':True}
    assert ok(*args,db=db) == 'posted #1 to everyone [note] (already posted)\n'
    for extra in [('changed',), ('payload','--to','b'), ('payload','--kind','done'),
                  ('payload','--topic','new'), ('payload','--reply-to','1')]:
        error('request_id_reused','--as','a','post',*extra,'--request-id','token',db=db)
    assert json.loads(ok('--as','b','post','payload','--request-id','token',db=db,json_=True)) == {'id':2}
    for expected in (3,4): assert json.loads(ok('--as','a','post','payload',db=db,json_=True)) == {'id':expected}
    p = run('--as','a','post','once','--request-id','closed',db=db,closed=True)
    assert p.returncode != 0 and 'stdout is closed' in p.stderr, p
    assert json.loads(ok('--as','a','post','once','--request-id','closed',db=db,json_=True)) == {'id':5,'duplicate':True}
    with contextlib.closing(sqlite3.connect(db)) as c:
        assert c.execute('SELECT request_id FROM messages ORDER BY id').fetchall() == [('token',),('token',),(None,),(None,),('closed',)]
        try: c.execute("INSERT INTO messages(ts,sender,body,request_id) VALUES('t','a','other','token')")
        except sqlite3.IntegrityError: pass
        else: raise AssertionError('unique sender/request_id index missing')
    assert len(json.loads(ok('read',db=db,json_=True))['items']) == 5
check('8 idempotent retry, payload conflicts, sender scope, unique index and closed stdout', retries)
if failures: sys.exit(1)
PY
echo "All round 11 tests passed"
