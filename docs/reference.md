# agentbus reference

## Setup

`agentbus init [DIR]` installs `.agentbus/bin/agentbus` and VERSION in an existing directory: a repo or a workspace of repos. DIR defaults to cwd. At a checkout root, it adds `.agentbus/` to the local git exclude. Nested init names the outer bus. The database appears on first use.

Run agents through that copy, using its absolute path from other directories. Run init and `upgrade [DIR]` from the installed tool or a source clone. Upgrade keeps its checkout resolution: DIR selects a repo's main checkout, whose copy is replaced.

### Upgrade and schema versions

`agentbus upgrade [DIR]` replaces the copy and opens the bus once, which migrates it when needed. `agentbus upgrade --all DIR [--depth N] [--dry-run]` does that for every bus folder under DIR (depth 5 by default; never follows a symlink; skips `.git`, `node_modules`, `.venv`, `__pycache__`), one line per bus, and exits 1 when any bus failed. A copy newer than the tool is skipped, never downgraded. Each bus gets 5 seconds to be free; a bus held longer is reported failed.

`PRAGMA user_version` is the bus's schema version (1 in this release, the v0.1.0 shape). A v0.1.0 bus is adopted by stamping 1, with no other write and no backup. A bus that needs a migration is backed up to `.agentbus/backups/bus-v<old>-<UTC time>.db` (0600, checked byte for byte; the newest 5 are kept, with the copy `upgrade` replaced beside each) before any write, then migrated, checked and stamped in one transaction. `watch` changes no data or schema (it may finish SQLite's recovery of a crashed writer's journal): it reports an older bus instead (`schema_older`). `upgrade --dry-run` applies no upgrade and writes no copy or backup. An older copy refuses a newer bus (`schema_newer`); a 0.1.0 copy refuses it as `schema_refused`. Backups, restore and the stale-copy notice: `docs/how-to/upgrade.md`.

## Discovery and nesting

Commands walk from cwd to the nearest ancestor containing `.agentbus/`. Linked worktrees first map cwd to the same relative spot in their main checkout, even when the worktree sits outside the workspace. `$HOME/.agentbus` is never discovered. Unsafe bus folders are refused, never skipped.

No bus means: `agentbus: no bus here or in any parent folder. Run: agentbus init <dir>`.

`--up N` selects the Nth bus above the nearest (default 0). `--up 1` reaches the next outer bus; a missing level is an error. Like `--as` and `--json`, it works before or after the subcommand.

`buses` lists the whole chain: level, directory, and whether bus.db exists. It creates no database. `buses --json` returns objects with `level`, `directory`, and `exists`. `status` shows the selected database path; `watch` shows its directory and honours `--up`.

Claims and messages are per bus; nothing merges across buses.

## Explicit buses

`AGENTBUS_DB` overrides discovery and `--up`; relative paths become absolute from cwd. With it set, `buses` lists only that explicit bus. Dispatchers set it for themselves and their lanes. See [sandboxed agents](sandboxed-agents.md).

## Claims and messages

Follow the [skill](../skills/agentbus/SKILL.md): join, check inbox between steps, claim before editing, release when done, and leave.

Path claims are relative to the bus's directory. Paths normalise `./`, repeated slashes and `..`; absolute and escaping paths are refused. A path includes its descendants, with or without a trailing slash. Resources compare as given after normalisation, case included. Scheme names such as `issue:17` compare exactly. Claims are advisory, at most 1024 characters, and expire after 120 minutes by default (`--ttl-min`: 1 to 10080). Claim again to renew; omitted `--purpose` preserves the current purpose, and the original `claimed_at` stays unchanged. `release RESOURCE --if-held` succeeds when you do not hold it, for cleanup scripts.

New identities receive older direct messages, but broadcasts only from their first join onward. `read` shows history. Inbox marks returned messages read after stdout writes successfully. This does not confirm that a downstream consumer read or processed them. Do not truncate a consuming inbox with `head`; use `inbox --limit N`. Use `inbox --peek` when inspecting without consuming. Delivery is at least once: a crash or concurrent calls can repeat a message. `--reply-to` links a message without choosing its recipient.

## Output

Use `--json` for parsing and check exit status; errors go to stderr. Human output escapes controls, invisible characters and backslashes. Rows start with tool-written text or two spaces, and wrap with indented continuations. JSON preserves stored text. Human message headers start with `#<integer id> `, followed by sender, recipient (`everyone` for broadcasts), kind and reply target. Local time comes last: `HH:MM` today, otherwise `Nov 1 16:19`; JSON timestamps stay UTC.

A nonzero exit does not imply rollback. A write command may commit before output fails; inspect the bus before retrying.

Listings default to 500 rows (log: 40; recent status messages: 10); `--limit -1` shows all. With `--json` they return an envelope that says whether rows were left out (see JSON output). Leave and release-all report at most 500 claims but release everything. A body of `-` reads stdin; an empty body is refused.


## Goal

`agentbus --as NAME goal "text"` sets the shared goal; `agentbus goal` shows it, with who set it and when. `-` reads the text from stdin. `--json` prints `{goal, set_by, set_at}`, or `null` when there is none. Setting the goal it already holds changes nothing and reports `unchanged: true`.

The goal is the context key `goal`, so `ctx history goal` lists every version. `join` prints `goal: ...` when one is set, and `status` opens with `== goal: ...`. `watch` pins it on the row under its header (🎯, or ◆ without emoji) and leaves it out of Facts.

## Watch

`agentbus watch` redraws in place until `q`, `Esc` or `Ctrl-C`. `--interval` sets 0.2 to 60 seconds, `--once` prints one frame, and `--json` prints one snapshot. Piped output also prints one frame. It needs 40 columns. `NO_COLOR` turns colour off.

On a terminal, watch shows emoji: a role per agent (🧠 brain or lead, ✋ lane, hand or implementer, 🧪 tests, 🔍 review, 📚 docs, 🚀 ops, 🎨 design, 🙋 human, 🤖 otherwise), a kind per message (🤝 handoff, ❓ question, 💬 answer, ✅ done, 🧭 decision, 🚨 alert, 📝 note) and a section icon (👥 🔒 📌 💬). `AGENTBUS_NO_EMOJI=1` turns them off. They never appear when stdout is not a terminal.

## JSON output

Use `--json` to parse results. On success stdout holds exactly one JSON value and the exit status is `0`; stderr may hold non-error notices. Read stdout and the exit status, never the two streams merged. `agentbus schema --json` prints everything on this page in machine form: every command's arguments, result schema, error codes, retry rule and exit codes. `agentbus schema` prints a one-screen table, and each command's `--help` ends with its result and retry line.

Contract version. `join --json` reports `agentbus` (the version of the running copy) and `contract` (`1`). Within contract 1 changes are additive: new keys on results, new error codes and new commands. Removing or renaming a key, changing a type or changing an exit status bumps `contract` and is listed under "Changed" in the CHANGELOG. A listing that prints a bare `[...]` instead of an object with `items` comes from a 0.1.x copy; upgrade it.

### Listings

Commands that list rows return an envelope, `{"v": 1, "items": [...], "has_more": false, "next": null}`:

- `items` is the array 0.1.x returned, with the same row shape and order.
- `has_more` is `true` when rows were left out by `--limit`. An empty `items` with `has_more: true` means "ask again", not "nothing to do" (`inbox --limit 0` is the clearest case).
- `next` is `null` except for the four id walks below, where it is an opaque cursor: pass it back unchanged and do not parse it. A cursor belongs to its command and filters (`--topic`, the key of `ctx history`, the agent of `inbox --peek`); one used with another command or other filters is `bad_input` (exit 2).

| Command | `items` order | `has_more` means | Continue with |
| --- | --- | --- | --- |
| `who` | last seen, newest first | more agents than `--limit` | raise `--limit`; no cursor |
| `claims`, `claims --stale` | resource, ascending | more claims than `--limit` | raise `--limit`; no cursor |
| `ctx get` | key, ascending | more facts than `--limit` | raise `--limit`; no cursor |
| `ctx history KEY` | newest `--limit` rows, shown by id ascending | older rows exist | `--before NEXT` |
| `read` | newest `--limit` rows, shown by id ascending | older rows exist | `--before NEXT` |
| `read --since ID` | the next `--limit` rows after ID | more rows after them | `--since` the last id (no cursor; `--before` cannot be combined with `--since`) |
| `log show` | newest `--limit` rows, shown by id ascending | older rows exist | `--before NEXT` |
| `inbox` | oldest unread first | unread messages remain | run `inbox` again (it marks what it returned as read) |
| `inbox --peek` | oldest unread first | unread messages remain | `--after NEXT` |
| `buses` | nearest first | always `false` | none |

The four cursor walks (`ctx history`, `read`, `log show`, `inbox --peek`) page over row ids that never change and only grow, so walking back with `--before` never skips or repeats a row whatever is posted meanwhile, and a forward `inbox --peek --after` walk sees new messages at its end. `who`, `claims` and `ctx get` have no cursor because their sort keys change (last seen, a renewed claim); raise `--limit` or filter. `status` and `watch --json` carry `omitted`, the number of rows each section left out (`0` when complete). Human output keeps its `... N more (use --limit)` hints.

### Results

Other commands return one object. `{...}` lists exact keys; `[X]` is an array of X; a `null` alternative is a literal JSON `null`. `unchanged` is `true` when `ctx set` or `goal` found the value already stored and wrote nothing.

<!-- generated:results -->
| Command | `--json` result |
| --- | --- |
| `join` | `{"joined": string, "bus": string, "goal": null or Goal, "agentbus": string, "contract": integer}` |
| `leave` | `{"left": string, "released": [string], "released_count": integer}` |
| `who` | `{"v": integer, "items": [Agent], "has_more": boolean, "next": string or null}` |
| `post` | `{"id": integer}` |
| `inbox` | `{"v": integer, "items": [Message], "has_more": boolean, "next": string or null}` |
| `read` | `{"v": integer, "items": [Message], "has_more": boolean, "next": string or null}` |
| `ctx set` | `Fact` |
| `ctx get` | `a Fact, or {"v": integer, "items": [Fact], "has_more": boolean, "next": string or null}` |
| `ctx history` | `{"v": integer, "items": [FactVersion], "has_more": boolean, "next": string or null}` |
| `claim` | `{"resource": string, "agent": string, "purpose": string or null, "claimed_at": string, "expires_at": string, "auto_released": [{"resource": string, "agent": string}], "auto_released_count": integer}` |
| `release` | `{"released": [string], "released_count": integer}` |
| `claims` | `{"v": integer, "items": [Claim], "has_more": boolean, "next": string or null}` |
| `log add` | `{"id": integer, "logged": boolean, "agent": string, "action": string, "detail": string}` |
| `log show` | `{"v": integer, "items": [LogEntry], "has_more": boolean, "next": string or null}` |
| `status` | `{"bus": string, "goal": null or Goal, "agents": [Agent], "context": [Fact], "claims": [Claim], "messages": [Message], "omitted": {"agents": integer, "context": integer, "claims": integer, "messages": integer}}` |
| `goal` | `null or a Goal` |
| `watch` | `{"bus": string, "directory": string, "agents": [{"name": string, "role": string or null, "last_seen": string, "joined_at": string}], "claims": [{"resource": string, "agent": string, "purpose": string or null, "expires_at": string}], "goal": null or Goal, "context": [Fact], "messages": [{"id": integer, "ts": string, "sender": string, "recipient": string, "kind": string, "body": string, "reply_to": integer or null}], "counts": {"agents": integer, "claims": integer, "messages": integer}, "omitted": {"agents": integer, "context": integer, "claims": integer, "messages": integer}}` |
| `buses` | `{"v": integer, "items": [BusLevel], "has_more": boolean, "next": string or null}` |
| `init` | `{"directory": string, "copy": string, "old": string, "new": string, "exclude_added": boolean, "gitignore_rule": boolean, "outer": string or null}` |
| `upgrade` | `{"directory": string, "old": string, "new": string, "schema_old": integer or null, "schema_new": integer or null, "backup": string or null}, or with --all or --dry-run {"buses": [UpgradeRow], "upgraded": integer, "current": integer, "skipped": integer, "failed": integer, "would_upgrade": integer (--dry-run)}` |
| `schema` | `{"contract": integer, "agentbus": string, "commands": object, "objects": object, "error_fields": object, "errors": object, "exit_codes": object, "env": object}` |
| `skill` | `{"text": string}` |
| `setup` | `{"target": string, "scope": string, "dry_run": boolean, "changes": [{"path": string, "detail": string, "action": string, "backup": string (only when a backup was saved)}]}` |
| `doctor` | `{"agentbus": string, "path": string, "contract": integer, "checks": [{"id": string, "status": "ok" \| "warn" \| "fail" \| "n/a", "detail": string, "fix": string or null, "hint": string or null, "scope": string (when it applies)}], "fail": integer, "warn": integer}; exit 1 (items_failed) when fail > 0` |
<!-- /generated:results -->

Shared objects. Nullable fields use JSON `null`; IDs and counts are integers; timestamps are UTC strings in JSON.

<!-- generated:objects -->
| Object | Fields |
| --- | --- |
| `Agent` | `name`, `tool`, `model`, `cwd`, `branch`, `role`, `joined_at`, `last_seen` |
| `Message` | `id`, `ts`, `sender`, `recipient`, `kind`, `topic`, `body`, `reply_to` |
| `Claim` | `resource`, `agent`, `purpose`, `claimed_at`, `expires_at`, `state` |
| `Fact` | `key`, `value`, `updated_by`, `updated_at`, `unchanged` (optional) |
| `FactVersion` | `id`, `key`, `value`, `updated_by`, `updated_at` |
| `LogEntry` | `id`, `ts`, `agent`, `action`, `detail` |
| `Goal` | `goal`, `set_by`, `set_at`, `unchanged` (optional) |
| `BusLevel` | `level`, `directory`, `exists`, `copy_version`, `stale` |
| `UpgradeRow` | `directory`, `status`, `old`, `new`, `schema_old`, `schema_new`, `backup`, `error` |
| `DoctorCheck` | `id`, `status`, `detail`, `fix`, `hint`, `scope` (optional) |
<!-- /generated:objects -->

`watch --json` returns once, with or without `--once`; its row projections differ from `status`. Data written directly through SQLite can have other types; JSON renders BLOBs and non-finite numbers as strings.

### Failures

A failing command exits non-zero and, under `--json`, prints one JSON object on stderr: `{"error": {"code": "claim_conflict", "message": "...", "retryable": false, "committed": false, ...}}`, plus the fields listed for its code below. Branch on `error.code`, not on the message. Every error object carries these fields:

<!-- generated:error-fields -->
| Field | Type | Meaning |
| --- | --- | --- |
| `code` | string | One of the error codes below; branch on this, not on the message. |
| `message` | string | What happened and what to do, for a person. |
| `retryable` | boolean | Whether running the same command again can succeed. False once the command saved database rows, unless it had a --request-id; a command that changed only files (init, upgrade's copy, setup) stays retryable. |
| `committed` | boolean | True when the command's own change had been saved before the failure, so a write must not be repeated without its --request-id unless retryable is true. |
<!-- /generated:error-fields -->

What stdout holds depends on when the failure happened:

1. Before any output (argument parsing, identity, finding or opening the bus, a refusal, a database error before the result was built): stdout is empty and the exit status is the code's. The one refusal with output is `items_failed` (point 4).
2. During output (the reader closed the pipe, a partial write): stdout may hold part of the value and the code is `output_failed`. If the command wrote something, `committed` is `true` and the write stands: a `post` that could not print was saved; retry with the same `--request-id`. A command that only reads has `committed: false` and can simply be run again.
3. After complete output, when `inbox` marks the messages read: stdout holds the complete value, the code is `ack_failed` (`delivered: true`) and the cursor did not move. Treat the output as delivered, expect the same messages again and dedupe by id (at least once).
4. After complete output, when some of the items failed (`upgrade --all`'s buses, `setup`'s files): stdout holds the whole result, every item with its status, and the code is `items_failed`, whose `failed` lists the items that failed.

Output together with a non-zero exit is possible for `ack_failed`, `output_failed`, `interrupted` and `items_failed`. When `committed` is `true`, any stdout is the complete result and must be read: an `inbox` interrupted inside its mark-read commit prints the full JSON, and its messages are already marked read.

`committed` is `true` when the command's own change had been saved before the failure came (a database error after a `post` committed, an `output_failed` from a write, an `interrupted` after the commit), `false` when nothing was written. `retryable` is never `true` once the command saved database rows, unless it carried `--request-id`: then repeating it returns the saved result with `duplicate: true`. A command that changed only files (`init`, the copy `upgrade` replaced, `setup`) is safe to repeat, so it stays retryable with `committed: true`; an interrupted one names the command that finishes it (`rerun`). The `retryable` column of the table below is the code's own value, before that rule.

Ctrl-C (SIGINT) is `interrupted`, exit `130` in both modes (the shell convention), with one JSON error on stderr under `--json`. Stdout is empty unless `committed` is `true` (see above). A Ctrl-C that lands while a command is committing is held until the commit is recorded, so `committed` is accurate.

### Error codes

<!-- generated:errors -->
| Code | Exit | Retryable | Extra fields | Meaning and what to do |
| --- | --- | --- | --- | --- |
| `claim_conflict` | 1 | no | `resource`, `holder`, `expires_at`, `purpose` | Another agent holds an overlapping claim. Ask the holder, or work elsewhere. |
| `not_held` | 1 | no | `resource` | You do not hold that claim. Nothing to release; use release --if-held for cleanup. |
| `no_message` | 1 | no | `id` | There is no message with that id. Check the id with read. |
| `no_context_key` | 1 | no | `key` | There is no fact with that key. List keys with ctx get. |
| `not_on_roster` | 1 | no | `agent` | That name has not joined. Join first. |
| `name_active` | 1 | no | `agent`, `last_seen_min` | The name was active recently and may be another live session. Pick another name, or join --takeover if it is you. |
| `request_id_reused` | 1 | no | `request_id`, `agent` | That request id was used with a different message. Use a new token for a different message. |
| `bad_input` | 2 | no | none | The arguments are not valid (a usage error). Fix the arguments. |
| `no_bus` | 3 | no | none | There is no bus here or above. Run agentbus init DIR, or set AGENTBUS_DB. |
| `busy` | 3 | yes | `bus` | Another process held the bus for 15 seconds. Retry after a few seconds. |
| `schema_refused` | 3 | no | none | The bus tables are not agentbus's. Stop and tell the user. |
| `schema_older` | 3 | no | `bus`, `bus_schema`, `tool_schema` | The bus is older than this tool and was opened read-only. Run any command that is not watch to upgrade it, or agentbus upgrade DIR. |
| `schema_newer` | 3 | no | `bus`, `bus_schema`, `tool_schema` | The bus is newer than this copy of the tool. Use a newer agentbus. |
| `schema_corrupt` | 3 | no | `bus`, `bus_schema` | bus.db records a schema version no agentbus writes; another tool or a lane changed it. Stop and tell the user; restore a backup (docs/how-to/upgrade.md). |
| `backup_failed` | 3 | no | `bus`, `reason` | The backup before a migration could not be made. Free disk space or move the bus. |
| `copy_newer` | 1 | no | `directory`, `copy_version`, `tool_version` | The folder's copy of agentbus is newer than this one; it is never downgraded. Run upgrade or init with a newer agentbus. |
| `bus_unavailable` | 3 | no | `file` (optional) | The bus or its folder failed a safety check, SQLite or the system refused it, or a command ran out of time. Read the message, fix the folder, then run the command again. |
| `ack_failed` | 3 | yes | `delivered` | inbox printed its messages but could not mark them read. The output was complete: use it, expect the same messages again, and dedupe by id. |
| `output_failed` | 1 | yes | none | stdout could not be written; committed effects stand. Retry with the same token. |
| `interrupted` | 130 | yes | `directory` (optional), `backup` (optional), `migrations` (optional), `rerun` (optional), `changed` (optional) | The command was stopped (Ctrl-C or SIGINT) before it finished. Check committed: if true the change was saved, so repeat a write only with its request id, unless retryable is true (init, upgrade and setup can simply be rerun). |
| `items_failed` | 1 | no | `failed` | Some of the items the command works on failed or were refused (buses of upgrade --all, files of setup, checks of doctor); stdout holds the whole result, and failed lists those items. Read each failed item's error, fix it, then run the command again. |
| `internal` | 4 | no | none | A bug in agentbus. Report it. |
<!-- /generated:errors -->

### Exit codes

The same with and without `--json`. `--version` and `--help` exit `0`. Exit `130` is Ctrl-C, except in live `watch` (a terminal, not `--once`), where quitting with Ctrl-C is the normal way out and exits `0`. A human-mode parse error keeps its one-line `agentbus:` message and exits `2`.

<!-- generated:exit-codes -->
| Exit | Meaning |
| --- | --- |
| `0` | success |
| `1` | the command ran and refused (conflicts, missing things) |
| `2` | usage: bad arguments, unknown command, missing identity |
| `3` | the bus is unavailable or unsafe |
| `4` | internal error |
| `130` | interrupted (Ctrl-C), the shell convention |
<!-- /generated:exit-codes -->

### Retrying safely

A retry after a timeout, a crash or an `output_failed` is safe when the command's class says so.

<!-- generated:retry -->
| Command | Class | How to retry safely |
| --- | --- | --- |
| `join` | idempotent with flag | join --takeover for your own name |
| `leave` | idempotent | a second run reports released_count 0 and writes no log row |
| `who` | safe | repeat freely |
| `post` | needs request id | pass --request-id TOKEN; the same token and payload returns the original id with duplicate true |
| `inbox` | at least once | repeat; a crash or ack_failed redelivers, so check message ids before acting; with `--peek`: safe (repeat freely) |
| `read` | safe | repeat freely |
| `ctx set` | idempotent | an unchanged value writes no history row and returns unchanged true |
| `ctx get` | safe | repeat freely |
| `ctx history` | safe | repeat freely |
| `claim` | idempotent | renews the claim and keeps its purpose and claimed_at |
| `release` | idempotent with flag | release RESOURCE --if-held: not held returns released [] and released_count 0 with exit 0; release --all is already idempotent |
| `claims` | safe | repeat freely |
| `log add` | unsafe | each call appends a row; check log show --limit 1 before retrying |
| `log show` | safe | repeat freely |
| `status` | safe | repeat freely |
| `goal` | idempotent | showing is free; an unchanged goal writes no history row and returns unchanged true |
| `watch` | safe | repeat freely |
| `buses` | safe | repeat freely |
| `init` | idempotent | repeat |
| `upgrade` | idempotent | repeat |
| `schema` | safe | repeat freely |
| `skill` | safe | repeat freely |
| `setup` | idempotent | a second run reports every change unchanged and writes nothing; a refusal exits 1 with the same object |
| `doctor` | safe | repeat freely |
<!-- /generated:retry -->

`post --request-id TOKEN` makes a retry by the same sender return the original message ID with `duplicate: true`. Body, recipient, kind, topic and reply target must match; a different payload gives `request_id_reused`. Tokens belong to their sender and remain on the message row. Without a token each post creates a message.

### Environment

<!-- generated:env -->
| Variable | Meaning | Default |
| --- | --- | --- |
| `AGENTBUS_DB` | Path of the bus database; overrides discovery and --up. | the nearest .agentbus/bus.db above the working directory |
| `AGENTBUS_AGENT` | Your agent identity; --as overrides it. | unset |
| `NO_COLOR` | Turns colour off in watch. | unset |
| `AGENTBUS_NO_EMOJI` | Turns emoji off in watch. | unset |
| `COLUMNS` | Width human output is wrapped to. | the terminal width, else 80 |
<!-- /generated:env -->

## Locking

Each command holds SQLite exclusively and closes it before formatting or printing. Others wait up to 15 seconds. SQL has a 6-second budget; a watchdog caps the whole hold at 8 seconds, leaving slack for a slow machine. Watch closes the bus between frames.

An idle sqlite3 shell or dashboard can block every command. Inspect with `status`, `read` or `--json`, or close the other client between queries. Files stay owner-only; link checks and schema-shape validation run on every open.
