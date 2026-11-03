#!/bin/bash
set -euo pipefail
# CONTRIBUTING's documented test command is the runner, and the runner must fail when a test fails.
# Bug it catches: the old loop ended in `|| break`, so a failing test stopped the loop and the command
# still exited 0. Throwaway test files stand in for the suite.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CONTRIBUTING="$(dirname "$BIN")/../CONTRIBUTING.md"
RUNNER="$(dirname "$BIN")/../tests/run_all.sh"
grep -qxF 'bash tests/run_all.sh' "$CONTRIBUTING" || fail "CONTRIBUTING.md does not tell the reader to run: bash tests/run_all.sh"
mkdir -p "$T/tests"
printf '#!/bin/bash\nexit 0\n' > "$T/tests/test_a_ok.sh"
printf '#!/bin/bash\necho boom\nexit 1\n' > "$T/tests/test_b_fails.sh"
printf '#!/bin/bash\ntouch %s/ran_after_failure\n' "$T" > "$T/tests/test_c_after.sh"
rc=0; bash "$RUNNER" "$T"/tests/test_*.sh >"$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "the runner exited $rc with a failing test, not 1"
[ "$(tail -n 1 "$T/out")" = "FAILED: $T/tests/test_b_fails.sh" ] || fail "the runner's last line was not FAILED: <file>: $(tail -n 1 "$T/out")"
grep -q '^boom$' "$T/out" || fail "the runner did not show the failing file's output"
[ ! -e "$T/ran_after_failure" ] || fail "the runner kept going after a failure"
rc=0; bash "$RUNNER" --keep-going "$T"/tests/test_*.sh >"$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && [ -e "$T/ran_after_failure" ] || fail "--keep-going did not run the file after the failure and exit 1 (rc $rc)"
rm "$T/tests/test_b_fails.sh" "$T/ran_after_failure"
rc=0; bash "$RUNNER" "$T"/tests/test_*.sh >"$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "the runner exited $rc with every test passing"
[ "$(tail -n 1 "$T/out")" = "ALL TESTS PASSED (2 files)" ] || fail "the runner's last line was not ALL TESTS PASSED (2 files): $(tail -n 1 "$T/out")"
# A file that exits 77 is a SKIP: reported, counted apart from passes, and a failure under AGENTBUS_NO_SKIP=1.
printf '#!/bin/bash\necho "SKIP: needs the thing"\nexit 77\n' > "$T/tests/test_e_skip.sh"   # skip-ok: throwaway test file
rc=0; env -u AGENTBUS_NO_SKIP bash "$RUNNER" "$T/tests/test_a_ok.sh" "$T/tests/test_e_skip.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && grep -q "^SKIP $T/tests/test_e_skip.sh (needs the thing)\$" "$T/out" && [ "$(tail -n 1 "$T/out")" = "ALL TESTS PASSED (2 files, 1 skipped)" ] \
  || fail "a skipped file was not reported and counted (rc $rc): $(cat "$T/out")"
rc=0; AGENTBUS_NO_SKIP=1 bash "$RUNNER" "$T/tests/test_a_ok.sh" "$T/tests/test_e_skip.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && [ "$(tail -n 1 "$T/out")" = "FAILED: $T/tests/test_e_skip.sh" ] || fail "AGENTBUS_NO_SKIP=1 did not turn a skip into a failure (rc $rc): $(cat "$T/out")"
# Under AGENTBUS_NO_SKIP=1 only a known platform skip (skip_platform KEY) stays a skip, and EVERY SKIP line must be one.
nosk() { rc=0; AGENTBUS_NO_SKIP=1 bash "$RUNNER" "$T/tests/test_a_ok.sh" "$T/tests/test_f_skip.sh" >"$T/out" 2>&1 || rc=$?; }
skipfile() { printf '#!/bin/bash\n%s\nexit 77\n' "$1" > "$T/tests/test_f_skip.sh"; }   # skip-ok: throwaway test files
skipfile 'echo "SKIP: platform: not-macos (sandbox-exec is macOS only)"'   # skip-ok
nosk
[ "$rc" = 0 ] && [ "$(tail -n 1 "$T/out")" = "ALL TESTS PASSED (2 files, 1 skipped)" ] || fail "a known platform skip failed under AGENTBUS_NO_SKIP=1 (rc $rc): $(cat "$T/out")"
for reason in "platform:needs ws07" "platform: needs ws07" "platform: not-macos-ish" "needs ws07"; do
  skipfile "echo \"SKIP: $reason\""   # skip-ok
  nosk
  [ "$rc" = 1 ] && [ "$(tail -n 1 "$T/out")" = "FAILED: $T/tests/test_f_skip.sh" ] || fail "'$reason' got through AGENTBUS_NO_SKIP=1 (rc $rc): $(cat "$T/out")"
done
skipfile 'echo "SKIP: platform: not-macos"; echo "SKIP: needs ws07"'   # skip-ok
nosk
[ "$rc" = 1 ] || fail "a bad second SKIP line got through AGENTBUS_NO_SKIP=1 (rc $rc): $(cat "$T/out")"
# No test file may print a skip and exit 0: that counts a skipped test as a pass. A skip is skip_test, skip_part
# (which ends in all_passed) or skip_platform, all of which exit 77. Case does not matter; a line that really needs to
# say it (a throwaway test file written by a test) carries the comment `# skip-ok`.
bad=$(grep -n -i -E "(echo|printf)( +-[a-z]+)* +[\"'\\]*(\\n)?skip|skip.*exit 0" "$TESTS_DIR"/test_*.sh | grep -v -E 'skip-ok|skip_(test|part|platform)\(|^[^:]*:[0-9]+:[[:space:]]*#' || true)
[ -z "$bad" ] || fail "a test prints a skip itself instead of calling skip_test/skip_part/skip_platform (or marks the line # skip-ok): $bad"
# --skip-heavy leaves out the files that run other tests again; --only-heavy runs only those.
rc=0; bash "$RUNNER" --skip-heavy tests/test_mutations.sh tests/test_eval_harness.sh >"$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && [ "$(tail -n 1 "$T/out")" = "ALL TESTS PASSED (0 files)" ] || fail "--skip-heavy ran a heavy file (rc $rc): $(cat "$T/out")"
rc=0; bash "$RUNNER" --only-heavy "$T/tests/test_a_ok.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && [ "$(tail -n 1 "$T/out")" = "ALL TESTS PASSED (0 files)" ] || fail "--only-heavy ran an ordinary file (rc $rc): $(cat "$T/out")"
# RUN_ALL_TIMEOUT caps each file: a file that outlives it fails the run with rc 124, and its whole process group is
# gone, a child that ignores SIGTERM too. The cap is the runner's own helper (tests/run_capped.py), never an optional
# binary: it is checked with no timeout or gtimeout on PATH (GitHub's macOS runners have neither; the old runner then
# ran with no cap at all) and with the PATH as it is.
# Bug it catches: a file that hangs holds the whole run until the CI job's own limit, and a child it started outlives it.
NOTMO="$T/notmo"; mkdir -p "$NOTMO"
"$PY" - "$NOTMO" <<'PY'
import os, sys
dest = sys.argv[1]
for d in os.environ["PATH"].split(os.pathsep):
    try:
        names = os.listdir(d or ".")
    except OSError:
        continue
    for n in names:
        src = os.path.join(d, n)
        if n in ("timeout", "gtimeout") or os.path.lexists(os.path.join(dest, n)) or not os.access(src, os.X_OK) or os.path.isdir(src):
            continue
        os.symlink(src, os.path.join(dest, n))
PY
! PATH="$NOTMO" command -v timeout >/dev/null && ! PATH="$NOTMO" command -v gtimeout >/dev/null || fail "the stripped PATH still has timeout or gtimeout"
# alive PID: 0 while PID runs (a zombie counts as gone: it has ended and only waits to be reaped).
alive() { "$PY" -c '
import os, sys
pid = int(sys.argv[1])
try:
    os.kill(pid, 0)
except ProcessLookupError:
    sys.exit(1)
try:
    sys.exit(1 if open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[0] == "Z" else 0)
except OSError:
    sys.exit(0)' "$1"; }
for path in "$NOTMO" "$PATH"; do
  rm -f "$T"/*.pid
  # test_d_slow: ignores SIGTERM itself, as do its children, so only the SIGKILL after the grace ends them.
  printf '#!/bin/bash\ntrap "" TERM\nsleep 30 & echo $! > %s/slow.pid\nsleep 30\n' "$T" > "$T/tests/test_d_slow.sh"
  # test_d_orphan: ends on SIGTERM, but leaves a child that ignores it.
  printf '#!/bin/bash\n(trap "" TERM; exec sleep 30) & echo $! > %s/orphan.pid\nsleep 30\n' "$T" > "$T/tests/test_d_orphan.sh"
  t0=$SECONDS
  rc=0; PATH="$path" RUN_ALL_TIMEOUT=1 bash "$RUNNER" --keep-going "$T/tests/test_d_slow.sh" "$T/tests/test_d_orphan.sh" >"$T/out" 2>&1 || rc=$?
  took=$((SECONDS-t0))
  [ "$rc" = 1 ] && grep -q '^FAIL .*test_d_slow.sh (rc 124)$' "$T/out" && grep -q '^FAIL .*test_d_orphan.sh (rc 124)$' "$T/out" \
    || fail "RUN_ALL_TIMEOUT=1 did not stop a slow test with rc 124 (PATH $([ "$path" = "$NOTMO" ] && echo 'without timeout' || echo 'as it is'), rc $rc): $(cat "$T/out")"
  [ "$took" -lt 15 ] || fail "RUN_ALL_TIMEOUT=1 took ${took}s to stop two slow tests"
  for k in slow orphan; do
    [ -s "$T/$k.pid" ] || fail "test_d_$k.sh never started its child"
    pid=$(cat "$T/$k.pid"); w=0
    while alive "$pid"; do sleep 0.1; w=$((w+1)); [ $w -lt 50 ] || { kill -9 "$pid" 2>/dev/null; fail "test_d_$k.sh's child $pid outlived the cap"; }; done
  done
done
rm -f "$T/tests/test_d_slow.sh" "$T/tests/test_d_orphan.sh"
# A Ctrl-C (SIGINT) to the helper ends the file's whole group, and the helper dies of the signal itself (not just
# exit 130), so the shell running it, run_all.sh, stops too. Ready marker: the file writes int.pid once it runs,
# and the helper's handlers are in place before it starts the file, so the SIGINT can never arrive too early.
printf '#!/bin/bash\nsleep 30 & echo $! > %s/int.pid\nsleep 30\n' "$T" > "$T/int.sh"
"$PY" - "$(dirname "$RUNNER")/run_capped.py" "$T/int.sh" "$T/int.pid" <<'PY' || fail "SIGINT to run_capped.py"
import os, signal, subprocess, sys, time
helper, script, pidfile = sys.argv[1:]
p = subprocess.Popen([sys.executable, helper, "60", "bash", script])
for _ in range(200):
    if os.path.exists(pidfile) and open(pidfile).read().strip():
        break
    time.sleep(0.05)
else:
    sys.exit("FAIL: the file under run_capped.py never started")
p.send_signal(signal.SIGINT)
rc = p.wait(20)
child = int(open(pidfile).read())
def alive(pid):  # a zombie has ended; it only waits to be reaped
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return True
for _ in range(50):
    if not alive(child):
        break
    time.sleep(0.1)
else:
    os.kill(child, signal.SIGKILL)
    sys.exit("FAIL: a child outlived the SIGINT to run_capped.py")
if rc != -signal.SIGINT:
    sys.exit("FAIL: run_capped.py did not die of the SIGINT it was sent (status %r)" % rc)
PY
rc=0; RUN_ALL_TIMEOUT=1.5 bash "$RUNNER" "$T/tests/test_a_ok.sh" >"$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q "^RUN_ALL_TIMEOUT must be a whole number of seconds" "$T/out" || fail "RUN_ALL_TIMEOUT=1.5 was not refused (rc $rc): $(cat "$T/out")"
ok "CONTRIBUTING's test command is the runner: exit 1 at the first failing test with FAILED: <file>, 0 when all pass"

export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
"$PY" - "$BIN" <<'PY'
import argparse, pathlib, re, runpy, shlex, subprocess, sys, tempfile
import os as _os, sys as _sys
_sys.path.insert(0, _os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
(bin_,) = sys.argv[1:]
root = pathlib.Path(bin_).resolve().parent.parent

def help_(*args):
    with tempfile.TemporaryDirectory() as cwd:
        p = subprocess.run([*agentbus_argv(), *args, '--help'], cwd=cwd, capture_output=True, text=True)
    assert p.returncode == 0 and p.stdout, (args, p.stderr)
    return p.stdout

top = help_()
commands = set(re.search(r'\{([^}]+)\}', top).group(1).split(','))
commands -= set(runpy.run_path(bin_, run_name='agentbus_test')['CONTRACT']['hidden'])  # hidden commands have no help
assert len(commands) >= 14, top
helps = {(): top}
for cmd in commands:
    helps[(cmd,)] = help_(cmd)
for cmd in ('ctx', 'log'):
    actions = re.search(r'\{([^}]+)\}', helps[(cmd,)]).group(1).split(',')
    for action in actions:
        helps[(cmd, action)] = help_(cmd, action)
all_flags = set(re.findall(r'--[a-z][a-z-]*', '\n'.join(helps.values())))
checked = []

def check(tokens, source):
    if not tokens:
        return
    prefix = []
    while tokens and tokens[0].startswith('--'):
        flag = tokens.pop(0)
        assert flag in all_flags, (source, flag)
        prefix.append(flag)
        if flag in ('--as', '--up'):
            assert tokens, (source, flag)
            tokens.pop(0)
    if not tokens:
        assert prefix, source
        return
    cmd = tokens.pop(0)
    assert cmd in commands, (source, 'unknown command', cmd)
    key = (cmd,)
    if cmd in ('ctx', 'log') and tokens:
        action = tokens.pop(0)
        key += (action,)
        assert key in helps, (source, 'unknown action', key)
    flags = set(re.findall(r'--[a-z][a-z-]*', helps[key]))
    # Quoted message text is one token and cannot masquerade as an option here.
    for token in prefix + tokens:
        if token.startswith('--'):
            assert token.split('=')[0] in flags, (source, key, token)
    checked.append((source, key))

skill = (root/'skills/agentbus/SKILL.md').read_text()
reference = (root/'docs/reference.md').read_text()
for source, text in [('skill', skill), ('reference', reference)]:
    assert 'Do not truncate a consuming inbox' in text, source
    assert 'inbox --limit N' in text and 'inbox --peek' in text, source
    assert 'A nonzero exit does not imply rollback.' in text, source
activity = "Successful commands run with --as refresh that agent's last-seen, except watch."
assert activity in skill and activity in ' '.join(top.split())
assert 'Omit --as to look without counting as present.' in skill
assert 'Omit --as to look without counting as present.' in ' '.join(top.split())
start = skill.split('## Start\n', 1)[1].split('\n## ', 1)[0]
assert re.search(r'`join`, then `status` and `inbox` \(20 rows each)', start), start
assert 'run `claims`, then' not in skill
assert 'claim itself is the check' in skill
assert len(skill.split()) < 720, 'keep the protocol short (the byte cap, 4800, is pinned in tests/test_skill.sh)'
links = re.findall(r'\]\(([^)]+)\)', skill)
assert links and all(link.startswith('https://github.com/wickdninja/agentbus/blob/main/docs/') for link in links), links

# Inventory comes from argparse itself, including nested ctx/log actions. A table entry for a
# nested action covers its parent; a future command/action must acquire its own documented row.
docs_module = runpy.run_path(bin_, run_name='agentbus_docs')
parser = docs_module['build_parser']()
def inventory(p, prefix=()):
    found = set()
    for action in p._actions:
        if isinstance(action, argparse._SubParsersAction):
            for name, child in action.choices.items():
                path = prefix + (name,)
                found.add(path)
                found.update(inventory(child, path))
    return found
table = reference.split('## JSON output\n', 1)[1].split('\n## ', 1)[0]
documented = set()
for cell in re.findall(r'^\| ([^|]+) \|', table, re.M):
    for form in re.findall(r'`([^`]+)`', cell):
        tokens = tuple(form.split())
        documented.update(tokens[:i] for i in range(1, len(tokens) + 1))
assert inventory(parser) - {(h,) for h in docs_module['CONTRACT']['hidden']} <= documented, ('missing JSON table commands', inventory(parser) - documented)  # hidden commands (hook) are not documented
for snippet in re.findall(r'`([^`]+)`', skill):
    if snippet in ('agentbus', 'AGENTBUS_DB', '.agentbus/bin/agentbus'):
        continue
    check(shlex.split(snippet), ('skill', snippet))

readme = (root/'README.md').read_text()
assert 'ln -s "$PWD/skill" ~/.claude/skills/agentbus' in readme  # valid for the pinned release (v0.1.0); skill/ links to skills/agentbus
assert 'or copy' not in readme
blocks = re.findall(r'```bash\n(.*?)```', readme, re.S)
assert blocks, 'README has no shell examples'
for block in blocks:
    for line in block.replace('\\\n', ' ').splitlines():
        tokens = shlex.split(line, comments=True)
        for i, token in enumerate(tokens):
            if token in ('agentbus', '$bus', '${installed_bus[@]}') or token.endswith('/bin/agentbus'):
                # git clone's destination and the demo's variable assignment are not invocations.
                if tokens[0] in ('cd', 'git') or '=' in token:
                    continue
                check(tokens[i+1:], ('README', line))
                break
assert len(checked) >= 25, checked
# Every install line pins one release tag (never a moving revision), and they all agree. That the tag is
# v<__version__> is a release check (scripts/release_check.py): before the release-prep commit the
# README keeps pointing at the last tag, whose commands are the only ones it may tell a user to run.
version = runpy.run_path(bin_, run_name='agentbus_docs')['__version__']
pins = set()
pinned = 0
# GitHub Releases is the only channel: the name `agentbus` on PyPI belongs to an unrelated project, so no document
# may tell anyone to install the bare name.
BARE = re.compile(r'(?:uv tool install|uv pip install|pipx install|pip3? install)(?:\s+--?[\w-]+)*\s+agentbus(?=[\s`\'"<>~=]|$)')
for name in ['README.md', 'SECURITY.md', 'RELEASING.md', *sorted(str(p.relative_to(root)) for p in (root/'docs').rglob('*.md'))]:
    assert not any(BARE.search(ln) for ln in (root/name).read_text().splitlines() if 'different project' not in ln and 'unrelated' not in ln), (name, 'installs agentbus by its bare name, which is not this project on PyPI')
assert BARE.search('run: pipx install agentbus') and BARE.search('uv tool install --force agentbus') and not BARE.search('pipx install git+https://github.com/wickdninja/agentbus@v0.1.0'), 'the bare-name check is vacuous or too wide'
for name in ['README.md', *sorted(str(p.relative_to(root)) for p in (root/'docs').rglob('*.md'))]:
    for m in re.finditer(r'git\+https://github\.com/wickdninja/agentbus(@[^\s`"\')]*)?', (root/name).read_text()):
        assert m.group(1) and re.fullmatch(r'@v\d+\.\d+\.\d+', m.group(1)), (name, 'install line must pin a release tag', m.group(0))
        pins.add(m.group(1))
        pinned += 1
assert len(pins) == 1, ('install lines pin different tags', pins)
# The README must not send a user to a command the release it pins lacks: tests/released_commands.txt lists
# the commands of each release tag (one line per tag, added by the release-prep commit).
released = {}
for line in (root/'tests/released_commands.txt').read_text().splitlines():
    if line.strip() and not line.startswith('#'):
        tag, cmds = line.split(':', 1)
        released[tag.strip()] = set(cmds.split())
(pin,) = pins
assert pin[1:] in released, (f'tests/released_commands.txt has no line for {pin[1:]}', sorted(released))
for m in re.finditer(r'\bagentbus[ ]+(?:--[a-z-]+[ ]+(?:[A-Za-z0-9_.-]+[ ]+)?)*([a-z][a-z-]*)', readme):
    word = m.group(1)
    assert word not in commands or word in released[pin[1:]], (f'README tells users to run `agentbus {word}`, which {pin[1:]} does not have', m.group(0))
# The README's Update section (U1): staged in RELEASING.md until the pinned release has `update`, then required in the README.
rel = (root/'RELEASING.md').read_text()
m = re.search(r'<!-- readme-update:begin -->\n(.*?)<!-- readme-update:end -->', rel, re.S)
assert m, 'RELEASING.md lost the staged README Update section'
staged = m.group(1).strip()
for must in ('agentbus update', 'AGENTBUS_NO_UPDATE_CHECK=1', 'different project', 'pip install agentbus'):
    assert must in staged, ('the staged README Update section lacks', must)
if 'update' in released[pin[1:]]:
    assert staged in readme, 'the pinned release has `agentbus update`, so the README must carry the staged Update section from RELEASING.md'
else:
    assert 'agentbus update' not in readme, 'the README names agentbus update, which the release it pins lacks'
# The README's first-install lines (the decision): the release wheel's URL once the pinned release publishes a wheel
# (tests/released_wheels.txt), the git+ lines before. scripts/release_check.py --lines is the generator; RELEASING.md
# shows the wheel form for the release-prep commit and must agree with it; the git+ form is documented once, in upgrade.md,
# as the from-source route.
wheels = {ln.split()[0] for ln in (root/'tests/released_wheels.txt').read_text().splitlines() if ln.strip() and not ln.startswith('#')}
def lines_for(tag, *flags):
    return subprocess.check_output([sys.executable, str(root/'scripts/release_check.py'), *flags, '--lines', tag], text=True).splitlines()
gen = lines_for('v9.9.9', '--wheel')
shown = re.search(r'<!-- readme-install:begin -->\n```bash\n(.*?)```\n<!-- readme-install:end -->', rel, re.S)
assert shown and shown.group(1).strip().splitlines() == [x.replace('9.9.9', 'X.Y.Z') for x in gen], 'RELEASING.md shows install lines that scripts/release_check.py --lines does not print'
assert len(lines_for('v9.9.9')) == 2 and all('git+' in x for x in lines_for('v9.9.9')), 'the git+ form of --lines changed'
expected = lines_for(pin[1:])
if pin[1:] in wheels:
    assert all(x in readme for x in expected) and 'git+' not in readme, ('the pinned release publishes a wheel, so the README installs its wheel URL', expected)
else:
    assert all(x in readme for x in expected), ('the README must carry the git+ install lines until the pinned release publishes a wheel', expected)
    assert 'releases/download/' not in readme, 'the README names a wheel URL, but the pinned release is not listed in tests/released_wheels.txt'
upgrade = (root/'docs/how-to/upgrade.md').read_text()
assert upgrade.count('git+https://github.com/wickdninja/agentbus@v') == 1, 'upgrade.md documents the from-source route exactly once'
security = (root/'SECURITY.md').read_text()
assert 'first-install lines' in security and 'Installing from source' in security and 'hatchling' in security, 'SECURITY.md describes the first install and the from-source route'
readme_pinned = len(re.findall(r'git\+https://github\.com/wickdninja/agentbus@|releases/download/v', readme))
assert readme_pinned >= 2, 'README must show both pinned install lines'
assert 'examples/two-agent-handoff.sh' in readme, 'README must link the executable demo'
# Inline command names and forms in the README's table and prose.
inline = re.sub(r'```.*?```', '', readme, flags=re.S)
non_commands = {
    *[l for l in lines_for(pin[1:]) if l.startswith('pipx')],
    'pipx install git+https://github.com/wickdninja/agentbus@v0.1.0',
    'examples/two-agent-handoff.sh',
    'mkdir -p ~/.claude/skills && ln -s "$PWD/skill" ~/.claude/skills/agentbus',
    'AGENTS.md', '.agentbus/bin/agentbus', '/path/to/agentbus/skill/SKILL.md',
    'issue:17', '.git', 'AGENTBUS_DB', '.agentbus/bin/',
}
for snippet in re.findall(r'`([^`]+)`', inline):
    if snippet in non_commands:
        continue
    if snippet.startswith('agentbus '):
        snippet = snippet[len('agentbus '):]
    if snippet == '--up':  # a reference to the option, not an invocation
        assert snippet in all_flags
        continue
    check(shlex.split(snippet), ('README', snippet))

# Scan tracked text, including staged additions. Binary files (NUL or non-UTF-8) are ignored.
def tracked_files():
    # git's list when root is the top of its own work tree; otherwise (no .git, or a copy inside another repo) every
    # file under root, so the scan cannot fail or look at the wrong repository.
    import os
    try:
        top = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--show-toplevel'], stderr=subprocess.DEVNULL).decode().strip()
    except (subprocess.CalledProcessError, OSError):
        top = ''
    if top and os.path.realpath(top) == os.path.realpath(str(root)):
        return subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0')
    found = []
    for dirpath, dirs, names in os.walk(str(root)):
        dirs[:] = [d for d in dirs if d != '.git']
        found += [os.path.relpath(os.path.join(dirpath, n), str(root)).encode() for n in names]
    return found


files = tracked_files()
assert any(name == b'README.md' for name in files), 'empty tracked-file inventory'
for name in files:
    if not name:
        continue
    path = root / name.decode()
    if not path.exists():  # tracked deletion in an uncommitted worktree
        continue
    data = path.read_bytes()
    if b'\0' in data:
        continue
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        continue
    assert chr(0x2014) not in text, f'{path}: contains U+2014'
print(f'Checked {len(checked)} documented command forms against --help')
PY
ok "documented commands, actions and flags exist; README links the executable demo; tracked text has no em-dashes"
all_passed "All docs tests passed"
