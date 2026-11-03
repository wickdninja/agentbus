# Codex hooks: threat note

The Codex hooks share their handlers, identity rules and safety rules with the Claude Code hooks ([threat note](claude-hooks-threat-note.md)); only the name prefix, the events and the way an edit names its files differ. This note covers what is Codex's own.

| Threat | Control | Test |
| --- | --- | --- |
| A cloned repo ships `.agentbus/bin/agentbus` and a Codex hook runs it | Same code as Claude Code: the hook runs the tool `setup` recorded; nothing is searched for | `test_hooks_codex.sh` TEST 1 |
| A patch's own text names a file to claim against (`+*** Add File: ...`) | Only lines that start with a marker count; a patched line starts with `+`, `-` or a space | TEST 13 |
| A peer writes instructions into a goal, message, purpose, name, path or patch | Hook output is fixed text, counts and kind names only | TEST 9, TEST 99 |
| A hook blocks, loops or slows Codex | Exit 0 always; Stop and PreToolUse print only `systemMessage` or `additionalContext`, never `decision`, `continue`, `permissionDecision` or exit 2; 5 s timeout on every entry | TEST 2, TEST 12, TEST 14, `test_setup.sh` (codex hooks) |
| A Codex session is given a Claude Code session's process id, environment file or notice | Name prefix, process-name memory, environment file and duplicate notice are per dialect | TEST 10, TEST 21 |
| A payload with no session id gets an invented name | It joins nobody and prints nothing | TEST 4 |
| `setup codex` trusts hooks for the user | It never writes Codex's trust ledger; it prints the `/hooks` step | `test_setup.sh` (trust line) |
| A project's `hooks.json` runs a command when it is checked | `check` reads text and looks at the file the hook names; it never starts it. Every tagged entry must be exactly the line setup writes around one quoted absolute path (or a Python interpreter and one), to a regular file named `agentbus*` that is agentbus by its first 4 KB (the pip, uv or pipx entry script, the plugin launcher, or agentbus's version marker), with no component of the path as written inside the project or a `.agentbus` folder (a repo link to a shell is still the repo's), else it is a problem (`curl \| sh`, a chained command, a relative path, `/bin/sh` as interpreter); another install of agentbus is only stale | `test_setup.sh` (check), `test_doctor.sh` TEST 17 |
| A project's `.codex` or `.claude` is a link, so setup writes where a clone points | With `--scope project`, any link between the working directory and every folder setup writes or removes in (`.codex`, `.claude`, `.claude/skills`), or a folder that resolves outside it, is refused by name, for install, dry run and uninstall; the chain is checked again right before each write and removal, and once more after a write (a swap in that window is reported with the path; a write that already landed cannot be undone) | `test_setup.sh` (linked config folder) |
| The user's login shell prints text and breaks the hook's JSON, or hangs | `setup codex` (never `check`) starts the user's own login shell once (`$SHELL -lc true`, home folder, no input, `AGENTBUS_SHELL_PROBE=1`, its own session), reports how many bytes it printed, never what, and kills the whole process group on a timeout or after a normal exit; a timeout is reported as unknown | `test_setup.sh` (login shell) |
| A name inherited through `AGENTBUS_AGENT` from the other harness | A name that matches the other dialect's derived pattern is ignored, both ways | `test_hooks_codex.sh` TEST 22 |
| Setup grows `AGENTS.md` past what Codex reads, or the block is ignored | Refused past 32 KiB; a non-empty `AGENTS.override.md` is reported | `test_setup.sh` (codex hooks) |
| User and project hooks both installed, so every event runs twice | `check` reports it | `test_setup.sh` (check) |

## Left open

- **The window between the last folder check and the write.** Setup checks the folders from the working directory down to every file it writes or removes when it plans, again right before each write and removal, and once more after a write. A folder swapped for a link in the few microseconds between the last check and the rename can still send that one write (or removal) through the link; the after-write check can only report it. Accepted for now. A follow-up will walk the chain with `O_NOFOLLOW` and write through the parent's directory descriptor (`dir_fd`), which closes it.
- A hook program is trusted by owner and mode like `claude_trusted_binary`: the program, its interpreter and their folders must belong to the user or root and not be writable by group or others. Ownership by another user is checked but has no test (it needs a second user).
- Outside the home folder, the ancestors of the working directory count as the project while they are the user's (owned by the user or writable by others, and not holding the home folder), so an unpacked tarball in `/tmp` is not an install; a root-owned folder nobody else can write (`/usr/local`) ends the walk.

- Edits made through the shell (`sed -i`, a redirect) carry no file list; the claim note cannot see them.
- Subagents of one Codex session share the parent's session id (Codex documentation, not run here), so they share one name.
- `setup codex` runs the program named by `$SHELL` (or `/bin/sh`), once. The environment is the caller's, not a project's; a caller whose environment is hostile can run anything anyway.
- Codex trusts a hook by its exact definition and position: a changed entry asks for approval again. That is Codex's behaviour, not something setup can or should work around.
