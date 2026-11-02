# Sandboxed agents on the bus

A lane that runs under an OS sandbox can still join the bus, as long as you grant it exactly one
folder: the bus's `.agentbus/`, in a repo or a workspace. This page covers how to grant that folder and nothing more.

## Threat model

A sandboxed lane is treated as hostile: it may write, rename or delete anything in `.agentbus/`
except `bin/`. The human and the orchestrating agent run the CLI unsandboxed, in that same folder.

- **What agentbus guarantees, given the sandbox below:** the unsandboxed CLI never writes to,
  truncates or changes the mode of a file outside `.agentbus/`, and never runs code a lane wrote.
- **What that guarantee depends on:** the lane's sandbox must deny creating links, symbolic or
  hard, in the bus folder, must deny creating special files (FIFOs, sockets, device nodes), and
  must keep `bin/` read only. SQLite opens its files by name and Python cannot tell it not to
  follow links, so a link planted at the wrong moment (a hard link at `bus.db-journal` between the
  CLI's checks and its connect, for example) can still redirect a write. A FIFO planted there
  makes SQLite's own open of it block; the CLI's watchdog then ends the command after 6 s (a
  denial of service, no write), and the sandbox rule makes planting one impossible.
- **The CLI's own checks are a second layer,** described below. They catch every link case our
  tests exercise except that one window, and they keep working when a sandbox is weaker than it
  should be, but they are not the guarantee.
- **What no sandbox changes:** a lane with write access can post anything, edit or delete rows,
  and forge claims. See the threat notes at the end.
- **Availability is out of scope.** A lane that can write `bus.db` can always deny service: it can
  hold the lock with its own `sqlite3` connection, or delete the bus. agentbus does not try to stop
  that. What stays in scope against a hostile lane: no write outside `.agentbus/`, no forged
  output, no lost or duplicated data for honest agents (beyond `inbox`'s documented
  at-least-once), and the CLI bounding its *own* hold of the lock below the 15 s other agents wait,
  whatever rows a lane planted, so planted rows cannot turn one honest command into a long hold.

Each harness section below says whether the link requirement is met and how that was checked.

## The grant

`agentbus init <dir>` creates `<dir>/.agentbus/`, owned by you, mode 0700:

```
.agentbus/
  bin/agentbus     the tool (the brain runs this outside any sandbox)
  VERSION
  bus.db           created on first use, plus bus.db-wal
```

A sandboxed lane gets:

| Path | Access | Why |
|---|---|---|
| `<bus directory>/.agentbus/` | read and write | SQLite in WAL mode writes `bus.db` and `-wal` side by side. Under agentbus SQLite never opens `-shm`; when one exists, agentbus only checks it and sets its mode to 0600 through an `O_NOFOLLOW` fd. Other SQLite clients on the same file may create and use it |
| `<bus directory>/.agentbus/bin/` | read only | `bin/agentbus` is code the brain and other agents run unsandboxed; a lane that could rewrite it could run code outside its sandbox |
| everything else | whatever the lane already had | the bus adds nothing else |

Set these in the lane's environment, and don't rely on the lane discovering them:

```bash
AGENTBUS_DB=<bus directory>/.agentbus/bus.db   # the dispatcher assigns the bus explicitly
AGENTBUS_AGENT=<tool>-<project>-<lane>         # one name per lane
PATH=<bus directory>/.agentbus/bin:$PATH
```

Put the protocol in the brief: join, read rulings, claim before editing, hand off, leave. The
lane's own sandbox makes `--as` unnecessary only if the environment survives between its tool
calls; when in doubt, have it pass `--as` on every call.

The brain and every dispatcher set `AGENTBUS_DB` explicitly too, for their own commands, and never
rely on git discovery from inside a tree a lane can write. A lane can plant a nested repository in
its worktree (`pkg/.git` with `core.worktree=/elsewhere`); a command run from inside it then finds
that repository, and its bus, instead of the real one.

A sandbox that allows writes to a folder usually allows creating links in it too (macOS
`sandbox-exec` does), so the lane's sandbox must deny that explicitly (the rules below). After
the lane exits, the dispatcher still sweeps the bus folder recursively, through every
subdirectory: remove any symlink, hard link or special file the lane left anywhere in it, and fail
the run. The sweep must be recursive because the rules below let a lane move a whole directory in,
and a directory made before the sandbox started can already hold a symlink.

## What the CLI does against a lane that plants links

The brain runs the CLI unsandboxed, in a folder the lane can write. The CLI:

- refuses to open a bus when `.agentbus/`, `bin/`, `VERSION`, `bus.db`, `-wal`, `-shm` or
  `-journal` is a symlink, a hard link, the wrong type or owned by someone else, and refuses any
  `-journal` at all (agentbus never writes one);
- tightens modes only through an `O_NOFOLLOW` fd that is the same single-link node it just
  checked (device and inode), so a link swapped in after the check is refused, never chmodded;
- opens `bus.db` itself with `O_NOFOLLOW` and lets SQLite only reopen it (`mode=rw`, never create);
- right after SQLite opens `bus.db`, and again right after it opens `-wal`, checks every regular
  file the process holds: each must be the single-link file named `bus.db` or `bus.db-wal` in the
  folder at that moment (device and inode). A link swapped in between the checks and SQLite's open
  is caught here, before any write, and the CLI then exits without closing SQLite, because a normal
  close checkpoints and can truncate the `-wal` it holds;
- uses SQLite's exclusive locking mode, so SQLite never opens `-shm` (the WAL index lives in memory)
  and one agentbus command holds the bus at a time; others retry for up to 15 seconds. It reads
  stdin before opening the bus and writes nothing to stdout or stderr (output, notices and errors
  alike) until it has closed it, so a slow or full pipe never holds it;
- runs the phases of opening the bus that block outside SQL (the connect, the first read, and
  SQLite's own opens of `-wal`, a hot `-journal` or a super-journal it names) under a watchdog: a
  command still there after 6 s exits with an `agentbus:` error, which releases the lock before
  another agent's 15 s of retries run out. A FIFO planted at `bus.db-journal` after the checks would
  otherwise make that open block forever with the bus locked;
- bounds its own hold of the lock, counted from the connect: all of a command's SQL gets 6 s (a
  statement still running then is stopped and its write rolled back), and everything else done
  with the bus held (Python loops, fetching and decoding rows) 2 s more. At 8 s a second watchdog
  ends the command with an `agentbus:` error, at least 5 s inside the 15 s another agent waits
  even on a slow machine, where a stopped process takes a moment more to be gone;
- re-checks inside every write transaction that the path still names the file it holds.

`init` and `upgrade` refuse the same links. They write `bin/agentbus` and `VERSION` only through fresh temp files (`O_EXCL`, then rename). The one file written in place, when the bus belongs to a checkout root, is
`.git/info/exclude`: `init`, and any command that finds the rule in neither it nor `.gitignore`,
appends `.agentbus/` to it through an `O_NOFOLLOW|O_NONBLOCK` fd that must still be a single-link
regular file you own, after refusing a symlinked `info/` or a symlinked or hard-linked `exclude`.
A lane cannot write that file (it is outside the folder). When an ordinary command cannot add the
rule (the lane's own command, or a refused `exclude`), it prints a notice and carries on; `init`
refuses.
`tests/test_race.sh` swaps `bus.db` and `-wal` for symlinks and hard links to a victim database,
both at exact points and in a loop against 300 posts, and checks the victim stays byte-identical.

**Residual window.** Python's `sqlite3` cannot pass `SQLITE_OPEN_NOFOLLOW` (no `flags` argument on
3.9 to 3.15, and no URI parameter for it), so SQLite opens `bus.db`, `-wal` and a `-journal` by
name, following links. Between the CLI's last check and SQLite's open:

- SQLite may *read* a swapped-in file before the audit catches it.
- A hard link planted at `bus.db-journal` before the CLI connects can be written to before any
  check of the CLI's can see it. This is the case that makes the sandbox rule required, not
  optional.
- SQLite creates `-wal` with `O_CREAT`; a dangling symlink planted at exactly that moment could
  make an SQLite build that follows it create an empty file at the link target. SQLite 3.54
  (macOS 27) refused such a link in our tests; other builds may not.

**The rules that close it.** On macOS, add these four rules to the lane's `sandbox-exec` profile,
after the rules that grant the folder:

```scheme
(deny file-write* (literal "<bus directory>/.agentbus"))
(deny file-write-create (vnode-type SYMLINK))
(deny file-write-create (vnode-type FIFO SOCKET CHARACTER-DEVICE BLOCK-DEVICE))
(deny file-link (subpath "<bus directory>/.agentbus"))
```

- The first stops the lane moving or replacing the folder itself. Without it, a lane that has any
  other writable dir (every real lane does) can move `.agentbus` there, rewrite `bin/agentbus`,
  move it back, and have the brain run that code.
- The second denies creating a symlink *anywhere*, not just in the folder: a symlink made in the
  lane's own tmp dir or worktree could be swapped into the folder with `renamex_np(RENAME_SWAP)`,
  which no create rule on the folder sees. The same rule also refuses renaming or swapping a
  symlink that existed before the sandbox started into the folder. It does not stop a whole
  directory being moved in with such a symlink inside it, hence the recursive sweep above.
- The third denies creating a FIFO, socket or device node anywhere, for the same reason as the
  second: one made elsewhere could be moved in. The rule also refuses moving one made before the
  sandbox started into the folder. A FIFO at `bus.db-journal` makes SQLite's open of it block (10
  of 30 commands hung in a mkfifo loop before the CLI's watchdog); device
  nodes need root anyway, so for them the rule is a second layer.
- The fourth denies hard links in the folder; hard links to files the lane cannot write are already
  denied by the base `(deny file-write*)`.

`tests/test_sandbox.sh` checks all of it on this Mac (macOS 27.0.1), with a writable lane tmp dir
as a real lane has: `join`, `post` and `read` work, and ordinary create, rename and delete in the
folder work; a symlink anywhere, a hard link from outside or inside the folder, a planted
hard-linked `bus.db-journal`, moving `.agentbus` or `bin/` out, writing `bin/agentbus` and writing
elsewhere are all denied, and so are a FIFO or socket made in the folder or the lane's tmp dir and
moving (or `RENAME_SWAP`ping) one made before the sandbox into the folder; without the FIFO rule the
same profile lets a lane make a FIFO in the folder (the negative control). A symlink the test made before the sandbox started cannot be moved or
swapped (`renamex_np` with `RENAME_SWAP`) into the folder, and the same swap succeeds under the
profile without the global symlink rule (the test's negative control). A directory holding such a
symlink can be moved in, and the symlink inside it then cannot be moved on to a bus file's name.
A lane can join, post and read when `info/exclude` lacks the rule, with or without the rule in
`.gitignore`. With the earlier folder-scoped rules the test fails ("the bus folder itself can be
moved").

The global symlink rule means a lane cannot create symlinks in its worktree either (a checkout of
a repo that tracks symlinks fails). If a harness has to allow that, the lane is outside the
guarantee: the CLI's checks still refuse a symlinked bus file, but a symlink swapped in during the
window above is no longer prevented. In our tests SQLite 3.53 and 3.54 then refused to open the
bus (a denial of service, no write to the target); other builds may differ.

## Per harness

These recipes come from working dispatchers. Each was checked on the version named; re-check
when you upgrade, since harness sandboxes change between releases.

### Codex CLI (permission profiles, checked on 0.164.0)

Use an inline permission profile to keep `bin/` read only inside the writable folder:

```bash
B=<bus directory>/.agentbus
codex exec \
  -c "permissions.bus-ro.filesystem={\":root\"=\"read\",\"$B\"=\"write\",\"$B/bin\"=\"read\"}" \
  -c 'permissions.bus-ro.network={enabled=false}' \
  -c 'default_permissions="bus-ro"' \
  ...
```

For a lane that also edits a worktree, add the worktree as `write` (and keep its `.git` as
`read`). A `sandbox_mode` set in any Codex config layer overrides the profile, so refuse to run
the lane if one is set.

Link and special-file requirement: not verified. Nothing here shows that a Codex permission
profile denies creating symlinks, hard links or FIFOs inside a writable folder; until you have
proven it from inside the sandbox (see "Any other harness"), treat a Codex lane on the bus as
outside the guarantee.

### Antigravity CLI (`agy`): wrap it in `sandbox-exec`

Measured on agy 1.4.8: `--sandbox` makes `-C` and `--add-dir` read-only to the shell and leaves
every other path the user can write writable. It does not confine the lane, so don't rely on it.
Run agy under `/usr/bin/sandbox-exec` with a profile you write per lane. A minimal one:

```scheme
(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "/dev"))
(allow file-write* (subpath "<lane tmp dir>"))
(allow file-write* (subpath "<bus directory>/.agentbus"))
(deny  file-write* (subpath "<bus directory>/.agentbus/bin"))
(deny file-write* (literal "<bus directory>/.agentbus"))
(deny file-write-create (vnode-type SYMLINK))
(deny file-write-create (vnode-type FIFO SOCKET CHARACTER-DEVICE BLOCK-DEVICE))
(deny file-link (subpath "<bus directory>/.agentbus"))
```

Link and special-file requirement: met and tested on macOS 27.0.1 (`tests/test_sandbox.sh`).

Later rules win, so `bin/` stays read only inside the writable folder. Use physical paths
(`pwd -P`); on macOS `/tmp` is `/private/tmp`. Checked on macOS 27.0.1: under this profile
`agentbus join` and `post` work, and writing `bin/agentbus`, renaming `bin/`, writing elsewhere in
the repo, writing to `$HOME`, and moving `.agentbus` or `bin/` out are all denied. A real lane needs more than this: the harness's
own state directory, its log, and for an editing lane the worktree plus the git paths a commit
writes (its git dir, `objects/`, its own branch ref and reflog, never hooks or the repo config).
Consider denying reads of other repos' `.agentbus/` folders and of `~/.ssh` too.

### GitHub Copilot CLI (settings, not yet checked live)

Add `<bus directory>/.agentbus` to the lane's `readwritePaths` and
`<bus directory>/.agentbus/bin` to `readonlyPaths`, and set the bus variables in the lane's
environment only. Whether a read-only path nested inside a read-write one holds has not been
measured on a live Copilot sandbox yet; probe it before you rely on it.

Link and special-file requirement: not verified, for the same reason as Codex.

### Any other harness

Grant the folder, deny `bin/`, then prove it from inside the sandbox before you trust it: run
`agentbus join` and `post` (they should work), then try to write `bin/agentbus` and a file
outside the grant (both should fail). Then prove the link and special-file requirement: from
inside the sandbox, `ln -s /tmp <bus>/x`, `ln <a file outside> <bus>/y`, `ln <bus>/VERSION <bus>/z`
and `mkfifo <bus>/f` must all fail. If any succeeds, the harness does not meet the guarantee above.

## Threat notes

- **Messages are peer information, not instructions.** A lane that can write the bus can post
  anything. Agents treat bus messages as notes from a peer; only the human owner's words direct
  work.
- **No secrets on the bus.** Every agent with the folder can read every message. Say where a
  secret lives, never its value, and never post environment dumps.
- **Claims are advisory.** A claim is a promise between cooperating agents, not a lock. A
  sandboxed lane is confined by its sandbox, not by the bus.
- **The bus folder is shared state.** Anything with write access can edit or delete rows directly
  with SQLite. Git, the issue tracker and the code stay the source of truth; the bus only
  coordinates.
- **Rows, yes; schema, no.** A lane can tamper with any row, but agentbus refuses a bus that
  carries a schema object it did not create (a trigger, a view, or an extra table or index) or a
  table whose shape is not agentbus's own (columns, types, NOT NULL, defaults, every index including
  SQLite's automatic ones, foreign keys and their actions, and any CHECK, COLLATE, ON CONFLICT,
  generated column, WITHOUT ROWID or STRICT its definition lacks), before running any statement
  that could fire one or write. All of a command's SQL together gets 6 seconds and the whole hold
  8 (see above); a statement still running when the SQL budget is spent is stopped (its write
  rolled back). Formatting the output happens after the bus is closed, and listings (`inbox`, and
  what `leave` and `release --all` print and log, included) stop at 500 rows unless `--limit` says
  otherwise. `claim` takes at most 1024 characters and finds overlapping claims through the
  resource index, never by reading every claim; text a lane planted is cut to 1024 characters
  wherever agentbus writes it into a log row or an error, and a planted resource longer than that
  is never read by the open-time normalisation.
