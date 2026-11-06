# First-handoff probe (P3): results

Run on 2026-11-05 from `examples/first-handoff/`. Data, not a verdict.

## Question

Two real headless sessions share a tiny project. Alice (Claude) holds three answers from a partner call that appear in no file. Bob (Codex) cannot write a correct `feed/parse.py` without them. Does Bob's code come out right because of Alice's message, through agentbus, and through a shared Markdown ledger given equal instructions?

## Setup

| What | Value |
| --- | --- |
| agentbus | 0.2.0 at main 24a8cf0, hooks installed by `agentbus setup claude` and `agentbus setup codex` into scratch configs |
| Alice | Claude Code 2.1.318, `--model sonnet`, `claude -p`, `--max-turns 30`, `--max-budget-usd 2`, 10 minute wall cap |
| Bob | codex-cli 0.166.0, `codex exec -s workspace-write --json`, default model (the driver did not record it), 10 minute wall cap, killed at 60 commands |
| OS | macOS, Python 3.9 |

- Alice runs first and finishes; Bob starts afterwards. Same folder, same project. This is a handoff between sessions at different times, not a live question and answer.
- Project: `docs/spec.md` leaves three details open (weight unit, date format, no-zone marker). Alice's prompt holds the answers, drawn from a seed (seeds 1 to 3, the same in every condition). Bob's prompt says Alice has them and not to guess. No sample feed exists. The visible tests check only the field count, so they cannot tell a guess from the answer.
- Alice's ticket is a separate small function (`feed/report.py`). She may edit only that file, its test and the channel, and is told to keep the notes out of every other file.
- Hidden check (`check.py`, run by the driver after Bob exits, never in the project): 12 generated feed lines, each compared field by field. Chance of passing by guessing is about 1 in 125 per seed.
- Conditions: `agentbus` (Alice and Bob named by `AGENTBUS_AGENT`, one channel sentence naming agentbus), `ledger` (the value eval's ledger skill and channel sentence, copied from `scripts/value-eval/tasks.py` at 33bffa5, in `ledger_skill.md`), `none` (control: no channel sentence, no setup).
- Isolation: scratch `HOME`, `CLAUDE_CONFIG_DIR` and `CODEX_HOME` per run, each holding a private copy of the sign-in that is deleted when the session ends. Real sign-in files and the real Claude and Codex settings were hashed before and after the whole run: unchanged. No credential string appears in any kept transcript (scanned).

## Pass rule, counted from the artifacts

A run passes only if all hold:

1. The hidden check passes.
2. Bob's `--json` transcript shows a command whose output holds Alice's message (first or last 25 characters, whitespace ignored; a shared fact counts by its value), before
3. his first write to `feed/parse.py` (a patch, or a command pairing a write verb with that path; a line that only names the file does not count).
4. Bob touched nothing outside the project (no look at Alice's config, the checker or the checkout).

## Results

Times are seconds from the start of Bob's session. "Steps" are Bob's commands and patches.

| Run | Result | Bob's first read of Alice's message | Bob's first write to `feed/parse.py` | Alice | Bob |
| --- | --- | --- | --- | --- | --- |
| agentbus, seed 1 | pass | step 0, 9.4 s: `agentbus status; inbox; skill` | step 3, 35.4 s | 0:20, 7 turns, $0.077 | 0:49, 7 steps |
| agentbus, seed 2 | pass | step 0, 11.7 s: same command | step 4, 37.1 s | 0:20, 10 turns, $0.070 | 0:53, 8 steps |
| agentbus, seed 3 | pass | step 0, 9.3 s: same command | step 3, 35.6 s | 0:22, 10 turns, $0.074 | 0:52, 7 steps |
| ledger, seed 1 | pass | step 1, 6.8 s: `cat COORDINATION.md` | step 7, 24.1 s | 0:14, 5 turns, $0.060 | 0:43, 13 steps |
| ledger, seed 2 | pass | step 1, 6.1 s: `cat COORDINATION.md` | step 5, 32.1 s | 0:17, 8 turns, $0.081 | 0:45, 9 steps |
| ledger, seed 3 | pass | step 0, 5.2 s: `cat COORDINATION.md` (with the spec and the stub) | step 2, 24.3 s | 0:14, 5 turns, $0.059 | 0:44, 6 steps |
| none (control), seed 1 | fail | none | none | 0:12, 7 turns, $0.058 | 0:27, 2 steps |
| none (control), seed 2 | fail | none | none | 0:17, 6 turns, $0.059 | 0:29, 3 steps |
| none (control), seed 3 | fail | none | none | 0:12, 4 turns, $0.061 | 0:33, 3 steps |

agentbus 3 of 3, ledger 3 of 3, control 0 of 3. In all six channel runs the check scored 12 of 12 on id, weight, date and zone and both sets of visible tests passed. Alice changed only her allowed files and the channel, and wrote no answer into a project file; none of Bob's steps looked outside the project.

Tokens (Alice: input counts fresh, cache read and cache write; Bob: input includes cached; both are what each CLI reported):

| Run | Alice input / output | Bob input (cached) / output |
| --- | --- | --- |
| agentbus 1 | 118,067 / 1,249 | 112,449 (96,896) / 1,286 |
| agentbus 2 | 122,942 / 1,605 | 160,570 (147,584) / 1,256 |
| agentbus 3 | 145,824 / 1,707 | 161,021 (136,832) / 1,363 |
| ledger 1 | 58,685 / 1,525 | 135,049 (111,744) / 1,182 |
| ledger 2 | 93,870 / 1,809 | 134,420 (120,960) / 1,334 |
| ledger 3 | 58,492 / 1,486 | 135,628 (112,000) / 1,297 |
| control 1 to 3 | 99,343 / 903; 78,281 / 1,183; 84,472 / 849 | 129,108 (109,440) / 408; 142,435 (100,608) / 492; 205,848 (176,256) / 493 |

What Alice left: in the agentbus runs, one direct note to bob with the three answers, a `done` broadcast and 1 to 3 shared facts (`ctx`); in the ledger runs, a JOIN, 1 or 2 CLAIM and RELEASE pairs, 1 to 3 FACT entries and a DONE. Her messages are in `channel-after-alice.json` of each run (kept outside the repo).

In the control, Bob stopped after two or three commands, wrote nothing and asked for the three answers; the stub still failed the check. So the check cannot be passed without the answers, and Bob does not guess when told not to.

## Failures and harness issues

- No pass-rule failure, no cap hit, no killed session, no non-zero exit among the 9 runs reported above.
- A first batch of the six channel runs also passed, but the grader counted a ledger entry that only named `feed/parse.py` as a write to it, which moved the reported write step earlier. Fixed (the grader now needs a write verb paired with the path) and pinned in `tests/test_first_handoff.sh`; the six runs were repeated and the table above is the repeat. Both batches passed 6 of 6.
- The shell command Bob used to read the bus (`status; inbox; skill`) bundles three commands, so which of the three carried the text is not separated.

## What this does not show

- Only the handoff shape ran: Alice finishes, Bob reads afterwards. A question that Alice answers while Bob waits was not tested.
- The ledger passed as well as the bus. This task does not separate the two on correctness; both left Bob reading the answer before writing.
- The ledger condition has the skill text and the same prompt sentence but no hooks. The agentbus condition has hooks from `agentbus setup`. Claude's hook events appeared in Alice's stream in every agentbus run (6 to 8 per run; the SessionStart text named her as alice). Whether Codex ran its hooks cannot be seen in `codex exec --json`, and `--dangerously-bypass-hook-trust` was on, so the "Hooks need review" approval was not exercised.
- Three seeds per condition, one model pair, one project shape. Differences in steps, time and tokens between the two channels are three samples each.
- Whether the scratch copy of the Claude sign-in refreshed its token was not checked.

## Reproduce

```
python3 examples/first-handoff/drive.py --out ~/probe-out --condition both --runs 3
python3 examples/first-handoff/drive.py --out ~/probe-out --condition none --runs 3
```

Needs `claude` and `codex` signed in (sign-in files are read from `~/.claude/.credentials.json` and `~/.codex/auth.json`, or `CLAUDE_AUTH_FROM` and `CODEX_AUTH_FROM`), about a minute per run; Alice's side cost 6 to 8 cents (Codex's cost was not measured). `tests/test_first_handoff.sh` covers the generator, the check, the prompts and the transcript grader without a model.
