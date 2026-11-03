# Check your install with doctor

*From v0.2.0.* `agentbus --version` must print 0.2.0 or later; the v0.1.0 release has no `doctor` command.

One command tells you what is installed, which version each piece is, what is wrong, and the command that fixes it.

```bash
agentbus doctor
```

```
agentbus 0.2.0 (~/.local/bin/agentbus)
  ok    bus        ~/src/app (schema 1)
  warn  copy       0.1.0 here, 0.2.0 installed. Run: agentbus upgrade ~/src/app
  ok    skill      ~/.claude/skills/agentbus/SKILL.md is current
  n/a   agents-md  no ~/.codex found
  ok    hooks      ~/.claude/settings.json has the current hooks
  ok    hooks      the hooks run ~/.local/bin/agentbus (0.2.0)
1 warning.
```

Run it from the folder you work in. Every line that is not `ok` ends with the command to run, or, when no command can fix it (a file of yours that setup will not overwrite), with a sentence on what to inspect. Run the command, then run `doctor` again.

## The checks

| Check | What it compares | Typical fix |
| --- | --- | --- |
| `tool` | the agentbus you ran, and where it is. Shown only when something is wrong: running a project's own copy (`.agentbus/bin/agentbus`) says so, because a copy cannot be compared with itself | `agentbus doctor` |
| `bus` | the bus for this folder, opened read-only: current, older than this agentbus, newer, unreadable, busy, or not created yet | `agentbus upgrade DIR`, `agentbus init .` |
| `copy` | the bus folder's own copy of agentbus (`.agentbus/bin/agentbus`) against the one you installed: its version, and its contents (an empty or edited file with the right version number is flagged) | `agentbus upgrade DIR` |
| `skill` | the Claude Code skill: missing, current, older, edited, not written by agentbus, or the old install-line link | `agentbus setup claude` |
| `agents-md` | the agentbus block in Codex's `AGENTS.md`: missing, current, older, edited, or damaged markers | `agentbus setup codex` |
| `hooks` | the hook entries `agentbus setup claude` wrote, and the agentbus they run (its path and version). With the Claude Code plugin installed, it says the plugin provides the hooks. Says so when there are none to check | `agentbus setup claude` |

A status is `ok`, `warn`, `fail` or `n/a` (nothing to check on this machine). A warning is something to tidy; a `fail` is something that stops agents from working. The last line counts both. The exit status is 0 unless a check failed, then 1.

`--scope user` checks your own config only, `--scope project` the files under the current folder, and the default `all` both (project files are listed only when they exist, or when you ask for the project scope).

## For scripts and agents

`agentbus doctor --json` prints one object: `{"agentbus": "0.2.0", "path": "...", "contract": 1, "checks": [{"id", "status", "detail", "fix", "hint", "scope"}], "fail": 0, "warn": 1}`. `fix` is a command you can run as written, or `null`. `hint` is advice in words when there is no such command, or `null`; an entry never has both. `scope` is there for checks of a user or project file. With a failing check the object is still printed in full, and stderr holds the `items_failed` error.

## What doctor does and does not do

It reads and prints. It fixes nothing, installs nothing and prints the fix instead of running it. It makes no network call, so it cannot tell you a newer release exists. It runs no program it finds: not a hook, not the bus folder's copy of agentbus (it reads that file as bytes to compare it). The only program it starts is `git`, found on your `PATH` like every agentbus command, with the same read-only lookups they make, because it finds the bus the way they do.

The bus is opened read-only and waits 0.3 seconds, so a bus another program holds shows as `busy` rather than hanging. That open can have two small effects, the same as `watch` and the other read commands: SQLite may create an empty `bus.db-wal` file beside the bus, and if a program crashed while writing, SQLite may finish recovering its journal, which folds rows that were already committed into `bus.db`. No row, table or version changes. The open needs write access to the bus folder for this, so in a read-only sandbox `bus` reports the permission error.

## Reading a line

- `bus ... older than this agentbus`: the next command that writes migrates it, after a backup. `agentbus upgrade DIR` does it now. See [Upgrade agentbus](upgrade.md).
- `bus ... newer than this agentbus`: the bus was made by a later release. Upgrade the tool you run; do not edit the bus.
- `bus ... is busy`: another program holds the bus, such as a `sqlite3` shell. Close it and run `doctor` again.
- `copy ... newer than the installed`: the folder's copy came from a later release than the agentbus you installed.
- `skill ... was edited`: setup saves your copy next to it as a `.bak` file, then updates it.
- `skill ... was not written by agentbus`: setup will not overwrite a file it did not write, so doctor names no command. Inspect the file and move it aside if it is yours to move.
- `copy ... has the installed version's number but not its contents`: the folder's copy is empty, damaged or edited. `agentbus upgrade DIR` replaces it.

How the pieces' versions relate is in [How versions fit together](../explanation/versions.md).
