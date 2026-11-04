# Agent evals

Do Claude Code and Codex agents complete the agentbus protocol? The suite proves the tool works; these evals measure whether agents use it correctly, graded on what they did.

## Run one

```bash
bash scripts/agent-eval.sh --dry-run --all                    # prints: agent invocations: 72 (16 cells x 3 attempts)
bash scripts/agent-eval.sh --go --cell claude skill resume    # one cell, the end-of-wave check
bash scripts/agent-eval.sh --go --all                         # the full matrix, before a release candidate
```

A run prints how many agent invocations it will make before it starts. Real runs spend tokens, so they need `--go`; without it the script prints the count and stops. `AGENTBUS_CMD` names the installed command (default: `agentbus` on PATH). Traces stay in `eval-out/`, which is local and ignored: they can hold anything an agent printed, so none go in the repo.

## What a cell is

A cell is an agent (`claude`, `codex`), an arm (`skill`: only the skill or the AGENTS.md block; `hooks`: the skill plus the hooks `agentbus setup` installs) and a scenario. Each attempt gets a temp HOME and a fresh project with a bus. A cell passes with at least 2 of 3 attempts. The full matrix is 16 cells and ends `eval complete: 16 of 16 cells pass`.

| Scenario | The agents are told | Passes when |
| --- | --- | --- |
| `handoff` | alice hands the "add a /health route" task to bob; bob checks for work and finishes it | the bus holds one handoff from alice to bob and a done from bob; bob's claim is released and both left; bob's `inbox` came before his first edit; the project's test passes |
| `conflict` | alice and bob both add a file to `lib/` and a line to `lib/__init__.py`, at the same time | neither edited under `lib/` while the other held a claim; each claimed before editing; an edit after a refused claim came after the holder's release; the bus log agrees; both files exist and neither overwrote the other |
| `worktrees` | lead is told only to coordinate two lanes across worktrees that sit in a folder apart from the project (no word of any bus) | every join and message that succeeded is on the project's own bus; each lane was told something; lead left; lead never ran `init`; no other `.agentbus` exists anywhere in the attempt |
| `resume` | carol is told "Continue the work" on a bus with a goal, 3 unread messages and 1 expired claim | `status` and `inbox` ran before her first edit; she did not edit `src/held/` (another agent's live claim); the final reply names the goal; the task's test passes; she wrote the staging token from the handoff nowhere on the bus |

## How an attempt is graded

Three sources, none of them an agent's own account of itself:

1. The harness's ordered tool trace: every tool call in call order, with receipt times (`scripts/agent-eval/normalize.py` reads Claude Code `--output-format stream-json` and `codex exec --json`). Order comes from the trace, never from file mtimes.
2. Bus facts read by SQL only: messages, claims, who is still on the roster, the log. The bus cannot show what an agent read or edited, because inbox consumption and file edits are not recorded in it.
3. Functional checks in the project: does the route answer, do both files exist.

`tests/test_eval_graders.sh` runs every grader on synthetic traces it must fail (an early edit, an edit before `inbox`, an `inbox` after the first edit, a late release with an earlier conflicting edit, a missing functional result, an empty trace and more), so a lenient grader is caught in CI. `tests/test_eval_harness.sh` runs the whole harness against a stand-in agent, with no tokens.

## What is not verified yet

The two real harnesses' command lines (`harness_argv` in `scripts/agent-eval/run.py`) and event formats (`normalize.py`) follow the documented shapes but have not been run against a live agent: the baseline run is their first test. If a cell fails with "no edit" or an empty trace, check the raw trace in `eval-out/` before blaming the agent. The `hooks` arm runs `agentbus setup claude|codex --scope project` and reports `unsupported` until those commands exist.

## Record results

Append the table to `docs/evals/<version>.md` with `--record docs/evals/0.2.0.md`. The skill-only arm on v0.1.0 is the baseline; the hooks arm must be no worse than it in every cell.
