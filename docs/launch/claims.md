# Launch claims

Every factual statement about another tool in the README comparison and the launch post has one row. Sources are primary (the project's own repo, package page or docs). Checked 2026-11-01 by fetching each URL; a fetch summarised by a small model, so the claim-gate lanes must re-read the quoted phrase at the source before the final bytes ship. A claim not marked `ok` is cut. No star counts anywhere.

Status: `ok` = source says it on the date checked. `cut` = unverified, stale or contradicted; do not use.

## Competitors

| id | Claim | Evidence (quote or file) | Source URL | Checked | Status |
|---|---|---|---|---|---|
| <!-- claim:1 --> 1 | MCP Agent Mail is a coordination layer for AI coding agents with agent identities, an inbox/outbox, searchable message history and voluntary file reservation leases. | "memorable identities, an inbox/outbox, searchable message history, and voluntary file reservation 'leases.'" | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:2 --> 2 | Agent Mail runs as a server. | README: "an HTTP-only FastMCP server"; default port 8765; start with `scripts/run_server_with_token.sh`. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:3 --> 3 | Agent Mail needs Python 3.14 (with uv). | "Create a Python 3.14 virtual environment and install dependencies" | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:4 --> 4 | Agent Mail keeps messages in a per-project Git repo and indexes in SQLite with FTS5. | README: Git for human-auditable artifacts, SQLite for indexing and queries. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:5 --> 5 | Agent Mail's file reservations are advisory with a TTL; conflicts are reported but the reservation is still granted; an optional pre-commit guard can block conflicting commits. | "advisory file reservations for editing surfaces"; `file_reservation_paths` takes a TTL and exclusive flag. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:6 --> 6 | The Python Agent Mail is in maintenance mode; new users are pointed to a Rust rewrite. | "Status: Maintenance mode"; Python version "no longer actively developed"; links `mcp_agent_mail_rust`. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok |
| <!-- claim:7 --> 7 | Agent Mail's Python README is inconsistent on transport (says HTTP-only and also lists a stdio option). | Both phrases appear on the page. | https://github.com/Dicklesworthstone/mcp_agent_mail | 2026-11-01 | ok (do not state a transport for the Python version; say "a server") |
| <!-- claim:8 --> 8 | The Rust Agent Mail runs `mcp-agent-mail serve` as an HTTP server on 127.0.0.1:8765, also supports stdio, installs from a prebuilt binary (Linux, macOS, Windows) and uses SQLite plus Git. | "Agent Mail supports both stdio and HTTP transports"; "SQLite for live state, Git for the durable ledger"; source build "Requires Rust nightly". | https://github.com/Dicklesworthstone/mcp_agent_mail_rust | 2026-11-01 | ok |
| <!-- claim:9 --> 9 | Agent Mail (Rust) supports Claude Code, Codex CLI, Gemini CLI, Oh My Pi and GitHub Copilot CLI. | README supported-agent list. | https://github.com/Dicklesworthstone/mcp_agent_mail_rust | 2026-11-01 | ok |
| <!-- claim:10 --> 10 | Agent Mail has a web UI (served at `/mail`) and a TUI (Rust). Better than agentbus's terminal `watch` for browsing history. | "Web UI is served at /mail"; Rust: "with a TUI". | both Agent Mail repos above | 2026-11-01 | ok |
| <!-- claim:11 --> 11 | Agent Mail's licence. | Python page shows a "License" link only; Rust badge reads "MIT+Rider", terms not read. | https://github.com/Dicklesworthstone/mcp_agent_mail_rust | 2026-11-01 | cut (never state a licence; read LICENSE first if wanted) |
| <!-- claim:12 --> 12 | Agent Mail last commit or release date. | Not shown on the pages fetched. | n/a | 2026-11-01 | cut |
| <!-- claim:13 --> 13 | Vibe Kanban is a kanban board that runs coding agents in isolated workspaces (branch, terminal, dev server) with diff review and PR creation. | README summary as fetched. | https://github.com/BloopAI/vibe-kanban | 2026-11-01 | ok |
| <!-- claim:14 --> 14 | Vibe Kanban runs with `npx vibe-kanban` and needs an authenticated coding agent; supports Claude Code, Codex, Gemini CLI, Copilot, Amp, Cursor, OpenCode and others; Apache-2.0. | "npx vibe-kanban"; agent list; Apache-2.0 as fetched. | https://github.com/BloopAI/vibe-kanban | 2026-11-01 | ok |
| <!-- claim:15 --> 15 | Vibe Kanban is sunsetting. | README: "Vibe Kanban is sunsetting." linking https://www.vibekanban.com/blog/shutdown. The announcement itself failed to load (SSL error), so no date or reason read. | https://github.com/BloopAI/vibe-kanban | 2026-11-01 | ok for "its README says it is sunsetting"; cut for any date, reason or "shut down" |
| <!-- claim:16 --> 16 | Vibe Kanban coordinates agents by workspace isolation and a human board; it has no agent-to-agent inbox. | Not stated either way on the page; absence is not a source. | n/a | 2026-11-01 | cut (say what it is, not what it lacks) |
| <!-- claim:17 --> 17 | Claude Code subagents work within a single session, each in its own context window, and return a summary to the caller. | "Subagents work within a single session."; "Each subagent runs in its own context window ... returns only the summary." | https://code.claude.com/docs/en/sub-agents | 2026-11-01 | ok |
| <!-- claim:18 --> 18 | Subagents do not see the caller's conversation history (except a fork). | "It doesn't see your conversation history ... The exception is a fork". | https://code.claude.com/docs/en/sub-agents | 2026-11-01 | ok |
| <!-- claim:19 --> 19 | Named subagents can message each other with `SendMessage`. | Agent teams page table: "Subagents that Claude named when it spawned them can also message each other". | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok. Do not say subagents "cannot talk to each other". |
| <!-- claim:20 --> 20 | Claude Code agent teams are experimental and off by default (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). | "Agent teams are experimental and disabled by default." | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok |
| <!-- claim:21 --> 21 | Agent teams have a shared task list claimed with file locking and a per-agent mailbox stored as JSON files under `~/.claude/teams/`. | "Task claiming uses file locking"; "~/.claude/teams/{team-name}/inboxes/{agent-name}.json". | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok |
| <!-- claim:22 --> 22 | An agent team is scoped to one session (one team per session, no nested teams, cannot be shared across sessions), and in-process teammates are not restored by `/resume`. | Limitations section. | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok |
| <!-- claim:23 --> 23 | Agent teams are Claude Code only. | The page describes Claude Code instances only; no statement about other tools. | https://code.claude.com/docs/en/agent-teams | 2026-11-01 | ok as "teammates are Claude Code sessions"; cut as "cannot include Codex" |
| <!-- claim:24 --> 24 | Claude Code can message your other Claude Code sessions on the same machine out of the box (cross-session messaging), over a per-session Unix socket, not through Anthropic servers. Needs v2.1.224+. | "Cross-session messaging requires Claude Code v2.1.224 or later"; "Over a per-session socket ... never through Anthropic servers". | https://code.claude.com/docs/en/cross-session-messaging | 2026-11-01 | ok. This is the closest built-in rival to agentbus; the README must name it. |
| <!-- claim:25 --> 25 | Cross-session messages are plain text between live sessions; delivery is to a running session's socket, with no stored history or file claims described. | "Claude sends only plain text across sessions"; session "appears only when it binds an inbox socket". | https://code.claude.com/docs/en/cross-session-messaging | 2026-11-01 | ok for "between live Claude Code sessions, plain text"; cut for "no history" (page does not say) |
| <!-- claim:26 --> 26 | Cross-session messaging can also reach sessions on other machines and cloud sessions via Remote Control (needs claude.ai sign-in). agentbus is local only. | Table "How the message travels"; availability section. | https://code.claude.com/docs/en/cross-session-messaging | 2026-11-01 | ok. A real advantage over agentbus. |
| <!-- claim:27 --> 27 | cabildo is an IPC bus and chat room for parallel Claude Code agents: messaging, presence, advisory locks (default TTL 600 s) enforced through hooks; runs locally, no server or account; optional daemon; Python 3.11+; MIT; can wire Claude Code and Codex to one bus. | PyPI JSON (cabildo 0.1.144, uploaded 2026-11-01). | https://pypi.org/project/cabildo/ | 2026-11-01 | ok. Closest direct rival (no server, TTL claims). Hook enforcement of locks is a real advantage over advisory-only claims. |
| <!-- claim:28 --> 28 | Korabus is a pre-alpha name reservation on PyPI, not usable software. | "Pre-alpha namespace reservation."; "2 - Pre-Alpha". | https://pypi.org/project/korabus/ | 2026-11-01 | ok but leave it out of the README (nothing to compare). |
| <!-- claim:29 --> 29 | CoordinationHub is a local MCP hub with region-level file locks (TTL), direct messages, handoffs and a local dashboard on 127.0.0.1:9898; Python 3.10+; MIT; Alpha; its description says active development is paused as of May 2026. | PyPI JSON (0.8.0, 2026-06-11). | https://pypi.org/project/coordinationhub/ | 2026-11-01 | ok. Region locks (line ranges) are finer than agentbus path claims. |

## agentbus (own claims, ground against the repo before the post)

| id | Claim | Evidence | Checked | Status |
|---|---|---|---|---|
| <!-- claim:30 --> 30 | One file, no server, no dependencies, one SQLite file. | README header; `bin/agentbus` stdlib only (verify with the 07/12 gates before the post). | 2026-11-01 | ok, re-run at launch |
| <!-- claim:31 --> 31 | Claims are advisory and expire (`claim --ttl-min`, max one week). | `bin/agentbus` `cmd_claim`: `--ttl-min must be at least 1 and at most MAX_TTL_MIN`. | 2026-11-01 | ok |
| <!-- claim:32 --> 32 | Works for Claude Code, Codex and any agent that can run a shell command. | README; the Codex path is `agentbus setup codex` (task 02). | 2026-11-01 | ok once 02 lands, else cut |
| <!-- claim:33 --> 33 | Python 3.9+, macOS and Linux. | README badge; CI matrix per the runbook gates. | 2026-11-01 | ok |

## Fair positioning

Where others are better (say so in the README table):

- Agent Mail: web UI and searchable history, Git-backed audit trail, a pre-commit guard that can block conflicting commits, MCP-native, broader agent list, active Rust rewrite.
- Claude Code cross-session messaging and agent teams: built in, nothing to install, reach other machines and cloud sessions, a shared task list with dependencies.
- cabildo: hook-enforced locks, presence, daemon-driven push and spawn.
- CoordinationHub: line-range locks, dashboard.
- Vibe Kanban: a visual board with diff review and PR creation (but its README says it is sunsetting).

Where agentbus is genuinely different: one file and one SQLite database with no server, daemon or runtime beyond Python 3.9; works across tools (Claude Code, Codex, scripts, you) in one folder; history persists in the file; agents can find the bus from any nested repo or worktree.

Strongest honest line: "Agent Mail runs as a server on Python 3.14; agentbus is one file and a SQLite database, with Claude Code, Codex and you reading the same inbox." (claims 2, 3, 30; "Claude Code, Codex" row 32.) Safer still: "Claude Code can already message its own sessions; agentbus is for when Codex, scripts and you need the same inbox and file claims."
