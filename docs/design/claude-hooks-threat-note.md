# Claude Code hooks: threat note

What the hooks protect, from what, and what they leave open. The hooks run on every session, so they are held to
"a repository cannot make them do harm".

| Threat | Control | Test |
| --- | --- | --- |
| A cloned repo ships `.agentbus/bin/agentbus` and the hook runs it | Hooks run the plugin's own file or the tool `setup` recorded; nothing is searched for | `test_hooks_claude.sh` TEST 1 |
| The hook tells the model to run that repo copy | Hook text names the installed command `agentbus`; a copy only when the hook itself runs from it | TEST 25 |
| A cloned repo commits a whole bus (goal, messages, a tool) | A `.agentbus` that git tracks is refused unless the local exclude rule or an index without it shows it is the user's; a hook never creates a bus | TEST 23, TEST 24 |
| A peer writes instructions into a goal, message, purpose, name or path | Hook output is fixed text, counts and kind names only; nothing peer-written is printed | TEST 7, TEST 99 |
| A hook blocks or slows a session | Always exit 0 (`\|\| true`, a catch-all, `os._exit(0)`); no decisions; 0.3 s busy wait, 1 s hold, 3 s whole-hook limit (1.2 s for SessionEnd) | TEST 2, TEST 3 |
| A hook takes over or releases another live session's name | A foreign name is never taken over or left; unsafe `AGENTBUS_AGENT` values are ignored | TEST 15, TEST 19 |
| `agentbus doctor` runs a command from a hostile `settings.json` | `ClaudeHooksPiece.check` reads text and looks at the file; it starts nothing | `test_setup.sh` (check section) |
| Writing the user's settings | Refuses invalid or symlinked files, keeps other keys, backs up, tagged entries only | `test_setup.sh` |

## Left open

- The plugin form of the hook command looks up `python3` on `PATH`. A `PATH` that begins with a folder another party can write could run a planted `python3`. The `setup` form records an absolute interpreter and script instead. Claude Code starts plugin hooks through a shell command string, and a plugin cannot know the interpreter's path in advance, so the lookup stays for the plugin.
- An `AGENTBUS_DB` in the environment is a dispatcher's choice and is not second-guessed (no tracked-folder check).
- Any process running as the user can write the bus; names are not credentials (SECURITY.md).
