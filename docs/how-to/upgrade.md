# Upgrade agentbus

One command takes you from one release to the next, everywhere:

```
agentbus update
```

It reinstalls agentbus from the new release, upgrades every bus folder it knows, and refreshes the
skill, the `AGENTS.md` block and the hooks that setup installed, when they are older and unedited. Nothing else
is touched. Releases come from GitHub Releases only.

**`pip install agentbus` and `uv tool install agentbus` install a different project.** The name `agentbus` on PyPI
belongs to an unrelated package, and agentbus is never published there. Install and update only with the lines in
the README and `agentbus update`.

```
$ agentbus update
agentbus 0.2.0, installed with uv from github.com/wickdninja/agentbus
latest release: 0.3.0
downloading agentbus-0.3.0-py3-none-any.whl and SHA256SUMS from github.com/wickdninja/agentbus/releases (the wheel's sha256 is checked against SHA256SUMS before anything is installed)
running: /Users/me/.local/bin/uv tool install --force ~/Library/Caches/agentbus/downloads/agentbus-0.3.0-py3-none-any.whl
...the installer's own output...
agentbus 0.3.0 is installed.
bus folders: upgraded 3, current 1, skipped 0, failed 0
  ~/src/app   0.2.0 -> 0.3.0
  ...
done: 0.2.0 -> 0.3.0. Restart Claude Code and Codex sessions, and any agentbus watch, to load it.
```

- `agentbus update --check` only says whether a newer release exists (`agentbus 0.2.0 (uv). Latest release: 0.3.0.`) and exits 0 either way. `--json` gives `update_available` and the installer command.
- `agentbus update --dry-run` prints `would run: ...` and the folders it would upgrade, and changes nothing.
- `agentbus update ~/src/app` names one bus folder. A folder that is not a bus (`agentbus update ~/src`, the folder that holds your repos) is remembered, and every bus under it is upgraded now and on later plain `agentbus update` runs. Buses made by `init` and `upgrade` are remembered too; older buses are not, until you name their folder once.
- `--no-buses` and `--no-setup` skip those steps.
- The Claude Code plugin updates through Claude Code. When `update` finds it installed it says so: `/plugin marketplace update agentbus`, then `/reload-plugins`. It never runs `claude` and never writes plugin files.

### How the tool is reinstalled

`update` reads the release's asset list from the GitHub API answer it already fetched, then downloads the release
**wheel** and `SHA256SUMS` from `https://github.com/wickdninja/agentbus/releases/download/vX.Y.Z/` into a 0700
folder under your cache folder (at most 5 MiB and 4 KiB, 60 seconds each, TLS verified, redirects only to GitHub's
own hosts). It checks the wheel's sha256 against `SHA256SUMS` and installs that local file with the tool that
installed agentbus. Nothing is built from source and no package index is asked. The downloaded files are removed
afterwards. A wheel that does not match is refused (`download_failed`, reason `hash_mismatch`) and nothing is
installed.

| Installed with | `update` runs (`WHEEL` is the verified download) |
|---|---|
| uv | `uv tool install --force WHEEL` |
| pipx | `pipx install --force WHEEL` |
| pip, in a virtual environment | `python -m pip install --upgrade WHEEL` |
| a clone of the repository | prints `git -C DIR fetch --tags` and `git -C DIR checkout vX.Y.Z` |
| a fork, or anything else | prints the install lines to run (these build from source) |
| no safe installer on `PATH` | prints the install line for your tool (this builds from source) |

If a release has no wheel or no `SHA256SUMS`, `update` exits 1 with `manual_step` and the one command that would
build from source; it never falls back to that on its own. A source build (`git+...@vX.Y.Z`, which is also what the
README's first-install line does) fetches the build backend and its dependencies from PyPI; the wheel route does not.
The installer runs with your cache folder as its working folder.

If `update` cannot run an installer itself it exits 1 with `manual_step` and the commands. Coming from 0.1.0,
which has no `update`, run the install line from the README once at the new tag.

An installer that fails, hangs (900 s, then it is stopped) or leaves the version unchanged is
`installer_failed`, with the command to run yourself. Ctrl-C stops the installer and exits 130
(`interrupted`, with the command and `agentbus update` to run again). To go back, run the same
command at the old tag, then restore the bus backups described below.

### Inside an agent session

When `CLAUDECODE`, a Codex shell variable or `AGENTBUS_AGENT_SESSION` is set, or stdin, stdout or stderr is not a terminal,
`update` upgrades only the current bus and skips setup, and says so (`agent session (CLAUDECODE is
set): upgrading this bus only and skipping setup. Run with --all-buses for the rest.`). `--all-buses`
widens it. Typing `--as` or setting `AGENTBUS_AGENT` does not make a session an agent's. A harness agentbus does not recognise
should set `AGENTBUS_AGENT_SESSION=1`, which silences the release notice and narrows `update` the same way.

## The release notice

Once a day, a command you run at a terminal on a tool-installed agentbus may print one line on stderr:

```
agentbus: a new release is available: 0.2.0 -> 0.3.0. Run: agentbus update
```

A detached background process asks GitHub for the latest release and remembers the answer in a cache
file (`~/Library/Caches/agentbus/release-check.json` on macOS, `$XDG_CACHE_HOME/agentbus/` or
`~/.cache/agentbus/` elsewhere); the notice shows on the run after a check and at most once a day. It
is never shown with `--json`, in CI (`CI`, `BUILD_NUMBER` or `RUN_ID` set), in an agent session, from a
project copy, a clone or a fork, or by `hook`, `watch`, `doctor`, `schema`, `skill` and `update` itself.
Turn it off with `AGENTBUS_NO_UPDATE_CHECK=1` (`DO_NOT_TRACK=1` and `NO_UPDATE_NOTIFIER=1` also do);
`AGENTBUS_NO_UPDATE_NOTICE=1` silences the notice and the stale-copy notice below. The check sends one
request to `api.github.com` with no identifier; see [SECURITY.md](../../SECURITY.md).

## Upgrade a bus folder without `update`

Each bus folder carries its own copy of agentbus (`.agentbus/bin/agentbus`) and its own database
(`.agentbus/bus.db`). Upgrading means replacing the copy and, when the new release changed the
database's shape, migrating the database. `agentbus upgrade` does both, and `agentbus update` runs it for
each bus it knows.

## Upgrade every bus under a folder

```
agentbus upgrade --all ~/src
```

It finds every bus folder under `~/src` (5 levels deep by default; `--depth N` changes that). It
never follows a symlink and skips `.git`, `node_modules`, `.venv` and `__pycache__`. For each bus it
replaces the copy, then opens the database once, which migrates it if needed. One line per bus:

```
~/src/app   0.1.0 -> 0.2.0   schema 0 -> 1   backup .agentbus/backups/bus-v0-20261101T201500Z.db
~/src/api   0.1.0 -> 0.2.0   schema 0 -> 1
~/src/site   current (0.2.0)
~/src/old   skipped: copy is newer (0.3.0)
~/src/locked   failed: busy. Close any sqlite3 shell or dashboard holding it, then retry.
upgraded 2, current 1, skipped 1, failed 1
```

- `schema 0 -> 1` with no backup: the bus already had the new shape and only got its version stamp.
- `schema 0 -> 1` with a backup: the bus was migrated, after a backup was taken.
- `skipped`: the folder's copy is newer than the tool you ran. It is never downgraded.
- `failed`: the line says why. The others are still upgraded, and the command exits 1. A bus held
  by another process for more than 5 seconds fails as busy, with nothing changed. When the bus was
  migrated but its copy could not be replaced, the line says the bus was migrated, names the backup
  and says to run `agentbus upgrade DIR` again; until then the folder's own copy refuses the newer
  bus (`schema_newer`). Fix the cause (the path is in the line) and run that command: it replaces
  the copy and migrates nothing twice.

`--dry-run` applies no upgrade and writes no copy or backup; it lists what would change. Like every read, it may finish SQLite's recovery of a crashed writer's journal. `--json` prints one object:
`{"buses": [{"directory", "status", "old", "new", "schema_old", "schema_new", "backup", "error"}], "upgraded": N, "current": N, "skipped": N, "failed": N}`.
When a bus failed, stderr also holds the `items_failed` error, whose `failed` lists those rows.

To upgrade one bus, `agentbus upgrade DIR` (or no DIR for the nearest bus). Its `--json` object is
`{"directory", "old", "new", "schema_old", "schema_new", "backup"}`.

Run `upgrade` from the installed tool or a clone, not from a project copy.

## When agentbus tells you

The installed tool prints this on stderr from `join`, `status` and `buses` when the bus's copy is
older than it:

```
agentbus: this bus's copy is 0.1.0; the installed agentbus is 0.2.0. Run: agentbus upgrade /Users/me/src/app
```

`AGENTBUS_NO_UPDATE_NOTICE=1` turns it off. It never appears with `--json`; read stdout only when you
parse JSON.

A newer agentbus opening an older bus migrates it on its first write (any command but `watch`).
`watch` changes no data or schema (it may finish SQLite's recovery of a crashed writer's journal): on an older bus it says the bus could not be read and names
`agentbus upgrade DIR`. A running `watch` keeps the code it started with; restart it after an
upgrade.

An older copy meeting a newer bus refuses and writes nothing:

```
this bus is newer than this copy of agentbus (schema 2, this copy knows 1). Use a newer agentbus: agentbus upgrade DIR from an up-to-date install
```

A 0.1.0 copy predates schema versions. It reads a version-1 bus (the same shape) but refuses any
newer shape with `bus schema is not agentbus's: ...` (`schema_refused`). Upgrade the folder's copy.

## Backups

Before a migration writes anything, agentbus copies `bus.db` to
`.agentbus/backups/bus-v<old version>-<UTC time>.db` (owner-only, mode 0600). It first checks the
bus with SQLite's `quick_check`, then checks the copy byte for byte against the bus. If the copy
cannot be made (not enough free space: it needs twice the bus size plus 16 MB), the command fails
with `backup_failed` and the bus is unchanged. A migration gets 9 seconds, so other agents waiting
on the bus (they wait 15) always get it; a bus too large to back up and migrate in that time fails
with `backup_failed`, unchanged. When `upgrade` replaced the folder's copy, the copy
it replaced is kept beside the backup as `agentbus-<UTC time>` and `VERSION-<UTC time>`. The newest
5 backups are kept.

A bus that only needs its version stamp gets no backup.

## Restore a backup

Restoring brings the bus back to the moment of the backup. Rows written since then are not in the
restored bus; they stay in `bus.db.broken`.

1. Stop every agent and every `watch` using the bus.
2. Find the backup. Its name is `bus-vN-STAMP.db`; when `upgrade` made it, `agentbus-STAMP` and
   `VERSION-STAMP` sit beside it:
   ```
   ls .agentbus/backups/
   ```
3. Move the migrated bus, its write-ahead log and its shared-memory file aside:
   ```
   mv .agentbus/bus.db .agentbus/bus.db.broken
   [ ! -e .agentbus/bus.db-wal ] || mv .agentbus/bus.db-wal .agentbus/bus.db.broken-wal
   [ ! -e .agentbus/bus.db-shm ] || mv .agentbus/bus.db-shm .agentbus/bus.db.broken-shm
   ```
4. Copy the backup into place and make it owner-only:
   ```
   cp -p .agentbus/backups/bus-vN-STAMP.db .agentbus/bus.db
   chmod 600 .agentbus/bus.db
   ```
5. Put back the copy that wrote it, if `upgrade` kept one (otherwise the folder's copy was not
   changed):
   ```
   cp -p .agentbus/backups/agentbus-STAMP .agentbus/bin/agentbus
   chmod 700 .agentbus/bin/agentbus
   cp -p .agentbus/backups/VERSION-STAMP .agentbus/VERSION
   ```

The restored bus has the old shape, and the folder's copy reads and writes it as before. Run agents
through that copy (`.agentbus/bin/agentbus`): a newer agentbus migrates the bus again on its next
write, with a new backup.
