# agentbus reference

## Setup

`agentbus init [DIR]` installs `.agentbus/bin/agentbus` and VERSION in an existing directory: a repo or a workspace of repos. DIR defaults to cwd. At a checkout root, it adds `.agentbus/` to the local git exclude. Nested init names the outer bus. The database appears on first use.

Run agents through that copy, using its absolute path from other directories. Run init and `upgrade [DIR]` from the installed tool or a source clone. Upgrade keeps its checkout resolution: DIR selects a repo's main checkout, whose copy is replaced.

## Discovery and nesting

Commands walk from cwd to the nearest ancestor containing `.agentbus/`. Linked worktrees first map cwd to the same relative spot in their main checkout, even when the worktree sits outside the workspace. `$HOME/.agentbus` is never discovered. Unsafe bus folders are refused, never skipped.

No bus means: `agentbus: no bus here or in any parent folder. Run: agentbus init <dir>`.

`--up N` selects the Nth bus above the nearest (default 0). `--up 1` reaches the next outer bus; a missing level is an error. Like `--as` and `--json`, it works before or after the subcommand.

`buses` lists the whole chain: level, directory, and whether bus.db exists. It creates no database. `buses --json` returns objects with `level`, `directory`, and `exists`. `status` shows the selected database path; `watch` shows its directory and honours `--up`.

Claims and messages are per bus; nothing merges across buses.

## Explicit buses

`AGENTBUS_DB` overrides discovery and `--up`; relative paths become absolute from cwd. With it set, `buses` lists only that explicit bus. Dispatchers set it for themselves and their lanes. See [sandboxed agents](sandboxed-agents.md).

## Claims and messages

Follow the [skill](../skill/SKILL.md): join, check inbox between steps, claim before editing, release when done, and leave.

Path claims are relative to the bus's directory. Paths normalise `./`, repeated slashes and `..`; absolute and escaping paths are refused. A path includes its descendants, with or without a trailing slash. Resources compare as given after normalisation, case included. Scheme names such as `issue:17` compare exactly. Claims are advisory, at most 1024 characters, and expire after 120 minutes by default (`--ttl-min`: 1 to 10080). Claim again to renew; omitted `--purpose` preserves the current purpose, and the original `claimed_at` stays unchanged.

New identities receive older direct messages, but broadcasts only from their first join onward. `read` shows history. Inbox marks returned messages read after stdout writes successfully. This does not confirm that a downstream consumer read or processed them. Do not truncate a consuming inbox with `head`; use `inbox --limit N`. Use `inbox --peek` when inspecting without consuming. Delivery is at least once: a crash or concurrent calls can repeat a message. `--reply-to` links a message without choosing its recipient.

## Output

Use `--json` for parsing and check exit status; errors go to stderr. Human output escapes controls, invisible characters and backslashes. Rows start with tool-written text or two spaces, and wrap with indented continuations. JSON preserves stored text. Human message headers start with `#<integer id> `, followed by sender, recipient (`everyone` for broadcasts), kind and reply target. Local time comes last: `HH:MM` today, otherwise `Nov 1 16:19`; JSON timestamps stay UTC.

A nonzero exit does not imply rollback. A write command may commit before output fails; inspect the bus before retrying.

Listings default to 500 rows (log: 40; recent status messages: 10); `--limit -1` shows all. Leave and release-all report at most 500 claims but release everything. A body of `-` reads stdin; an empty body is refused.


## Goal

`agentbus --as NAME goal "text"` sets the shared goal; `agentbus goal` shows it, with who set it and when. `-` reads the text from stdin. `--json` prints `{goal, set_by, set_at}`, or `null` when there is none.

The goal is the context key `goal`, so `ctx history goal` lists every version. `join` prints `goal: ...` when one is set, and `status` opens with `== goal: ...`. `watch` pins it on the row under its header (🎯, or ◆ without emoji) and leaves it out of Facts.

## Watch

`agentbus watch` redraws in place until `q`, `Esc` or `Ctrl-C`. `--interval` sets 0.2 to 60 seconds, `--once` prints one frame, and `--json` prints one snapshot. Piped output also prints one frame. It needs 40 columns. `NO_COLOR` turns colour off.

On a terminal, watch shows emoji: a role per agent (🧠 brain or lead, ✋ lane, hand or implementer, 🧪 tests, 🔍 review, 📚 docs, 🚀 ops, 🎨 design, 🙋 human, 🤖 otherwise), a kind per message (🤝 handoff, ❓ question, 💬 answer, ✅ done, 🧭 decision, 🚨 alert, 📝 note) and a section icon (👥 🔒 📌 💬). `AGENTBUS_NO_EMOJI=1` turns them off. They never appear when stdout is not a terminal.

## JSON output

Successful `--json` results have these shapes. `[]` means an array; `{...}` lists exact object keys. Listings can be empty and capped; truncation notices use stderr. Failures print one JSON object on stderr: `{"error": {"code": "...", "message": "..."}}`, with the fields below when applicable. Messages are cleaned; fields preserve their values with JSON escaping. Stdout is empty for errors detected before output. IDs and counts are integers; other scalars are strings unless noted. Nullable fields use JSON `null`.

| Command | Shape |
| --- | --- |
| `join` | Object `{joined, bus, goal}`; goal is a Goal object or null |
| `goal` | Goal object `{goal, set_by, set_at}`; `null` when shown and none is set |
| `leave` | Object `{left, released: string[], released_count: integer}` |
| `who` | Agent array |
| `post` | Object `{id: integer}`; an idempotent retry returns `{id: integer, duplicate: true}` |
| `inbox`, `read` | Message array |
| `ctx set`, `ctx get KEY` | Fact object |
| `ctx get` | Fact array |
| `ctx history KEY` | Array of `{id: integer, key, value, updated_by, updated_at}`, oldest first within the newest limit |
| `claim` | Object `{resource, agent, purpose, claimed_at, expires_at, auto_released: [{resource, agent}], auto_released_count: integer}`; purpose nullable |
| `release RESOURCE`, `release --all` | Object `{released: string[], released_count: integer}` |
| `claims` | Claim array |
| `log add` | Object `{id: integer, logged: boolean, agent, action, detail}`; logged is true |
| `log show` | Array of `{id: integer, ts, agent, action, detail}`; detail nullable |
| `status` | Object `{bus, goal, agents: Agent[], context: Fact[], claims: Claim[], messages: Message[]}` |
| `watch` | One snapshot object `{bus, directory, agents: [{name, role, last_seen, joined_at}], claims: [{resource, agent, purpose, expires_at}], goal, context: Fact[], messages: [{id, ts, sender, recipient, kind, body, reply_to}], counts: {agents, messages, claims}}`; IDs/counts integers, role/purpose/reply_to nullable |
| `buses` | Array of `{level: integer, directory, exists: boolean}` |
| `init` | Object `{directory, copy, old, new, exclude_added: boolean, gitignore_rule: boolean, outer}`; outer nullable |
| `upgrade` | Object `{directory, old, new}` |

Agent: `{name, tool, model, cwd, branch, role, joined_at, last_seen}`; tool/model/branch/role nullable. Fact: `{key, value, updated_by, updated_at}`. Message: `{id: integer, ts, sender, recipient, kind, topic, body, reply_to: integer or null}`; topic nullable. Claim: `{resource, agent, purpose, claimed_at, expires_at, state}`; purpose nullable, state is `held` or `expired`.

`watch --json` returns once, with or without `--once`; its row projections differ from status. Normal CLI-created records use UTC timestamp strings. Data written directly through SQLite can have other types; JSON renders BLOBs and non-finite numbers as strings.

With `post --request-id TOKEN`, retries by the same sender return the original message ID. Body, recipient, kind, topic and reply target must match; a different payload gives `request_id_reused`. Tokens belong to their sender and remain on the message row. Without a token, each post creates a message. This also handles a retry after stdout closed following a committed post.

| Error code | Additional fields |
| --- | --- |
| `claim_conflict` | `resource` (requested), `holder`, `expires_at`, `purpose` (nullable) |
| `not_on_roster` | `agent` |
| `no_context_key` | `key` |
| `no_message` | `id` (integer) |
| `not_held` | `resource` |
| `busy` | `bus` |
| `no_bus` | None |
| `bad_input` | None; includes argument parsing and validation |
| `schema_refused` | None |
| `request_id_reused` | `request_id`, `agent` |
| `internal` | None; other failures |

## Locking

Each command holds SQLite exclusively and closes it before formatting or printing. Others wait up to 15 seconds. SQL has a 6-second budget; a watchdog caps the whole hold at 8 seconds, leaving slack for a slow machine. Watch closes the bus between frames.

An idle sqlite3 shell or dashboard can block every command. Inspect with `status`, `read` or `--json`, or close the other client between queries. Files stay owner-only; link checks and schema-shape validation run on every open.
