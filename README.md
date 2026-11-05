<div align="center">

<img src="docs/agentbus.jpg" alt="A comic yellow bus full of agents leaps down a road made of a git commit graph, its robot driver pointing straight at you" width="100%">

# agentbus

**A shared inbox for the coding agents in your workspace.**

Claude Code, Codex, scripts and you: messages, file claims and shared facts,<br>
all in one SQLite file. No server. No dependencies.

[![test](https://github.com/wickdninja/agentbus/actions/workflows/test.yml/badge.svg)](https://github.com/wickdninja/agentbus/actions/workflows/test.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![python 3.9+](https://img.shields.io/badge/python-3.9%2B-blue.svg)

</div>

<br>

## What it is

Agents in one folder hand each other work, ask questions, and claim files before they edit them, and you can watch it happen. It is for two or more agents, or one agent and you, in the same repo or workspace. There is no server and no third-party package: the bus is one SQLite file in that folder.

Claims are advisory, so nothing stops an agent that ignores one. It runs on one machine, on macOS and Linux. An agent sees a message when it next checks, and agentbus cannot wake an idle session. `wait`, run as a background command, ends when mail arrives and so tells a session whose tool reports finished background commands (Claude Code does); it starts no turn in a session with nothing running.

<br>

## Demo

<div align="center">

<img src="docs/demo.gif" alt="Three agents in terminal panes hand off work, hit a claim conflict, ask and answer a question and take over the claim, while agentbus watch shows it live" width="100%">

<sub>A scripted session driving the real tool: a handoff, a claim conflict and its resolution, a question answered, with <code>agentbus watch</code> on the right. Cut by <a href="scripts/record_demo.sh">scripts/record_demo.sh</a>.</sub>

</div>

<br>

<a id="quick-start"></a>

## Try it

**1. Install**

```bash
uv tool install https://github.com/wickdninja/agentbus/releases/download/v0.2.0/agentbus-0.2.0-py3-none-any.whl
```

or `pipx install --force https://github.com/wickdninja/agentbus/releases/download/v0.2.0/agentbus-0.2.0-py3-none-any.whl`.

Not on PyPI: `pip install agentbus` installs a different project. Needs Python 3.9+ and git 2.31+.

**2. Add a bus to a repo, or to a folder of repos**

```bash
cd your-repo        # or ~/src/your-workspace
agentbus init .
```

**3. Hand off some work**

```bash
agentbus --as claude join
agentbus --as codex  join

agentbus --as claude goal "auth on the new token API"

agentbus --as claude post "auth refactor is yours" --to codex --kind handoff
agentbus --as codex  inbox
agentbus --as codex  claim src/auth/
agentbus --as codex  release src/auth/
agentbus --as codex  post "done, tests green" --to claude --reply-to 1 --kind done
agentbus --as claude inbox
```

```text
#2 codex -> claude [done] re #1 · 16:19
  done, tests green
```

**4. Watch it**

```bash
agentbus watch      # live view of agents, claims, facts and messages; q quits
```

Without touching a repo, `agentbus demo` is a 30-second tour on a temporary bus. From a clone, with no install:

```bash
AGENTBUS="python3 bin/agentbus" bash examples/two-agent-handoff.sh
```

<br>

## Set up your agents

### Claude Code

Inside Claude Code, then restart it:

```
/plugin marketplace add wickdninja/agentbus
/plugin install agentbus@agentbus
```

Or with the tool installed, and no plugin:

```bash
agentbus setup claude
```

**Then you just talk to it.** You don't need a command. Hooks join each session to the bus, tell it its name and what is waiting, and leave when it ends. Ask it "who is on the bus?".

A skill is also a command you can type in Claude Code: `/agentbus` after `agentbus setup claude`, or `/agentbus:agentbus` with the plugin. More: [Claude Code](docs/how-to/claude-code.md).

### Codex

```bash
agentbus setup codex
```

Then start `codex`, review the hooks on its "Hooks need review" screen (or type `/hooks`) and approve the four agentbus entries: Codex runs no hook until you do. More: [Codex](docs/how-to/codex.md).

### Other agents

Anything that can run a shell command can use the bus. Give it the protocol:

```bash
agentbus skill              # the protocol
agentbus skill --agents-md  # the block for an AGENTS.md
```

### Check it

```bash
agentbus doctor
```

### Terminal

Keep `agentbus watch` open beside your agents. `agentbus watch --json` prints one snapshot, for a tmux status line or a script. More: [Watch your agents](docs/how-to/watch.md).

<br>

## Update

`agentbus update` installs the latest release, upgrades your bus folders and refreshes the skill. Once a day, a command you run at a terminal may tell you a release is out (on stderr; never in CI, with `--json` or in an agent session); `AGENTBUS_NO_UPDATE_CHECK=1` turns that off. Do not run `pip install agentbus` or `uv tool install agentbus`: that name on PyPI is a different project.

<br>

## How it works

<img src="docs/how-agents-work.jpg" alt="A six-panel comic: the human pins a goal, the brain robot hands a sealed envelope to a hand robot, the hand padlocks a code file with an hourglass, a test ghost bounces off the lock and sends a question instead, the hand releases the file and sends a green check, and the human watches it all on a dashboard" width="100%">

- **A bus lives in a folder.** Run `init` in one repo or a workspace of many. Commands find the nearest bus above them, as git finds `.git`, and linked worktrees start at their main checkout.
- **Buses nest.** A repo can have its own bus inside a workspace that has one. `--up 1` reaches the outer bus and `buses` lists the chain. Nothing merges across them.
- **Claims are advisory and expire.** A claim covers a file, a folder or anything (`issue:17`), for 2 hours by default, so a crashed agent cannot hold it for good.
- **Each agent has its own inbox.** Delivery is at least once: a crash can show a message again, so check its id before acting on it.
- **Agents run the installed tool.** `init` also copies the tool into `.agentbus/bin/`, for a dispatcher to hand to a sandboxed worker, and `AGENTBUS_DB` gives that worker an explicit bus.

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/hero-dark.png">
  <img src="docs/diagrams/hero-light.png" alt="How agents work together. The bus sits in the middle holding the goal, inboxes, claims and facts. 1: you set the goal. 2: claude, the lead, hands off to codex. 3: codex claims src/auth/. 4: the tests subagent's claim is refused, held by codex, so it asks codex instead. 5: codex answers, releases src/auth/, and posts done to claude. 6: you watch it all live." width="100%">
</picture>

### How it compares

What agentbus adds is one place for Claude Code, Codex, scripts and you: one inbox, with claims and history in one file. If every agent you run is a Claude Code session, try its built-in messaging first.

| Option | Where it is better | Where agentbus fits |
| --- | --- | --- |
| **Claude Code messaging** | Built in, nothing to enable. Starts a turn in an idle session, which agentbus cannot do. Reaches other machines over Remote Control. | Codex on the same inbox, plus claims, shared facts and a history you can read later. |
| **Claude Code subagents and agent teams** | Built in. Teams add a shared task list, though they are experimental and off by default. | Agents from different tools, and work that outlives one session. |
| **`codex queue`** | Built in and stable. Queues a message for an existing Codex session. | Claude Code on the same inbox, plus claims, shared facts and history. |
| **MCP Agent Mail** (the Rust build; the Python one is deprecated) | A web UI and a TUI, searchable history, a Git archive, a pre-commit guard that can block commits, Windows binaries. | No MCP server: a plain command an agent runs from its shell. |
| **cabildo** | Its hooks deny risky git, such as `git push` while another agent is live. Messages sync across machines. A read-only web view. | Python 3.9 with no packages to install (cabildo needs 3.11 and its dependencies). One bus per folder, and buses nest. |
| **Vibe Kanban** (its company closed in April 2026; community maintained) | A visual board where each workspace gets a branch, a terminal and a dev server, with diff review and pull requests. | Agents you already run in your own terminals, with no board to open. |
| **A shared Markdown file, or GitHub issues** | Nothing new to install, and people read them with no tool. Issues reach across machines. | Unread state per agent and claims that expire, on your machine with no account. |
| **`tmux send-keys`** | Already there if you use tmux, and reaches any program in a pane. | Messages wait in an inbox, instead of being typed into whatever is on screen. |

<br>

## Reference

- [Commands](docs/reference.md): how a command finds its bus, nesting, locking
- [JSON and errors](docs/reference.md#json-output): every result shape, error code and exit status
- [Environment](docs/reference.md#environment): every variable
- [Upgrading and restoring](docs/how-to/upgrade.md)
- [`agentbus doctor`](docs/how-to/doctor.md): what each check means and what fixes it
- [Sandboxed agents](docs/sandboxed-agents.md): giving a sandboxed agent the bus, and only the bus
- [How the pieces fit](docs/workflow.md): full diagrams and their sources
- [Security](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

<br>

<div align="center">

MIT licensed

</div>
