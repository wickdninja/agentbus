#!/bin/bash
set -euo pipefail
# The skill is a file in the repo (skills/agentbus/SKILL.md): its place, its managed marker, its byte
# budget and the sentences other streams are promised room for (tests/skill_required.txt).
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
cd "$T"
ROOT="$(cd "$(dirname "$BIN")/.." && pwd)"
SKILL="$ROOT/skills/agentbus/SKILL.md"

echo "TEST: the skill lives at skills/agentbus/SKILL.md; skill/SKILL.md is only a link to it, so v0.1.0's README line keeps working from a clone"
[ -f "$SKILL" ] && [ ! -L "$SKILL" ] || fail "missing or linked: $SKILL"
[ -L "$ROOT/skill/SKILL.md" ] && [ "$(readlink "$ROOT/skill/SKILL.md")" = "../skills/agentbus/SKILL.md" ] || fail "skill/SKILL.md is not a link to ../skills/agentbus/SKILL.md"
[ "$(ls -A "$ROOT/skill")" = "SKILL.md" ] || fail "skill/ must hold only the link: $(ls -A "$ROOT/skill")"
cmp -s "$ROOT/skill/SKILL.md" "$SKILL" || fail "the link does not reach the skill"
# What a v0.1.0 user does from a clone: ln -s "$PWD/skill" ~/.claude/skills/agentbus
mkdir -p "$T/claude-skills"; ln -s "$ROOT/skill" "$T/claude-skills/agentbus"
head -n 2 "$T/claude-skills/agentbus/SKILL.md" | grep -qx 'name: agentbus' || fail "the old README line's link no longer reaches the skill"
grep -q 'core.symlinks' "$ROOT/docs/how-to/setup.md" || fail "docs/how-to/setup.md must say Windows checkouts need core.symlinks=true (skill/SKILL.md is a link)"
ok "skill moved; the old link target still resolves"

echo
echo "TEST: the skill ends with the managed marker, and fits the byte budget"
[ "$(tail -n 1 "$SKILL")" = "<!-- agentbus:managed -->" ] || fail "last line is not the managed marker: $(tail -n 1 "$SKILL")"
[ "$(grep -c 'agentbus:managed' "$SKILL")" = 1 ] || fail "the marker must appear once"
n=$(wc -c <"$SKILL" | tr -d ' ')
[ "$n" -le 4800 ] || fail "SKILL.md is $n bytes, the cap is 4800"
ok "marker present; $n bytes (cap 4800)"
w=$(wc -w <"$SKILL" | tr -d ' ')
[ "$w" -le 720 ] || fail "SKILL.md is $w words, the cap is 720"
grep -q '^Kinds: note, question, answer, handoff, decision, alert, done\. Assign work with handoff\.' "$SKILL" || fail "the skill must list all seven kinds on one line and say to assign work with handoff"
if grep -q 'Run `release RESOURCE` when finished' "$SKILL"; then fail "the skill still has the release-before-leave step; leave releases everything"; fi
ok "$w words (cap 720); the seven kinds and 'assign work with handoff' on one line; no release-before-leave step"

echo
echo "TEST: every required sentence in tests/skill_required.txt is present and within its byte cap"
"$PY" -I - "$SKILL" "$ROOT/tests/skill_required.txt" <<'PY'
import re, sys
skill = open(sys.argv[1], encoding='utf-8').read()
rows = [l.rstrip('\n') for l in open(sys.argv[2], encoding='utf-8') if l.strip() and not l.startswith('#')]
assert rows, 'no required sentences listed'
for row in rows:
    kind, cap, phrase = row.split('|', 2)
    assert kind in ('s', 'p') and cap.isdigit(), row
    assert skill.count(phrase) == 1, ('phrase must appear exactly once', phrase)
    at = skill.index(phrase)
    if kind == 'p':
        start = skill.rfind('\n\n', 0, at) + 2 if '\n\n' in skill[:at] else 0
        end = skill.find('\n\n', at)
        unit = skill[start:end if end >= 0 else len(skill)]
    else:
        base = max(skill.rfind('\n', 0, at) + 1, 0)
        start = base
        for m in re.finditer(r'[.!?](?=\s)', skill[base:at]):
            start = base + m.end()
        while skill[start] in ' \n':
            start += 1
        m = re.search(r'[.!?](?=\s|$)', skill[at:])
        end = at + m.end() if m else len(skill)
        nl = skill.find('\n', at)
        if nl >= 0 and nl < end:
            end = nl
        unit = skill[start:end]
    size = len(unit.encode('utf-8'))
    assert size <= int(cap), (phrase, 'unit is', size, 'bytes, cap', cap)
print(f'checked {len(rows)} required sentences')
PY
ok "required sentences present and within their caps"

echo
echo "TEST: every command the skill names exists in the parser; coordination commands name .agentbus/bin/agentbus, never a bare agentbus"
"$PY" -I - "$BIN" "$SKILL" <<'PY'
import re, runpy, shlex, sys
bin_, skill_path = sys.argv[1:]
skill = open(skill_path, encoding='utf-8').read()
parser = runpy.run_path(bin_, run_name='agentbus_skill_test')['build_parser']()
commands = set()
for action in parser._actions:
    if hasattr(action, 'choices') and isinstance(action.choices, dict):
        commands |= set(action.choices)
INSTALLED = {'init', 'upgrade', 'setup', 'doctor', 'skill', 'watch', 'schema'}  # the installed tool's own
skip = {'agentbus', 'AGENTBUS_DB', '.agentbus/bin/agentbus'}
for snippet in re.findall(r'`([^`]+)`', skill):
    if snippet in skip:
        continue
    tokens = shlex.split(snippet)
    while tokens and tokens[0].startswith('--') and tokens[0] != '--json':
        tokens = tokens[2:] if tokens[0] in ('--as', '--up') else tokens[1:]
    if tokens and not tokens[0].startswith('-') and tokens[0].isalpha():
        assert tokens[0] in commands, ('the skill names a command that does not exist', snippet)
# A bare `agentbus <command>` in agent-facing text is the installed tool, which is only for the
# human commands. Everything an agent runs for coordination names .agentbus/bin/agentbus.
for m in re.finditer(r'(?<![./\w-])agentbus[ ]+([a-z][a-z-]*)', skill):
    assert m.group(1) not in commands or m.group(1) in INSTALLED, ('bare agentbus used for a coordination command', m.group(0))
print(f'{len(commands)} commands in the parser')
PY
ok "commands named by the skill exist; none is a bare agentbus coordination command"

echo
echo "TEST: agentbus skill prints the bundled skill; with AGENTBUS_EMBED_CHECK=1 it is exactly skills/agentbus/SKILL.md"
agentbus skill >"$T/skill.out"
[ "$(tail -n 1 "$T/skill.out")" = "<!-- agentbus:managed -->" ] || fail "agentbus skill does not end with the managed marker"
head -n 2 "$T/skill.out" | grep -qx 'name: agentbus' || fail "agentbus skill does not start with the skill front matter"
n=$(wc -c <"$T/skill.out" | tr -d ' ')
[ "$n" -le 4800 ] || fail "agentbus skill printed $n bytes, the cap is 4800"
if [ "${AGENTBUS_EMBED_CHECK:-}" = 1 ]; then
  cmp -s "$T/skill.out" "$SKILL" || fail "agentbus skill differs from skills/agentbus/SKILL.md; run python3 scripts/embed_skill.py"
  python3 "$ROOT/scripts/embed_skill.py" --check >"$T/embed.out" 2>&1 || fail "embed_skill.py --check: $(cat "$T/embed.out")"
  grep -qx 'embedded skill is current' "$T/embed.out" || fail "embed_skill.py --check said: $(cat "$T/embed.out")"
fi
ok "agentbus skill prints $n bytes ending with the marker"

echo "TEST: docs/how-to/setup.md's dry-run example is what setup claude --dry-run prints, byte count included"
# Bug it catches: the example said 4,277 bytes after the skill had grown to 4,317.
mkdir -p "$T/dryhome"
got=$(cd "$T" && HOME="$T/dryhome" "${AB[@]}" setup claude --dry-run) || fail "setup claude --dry-run failed: $got"
want=$("$PY" - "$ROOT/docs/how-to/setup.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"```bash\nagentbus setup claude --dry-run\n```\n\n```\n(.*?)```", text, re.S)
assert m, "no dry-run example in docs/how-to/setup.md"
print(m.group(1), end="")
PY
) || fail "could not read the example"
[ "$got" = "$want" ] || fail "docs/how-to/setup.md's dry-run example differs: wanted (the real output)
$got
the doc shows
$want"
ok "the setup how-to's dry-run example matches the real output"

echo
echo "TEST: agentbus skill --agents-md prints the 4-line AGENTS.md block, at most 700 bytes, naming .agentbus/bin/agentbus"
agentbus skill --agents-md >"$T/agents.out"
[ "$(wc -l <"$T/agents.out" | tr -d ' ')" = 4 ] || fail "the AGENTS.md block is not 4 lines: $(cat "$T/agents.out")"
[ "$(wc -c <"$T/agents.out" | tr -d ' ')" -le 700 ] || fail "the AGENTS.md block is over 700 bytes"
head -n 1 "$T/agents.out" | grep -qx '## agentbus' || fail "first line is not '## agentbus'"
grep -qF '`.agentbus/bin/agentbus skill`' "$T/agents.out" || fail "the block does not name .agentbus/bin/agentbus skill"
grep -qF "if it says \`unknown command 'skill'\`, the copy is 0.1.x" "$T/agents.out" || fail "the block lacks the stale-copy rule"
grep -qE '(^|[^./a-z-])agentbus (join|claim|inbox|post|leave)' "$T/agents.out" && fail "a bare agentbus coordination command in the block"
agentbus --json skill --agents-md | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["text"].startswith("## agentbus\n"), d' || fail "--json skill --agents-md"
ok "AGENTS.md block: 4 lines, $(wc -c <"$T/agents.out" | tr -d ' ') bytes"

echo
echo "TEST: embed_skill.py --check fails after the skill file is edited and passes after the script runs"
mkdir -p "$T/tree/scripts" "$T/tree/skills/agentbus" "$T/tree/bin"
cp "$ROOT/scripts/embed_skill.py" "$T/tree/scripts/"; cp "$SKILL" "$T/tree/skills/agentbus/"; cp "$BIN" "$T/tree/bin/agentbus"
python3 "$T/tree/scripts/embed_skill.py" --check >"$T/e.out" 2>&1 || fail "a fresh copy of the tree is not current: $(cat "$T/e.out")"
grep -qx 'embedded skill is current' "$T/e.out" || fail "expected 'embedded skill is current', got: $(cat "$T/e.out")"
sed -i.orig 's/^# agentbus protocol$/# agentbus protocol (edited)/' "$T/tree/skills/agentbus/SKILL.md"
if python3 "$T/tree/scripts/embed_skill.py" --check >"$T/e.out" 2>&1; then fail "--check passed after the skill file was edited"; fi
grep -qF 'embedded skill is stale' "$T/e.out" || fail "the failure did not say the embedded skill is stale: $(cat "$T/e.out")"
python3 "$T/tree/scripts/embed_skill.py" >"$T/e.out" 2>&1 || fail "embed_skill.py failed: $(cat "$T/e.out")"
python3 "$T/tree/scripts/embed_skill.py" --check >"$T/e.out" 2>&1 || fail "--check failed after the script ran: $(cat "$T/e.out")"
"$PY" "$T/tree/bin/agentbus" skill | grep -qx '# agentbus protocol (edited)' || fail "the rewritten copy does not print the edited skill"
ok "--check: stale after an edit, current after the script ran"

echo
echo "TEST: embed_skill.py refuses a skill over the cap or without the marker"
printf 'x%.0s' $(seq 1 4900) >>"$T/tree/skills/agentbus/SKILL.md"
if python3 "$T/tree/scripts/embed_skill.py" >"$T/e.out" 2>&1; then fail "embed_skill.py accepted an oversize skill"; fi
grep -qF 'the cap is 4800' "$T/e.out" || fail "oversize message: $(cat "$T/e.out")"
cp "$SKILL" "$T/tree/skills/agentbus/SKILL.md"; sed -i.orig '$d' "$T/tree/skills/agentbus/SKILL.md"
if python3 "$T/tree/scripts/embed_skill.py" >"$T/e.out" 2>&1; then fail "embed_skill.py accepted a skill with no marker"; fi
grep -qF 'must end with the line' "$T/e.out" || fail "marker message: $(cat "$T/e.out")"
ok "embed_skill.py enforces the cap and the marker"

echo
echo "All skill tests passed"
