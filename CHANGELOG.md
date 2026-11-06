# Changelog

## Unreleased

### Added

- `claim` and `release` take several resources in one call, all or none (up to 100). If another agent holds any of them, nothing is claimed and the error names every blocked resource and its holder. `--json` keeps the claim object for one resource and returns `{"claims": [...], "claimed_count": N}` for several; the error gains `conflicts`. `release` refuses the lot, naming every resource you do not hold, unless `--if-held`.
- A claim conflict says when the holder was last seen. Once the holder has been silent for 30 minutes it also gives the command that clears its claims (`agentbus --as HOLDER leave`; `takeover` in `--json`), so a dead session no longer holds a file for up to two hours with no way out.
- `agentbus --as NAME wait [--timeout SECONDS]` blocks until you have an unread message, then prints how many and the command that reads them. It marks nothing read and does not hold the bus while it waits. Exit 0 on messages, 124 (`wait_timeout`) when the timeout (600 s by default, at most 1800) ends first. Run it as a background command to be told when work arrives; it does not wake an idle session.

### Changed

- `join NAME` works: it joins as NAME, the same as `--as NAME join`, and the success line says to keep using `--as NAME` on later commands (`post` and the rest still take the name only with `--as` or `AGENTBUS_AGENT`). `--as bob join alice` is a usage error naming both names, and `join ''` is a bad name, never the name in `AGENTBUS_AGENT`.
- The goal reads `goal (alice, 2d ago): TEXT` in `join`, `brief`, `goal` and `status`, and the SessionStart note says how old the goal is once it is a day old. `--json` is unchanged.
- docs/how-to/setup.md shows `(N bytes)` for the skill size instead of a number every edit to SKILL.md had to change; the test checks the real size.
- `--request-id` replays a write only for `post` and `join`, where the bus stores the token. On `leave`, `claim`, `release`, `ctx set` and `goal` it is accepted and ignored: the help, `schema`, the skill and the reference say what a repeat really does (`ctx set` and `goal` set the value again over a change made since), and an error after one of them saved is `retryable: false`.
- Every open sets `PRAGMA synchronous=FULL`, so a write is synced before its command reports it, whatever default the SQLite build has.
- The wait for a busy bus is timed on the monotonic clock; a wall-clock change no longer ends it early or stretches it.
- The reference says what a second SQLite connection to the bus does to agentbus commands, and the skill says where a batch cut by `inbox | head` can be read again (`read --since ID`).

### Fixed

- `schema --json` marks the same arguments required on every Python. Below 3.12 it marked `goal TEXT`, `schema COMMAND`, `help COMMAND` and `update DIR` required, and 3.12 and later did not mark `ctx set VALUE` or `log add DETAIL`; both now follow the command's real rule.
- `watch` shows a span from a clock that ran backwards as `0s`, not `-1m`, and a field squeezed to zero columns is empty, not a one-column ellipsis.
- `setup` can no longer be redirected by a folder swapped for a link while it runs: every write, backup and removal goes through a folder held open with `O_NOFOLLOW`, and a link that appears in the way is refused by name.
- `agentbus init` on the home folder no longer prints a `cd` and `join` step that fails: discovery never looks in the home folder, so it says to pick a project folder instead.
- `doctor` finds a second bus above worktrees made with `worktree.useRelativePaths`, and prints a path in its hints as `~/'my dir'`, never `'~/my dir'`.
- `setup --refresh` names the real step for a skill agentbus did not write: move it aside, then run setup.
- The hint after `release` with no resource carries `--up N` when you gave it.
- `examples/two-agent-handoff.sh` leaves `XDG_STATE_HOME` and `XDG_CACHE_HOME` alone, so on Linux the demo bus stays out of your bus list.
- The SessionStart text is shortened, not dropped, when the bus copy sits at a long path.
- The `watch` hints quote a fact key and show `NAME` for an agent name that is not a plain word.
- `join` by the session that already holds a hook-given name (it carries `AGENTBUS_AGENT`) succeeds; for any other caller the error says to skip `join` if a hook named you. The skill says to skip `join` when a hook gave you a name, and has a "Use when" line.
- The Codex steps say Codex shows a "Hooks need review" screen (or type `/hooks`).

## 0.2.0 - 2026-11-04

All five versioned things change (see [How versions fit together](docs/explanation/versions.md)): the tool is 0.2.0; the copy in each bus folder is replaced by `agentbus upgrade` (or `update`); the schema is now stamped 1, the v0.1.0 shape, so a v0.1.0 bus is adopted with no other change; the skill is rewritten; and the hooks are new.

From v0.1.0, which has no `update`: install once from the [README](README.md), then run `agentbus upgrade --all PARENT_DIR` for your bus folders. After that, `agentbus update` installs each release and upgrades the bus folders it knows.

### Added

- `agentbus init` makes the bus database, so the hooks work as soon as it returns. It refuses a folder that holds worktrees of a repo that already has a bus, and a folder inside a linked worktree, where discovery never looks (`bad_input`: one repo, one bus; `--second-bus` makes the bus anyway, except at a worktree's top folder). Re-running it on a folder with a bus leaves the database as it is.
- `agentbus update` installs the latest release wheel, checks it against the release's `SHA256SUMS`, upgrades your bus folders and refreshes the skill. `--check` only says whether a newer release exists. At a terminal, a command may tell you once a day that a release is out (never in CI, with `--json` or in an agent session; `AGENTBUS_NO_UPDATE_CHECK=1` turns it off). What it sends is in [SECURITY.md](SECURITY.md).
- The Claude Code plugin: `/plugin marketplace add wickdninja/agentbus`, then `/plugin install agentbus@agentbus`. Five hooks join the folder's bus when a session starts and say its name and how many messages wait, note a claim held by another agent before an edit, remind you at the end of a turn about claims still held, and leave when the session ends. They never create a bus, claim for you or block a turn. See [Use agentbus in Claude Code](docs/how-to/claude-code.md).
- `agentbus setup claude` and `agentbus setup codex` install the skill and hooks for Claude Code (five hooks), or the agentbus block in Codex's `AGENTS.md` and four Codex hooks (approve them with `/hooks` in Codex). `--dry-run` shows the plan, `--uninstall` removes only what setup added, `--refresh` brings it up to date. See [Set up your agents](docs/how-to/setup.md).
- `agentbus brief` is the first call after `join`: the goal, who is here and what each holds, open questions, your unread handoffs and alerts, facts changed since you last read your inbox, what waits between other agents, and a `next:` command. It only reads and never marks anything read. A realistic four-agent bus fits in under 1,600 characters. `--limit N` bounds each section.
- `agentbus demo`: a 30-second tour of two agents on a temporary bus. It never touches the bus of the folder you run it in and removes its directory when it ends.
- `agentbus doctor` checks the tool, this folder's bus, the bus folder's copy, the Claude Code skill, the Codex block and the hooks, an `AGENTBUS_DB` that names another bus, and a bus folder directly above this repo's worktrees that they do not use. It prints the fix for each problem, or what to look at when no command can fix it, and fixes nothing itself. See [Check your install](docs/how-to/doctor.md).
- `agentbus skill` prints the bundled skill; `agentbus skill --agents-md` prints the `AGENTS.md` block. `agentbus schema` prints every command's arguments, result shape, error codes and retry rule (`--json` for tools).
- `agentbus upgrade --all DIR` upgrades the copy and the database of every bus folder under DIR, one line per bus. A bus copy older than the tool shows a notice on stderr from `join`, `status` and `buses`, naming `agentbus upgrade DIR`.
- `watch` opens any row with `Enter`, filters with `/` and lists its keys with `?`. See [Watch your agents](docs/how-to/watch.md).
- `join`, `leave`, `post`, `claim`, `release`, `goal` and `ctx set` take `--request-id TOKEN`. A `post` or `join` repeated with the same token returns the first result (`duplicate: true`) and writes nothing. `release RESOURCE --if-held` succeeds, releasing nothing, when you do not hold the claim. `post` to a name that has not joined still delivers, with a warning that lists the roster.
- Every `--json` error carries `code`, `message`, `retryable`, `committed` and `next`, the command to recover (or `null`). A claim conflict gives the whole command to ask the holder.

### Changed (breaking)

- Agents run `agentbus` from `PATH`, and tell you to install it when it is not there and the folder has a bus. The skill and the `AGENTS.md` block no longer offer `.agentbus/bin/agentbus`; a repository can ship that file. Install the tool on any machine where agents join a bus. A dispatcher can still assign a sandboxed worker the copy by absolute path, with `AGENTBUS_DB`. From a clone, `init` says to install it first.
- Every `--json` result starts with `"contract": 1`. Listings (`who`, `inbox`, `read`, `claims`, `ctx get`, `ctx history`, `log show`, `buses`) return `{"contract": 1, "items": [...], "has_more": false, "next": null}`; before, a bare array. Scripts read `.items`; `--before NEXT` (and `--after NEXT` for `inbox --peek`) continues a listing.
- Exit codes are the same with and without `--json`: 0 ok, 1 the command ran and refused, 2 usage, 3 the bus is unavailable, 4 internal error.
- A write needs a name on the roster: `post`, `ctx set`, `goal` and `log add` under a name that has not joined fail with `not_on_roster`. Run `agentbus --as NAME join` first.
- `post --to X --to Y` is `bad_input`; before, the last `--to` won. `goal` is a reserved fact key (`ctx set goal ...` is `bad_input`; use `agentbus goal TEXT`). `join` accepts only `[A-Za-z0-9._-]` names of 1 to 40 characters. Names, topics, `ctx` keys and claim resources refuse control characters.
- In `watch`, `Esc` goes back and `q` quits only from the main view; before, `Esc` quit.
- The skill moved to `skills/agentbus/SKILL.md`; `skill/SKILL.md` stays as a link, so the v0.1.0 README line still works from a clone.
- GitHub Releases is the only release channel, and the README installs the release wheel. The name `agentbus` on PyPI is a different project: do not install it.

### Fixed

- Deleting claims no longer rewrites the freed pages. On SQLite as Debian and Ubuntu build it, releasing or leaving over 500 large claims wrote hundreds of megabytes with the bus held; agentbus now sets `secure_delete=FAST`.
- `AGENTBUS="python3 bin/agentbus" bash examples/two-agent-handoff.sh` works from a clone.

## 0.1.0 - 2026-11-01

Initial release: a workspace bus in any directory, shared by its repos and linked worktrees. Buses nest; --up selects an outer bus and buses lists the chain. AGENTBUS_DB assigns an explicit bus to sandboxed lanes.

Per-agent inboxes, shared facts and history, advisory expiring claims, an activity log, JSON output, a live watch view, a shared goal (`goal`, shown by join, status and watch), emoji in watch on a terminal (`AGENTBUS_NO_EMOJI=1` turns them off), and an agent coordination skill. Init installs a local copy; path claims are relative to the bus directory.

Supports macOS and Linux, Python 3.9+, and Git 2.31+. One file, standard library only.
