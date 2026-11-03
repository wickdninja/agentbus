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
| A project's `hooks.json` runs a command when it is checked | `check` reads text and looks at the file the hook names; it never starts it, and vouches only when every tagged entry runs this very agentbus | `test_setup.sh` (check) |
| A project's `.codex` or `.claude` is a link, so setup writes where a clone points | With `--scope project`, any link between the working directory and the config folder, or a folder that resolves outside it, is refused by name, for install, dry run and uninstall | `test_setup.sh` (linked config folder) |
| The user's login shell prints text and breaks the hook's JSON, or hangs | `setup codex` (never `check`) starts the user's own login shell once (`$SHELL -lc true`, home folder, no input, `AGENTBUS_SHELL_PROBE=1`, its own session), reports how many bytes it printed, never what, and kills the whole process group on a timeout or after a normal exit; a timeout is reported as unknown | `test_setup.sh` (login shell) |
| A name inherited through `AGENTBUS_AGENT` from the other harness | A name that matches the other dialect's derived pattern is ignored, both ways | `test_hooks_codex.sh` TEST 22 |
| Setup grows `AGENTS.md` past what Codex reads, or the block is ignored | Refused past 32 KiB; a non-empty `AGENTS.override.md` is reported | `test_setup.sh` (codex hooks) |
| User and project hooks both installed, so every event runs twice | `check` reports it | `test_setup.sh` (check) |

## Left open

- Edits made through the shell (`sed -i`, a redirect) carry no file list; the claim note cannot see them.
- Subagents of one Codex session share the parent's session id (Codex documentation, not run here), so they share one name.
- `setup codex` runs the program named by `$SHELL` (or `/bin/sh`), once. The environment is the caller's, not a project's; a caller whose environment is hostile can run anything anyway.
- Codex trusts a hook by its exact definition and position: a changed entry asks for approval again. That is Codex's behaviour, not something setup can or should work around.
