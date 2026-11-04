# Launch claims

Every factual statement about another tool in the README comparison and the launch post has one row. Sources are primary (the project's own repo, package page or docs). First checked 2026-11-01 by fetching each URL. On 2026-11-04 every row was re-read from a raw download of its source and each quote grepped from that copy; rows that changed carry that date. The claim-gate lanes still re-read the quoted phrase at the source before the final bytes ship. A claim not marked `ok` is cut. No star counts anywhere.

Status: `ok` = source says it on the date checked. `cut` = unverified, stale or contradicted; do not use.

## Competitors

| id | Claim | Evidence (quote or file) | Source URL | Checked | Status |
|---|---|---|---|---|---|
| <!-- claim:1 --> 1 | MCP Agent Mail is a coordination layer for AI coding agents with agent identities, an inbox/outbox, searchable message history and voluntary file reservation leases. | "memorable identities, an inbox/outbox, searchable message history, and voluntary file reservation 'leases.'" | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:2 --> 2 | Agent Mail runs as a server. | README: "an HTTP-only FastMCP server"; default port 8765; start with `scripts/run_server_with_token.sh`. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:3 --> 3 | The Python Agent Mail needs Python 3.14 (with uv). | Still on the page: "Create a Python 3.14 virtual environment". But line 3 now reads "This Python version is no longer maintained; use the Rust version for new installs." | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-04 | cut as a comparison: the current Agent Mail is a Rust binary |
| <!-- claim:4 --> 4 | Agent Mail keeps messages in a per-project Git repo and indexes in SQLite with FTS5. | README: Git for human-auditable artifacts, SQLite for indexing and queries. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:5 --> 5 | Agent Mail's file reservations are advisory with a TTL; conflicts are reported but the reservation is still granted; an optional pre-commit guard can block conflicting commits. | "advisory file reservations for editing surfaces"; `file_reservation_paths` takes a TTL and exclusive flag. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:6 --> 6 | The Python Agent Mail is deprecated; new installs are pointed to the Rust build. | "Superseded by" the Rust repo; "This Python version is no longer maintained"; repo description starts "Deprecated:". | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-04 | ok. Say deprecated. |
| <!-- claim:7 --> 7 | Agent Mail's Python README is inconsistent on transport (says HTTP-only and also lists a stdio option). | Both phrases appear on the page. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok (do not state a transport for the Python version; say "a server") |
| <!-- claim:8 --> 8 | The Rust Agent Mail runs `mcp-agent-mail serve` as an HTTP server on 127.0.0.1:8765, also supports stdio, installs from a prebuilt binary (Linux, macOS, Windows) and uses SQLite plus Git. | "Agent Mail supports both stdio and HTTP transports"; "SQLite for live state, Git for the durable ledger"; source build "Requires Rust nightly". | https://github.com/Dicklesworthstone/mcp_agent_mail_rust | 2026-11-01 | ok |
| <!-- claim:9 --> 9 | Agent Mail (Rust) supports Claude Code, Codex CLI, Gemini CLI, Oh My Pi and GitHub Copilot CLI. | README supported-agent list. | https://github.com/Dicklesworthstone/mcp_agent_mail_rust | 2026-11-01 | ok |
| <!-- claim:10 --> 10 | Agent Mail has a web UI and a TUI. Better than agentbus's terminal `watch` for browsing history. | Python: "built into the HTTP server in `mcp_agent_mail.http` under the `/mail` path". Rust: "an interactive 16-screen TUI, a server-rendered web UI". | both Agent Mail repos above | 2026-11-04 | ok |
| <!-- claim:11 --> 11 | Agent Mail's licence. | Python page shows a "License" link only; Rust badge reads "MIT+Rider", terms not read. | https://github.com/Dicklesworthstone/mcp_agent_mail_rust | 2026-11-01 | cut (never state a licence; read LICENSE first if wanted) |
| <!-- claim:12 --> 12 | Agent Mail last commit or release date. | Not shown on the pages fetched. | n/a | 2026-11-01 | cut |
| <!-- claim:13 --> 13 | Vibe Kanban is a kanban board that runs coding agents in isolated workspaces (branch, terminal, dev server) with diff review and PR creation. | README summary as fetched. | https://github.com/BloopAI/vibe-kanban | 2026-11-01 | ok |
| <!-- claim:14 --> 14 | Vibe Kanban runs with `npx vibe-kanban` and needs an authenticated coding agent; supports Claude Code, Codex, Gemini CLI, Copilot, Amp, Cursor, OpenCode and others; Apache-2.0. | "npx vibe-kanban"; agent list; Apache-2.0 as fetched. | https://github.com/BloopAI/vibe-kanban | 2026-11-01 | ok |
| <!-- claim:15 --> 15 | Vibe Kanban's company closed in April 2026 and the project is community maintained. | Announcement dated April 10, 2026: "Today we're shutting down bloop, the company behind Vibe Kanban. The Vibe Kanban project will live on, open source and community maintained." README still says "Vibe Kanban is sunsetting." Direct fetch fails TLS; the quote is from Exa's copy. | https://www.vibekanban.com/blog/shutdown | 2026-11-04 | ok as worded here; "sunsetting" alone misleads |
| <!-- claim:16 --> 16 | Vibe Kanban coordinates agents by workspace isolation and a human board; it has no agent-to-agent inbox. | Not stated either way on the page; absence is not a source. | n/a | 2026-11-01 | cut (say what it is, not what it lacks) |
| <!-- claim:17 --> 17 | Claude Code subagents work within a single session, each in its own context window, and return a summary to the caller. | "Subagents work within a single session."; "Each subagent runs in its own context window ... returns only the summary." | https://code.claude.com/docs/en/sub-agents | 2026-11-01 | ok |
| <!-- claim:18 --> 18 | Subagents do not see the caller's conversation history (except a fork). | "It doesn't see your conversation history ... The exception is a fork". | https://code.claude.com/docs/en/sub-agents | 2026-11-01 | ok |
| <!-- claim:19 --> 19 | Named subagents can message each other with `SendMessage`. | Agent teams page table: "Subagents that Claude named when it spawned them can also message each other". | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok. Do not say subagents "cannot talk to each other". |
| <!-- claim:20 --> 20 | Claude Code agent teams are experimental and off by default (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). | "Agent teams are experimental and disabled by default." | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok |
| <!-- claim:21 --> 21 | Agent teams have a shared task list claimed with file locking and a per-agent mailbox stored as JSON files under `~/.claude/teams/`. | "Task claiming uses file locking"; "~/.claude/teams/{team-name}/inboxes/{agent-name}.json". | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok |
| <!-- claim:22 --> 22 | An agent team is scoped to one session (one team per session, no nested teams, cannot be shared across sessions), and in-process teammates are not restored by `/resume`. | Limitations section. | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok |
| <!-- claim:23 --> 23 | The workers in Claude Code's agent approaches are Claude sessions. | "In every approach the workers are Claude sessions. To involve a different tool, expose it to Claude as an MCP server." | https://code.claude.com/docs/en/agents | 2026-11-04 | ok as "the workers are Claude sessions"; cut as "cannot include Codex" |
| <!-- claim:24 --> 24 | Claude Code can message your other Claude Code sessions on the same machine out of the box (cross-session messaging), over a per-session Unix socket, not through Anthropic servers. Needs v2.1.224+. | "Cross-session messaging requires Claude Code v2.1.224 or later"; "Over a per-session socket ... never through Anthropic servers". | https://code.claude.com/docs/en/cross-session-messaging | 2026-11-01 | ok. This is the closest built-in rival to agentbus; the README must name it. |
| <!-- claim:25 --> 25 | Cross-session messages are plain text between live sessions. An idle receiving session starts a new turn with the message. A script or hook can post to a session's socket. | "Claude sends only plain text across sessions"; "When the receiving session is idle, Claude Code starts a new turn with the message."; `CLAUDE_CODE_MESSAGING_SOCKET`. | https://code.claude.com/docs/en/cross-session-messaging | 2026-11-04 | ok. Idle wake is a real advantage agentbus lacks (claim 35). Cut "no history" (page does not say). |
| <!-- claim:26 --> 26 | Cross-session messaging can also reach sessions on other machines and cloud sessions via Remote Control (needs claude.ai sign-in). agentbus is local only. | Table "How the message travels"; availability section. | https://code.claude.com/docs/en/cross-session-messaging | 2026-11-01 | ok. A real advantage over agentbus. |
| <!-- claim:27 --> 27 | cabildo is a bus and chat room for parallel agents: messaging, presence, advisory locks (default TTL 600 s); hooks deny risky git, such as `git push` while another agent is live, and do not gate file edits; messages sync across machines, locks stay per-machine; read-only web view; Claude Code, Codex and opencode; one SQLite database under `~/.cabildo`; Python 3.11+ with dependencies (mcp, textual and others); MIT. | PyPI JSON (cabildo 0.1.154, uploaded 2026-11-03): "`git push`" "while any other agent is simply live on the project"; "Not enforced: **file edits**"; "LAN/WAN sync covers messages for one project; locks stay per-machine"; "read-only web view"; "All state is one SQLite database"; `requires_python` >=3.11; `requires_dist`. | https://pypi.org/project/cabildo/ | 2026-11-04 | ok. Say hook-level git guard; "hook-enforced locks" overstates it. |
| <!-- claim:28 --> 28 | Korabus is a pre-alpha name reservation on PyPI, not usable software. | "Pre-alpha namespace reservation."; "2 - Pre-Alpha". | https://pypi.org/project/korabus/ | 2026-11-01 | ok but leave it out of the README (nothing to compare). |
| <!-- claim:29 --> 29 | CoordinationHub is a local MCP hub with region-level file locks (TTL), direct messages, handoffs and a local dashboard on 127.0.0.1:9898; Python 3.10+; MIT; Alpha; its description says active development is paused as of May 2026. | PyPI JSON (0.8.0, 2026-06-11). | https://pypi.org/project/coordinationhub/ | 2026-11-01 | ok. Region locks (line ranges) are finer than agentbus path claims. |
| <!-- claim:34 --> 34 | Codex has a stable built-in command that queues a text message for an existing session. | `codex queue`, maturity Stable: "Queue a text message for an existing session by UUID or exact name." | https://developers.openai.com/codex/cli/reference | 2026-11-04 | ok |
| <!-- claim:38 --> 38 | `tmux send-keys` sends keys to a pane, whatever program is running there. | `man tmux` (tmux 3.8): "Send a key or keys to a window or client."; takes `-t target-pane`. | local man page | 2026-11-04 | ok |
| <!-- claim:39 --> 39 | A shared Markdown file or a GitHub issue needs nothing new installed and people read it with no tool. GitHub issues reach across machines and need a GitHub account to write. agentbus keeps no account and stays on the machine. | Common knowledge of the tools, stated for the comparison; agentbus side: claims 37 and 30. | n/a | 2026-11-04 | ok, no quote needed; a claim beyond this wording is cut |

## agentbus (own claims, ground against the repo before the post)

| id | Claim | Evidence | Checked | Status |
|---|---|---|---|---|
| <!-- claim:30 --> 30 | One file, no server, no dependencies, one SQLite file. | README header; `bin/agentbus` stdlib only (verify with the 07/12 gates before the post). | 2026-11-01 | ok, re-run at launch |
| <!-- claim:31 --> 31 | Claims are advisory and expire (`claim --ttl-min`, max one week). | `bin/agentbus` `cmd_claim`: `--ttl-min must be at least 1 and at most MAX_TTL_MIN`. | 2026-11-01 | ok |
| <!-- claim:32 --> 32 | Works for Claude Code, Codex and any agent that can run a shell command. | README; the Codex path is `agentbus setup codex` (task 02). | 2026-11-01 | ok once 02 lands, else cut |
| <!-- claim:33 --> 33 | Python 3.9+, macOS and Linux. | README badge; CI matrix per the runbook gates. | 2026-11-01 | ok |
| <!-- claim:35 --> 35 | agentbus cannot start a turn in an idle session. An agent sees a message when it next checks. | The hooks add text at session start, prompt, edit and turn end, and "never" block: `docs/how-to/claude-code.md` "What the hooks do"; nothing in `bin/agentbus` signals a session. | 2026-11-04 | ok |
| <!-- claim:36 --> 36 | agentbus has no MCP server; agents run a plain command from a shell. | `grep -i mcp bin/agentbus` finds nothing. | 2026-11-04 | ok |
| <!-- claim:37 --> 37 | One bus per folder, buses nest, and the bus file stays after every session ends: unread messages, claims until they expire, facts and history. Local machine only. | `docs/reference.md` "Discovery and nesting"; `agentbus read`, `log show`, `ctx history`; `leave` releases that agent's claims only. | 2026-11-04 | ok |

## Fair positioning

Where others are better (the README table says so):

- Agent Mail (the Rust build; the Python one is deprecated): web UI and TUI, searchable history, Git archive, a pre-commit guard that can block conflicting commits, Windows binaries, a broader agent list.
- Claude Code cross-session messaging and agent teams: built in, nothing to install, starts a turn in an idle session (agentbus cannot wake anyone), reaches other machines and cloud sessions, a shared task list.
- Codex `codex queue`: built in and stable, messages an existing session from a shell.
- cabildo: a hook-level git guard (file edits are not gated), messages that sync across machines, a read-only web viewer.
- CoordinationHub: line-range locks, dashboard.
- Vibe Kanban: a visual board with diff review and PR creation (its company closed in April 2026; the project is community maintained).

Where agentbus is different: Claude Code, Codex, scripts and you on one inbox, with claims and history in one file. A single standard-library Python file, a per-folder bus that nests, and no MCP. "One file and one SQLite database with no server" is not unique: ericfitz/agentbus says "one Go binary and one SQLite file" and cabildo "All state is one SQLite database". Do not say it is.

Line for copy: "Claude Code can already message its own sessions and Codex can queue a message to one of its own; agentbus is the shared store when Claude Code, Codex, scripts and you need one inbox, file claims and history." (claims 24, 34, 37.) Do not use "Agent Mail runs as a server on Python 3.14": it compares against a version its author says not to install.

## README table: which claim backs each row

| README row | Where it is better | Where agentbus fits |
|---|---|---|
| Claude Code messaging | 24, 25, 26 | 37; 32 for Codex |
| Claude Code subagents and agent teams | 17, 20, 21 | 23, 22, 37 |
| `codex queue` | 34 | 37; 32 for Claude Code |
| MCP Agent Mail | 6, 10, 1, 8, 5 | 36 |
| cabildo | 27 | 33, 30, 27, 37 |
| Vibe Kanban | 15, 13 | 32 |
| A shared Markdown file, or GitHub issues | 39 | 31, 37, 39 |
| `tmux send-keys` | 38 | 37 |
