# Codex hook contract (captured)

Task 4.1 of workstream 04 (issue #6). This is the contract the Codex dialect, the `hooks` printer and `setup codex` are built from. Every item is marked:

- **VERIFIED-BY-RUN**: observed in a real `codex exec` on the version below; the captured JSON is in `tests/fixtures/codex_hooks/`.
- **SOURCE**: read from the open-source Codex tree (`main`, not pinned to the tested version); treat as likely, re-check on upgrade.
- **DOCS-ONLY**: stated by the official docs, not run. The URL is given.
- **UNKNOWN**: neither.

## Version and method

- Codex tested: `codex-cli 0.166.0` (macOS arm64), model `gpt-6.1-sol`, 2026-11-01. Only this version was run. The supported range is therefore "0.166.0 and later, re-verified per release"; no older version was tested.
- Two real `codex exec` runs in a scratch git repo, with a scratch `CODEX_HOME` (own `config.toml`, `AGENTS.md`, `hooks.json`; auth copied in and deleted afterwards). Hook commands were a script that wrote their stdin payload and the NAMES (never values) of their environment variables to files.
  - Run 1: hooks present, not trusted. Run 2: hooks trusted (see Trust). Both used the prompt "use apply_patch to create hello.txt containing hi, then reply with the sentinel word from your AGENTS.md".
- Only `codex exec` was run. The interactive TUI (`/hooks`, the startup warning) was not.
- Docs: https://developers.openai.com/codex/hooks.md , https://developers.openai.com/codex/guides/agents-md.md , https://developers.openai.com/codex/config-reference.md . Source: `codex-rs/hooks/src/engine/command_runner.rs`, `codex-rs/core/config.schema.json` (github.com/openai/codex). Local: `codex app-server generate-json-schema` (v2 `HooksList*`).

## 1. File locations and format

| Item | Result | Status |
|---|---|---|
| User hooks file | `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`). Loaded and fired in run 2 | VERIFIED-BY-RUN for `$CODEX_HOME`; default path DOCS-ONLY |
| Project hooks file | `<repo>/.codex/hooks.json`. Fired in run 2 | VERIFIED-BY-RUN |
| Inline alternative | `[hooks]` tables in `config.toml` of either layer; both forms in one layer are merged with a startup warning | DOCS-ONLY |
| Both user and project files | Both run, every event, twice. Payloads byte-identical | VERIFIED-BY-RUN |
| Project hooks need a trusted project | `projects.<path>.trust_level = "trusted"` or the project layer is skipped | DOCS-ONLY (config-reference) |
| Top-level shape | `{"hooks": {"<Event>": [{"matcher"?: str, "hooks": [{"type":"command","command": str, "timeout"?: sec, "statusMessage"?: str, "async"?: bool}]}]}}` | VERIFIED-BY-RUN (minimal form, `hooks_config_used.json`); optional fields DOCS-ONLY |
| Event names | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`, `Stop`, `Interrupt`, `SessionEnd` | `SessionStart UserPromptSubmit PreToolUse PostToolUse Stop SessionEnd` VERIFIED-BY-RUN; rest DOCS-ONLY |
| Feature flag | `[features] hooks = true` (default on in 0.166.0: `codex features list` shows `hooks stable true`; `codex_hooks` is a deprecated alias) | VERIFIED-BY-RUN (features list), DOCS-ONLY (alias) |
| Hook process | Unix: `$SHELL -lc '<command>'` (falls back to `/bin/sh`), env rebuilt from the session environment minus restricted names, stdin piped, cwd is the session cwd | SOURCE (`command_runner.rs` `build_command`); cwd VERIFIED-BY-RUN |
| Timeout | default 600 s; `timeout` in seconds per handler | DOCS-ONLY |
| Concurrency | matching hooks for one event start concurrently | DOCS-ONLY; two-at-once seen in run 2 |

Consequences: `... 2>/dev/null || true # agentbus:managed` is valid (a shell parses it). The shell is a login shell, so the user's profile runs before the hook (latency, see Plan implications). Whatever the profile prints on stdout comes before the hook's JSON; the generated command cannot prevent that, so `setup`'s check starts the login shell once with a command that does nothing and reports how many bytes it printed (`codex_login_shell`), and `scripts/e2e_codex.sh` asserts a silent hook prints nothing through the login shell.

## 2. Payloads (stdin, one JSON object)

All VERIFIED-BY-RUN (fixtures in `tests/fixtures/codex_hooks/`; paths rewritten to `/work/...` and `/home/user/.codex/...`, ids are the real ones from the run).

Common to every event: `session_id`, `transcript_path`, `cwd`, `hook_event_name`. All except `SessionEnd` also carry `model` and `permission_mode` (`bypassPermissions` here because `codex exec` ran with approval `never`).

| Event | Extra fields | Fixture |
|---|---|---|
| `SessionStart` | `source` (`startup` seen; docs list `resume`, `clear`, `compact`, `fork`) | `session_start.json` |
| `UserPromptSubmit` | `turn_id`, `prompt` (the full user prompt text) | `user_prompt_submit.json` |
| `PreToolUse` | `turn_id`, `tool_name`, `tool_input`, `tool_use_id` | `pre_tool_use_apply_patch.json` |
| `PostToolUse` | as PreToolUse plus `tool_response` (string for apply_patch) | `post_tool_use_apply_patch.json` |
| `Stop` | `turn_id`, `stop_hook_active` (bool), `last_assistant_message` | `stop.json` |
| `SessionEnd` | `reason` (`other`); no `model`, no `permission_mode` | `session_end.json` |

Not run: `Bash` tool payload (docs: `tool_input.command` is the shell command string), MCP tool payloads, `PermissionRequest`, compaction and subagent events (DOCS-ONLY, hooks.md).

`UserPromptSubmit.prompt`, `Stop.last_assistant_message` and `tool_input` carry user or model text. Handlers must not echo them (hook safety rule 4) and tests should use canaries in them.

## 3. Output shapes (stdout of the hook)

Not run: both runs used hooks that print nothing. Everything here is DOCS-ONLY (hooks.md, "Common output fields" and per-event sections).

| Event | Accepted output |
|---|---|
| `SessionStart` | plain text on stdout becomes developer context; or `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}`; common fields `systemMessage` (UI warning), `continue`, `stopReason`, `suppressOutput` (parsed, not implemented) |
| `UserPromptSubmit` | plain text becomes developer context; or `hookSpecificOutput.additionalContext`; `{"decision":"block","reason":...}` blocks the prompt |
| `PreToolUse` | plain text IGNORED. JSON only: `systemMessage`, `hookSpecificOutput.additionalContext`, `permissionDecision` `deny`/`allow`+`updatedInput`. `continue`, `stopReason`, `suppressOutput`, `ask` mark the hook run failed and the tool call proceeds |
| `Stop` | JSON REQUIRED on exit 0 (plain text is invalid). `{"decision":"block","reason":...}` does not reject the turn: it starts a new continuation turn using `reason` as the prompt. `systemMessage` is the user-visible warning |
| `PostToolUse` | `systemMessage`, `continue:false`, `decision:"block"` (replaces the tool result), `hookSpecificOutput.additionalContext` |
| Any, exit 2 | stderr text is the block reason for PreToolUse, UserPromptSubmit, PostToolUse, Stop |
| Any, exit 0, no output | success, Codex continues |
| Size | model-visible hook output is capped at about 2,500 tokens per handler by default (`additionalContextLimit`); the rest spills to a file under the temp dir |

Safety for agentbus: a hook must never print `decision`, `continue:false`, `permissionDecision` or exit 2 (never blocks). Stop with `decision:"block"` would loop the agent; the Stop dialect emits only `{"systemMessage": "..."}` or nothing.

These shapes must be confirmed by one run before 4.3 merges (the e2e gate in the runbook does this).

## 4. Tool names for edits

| Item | Result | Status |
|---|---|---|
| File edit tool | `tool_name` is `apply_patch` (canonical). Matchers may use `apply_patch`, `Edit` or `Write`; the payload still says `apply_patch` | `apply_patch` VERIFIED-BY-RUN; matcher aliases DOCS-ONLY |
| Input shape | `tool_input` is `{"command": "<patch text>"}`, not a file path field. Patch text: `*** Begin Patch`, then `*** Add File: <path>` (also `*** Update File:`, `*** Delete File:` per the apply_patch format), then `*** End Patch` | Add File VERIFIED-BY-RUN; Update/Delete/Move DOCS-ONLY (apply_patch format) |
| Path form | absolute in this run (the model chose it); relative paths resolve against `cwd`. A claim check must normalize both | absolute VERIFIED-BY-RUN; relative UNKNOWN |
| Shell edits | `sed -i`, redirects, formatters run as `Bash` and carry no file list; a PreToolUse claim note cannot see them | DOCS-ONLY ("a guardrail, not a complete enforcement boundary") |
| Pre/Post ids | `tool_use_id` identical on Pre and Post (`exec-<uuid>`) | VERIFIED-BY-RUN |

## 5. Session id

- `session_id` is present in every event, a UUID-shaped string (`01a19a84-ce11-7e82-aeae-001ab82934fe`), identical across all six events of the run, and equal to the `session id:` line `codex exec` printed. VERIFIED-BY-RUN.
- Subagent hooks carry the parent's session id (docs): two subagents of one session share an identity unless `agent_id` is also used. DOCS-ONLY.
- No Codex session, thread or turn variable is in the hook's environment. The only Codex names seen: `CODEX_HOME` (set by the test), `CODEX_MANAGED_BY_NPM`, `CODEX_MANAGED_PACKAGE_ROOT`. Identity can come only from the payload (or `AGENTBUS_AGENT` inherited from the parent environment; the hook sees the whole parent environment). VERIFIED-BY-RUN (names only; the full list is not committed because it names unrelated variables).
- `codex resume` and `fork` behaviour of `session_id`: UNKNOWN (docs: `source` becomes `resume` / `fork`).

## 6. Trust flow

| Item | Result | Status |
|---|---|---|
| Untrusted hooks | skipped silently in `codex exec`: no hook ran, no warning on stderr or stdout | VERIFIED-BY-RUN (run 1) |
| Interactive path | `/hooks` in the TUI lists hooks, approves, disables; a startup warning says hooks need review | DOCS-ONLY (hooks.md); not run |
| What is trusted | the exact definition, by hash; a changed hook is "modified" and skipped until re-trusted; a new hook is "untrusted" | DOCS-ONLY; states `untrusted`/`trusted` seen, `modified`/`managed` in schema |
| Where it is stored | `config.toml` `[hooks.state."<key>"]` with `trusted_hash = "<hash>"` (also `enabled`) | schema DOCS-ONLY; writing it flips status to `trusted` and hooks fire, VERIFIED-BY-RUN |
| Key format | `<abs path of hooks.json>:<event_snake_case>:<group index>:<handler index>`, e.g. `/home/user/.codex/hooks.json:session_start:0:0` | VERIFIED-BY-RUN (`trust_state_*.json`). Moving the file or changing entry order changes the key |
| Hash | `currentHash` = `sha256:<hex>`; algorithm not documented. Read it from the app-server (below), never recompute | VERIFIED-BY-RUN (read), algorithm UNKNOWN |
| Reading trust from outside Codex | `codex app-server --stdio`, JSON-RPC `initialize` then `hooks/list` with `{"cwds":[repo]}` returns each hook with `key`, `trustStatus` (`managed`/`untrusted`/`trusted`/`modified`), `currentHash`, `source`, `sourcePath`, `command`. No model call, no network | VERIFIED-BY-RUN. Experimental API (`app-server` is marked experimental) |
| Non-interactive trust | (a) write `[hooks.state."<key>"] trusted_hash = <currentHash>` into `config.toml` (what this capture did, in a scratch `CODEX_HOME` only); (b) `--dangerously-bypass-hook-trust` on `codex` / `codex exec`, per invocation, not persisted | (a) VERIFIED-BY-RUN; that the TUI writes the same key is an inference, UNVERIFIED; (b) VERIFIED in `codex exec --help`, not run (trust bypass, deliberately not used) |
| Project trust | project `.codex/` hooks load only for a trusted project. `config.toml` gained `[projects."<repo>"] trust_level = "trusted"` during run 1 without my writing it (the app-server probe alone does not write it); `codex exec` appears to record it. Not isolated further | VERIFIED-BY-RUN (observation), cause UNKNOWN |

Decision input for 4.5: a non-interactive trust exists, but it relies on an undocumented hash read through an experimental API and writes Codex's own trust ledger. Recommended: ship the printed `/hooks` line only; do not ship `--trust` in 0.2.0 unless the owner asks. `doctor` can report the real trust state by calling the app-server `hooks/list` and degrade to the `/hooks` line when `codex` or the call is missing.

## 7. AGENTS.md

| Item | Result | Status |
|---|---|---|
| Global path | `$CODEX_HOME/AGENTS.md` (default `~/.codex/AGENTS.md`). A sentinel word in the scratch `CODEX_HOME/AGENTS.md` was returned by the model | VERIFIED-BY-RUN for `$CODEX_HOME`; default DOCS-ONLY (it exists on this machine) |
| Override file | `$CODEX_HOME/AGENTS.override.md`, if it exists and is non-empty, REPLACES the global `AGENTS.md` (only the first non-empty file at the global level is read) | DOCS-ONLY |
| Project files | from the project root (git root) down to cwd, one file per directory: `AGENTS.override.md`, then `AGENTS.md`, then `project_doc_fallback_filenames` | DOCS-ONLY |
| Size cap | `project_doc_max_bytes`, 32 KiB default, over the COMBINED chain; files are dropped once the total reaches it | DOCS-ONLY |
| When read | once when the session starts | DOCS-ONLY |

## 8. Runbook assumptions

| Assumption (04-codex-integration.md) | Verdict | Evidence |
|---|---|---|
| Events SessionStart, UserPromptSubmit, PreToolUse, Stop exist | CONFIRMED | all fired; PostToolUse and SessionEnd also exist |
| `~/.codex/hooks.json` and `<repo>/.codex/hooks.json` | CONFIRMED | both fired (user via `CODEX_HOME`) |
| Hooks need trust before they run | CONFIRMED | run 1 silent skip; run 2 ran after trust |
| Installing a plugin does not trust hooks | CONFIRMED (docs) | hooks.md "Plugin-bundled hooks" |
| Payload has a stable session id | CONFIRMED | `session_id` on all events, constant |
| Edit tool names captured | CONFIRMED | `apply_patch`, patch text in `tool_input.command` |
| `Stop` can give a user-visible reminder | UNKNOWN | docs: `systemMessage` is a UI warning and Stop requires JSON; not run |
| Output shapes | UNKNOWN (DOCS-ONLY) | section 3 |
| Trust "cannot be checked from outside Codex" | REFUTED | app-server `hooks/list` returns `trustStatus` |
| Non-interactive trust: "a config key or a command" | CONFIRMED | `hooks.state` key; bypass flag |
| AGENTS.md global path `~/.codex/AGENTS.md` | CONFIRMED | via `CODEX_HOME`; plus override-file caveat |
| AGENTS.md 32 KiB cap per file | REFUTED (it is a combined cap) | agents-md.md |
| "No SessionEnd" is a choice, not a gap | NOTE | `SessionEnd` exists and fired (`reason: other`); advisory only |

## 9. Plan implications (for 04 and 02)

1. Duplicate hooks: a user-level and a project-level agentbus entry both run on every event. `setup codex` must not write both scopes, and `check` should flag it.
2. Hook command latency: Codex runs `$SHELL -lc`, so a login shell starts per hook. The epic's p95 250 ms hook target must be measured through this path in the e2e, not by calling the script directly. Set a short `timeout` (for example 5) on every entry; the default is 600 s and hooks run synchronously.
3. Claim notes: parse `*** Add/Update/Delete File:` (and `Move to:`) lines out of `tool_input.command`; matcher `Edit|Write|apply_patch` or no matcher. Shell-made edits are invisible.
4. Trust key embeds the index and the file path: a tagged entry is trusted only while its position and definition are unchanged. Reordering or merging into an existing `hooks.json` re-prompts.
5. AGENTS.md: the block is ignored if `~/.codex/AGENTS.override.md` exists and is non-empty; `setup codex` should detect that and say so. The 32 KiB guard is a total across the chain, so the test should assert the block's own size and warn on the file size, not promise the chain fits.
6. Stop and PreToolUse emit only the shapes in section 3, never `decision`, `continue:false`, `permissionDecision` or exit 2.

## 10. Unknowns to close

- One run with hooks that print output, to verify the SessionStart `additionalContext` reaches the model, the UserPromptSubmit plain-text path, and the Stop `systemMessage` display (belongs to the e2e gate, 4.6).
- The `/hooks` TUI flow and whether it writes `hooks.state` exactly as above.
- Relative paths in `apply_patch`, `Update File` and `Move to` payloads, Bash payloads, `resume`/`fork` session ids.
- Versions other than 0.166.0.
