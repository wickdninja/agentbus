# How versions fit together

Five things carry a version, and five different commands update them.

| Piece | What it is | Where the version lives | Updated by |
| --- | --- | --- | --- |
| Tool | the agentbus you installed (`agentbus --version`) | the package | `agentbus update` |
| Copy | the agentbus inside a bus folder (`.agentbus/bin/agentbus`) | `.agentbus/VERSION` | `agentbus upgrade`, `agentbus init` |
| Schema | the shape of the bus database | `PRAGMA user_version` in `bus.db` | the first write by a newer tool, or `agentbus upgrade` |
| Skill | what Claude Code reads | `~/.claude/skills/agentbus/SKILL.md` | `agentbus setup claude` |
| Hooks | commands an agent's tool runs on events | the agent's config | `agentbus setup claude`, or the Claude Code plugin |

`agentbus doctor` compares them and names the one command that fixes each difference ([Check your install](../how-to/doctor.md)).

## The rules

1. **Agents run the bus copy.** The skill, the `AGENTS.md` block and every message an agent is told to act on name `.agentbus/bin/agentbus` (from another worktree, its absolute path). The installed `agentbus` is the tool for people: `init`, `upgrade`, `setup`, `doctor`, `skill`, `watch`, `schema`.
2. **A newer tool opens an older bus; an older copy never opens a newer one.** A write by a newer tool migrates the bus after a verified backup. A read that must not write (`watch`, `doctor`) reports the bus as older and changes nothing. An older copy that meets a newer bus refuses and writes nothing: `schema_newer` from a 0.2 copy, `schema_refused` from a 0.1.0 copy, which predates versions. A 0.1.0 copy does open a bus at schema 1, because version 1 is the v0.1.0 shape. Tools and copies one minor release apart are supported; older ones are not.
3. **A stale copy shows in the data.** `join --json` carries `"agentbus"` and `"contract": 1`. A listing that prints a bare `[...]` instead of an object with `items` comes from a 0.1.x copy: run `agentbus upgrade DIR` for that bus (or `agentbus upgrade --all PARENT_DIR` for every bus under a folder). The skill an agent reads describes the `items` object and says that on `schema_newer`, `schema_older` or a stale-copy notice the agent tells you to run `agentbus upgrade DIR` and never edits the bus; it does not yet teach agents that a bare `[...]` means a 0.1.x copy. The Codex `AGENTS.md` block says that a copy without a `skill` command is 0.1.x and names `agentbus upgrade --all PARENT_DIR`. The notice on stderr (`this bus's copy is 0.1.0; ...`) is for you, comes only from the installed tool, and never appears with `--json`.
4. **Hooks run the installed tool**, never a copy found in a project, and stay silent when the bus is older, newer, busy or unreadable.
5. **`agentbus doctor` reports all of it**, each with its fix. Every release's changelog says which of the five changed.
6. **A running `watch` keeps its old code.** After an upgrade, restart it.

## What happens in each combination

| Tool | Copy | Bus | What you see |
| --- | --- | --- | --- |
| new | 0.1.0 | v0.1.0 shape | `join`, `status` and `buses` print the stale-copy notice on stderr. `doctor` warns on `copy`. `agentbus upgrade DIR` (or `upgrade --all PARENT_DIR`) replaces the copy and stamps the bus, with no backup. |
| new | new | v0.1.0 shape | Any write adopts the bus (the stamp is the only change). `watch`, `who` and `status` without a name write nothing. |
| new | 0.1.0 | schema 1 | The 0.1.0 copy works. Its writes leave the version at 1. Nothing is refused. `doctor` still warns on `copy`. |
| new | new | newer than the tool | Every command, `watch` included, refuses with `schema_newer`. `doctor` fails `bus`. Upgrade the tool. |
| new | 0.1.0 | any | The copy prints bare arrays and no `contract`. The skill describes the `items` object and says the user runs the upgrade; it does not mention bare arrays. |
| new | new | current, old install-line link for the skill | `doctor` flags the link. `agentbus setup claude` replaces it with a real file. |
| new | any | current, a SKILL.md agentbus did not write | `setup claude` refuses and writes nothing. `doctor` warns. |
| 0.1.0 | 0.1.0 | a later schema shape | The copy answers `schema_refused` and writes nothing. `upgrade` run from a project copy is refused by every version. |
| new | new | needs a migration | `watch` and `doctor` write nothing. Any other command migrates after one backup. |

These rows are tests: `tests/test_version_policy.sh`.
