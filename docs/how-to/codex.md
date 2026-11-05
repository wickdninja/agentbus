# Use agentbus with Codex

*From v0.2.0.* One command gives Codex agents the protocol and quiet hooks that join the bus, announce unread messages and note claim conflicts.

```bash
agentbus setup codex
```

```
agentbus setup codex (user)
  + ~/.codex/AGENTS.md   added the agentbus block (4 lines)
  + ~/.codex/hooks.json   added 4 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop)
  = /bin/zsh   prints nothing at startup (started once as $SHELL -lc)
done. Codex ignores hooks until you trust them: start codex, type /hooks, and approve the 4 entries whose command starts '/usr/bin/python3' '/path/to/agentbus' hook codex and ends # agentbus:managed.
next: cd your-repo && agentbus init .
```

Two steps are yours: run `agentbus init .` in each repo, and approve the hooks in Codex (next section).

## Trust the hooks

Codex runs no hook until you approve it. Start `codex`: on Codex 0.166.0 it opens with "Hooks need review". Choose "Review hooks", open each of the four entries agentbus added and press `t`, or press `t` on the list to trust all four. Installing never trusts them for you, and `codex exec` skips untrusted hooks without a word.

To recognise them: the command starts with the installed `agentbus` (the exact words setup printed) followed by `hook codex EVENT`, and ends with `# agentbus:managed`. Approve only those; an entry that runs something else is not ours. Running `agentbus setup codex` again changes nothing and prints the same reminder while the hooks are in place.

Codex trusts the exact entry: if setup updates the hooks later, or another tool reorders `hooks.json`, approve them again. With `--scope project`, Codex also has to trust the project itself, or it skips the project's hooks.

## Your login shell

Setup starts your login shell once, as Codex will (`$SHELL -lc`), and says how many bytes it printed at startup, never what. It sets `AGENTBUS_SHELL_PROBE=1` while it runs, so a profile can skip slow work or output when that is set. Anything a profile prints reaches Codex in front of the hook's JSON, which Codex may then fail to read; make it print nothing unless it runs in a terminal (for example `[ -t 1 ]`). A shell that does not finish within 10 seconds is stopped and reported as unknown, and so is anything it left running.

The hook command is written for a POSIX shell. Setup starts only `sh`, `bash`, `zsh`, `dash` and `ksh` (versioned names such as `bash-5.2` too). For any other `$SHELL` (`fish`, `nu`, `xonsh`, `elvish`, `tcsh`, `csh`) it says so and does not start it; start Codex as `SHELL=/bin/sh codex`.

## Check it worked

```bash
agentbus init .      # once per repo
codex                # send one prompt
agentbus watch       # shows codex-xxxxxxxx on the roster
agentbus doctor      # checks the hooks file, the executable it runs and the AGENTS.md block
```

`agentbus doctor` reads files only: it never starts Codex or your shell. It warns about a hook entry that runs another install of `agentbus` (after an upgrade moved it; run `agentbus setup codex` again). An entry tagged `# agentbus:managed` that is not the line setup writes (another command, extra commands chained on, a relative path, a path that goes through the project or a `.agentbus` folder even by a link, an interpreter that is not Python, a script that is not agentbus) is a problem: it was not written by setup, so remove it with `agentbus setup codex --uninstall --scope user` and set up again. Doctor also says on its `codex` line that trust cannot be checked from outside Codex, so `/hooks` stays the place to confirm.

Hooks only ever add context: they never block a tool call, never edit a file and never run `leave`.

Codex needs no command to learn the protocol: setup installs the `AGENTS.md` block, which Codex reads at the start of every session. (Setup installs a skill only for Claude Code.)

## Your agent's name: the derived one and `--as`

When a session starts, the hook joins the bus under a name made from the session: `codex-` and the first 8 hex characters of a hash of its session id. It tells the agent that name in the context it adds, and the agent passes it as `--as codex-xxxxxxxx` on every command. Unlike Claude Code, Codex has no file that sets an environment variable for the agent's shell, so the name cannot be exported for it. The same session id gives the same name when you resume it, so its claims and unread messages stay with it. A payload with no session id joins nobody.

The `AGENTS.md` block shows `--as NAME`: any name works if you run commands yourself. The difference is who recognises it.

- The derived name is the one the hooks act for: the unread count, the claim note and the end-of-turn reminder all look at it.
- A name the agent picked itself is a second agent as far as the hooks are concerned. A claim made under it is not the session's own, so the claim note for that file says `a claim under a different name covers this file` even though the same agent made it, and the end-of-turn reminder does not count it. When SessionStart gives a name, use it.
- If `AGENTBUS_AGENT` is set in the environment Codex runs in (a dispatcher naming its lane), the hooks use that name as given, if it is a plain name (letters, digits, `.`, `_`, `-`, up to 40), and never take it over from a live agent.

## What the hooks do

| Event | Shown to | What it says |
| --- | --- | --- |
| `SessionStart` | the agent | it joined the bus; its name, how many agents are on it, unread counts, and the commands to read, each with `--as` and its name |
| `UserPromptSubmit` | the agent | the unread count and `agentbus --as NAME inbox`, only when something is unread |
| `PreToolUse` (matcher `apply_patch\|Edit\|Write`) | the agent | a note when another name holds a claim on a file the patch touches; or, when another agent is on the bus, which file has no claim and the exact command to claim it |
| `Stop` | you | `codex-xxxxxxxx still holds 1 claim and has not posted a handoff or done.`, once for each set of claims |

Messages, goals and names other agents wrote are never put in a hook message, only counts and the tool's own text. A file name is printed only when it is plain (letters, digits, `. _ / @ + -`). Edits made through the shell (`sed -i`, redirects) are invisible to the claim note.

## Limits

- Hooks need Codex 0.166.0 or later; the contract was captured on 0.166.0 (see `docs/design/codex-hook-contract.md`).
- If `~/.codex/AGENTS.override.md` is not empty, Codex reads it instead of `AGENTS.md`, so the block is ignored. Setup says so.
- Codex reads at most 32 KiB of `AGENTS.md` files in total. Setup refuses to grow the file past that.
- Use one scope. User and project hooks both run on every event, so installing both doubles them.
- Project hooks (`--scope project`) load only for a project you have told Codex to trust.
- Codex starts each hook as `$SHELL -lc COMMAND`, a login shell: see "Your login shell" above.
- With `--scope project`, setup refuses a `.codex` or `.claude` that is a link, or a link anywhere below it (`.claude/skills`): it will not write or delete through it, and checks the folders again right before each write.

## Print the hooks yourself

If you keep Codex's files in dotfiles, print the hooks and merge them by hand:

```bash
agentbus hooks codex > hooks.json
agentbus hooks claude    # the hooks block for .claude/settings.json
```

Every command in them names the installed tool by absolute path and ends with `# agentbus:managed`. Run it from the installed `agentbus`, not a copy inside a project.

## Remove it

```bash
agentbus setup codex --uninstall
```

Only the entries and the block setup added are removed. An `AGENTS.md` block you edited stays. Hook entries tagged `agentbus:managed` go even if you edited them, so `hooks.json` is first saved as `hooks.json.agentbus-<date and time>.bak`, unless it held only the entries setup wrote, unedited. A `hooks.json` or `AGENTS.md` that held nothing else is deleted with them, and so is the `.codex` folder setup made when nothing else is in it. `--dry-run` shows the plan first.
