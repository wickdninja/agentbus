# Upgrade agentbus

Each bus folder carries its own copy of agentbus (`.agentbus/bin/agentbus`) and its own database
(`.agentbus/bus.db`). Upgrading means replacing the copy and, when the new release changed the
database's shape, migrating the database. `agentbus upgrade` does both.

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
   If a sandboxed lane could write `backups/` (a grant without the `backups/` rule in
   [Sandboxed agents](../sandboxed-agents.md)), skip this step and run `agentbus upgrade DIR` from
   the agentbus you installed. The kept copy may not be the file `upgrade` saved, and
   `bin/agentbus` is code you and your agents run outside any sandbox. `upgrade` writes the
   installed tool's own file there instead. It also migrates the restored bus again, with a new
   backup.

The restored bus has the old shape, and the folder's copy reads and writes it as before. Run agents
through that copy (`.agentbus/bin/agentbus`): a newer agentbus migrates the bus again on its next
write, with a new backup.
