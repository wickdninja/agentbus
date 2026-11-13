# watch v2 build addendum (issue #8 must follow this)

Revision 2 of the watch v2 design (issue #7) changed behaviour contracts that the 06 runbook (issue #8) was written against. Where this addendum and the runbook differ, this addendum wins; where this addendum and the goldens differ, the goldens win and the difference is a bug in this file. Sources: `docs/design/watch-v2.md` (section "Revision 2" lists every review finding), `tests/golden/watch/` (frames, `fixture.json`, `behaviour.json`).

## Rules

### View state

- **R1. View fields.** `View` gains `copied` (text or None), `frozen` (the retained snapshot and its time, see R3) and `detail.stack` (a list of `{section, key, sel, scroll, thread}`); `detail` gains `sel` (a `(section, key)` pair or None). `pending` is not a field: render counts it as `current.counts.messages - frozen.counts.messages`.
- **R2. The view state survives every error.** Mode, focus, selection, scroll, filter, pause, frozen snapshot and the detail stack are never reset by a busy, refused, newer or missing bus. When the bus reads again, the same frame comes back. Test: `view-survives-errors`.

### Pause

- **R3. Pause retains the loaded records, the selection and the viewport.** On pause, `View.frozen` takes the whole current snapshot (every section, `unread`, `counts`) and its `t_now`. While paused, `render` draws only the frozen snapshot at its own time (ages, summary, `paused at HH:MM`); the current snapshot is used for one thing, the `+N new` count. Filtering, moving, opening details and resizing work on the frozen records. Resume (`p` or `G`) replaces the frozen snapshot with the newest one. Tests: `pause-rollover`, `pause-rollover-pty`, `pause-freezes-display`.
- **R4. Pause freezes the whole display** (reduced motion). No row but the Messages title changes between ticks while paused; the `▌` bar is not drawn.

### Busy and errors

- **R5. Lock wait 250 ms, never blocking keys.** The snapshot and detail reads use a busy timeout of 250 ms (`LOCK_WAIT_MS`), not `BUSY_WAIT_S = 15.0`. On a timeout watch keeps the last frame and its state and adds `waiting · Ns old` to the header (SGR `33;40`), N being the age of the last good read. Only `schema_refused`, `schema_older`, `schema_newer` and `no_bus` render a full-screen error frame. `q` exits within 250 ms of being pressed while another process holds the lock. Tests: `busy-keeps-frame`, `busy-q-under-250ms`. 01's error plumbing must expose `busy` as a soft state, not an exception that replaces the frame.

### Snapshot

- **R6. Two additive snapshot keys, read-only.** `watch_snapshot` adds `topic` to each message (`SELECT id, ts, sender, recipient, kind, topic, body, reply_to`) and `unread` per agent name: messages addressed to the agent or broadcast after its cursor (`last_read_id`, `bcast_from`), not sent by it, counted in the same short read-only open. `watch --json` gains both keys (additive, like 07's `omitted`). No write, no cursor created.

### Overview

- **R7. Header summary.** The overview header's right-hand text is `N alert(s) · N open question(s)` wide, `N ALRT · N ask` narrow, with `· N open todo(s)` / `· N todo` added only when a todo is open. The counts are brief's, over the whole bus rather than the rows the view holds (`open_question_where`, `open_todo_where`; an alert is open until a message replies to it): a question closes only on a direct answer and a todo only on a direct `done` or `dropped`. They look at the newest 5000 messages (`SCAN`); past that the header is prefixed `newest 5000: ` and `watch --json` has `open.window` 5000 (null otherwise). The counts `3 agents · 2 claims · 9 messages` are gone.
- **R8. Selection never hidden, more never 0.** A section window moves only as far as the selection needs. A cut section with two or more rows ends in `… N more`, N every hidden row; with one row it shows the selected row and its title carries `… N more`. Messages count `… N earlier` and `… N later`. No marker reads 0. Test: `selection-never-hidden`, goldens `facts-focus-40x16`, `agents-focus-40x16`.
- **R8a. Following in Messages**: footer `k browse`, title `following · k to browse` when Messages has the focus; j does nothing there.
- **R8b. Agents rows** show the role, then `N unread · holds RESOURCE` (`+N` for more claims) when 8 or more columns are left for it.

### Filter

- **R9a. Kind codes.** `kind:X` matches a kind that starts with X or whose code is X, case ignored. The error is exactly `kind must be one of: note, question (ask), answer (ans), handoff (hand), decision (dec), alert (ALRT), done` and stays on screen while the filter is kept. Test: `kind-codes`.
- **R9b. Coverage and n/a.** A filtered section that holds fewer rows than exist counts `N of newest 200` and adds `… M older not searched · agentbus read` (`who`, `claims`, `ctx get` for the others). A section with any token that does not apply to it (`to:`, `kind:`, `topic:` outside Messages) shows `n/a` and `FIELD: is for messages` and takes no rows. Test: `filter-coverage`.
- **R9c. New tokens and words.** `topic:NAME` (prefix match on the message topic). A broadcast matches the words `everyone` and `all` and `to:*`, `to:all`, `to:everyone`. Narrow rows show a broadcast as `→all`.
- **R9d. Input that never breaks the row.** The filter input keeps `Enter keep · Esc clear` on the right and scrolls its text so the end shows (`/…text_`). A kept filter is cut in the footer before `Esc clear · ? help · q quit` ever is. Test: `long-input`.

### Detail

- **R10. Navigable, stacked details.** j/k select the related rows (thread messages; an agent's claims and messages; a claim's holder and mentions; a fact's author), Enter opens one on top of the stack, Esc and q pop one level and restore that detail's selection and scroll, `/` clears the stack. A detail opens with nothing selected; j/k scroll when there are no related rows; PgUp/PgDn scroll the page; the page scrolls to keep the selection visible and counts hidden rows (`… N lines above · PgUp`, `… N more lines · PgDn`). The open message is marked `*` in column 0 and `>` means only the selection. The footer names the back target (`Esc/q back to #10`). Tests: `detail-marks`, `esc-and-q-back-one-level`.
- **R11. q quits only from the overview** (and the full-screen error frames). In detail and help, q is back. Ctrl-C, SIGTERM and SIGHUP quit from anywhere.
- **R11a. Nothing is cut in a detail.** Message metadata wraps by field, names and ids whole; resources, keys, values, history values and the reply command wrap under their label. Rows that open something stay one-line summaries. Test: `detail-wraps`.
- **R11b. Limits are labelled with a route.** At most 20 ancestors and 20 direct replies: `Thread  N shown`, `… #A replies to #B · open #A to go further up`, `… N more replies · agentbus read --since ID`. Agent and claim lists: newest 5, `5 of N`, then `… N older · /WORD lists them` (all within the held 200) or `· agentbus read`. Fact history: newest 20, then `… N older · agentbus ctx history KEY`. An ancestor older than the held 200 is loaded by the detail query and opens like any row. Test: `thread-limits`, golden `detail-nav`.
- **R11c. The holder's dot** in claim detail (and the author's in fact detail) is the overview's calculation: `held by   ○ codex · implementer · seen 6m ago`. Test: `claim-holder-idle`.
- **R11d. Reply command.** Message detail shows `reply     agentbus --as NAME post --to SENDER --reply-to ID` plus ` --kind answer` for a question, then ` "..."`. NAME is `$AGENTBUS_AGENT` when set, else the literal `NAME` (the goldens use `NAME`).

### Copy

- **R12. `y` copies via OSC 52.** Overview: the selected row's key (message id, agent name, claim resource, fact key). Detail: the reply command (message), name, resource or value. watch writes `ESC ] 52 ; c ; BASE64 BEL` to the terminal and sets `View.copied`; the footer shows `copied: TEXT · if paste fails, select it here` when it fits, else `copied the reply command · if paste fails, select it above`, until the next key. Nothing in the bus changes. Test: `copy-osc52`, golden `copied`.

### Performance

- **R13. The input loop never waits on SQL.** Snapshot and detail reads run on one reader thread; the loop `select`s on stdin, the wake pipe and a result pipe. At most one snapshot read in flight (a tick that finds one running skips); a detail result is applied only if its detail is still open. On quit the loop calls `Connection.interrupt()` and joins the reader for at most 50 ms. Test: `input-never-waits-on-sql` (key to redraw under 100 ms for 20 keys while a read is blocked).
- **R14. Detail queries run on open and on `r`**, never per tick. Test: `detail-queries-on-open-and-r`.
- **R15. Bounded scans.** Every detail query reads at most the newest 5000 messages (`id > (SELECT MAX(id) FROM messages) - 5000`), counts matches, returns `LIMIT 5` (20 for thread and history); lists cut by the bound say `in newest 5000`. Test: `scan-bounded`.
- **R16. Mentions use `instr(body, ?) > 0`**, never `LIKE`. Test: `mentions-instr`.
- **R17. Wrapping is linear and cached** by (text, width) (an LRU of a few thousand entries). Test: `wrap-linear` (twice the text, under 3 times the cost).

### Accessibility and terminals

- **R18. ASCII mode.** `AGENTBUS_ASCII=1`, `TERM=linux`, or the start-up probe (write `●`, request the cursor position with `ESC [ 6 n`, wait at most 100 ms; a two-column advance means ambiguous-wide) switch to the ASCII glyph set: `* o | ... - -> re:# +` and `Down Up`, the goal as `goal: `, narrow route width 14, emoji off. Every ASCII golden is pure ASCII. Tests: `ascii-only`, `ascii-auto`.
- **R19. Header SGR** `30;43` (never bold); `1;7` in ASCII mode. **Instructions at normal intensity**: footer words, the error reason and `Run:` carry no SGR 2. Test: `header-sgr`.
- **R20. Help, kind codes and filter agree**: the help frame is the `help` golden (keys, marks, Words, Kinds with codes); `watch --help` gains `Keys: j/k move, Tab section, Enter open, / filter, p pause, y copy, ? help, q quit. Read-only.` and `Esc and q go back; q quits from the main view, Esc never quits.`

## Runbook lines this replaces

- 06 Design, `View`: add R1's fields; remove `pending`.
- 06 Design, "Detail data": add R10 to R11d and R13 to R16; "one short open per request" stays.
- 06 Design, "Errors": replace with R2 and R5.
- 06 Tests, pty `p pauses: a post made while paused shows "+1 new" and the view does not change`: keep, and add `pause-rollover-pty`.
- 06 Tests, `key to redraw under 100 ms for 20 keys`: keep, and add `busy-q-under-250ms` and `input-never-waits-on-sql`.
- 06 Tests, `filter with kind:fyi sets the kind-must-be-one-of message`: the message is R9a's.
- 06 DX acceptance footer: the following footer is `k browse · Enter open · / filter · p pause · Tab section · ? help · q quit`.
- 06 Tests, `Esc returns to the overview frame byte for byte`: also for q from a detail, and one level at a time from a nested detail.

## Behaviour cases

`tests/golden/watch/behaviour.json` lists 25 cases. The 14 with `"runs": "mock"` pass on the design mock today; 06 ports each to `tests/test_watch_keys.sh` against `bin/agentbus`'s pure `render` (no pty needed). The 11 with `"runs": "06"` need the live loop, a pty or a held lock; 06 writes them. The four the brain named: `pause-rollover`, `selection-never-hidden`, `kind-codes`, `busy-q-under-250ms`.
