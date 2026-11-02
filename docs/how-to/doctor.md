# Check your install with doctor

*From v0.2.0.* `agentbus --version` must print 0.2.0 or later; the v0.1.0 release has no `doctor` command.

One command tells you what is installed, which version each piece is, what is wrong, and the command that fixes it.

```bash
agentbus doctor
```

```
agentbus 0.2.0 (~/.local/bin/agentbus)
  ok    bus        ~/src/app (schema 1)
  warn  copy       0.1.0 here, 0.2.0 installed. Run: agentbus upgrade --all ~/src
  ok    skill      ~/.claude/skills/agentbus/SKILL.md is current
  n/a   agents-md  no ~/.codex found
  n/a   hooks      not installed by this version
1 warning.
```

Run it from the folder you work in. Every line that is not `ok` ends with the command to run. Run that, then run `doctor` again.

## The checks

| Check | What it compares | Typical fix |
| --- | --- | --- |
| `tool` | the agentbus you ran, and where it is. Shown only when something is wrong, for example when you ran a project's own copy | `uv tool upgrade agentbus` |
| `bus` | the bus for this folder, opened read-only: current, older than this agentbus, newer, unreadable, busy, or not created yet | `agentbus upgrade DIR`, `agentbus init .` |
| `copy` | the bus folder's own copy of agentbus (`.agentbus/bin/agentbus`) against the one you installed | `agentbus upgrade --all PARENT_DIR` |
| `skill` | the Claude Code skill: missing, current, older, edited, not written by agentbus, or the old install-line link | `agentbus setup claude` |
| `agents-md` | the agentbus block in Codex's `AGENTS.md`: missing, current, older, edited, or damaged markers | `agentbus setup codex` |
| `hooks` | hook entries `agentbus setup` wrote. This version installs none, so it says so | none |

A status is `ok`, `warn`, `fail` or `n/a` (nothing to check on this machine). A warning is something to tidy; a `fail` is something that stops agents from working. The last line counts both. The exit status is 0 unless a check failed, then 1.

`--scope user` checks your own config only, `--scope project` the files under the current folder, and the default `all` both (project files are listed only when they exist, or when you ask for the project scope).

## For scripts and agents

`agentbus doctor --json` prints one object: `{"agentbus": "0.2.0", "path": "...", "contract": 1, "checks": [{"id", "status", "detail", "fix", "scope"}], "fail": 0, "warn": 1}`. `fix` is the command to run, or `null`. With a failing check the object is still printed in full, and stderr holds the `items_failed` error.

## What doctor never does

It reads files and prints. It does not write, fix, migrate or install anything, and it prints the fix instead of running it. It does not run any program it finds: not a hook, not the bus folder's copy of agentbus, not even `git` (it finds a linked worktree's main checkout by reading `.git`). It makes no network call, so it cannot tell you a newer release exists. The bus is opened read-only and waits 0.3 seconds, so a bus another program holds shows as `busy` rather than hanging. (Opening a bus can make SQLite create an empty `bus.db-wal` file beside it, as every read-only command does; nothing in the bus changes.)

## Reading a line

- `bus ... older than this agentbus`: the next command that writes migrates it, after a backup. `agentbus upgrade DIR` does it now. See [Upgrade agentbus](upgrade.md).
- `bus ... newer than this agentbus`: the bus was made by a later release. Upgrade the tool you run; do not edit the bus.
- `bus ... is busy`: another program holds the bus, such as a `sqlite3` shell. Close it and run `doctor` again.
- `copy ... newer than the installed`: the folder's copy came from a later release than the agentbus you installed.
- `skill ... was edited`: setup saves your copy next to it as a `.bak` file, then updates it.
- `skill ... was not written by agentbus`: setup will not overwrite a file it did not write. Move it aside first.

How the pieces' versions relate is in [How versions fit together](../explanation/versions.md).
