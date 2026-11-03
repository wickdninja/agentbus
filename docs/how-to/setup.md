# Set up your agents

*From v0.2.0.* `agentbus --version` must print 0.2.0 or later; the v0.1.0 release has no `setup` command (its README line, a symlink from a clone, still works).

One command gives an agent the agentbus protocol. No clone, no symlink, no path to type.

```bash
agentbus setup claude     # Claude Code: installs the skill and the hooks
agentbus setup codex      # Codex: adds the agentbus block to AGENTS.md
```

Start a new session afterwards so the agent loads it. Then, in each repo or folder of repos:

```bash
agentbus init .
```

## See the plan first

`--dry-run` prints what would change and writes nothing. `--json` prints the same plan as data.

```bash
agentbus setup claude --dry-run
```

```
agentbus setup claude (user)
  + would install ~/.claude/skills/agentbus/SKILL.md (4,606 bytes)
  + would add 5 hooks (SessionStart, UserPromptSubmit, PreToolUse, Stop, SessionEnd) to ~/.claude/settings.json
dry run: nothing was written.
```

## Where it writes

| Command | User scope (default) | `--scope project` |
| --- | --- | --- |
| `setup claude` | `~/.claude/skills/agentbus/SKILL.md` and the `hooks` of `~/.claude/settings.json` (or under `CLAUDE_CONFIG_DIR`) | `./.claude/skills/agentbus/SKILL.md` and `./.claude/settings.json` |
| `setup codex` | `~/.codex/AGENTS.md` (or under `CODEX_HOME`) | `./AGENTS.md` |

The hooks are five entries, each ending in `# agentbus:managed`; your other hooks and settings stay. If the agentbus plugin is already installed and enabled (setup asks `claude plugin list --json`, and reads Claude Code's plugin files only when there is no `claude` to ask) it provides the hooks, so setup adds only the skill and says `provided by the agentbus plugin; not added`. [Claude Code](claude-code.md) describes what the hooks do.

Nothing else is written. New folders are private (0700) and new files owner-only (0600).

## What it never does

- It never overwrites a file it did not write. A `SKILL.md` without the agentbus marker is left alone and setup stops with the command to use instead (`--scope project`). When one piece refuses, nothing is written for any piece.
- It never changes text outside its own block in `AGENTS.md`. The block sits between `<!-- agentbus:begin -->` and `<!-- agentbus:end -->` (markers inside a fenced code block are your text and are ignored); setup refuses a file whose markers are damaged or that ends inside an unclosed code fence. A file with CRLF line endings gets a CRLF block.
- It never starts a write it cannot finish: a config folder that is a link to nowhere is refused up front, in a dry run too. If a write does fail, the message lists exactly which files were written before it, and running setup again finishes the rest.
- It never follows a link to write somewhere else. A symlinked `SKILL.md` or `AGENTS.md` is refused.

Running it again changes nothing and says `unchanged`.

Your edits are kept. If you edited the installed skill, or the text inside the agentbus block of `AGENTS.md`, an update first saves the file as `SKILL.md.agentbus-<date and time>.bak` (or `AGENTS.md.agentbus-<date and time>.bak`), a new copy each time, and says so. The same goes for a JSON file setup changes: the file as it was is saved first. Uninstall never removes an edited skill or an edited block. If the file changes while setup is running, setup stops and leaves it as you changed it.

## If you used the old install line

Earlier versions asked you to run `ln -s "$PWD/skill" ~/.claude/skills/agentbus` from a clone. That link breaks when the clone moves. `agentbus setup claude` replaces the link itself (never what it points to) with a real folder and prints where it pointed:

```
  ~ ~/.claude/skills/agentbus   replaced the link to /Users/me/src/agentbus/skill (the old install line)
```

A link to anything that is not an agentbus skill is left alone.

In a clone of the repository, `skill/SKILL.md` is itself a symlink to `skills/agentbus/SKILL.md`, so the old line keeps working. On Windows, a checkout needs `git config core.symlinks true` (and permission to create links) for that file to be a link; otherwise it is a one-line text file. Use `agentbus setup claude` instead, which needs no clone.

## Remove it

```bash
agentbus setup claude --uninstall
```

Uninstall removes only what setup added. A skill you edited stays and is reported as `modified; not removed`. For `AGENTS.md`, only the marked block goes; your other text, and any edits you made since, stay.

## For agents

An agent in a repo with no skill runs `.agentbus/bin/agentbus skill` and gets the protocol on stdout. `agentbus skill --agents-md` prints the Codex block.

`setup` runs from the installed `agentbus`, not from a copy inside a project (`.agentbus/bin/agentbus`).
