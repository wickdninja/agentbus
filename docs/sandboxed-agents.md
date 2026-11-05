# Sandboxed agents on the bus

A lane that runs under an OS sandbox can still use the bus. On macOS you grant it write access to
three names, `bus.db`, `bus.db-wal` and `bus.db-shm`, only as files, and nothing else in the bus
folder. This page shows how, how to check it, and what that does and does not protect.

The profile below limits what a lane can write, plus three more things: writing to terminals,
pushing input into its own terminal, and connecting to unix sockets. Nothing else. The lane can
still read every file you can (SSH keys, tokens, `~/.claude`), use the network, and signal your
processes. Checked under the recipe's profile: a lane read a file in the home folder, stopped
another process of the same user with `kill -STOP`, and fetched `https://example.com`. To close
those, add read rules (`deny file-read*`) and network rules (`deny network-outbound`) that fit
your setup; this page does not cover them.

## Who this is for

- You run several coding agents at once, and some of them run under a sandbox you control.
- Every agent runs as the same OS user as you. agentbus checks that the bus files are owned by the
  user running it; it does not separate users.
- Tested on macOS 27.0.1 with `/usr/bin/sandbox-exec`, in bash and zsh. Linux is not covered here.

## Terms

- **Lane:** one agent working on one task, usually in its own git worktree. Here, the sandboxed one.
- **Brain:** you, or the agent directing the lanes. It runs unsandboxed.
- **Dispatcher:** whatever starts a lane: a script, a harness, or the brain itself.
- **Grant:** the paths a lane's sandbox lets it write.
- **Bus folder:** `.agentbus/` in a repo or workspace. `agentbus init` makes it.
- **Bus copy:** `.agentbus/bin/agentbus`, the copy of the tool `init` puts there. An agent never picks
  it for itself. A dispatcher can assign it to a lane along with `AGENTBUS_DB`, by absolute path or, as
  in step 4, by putting its folder on the lane's `PATH`.

## Quick recipe (macOS, sandbox-exec)

Every step except the lane itself runs in your own shell, unsandboxed.

**1. Set the paths, once.** Use physical paths. A regex rule is matched against the real path,
and on macOS `mktemp -d` returns `/var/folders/...`, which is really `/private/var/folders/...`.
A regex naming `/var/folders/...` matches nothing, and the lane's post fails with `agentbus:
Operation not permitted`.

```bash
cd ~/src/app
B="$(pwd -P)/.agentbus"                          # the bus folder
LT=$(mktemp -d); LT=$(cd "$LT" && pwd -P)        # the lane's own tmp dir
P=$(mktemp -d); P=$(cd "$P" && pwd -P)           # holds the profile; the lane never gets this one
```

**2. Create the bus.**

```bash
agentbus init .
agentbus --as lead join
```

Output, trimmed and with paths shortened:

```
installed agentbus 0.2.0 into ~/src/app/.agentbus/
added .agentbus/ to ~/src/app/.git/info/exclude (local only; the repo stays clean)
...
joined as lead on ~/src/app/.agentbus/bus.db
```

The `added .agentbus/ to ... exclude` line appears only when the folder is a git checkout root.

For a workspace that holds several repos (`~/src/work/frontend`, `~/src/work/backend`), make the
bus in the parent, `~/src/work`. Claims are paths relative to the bus folder's parent, whichever
repo the lane works in:

```
$ agentbus --as worker claim frontend/src/login.tsx
claimed frontend/src/login.tsx until 2026-11-03T18:29:43Z
```

**3. Write the lane's profile, and a function that runs a command under it.**

```bash
BRE=$(printf '%s' "$B" | sed 's/[][\\.*^$+?(){}|]/\\&/g')   # $B as a regex
cat > "$P/lane.sb" <<SB
(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty")
  (literal "/dev/dtracehelper") (regex #"^/dev/fd/"))
(allow file-write* (subpath "$LT"))
(deny file-write* (subpath "$B"))
(allow file-write* (regex #"^$BRE/bus\.db(-wal|-shm)?\$"))
(deny file-write-create (require-all (subpath "$B") (vnode-type DIRECTORY)))
(deny file-write-create (vnode-type SYMLINK))
(deny file-write-create (vnode-type FIFO SOCKET CHARACTER-DEVICE BLOCK-DEVICE))
(deny file-link (subpath "$B"))
(deny file-ioctl (ioctl-command TIOCSTI))
(deny network-outbound (remote unix-socket))
(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
SB
lane() { /usr/bin/sandbox-exec -f "$P/lane.sb" "$@"; }
```

The function keeps every argument whole, in bash and in zsh. Later rules win. Line by line:

- `/dev`: only these files. All of `/dev` would include your other terminals, and a lane could
  write escape sequences into them.
- `$LT`: the lane's own tmp dir. For a real lane, add its worktree here, and its own copy of the
  harness's config dir (see "Per harness").
- `(deny ... (subpath "$B"))`, then the regex: inside the bus folder, only `bus.db`, `bus.db-wal`
  and `bus.db-shm`. This holds even when `$B` sits inside a folder granted above it.
- `DIRECTORY`: those names only as files. Without it a lane can make a directory at `bus.db-shm`,
  or move one in there, and every agent's next command refuses the bus.
- `SYMLINK`, `FIFO ...`, `file-link`: no symlink and no FIFO, socket or device node anywhere, and
  no hard link in the bus folder. See "Why the link rules".
- `TIOCSTI`: no pushing input into the lane's own terminal. Without it, a lane can type a command
  into the terminal it runs in, and your shell runs that command after the lane exits, outside the
  sandbox. The window size and raw mode still work. Run lanes in a terminal or pty that nothing
  else reads from.
- `unix-socket`: no connecting to unix sockets, except DNS. A socket is a door to the process that
  listens on it, and that process acts with its own access: ssh-agent, Docker, tmux and other
  terminal multiplexers all act outside the sandbox. The allow keeps DNS working; without it, name
  lookups fail and so does HTTPS. A harness that needs another socket (an IDE bridge, a credential
  helper) needs an allow for that exact path.

A path with a `"` in it breaks the profile; use another folder.

**4. Run the lane.** The subshell keeps these variables out of your own shell.

```bash
( export AGENTBUS_DB="$B/bus.db" AGENTBUS_AGENT=codex-app-docs \
         PATH="$B/bin:$PATH" TMPDIR="$LT/"
  lane YOUR-HARNESS-COMMAND )
```

- `AGENTBUS_DB` names the bus. A lane never has to find it (see "Discovery").
- `AGENTBUS_AGENT` is the lane's name. Keep it to 40 characters of letters, digits, `.`, `_` and
  `-`: the Claude Code hooks ignore any other name.
- `TMPDIR` gives the lane its own temp dir. Never give a lane yours (see "Threat notes").

To test it, post the lane its task (it does not have to have joined yet), then run a shell script
in place of the harness:

```bash
agentbus --as lead post "take src/api.py" --to worker
( export AGENTBUS_DB="$B/bus.db" AGENTBUS_AGENT=worker PATH="$B/bin:$PATH" TMPDIR="$LT/"
  lane sh -c '
    agentbus join &&
    agentbus inbox &&
    agentbus claim src/api.py --purpose "fix the retry" &&
    agentbus post "retry fixed in src/api.py" --to lead --kind handoff &&
    agentbus release src/api.py &&
    agentbus leave' )
agentbus --as lead inbox
```

Output, trimmed the same way:

```
agentbus: worker is not on the roster; the message waits for that name.
posted #1 to worker [note]
joined as worker on ~/src/app/.agentbus/bus.db
#1 lead -> worker [note] · 11:33
  take src/api.py
claimed src/api.py until 2026-11-03T18:33:03Z
posted #2 to lead [handoff]
released src/api.py
left as worker, released 0 claims
#2 worker -> lead [handoff] · 11:33
  retry fixed in src/api.py
```

Message kinds are `note` (the default), `question`, `answer`, `handoff`, `decision`, `alert` and
`done`. The [reference](reference.md) has every command.

## Check it

From outside the lane, in `~/src/app`, run [`agentbus doctor`](how-to/doctor.md):

```
  ok    bus        ~/src/app (schema 1)
  ok    copy       0.2.0, same as the installed agentbus
  n/a   skill      no ~/.claude found
  n/a   agents-md  no ~/.codex found
  warn  hooks      ~/.claude/settings.json has no agentbus hooks. Run: agentbus setup claude
```

`bus` and `copy` must say `ok`. `skill`, `agents-md` and `hooks` may say `warn` or `n/a` in a lane
setup; that is fine.

Inside the lane, `agentbus join` is the test that the grant works. Then run each probe below. Each
must fail:

| Probe | What it shows |
|---|---|
| `lane sh -c "echo x > '$B/bin/agentbus'"` | the bus copy is read only |
| `lane sh -c "echo x > '$B/VERSION'"` | nothing in the folder is writable but the three bus files |
| `lane sh -c "echo x > '$B/bus.db-journal'"` | no journal can be planted |
| `lane mkdir "$B/backups"`, `lane mkdir "$B/bus.db-shm"` | no new dirs |
| `mkdir "$LT/d"; lane mv "$LT/d" "$B/bus.db-shm"` | no dirs moved in |
| `lane mv "$B" "$LT/ab"`, `lane mv "$B/bin" "$LT/bin"` | the folder and `bin/` stay put |
| `lane ln -s /etc/hosts "$B/x"`, `lane ln -s /etc/hosts "$LT/x"` | no symlinks, anywhere |
| `lane ln "$B/bus.db" "$B/bus.db-shm"` | no hard links in the folder |
| `lane mkfifo "$B/f"`, `lane mkfifo "$LT/f"` | no FIFOs, anywhere |
| `lane python3 -c 'import socket; socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM).connect("/var/run/syslog")'` | no unix sockets outside the grant |
| `lane sh -c "printf '' > /dev/ttys001"` (another of your terminals: `ls /dev/ttys*`) | no writes to other terminals |
| `lane sh -c "echo x > ~/src/app/elsewhere"` | nothing outside the grant |

With no other terminal open (on a headless machine, say), open a pty to probe instead:
`python3 -c 'import os, time; m, s = os.openpty(); print(os.ttyname(s), flush=True); time.sleep(60)' &`
prints a name like `/dev/ttys034`; probe that, then `kill %1`.

From a terminal, also check that a lane cannot type into it:
`lane python3 -c 'import fcntl, termios; fcntl.ioctl(open("/dev/tty"), termios.TIOCSTI, b"#")'`
must fail with `Operation not permitted`. If it works, a `#` appears at your prompt; delete it and
check the profile.

`lane sh -c "echo x > '$LT/scratch'"` must work, and so must DNS and HTTPS
(`lane curl -sS -o /dev/null https://example.com`). Checked on macOS 27.0.1, in bash and in zsh:
every probe above was denied, and the scratch write, DNS and HTTPS worked. `tests/test_sandbox.sh`
runs the same checks, the `TIOCSTI` one in a pty of its own.

If the lane runs `/usr/bin/python3` (the Xcode shim), it can print `python3: error: couldn't
create cache file '.../xcrun_db-...' (errno=Operation not permitted)`. That is `xcrun` failing to
refresh its cache in your per-user temp dir, which the lane cannot write. The command still runs
and exits 0. Setting `TMPDIR` does not stop it. To avoid it, put a `python3` that is not
`/usr/bin/python3` first on the lane's `PATH`.

## After the lane exits: the sweep

Before you or the brain run anything else on the bus, list every link, special file and stray
directory in the bus folder:

```bash
find "$B" \( -type l -o -type p -o -type s -o -type b -o -type c -o \( -type f -links +1 \) \
  -o \( -type d -name 'bus.db*' \) \) -print
```

Any output fails the run: remove what it lists and find out how the lane made it. A hard-linked
pair shows up under both its names. Checked: under the recipe's grant every plant this page names
was denied, and the sweep printed nothing. The sweep is required with the folder grant below, and
for any harness whose sandbox does not meet the link rules.

## Per harness

Each was checked on the version named. Re-check when you upgrade, since harness sandboxes change
between releases.

### Claude Code

Claude Code's own sandbox does not cover its hooks. From the
[official docs](https://code.claude.com/docs/en/sandboxing): "The sandbox covers shell commands
only. Claude's file tools, MCP servers, and hooks run outside it." The agentbus hooks write to the
bus (`join` when a session starts, `leave` when it ends), so they run with your full access.

- Run the whole `claude` process under the recipe's profile, with the worktree added to the grant.
  Its hooks are its child processes, so the profile covers them. Not measured here: a full Claude
  Code session under `sandbox-exec`, and whether Claude Code's own sandbox can start inside one
  (Codex's cannot, below).
- Give the lane its own config dir: set `CLAUDE_CONFIG_DIR` to a copy of what the lane needs under
  `$LT`, never your `~/.claude`. A lane that can write your config can add hooks that your own
  sessions then run unsandboxed. The [official docs](https://code.claude.com/docs/en/sandboxing)
  give the same reason for keeping those files write-denied: "A command that could edit those
  files could grant itself permissions, or add a hook or MCP server that Claude Code runs outside
  the sandbox."
- Set `AGENTBUS_DB` and `AGENTBUS_AGENT` in the environment `claude` starts with, as in step 4. The
  hooks use `AGENTBUS_DB` when it is set there, and otherwise find the bus from the session's
  working directory. A variable set later, inside the agent's shell, never reaches the hooks.
- The hooks keep per-session state in `$TMPDIR/agentbus-hooks-<uid>`. With `TMPDIR` set to the
  lane's tmp dir, that state is the lane's own.

[Claude Code](how-to/claude-code.md) covers what the hooks do.

### Codex CLI (checked on 0.166.0)

Codex's permission profiles do not meet the link rules. Measured with `codex sandbox -P bus-ro`
(no model call) and this profile:

```bash
-c "permissions.bus-ro.filesystem={\":root\"=\"read\",\"$B\"=\"write\",\"$B/bin\"=\"read\",\"$B/backups\"=\"read\"}" \
-c 'permissions.bus-ro.network={enabled=false}' \
-c 'default_permissions="bus-ro"'
```

`join` and `post` worked. Writing `bin/agentbus`, writing in `backups/`, renaming `bin/`, writing
outside the grant, and hard-linking an outside file into the folder were denied. A symlink, a hard
link between two files in the folder, and a FIFO in the folder were all **created**. A Codex lane
under its own profile is outside the guarantee below.

From the [official docs](https://learn.chatgpt.com/docs/permissions): permission profiles are
"Beta. Permission profiles are under active development and may change." And if `sandbox_mode`
appears in a loaded config file, or you pass `--sandbox`, "Codex uses those older sandbox settings
instead of `default_permissions`."

**Recommended:** run Codex lanes under the recipe's `sandbox-exec` profile instead. Codex's own
sandbox cannot start inside it: `codex sandbox` under the profile fails with `sandbox-exec:
sandbox_apply: Operation not permitted`. So Codex's sandbox has to be off, which its help reserves
for this case: `--dangerously-bypass-approvals-and-sandbox` is "Intended solely for running in
environments that are externally sandboxed". Add the worktree to the grant, and set `CODEX_HOME` to
a copy of what the lane needs under `$LT`, never your `~/.codex`, for the same reason as Claude
Code's config above. Not measured here: a full `codex exec` run under the profile.

### Antigravity CLI (`agy`): not re-measured

agy 1.4.12 is current. This page's earlier measurement was on 1.4.8 and is stale. The
[official docs](https://www.antigravity.google/docs/sandbox?tab=cli) now describe a different
model: on macOS, Seatbelt profiles through `sandbox-exec`; "Commands can write to your workspace,
temporary directories, and common build caches"; paths not mounted are hidden; the sandbox is off
unless you enable it (`--sandbox`, or `enableTerminalSandbox` in settings). Checking it needs a
model call, so it was not re-measured. Until it is, run agy under the recipe's profile and treat
its own sandbox as untested. Whether agy's own sandbox can start inside that profile is not
measured.

### GitHub Copilot CLI: not measured

From `copilot help sandbox` (1.0.105):

- "Built-in file edits aren't OS-sandboxed, but still follow the same policy on a best-effort
  basis." Read-only rules hold for shell commands, not for Copilot's own edits.
- "By default access is limited to your working directory, PATH directories, the temp directory,
  and your user profile." The help does not say which part of the user profile, or with what
  access. If it means your whole home folder, that includes the bus, `~/.claude` and `~/.codex`.
  The official docs say application directories in the profile are read-only. Not measured.
- "Enabling seeds a sensible starting policy: ... and a per-command bypass escape hatch is
  available." That is `sandbox.allowBypass`; set it to `false` for a lane.
- The path settings are `sandbox.userPolicy.filesystem.readwritePaths`, `readonlyPaths` and
  `deniedPaths`.

The [official docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/understanding-local-sandboxing)
say the same of file edits: they "run as part of Copilot CLI itself rather than as a sandboxed
child process". Whether a read-only path inside a read-write one holds, and whether links can be
made, has not been measured. Treat a Copilot lane as outside the guarantee, or run it under the
recipe's profile.

### Any other harness

Grant only the three bus files if the harness can name single files, or use the folder grant below
if it can only grant folders. Then run every probe in "Check it" from inside its sandbox. If any
probe succeeds, the harness does not meet the guarantee, and the sweep is the only check left.

### The folder grant (fallback)

For a harness that can only grant folders. It also lets the lane create, rename and delete other
files in `.agentbus/`, a `bus.db-journal` included (the CLI then refuses the bus).

```scheme
(allow file-write* (subpath "$B"))
(deny file-write* (literal "$B"))
(deny file-write* (subpath "$B/bin"))
(deny file-write* (subpath "$B/backups"))
(deny file-write-create (vnode-type SYMLINK))
(deny file-write-create (vnode-type FIFO SOCKET CHARACTER-DEVICE BLOCK-DEVICE))
(deny file-link (subpath "$B"))
```

Keep the recipe's other rules (`/dev`, `$LT`, `TIOCSTI`, unix sockets). `bin/` and `backups/` stay
read only ("Threat notes" says why `backups/`). The literal rule stops the lane moving the folder
itself. Run the sweep after every lane.

## What agentbus guarantees, and what it does not

A sandboxed lane is treated as hostile. The brain runs the CLI unsandboxed, in the same folder.

- **Guaranteed, given the recipe's grant or the folder grant:** the unsandboxed CLI never writes
  to, truncates or changes the mode of a file outside `.agentbus/`, and never runs code a lane
  wrote.
- **That depends on the link rules:** no links, symbolic or hard, in the bus folder, no special
  files (FIFOs, sockets, device nodes), and `bin/` and `backups/` read only. SQLite opens its files
  by name and Python cannot tell it not to follow links, so a link planted at the wrong moment can
  still redirect a write (see "Residual window").
- **The CLI's own checks are a second layer,** described below. They catch every link case the
  tests exercise except that window, and they keep working when a sandbox is weaker than it should
  be. They are not the guarantee.
- **Not guaranteed: who wrote what.** A lane with the grant can post anything and edit or delete
  rows. See "Threat notes".
- **Availability is out of scope.** A lane that can write `bus.db` can always deny service: it can
  hold the lock with its own `sqlite3` connection, or delete the bus. What stays in scope: no write
  outside `.agentbus/`, no forged output, no lost or duplicated data for honest agents (beyond
  `inbox`'s documented at-least-once), and the CLI bounding its *own* hold of the lock, whatever
  rows a lane planted. That bound is 8 s while the process can run. A process blocked in the kernel
  on a stalled disk (in `fsync`) cannot be ended until the disk answers, so its hold lasts as long
  as the stall.

## Discovery

The brain and every dispatcher set `AGENTBUS_DB` for their own commands too, and never rely on
discovery from inside a tree a lane can write. A lane can plant a `.git` file that makes a folder
in its worktree look like a linked worktree of another repository:

```
gitdir: /path/to/other/.git/worktrees/x
```

A command run from inside that folder then finds the other repository's bus. Checked: this
redirected discovery, with or without a back-link `gitdir` file in `worktrees/x`. A nested
repository with `core.worktree` set elsewhere, and a `.git` file naming `/path/to/other/.git`, did
not. With `AGENTBUS_DB` set, the plant changed nothing.

## How the CLI defends itself

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
  ends the command with an `agentbus:` error. That bound holds while the process can run. A process
  blocked in the kernel, in `fsync` on a disk that has stalled, is not ended until the disk answers
  (holds of 31 s to 200 s were seen with a disk limited to 40 MB/s, issue #19), so other agents'
  15 s of retries can run out first. If the stop comes while a write is being saved, whether it was
  saved is not known, since the commit record may already be on disk. The error then says so
  (`outcome_unknown: true` under `--json`), counts the write as possibly saved (`committed: true`,
  `retryable: false`), and tells the caller to check the bus or to repeat only with the write's
  `--request-id`;
- re-checks inside every write transaction that the path still names the file it holds.

`init` and `upgrade` refuse the same links. They write `bin/agentbus` and `VERSION` only through
fresh temp files (`O_EXCL`, then rename). The one file written in place, when the bus belongs to a
checkout root, is `.git/info/exclude`: `init`, and any command that finds the rule in neither it
nor `.gitignore`, appends `.agentbus/` to it through an `O_NOFOLLOW|O_NONBLOCK` fd that must still
be a single-link regular file you own, after refusing a symlinked `info/` or a symlinked or
hard-linked `exclude`. A lane cannot write that file (it is outside the grant). When an ordinary
command cannot add the rule (the lane's own command, or a refused `exclude`), it prints a notice
and carries on. `init` installs the copy first, then exits 3 naming the refused file
(`bus_unavailable`, with `committed: true` under `--json`).
`tests/test_race.sh` swaps `bus.db` and `-wal` for symlinks and hard links to a victim database,
both at exact points and in a loop against 300 posts, and checks the victim stays byte-identical.

**Errors.** A refusal to open or use the bus exits 3. Under `--json`, branch on `error.code`:
`bus_unavailable` (a safety check failed, SQLite or the system refused, or the command ran out of
time; with `outcome_unknown: true`, a write may or may not have been saved), `schema_refused` (the
bus carries tables agentbus did not make: stop and tell the user), and `busy` (another process held
the bus for 15 s). Of these three only `busy` is retryable; read `error.retryable` rather than
keeping a list. The [reference](reference.md) lists every code.

**Residual window.** Python's `sqlite3` cannot pass `SQLITE_OPEN_NOFOLLOW` (no `flags` argument on
3.9 to 3.15, and no URI parameter for it), so SQLite opens `bus.db`, `-wal` and a `-journal` by
name, following links. Between the CLI's last check and SQLite's open:

- SQLite may *read* a swapped-in file before the audit catches it.
- A hard link planted at `bus.db-journal` before the CLI connects can be written to before any
  check of the CLI's can see it. This is the case that makes the sandbox rules required, not
  optional. Under the recipe's grant a lane cannot create `bus.db-journal` at all.
- SQLite creates `-wal` with `O_CREAT`; a dangling symlink planted at exactly that moment could
  make an SQLite build that follows it create an empty file at the link target. SQLite 3.54
  (macOS 27) refused such a link in our tests; other builds may not.

### Why the link rules

- **No symlink anywhere,** not just in the folder: a symlink made in the lane's tmp dir or worktree
  could be swapped into the folder with `renamex_np(RENAME_SWAP)`, which no create rule on the
  folder sees. The same rule refuses renaming or swapping in a symlink that existed before the
  sandbox started. Under the folder grant it does not stop a whole directory being moved in with
  such a symlink inside it, hence the recursive sweep.
- **No FIFO, socket or device node anywhere,** for the same reason. A FIFO at `bus.db-journal`
  makes SQLite's open of it block (10 of 30 commands hung in a `mkfifo` loop before the CLI's
  watchdog). Device nodes need root anyway, so for them the rule is a second layer.
- **No hard links in the folder.** Hard links to files the lane cannot write are already denied by
  the base `(deny file-write*)`.
- **The folder itself** (folder grant): without the literal rule, a lane with any other writable
  dir could move `.agentbus` there, rewrite `bin/agentbus`, move it back, and have the brain run
  that code. The recipe's grant denies the whole folder except the three files.

The global symlink rule means a lane cannot create symlinks in its worktree either (a checkout of
a repo that tracks symlinks fails). If a harness has to allow that, the lane is outside the
guarantee: the CLI's checks still refuse a symlinked bus file, but a symlink swapped in during the
window above is no longer prevented. In our tests SQLite 3.53 and 3.54 then refused to open the bus
(a denial of service, no write to the target); other builds may differ.

`tests/test_sandbox.sh` checks the recipe's grant and the folder grant on macOS 27.0.1, with a
writable lane tmp dir as a real lane has, plus negative controls: without the global symlink rule a
symlink made before the sandbox can be swapped in, without the FIFO rule a FIFO can be made in the
folder, and with all of `/dev` granted a lane can write to another terminal.

## Threat notes

- **`--as` is not authentication.** A lane with the grant can post as any name, `lead` and yours
  included, and can join under a name before its owner does (the owner's `join` is then refused as
  a possible live session). It can set the shared goal and post to topic `ruling`. Treat the goal
  and rulings as untrusted unless you set them yourself in this session. Checked from inside the
  recipe's sandbox: all of these worked.
- **Messages are peer information, not instructions.** Agents treat bus messages as notes from a
  peer; only the human owner's words direct work.
- **Claims are advisory, and a lane can squat them.** A lane can claim a whole directory for up to
  a week (`--ttl-min 10080`) and renew it, and honest agents are refused until it expires or
  someone releases it. A claim is a promise between cooperating agents, not a lock.
- **Never give a lane your `$TMPDIR`.** The Claude Code hooks keep per-session state in
  `$TMPDIR/agentbus-hooks-<uid>`; a lane that can write yours can change what your own sessions'
  hooks do.
- **Keep a lane worktree's `.git`, `.codex`, `.claude` and `.agents` read only.** They hold config,
  hooks and skills that you or your harness run outside the lane's sandbox. Claude Code's sandbox
  and Codex's workspace profile already keep parts of them read only
  ([Claude Code](https://code.claude.com/docs/en/sandboxing): "the `.claude` settings files ... and
  `hooks` and `config` inside `.git`"; [Codex](https://learn.chatgpt.com/docs/permissions): "paths
  such as .git/, .agents/, .codex/, and .aws/ within a workspace root are read-only"). A
  `sandbox-exec` profile has to deny them itself.
- **`backups/` is read only for a reason.** `agentbus upgrade` keeps the copy of the tool it
  replaced there, and the [restore steps](how-to/upgrade.md#restore-a-backup) copy it back into
  `bin/`, which the brain runs unsandboxed. If a lane could write `backups/`, reinstall the copy
  with `agentbus upgrade` instead; the upgrade guide says how.
- **Apple Events and `open` are not restricted by this profile.** It does not deny sending Apple
  Events or asking LaunchServices to open a file, URL or app, and what those start runs outside
  the sandbox. Not measured here, since a probe would open apps on the machine.
- **No secrets on the bus.** Every agent with the grant can read every message. Say where a secret
  lives, never its value, and never post environment dumps.
- **The bus is shared state.** Anything with write access can edit or delete rows directly with
  SQLite. Git, the issue tracker and the code stay the source of truth; the bus only coordinates.
- **Rows, yes; schema, no.** A lane can tamper with any row, but agentbus refuses a bus that
  carries a schema object it did not create (a trigger, a view, or an extra table or index) or a
  table whose shape is not agentbus's own (columns, types, NOT NULL, defaults, every index including
  SQLite's automatic ones, foreign keys and their actions, and any CHECK, COLLATE, ON CONFLICT,
  generated column, WITHOUT ROWID or STRICT its definition lacks), before running any statement
  that could fire one or write. All of a command's SQL together gets 6 seconds and the whole hold
  8 (see above); a statement still running when the SQL budget is spent is stopped (its write
  rolled back). Formatting the output happens after the bus is closed. Listings stop at their
  default limit (500 rows at most) unless `--limit` says otherwise. `leave` and `release --all`
  take no `--limit` (passing one is a usage error, exit 2); what they print and log stops at 500
  claims, then a `... N more` line.
  `claim` takes at most 1024 characters and finds overlapping claims through the resource index,
  never by reading every claim; text a lane planted is cut to 1024 characters wherever agentbus
  writes it into a log row or an error, and a planted resource longer than that is never read by
  the open-time normalisation.
