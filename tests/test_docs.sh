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

skill = (root/'skill/SKILL.md').read_text()
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
assert re.search(r'`join`, then `status --limit 20` and `inbox --limit 20`', start), start
assert 'run `claims`, then' not in skill
assert 'claim itself is the check' in skill
assert len(skill.split()) < 650, 'keep the protocol short'
links = re.findall(r'\]\(([^)]+)\)', skill)
assert links and all(link.startswith('https://github.com/wickdninja/agentbus/blob/main/docs/') for link in links), links

# Inventory comes from argparse itself, including nested ctx/log actions. A table entry for a
# nested action covers its parent; a future command/action must acquire its own documented row.
parser = runpy.run_path(bin_, run_name='agentbus_docs')['build_parser']()
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
assert inventory(parser) <= documented, ('missing JSON table commands', inventory(parser) - documented)
for snippet in re.findall(r'`([^`]+)`', skill):
    if snippet in ('agentbus', 'AGENTBUS_DB', '.agentbus/bin/agentbus'):
        continue
    check(shlex.split(snippet), ('skill', snippet))

readme = (root/'README.md').read_text()
assert 'ln -s "$PWD/skill" ~/.claude/skills/agentbus' in readme
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
assert 'examples/two-agent-handoff.sh' in readme, 'README must link the executable demo'
# Inline command names and forms in the README's table and prose.
inline = re.sub(r'```.*?```', '', readme, flags=re.S)
non_commands = {
    'pipx install git+https://github.com/wickdninja/agentbus',
    'examples/two-agent-handoff.sh',
    'mkdir -p ~/.claude/skills && ln -s "$PWD/skill" ~/.claude/skills/agentbus',
    'AGENTS.md', '.agentbus/bin/agentbus', '/path/to/agentbus/skill/SKILL.md',
    'issue:17', '.git', 'AGENTBUS_DB', '.agentbus/bin/',
}
for snippet in re.findall(r'`([^`]+)`', inline):
    if snippet in non_commands:
        continue
    if snippet == '--up':  # a reference to the option, not an invocation
        assert snippet in all_flags
        continue
    check(shlex.split(snippet), ('README', snippet))

# Scan tracked text, including staged additions. Binary files (NUL or non-UTF-8) are ignored.
files = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0')
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
