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
grep -q '^Kinds: note, question, answer, handoff, decision, alert, done, todo, dropped\. Assign work with handoff\.' "$SKILL" || fail "the skill must list all nine kinds on one line and say to assign work with handoff"
grep -qF 'Promise: `post "WHAT" --kind todo`; close: `post "RESULT" --reply-to ID --kind done`' "$SKILL" || fail "the skill must say how to record a todo and close it"
# Bug it catches: a live trial (fresh agents given only this skill) finished one of three jobs and stopped, never posting the
# other two; one wrote "b.py and validation remain" inside a done, which brief cannot list. Recording your own jobs must be an
# explicit step, with the unfinished ones left as open todos and a dead owner's todo finishable.
grep -qF 'At start, post each job you own as its own todo.' "$SKILL" || fail "the skill must tell an agent to post each job it owns as a todo at start"
grep -qF 'Close each with a linked done' "$SKILL" || fail "the skill must say to close each todo with a linked done"
grep -qF 'every unfinished job must be an open todo' "$SKILL" || fail "the skill must say every unfinished job is left as an open todo before stopping"
grep -qF 'not a line inside a done' "$SKILL" || fail "the skill must say unfinished work is never written inside a done"
grep -qF 'You may finish a todo whose owner left: claim its files as usual (`--from`, below, if a claim is in the way).' "$SKILL" || fail "the skill must say a todo whose owner left may be finished, claiming as usual"
# Bug it catches: the skill said decisions are read with `read --topic decision`, but a decision posted with --kind alone has
# no topic, so that read answered "no messages". The post line it teaches sets the topic the read line asks for.
grep -qF 'post "WHAT" --kind decision --topic decision' "$SKILL" || fail "the skill must teach posting a decision with --topic decision, the topic it reads back"
grep -qF 'read --topic decision' "$SKILL" || fail "the skill must say how decisions are read"
if grep -q 'Run `release RESOURCE` when finished' "$SKILL"; then fail "the skill still has the release-before-leave step; leave releases everything"; fi
ok "$w words (cap 720); the nine kinds and 'assign work with handoff' on one line; no release-before-leave step"

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
echo "TEST: every command the skill names exists in the parser; coordination commands run the installed agentbus, never the project copy"
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
skip = {'agentbus', 'AGENTBUS_DB'}
for snippet in re.findall(r'`([^`]+)`', skill):
    if snippet in skip:
        continue
    tokens = shlex.split(snippet)
    while tokens and tokens[0].startswith('--') and tokens[0] != '--json':
        tokens = tokens[2:] if tokens[0] in ('--as', '--up') else tokens[1:]
    if tokens and not tokens[0].startswith('-') and tokens[0].isalpha():
        assert tokens[0] in commands, ('the skill names a command that does not exist', snippet)
# A hostile clone can ship .agentbus/bin/agentbus, and a gate on git ls-files is bypassed by a differently cased tracked
# folder, a subfolder or an archive with no .git: the skill does not name it at all.
assert '.agentbus/bin/agentbus' not in skill, 'the skill names the project copy'
print(f'{len(commands)} commands in the parser')
PY
ok "commands named by the skill exist; none is run through the project copy"

echo
echo "TEST: agentbus skill prints the bundled skill; with AGENTBUS_EMBED_CHECK=1 it is exactly skills/agentbus/SKILL.md"
agentbus skill >"$T/skill.out"
[ "$(tail -n 1 "$T/skill.out")" = "<!-- agentbus:managed -->" ] || fail "agentbus skill does not end with the managed marker"
head -n 2 "$T/skill.out" | grep -qx 'name: agentbus' || fail "agentbus skill does not start with the skill front matter"
n=$(wc -c <"$T/skill.out" | tr -d ' ')
[ "$n" -le 4800 ] || fail "agentbus skill printed $n bytes, the cap is 4800"
ok "agentbus skill prints $n bytes ending with the marker"
grep -qF 'Delivery can repeat; dedupe by message ID.' "$T/skill.out" || fail "the printed skill lost the sentence that duplicate delivery is possible (inbox is at least once)"
grep -qF 'Use `agentbus` from PATH; if it is not on PATH, stop and tell the user to install it.' "$T/skill.out" || fail "the skill lacks the PATH rule and its refusal wording"
grep -qF 'If a dispatcher assigned an absolute CLI path too, use it.' "$T/skill.out" || fail "the skill lost the sandbox case: a dispatcher that assigns the CLI by absolute path"
grep -qF 'this copy' "$T/skill.out" && fail "the skill says 'this copy', which assumes the project copy"
grep -qF '.agentbus/bin/agentbus' "$T/skill.out" && fail "the skill names the project copy"
grep -qF 'every unfinished job must be an open todo' "$T/skill.out" || fail "the printed skill lost the rule that unfinished jobs stay open todos"
grep -qF 'post "WHAT" --kind decision --topic decision' "$T/skill.out" || fail "the printed skill lost the decision post line"
ok "the printed skill says delivery can repeat"

echo "TEST: docs/how-to/setup.md's dry-run example is what setup claude --dry-run prints, with the byte count read from the real skill"
# Bug it catches: the example said 4,277 bytes after the skill had grown to 4,317. The doc does not pin the count any more
# (every branch that touched SKILL.md edited that one line); the count is checked against the file here and masked for the diff.
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
real=$(wc -c <"$ROOT/skills/agentbus/SKILL.md" | tr -d ' ')
real=$("$PY" -c 'import sys; print(format(int(sys.argv[1]), ","))' "$real")
grep -qF "(${real} bytes)" <<<"$got" || fail "setup claude --dry-run does not name the real skill size ($real bytes): $got"
got=$(sed -E 's/\([0-9][0-9,]* bytes\)/(N bytes)/' <<<"$got")
[ "$got" = "$want" ] || fail "docs/how-to/setup.md's dry-run example differs: wanted (the real output, byte count masked)
$got
the doc shows
$want"
ok "the setup how-to's dry-run example matches the real output"

echo
echo "TEST: agentbus skill --agents-md prints the 4-line AGENTS.md block, at most 700 bytes, running the installed agentbus and never the project copy"
agentbus skill --agents-md >"$T/agents.out"
[ "$(wc -l <"$T/agents.out" | tr -d ' ')" = 4 ] || fail "the AGENTS.md block is not 4 lines: $(cat "$T/agents.out")"
[ "$(wc -c <"$T/agents.out" | tr -d ' ')" -le 700 ] || fail "the AGENTS.md block is over 700 bytes"
head -n 1 "$T/agents.out" | grep -qx '## agentbus' || fail "first line is not '## agentbus'"
grep -qF 'run `agentbus skill` for the full protocol' "$T/agents.out" || fail "the block does not send the agent to agentbus skill from PATH"
grep -qF 'exists in this folder or a parent' "$T/agents.out" && fail "the block's condition tells an agent in a linked worktree elsewhere to ignore a bus that discovery finds"
grep -qF 'If `agentbus buses` finds no bus, ignore this section.' "$T/agents.out" || fail "the block does not let discovery decide whether it applies"
# The block can sit in a user-wide AGENTS.md, and be left behind after an uninstall: a missing tool with no bus folder must not stop an agent.
grep -qF 'If `agentbus` is not on PATH: ignore this section unless `.agentbus/` is in this folder or a parent;' "$T/agents.out" || fail "with no agentbus on PATH and no .agentbus, the block does not say to ignore it"
grep -qF 'if one is, tell the user to install agentbus, never run the copy in it, and carry on with the task.' "$T/agents.out" || fail "the block lacks the no-PATH rule for a folder with a bus"
sed -n 2p "$T/agents.out" | sed 's/ If `agentbus buses`.*//' | grep -qiw 'stop' && fail "the block halts the agent when agentbus is not on PATH"
grep -qF '.agentbus/bin/agentbus' "$T/agents.out" && fail "the block names the project copy"
grep -qF "if it says \`unknown command 'skill'\`, that agentbus is 0.1.x" "$T/agents.out" || fail "the block lacks the stale-install rule"
grep -qF '`agentbus --as NAME join`' "$T/agents.out" || fail "the block lacks the installed-agentbus join command"
grep -qF 'One repo, one bus. Use the one discovery finds. If it looks wrong, run `buses` and ask; do not create another.' "$SKILL" || fail "the skill lacks the one-repo-one-bus rule"
grep -qF 'Set `AGENTBUS_DB` only when a worker cannot discover the bus' "$SKILL" || fail "the skill lacks the AGENTBUS_DB rule"
agentbus --json skill --agents-md | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["text"].startswith("## agentbus\n"), d' || fail "--json skill --agents-md"
ok "AGENTS.md block: 4 lines, $(wc -c <"$T/agents.out" | tr -d ' ') bytes"

echo "TEST: what the block tells an agent to run decides right, from a linked worktree outside the repo and from a folder with no bus"
# Bug it catches: "if .agentbus/ exists in this folder or a parent (otherwise ignore this section)" told an agent in a linked
# worktree elsewhere to ignore a bus that discovery finds.
CB="$T/c-repo"; mkrepo "$CB"; agentbus init "$CB" >/dev/null; CW="$T/c-elsewhere/lane"; mkdir -p "$T/c-elsewhere"; git -C "$CB" worktree add -q "$CW" -b c-lane
[ ! -e "$CW/.agentbus" ] && [ ! -e "$T/c-elsewhere/.agentbus" ] || fail "the worktree has a .agentbus of its own: the case proves nothing"
out=$(cd "$CW" && agentbus buses) || fail "buses from a linked worktree elsewhere failed: $out"
grep -qF "$(cd "$CB" && pwd -P)" <<<"$out" || fail "buses from a linked worktree elsewhere did not find the repo's bus: $out"
mkdir -p "$T/c-none"; rc=0; out=$(cd "$T/c-none" && agentbus buses 2>&1) || rc=$?
[ "$rc" = 3 ] && grep -qF 'no bus here' <<<"$out" || fail "buses in a folder with no bus does not say what the block tells an agent to look for: rc $rc: $out"
ok "buses finds the bus from a linked worktree elsewhere and says no bus here where there is none"

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

# After the text checks, so a mutation of the embedded text fails for what it lost, not only because the copy went stale.
if [ "${AGENTBUS_EMBED_CHECK:-}" = 1 ]; then
  cmp -s "$T/skill.out" "$SKILL" || fail "agentbus skill differs from skills/agentbus/SKILL.md; run python3 scripts/embed_skill.py"
  python3 "$ROOT/scripts/embed_skill.py" --check >"$T/embed.out" 2>&1 || fail "embed_skill.py --check: $(cat "$T/embed.out")"
  grep -qx 'embedded skill is current' "$T/embed.out" || fail "embed_skill.py --check said: $(cat "$T/embed.out")"
  ok "the embedded skill and block match their sources"
fi

echo
echo "TEST: embed_skill.py --release records the hash and --check still says current (the release-prep order)"
# Bug it catches: the block's regex swallowed the history, so --check rebuilt it from the v0.1.0 seed and called every tree stale after --release.
rm -rf "$T/rel"; mkdir -p "$T/rel/scripts" "$T/rel/skills/agentbus" "$T/rel/bin"
cp "$ROOT/scripts/embed_skill.py" "$T/rel/scripts/"; cp "$SKILL" "$T/rel/skills/agentbus/"; cp "$BIN" "$T/rel/bin/agentbus"
sed -i.orig 's/^# agentbus protocol$/# agentbus protocol (a later edit)/' "$T/rel/skills/agentbus/SKILL.md"
python3 "$T/rel/scripts/embed_skill.py" --release >"$T/e.out" 2>&1 || fail "embed_skill.py --release failed: $(cat "$T/e.out")"
python3 "$T/rel/scripts/embed_skill.py" --check >"$T/e.out" 2>&1 || fail "--check failed after --release: $(cat "$T/e.out")"
grep -qx 'embedded skill is current' "$T/e.out" || fail "after --release, expected 'embedded skill is current', got: $(cat "$T/e.out")"
python3 "$T/rel/scripts/embed_skill.py" >"$T/e.out" 2>&1 || fail "a plain run after --release failed: $(cat "$T/e.out")"
[ "$(grep -c '^    "[0-9a-f]\{64\}",$' "$T/rel/bin/agentbus")" -ge 3 ] || fail "a plain run after --release dropped a recorded hash (wanted the v0.1.0 seed, this skill and the AGENTS.md block): $(grep -n '_SHA256_HISTORY = (' -A3 "$T/rel/bin/agentbus")"
ok "--release then --check: current; a plain run keeps the recorded hashes"

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
echo "TEST: the skill does not say read --id cuts a body (a listing cuts at 2 KB; read --id returns the whole body, see test_output.sh)"
! grep -E 'read --id[^.]*(cut|truncat)' "$SKILL" || fail "the skill says read --id cuts a body: $(grep -E 'read --id[^.]*(cut|truncat)' "$SKILL")"
grep -qF 'read --id N` shows the whole body' "$SKILL" || fail "the skill does not say read --id shows the whole message"
ok "read --id is the whole body in the skill's words"

echo
echo "All skill tests passed"
