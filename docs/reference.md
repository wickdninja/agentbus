# agentbus reference

## Setup

`agentbus init [DIR]` installs `.agentbus/bin/agentbus` and VERSION in a directory: a repo or a workspace of repos. DIR defaults to cwd. A DIR that does not exist is created with its parents (like `mkdir -p`); a path whose nearest existing parent is not a writable directory, or that is a file, is refused with `bad_input` and nothing is created. At a checkout root, it adds `.agentbus/` to the local git exclude. Nested init names the outer bus. It also makes the empty bus database (the hooks speak only for a bus whose database exists, and a hook never makes one); re-running init on a folder that has a bus leaves the database as it is. One repo, one bus: a DIR that holds linked worktrees of a repository whose bus discovery already finds (the repo's own, or a workspace's above it) is refused with `bad_input`, because the agents in those worktrees use that bus and never one made here. So is a DIR inside a linked worktree, where discovery never looks (it starts from the same folder of the main checkout); the worktree's top folder is always refused. Only linked worktrees that are immediate children count (the first 200 entries are looked at, from git's own files; no program a repository names is run), so a workspace folder of independent repos, each with or without a bus, is never refused. `--second-bus` makes the bus anyway, except at a linked worktree's top folder; a DIR that already has a bus is not refused.

Agents run the installed `agentbus` from `PATH`. When it is not on `PATH` and a `.agentbus/` is in the folder or a parent, the agent tells the user to install it; with no `.agentbus/` the Codex block is ignored. A project's `.agentbus/bin/agentbus` may have come with a clone and is not trusted, so an agent never picks it for itself. A dispatcher that assigns a worker an absolute CLI path and `AGENTBUS_DB` is the one exception (see [Sandboxed agents](sandboxed-agents.md)). Run init and `upgrade [DIR]` from the installed tool or a source clone. Upgrade keeps its checkout resolution: DIR selects a repo's main checkout, whose copy is replaced.

### Upgrade and schema versions

`agentbus upgrade [DIR]` replaces the copy and opens the bus once, which migrates it when needed. `agentbus upgrade --all DIR [--depth N] [--dry-run]` does that for every bus folder under DIR (depth 5 by default; never follows a symlink; skips `.git`, `node_modules`, `.venv`, `__pycache__`), one line per bus, and exits 1 when any bus failed. A copy newer than the tool is skipped, never downgraded. Each bus gets 5 seconds to be free; a bus held longer is reported failed.

`PRAGMA user_version` is the bus's schema version (1 in this release, the v0.1.0 shape). A v0.1.0 bus is adopted by stamping 1, with no other write and no backup. A bus that needs a migration is backed up to `.agentbus/backups/bus-v<old>-<UTC time>.db` (0600, checked byte for byte; the newest 5 are kept, with the copy `upgrade` replaced beside each) before any write, then migrated, checked and stamped in one transaction. `watch` changes no data or schema (it may finish SQLite's recovery of a crashed writer's journal): it reports an older bus instead (`schema_older`). `upgrade --dry-run` applies no upgrade and writes no copy or backup. An older copy refuses a newer bus (`schema_newer`); a 0.1.0 copy refuses it as `schema_refused`. Backups, restore and the stale-copy notice: `docs/how-to/upgrade.md`.

## Discovery and nesting

Commands walk from cwd to the nearest ancestor containing `.agentbus/`. Linked worktrees first map cwd to the same relative spot in their main checkout, even when the worktree sits outside the workspace. `$HOME/.agentbus` is never discovered. Unsafe bus folders are refused, never skipped.

One repo, one bus. Use the one discovery finds; if it looks wrong, run `buses` and ask, and do not create another. `init` refuses a folder of worktrees whose repo already has a bus, and a folder inside a linked worktree (`--second-bus` overrides both), and `doctor` shows a `two-buses` row when a bus folder sits directly above this repo's linked worktrees without being the repo's. That row says which bus the worktrees use and how to look at the other; the other may serve repos of its own, so what to do with it is your call.

No bus means: `agentbus: no bus here or in any parent folder. Run: agentbus init <dir>`.

`--up N` selects the Nth bus above the nearest (default 0). `--up 1` reaches the next outer bus; a missing level is an error. Like `--as` and `--json`, it works before or after the subcommand.

`buses` lists the whole chain: level, directory, and whether bus.db exists. It creates no database. `buses --json` returns objects with `level`, `directory`, and `exists`. `status` shows the selected database path; `watch` shows its directory and honours `--up`.

Claims and messages are per bus; nothing merges across buses.

## Explicit buses

`AGENTBUS_DB` overrides discovery and `--up`; relative paths become absolute from cwd. With it set, `buses` lists only that explicit bus. Set it only when a worker cannot discover the bus (a sandbox, or a folder outside the checkout). When it names a bus other than the one this folder finds, `join` and `brief` print one `bus_env_mismatch` warning (in `--json`, `warnings`) and `doctor` shows a `bus-env` row; no warning when it is the same file or when discovery finds nothing. See [sandboxed agents](sandboxed-agents.md).

## Claims and messages

Follow the [skill](../skills/agentbus/SKILL.md): join, check inbox between steps, claim before editing, release when done, and leave.

Every write (`post`, `claim`, `ctx set`, `goal`, `log add`) needs a name on the roster: under a name that has not joined, or has left, it fails with `not_on_roster` and writes nothing. Names are `[A-Za-z0-9._-]{1,40}` (`join` refuses others; a name already on a bus keeps working). `join` takes the name either way, `--as NAME join` or `join NAME`; every other command takes it with `--as` (or `AGENTBUS_AGENT`) only. `post --to` takes one name; a name not on the roster still gets the message, with a `recipient_not_on_roster` warning that lists close matches. `goal` is the shared goal's reserved fact key: set it with `goal TEXT`, not `ctx set`.

Path claims are relative to the bus's directory. Paths normalise `./`, repeated slashes and `..`; absolute and escaping paths are refused. A path includes its descendants, with or without a trailing slash. Resources compare as given after normalisation, case included. Scheme names such as `issue:17` compare exactly. Claims are advisory, at most 1024 characters, and expire after 120 minutes by default (`--ttl-min`: 1 to 10080). Claim again to renew; omitted `--purpose` preserves the current purpose, and the original `claimed_at` stays unchanged. `claim` and `release` take up to 100 resources, each once, in one transaction: all of them or none. If any is held by another agent, nothing is claimed and the error names every blocked resource and its holder (`error.conflicts` under `--json`). Under `--json` one resource returns the claim object as always; several return `{"claims": [...], "claimed_count": N}` with one claim object per resource. Releasing several works the same way: if you hold none of one, nothing is released and `not_held` lists them all (`error.resources`); `release RESOURCE... --if-held` skips the ones you do not hold and succeeds, for cleanup scripts. Each resource gets its own log row. A claim conflict says when the holder was last seen (`holder_last_seen`, `holder_idle_min` under `--json`). Once it has not been seen for 30 minutes (the window `join` uses to tell a live session from a gone one) the message says it may be gone and, if no answer comes, to ask your user. Every conflict ends with the command that takes the holder's claims under your own name, `agentbus --as YOU claim RESOURCE --from HOLDER` (`claim_from` under `--json`, always given; `takeover` is the same command, given only after the 30 minutes, else null). Run it only when your user or a handoff gave you the holder's work. `--from` repeats for several holders and takes all or nothing: a claim moves whole (a folder the holder claimed above the resource has to be named), anyone not named in the way refuses it, and a named holder with nothing in the way is refused as a stale command. The holder stays on the roster, and gets a `claim_taken` log row and an alert (topic `claim`) saying who took what and why.

New identities receive older direct messages, but broadcasts only from their first join onward. `read` shows history. Inbox marks returned messages read after stdout writes successfully. This does not confirm that a downstream consumer read or processed them. Do not truncate a consuming inbox with `head`; use `inbox --limit N`. Use `inbox --peek` when inspecting without consuming. Delivery is at least once: a crash or concurrent calls can repeat a message. `--reply-to` links a message without choosing its recipient.

`agentbus --as NAME wait [--timeout SECONDS]` blocks until `inbox` would show you at least one message, then prints how many and the command that reads them, and exits 0. It marks nothing read. `--timeout` is 1 to 1800 seconds, 600 by default; when it ends first, `wait` exits 124 with the `wait_timeout` error. It looks at the bus every 2 seconds, each time opening it, counting and closing it, so it never holds the bus while it sleeps and a writer is never kept waiting behind it. It checks the name is on the roster, and refreshes your last-seen when it starts and again when it ends. Ctrl-C exits 130 as for any command. `--json` prints `{"name", "unread", "waited_s", "next"}`. There is no daemon and no file watcher.

`wait` does not wake an idle session. It is for a command an agent runs in the background: when it exits, a tool that reports a finished background command to its session (Claude Code does) tells the agent mail has arrived. A session with no such command running, and a tool that does not report one, sees mail when it next runs `inbox`.

## Output

Names, topics, fact keys and claim resources are identifiers: `--as`, `AGENTBUS_AGENT`, `post --to`, `--topic`, `ctx` KEY and `claim`/`release` RESOURCE refuse a control character (C0, DEL, C1) or a bidirectional override with `bad_input` (exit 2), naming the field in the message and in `error.field`, and showing the character as `U+XXXX`. Bodies and values stay free text. Rows an older bus already holds are read as before and shown escaped (`\x1b`); such a name can no longer be passed as `--as`, so its claims end by expiry.

Use `--json` for parsing and check exit status; errors go to stderr. Human output escapes controls, invisible characters and backslashes. Rows start with tool-written text or two spaces. On a terminal long lines wrap at its width with indented continuations (a word that fits a row is never cut); piped or redirected they are not wrapped, unless `COLUMNS` is set. JSON preserves stored text, and is compact when piped and indented on a terminal. Paths show `~` for the home folder. Human message headers start with `#<integer id> `, followed by sender, recipient (`everyone` for broadcasts), kind and reply target. Local time comes last: `HH:MM` today, otherwise `Nov 1 16:19`; a claim reads `for 2h (until 13:47)`. JSON timestamps stay UTC.

A nonzero exit does not imply rollback. A write command may commit before output fails; inspect the bus before retrying.

Listings default to 20 rows for `inbox` and each section of `status` (its recent messages too) and 50 for every other listing; `--limit -1` shows all. A listing that left rows out says how many and prints the exact command that shows more (`next: agentbus read --before v1.eyJ... --limit 20`). With `--json` they return an envelope that says whether rows were left out (see JSON output). Leave and release-all report at most 500 claims but release everything. A body of `-` reads stdin; an empty body is refused, and so is one over 64 KB (`bad_input`, `field` `body`). Listings cut a message body at 2 KB (`body_truncated` true); `read --id N` shows one message whole. Text `status` shows a fact's first line only; `ctx get KEY` has the rest.


## Goal

`agentbus --as NAME goal "text"` sets the shared goal; `agentbus goal` shows it as `goal (alice, 2d ago): TEXT`, with who set it and how long ago. `-` reads the text from stdin. `--json` prints `{goal, set_by, set_at}`, or `null` when there is none. Setting the goal it already holds changes nothing and reports `unchanged: true`.

The goal is the fact `goal`, so `ctx history goal` lists every version. `join` and `brief` print `goal (alice, 2d ago): ...` when one is set, and `status` opens with `== goal (alice, 2d ago): ...`. `watch` pins it on the row under its header (🎯, or ◆ without emoji) and leaves it out of Facts.

## Brief

`agentbus --as NAME brief` is the one call for an agent that has just joined or come back: the goal, who is here and what each holds (with the claim's purpose), open questions, your unread handoffs and alerts, facts changed since your last read, and one `next:` line with the command to run (a todo you may take when one is open, `read --id ID`, with a line under it that says how to close it: your own first, else the oldest whose owner has left the roster, never one whose owner is still here; chosen from all open work, so `--limit 0` points at the same command). About 1,100 characters (under 400 tokens) for four agents with claims, three questions, a handoff, an alert and three facts. `status` plus `inbox` for the same bus is several times longer, and a late joiner needs one call fewer (`join`, `brief` instead of `join`, `status`, `inbox`).

- It only reads. It never moves an inbox cursor, so the handoffs it lists are still there for `inbox`, which is what consumes them. With `--as` it refreshes your last-seen like every command; without `--as` it is a read-only open and shows the bus as a bystander (no unread, only questions to everyone).
- An open question has kind `question`, is addressed to you or to everyone, and has no answer: no message of kind `answer` replies to it directly. An answer closes only the message it replies to, so an answer to a clarifying question does not close the question above it, and a reply of another kind, a note or a question, does not answer it. Oldest first.
- Open todos are every `todo` that no `done` or `dropped` replies to directly, whoever it is for: no name filter. Each line gives the id, the owner (the named recipient, else the sender), how old it is, when the owner was last seen, or that the owner is not on the roster. Nothing else closes a todo: not a reply of another kind, not reading, leaving or a claim expiring. The section is left out when nothing is open. `--json` has `todos.items` with `owner`, `owner_last_seen` and `owner_on_roster`.
- Expired claims whose holder is still on the roster get one line with each resource, its purpose, the holder, when it expired and when the holder was last seen, and the plain `claim` command. It states facts and does not say whether the holder is gone. `--json` has `expired_claims`.
- Unread follows the inbox rule exactly (after your cursor; direct to you, or broadcast since you first joined; not from you). The list shows handoffs and alerts; `unread.total` counts every kind.
- Changed facts are those updated at or after the time of the last message you read with `inbox` (every fact before a first read), leaving out your own and the goal.
- A row whose body or value was cut shows `...` and `[cut: agentbus read --id ID]` (`ctx get KEY` for a fact, with the real key; a key too long for a command lists the facts), so a row that looks whole is whole. Every command brief prints parses as printed: a name or key that starts with `-` is written `--as=-name` or after a `--`.
- `--limit N` (default 5) bounds every section; `omitted` counts what was left out and the text names the next command. At `--limit 0` a section with items left out shows its total and the hint; it says `none` only when there are none. Stored text is cut (bodies and values at 200 characters in `--json`, with `body_truncated` or `value_truncated`; the goal at 300).

## Todos

`post --kind todo "validate X"` records work before it starts; `--to NAME` gives it to someone, else it is the sender's. It stays open until a `done` or `dropped` replies to it: `post "X validated; 12 checks green" --kind done --reply-to ID`, or `post "no longer needed" --kind dropped --reply-to ID`. Any name may close one, so the next agent can finish a lane's work; the closing row records who did. Only that direct reply closes it. `dropped` needs `--reply-to`; a `done` with none is a plain done. Closing a todo that is already closed, or a `dropped` aimed at a message that is not a todo, is allowed and closes nothing further; the post's `closed` field (the todo's id, or null) and a line on stderr say so. **Record your own jobs.** At start, post each job you own as its own todo. Close each with a linked `done`. Before you stop with work left, every unfinished job must be an open todo: a job named only inside a `done` ("b.py remains") is invisible to `brief`. You may finish a todo whose owner left; claim its files as usual, with `claim RESOURCE --from HOLDER` if a claim is in the way. `brief` lists the open ones, and SessionStart says how many are open (or `run brief` when it could not count in time).

## Demo

`agentbus demo` is a hands-off tour of about 30 seconds for a person: two scripted agents join a temporary bus, set a goal, post a task, claim a folder, are refused a conflicting claim, hand off, catch up with `brief` and release. Each command is printed as it runs. The bus lives in a directory it makes under `TMPDIR`, outside any repo; it never reads or writes the bus of the folder you are in (every `AGENTBUS_*` variable is dropped for the commands it runs) and it removes the directory when it finishes, fails, or is stopped with Ctrl-C or SIGTERM (exit 130). On a terminal it offers `watch` on the demo bus at the end; `--watch` opens it without asking, `--no-pause` skips the pauses and the offer. `--json` runs the same tour without pauses and prints each step's exit status and `cleaned: true`, a quick check that an install works.

## Watch

`agentbus watch` redraws in place until `q` (from the main view) or `Ctrl-C`. `--interval` sets 0.2 to 60 seconds, `--once` prints one frame, and `--json` prints one snapshot. Piped output, `TERM=dumb` and an unset `TERM` also print one frame. It needs 40 columns. `NO_COLOR` turns colour off. Watch only reads: no key marks a message read or changes a claim, and `y` writes only to the terminal.

| Key | Main view | Detail | Help | Filter input |
|---|---|---|---|---|
| `j` `k`, Down Up | move in the focused section; in Messages while following, `k` selects the newest and pauses | select a related row, or scroll | scroll | text |
| `g` `G`, Home End | first, last row; `G` follows again | top, bottom | top, bottom | text |
| PgUp PgDn, Ctrl-u Ctrl-d | a page, half a page | scroll | scroll | ignored |
| Tab, Shift-Tab, `1` to `4` | next, previous section; Agents, Claims, Facts, Messages | | | ignored, digits are text |
| Enter | open the selected row (the newest message while following) | open the selected related row on top | | keep the filter |
| `t` | | show or hide a message's thread | | text |
| `y` | copy the selected id, name, resource or key (OSC 52) | copy the reply command, name, resource or value | | text |
| `/` | filter: `from:NAME to:NAME kind:KIND topic:NAME`, or words | close the details, filter | | text |
| `p` | pause the whole view, or follow again | | | text |
| `r` | read the bus now | read the bus and this detail again | read now | text |
| `?` | help | help | close | text |
| Esc | clear a kept filter, else nothing | back one level | back | clear and close |
| `q` | quit | back one level | back | text |
| Ctrl-C | quit | quit | quit | quit |

`kind:` takes a kind's start or its short code (`hand`, `ask`, `ans`, `dec`, `ALRT`, `done`, `todo`, `drop`, `note`), which narrow rows show. Watch holds the newest 200 rows of each section; a filtered section with more says `N of newest 200`, and `agentbus read` (or `who`, `claims`, `ctx get`) reads the rest. A detail reads at most the newest 5000 messages. A busy bus keeps the last frame and adds `waiting · Ns old` to the header; a bus it cannot read (refused, newer, gone) replaces the frame with the reason and the fix, and the view comes back as it was once the bus reads again. A watch left running after its bus copy was upgraded says `restart for X.Y.Z`. `AGENTBUS_ASCII=1`, `TERM=linux` or a terminal that draws `●` two columns wide switch watch's marks to ASCII. SIGTERM ends it like `q`; SIGHUP exits `129`; both restore the terminal. Ctrl-Z gives the terminal back and `fg` takes it again. A filter holds at most 200 characters. The main view reads the first 4096 characters of each body (a word filter searches those); a detail shows its message whole. A stdout that is not UTF-8 gets the ASCII marks. Walkthrough: [Watch your agents](how-to/watch.md).

On a terminal, watch shows emoji: a role per agent (🧠 brain or lead, ✋ lane, hand or implementer, 🧪 tests, 🔍 review, 📚 docs, 🚀 ops, 🎨 design, 🙋 human, 🤖 otherwise), a kind per message (🤝 handoff, ❓ question, 💬 answer, ✅ done, 📋 todo, 🚫 dropped, 🧭 decision, 🚨 alert, 📝 note) and a section icon (👥 🔒 📌 💬). `AGENTBUS_NO_EMOJI=1` turns them off. They never appear when stdout is not a terminal.

## JSON output

Use `--json` to parse results. On success stdout holds exactly one JSON value and the exit status is `0`; stderr may hold non-error notices. Read stdout and the exit status, never the two streams merged. `agentbus schema --json` prints everything on this page in machine form: every command's arguments, result schema, error codes, retry rule and exit codes. `agentbus schema` prints a one-screen table, and each command's `--help` ends with its result and retry line. `agentbus --json schema COMMAND` prints only that command: its arguments, result, the errors of its own (`common_errors` names the ones every command that opens a bus can raise) and the warnings it can give; add `--full` for the global arguments, environment, exit codes and every error's definition. `schema --index` lists every command's arguments and errors in about 2 KB.

Contract version. Every `--json` result is an object whose first key is `contract` (`1`): the same name in every command, in `agentbus schema --json` and in the registry. Nothing else carries a version. `join --json` also reports `agentbus` (the version of the running copy). Within contract 1 changes are additive: new keys on results, new error codes and new commands. Removing or renaming a key, changing a type or changing an exit status bumps `contract` and is listed under "Changed" in the CHANGELOG. A listing that prints a bare `[...]` instead of an object with `items` comes from a 0.1.x copy; upgrade it. The tables below leave `contract` out of each result; it is always there. `goal` with no goal set returns `{"contract": 1, "goal": null, "set_by": null, "set_at": null}`, so no result is ever a bare `null`.

### Listings

Commands that list rows return an envelope, `{"contract": 1, "items": [...], "has_more": false, "next": null}`:

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

Other commands return one object. `{...}` lists exact keys; `[X]` is an array of X; a `null` alternative is a literal JSON `null`. `unchanged` is `true` when `ctx set` or `goal` found the value already stored and wrote nothing. `post` adds `duplicate` (`true` on a repeat of a `--request-id`) and, for a `done` or `dropped` that replies to a message, `closed`: the id of the todo it closed, or `null` when it closed nothing (the todo was already closed, or the target is not a todo). A repeat of the same `--request-id` returns the same `closed` as the first response.

<!-- generated:results -->
| Command | `--json` result |
| --- | --- |
| `join` | `{"joined": string, "bus": string, "goal": null or Goal, "agentbus": string}` |
| `leave` | `{"left": string, "was_joined": boolean, "released": [string], "released_count": integer}` |
| `who` | `{"items": [Agent], "has_more": boolean, "next": string or null}` |
| `post` | `{"id": integer, "warnings": [Warning]}` |
| `inbox` | `{"items": [Message], "has_more": boolean, "next": string or null}` |
| `wait` | `{"name": string, "unread": integer, "waited_s": integer, "next": string}` |
| `read` | `{"items": [Message], "has_more": boolean, "next": string or null}, or with --id a Message` |
| `ctx set` | `Fact` |
| `ctx get` | `a Fact, or {"items": [Fact], "has_more": boolean, "next": string or null}` |
| `ctx history` | `{"items": [FactVersion], "has_more": boolean, "next": string or null}` |
| `claim` | `for one resource a ClaimResult; for several {"claims": [ClaimResult], "claimed_count": integer}, one per resource, each once, in the order given` |
| `release` | `{"released": [string], "released_count": integer}` |
| `claims` | `{"items": [Claim], "has_more": boolean, "next": string or null}` |
| `log add` | `{"id": integer, "logged": boolean, "agent": string, "action": string, "detail": string}` |
| `log show` | `{"items": [LogEntry], "has_more": boolean, "next": string or null}` |
| `status` | `{"bus": string, "goal": null or Goal, "agents": [Agent], "context": [Fact], "claims": [Claim], "messages": [Message], "omitted": {"agents": integer, "context": integer, "claims": integer, "messages": integer}}` |
| `goal` | `a Goal, or {"goal": null, "set_by": null, "set_at": null} when none is set` |
| `watch` | `{"bus": string, "directory": string, "agents": [{"name": string, "role": string or null, "last_seen": string, "joined_at": string}], "claims": [{"resource": string, "agent": string, "purpose": string or null, "expires_at": string}], "goal": null or Goal, "context": [Fact], "messages": [{"id": integer, "ts": string, "sender": string, "recipient": string, "kind": string, "topic": string or null, "body": string, "reply_to": integer or null}], "unread": object, "counts": {"agents": integer, "claims": integer, "messages": integer}, "open": {"alerts": integer, "questions": integer, "todos": integer, "window": integer or null}, "omitted": {"agents": integer, "context": integer, "claims": integer, "messages": integer}}` |
| `buses` | `{"items": [BusLevel], "has_more": boolean, "next": string or null}` |
| `init` | `{"directory": string, "copy": string, "old": string, "new": string, "exclude_added": boolean, "gitignore_rule": boolean, "outer": string or null}` |
| `upgrade` | `{"directory": string, "old": string, "new": string, "schema_old": integer or null, "schema_new": integer or null, "backup": string or null}, or with --all or --dry-run {"buses": [UpgradeRow], "upgraded": integer, "current": integer, "skipped": integer, "failed": integer, "would_upgrade": integer (--dry-run)}` |
| `schema` | `the full schema {"contract": integer, "agentbus": string, "commands": object, "global_args": [object], "objects": object, "errors": object, "warnings": object, "exit_codes": object, "error_fields": object, "env": object}; with COMMAND only that command's commands, objects, error_fields, warnings and the errors of its own (common_errors names the rest; with --full also global_args, exit_codes, env and every error it can raise); with --index {"contract": integer, "agentbus": string, "commands": {NAME: {"args": [string], "errors": [string]}}, "global_args": [string], "common_errors": [string]}` |
| `help` | `{"command": string or null, "text": string}` |
| `completion` | `{"shell": string, "text": string}` |
| `skill` | `{"text": string}` |
| `setup` | `{"target": string, "scope": string, "dry_run": boolean, "changes": [{"path": string, "detail": string, "action": string, "backup": string (only when a backup was saved), "info": boolean (true for a report about something that is not a file, such as the login shell)}]}` |
| `update` | `{"from": string, "to": string, "latest": string or null, "install": {"method": string, "url": string or null}, "tool": {"status": string, "argv": [string] or null, "exit_status": integer or null, "commands": [string] or null, "download": {"wheel": string, "sha256sums": string, "install_with": [string]} or null (only when update downloads the release wheel; "install_with" in a dry run)}, "buses": [UpgradeRow], "setup": [SetupResult], "plugin": {"fix": string} or null, "restart": boolean, "scope": {"narrowed": boolean, "why": string or null}}, or with --check {"running": string, "latest": string or null, "update_available": boolean, "install": {"method": string, "url": string or null}, "argv": null, "commands": [string] or null, "download": {"wheel": string, "sha256sums": string, "install_with": [string]} or null, "notes": string or null}` |
| `hooks` | `{"hooks": {EVENT: [{"matcher": string (optional), "hooks": [{"type": string, "timeout": integer, "command": string}]}]}}` |
| `doctor` | `{"agentbus": string, "path": string, "contract": integer, "checks": [{"id": string, "status": "ok" \| "warn" \| "fail" \| "n/a", "detail": string, "fix": string or null, "hint": string or null, "scope": string (when it applies)}], "fail": integer, "warn": integer}; exit 1 (items_failed) when fail > 0` |
| `brief` | `{"bus": string, "me": null or {"name": string, "joined": boolean}, "goal": null or BriefGoal, "agents": {"items": [BriefAgent]}, "questions": {"items": [BriefMessage]}, "todos": {"items": [BriefTodo]}, "expired_claims": {"items": [BriefExpiredClaim], "next": string or null}, "unread": {"total": integer, "items": [BriefMessage]}, "pending_others": {"items": [BriefMessage], "next": string or null}, "facts": {"since": string or null, "items": [BriefFact]}, "omitted": {"agents": integer, "questions": integer, "todos": integer, "expired_claims": integer, "unread": integer, "pending_others": integer, "facts": integer}, "next": string}` |
| `demo` | `{"steps": [{"command": string, "exit": integer}], "cleaned": boolean}` |
<!-- /generated:results -->

Shared objects. Nullable fields use JSON `null`; IDs and counts are integers; timestamps are UTC strings in JSON.

<!-- generated:objects -->
| Object | Fields |
| --- | --- |
| `Agent` | `name`, `tool`, `model`, `cwd`, `branch`, `role`, `joined_at`, `last_seen` |
| `Message` | `id`, `ts`, `sender`, `recipient`, `kind`, `topic`, `body`, `reply_to`, `body_truncated` (optional) |
| `Claim` | `resource`, `agent`, `purpose`, `claimed_at`, `expires_at`, `state` |
| `ClaimResult` | `resource`, `agent`, `purpose`, `claimed_at`, `expires_at`, `auto_released`, `auto_released_count`, `renewed`, `previous_purpose` (optional), `taken_from` (optional) |
| `Fact` | `key`, `value`, `updated_by`, `updated_at`, `unchanged` (optional) |
| `FactVersion` | `id`, `key`, `value`, `updated_by`, `updated_at` |
| `LogEntry` | `id`, `ts`, `agent`, `action`, `detail` |
| `Goal` | `goal`, `set_by`, `set_at`, `unchanged` (optional) |
| `BusLevel` | `level`, `directory`, `exists`, `copy_version`, `stale` |
| `UpgradeRow` | `directory`, `status`, `old`, `new`, `schema_old`, `schema_new`, `backup`, `error` |
| `SetupResult` | `target`, `scope`, `directory`, `changes`, `error` |
| `DoctorCheck` | `id`, `status`, `detail`, `fix`, `hint`, `scope` (optional) |
| `Warning` | `code`, `name` (optional), `did_you_mean` (optional), `roster` (optional), `roster_total` (optional), `agentbus_db` (optional), `discovered` (optional) |
| `BriefGoal` | `goal`, `set_by`, `set_at`, `truncated` |
| `BriefMessage` | `id`, `ts`, `sender`, `recipient`, `kind`, `topic`, `body`, `reply_to`, `body_truncated` |
| `BriefTodo` | `id`, `ts`, `sender`, `recipient`, `kind`, `topic`, `body`, `reply_to`, `body_truncated`, `owner`, `owner_last_seen`, `owner_on_roster` |
| `BriefExpiredClaim` | `resource`, `purpose`, `expires_at`, `holder`, `holder_last_seen` |
| `BriefClaim` | `resource`, `purpose`, `expires_at` |
| `BriefAgent` | `name`, `role`, `tool`, `last_seen`, `claims`, `claims_omitted` |
| `BriefFact` | `key`, `value`, `updated_by`, `updated_at`, `value_truncated` |
<!-- /generated:objects -->

#### `update --json`

A real `update`, `update --dry-run` and `update --check` print one object each (shapes in the table above). A failure is not a status in that object: it is an error on stderr (`installer_failed`, `manual_step`, `release_offline`, `rate_limited`, `release_unknown`, `download_failed`, `update_running`, `items_failed`), with nothing on stdout, except `items_failed`, whose stdout holds the whole result.

- `tool.status`: `updated` (the installer ran and the new version answers), `current` (no newer release, or nothing needed installing), `dry_run` (`--dry-run`: `argv` is what would run, `download` names the two files it would fetch), `manual` (`--dry-run` only: `commands` hold what a person runs; a real run that cannot update exits 1 with `manual_step` instead).
- `tool.argv` is the installer command a real update ran, on the downloaded, checksum-verified wheel; it is `null` in `--dry-run` and `--check`, because that wheel does not exist yet. `tool.download` is `{"wheel", "sha256sums"}` (URLs) when `update` downloads the release, plus `install_with` (the installer command that would then run on the file) in a dry run, else `null`.
- `from` and `to` are the versions before and after (equal when nothing was installed); `latest` is the newest release found, `null` when none is published.
- `restart` is `true` when the tool was replaced: running sessions and `watch` keep the old code until restarted.
- `scope.narrowed` is `true` in an agent session without `--all-buses`: only the current bus was upgraded and setup was skipped; `scope.why` names the signal (`CLAUDECODE`, a Codex variable, `AGENTBUS_AGENT_SESSION`, or `no terminal`).
- `buses` are the `UpgradeRow`s of the bus step. `setup` is a list of `SetupResult`s, one per `setup TARGET --refresh` run: `target` (`claude` or `codex`), `scope` (`user` or `project`), `directory` (the project folder, `null` for user scope), `changes` (`path`, `detail`, `action`; a piece that is not installed is `unchanged`, and one you edited is `skipped`, kept), and `error` (`null`, or `{code, message}` when that run failed). `plugin` is `{fix}` when the Claude Code plugin is installed, else `null`.
- `--check`: `running`, `latest`, `update_available`, `install` (`method` and `url`), `argv`, `commands` and `notes` (the release page).

`watch --json` returns once, with or without `--once`; its row projections differ from `status`. Data written directly through SQLite can have other types; JSON renders BLOBs and non-finite numbers as strings.

### Failures

A failing command exits non-zero and, under `--json`, prints one JSON object on stderr: `{"error": {"code": "claim_conflict", "message": "...", "retryable": false, "committed": false, ...}}`, plus the fields listed for its code below. Branch on `error.code`, not on the message. `error.next` is the command that recovers, spelled as the message gives it (fill in any capitals), or `null`. Every error object carries these fields:

<!-- generated:error-fields -->
| Field | Type | Meaning |
| --- | --- | --- |
| `code` | string | One of the error codes below; branch on this, not on the message. |
| `message` | string | What happened and what to do, for a person. |
| `retryable` | boolean | Whether running the same command again can succeed. False once the command saved database rows, unless it is a post or join with a --request-id (the bus stores that token, so a repeat returns the first result); a command that changed only files (init, upgrade's copy, setup) stays retryable. |
| `committed` | boolean | True when the command's own change had been saved before the failure, so a write must not be repeated unless retryable is true (a post or join with its --request-id). For any other write, look at what it changed first. |
| `next` | string or null | The one command that recovers from this error, exactly as the message gives it (placeholders in capitals, such as NAME or PATH, are yours to fill); null when no command recovers from it. A post's or join's request id is not repeated here: reuse the one you sent. |
<!-- /generated:error-fields -->

What stdout holds depends on when the failure happened:

1. Before any output (argument parsing, identity, finding or opening the bus, a refusal, a database error before the result was built): stdout is empty and the exit status is the code's. The one refusal with output is `items_failed` (point 4).
2. During output (the reader closed the pipe, a partial write): stdout may hold part of the value and the code is `output_failed`. If the command wrote something, `committed` is `true` and the write stands: a `post` that could not print was saved; retry with the same `--request-id`. A command that only reads has `committed: false` and can simply be run again.
3. After complete output, when `inbox` marks the messages read: stdout holds the complete value, the code is `ack_failed` (`delivered: true`) and the cursor did not move. Treat the output as delivered, expect the same messages again and dedupe by id (at least once).
4. After complete output, when some of the items failed (`upgrade --all`'s buses, `setup`'s files): stdout holds the whole result, every item with its status, and the code is `items_failed`, whose `failed` lists the items that failed.

Output together with a non-zero exit is possible for `ack_failed`, `output_failed`, `interrupted` and `items_failed`. When `committed` is `true`, any stdout is the complete result and must be read: an `inbox` interrupted inside its mark-read commit prints the full JSON, and its messages are already marked read.

`committed` is `true` when the command's own change had been saved before the failure came (a database error after a `post` committed, an `output_failed` from a write, an `interrupted` after the commit), `false` when nothing was written. `retryable` is never `true` once the command saved database rows, unless it is a `post` or `join` that carried `--request-id`: then repeating it returns the saved result with `duplicate: true`. For any other write, look at what it changed before repeating it. A command that changed only files (`init`, the copy `upgrade` replaced, `setup`) is safe to repeat, so it stays retryable with `committed: true`; an interrupted one names the command that finishes it (`rerun`). The `retryable` column of the table below is the code's own value, before that rule.

Ctrl-C (SIGINT) is `interrupted`, exit `130` in both modes (the shell convention), with one JSON error on stderr under `--json`. Stdout is empty unless `committed` is `true` (see above). A Ctrl-C that lands while a command is committing is held until the commit is recorded, so `committed` is accurate.

### Error codes

<!-- generated:errors -->
| Code | Exit | Retryable | Extra fields | Meaning and what to do |
| --- | --- | --- | --- | --- |
| `claim_conflict` | 1 | no | `resource`, `holder`, `claimed_at`, `expires_at`, `purpose`, `holder_last_seen`, `holder_idle_min`, `takeover`, `claim_from`, `conflicts` (optional) | Another agent holds an overlapping claim. claimed_at is when the holder took it. holder_last_seen is when the holder last ran a command (null when unknown) and holder_idle_min the whole minutes since. claim_from is always the claim --from command that moves the claims in the way to you under your own name (a folder held above the resource is named whole: a claim moves whole); with several resources it takes the whole batch. It is null only when more than 100 agents hold claims in the way (one command names at most 100). takeover is the same command for that conflict, given only when the holder has not been seen for 30 minutes or more (the window join uses), else null. With several resources, nothing was claimed: resource and holder are the first blocked resource, and conflicts lists every blocked one as {resource, holder, held, claimed_at, expires_at, purpose, holder_last_seen, holder_idle_min, takeover, claim_from} (held is the claim in the way, the resource itself or a folder above or inside it). In a shared checkout, leave it until the holder answers or releases it. On a separate branch, post what you are touching; the merge decides. Run claim_from only if your user or a handoff gave you the holder's work; if takeover is given and the holder does not answer, ask your user. With several resources, leave the blocked ones out and claim the rest. |
| `not_held` | 1 | no | `resource`, `resources` (optional) | You do not hold that claim. With several resources, none was released, and resources lists every one you do not hold. Nothing to release; use release --if-held for cleanup. |
| `no_message` | 1 | no | `id` | There is no message with that id. Check the id with read. |
| `no_context_key` | 1 | no | `key` | There is no fact with that key. List facts with ctx get. |
| `not_on_roster` | 1 | no | `agent`, `did_you_mean`, `roster` | That name has not joined. did_you_mean lists the roster names closest to it (at most 3, possibly none); roster lists the agents that have joined, by name (the 10 most recently seen at most). If the name is a typo, repeat the command with a name in did_you_mean. Otherwise join first. |
| `name_active` | 1 | no | `agent`, `last_seen_min`, `suggested_name` | The name was active recently and may be another live session. suggested_name is a free name, or null. Join under suggested_name, or join --takeover if it is you. To retry your own join, pass the same --request-id. |
| `request_id_reused` | 1 | no | `request_id`, `agent`, `original_id` | That request id was used with a different message or join. original_id is the message id, or the log id of the join, that first used it. Repeat the original request exactly, or use a new token for a different one. |
| `bad_input` | 2 | no | `field` (optional) | The arguments are not valid (a usage error). field names the argument when a value is refused: a body, value, detail or text over 64 KB (field body for post). Fix the arguments. |
| `no_bus` | 3 | no | none | There is no bus here or above. Run agentbus init DIR, or set AGENTBUS_DB. |
| `busy` | 3 | yes | `bus` | Another process held the bus for 15 seconds. Retry after a few seconds. |
| `schema_refused` | 3 | no | none | The bus tables are not agentbus's. Stop and tell the user. |
| `schema_older` | 3 | no | `bus`, `bus_schema`, `tool_schema` | The bus is older than this tool and was opened read-only. Run any command that is not watch to upgrade it, or agentbus upgrade DIR. |
| `schema_newer` | 3 | no | `bus`, `bus_schema`, `tool_schema` | The bus is newer than this copy of the tool. Use a newer agentbus. |
| `schema_corrupt` | 3 | no | `bus`, `bus_schema` | bus.db records a schema version no agentbus writes; another tool or an agent changed it. Stop and tell the user; restore a backup (docs/how-to/upgrade.md). |
| `backup_failed` | 3 | no | `bus`, `reason` | The backup before a migration could not be made. Free disk space or move the bus. |
| `copy_newer` | 1 | no | `directory`, `copy_version`, `tool_version` | The folder's copy of agentbus is newer than this one; it is never downgraded. Run upgrade or init with a newer agentbus. |
| `bus_unavailable` | 3 | no | `file` (optional), `outcome_unknown` (optional) | The bus or its folder failed a safety check, SQLite or the system refused it, or a command ran out of time. outcome_unknown (true) means it was stopped while saving a write, so the write may or may not have been saved; committed is then true when that write was the command's own. Read the message, fix the folder, then run the command again. When outcome_unknown is true, check the bus before repeating a write, or repeat a post or join only with its request id. |
| `ack_failed` | 3 | yes | `delivered` | inbox printed its messages but could not mark them read. The output was complete: use it, expect the same messages again, and dedupe by id. |
| `wait_timeout` | 124 | yes | `waited` | wait ended with no unread message after --timeout seconds (waited). Run wait again to keep waiting, or read inbox. |
| `output_failed` | 1 | yes | none | stdout could not be written; committed effects stand. Repeat a post or join with the same --request-id; for any other write, look at what it changed instead of repeating it. |
| `interrupted` | 130 | yes | `directory` (optional), `backup` (optional), `migrations` (optional), `rerun` (optional), `changed` (optional), `argv` (optional) | The command was stopped (Ctrl-C or SIGINT) before it finished. Check committed: if true the change was saved, so repeat a post or join only with its request id, and look at what any other write changed before repeating it, unless retryable is true (init, upgrade and setup can simply be rerun). |
| `items_failed` | 1 | no | `failed` | Some of the items the command works on failed or were refused (buses of upgrade --all, files of setup, checks of doctor); stdout holds the whole result, and failed lists those items. Read each failed item's error, fix it, then run the command again. |
| `installer_failed` | 1 | no | `argv`, `exit_status`, `reason`, `recovery` | The installer update ran did not finish, or finished without moving agentbus to the new release (reason: exit, signal, timeout, version_unchanged, version_mismatch). Run agentbus update again (recovery); the installer's own output is above the error. |
| `download_failed` | 1 | no | `reason`, `asset` | The release's wheel or SHA256SUMS could not be downloaded or did not check out (reason: http, redirect, tls, malformed, too_large, hash_mismatch). Nothing was installed. Try again later: agentbus update. |
| `manual_step` | 1 | no | `commands` | This copy of agentbus is not one update may replace (a clone, a fork, an install of unknown origin, or no safe installer on PATH); the commands to run are listed. Run the listed commands, then agentbus update. |
| `release_offline` | 1 | yes | `reason` | GitHub could not be reached to look for a release (reason: offline, timeout). Retry when online. |
| `rate_limited` | 1 | yes | `retry_after` | GitHub is limiting requests from this network. Retry after retry_after seconds. |
| `release_unknown` | 1 | no | `reason` | GitHub's answer about releases could not be used (reason: http, redirect, tls, malformed, too_large). Try again later, or read the releases page. |
| `update_running` | 1 | yes | `lock` | Another agentbus update is running. Wait for it, then retry. |
| `internal` | 4 | no | none | A bug in agentbus. Report it. |
<!-- /generated:errors -->

### Warnings

A warning is not an error: the command succeeded and its `--json` result carries `warnings: [Warning]` (always an array, empty when there is nothing to say). In human output each warning is one line on stderr.

<!-- generated:warnings -->
| Code | Extra fields | Commands | Meaning and what to do |
| --- | --- | --- | --- |
| `recipient_not_on_roster` | `name`, `did_you_mean`, `roster`, `roster_total` | `post` | The message was delivered to --to NAME, but no agent with that name has joined. did_you_mean lists the closest roster names (at most 3, possibly none). roster lists the agents that have joined, by name (the 10 most recently seen at most); roster_total is how many there are. If the name is a typo, post again to a name in did_you_mean or roster. The first message waits for the typo. |
| `bus_env_mismatch` | `agentbus_db`, `discovered` | `join`, `brief` | AGENTBUS_DB names a bus other than the one this folder finds (the nearest .agentbus above it, or the main checkout's for a linked worktree). The command used AGENTBUS_DB. Given only when discovery finds a bus and the two differ; a worker outside any checkout is never warned. One repo, one bus: unset AGENTBUS_DB to use the one discovery finds, or keep it only when the worker cannot discover the bus (a sandbox, or a folder outside the checkout). Run buses to see the chain. |
<!-- /generated:warnings -->

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
| `124` | wait: the timeout ended with no message, as GNU timeout exits |
| `130` | interrupted (Ctrl-C), the shell convention |
<!-- /generated:exit-codes -->

### Retrying safely

A retry after a timeout, a crash or an `output_failed` is safe when the command's class says so.

<!-- generated:retry -->
| Command | Class | How to retry safely |
| --- | --- | --- |
| `join` | idempotent with flag | join --request-id TOKEN: the same token and flags return the first result with duplicate true instead of name_active; or join --takeover for your own name |
| `leave` | idempotent | a second run reports was_joined false and released_count 0 and writes no log row; --request-id is ignored (a repeat after you joined again releases what you then hold) |
| `who` | safe | repeat freely |
| `post` | needs request id | pass --request-id TOKEN; the same token and payload returns the original id with duplicate true |
| `inbox` | at least once | repeat; a crash or ack_failed redelivers, so check message ids before acting; with `--peek`: safe (repeat freely) |
| `wait` | safe | repeat freely; wait marks nothing read |
| `read` | safe | repeat freely |
| `ctx set` | idempotent | an unchanged value writes no history row and returns unchanged true. --request-id is ignored: a repeat after another agent changed the key sets your value again and overwrites theirs, so ctx get KEY first |
| `ctx get` | safe | repeat freely |
| `ctx history` | safe | repeat freely |
| `claim` | idempotent | renews the claim and keeps its purpose and claimed_at; renewed is true when you already held it, and previous_purpose is set when --purpose changed it. --request-id is ignored; if another agent took any of the resources meanwhile, nothing is claimed and the repeat gives claim_conflict, never an overwrite; except that --from takes again from the holders you name, whatever they hold by then, and a repeat after it worked renews and takes nothing |
| `release` | idempotent with flag | release RESOURCE... --if-held: a resource you do not hold is skipped (none held returns released [] and released_count 0 with exit 0); release --all is already idempotent. --request-id is ignored: a plain repeat of a release that worked gives not_held |
| `claims` | safe | repeat freely |
| `log add` | unsafe | each call appends a row; check log show --limit 1 before retrying |
| `log show` | safe | repeat freely |
| `status` | safe | repeat freely |
| `goal` | idempotent | showing is free; an unchanged goal writes no history row and returns unchanged true. --request-id is ignored: a repeat after another agent changed the goal sets your text again and overwrites theirs, so run goal first |
| `watch` | safe | repeat freely |
| `buses` | safe | repeat freely |
| `init` | idempotent | repeat |
| `upgrade` | idempotent | repeat |
| `schema` | safe | repeat freely |
| `help` | safe | repeat freely |
| `completion` | safe | repeat freely |
| `skill` | safe | repeat freely |
| `setup` | idempotent | a second run reports every change unchanged and writes nothing; a refusal exits 1 with the same object |
| `update` | idempotent | repeat |
| `hooks` | safe | repeat freely |
| `doctor` | safe | repeat freely |
| `brief` | safe | repeat freely |
| `demo` | safe | repeat freely |
<!-- /generated:retry -->

`--request-id` replays a write only where the bus stores the token: `post` and `join` return the first result (`duplicate: true`). `leave`, `claim`, `release`, `ctx set` and `goal` accept the flag and ignore it, and a repeat does what the command does: `leave` leaves again, `claim` renews your hold or gives `claim_conflict` if another agent took the resource meanwhile, a repeated `release` gives `not_held` unless it has `--if-held`, and `ctx set` and `goal` set the value again, over a change another agent made since (run `ctx get KEY` or `goal` first). `log add` has no token: check `log show --limit 1` before retrying it.

`post --request-id TOKEN` makes a retry by the same sender return the original message ID with `duplicate: true`. Body, recipient, kind, topic and reply target must match; a different payload gives `request_id_reused`, naming the original (`original_id`). Tokens belong to their sender and remain on the message row. Without a token each post creates a message.

`join --request-id TOKEN` makes a retry of your own join (same name, same flags) return the first result with `duplicate: true` instead of `name_active`. Different flags under the same token give `request_id_reused`; `original_id` is the log id of the first join.

### Environment

<!-- generated:env -->
| Variable | Meaning | Default |
| --- | --- | --- |
| `AGENTBUS_DB` | Path of the bus database; overrides discovery and --up. | the nearest .agentbus/bus.db above the working directory |
| `AGENTBUS_AGENT` | Your agent identity; --as overrides it. | unset |
| `NO_COLOR` | Turns colour off in watch. | unset |
| `AGENTBUS_NO_EMOJI` | Turns emoji off in watch. | unset |
| `AGENTBUS_ASCII` | Draws watch's own marks in ASCII, with emoji off (also under TERM=linux). | unset |
| `COLUMNS` | Width human output is wrapped to. Without it, human output wraps to the terminal when stdout is one and is never wrapped when stdout is a pipe or a file. | the terminal width; no wrapping when piped |
| `AGENTBUS_AGENT_SESSION` | Set to anything but 0 to mark a run as an agent's: no release notice, and update covers only the current bus. Use it from an agent harness that agentbus does not recognise. | unset |
| `AGENTBUS_NO_UPDATE_NOTICE` | Set to anything but 0 to silence the release notice and the stale-copy notice. | unset |
| `AGENTBUS_NO_UPDATE_CHECK` | Set to anything but 0 to turn off the once-a-day release check (DO_NOT_TRACK and NO_UPDATE_NOTIFIER do the same). | unset |
<!-- /generated:env -->

## Locking

Each command holds SQLite exclusively and closes it before formatting or printing. Others wait up to 15 seconds, timed on the monotonic clock, so a clock change cannot cut the wait or stretch it. SQL has a 6-second budget; a watchdog caps the whole hold at 8 seconds, leaving slack for a slow machine. Watch closes the bus between frames. Every open sets `PRAGMA synchronous=FULL`, so a write is synced to disk before its command reports it, whatever default the SQLite build has; it costs one sync per write command.

Any other SQLite connection that has read the bus blocks every agentbus command, reads included, for as long as it stays open, even idle between queries. A command waits for it to close and then runs; if it is still open after 15 seconds the command fails `busy`. Inspect with `status`, `read` or `--json`, or close the other client between queries. Files stay owner-only; link checks and schema-shape validation run on every open.
