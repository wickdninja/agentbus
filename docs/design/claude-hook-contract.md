# Claude Code hook contract (task 3.1, issue #5)

What the agentbus Claude plugin may rely on. Captured on **Claude Code 2.1.316** (macOS), 2026-11-01.
Every item is marked **VERIFIED-BY-RUN** (a real `claude` run, evidence in `tests/fixtures/claude_hooks/`)
or **DOCS-ONLY** (with the URL). Docs: <https://code.claude.com/docs/en/hooks>,
<https://code.claude.com/docs/en/plugins-reference>, <https://code.claude.com/docs/en/plugin-marketplaces>,
<https://code.claude.com/docs/en/plugins/marketplace-reference>, <https://code.claude.com/docs/en/plugins/cli-reference>.

## Method

A scratch plugin (`.claude-plugin/plugin.json` plus `hooks/hooks.json`) in a `mktemp -d` outside any repo.
Its hooks ran `python3 "${CLAUDE_PLUGIN_ROOT}/hooklog.py" EVENT [2>/dev/null || true]`, which wrote the stdin
payload and environment variable NAMES (never values) to files, and printed or exited as a per-run `spec.json` said.
Runs used `claude -p ... --model haiku --setting-sources project --strict-mcp-config --plugin-dir <scratch>
--output-format stream-json --verbose --include-hook-events` (the stream shows each `hook_response` with stdout,
stderr, `exit_code`, `outcome`). Interactive-only facts (`/clear`, `/exit`) came from a tmux session. Two plugin copies:
`p` ends every command with `2>/dev/null || true` (the planned form), `q` has no suffix (to see raw exit codes).
Install behaviour came from an isolated `CLAUDE_CONFIG_DIR`. Fixtures are scrubbed: paths are `/home/user/...`,
session ids are fixed `aaaaaaaa-0000-4000-8000-00000000000N`.

## 1. Plugin layout and `${CLAUDE_PLUGIN_ROOT}`

- `${CLAUDE_PLUGIN_ROOT}` expands inside a shell-form hook command, quoted as planned
  (`python3 "${CLAUDE_PLUGIN_ROOT}/bin/agentbus" ...`). **VERIFIED-BY-RUN**, both with `--plugin-dir` and from a
  marketplace install (cache path `<config>/plugins/cache/<marketplace>/<plugin>/<version>`); the hook also gets
  `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` and `CLAUDE_PROJECT_DIR` as env vars, and `CLAUDE_PLUGIN_ROOT`
  equalled the script directory. See `hook_env_names.json`.
- Unquoted `${CLAUDE_PLUGIN_ROOT}` in a shell-form command makes `claude plugin validate` warn
  (`Shell command uses ${CLAUDE_PLUGIN_ROOT} without quotes`). **VERIFIED-BY-RUN** (`validate_hooks_warning.json`). Keep the quotes.
- `hooks/hooks.json` wraps events in a top-level `"hooks"` key. **DOCS-ONLY** (plugins-reference, hooks section); the scratch plugin used it and loaded.
- An unknown event name is a validate warning (`unknown hook event; entry ignored at runtime`) and exit 0. **VERIFIED-BY-RUN**.
- Hook processes run with `cwd` = the project dir, payload `cwd` equals process cwd. **VERIFIED-BY-RUN**.
- Hook stdin is a pipe, stdout is a pipe, no controlling terminal. **VERIFIED-BY-RUN** (isatty false) and DOCS-ONLY (hooks, "Hook input and output").
- A `claude` run launched inside another Claude Code session passes `CLAUDECODE`, `CLAUDE_CODE_*` names through to hooks; the env list in `hook_env_names.json` includes those because the capture ran nested.

## 2. Payloads per event

All carry `session_id`, `transcript_path`, `cwd`, `hook_event_name`. Fields below are what each adds.
Fixtures are the exact captured JSON (scrubbed).

| Event | Extra fields captured | Fixture | Status |
|---|---|---|---|
| SessionStart | `source` (`startup`, `resume`, `clear` seen); interactive also `model`, `scratchpad_dir`; `resume` adds `seconds_since_last_response`, `context_tokens`, `prompt_cache_likely_expired`, `estimated_cache_write_usd`. No `model` under `claude -p`. | `session_start_startup_print.json`, `session_start_startup_interactive.json`, `session_start_resume.json`, `session_start_clear.json` | VERIFIED-BY-RUN |
| UserPromptSubmit | `prompt_id`, `permission_mode`, `prompt` | `user_prompt_submit.json` | VERIFIED-BY-RUN |
| PreToolUse | `prompt_id`, `permission_mode`, `effort.level`, `tool_name`, `tool_input`, `tool_use_id`; in a subagent also `agent_id`, `agent_type` | `pre_tool_use_write.json`, `pre_tool_use_edit.json`, `pre_tool_use_notebook_edit.json`, `pre_tool_use_write_subagent.json` | VERIFIED-BY-RUN |
| Stop | `prompt_id`, `permission_mode`, `effort`, `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons` | `stop.json`, `stop_hook_active.json`, `stop_background_subagent.json` | VERIFIED-BY-RUN |
| SessionEnd | `prompt_id`, `reason` (plus `scratchpad_dir` interactive) | `session_end_other.json`, `session_end_clear.json`, `session_end_prompt_input_exit.json` | VERIFIED-BY-RUN |
| SubagentStart / SubagentStop | `agent_id`, `agent_type`; Stop adds `agent_transcript_path`, `last_assistant_message`, `background_tasks` | `subagent_start.json`, `subagent_stop.json` | VERIFIED-BY-RUN |

PreToolUse `tool_input` by tool (key for the handler):

```json
{"tool_name":"Write","tool_input":{"file_path":"/home/user/proj/hello.txt","content":"hi\n"}}
{"tool_name":"Edit","tool_input":{"file_path":"/home/user/proj/sub.txt","old_string":"x","new_string":"y","replace_all":false}}
{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/home/user/proj/nb.ipynb","cell_id":"c1","new_source":"print(2)"}}
```

- **`NotebookEdit` has `notebook_path`, not `file_path`.** The handler must read `file_path` or `notebook_path`. VERIFIED-BY-RUN. (`[plan-gap]` posted.)
- `file_path` is absolute for Write and Edit; captured paths are realpaths (`/private/var/...` on macOS). VERIFIED-BY-RUN. Windows backslashes: DOCS-ONLY (hooks, PreToolUse input).
- `MultiEdit` is not a tool in the current tools reference (<https://code.claude.com/docs/en/tools-reference>). A matcher naming it is harmless. DOCS-ONLY.
- Subagent: `session_id` is the **parent's**; the PreToolUse payload adds `agent_id` and `agent_type`. SubagentStart/Stop exist as events. A subagent fires no SessionStart or SessionEnd. VERIFIED-BY-RUN (`pre_tool_use_write_subagent.json`).
- `UserPromptSubmit` also fires for non-typed prompts: a finished background subagent arrives as a second UserPromptSubmit whose `prompt` is a `<task-notification>...` block (`user_prompt_submit_task_notification.json`). VERIFIED-BY-RUN. Docs add scheduled tasks and cross-session messages. DOCS-ONLY.
- `Stop` fires when the main agent ends its turn even while a background subagent still runs (`background_tasks` has `status: "running"`), then again after it finishes (`stop_background_subagent.json` is the first of the two, run r7). VERIFIED-BY-RUN. A Stop nudge can therefore fire before the work is finished.
- `session_id` is stable across `claude -p --resume <id>` (same id on SessionStart `resume`). VERIFIED-BY-RUN.
- `/clear` gives a NEW `session_id`: SessionEnd `reason:"clear"` carries the old id, SessionStart `source:"clear"` the new one. VERIFIED-BY-RUN (interactive tmux run; fixtures `session_end_clear.json` + `session_start_clear.json`, ids ...002 and ...003).

## 3. Output shapes and context injection

All three shapes below are VERIFIED-BY-RUN: the model quoted the canary string back and the stream `hook_response` shows the stdout. Full evidence in `hook_outputs.json`.

```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"..."}}
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}
{"systemMessage":"..."}
```

- PreToolUse `additionalContext` with no `permissionDecision`: the tool call runs normally (Write succeeded, no prompt change). The context reached the model. VERIFIED-BY-RUN.
- Stop `{"systemMessage": "..."}` surfaces as a stream message `{"type":"system","subtype":"informational","content":"Stop says: <text>","level":"notice"}`, the turn ends normally, no continuation. VERIFIED-BY-RUN. In interactive mode it is a user-visible notice. DOCS-ONLY for the interactive rendering.
- SessionEnd `systemMessage` produced no output in the stream. VERIFIED-BY-RUN; docs say SessionEnd discards JSON output. DOCS-ONLY (hooks, SessionEnd).
- Plain-text stdout from SessionStart, UserPromptSubmit is added as context, and stdout must be exactly one JSON object to count as JSON. DOCS-ONLY (hooks, "Exit code 0"). Do not print anything else on stdout.
- `additionalContext`, `systemMessage` and plain stdout are capped at 10,000 characters each (excess goes to a file with a 2,000-character preview). DOCS-ONLY (hooks, "JSON output"). The planned 600-character SessionStart output is far below it.
- Deny/ask/defer decisions (`permissionDecision`) and `decision: "block"` exist but the plugin never uses them. DOCS-ONLY (hooks, PreToolUse decision control).

## 4. Exit codes

| Case | Result | Status |
|---|---|---|
| PreToolUse exit 2 (no `\|\| true`), stderr text | Tool blocked, file not created; the model gets `PreToolUse:Write hook error: [<cmd>]: <stderr>` | VERIFIED-BY-RUN (r5) |
| PreToolUse exit 1 | Not blocking; Write ran; stream `outcome:"error"`, `exit_code:1`, stderr only in the hook record | VERIFIED-BY-RUN (r6) |
| UserPromptSubmit exit 2 | Prompt blocked, no model call (`num_turns: 0`), result text `UserPromptSubmit operation blocked by hook: ...` | VERIFIED-BY-RUN (r4) |
| Stop exit 2 | Conversation continues for another turn; the next Stop payload has `stop_hook_active: true` | VERIFIED-BY-RUN (r6) |
| SessionStart exit 2 | Not blocking; the session went on (UserPromptSubmit ran next); `outcome:"error"` | VERIFIED-BY-RUN (r4) |
| SessionEnd exit 2 | Not blocking; session ended | VERIFIED-BY-RUN (r4) |
| PreToolUse hook `... \|\| true` that exits 2 | Swallowed: `exit_code:0`, `outcome:"success"`, Write ran | VERIFIED-BY-RUN (r3) |

So the planned registered form `python3 "..." hook claude EVENT 2>/dev/null || true` can never block, as intended. Exit 2 per event table: DOCS-ONLY (hooks, "Exit code 2 behavior per event").

## 5. `CLAUDE_ENV_FILE`

- Set in the environment of **SessionStart hooks only** (docs add Setup, CwdChanged, FileChanged; not captured). It was unset for UserPromptSubmit, PreToolUse, Stop, SessionEnd. VERIFIED-BY-RUN (`hook_env_names.json`).
- At SessionStart the path does not exist yet; the hook creates it. Shape: `~/.claude/session-env/<session_id>/sessionstart-hook-<N>.sh`. On `--resume` of the same session id the file already held the earlier export (1 line before the hook wrote), so exports accumulate across resumes; use append (`>>`). VERIFIED-BY-RUN.
- A line `export HOOKTEST_VAR=ss1` written by the hook reached the **model's Bash tool** (`printenv HOOKTEST_VAR` printed `ss1`). VERIFIED-BY-RUN.
- **Later hook processes do NOT inherit it.** `HOOKTEST_VAR` was absent from the UserPromptSubmit, PreToolUse, Stop and SessionEnd hook environments, and absent from the resumed SessionStart's environment. VERIFIED-BY-RUN. A hook only sees what `claude`'s own parent environment held.
- `AGENTBUS_AGENT` set in the parent environment of `claude` IS visible in hook env. VERIFIED-BY-RUN (r10). The Bash tool inherits the parent's env too. DOCS-ONLY.
- `CLAUDE_CODE_SESSION_ID` is present in every hook environment and equals the payload `session_id`; the model's Bash tool also has it, while `CLAUDE_ENV_FILE`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PROJECT_DIR` and `AGENTBUS_AGENT` (unset) were not in the Bash env. VERIFIED-BY-RUN (r3 and `hook_env_names.json`). This gives the model a way to derive its own name without any export.

## 6. SessionEnd

- `reason` values seen: `other` (every `claude -p` exit), `clear` (`/clear`), `prompt_input_exit` (`/exit`). VERIFIED-BY-RUN.
- Documented set: `clear`, `resume`, `logout`, `prompt_input_exit`, `other`; `bypass_permissions_disabled` was removed in v2.1.234. DOCS-ONLY (hooks, SessionEnd). `resume` (interactive `/resume` switch) and `logout` were not run.
- Every reason ends the session id the payload names. `clear` and `resume` end the old id and start a new one.
- **Budget: SessionEnd hooks share a 1.5 s budget.** A hook that slept 3 s under `"timeout": 5` was cancelled (`SessionEnd hook [...] failed: Hook cancelled`, post-sleep work never ran). Timeouts set on plugin hooks do not raise the budget. VERIFIED-BY-RUN (r2) and DOCS-ONLY (hooks, SessionEnd: "Timeouts set on plugin-provided hooks don't raise the budget").
- Output is discarded (see section 3).

## 7. SessionStart matcher values

`startup`, `resume`, `clear`, `compact`, `fork`. `startup`, `resume`, `clear` VERIFIED-BY-RUN. `compact` and `fork` DOCS-ONLY (hooks, SessionStart). `fork` is a new forked session (`--fork-session`, `/fork`, `/branch`); the planned matcher `startup|resume|clear` skips it. SessionStart hooks run in the background in interactive mode and the first model response waits for them. DOCS-ONLY.

## 8. Marketplace and git source with `ref`

`.claude-plugin/marketplace.json`, required `name`, `owner`, `plugins[]`; each plugin has `name` (must equal the plugin.json name) and `source`.

- `url` source with a tag `ref`: **VERIFIED-BY-RUN** end to end. A marketplace repo whose entry is
  `{"source":"url","url":"file:///.../mrepo","ref":"v0.0.1"}` (fixture `marketplace_url_source_ref.json`) was added with
  `claude plugin marketplace add <dir>` and installed with `claude plugin install agentbus-cap@capmkt`. A later commit on `main`
  (version 0.0.2, extra file) was NOT installed: the cache held version 0.0.1 and the tag's files, and
  `installed_plugins.json` recorded `gitCommitSha` = the tag commit. So a `ref` pins the install.
- `github` source with `ref` (the shape in the plan): `{"source":"github","repo":"wickdninja/agentbus","ref":"v0.2.0"}`
  (fixture `marketplace_github_source_ref.json`). Schema accepted by `claude plugin validate` (`Validation passed`, exit 0): VERIFIED-BY-RUN. The network fetch itself was not run: DOCS-ONLY (marketplace-reference, "github plugin source"). `ref` is a branch or tag; optional `sha` is a full 40-char commit and wins when both are set.
- A relative `"./"` source passes validate (exit 0). **VERIFIED-BY-RUN** (`validate_bad_source.json` contains it with no error). `release_check.py --tag` must enforce the "no `./`" rule itself.
- A non-string `ref` fails validate: `plugins.N.source: Invalid input`, exit 1. VERIFIED-BY-RUN.
- The marketplace and plugin can share one repo root: validate on a folder that holds both `marketplace.json` and `plugin.json` checks both. VERIFIED-BY-RUN.
- User commands: `/plugin marketplace add owner/repo`, `/plugin install name@marketplace`; shell `claude plugin marketplace add <src>` and `claude plugin install name@marketplace`. Scope default `user`. Shell commands VERIFIED-BY-RUN; the in-app `/plugin` flow DOCS-ONLY (plugins).
- Installed plugin version comes from `plugin.json` `version`; cache path includes it. VERIFIED-BY-RUN.

## 9. Detecting an installed plugin

Two methods, both VERIFIED-BY-RUN:

1. `claude plugin list --json` (about 0.6 s, needs `claude` on PATH): array of
   `{"id":"agentbus-cap@capmkt","version":"0.0.1","scope":"user","enabled":true,"installPath":"...","installedAt":"...","lastUpdated":"...","projectEnabled":false}`.
   Fixture `plugin_list_json.json`. **Disabled plugins stay in the list with `enabled:false`**, so test
   `id.startswith("agentbus@") and enabled`. A `--plugin-dir` plugin appears as `name@inline`, not a marketplace id. Empty list is `[]`. Fields DOCS-ONLY (cli-reference, plugin list).
2. `<config>/plugins/installed_plugins.json` (`~/.claude/plugins/installed_plugins.json`, `{"version":2,"plugins":{"<id>":[{scope,installPath,version,installedAt,lastUpdated,gitCommitSha}]}}`, fixture `installed_plugins.json`). The file is not in the public docs, so its format is undocumented and may change; it keeps a disabled plugin (enabled state lives in settings `enabledPlugins`). After uninstall the key is removed (`"plugins": {}`). Honors `CLAUDE_CONFIG_DIR`.

Recommendation for `setup claude` / `doctor` (not hooks, too slow): method 1; fall back to "unknown, add hooks" if `claude` is absent or errors. This satisfies the runbook's "if neither is reliable" test: method 1 is reliable and documented.

## 10. `claude plugin validate`

- Exit codes: 0 pass (with or without warnings), 1 failed, 2 validator error. DOCS-ONLY (cli-reference, plugin validate); 0 and 1 VERIFIED-BY-RUN.
- Verdict lines are `✔ Validation passed` (clean) or `✔ Validation passed with warnings` (still exit 0) or `✘ Validation failed`. VERIFIED-BY-RUN. The gate "ends: Validation passed" holds only when there are no warnings; the marketplace needs a `description` and plugin.json an `author` for that (`validate_clean.json`, `success:true`). Prefer asserting on exit code plus `--json`'s `success`.
- It also validates `hooks/hooks.json` (unknown event, unquoted `${CLAUDE_PLUGIN_ROOT}` warnings). VERIFIED-BY-RUN.
- Extra "plugin directory" notes (README missing, no icon) print but do not change the verdict unless `--profile directory`. VERIFIED-BY-RUN. `--json` and `--strict` flags exist. DOCS-ONLY.
- Plain `validate .` on a repo root with both manifests prints `Validating marketplace manifest: ...`. VERIFIED-BY-RUN.

## 11. Runbook assumptions

| Runbook assumption | Verdict | Evidence |
|---|---|---|
| `${CLAUDE_PLUGIN_ROOT}` expands in hook commands | CONFIRMED | section 1 |
| `hookSpecificOutput.additionalContext` injected for SessionStart, UserPromptSubmit, PreToolUse | CONFIRMED | section 3 |
| Stop `systemMessage` is user-visible and does not block | CONFIRMED | section 3 |
| exit 2 blocks, 1 and others do not | CONFIRMED for PreToolUse, UserPromptSubmit, Stop; SessionStart, SessionEnd never block | section 4 |
| registered `\|\| true` form cannot block | CONFIRMED | section 4 |
| SessionStart writes `CLAUDE_ENV_FILE` so the model's Bash gets the name | CONFIRMED | section 5 |
| later hook processes inherit CLAUDE_ENV_FILE exports, so a value equal to the derived name can reach a hook | REFUTED (they do not; only the parent env of `claude` reaches hooks) | section 5 |
| PreToolUse path is `tool_input.file_path` for Edit, Write, MultiEdit, NotebookEdit | PARTLY REFUTED: NotebookEdit uses `notebook_path`; MultiEdit is not a current tool | section 2 |
| 5 s hook timeout fits all five events | REFUTED for SessionEnd (1.5 s budget, plugin timeouts do not raise it) | section 6 |
| SessionEnd reasons that end the session | CONFIRMED set `clear`, `resume`, `logout`, `prompt_input_exit`, `other`; all end the named id; `claude -p` always gives `other` | section 6 |
| a derived name resumed with the same session id keeps its claims | UNKNOWN / at risk: same id on resume is CONFIRMED, but SessionEnd `other` fires at every `-p` exit and the plan's `leave` releases claims | sections 2, 6 |
| subagent shares the parent's session id | CONFIRMED; payload adds `agent_id`, `agent_type` | section 2 |
| marketplace git source with `ref` pins the release tag | CONFIRMED for `url`+`ref` by run; `github`+`ref` shape accepted by validate, fetch DOCS-ONLY | section 8 |
| `./` source rejected | REFUTED for validate (passes); `release_check.py` must enforce | section 8 |
| plugin installed can be detected | CONFIRMED (`claude plugin list --json`, filter `enabled`) | section 9 |
| `claude plugin validate .` ends `Validation passed` | PARTLY: only with no warnings; use exit code | section 10 |
