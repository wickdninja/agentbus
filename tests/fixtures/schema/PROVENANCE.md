# Schema fixtures: where each one came from

Every shape in `HISTORY` (bin/agentbus) is one captured from a real bus, never guessed. Each
captured shape is a schema-only dump (no rows) in this folder, made with:

```
sqlite3 FILE .schema > <shape>.sql
sqlite3 FILE 'PRAGMA user_version'
```

`tests/test_schema.sh` runs one migration case per row of the Shapes table below.

## Shapes

| Fixture | Source bus | Captured | sha256 of the dump | Buses of the 13 with it |
|---|---|---|---|---|

None captured yet. The 13 rollout buses were upgraded by hand on 2026-11-01 (`upgrade_bus.py`), so
they now have the current shape and are not historical; their pre-upgrade backups have not been
dumped. Until a dump lands here, `HISTORY` ships empty and the migration path is tested with a
synthetic entry.

## Legacy copy

| File | What it is | sha256 | git blob |
|---|---|---|---|
| `../legacy/agentbus-0.1.0` | v0.1.0's `bin/agentbus`, byte-identical: taken with `git show v0.1.0:bin/agentbus` while the tag was its original object ed202e389958cdb253426b1514161227e284f953. The 2026-11-02 squash moved the tag, which now names the wave-0 file (blob 94eabdf); `git cat-file blob 35d4b3d7` gives this one. | c12c0b5e0447dc4536aa5d7abc1b8c2625fe78043f208cff541bf302a1ecedc9 | 35d4b3d7ba694b63814e34c4e0bdaddae5cb992c |

Tests use it as an old bus copy: to make v0.1.0 buses, to read a restored backup, and to install a
0.1.0 copy into a bus folder.
