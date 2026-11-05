# Live acceptance: agentbus v0.2.0 in real sessions

Run on 2026-11-05 against the released v0.2.0 wheel (`SHA256SUMS` checked) installed in a throwaway venv. Every run used a scratch `HOME`, scratch `CLAUDE_CONFIG_DIR` / `CODEX_HOME` and a scratch project with its own bus. The wheel's `agentbus.py` is byte-identical to `bin/agentbus` in the checkout the two e2e scripts ran from.

| What | Version |
| --- | --- |
| agentbus | 0.2.0 (release wheel) |
| Claude Code | 2.1.318, `--model sonnet` (claude-sonnet-5-5), headless `claude -p` |
| Codex | codex-cli 0.166.0, default model gpt-6.1-sol |
| OS, Python | macOS (Darwin 27.0.0), Python 3.9.6 |

Signing in: a scratch config cannot see the real sign-in, so only the Claude sign-in token block and the Codex `auth.json` were copied (mode 600) into the scratch config folders and deleted afterwards. The Claude token had hours left, so no refresh ran. The real `~/.claude` and `~/.codex` were not written.

## Claude Code

Each run: a bus with one other agent (`peer`) holding `hello.txt`, a fixed session id so the name is known in advance (the other agent sends two direct messages to it), then `claude -p` asked to report its name and unread count, write `hello.txt`, and say whether a hook warned it. Evidence is the stream-json transcript (`--include-hook-events`) and the bus log.

| Path | Result |
| --- | --- |
| Plugin from the marketplace (`claude plugin marketplace add wickdninja/agentbus`, `claude plugin install agentbus@agentbus`, in a scratch config) | Installs: `agentbus@agentbus 0.2.0, user scope, enabled`. The marketplace entry pins `ref: v0.2.0`. |
| SessionStart note, plugin | Arrives as `SessionStart:startup`, exit 0: `you are on this folder's bus as claude-cf4c4732. 2 agents are on it, 2 unread messages for you (1 handoff, 1 question)`. The agent answered `NAME=claude-cf4c4732 UNREAD=2`. |
| Unread note on the prompt | `UserPromptSubmit` added `2 unread messages for you (1 handoff, 1 question). Read them with: agentbus --as claude-cf4c4732 inbox.` |
| Claim warning, plugin | `PreToolUse:Write` on `hello.txt` added `a claim under a different name covers this file`. The agent answered `CLAIMNOTE=yes`, having run no shell command, so the answer came from the hook. |
| Leaving, plugin | Bus log: `join`, `leave` for the session's name. No agent left on the roster except `peer`. |
| `agentbus setup claude` in a clean scratch config (no plugin) | Wrote `skills/agentbus/SKILL.md` and five hooks to `settings.json`; `doctor` was clean. A run gave the same SessionStart note with `UNREAD=2`, the same claim warning, and join then leave in the bus log. |
| Same, plugin already installed | Setup added the skill only (`hooks provided by the agentbus plugin; not added`). One SessionStart note per session, no doubled hooks. |
| Agent claims for itself, then session ends | The agent ran `agentbus --as NAME claim world.txt` (the bare `agentbus` was on PATH), wrote the file; the turn-end reminder to the user appeared (`claude-7cf4602a still holds 1 claim and has not posted a handoff or done.`); the session end logged `leave: released 1 claim: world.txt`. |

Slash commands. Each was run as `claude -p "/NAME Do not run any command. Reply with one sentence: the first step the protocol tells you to take."`. Without the slash, the agent answered from the SessionStart text (`status` and `inbox`). With it, the agent answered with the skill body's wording (`join`, then `brief`, then `inbox --limit 20`), so the skill was loaded.

| Install | Command | Result |
| --- | --- | --- |
| Plugin | `/agentbus:agentbus` | Works. The init event lists `agentbus:agentbus` as a command and a skill. |
| Plugin | `/agentbus` | Also works: Claude Code resolved it to the plugin's skill. |
| `setup claude` | `/agentbus` | Works. The init event lists `agentbus`. |
| `setup claude` | `/agentbus:agentbus` | No such command, as documented; the agent did not load the skill. |
| Plugin and `setup claude` | both | Both are listed, as two entries for the same skill. |

`scripts/e2e_claude.sh` (haiku, `--plugin-dir` from the checkout) ended `claude e2e passed`: `SessionStart named claude-dc86f790; who listed it`, then `join`, `leave`.

## Codex

`scripts/e2e_codex.sh` ended `codex e2e passed (codex-cli 0.166.0)`: `roster: codex-852ad0bb peer | model reported codex-852ad0bb`, `hook through the login shell: p95 63 ms`. It uses `--dangerously-bypass-hook-trust`, so it does not exercise the trust step.

The trust step, run for real in a scratch `CODEX_HOME`:

1. `agentbus setup codex` wrote `hooks.json` (4 hooks) and the `AGENTS.md` block, and its login-shell probe printed nothing.
2. `codex exec` with the hooks untrusted: no hook ran. The agent reported `NAME=none` and the bus log stayed empty. No warning was printed.
3. Interactive `codex`, driven in a tmux session of its own: it opened with `Hooks need review: 4 hooks are new or changed` and three choices (`Review hooks`, `Trust all and continue`, `Continue without trusting (hooks won't run)`). `Review hooks` shows the event list, then each entry with its event, matcher, source, command (`.../agentbus' hook codex PreToolUse 2>/dev/null || true # agentbus:managed`) and `Trust: New hook - review required`. `t` trusted one entry; `t` on the list trusted the rest (`Active` went from 0 to 1 for each of the three events). Codex wrote `[hooks.state."<hooks.json>:<event>:0:0"] trusted_hash = "sha256:..."` to the scratch `config.toml`.
4. After that, a prompt in the TUI asked for `hello.txt` (held by `peer`) with shell commands forbidden. The agent answered `NAME=codex-8236ee93 CLAIMNOTE=yes`, the name was on the roster, and the file was created. The claim answer could only come from the PreToolUse hook.
5. After `/quit`, `codex-8236ee93` was still on the roster (`seen 33s ago`): Codex has no leave hook, as documented.

What a person still has to do: nothing in this run needed a person. The keys were sent by script, so the look of the screens was read from the captured panes, not seen live.

## Not run

- Claude Code's interactive `/plugin` slash commands. The CLI forms (`claude plugin ...`) were run instead.
- Any interactive Claude Code session; every Claude run was `claude -p`.
- `resume`, `clear`, `compact` and `fork` sessions.
- Typing `/hooks` in Codex. The review screen was reached from the startup prompt.
- The `Trust all and continue` choice.

## Findings

1. The skill and the hook disagree about `join`. `skills/agentbus/SKILL.md:20` says `Start with join`, but the SessionStart hook has already joined the derived name. An agent that follows the skill gets exit 1: `claude-b383c84c was active less than a minute ago and may be another live session. Pick your own name (run: agentbus --as claude-b383c84c-2 join), or pass --takeover only if that session is you.` A Codex agent hit the same error unprompted in the first `e2e_codex.sh` run (and went on without joining). The advice in the error names a second name the hooks do not act for (the claim note and unread count look only at the derived name).
2. Codex's trust prompt is not what the docs and setup output describe. `bin/agentbus` setup output, `README.md:121` and `docs/how-to/setup.md:14` say to type `/hooks`; Codex 0.166.0 shows a `Hooks need review` screen at launch. `docs/how-to/codex.md` is corrected in this change; the other three still say `/hooks`.
3. `scripts/e2e_codex.sh` hung when its stdin was an open pipe: `codex exec` prints `Reading additional input from stdin...` and waits. Fixed with `</dev/null` in both e2e scripts (Claude waited 3 seconds and warned).
4. `scripts/e2e_codex.sh` failed on a correct run: left free, the agent followed the `AGENTS.md` block, ran `leave`, and was gone from the roster the script then checked. Its claim answer also came from its own refused `claim`, not the hook. The prompt now forbids shell commands.
5. On macOS, bare `mktemp -d` in both e2e scripts ignores `TMPDIR` (the scratch project was under `/var/folders/...`), so the "set TMPDIR elsewhere" advice in their messages does nothing there.
