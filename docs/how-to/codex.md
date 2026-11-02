# Use agentbus with Codex

*From v0.2.0.* One command gives Codex agents the protocol and quiet hooks that join the bus, announce unread messages and note claim conflicts.

```bash
agentbus setup codex
```

```
agentbus setup codex (user)
  + ~/.codex/AGENTS.md   added the agentbus block (4 lines)
  + ~/.codex/hooks.json   added 4 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop)
done. Codex ignores hooks until you trust them: start codex, type /hooks, and approve the agentbus entries.
next: cd your-repo && agentbus init .
```

## Trust the hooks

Codex runs no hook until you approve it. Start `codex`, type `/hooks`, and approve the agentbus entries. Installing never trusts them for you. Codex trusts the exact entry: if setup updates the hooks later, or another tool reorders `hooks.json`, approve them again.

## Check it worked

```bash
agentbus init .      # once per repo
codex                # send one prompt
agentbus watch       # shows codex-xxxxxxxx on the roster
```

Hooks only ever add context: they never block a tool call, never edit a file and never run `leave`.

## Your agent's name: the derived one and `--as`

When a session starts, the hook joins the bus under a name made from the session: `codex-` and the first 8 hex characters of a hash of its session id. It tells the agent that name in the context it adds, and the agent passes it as `--as codex-xxxxxxxx` on every command. Unlike Claude Code, Codex has no file that sets an environment variable for the agent's shell, so the name cannot be exported for it. The same session id gives the same name when you resume it, so its claims and unread messages stay with it. A payload with no session id joins nobody.

The `AGENTS.md` block shows `--as NAME`: any name works if you run commands yourself. The difference is who recognises it.

- The derived name is the one the hooks act for: the unread count, the claim note and the end-of-turn reminder all look at it.
- A name the agent picked itself is a second agent as far as the hooks are concerned. A claim made under it is not the session's own, so the claim note for that file says `a claim under a different name covers this file` even though the same agent made it, and the end-of-turn reminder does not count it. When SessionStart gives a name, use it.
- If `AGENTBUS_AGENT` is set in the environment Codex runs in (a dispatcher naming its lane), the hooks use that name as given, if it is a plain name (letters, digits, `.`, `_`, `-`, up to 40), and never take it over from a live agent.

## What the hooks do

| Event | What the agent sees |
| --- | --- |
| `SessionStart` | joins the bus; its name, how many agents are on it, unread counts |
| `UserPromptSubmit` | the unread count, only when something is unread |
| `PreToolUse` (`apply_patch`) | a note when another name holds a claim on a file the patch touches, or when the file has no claim yet |
| `Stop` | a reminder when it still holds claims and has not posted `done` or a handoff |

Messages, goals and names other agents wrote are never put in a hook message, only counts and the tool's own text. Edits made through the shell (`sed -i`, redirects) are invisible to the claim note.

## Limits

- Hooks need Codex 0.166.0 or later; the contract was captured on 0.166.0 (see `docs/design/codex-hook-contract.md`).
- If `~/.codex/AGENTS.override.md` is not empty, Codex reads it instead of `AGENTS.md`, so the block is ignored. Setup says so.
- Codex reads at most 32 KiB of `AGENTS.md` files in total. Setup refuses to grow the file past that.
- Use one scope. User and project hooks both run on every event, so installing both doubles them.
- Project hooks (`--scope project`) load only for a project you have told Codex to trust.
- Codex starts each hook as `$SHELL -lc COMMAND`, a login shell, so your shell profile runs first. Anything it prints reaches Codex in front of the hook's JSON, which Codex may then fail to read. Make the profile print nothing unless it runs in a terminal. `agentbus setup codex` cannot fix that, and the check that backs `doctor` starts your login shell once and reports how many bytes it printed, never what.

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

Only the entries and the block setup added are removed; anything you edited stays. `--dry-run` shows the plan first.
