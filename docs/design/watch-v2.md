# agentbus watch v2: the design

Issue #7 (workstream 05). Status: **revision 2, waiting for the owner's sign-off**. Revision 1 went to two adversarial reviews (wd-opus: approve with changes; wd-astra: redesign the behaviour contracts). This revision keeps the look the owner liked and rewrites the behaviour contracts; every finding is listed in "Revision 2" below. Nothing in `bin/agentbus` changes until it is approved; 06 (issue #8) then builds to these frames character for character and follows `docs/design/watch-v2-build-addendum.md`.

How to read it:

- `docs/design/watch-v2.html` shows every frame below in colour on a dark terminal, with a NO_COLOR switch. It is the quickest read.
- Every frame here is the exact text. Colour only adds SGR codes; it never adds, removes or moves a character, so the text you see is also the no-colour rendering.
- Each state is shown at 100x30 and 60x20, with emoji (what a UTF-8 terminal shows) and without (`AGENTBUS_NO_EMOJI=1`, a non-UTF-8 terminal, or any non-terminal). ASCII states are shown without emoji only. Trailing blank rows are left out here; the golden files keep them.
- Two sample buses. The small one, used by most frames: 3 agents, 2 claims, 2 facts, 9 messages and a goal, at 16:44 UTC on 2026-11-01, in `~/src/acme-api`. The big one is the same bus at 16:58:20, after 200 more messages (#10 to #209): 209 messages, of which watch holds the newest 200. The frames are drawn by `docs/design/watch_v2_mock.py` from `tests/golden/watch/fixture.json`, so the columns are exact.

## Revision 2

The brain's rulings on the two reviews, applied:

1. Every finding of both reviews and both Missing lists: `y` copies an id or a command (OSC 52) with a visible fallback; message detail shows the reply command; a `topic:` filter. The noise goes: the header's counts become the "what needs me" summary (open alerts, open questions) and the bus-gone 🌱 is gone.
2. Pause keeps the loaded records, the selection and the viewport; resume replaces them. Pause freezes the whole display, which is also the reduced-motion mode.
3. Every capped section and every filter states its coverage: `of newest 200`, `older not searched · agentbus read`, and `n/a` for sections a filter does not apply to.
4. The selection is never hidden, and a "more" count is never 0.
5. Details are navigable: j/k select the related rows, Enter opens one, Esc and q go back one level, q quits only from the overview. The open record is marked `*`. Identifiers and values wrap in detail, nothing is cut there; the ancestor and reply limits are labelled with the route to the rest.
6. A busy bus never blocks keys: watch waits at most 250 ms for the lock, keeps the last frame and its state, and shows `waiting · Ns old` in the header. Only refused, newer and no-bus get a full screen, and the view state survives every error.
7. Help, kind codes and the filter agree; `kind:` takes the codes.
8. Accessibility: `AGENTBUS_ASCII` (automatic on `TERM=linux`) with an ASCII glyph set; a header that stays legible where bold means bright; the error reason at normal intensity; nothing carried by colour alone.
9. Performance rules are spec (section 8): detail queries on open and on r only; mentions with `instr`; scans bounded at the newest 5000 messages with a coverage label; linear, cached wrapping; the input loop never waits on SQL.
10. Every consistency nit both reviews list.

New states: `pause-rollover` (pause with rollover), `filter-coverage`, `busy` (the last frame kept), `ascii`, `ascii-detail` and `ascii-help`, `detail-nav` and `detail-nested` (detail navigation), `copied`, and two single 40x16 frames, `facts-focus-40x16` and `agents-focus-40x16`. `error-busy` is gone: busy is no longer a full screen.

Behaviour cases: `tests/golden/watch/behaviour.json` lists the reviewers' cheapest falsifying tests and the new rules as cases. 14 run on the mock now (`python3 docs/design/watch_v2_mock.py --behaviour`, run by `tests/test_watch_golden.sh`) and 06 ports them to `bin/agentbus`; 11 need the live loop and are 06's to write (among them busy with `q` under 250 ms). The four named by the brain: `pause-rollover` (#9, then #10 to #209), `selection-never-hidden` (40x16 and up), `kind-codes` (`kind:ask`), `busy-q-under-250ms`.

Each finding, with what was done: 30 APPLIED, 2 REJECTED. O is wd-opus, A is wd-astra.

| # | Finding | Status | What changed, or why not |
|---|---|---|---|
| O1 | A short section hides rows and the selection; `… 0 more` | APPLIED | A cut section always shows its selected row; with one row the title carries `… N more`; the count is every hidden row and never 0. Messages also count `… N later` below the window. Frames `facts-focus-40x16`, `agents-focus-40x16`; case `selection-never-hidden`. |
| O2 | Filter counts claim the whole bus | APPLIED | `Messages  0 of newest 200` and `… 9 older not searched · agentbus read`; the same rule for every capped section. Frame `filter-coverage`; case `filter-coverage`. |
| O3 | Help teaches kind codes the filter rejects | APPLIED | `kind:X` matches a kind that starts with X or whose code is X; the error lists `question (ask)` and the rest. Frame `filter` types `kind:ask`; case `kind-codes`. |
| O4 | Busy blocks keys for 15 s, contradicts itself and throws away the view | APPLIED | 250 ms lock wait; the last frame stays with `waiting · 27s old` in the header; full screens only for refused, newer and no bus; the view state survives every error. Frame `busy`; cases `busy-keeps-frame`, `busy-q-under-250ms`, `view-survives-errors`. |
| O5 | Claim detail shows an idle holder as active | APPLIED | `held by   ○ codex · implementer · seen 6m ago`, the overview's own calculation. Case `claim-holder-idle`. |
| O6 | The overview does not say what needs me; Agents rows are empty | APPLIED | Header right: `1 alert · 1 open question` (narrow `1 ALRT · 1 ask`); open means no message replies to it, counted in what watch holds and labelled `newest 200:` when the bus has more. Agents rows: `2 unread · holds src/auth/` from the cursors table, read without writing. |
| O7 | Details are dead ends; `>` means two things; agent `5 of 6` has no route | APPLIED | j/k select related rows, Enter opens, Esc goes back one level; `*` marks the open record and `>` only the selection; `… 1 older · /codex lists them`. Frames `detail-nav`, `detail-nested`; case `detail-marks`. |
| O8 | `q` in detail or help quits the app | APPLIED | q goes back one level there, as in less and man; it quits from the overview (and the error screens). Footers say `Esc/q back`. |
| O9 | Ambiguous-width glyphs and missing console glyphs | APPLIED | `AGENTBUS_ASCII=1`, automatic on `TERM=linux` and when a start-up probe finds `●` drawn two columns wide: `* o \| ... -> re:#6 +1`, `-` for `·`. Frames `ascii`, `ascii-detail`, `ascii-help`; case `ascii-only`. |
| O9b | ASCII goal mark `>` | REJECTED | `>` already means the selected row; two meanings for one mark is the confusion O7 removes. The ASCII goal row reads `goal: auth on the new token API`. |
| O10 | Bold black on yellow turns grey where bold means bright | APPLIED | The bar is `30;43`, never bold, so no terminal can brighten its black; `1;7` under `TERM=linux` and `AGENTBUS_ASCII`. Same yellow look. |
| O11 | The error reason is dim | APPLIED | Normal intensity; so are `Run:` and the footer's words (instructions); only separators, ages and roles stay dim. |
| O12 | Detail queries have no index and LIKE treats `_` as a wildcard | APPLIED | Section 8 and addendum R9-R12: on open and r only; `instr(body, ?)`; at most the newest 5000 messages, labelled `in newest 5000`; `LIMIT 5` plus a count. Case `mentions-instr`. |
| O13 | You cannot tell Messages has focus while following | APPLIED | Footer `k browse`; title `following · k to browse`. |
| O14 | A `kind:` filter says Agents `no match` | APPLIED | `Agents  n/a` with `kind: is for messages`; the section gives its rows away. |
| O15 | `everyone` matches nothing | APPLIED | A broadcast matches the words it is shown as, `everyone` and `all`, and `to:*`, `to:all`, `to:everyone`. |
| O16 | Narrow `claude→every…` | APPLIED | Narrow rows say `→all`. |
| O17 | The same thing written two ways | APPLIED | `Tab section` everywhere; `↳#6` everywhere (detail too); the goal row loses its stray `·` (`nate · 2h`); headers say `agent codex`, `claim src/auth/`, `fact baseline_sha`. |
| O18 | Help does not explain the screen's words | APPLIED | Help has a Words block: `following`, `paused at`, `+N new`, `… N earlier/later/more`, `N of M`, `of newest 200`, `n/a`, `open`, `waiting · Ns old`, `restart for`. |
| OM1 | No key to copy an id or command | APPLIED | `y` copies via OSC 52; the footer says what was copied and where it is on screen if paste fails. Frame `copied`. |
| OM2 | No reply command in message detail | APPLIED | `reply     agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."`, wrapped, never cut; `NAME` is `$AGENTBUS_AGENT` when set. |
| OM3 | No `topic:` filter | APPLIED | `topic:NAME` matches a message topic that starts with NAME; `n/a` elsewhere; detail shows `topic auth`. Needs `topic` in the snapshot (addendum R6). |
| ON1 | Header counts are noise | APPLIED | Replaced by the "what needs me" summary (O6). |
| ON2 | The bus-gone 🌱 is noise | APPLIED | Gone; ⏳ went with the busy screen. 🚧 stays for refused and newer. |
| A1 | Pause loses what you were reading on rollover | APPLIED | Pause keeps the records, selection and viewport; resume replaces them; the whole display freezes. Frame `pause-rollover`; case `pause-rollover` (also filter and resize while paused). |
| A2 | Filters imply a complete search; recent is not the same as blocked | APPLIED | O2's coverage rows, on every capped section and in the header summary. Nothing claims "blocked": `open` is defined only as "no reply among the messages held". |
| A3 | Long input breaks rows and drops the escape hints; the kind error vanishes after Enter | APPLIED | The input scrolls around its cursor; a kept filter is cut, never `Esc clear · ? help · q quit`; detail metadata wraps by field; the kind error stays while the filter is kept. Case `long-input`, `detail-wraps`. |
| A4 | Inspection dead ends; truncated identifiers; unlabelled limits | APPLIED | O7's navigation; an ancestor older than the 200 opens like any row (`detail-nav`); resources, keys, values and history values wrap whole; `Thread  41 shown`, `… #6 replies to #5 · open #6 to go further up`, `… 5 more replies · agentbus read --since 26`. Rows that open something stay one-line summaries, because Enter shows them whole. Case `thread-limits`. |
| A5 | Claim detail contradicts the activity legend | APPLIED | As O5. |
| A6 | Bounded queries do not bound work; wrapping is quadratic | APPLIED | Scans bounded at 5000 with a label; wrapping linear and cached by text and width (case `wrap-linear`); reads run off the input loop and are interrupted on quit (section 8, addendum R12-R14). |
| A7 | Accessibility: freeze, essential text at normal intensity, width tested apart from the renderer | APPLIED | Pause freezes everything; instructions at normal intensity; goldens are checked through `tests/term_oracle.py` (libc wcwidth), ASCII goldens must be pure ASCII, and 06 probes ambiguous width at start. |
| A7b | An optional linear change output | REJECTED | A new output mode, not a frame, and outside #7's scope. A linear, append-only stream already exists (`agentbus read --since ID`), and `--once` and `--json` stay. Listed for the brain as a follow-up issue. |

Kept, as both reviews asked: generated exact frames and goldens; nothing carried by colour alone; selection held by stable key; every printable key is text in the filter input; Esc does not quit; kind codes on narrow rows with `ALRT`; the spare last column; the read-only invariant, pty tests and ordered cleanup; the empty-bus lines, `restart for`, `--once` and `TERM=dumb`; the pinned goal and the visible selection marker.

## Decisions for the owner

One at a time, recommended answer first. Each has a fallback that only changes colour, a glyph or a word, not the layout.

1. **Header bar in bus yellow** (black on yellow, SGR `30;43`, not bold so no terminal greys the text) instead of v0.1.0's reverse video. It ties the view to the yellow bus in the README art. `TERM=linux` and `AGENTBUS_ASCII` use `1;7`. Fallback: `1;7` everywhere.
2. **🚌 before `agentbus` in the header when emoji are on.** It costs 3 columns and is dropped, right after the folder name, when the header cannot fit. Fallback: no glyph.
3. **Section icons for the detail views** (🧵 Thread, 📜 History, 🔗 Mentioned in) and 🚧 on the refused and newer screens. Single wide code points, emoji on only. Fallback: no icons there.
4. **The header says what needs you**, `1 alert · 1 open question`, instead of repeating the section counts. Fallback: no right-hand text.
5. **Agents rows show unread and holdings** (`2 unread · holds src/auth/`); watch reads the cursors table without writing. Fallback: the role alone, as revision 1.
6. **Pause freezes the whole view**, ages included (`paused at 16:44`), not only Messages. It is what keeps your place on a busy bus, and it is the reduced-motion mode. Fallback: none recommended.
7. **q goes back one level in a detail or help and quits only from the overview** (less, man). Ctrl-C quits from anywhere. Fallback: q quits everywhere, as revision 1.
8. **A filter that leaves a section empty or does not apply to it collapses it to its title row** (`no match`, `n/a`), so the matching messages get the rows. Fallback: an extra row each.
9. **Claim detail lists the messages that name the claim** (the newest 5 of the newest 5000 messages). Fallback: drop the list.
10. **Narrow rows (40 to 71 columns) show both the kind emoji and the short code** (`🤝 hand`). Fallback: emoji alone with emoji on, code alone otherwise.
11. **Esc no longer quits from the overview** (decided in the runbook; listed under Changed in CHANGELOG).

## What changes from v0.1.0, in one list

- Browse: Tab and 1 to 4 move the focus between Agents, Claims, Facts and Messages; j/k move a `>` selection; g/G, PgUp/PgDn and Ctrl-u/Ctrl-d jump. The selection is never off screen.
- Inspect: Enter opens any row: a message with every field, its whole body, its reply command and thread; an agent with its unread count, claims and last messages; a claim with its holder, times and mentions; a fact with its value and history. Inside a detail, j/k select the related rows and Enter opens them; Esc or q goes back one level.
- Filter: `/` with `from:`, `to:`, `kind:` (word or code), `topic:` and plain words; counts read `N of M` or `N of newest 200`, and say what was not searched.
- Read in peace: k in Messages pauses the whole view and keeps it, whatever arrives; p or G follows again.
- What needs me: the header counts open alerts and open questions.
- Copy: y puts an id or the reply command on the clipboard (OSC 52).
- Learn in place: a footer that names the keys for the current view, and `?` for every key, mark and word.
- Honest failures: a bus that cannot be read gets a full-screen explanation and the fix; a busy bus keeps your frame and says how old it is.
- Accessible: NO_COLOR loses nothing; `AGENTBUS_ASCII` (and `TERM=linux`) draw only ASCII.
- The rest is v0.1.0's: the sections, their order, the row shares, the blank-row rule, escaping, the emoji tables, the colours of agents and kinds.

## 1. States and frames

<!-- BEGIN states -->
### Overview, following

What opens. Everything at a glance: the pinned goal, who is here and what each one has waiting and holds, what is claimed, the shared facts and the newest messages. The header answers "what needs me?": open alerts, open questions and open todos (an alert no message replies to, a question no answer replies to, a todo no done or dropped replies to). Messages follow the stream; message 9 arrived in the last 3 seconds, so it carries the `▌` bar and a bold body. While following, j does nothing in Messages, so the footer says `k browse`.

```text
[frame overview 100x30]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  3
  ● 🧠 claude           planner         1 unread                                                now
  ○ ✋ codex            implementer     2 unread · holds src/auth/                               6m
  ● 🧪 tests            tester          holds docs/api.md                                       now

🔒 Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9                                                              following · k to browse
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
▌ #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now



  k browse · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame overview-noemoji 100x30]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  3
  ● claude           planner         1 unread                                                   now
  ○ codex            implementer     2 unread · holds src/auth/                                  6m
  ● tests            tester          holds docs/api.md                                          now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9                                                                 following · k to browse
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
▌ #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now



  k browse · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame overview 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h
👥 Agents  3
  ● 🧠 claude       planner     1 unread                now
  ○ ✋ codex        implementer 2 unread · holds src/…   6m
  ● 🧪 tests        tester      holds docs/api.md       now
🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9                      following · k to browse
  … 4 earlier
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
▌ #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
  k browse · Enter open · / filter · ? help · q quit
```

```text
[frame overview-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h
Agents  3
  ● claude       planner     1 unread                   now
  ○ codex        implementer 2 unread · holds src/aut…   6m
  ● tests        tester      holds docs/api.md          now
Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9                         following · k to browse
  … 4 earlier
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
▌ #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
  k browse · Enter open · / filter · ? help · q quit
```

### A section focused, a row selected

After Tab, Tab, j: Claims has the focus, so its title says `j/k move · Enter open`, and `src/auth/` is selected (`>` and reverse video). Messages keep following underneath.

```text
[frame section-focus 100x30]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  3
  ● 🧠 claude           planner         1 unread                                                now
  ○ ✋ codex            implementer     2 unread · holds src/auth/                               6m
  ● 🧪 tests            tester          holds docs/api.md                                       now

🔒 Claims  2                                                                  j/k move · Enter open
  docs/api.md                       tests        42m left
> src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9                                                                            following
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now



  j/k move · Enter open · y copy · Tab section · / filter · ? help · q quit
```

```text
[frame section-focus-noemoji 100x30]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  3
  ● claude           planner         1 unread                                                   now
  ○ codex            implementer     2 unread · holds src/auth/                                  6m
  ● tests            tester          holds docs/api.md                                          now

Claims  2                                                                     j/k move · Enter open
  docs/api.md                       tests        42m left
> src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9                                                                               following
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now



  j/k move · Enter open · y copy · Tab section · / filter · ? help · q quit
```

```text
[frame section-focus 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h
👥 Agents  3
  ● 🧠 claude       planner     1 unread                now
  ○ ✋ codex        implementer 2 unread · holds src/…   6m
  ● 🧪 tests        tester      holds docs/api.md       now
🔒 Claims  2                          j/k move · Enter open
  docs/api.md         tests      42m left
> src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9                                    following
  … 4 earlier
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
  j/k move · Enter open · / filter · ? help · q quit
```

```text
[frame section-focus-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h
Agents  3
  ● claude       planner     1 unread                   now
  ○ codex        implementer 2 unread · holds src/aut…   6m
  ● tests        tester      holds docs/api.md          now
Claims  2                             j/k move · Enter open
  docs/api.md         tests      42m left
> src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9                                       following
  … 4 earlier
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
  j/k move · Enter open · / filter · ? help · q quit
```

### Paused

After k in Messages: the whole view freezes, as it was at 16:44, so you can read (and nothing on the screen moves, which is also the reduced-motion mode). Rows hidden above and below the window are counted. p or G follows again.

```text
[frame messages-paused 100x30]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  3
  ● 🧠 claude           planner         1 unread                                                now
  ○ ✋ codex            implementer     2 unread · holds src/auth/                               6m
  ● 🧪 tests            tester          holds docs/api.md                                       now

🔒 Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9                                                   paused at 16:44 · p or G to follow
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
> #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now



  j/k move · Enter open · p follow · y copy · g/G top/bottom · / filter · ? help · q quit
```

```text
[frame messages-paused-noemoji 100x30]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  3
  ● claude           planner         1 unread                                                   now
  ○ codex            implementer     2 unread · holds src/auth/                                  6m
  ● tests            tester          holds docs/api.md                                          now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9                                                      paused at 16:44 · p or G to follow
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
> #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now



  j/k move · Enter open · p follow · y copy · g/G top/bottom · / filter · ? help · q quit
```

```text
[frame messages-paused 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h
👥 Agents  3
  ● 🧠 claude       planner     1 unread                now
  ○ ✋ codex        implementer 2 unread · holds src/…   6m
  ● 🧪 tests        tester      holds docs/api.md       now
🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9           paused at 16:44 · p or G to follow
  … 4 earlier
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
> #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
  j/k move · Enter open · p follow · ? help · q quit
```

```text
[frame messages-paused-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h
Agents  3
  ● claude       planner     1 unread                   now
  ○ codex        implementer 2 unread · holds src/aut…   6m
  ● tests        tester      holds docs/api.md          now
Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9              paused at 16:44 · p or G to follow
  … 4 earlier
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
> #8  claude→codex  hand Next: the token endpoint in …   1m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
  j/k move · Enter open · p follow · ? help · q quit
```

### Paused while 200 messages arrive

Paused on #9, then 200 messages arrive (#10 to #209), more than the 200 watch holds. Pause keeps the records, the selection and the viewport it froze, so #9 stays on screen and selected; the title counts `+200 new`. p or G replaces the frozen view with the newest one.

```text
[frame pause-rollover 100x30]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  3
  ● 🧠 claude           planner         1 unread                                                now
  ○ ✋ codex            implementer     2 unread · holds src/auth/                               6m
  ● 🧪 tests            tester          holds docs/api.md                                       now

🔒 Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9                                        paused at 16:44 · +200 new · p or G to follow
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
> #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now



  j/k move · Enter open · p follow · y copy · g/G top/bottom · / filter · ? help · q quit
```

```text
[frame pause-rollover-noemoji 100x30]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  3
  ● claude           planner         1 unread                                                   now
  ○ codex            implementer     2 unread · holds src/auth/                                  6m
  ● tests            tester          holds docs/api.md                                          now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9                                           paused at 16:44 · +200 new · p or G to follow
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
> #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now



  j/k move · Enter open · p follow · y copy · g/G top/bottom · / filter · ? help · q quit
```

```text
[frame pause-rollover 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h
👥 Agents  3
  ● 🧠 claude       planner     1 unread                now
  ○ ✋ codex        implementer 2 unread · holds src/…   6m
  ● 🧪 tests        tester      holds docs/api.md       now
🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9         paused · +200 new · p or G to follow
  … 4 earlier
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
> #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
  j/k move · Enter open · p follow · ? help · q quit
```

```text
[frame pause-rollover-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h
Agents  3
  ● claude       planner     1 unread                   now
  ○ codex        implementer 2 unread · holds src/aut…   6m
  ● tests        tester      holds docs/api.md          now
Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9   paused at 16:44 · +200 new · p or G to follow
  … 4 earlier
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
> #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
  j/k move · Enter open · p follow · ? help · q quit
```

### Message detail with its thread

Enter on message 7: every field and the whole body, wrapped, never cut; the command that replies to it; and the thread (the messages it replies to and the replies to it). The open message is marked `*`. j/k select a thread row and Enter opens it; t hides the thread; Esc or q goes back one level.

```text
[frame message-detail 100x30]
 🚌 agentbus  ~/src/acme-api                                                            message #7
  🎯 auth on the new token API                                                            nate · 2h

  #7  codex → tests  💬 answer  ↳#6  topic auth                                      16:37 · 7m ago

    Plain text for now. A test will pin it once the spec says otherwise, and the handler returns
    the same body for every 401.

  reply     agentbus --as NAME post --to codex --reply-to 7 "..."

🧵 Thread  3                                                                j/k select · Enter open
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
* #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now















  j/k select · Enter open · y copy · t thread · Esc/q back · ? help
```

```text
[frame message-detail-noemoji 100x30]
 agentbus  ~/src/acme-api                                                               message #7
  ◆ auth on the new token API                                                             nate · 2h

  #7  codex → tests  answer  ↳#6  topic auth                                         16:37 · 7m ago

    Plain text for now. A test will pin it once the spec says otherwise, and the handler returns
    the same body for every 401.

  reply     agentbus --as NAME post --to codex --reply-to 7 "..."

Thread  3                                                                   j/k select · Enter open
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
* #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now















  j/k select · Enter open · y copy · t thread · Esc/q back · ? help
```

```text
[frame message-detail 60x20]
 🚌 agentbus  ~/src/acme-api                    message #7
  🎯 auth on the new token API                    nate · 2h

  #7  codex → tests  💬 answer  ↳#6  topic auth
  16:37 · 7m ago

    Plain text for now. A test will pin it once the spec
    says otherwise, and the handler returns the same body
    for every 401.

  reply     agentbus --as NAME post --to codex --reply-to 7
            "..."

🧵 Thread  3                        j/k select · Enter open
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
* #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now


  j/k select · Enter open · t thread · Esc/q back · ? help
```

```text
[frame message-detail-noemoji 60x20]
 agentbus  ~/src/acme-api                       message #7
  ◆ auth on the new token API                     nate · 2h

  #7  codex → tests  answer  ↳#6  topic auth
  16:37 · 7m ago

    Plain text for now. A test will pin it once the spec
    says otherwise, and the handler returns the same body
    for every 401.

  reply     agentbus --as NAME post --to codex --reply-to 7
            "..."

Thread  3                           j/k select · Enter open
  #6  tests→codex   ask  Is the 401 body part of the …   9m
* #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now


  j/k select · Enter open · t thread · Esc/q back · ? help
```

### Moving inside a detail

On the bus with 209 messages: Enter on #10, then j. #10 answers #9, which is older than the 200 messages watch holds; the detail query loaded it, so it can be selected and opened like any other row.

```text
[frame detail-nav 100x30]
 🚌 agentbus  ~/src/acme-api                                                           message #10
  🎯 auth on the new token API                                                            nate · 2h

  #10  claude → tests  💬 answer  ↳#9  topic auth                                   16:45 · 13m ago

    RS256. The spec draft wins; the old service is going away.

  reply     agentbus --as NAME post --to claude --reply-to 10 "..."

🧵 Thread  4                                                                j/k select · Enter open
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …  23m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …  21m
> #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  14m
* #10  claude → tests           💬 answer    ↳#9 RS256. The spec draft wins; the old service …  13m















  j/k select · Enter open · y copy · t thread · Esc/q back · ? help
```

```text
[frame detail-nav-noemoji 100x30]
 agentbus  ~/src/acme-api                                                              message #10
  ◆ auth on the new token API                                                             nate · 2h

  #10  claude → tests  answer  ↳#9  topic auth                                      16:45 · 13m ago

    RS256. The spec draft wins; the old service is going away.

  reply     agentbus --as NAME post --to claude --reply-to 10 "..."

Thread  4                                                                   j/k select · Enter open
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…  23m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…  21m
> #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  14m
* #10  claude → tests           answer    ↳#9 RS256. The spec draft wins; the old service is …  13m















  j/k select · Enter open · y copy · t thread · Esc/q back · ? help
```

```text
[frame detail-nav 60x20]
 🚌 agentbus  ~/src/acme-api                   message #10
  🎯 auth on the new token API                    nate · 2h

  #10  claude → tests  💬 answer  ↳#9  topic auth
  16:45 · 13m ago

    RS256. The spec draft wins; the old service is going
    away.

  reply     agentbus --as NAME post --to claude --reply-to
            10 "..."

🧵 Thread  4                        j/k select · Enter open
  #6  tests→codex   ❓ ask  Is the 401 body part of t…  23m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…  21m
> #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  14m
* #10 claude→tests  💬 ans  ↳#9 RS256. The spec draft…  13m


  j/k select · Enter open · t thread · Esc/q back · ? help
```

```text
[frame detail-nav-noemoji 60x20]
 agentbus  ~/src/acme-api                      message #10
  ◆ auth on the new token API                     nate · 2h

  #10  claude → tests  answer  ↳#9  topic auth
  16:45 · 13m ago

    RS256. The spec draft wins; the old service is going
    away.

  reply     agentbus --as NAME post --to claude --reply-to
            10 "..."

Thread  4                           j/k select · Enter open
  #6  tests→codex   ask  Is the 401 body part of the …  23m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…  21m
> #9  tests→claude  ask  ↳#7 Which signing algorithm …  14m
* #10 claude→tests  ans  ↳#9 RS256. The spec draft wi…  13m


  j/k select · Enter open · t thread · Esc/q back · ? help
```

### A detail opened from a detail

Enter on #9 from the previous frame: #9 opens on top of #10. The footer says where Esc or q goes back to.

```text
[frame detail-nested 100x30]
 🚌 agentbus  ~/src/acme-api                                                            message #9
  🎯 auth on the new token API                                                            nate · 2h

  #9  tests → claude  ❓ question  ↳#7  topic auth                                  16:44 · 14m ago

    Which signing algorithm should the tokens use? The spec draft says RS256, the old service used
    HS256, and the fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."

🧵 Thread  4                                                                j/k select · Enter open
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …  23m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …  21m
* #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  14m
  #10  claude → tests           💬 answer    ↳#9 RS256. The spec draft wins; the old service …  13m














  j/k select · Enter open · y copy · t thread · Esc/q back to #10 · ? help
```

```text
[frame detail-nested-noemoji 100x30]
 agentbus  ~/src/acme-api                                                               message #9
  ◆ auth on the new token API                                                             nate · 2h

  #9  tests → claude  question  ↳#7  topic auth                                     16:44 · 14m ago

    Which signing algorithm should the tokens use? The spec draft says RS256, the old service used
    HS256, and the fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."

Thread  4                                                                   j/k select · Enter open
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…  23m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…  21m
* #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  14m
  #10  claude → tests           answer    ↳#9 RS256. The spec draft wins; the old service is …  13m














  j/k select · Enter open · y copy · t thread · Esc/q back to #10 · ? help
```

```text
[frame detail-nested 60x20]
 🚌 agentbus  ~/src/acme-api                    message #9
  🎯 auth on the new token API                    nate · 2h

  #9  tests → claude  ❓ question  ↳#7  topic auth
  16:44 · 14m ago

    Which signing algorithm should the tokens use? The spec
    draft says RS256, the old service used HS256, and the
    fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9
            --kind answer "..."

🧵 Thread  4                        j/k select · Enter open
  #6  tests→codex   ❓ ask  Is the 401 body part of t…  23m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…  21m
* #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  14m
  #10 claude→tests  💬 ans  ↳#9 RS256. The spec draft…  13m

  j/k select · Enter open · Esc/q back to #10 · ? help
```

```text
[frame detail-nested-noemoji 60x20]
 agentbus  ~/src/acme-api                       message #9
  ◆ auth on the new token API                     nate · 2h

  #9  tests → claude  question  ↳#7  topic auth
  16:44 · 14m ago

    Which signing algorithm should the tokens use? The spec
    draft says RS256, the old service used HS256, and the
    fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9
            --kind answer "..."

Thread  4                           j/k select · Enter open
  #6  tests→codex   ask  Is the 401 body part of the …  23m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…  21m
* #9  tests→claude  ask  ↳#7 Which signing algorithm …  14m
  #10 claude→tests  ans  ↳#9 RS256. The spec draft wi…  13m

  j/k select · Enter open · Esc/q back to #10 · ? help
```

### Copied

y in a message detail copies the reply command (OSC 52). Some terminals ignore OSC 52, so the footer says what was copied and where it is on screen to select by hand.

```text
[frame copied 100x30]
 🚌 agentbus  ~/src/acme-api                                                            message #9
  🎯 auth on the new token API                                                            nate · 2h

  #9  tests → claude  ❓ question  ↳#7  topic auth                                      16:44 · now

    Which signing algorithm should the tokens use? The spec draft says RS256, the old service used
    HS256, and the fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."

🧵 Thread  3                                                                j/k select · Enter open
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
* #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now















  copied the reply command · if paste fails, select it above
```

```text
[frame copied-noemoji 100x30]
 agentbus  ~/src/acme-api                                                               message #9
  ◆ auth on the new token API                                                             nate · 2h

  #9  tests → claude  question  ↳#7  topic auth                                         16:44 · now

    Which signing algorithm should the tokens use? The spec draft says RS256, the old service used
    HS256, and the fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."

Thread  3                                                                   j/k select · Enter open
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
* #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now















  copied the reply command · if paste fails, select it above
```

```text
[frame copied 60x20]
 🚌 agentbus  ~/src/acme-api                    message #9
  🎯 auth on the new token API                    nate · 2h

  #9  tests → claude  ❓ question  ↳#7  topic auth
  16:44 · now

    Which signing algorithm should the tokens use? The spec
    draft says RS256, the old service used HS256, and the
    fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9
            --kind answer "..."

🧵 Thread  3                        j/k select · Enter open
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
* #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now


  copied the reply command · if paste fails, select it abo…
```

```text
[frame copied-noemoji 60x20]
 agentbus  ~/src/acme-api                       message #9
  ◆ auth on the new token API                     nate · 2h

  #9  tests → claude  question  ↳#7  topic auth
  16:44 · now

    Which signing algorithm should the tokens use? The spec
    draft says RS256, the old service used HS256, and the
    fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9
            --kind answer "..."

Thread  3                           j/k select · Enter open
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
* #9  tests→claude  ask  ↳#7 Which signing algorithm …  now


  copied the reply command · if paste fails, select it abo…
```

### Agent detail

Enter on an agent: its role, when it was last seen, how many messages wait for it, what it holds, and its last 5 messages (sent by it or addressed to it), with the route to the rest. j/k select a claim or a message; Enter opens it.

```text
[frame agent-detail 100x30]
 🚌 agentbus  ~/src/acme-api                                                           agent codex
  🎯 auth on the new token API                                                            nate · 2h

  ○ ✋ codex  implementer
  last seen 16:38, 6m ago · joined 14:41
  2 unread · agentbus --as codex inbox --peek shows them

🔒 Claims  1                                                                j/k select · Enter open
  src/auth/                         codex        1h 59m left · token refactor

💬 Messages  5 of 6                                                                from or to codex
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
  … 1 older · /codex lists them












  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame agent-detail-noemoji 100x30]
 agentbus  ~/src/acme-api                                                              agent codex
  ◆ auth on the new token API                                                             nate · 2h

  ○ codex  implementer
  last seen 16:38, 6m ago · joined 14:41
  2 unread · agentbus --as codex inbox --peek shows them

Claims  1                                                                   j/k select · Enter open
  src/auth/                         codex        1h 59m left · token refactor

Messages  5 of 6                                                                   from or to codex
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
  … 1 older · /codex lists them












  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame agent-detail 60x20]
 🚌 agentbus  ~/src/acme-api                   agent codex
  🎯 auth on the new token API                    nate · 2h

  ○ ✋ codex  implementer
  last seen 16:38, 6m ago · joined 14:41
  2 unread · agentbus --as codex inbox --peek shows them

🔒 Claims  1                        j/k select · Enter open
  src/auth/           codex      1h 59m left

💬 Messages  5 of 6                        from or to codex
  #4  claude→codex  🧭 dec  Keep the refresh path. To…   1h
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  … 1 older · /codex lists them


  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame agent-detail-noemoji 60x20]
 agentbus  ~/src/acme-api                      agent codex
  ◆ auth on the new token API                     nate · 2h

  ○ codex  implementer
  last seen 16:38, 6m ago · joined 14:41
  2 unread · agentbus --as codex inbox --peek shows them

Claims  1                           j/k select · Enter open
  src/auth/           codex      1h 59m left

Messages  5 of 6                           from or to codex
  #4  claude→codex  dec  Keep the refresh path. Token…   1h
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
  … 1 older · /codex lists them


  j/k select · Enter open · y copy · Esc/q back · ? help
```

### Claim detail

Enter on a claim: the whole resource, the holder with the same activity dot as the overview, purpose, when it was taken and when it runs out, and the messages that name it. The holder and the messages are selectable.

```text
[frame claim-detail 100x30]
 🚌 agentbus  ~/src/acme-api                                                       claim src/auth/
  🎯 auth on the new token API                                                            nate · 2h

  claim     src/auth/
> held by   ○ ✋ codex · implementer · seen 6m ago
  purpose   token refactor
  claimed   15:30, 1h ago
  expires   18:43, 1h 59m left

🔗 Mentioned in  2                                                            messages that name it
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m

















  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame claim-detail-noemoji 100x30]
 agentbus  ~/src/acme-api                                                          claim src/auth/
  ◆ auth on the new token API                                                             nate · 2h

  claim     src/auth/
> held by   ○ codex · implementer · seen 6m ago
  purpose   token refactor
  claimed   15:30, 1h ago
  expires   18:43, 1h 59m left

Mentioned in  2                                                               messages that name it
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m

















  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame claim-detail 60x20]
 🚌 agentbus  ~/src/acme-api               claim src/auth/
  🎯 auth on the new token API                    nate · 2h

  claim     src/auth/
> held by   ○ ✋ codex · implementer · seen 6m ago
  purpose   token refactor
  claimed   15:30, 1h ago
  expires   18:43, 1h 59m left

🔗 Mentioned in  2                    messages that name it
  #2  claude→codex  🤝 hand Take src/auth/: swap the …   1h
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m







  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame claim-detail-noemoji 60x20]
 agentbus  ~/src/acme-api                  claim src/auth/
  ◆ auth on the new token API                     nate · 2h

  claim     src/auth/
> held by   ○ codex · implementer · seen 6m ago
  purpose   token refactor
  claimed   15:30, 1h ago
  expires   18:43, 1h 59m left

Mentioned in  2                       messages that name it
  #2  claude→codex  hand Take src/auth/: swap the ses…   1h
  #8  claude→codex  hand Next: the token endpoint in …   1m







  j/k select · Enter open · y copy · Esc/q back · ? help
```

### Fact detail

Enter on a fact: the whole key and value and its history, newest first, each value whole (what `agentbus ctx history KEY` prints).

```text
[frame fact-detail 100x30]
 🚌 agentbus  ~/src/acme-api                                                     fact baseline_sha
  🎯 auth on the new token API                                                            nate · 2h

  key       baseline_sha
  value     abc123
  set by    ○ ✋ codex · implementer · seen 6m ago · set 16:37

📜 History  2                                                                          newest first
  16:37  codex        abc123
  15:02  claude       9f8e7d6



















  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame fact-detail-noemoji 100x30]
 agentbus  ~/src/acme-api                                                        fact baseline_sha
  ◆ auth on the new token API                                                             nate · 2h

  key       baseline_sha
  value     abc123
  set by    ○ codex · implementer · seen 6m ago · set 16:37

History  2                                                                             newest first
  16:37  codex        abc123
  15:02  claude       9f8e7d6



















  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame fact-detail 60x20]
 🚌 agentbus  ~/src/acme-api             fact baseline_sha
  🎯 auth on the new token API                    nate · 2h

  key       baseline_sha
  value     abc123
  set by    ○ ✋ codex · implementer · seen 6m ago
            set 16:37

📜 History  2                                  newest first
  16:37  codex        abc123
  15:02  claude       9f8e7d6








  j/k select · Enter open · y copy · Esc/q back · ? help
```

```text
[frame fact-detail-noemoji 60x20]
 agentbus  ~/src/acme-api                fact baseline_sha
  ◆ auth on the new token API                     nate · 2h

  key       baseline_sha
  value     abc123
  set by    ○ codex · implementer · seen 6m ago · set 16:37

History  2                                     newest first
  16:37  codex        abc123
  15:02  claude       9f8e7d6









  j/k select · Enter open · y copy · Esc/q back · ? help
```

### Help

? from anywhere: every key, mark and word on the screen, in plain words. With emoji on it also explains the emoji. Esc or q closes it; where the page is taller than the terminal, j/k scroll it.

```text
[frame help 100x30]
 🚌 agentbus  ~/src/acme-api                                                                  keys
  watch only reads the bus. It never marks a message read and never changes a claim.

Move
  j k  ↓ ↑        one row                          g G  Home End   first, last row
  PgUp PgDn       one page                         Ctrl-u Ctrl-d   half a page
  Tab  Shift-Tab  next, previous section           1 2 3 4         Agents, Claims, Facts, Messages

Look closer
  Enter           open the selected row; in a detail, open the selected related row
  t               show or hide the thread of an open message
  y               copy the selected id, or in a message its reply command (OSC 52; if paste fails,
                  the footer says where it is on screen)
  /               filter: from:NAME to:NAME kind:KIND topic:NAME, or any words
  p               pause the whole view, or follow again
  r               read the bus now
  Esc  q          back one level: a detail, the filter or this page; q quits from the overview
  Ctrl-C          quit from anywhere

Marks
  ●   seen in the last 5 minutes   ○   quiet for 5 minutes or more  >   selected row
  *   the record open in a detail  ▌   new in the last 3 seconds    🎯  the team's goal
  ↳#6 a reply to message 6         ↵+1 one more line; Enter shows it

Words
  following          the newest messages, as they arrive
  paused at 16:44    the whole view is frozen as it was then; +N new counts what came since
  … N earlier        rows above the window; … N later, … N more: rows not shown
  … 14 more lines · PgDn
  j/k scroll · Esc/q back
```

```text
[frame help-noemoji 100x30]
 agentbus  ~/src/acme-api                                                                     keys
  watch only reads the bus. It never marks a message read and never changes a claim.

Move
  j k  ↓ ↑        one row                          g G  Home End   first, last row
  PgUp PgDn       one page                         Ctrl-u Ctrl-d   half a page
  Tab  Shift-Tab  next, previous section           1 2 3 4         Agents, Claims, Facts, Messages

Look closer
  Enter           open the selected row; in a detail, open the selected related row
  t               show or hide the thread of an open message
  y               copy the selected id, or in a message its reply command (OSC 52; if paste fails,
                  the footer says where it is on screen)
  /               filter: from:NAME to:NAME kind:KIND topic:NAME, or any words
  p               pause the whole view, or follow again
  r               read the bus now
  Esc  q          back one level: a detail, the filter or this page; q quits from the overview
  Ctrl-C          quit from anywhere

Marks
  ●   seen in the last 5 minutes   ○   quiet for 5 minutes or more  >   selected row
  *   the record open in a detail  ▌   new in the last 3 seconds    ◆   the team's goal
  ↳#6 a reply to message 6         ↵+1 one more line; Enter shows it

Words
  following          the newest messages, as they arrive
  paused at 16:44    the whole view is frozen as it was then; +N new counts what came since
  … N earlier        rows above the window; … N later, … N more: rows not shown
  … 10 more lines · PgDn
  j/k scroll · Esc/q back
```

```text
[frame help 60x20]
 🚌 agentbus  ~/src/acme-api                          keys
  watch only reads the bus. It never marks a message read
  and never changes a claim.

Move
  j k  ↓ ↑        one row
  g G  Home End   first, last row
  PgUp PgDn       one page
  Ctrl-u Ctrl-d   half a page
  Tab  Shift-Tab  next, previous section
  1 2 3 4         Agents, Claims, Facts, Messages

Look closer
  Enter           open the selected row; in a detail, open
                  the selected related row
  t               show or hide the thread of an open
                  message
  y               copy the selected id, or in a message its
  … 49 more lines · PgDn
  j/k scroll · Esc/q back
```

```text
[frame help-noemoji 60x20]
 agentbus  ~/src/acme-api                             keys
  watch only reads the bus. It never marks a message read
  and never changes a claim.

Move
  j k  ↓ ↑        one row
  g G  Home End   first, last row
  PgUp PgDn       one page
  Ctrl-u Ctrl-d   half a page
  Tab  Shift-Tab  next, previous section
  1 2 3 4         Agents, Claims, Facts, Messages

Look closer
  Enter           open the selected row; in a detail, open
                  the selected related row
  t               show or hide the thread of an open
                  message
  y               copy the selected id, or in a message its
  … 43 more lines · PgDn
  j/k scroll · Esc/q back
```

### Filter, typing

/ then `kind:ask`: the input sits in the footer and every key is text (q types a q). A kind takes its word or the short code help and the narrow rows show. Sections the filter does not apply to say `n/a` and give their rows to the others. Enter keeps the filter, Esc clears it.

```text
[frame filter 100x30]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  n/a                                                                kind: is for messages

🔒 Claims  n/a                                                                kind: is for messages

📌 Facts  n/a                                                                 kind: is for messages

💬 Messages  2 of 9                                                         following · k to browse
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now

















/kind:ask_                                                                   Enter keep · Esc clear
```

```text
[frame filter-noemoji 100x30]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  n/a                                                                   kind: is for messages

Claims  n/a                                                                   kind: is for messages

Facts  n/a                                                                    kind: is for messages

Messages  2 of 9                                                            following · k to browse
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now

















/kind:ask_                                                                   Enter keep · Esc clear
```

```text
[frame filter 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h

👥 Agents  n/a                        kind: is for messages

🔒 Claims  n/a                        kind: is for messages

📌 Facts  n/a                         kind: is for messages

💬 Messages  2 of 9                 following · k to browse
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now







/kind:ask_                           Enter keep · Esc clear
```

```text
[frame filter-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h

Agents  n/a                           kind: is for messages

Claims  n/a                           kind: is for messages

Facts  n/a                            kind: is for messages

Messages  2 of 9                    following · k to browse
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now







/kind:ask_                           Enter keep · Esc clear
```

### Filter kept

After Enter: the filter stays on (here the word `auth`), the footer shows it, Esc clears it and / edits it. A long filter is cut in the footer, never the keys.

```text
[frame filter-kept 100x30]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  0 of 3                                                                          no match

🔒 Claims  1 of 2
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  0 of 2                                                                           no match

💬 Messages  4 of 9                                                         following · k to browse
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m














  /auth · Esc clear · / edit · j/k move · Enter open · ? help · q quit
```

```text
[frame filter-kept-noemoji 100x30]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  0 of 3                                                                             no match

Claims  1 of 2
  src/auth/                         codex        1h 59m left · token refactor

Facts  0 of 2                                                                              no match

Messages  4 of 9                                                            following · k to browse
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m














  /auth · Esc clear · / edit · j/k move · Enter open · ? help · q quit
```

```text
[frame filter-kept 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h

👥 Agents  0 of 3                                  no match

🔒 Claims  1 of 2
  src/auth/           codex      1h 59m left

📌 Facts  0 of 2                                   no match

💬 Messages  4 of 9                 following · k to browse
  #1  claude→all    📝 note Kickoff: auth moves to th…   1h
  #2  claude→codex  🤝 hand Take src/auth/: swap the …   1h
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m




  /auth · Esc clear · / edit · j/k move · ? help · q quit
```

```text
[frame filter-kept-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h

Agents  0 of 3                                     no match

Claims  1 of 2
  src/auth/           codex      1h 59m left

Facts  0 of 2                                      no match

Messages  4 of 9                    following · k to browse
  #1  claude→all    note Kickoff: auth moves to the n…   1h
  #2  claude→codex  hand Take src/auth/: swap the ses…   1h
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #8  claude→codex  hand Next: the token endpoint in …   1m




  /auth · Esc clear · / edit · j/k move · ? help · q quit
```

### Filter with an unknown kind

A `kind:` that is neither a kind's start nor its code matches nothing and says which kinds exist, on the row above the input; the row stays after Enter.

```text
[frame filter-error 100x30]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  n/a                                                                kind: is for messages

🔒 Claims  n/a                                                                kind: is for messages

📌 Facts  n/a                                                                 kind: is for messages

💬 Messages  0 of 9                                                                        no match

















  kind must be one of: note, question (ask), answer (ans), handoff (hand), decision (dec), alert
  (ALRT), done, todo, dropped (drop)
/kind:fyi_                                                                   Enter keep · Esc clear
```

```text
[frame filter-error-noemoji 100x30]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  n/a                                                                   kind: is for messages

Claims  n/a                                                                   kind: is for messages

Facts  n/a                                                                    kind: is for messages

Messages  0 of 9                                                                           no match

















  kind must be one of: note, question (ask), answer (ans), handoff (hand), decision (dec), alert
  (ALRT), done, todo, dropped (drop)
/kind:fyi_                                                                   Enter keep · Esc clear
```

```text
[frame filter-error 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h

👥 Agents  n/a                        kind: is for messages

🔒 Claims  n/a                        kind: is for messages

📌 Facts  n/a                         kind: is for messages

💬 Messages  0 of 9                                no match






  kind must be one of: note, question (ask), answer (ans),
  handoff (hand), decision (dec), alert (ALRT), done, todo,
  dropped (drop)
/kind:fyi_                           Enter keep · Esc clear
```

```text
[frame filter-error-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h

Agents  n/a                           kind: is for messages

Claims  n/a                           kind: is for messages

Facts  n/a                            kind: is for messages

Messages  0 of 9                                   no match






  kind must be one of: note, question (ask), answer (ans),
  handoff (hand), decision (dec), alert (ALRT), done, todo,
  dropped (drop)
/kind:fyi_                           Enter keep · Esc clear
```

### A filter on a bus bigger than the view

209 messages, of which watch holds the newest 200. `kind:alert` finds none in those 200, and says so: `0 of newest 200`, and the 9 older messages were not searched (`agentbus read` reads them). The header says the same of its counts.

```text
[frame filter-coverage 100x30]
 🚌 agentbus  ~/src/acme-api                                            1 alert · 0 open questions
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  n/a                                                                kind: is for messages

🔒 Claims  n/a                                                                kind: is for messages

📌 Facts  n/a                                                                 kind: is for messages

💬 Messages  0 of newest 200                                                               no match
  … 9 older not searched · agentbus read


















  /kind:alert · Esc clear · / edit · j/k move · Enter open · ? help · q quit
```

```text
[frame filter-coverage-noemoji 100x30]
 agentbus  ~/src/acme-api                                               1 alert · 0 open questions
  ◆ auth on the new token API                                                             nate · 2h

Agents  n/a                                                                   kind: is for messages

Claims  n/a                                                                   kind: is for messages

Facts  n/a                                                                    kind: is for messages

Messages  0 of newest 200                                                                  no match
  … 9 older not searched · agentbus read


















  /kind:alert · Esc clear · / edit · j/k move · Enter open · ? help · q quit
```

```text
[frame filter-coverage 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 0 ask
  🎯 auth on the new token API                    nate · 2h

👥 Agents  n/a                        kind: is for messages

🔒 Claims  n/a                        kind: is for messages

📌 Facts  n/a                         kind: is for messages

💬 Messages  0 of newest 200                       no match
  … 9 older not searched · agentbus read








  /kind:alert · Esc clear · / edit · ? help · q quit
```

```text
[frame filter-coverage-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 0 ask
  ◆ auth on the new token API                     nate · 2h

Agents  n/a                           kind: is for messages

Claims  n/a                           kind: is for messages

Facts  n/a                            kind: is for messages

Messages  0 of newest 200                          no match
  … 9 older not searched · agentbus read








  /kind:alert · Esc clear · / edit · ? help · q quit
```

### Bus busy

Another process holds the bus. watch waits at most 250 ms for it, then keeps the last frame and everything you were doing (here a selected claim) and says how old the frame is. Keys keep working.

```text
[frame busy 100x30]
 🚌 agentbus  ~/src/acme-api                         1 alert · 1 open question · waiting · 27s old
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  3
  ● 🧠 claude           planner         1 unread                                                now
  ○ ✋ codex            implementer     2 unread · holds src/auth/                               6m
  ● 🧪 tests            tester          holds docs/api.md                                       now

🔒 Claims  2                                                                  j/k move · Enter open
  docs/api.md                       tests        42m left
> src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9                                                                            following
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now



  j/k move · Enter open · y copy · Tab section · / filter · ? help · q quit
```

```text
[frame busy-noemoji 100x30]
 agentbus  ~/src/acme-api                            1 alert · 1 open question · waiting · 27s old
  ◆ auth on the new token API                                                             nate · 2h

Agents  3
  ● claude           planner         1 unread                                                   now
  ○ codex            implementer     2 unread · holds src/auth/                                  6m
  ● tests            tester          holds docs/api.md                                          now

Claims  2                                                                     j/k move · Enter open
  docs/api.md                       tests        42m left
> src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9                                                                               following
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now



  j/k move · Enter open · y copy · Tab section · / filter · ? help · q quit
```

```text
[frame busy 60x20]
 🚌 agentbus  …acme-api 1 ALRT · 1 ask · waiting · 27s old
  🎯 auth on the new token API                    nate · 2h
👥 Agents  3
  ● 🧠 claude       planner     1 unread                now
  ○ ✋ codex        implementer 2 unread · holds src/…   6m
  ● 🧪 tests        tester      holds docs/api.md       now
🔒 Claims  2                          j/k move · Enter open
  docs/api.md         tests      42m left
> src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9                                    following
  … 4 earlier
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
  j/k move · Enter open · / filter · ? help · q quit
```

```text
[frame busy-noemoji 60x20]
 agentbus  …rc/acme-api 1 ALRT · 1 ask · waiting · 27s old
  ◆ auth on the new token API                     nate · 2h
Agents  3
  ● claude       planner     1 unread                   now
  ○ codex        implementer 2 unread · holds src/aut…   6m
  ● tests        tester      holds docs/api.md          now
Claims  2                             j/k move · Enter open
  docs/api.md         tests      42m left
> src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9                                       following
  … 4 earlier
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
  j/k move · Enter open · / filter · ? help · q quit
```

### Bus refused

The bus could not be read (here a v0.1.0 bus whose tables differ). The sections are not drawn at all, so nothing stale passes for current. The fix is one command. watch keeps retrying; r retries now; your place comes back with the bus.

```text
[frame error-refused 100x30]
 🚌 agentbus  ~/src/acme-api                                                          not readable

  🚧 This bus could not be read, so the sections are not drawn.
     bus schema is not agentbus's: table messages differs (no column request_id)
     Run: agentbus upgrade ~/src/acme-api

     Retrying every 1s. Last good frame: none. Your place (filter, selection, pause, open detail)
     comes back with the bus.





















  r retry now · ? help · q quit
```

```text
[frame error-refused-noemoji 100x30]
 agentbus  ~/src/acme-api                                                             not readable

  This bus could not be read, so the sections are not drawn.
  bus schema is not agentbus's: table messages differs (no column request_id)
  Run: agentbus upgrade ~/src/acme-api

  Retrying every 1s. Last good frame: none. Your place (filter, selection, pause, open detail)
  comes back with the bus.





















  r retry now · ? help · q quit
```

```text
[frame error-refused 60x20]
 🚌 agentbus  ~/src/acme-api                  not readable

  🚧 This bus could not be read, so the sections are not
     drawn.
     bus schema is not agentbus's: table messages differs
     (no column request_id)
     Run: agentbus upgrade ~/src/acme-api

     Retrying every 1s. Last good frame: none. Your place
     (filter, selection, pause, open detail) comes back
     with the bus.








  r retry now · ? help · q quit
```

```text
[frame error-refused-noemoji 60x20]
 agentbus  ~/src/acme-api                     not readable

  This bus could not be read, so the sections are not
  drawn.
  bus schema is not agentbus's: table messages differs (no
  column request_id)
  Run: agentbus upgrade ~/src/acme-api

  Retrying every 1s. Last good frame: none. Your place
  (filter, selection, pause, open detail) comes back with
  the bus.








  r retry now · ? help · q quit
```

### Bus newer than this watch

The bus was upgraded by a newer agentbus than the one running this watch.

```text
[frame error-newer 100x30]
 🚌 agentbus  ~/src/acme-api                                                          not readable

  🚧 This bus is newer than this watch, so the sections are not drawn.
     bus schema 3 is newer than this agentbus understands (2)
     This watch is agentbus 0.2.0; the bus needs a newer one.
     Run: agentbus upgrade ~/src/acme-api from a newer install

     Retrying every 1s. Last good frame: none. Your place (filter, selection, pause, open detail)
     comes back with the bus.




















  r retry now · ? help · q quit
```

```text
[frame error-newer-noemoji 100x30]
 agentbus  ~/src/acme-api                                                             not readable

  This bus is newer than this watch, so the sections are not drawn.
  bus schema 3 is newer than this agentbus understands (2)
  This watch is agentbus 0.2.0; the bus needs a newer one.
  Run: agentbus upgrade ~/src/acme-api from a newer install

  Retrying every 1s. Last good frame: none. Your place (filter, selection, pause, open detail)
  comes back with the bus.




















  r retry now · ? help · q quit
```

```text
[frame error-newer 60x20]
 🚌 agentbus  ~/src/acme-api                  not readable

  🚧 This bus is newer than this watch, so the sections are
     not drawn.
     bus schema 3 is newer than this agentbus understands
     (2)
     This watch is agentbus 0.2.0; the bus needs a newer
     one.
     Run: agentbus upgrade ~/src/acme-api from a newer
     install

     Retrying every 1s. Last good frame: none. Your place
     (filter, selection, pause, open detail) comes back
     with the bus.





  r retry now · ? help · q quit
```

```text
[frame error-newer-noemoji 60x20]
 agentbus  ~/src/acme-api                     not readable

  This bus is newer than this watch, so the sections are
  not drawn.
  bus schema 3 is newer than this agentbus understands (2)
  This watch is agentbus 0.2.0; the bus needs a newer one.
  Run: agentbus upgrade ~/src/acme-api from a newer install

  Retrying every 1s. Last good frame: none. Your place
  (filter, selection, pause, open detail) comes back with
  the bus.








  r retry now · ? help · q quit
```

### Bus gone

The bus folder was removed while watch was open.

```text
[frame error-nobus 100x30]
 🚌 agentbus  ~/src/acme-api                                                                no bus

  There is no bus here any more, so the sections are not drawn.
  no bus here or in any parent folder
  Run: agentbus init ~/src/acme-api

  Retrying every 1s. Last good frame: 40s ago. Your place (filter, selection, pause, open detail)
  comes back with the bus.





















  r retry now · ? help · q quit
```

```text
[frame error-nobus-noemoji 100x30]
 agentbus  ~/src/acme-api                                                                   no bus

  There is no bus here any more, so the sections are not drawn.
  no bus here or in any parent folder
  Run: agentbus init ~/src/acme-api

  Retrying every 1s. Last good frame: 40s ago. Your place (filter, selection, pause, open detail)
  comes back with the bus.





















  r retry now · ? help · q quit
```

```text
[frame error-nobus 60x20]
 🚌 agentbus  ~/src/acme-api                        no bus

  There is no bus here any more, so the sections are not
  drawn.
  no bus here or in any parent folder
  Run: agentbus init ~/src/acme-api

  Retrying every 1s. Last good frame: 40s ago. Your place
  (filter, selection, pause, open detail) comes back with
  the bus.









  r retry now · ? help · q quit
```

```text
[frame error-nobus-noemoji 60x20]
 agentbus  ~/src/acme-api                           no bus

  There is no bus here any more, so the sections are not
  drawn.
  no bus here or in any parent folder
  Run: agentbus init ~/src/acme-api

  Retrying every 1s. Last good frame: 40s ago. Your place
  (filter, selection, pause, open detail) comes back with
  the bus.









  r retry now · ? help · q quit
```

### Empty bus

A fresh bus: every section says how to fill it (the v0.1.0 lines, kept).

```text
[frame empty-bus 100x30]
 🚌 agentbus  ~/src/acme-api                                           0 alerts · 0 open questions
  🎯 no goal yet · agentbus --as NAME goal "..."

👥 Agents  0
  no one yet. Join with: agentbus --as NAME join

🔒 Claims  0
  nothing claimed

📌 Facts  0
  none yet

💬 Messages  0                                                              following · k to browse
  quiet so far















  k browse · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame empty-bus-noemoji 100x30]
 agentbus  ~/src/acme-api                                              0 alerts · 0 open questions
  ◇ no goal yet · agentbus --as NAME goal "..."

Agents  0
  no one yet. Join with: agentbus --as NAME join

Claims  0
  nothing claimed

Facts  0
  none yet

Messages  0                                                                 following · k to browse
  quiet so far















  k browse · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame empty-bus 60x20]
 🚌 agentbus  ~/src/acme-api                0 ALRT · 0 ask
  🎯 no goal yet · agentbus --as NAME goal "..."

👥 Agents  0
  no one yet. Join with: agentbus --as NAME join

🔒 Claims  0
  nothing claimed

📌 Facts  0
  none yet

💬 Messages  0                      following · k to browse
  quiet so far





  k browse · Enter open · / filter · ? help · q quit
```

```text
[frame empty-bus-noemoji 60x20]
 agentbus  ~/src/acme-api                   0 ALRT · 0 ask
  ◇ no goal yet · agentbus --as NAME goal "..."

Agents  0
  no one yet. Join with: agentbus --as NAME join

Claims  0
  nothing claimed

Facts  0
  none yet

Messages  0                         following · k to browse
  quiet so far





  k browse · Enter open · / filter · ? help · q quit
```

### Running old code

The bus copy on disk was upgraded to 0.2.0 while this watch kept running older code; the Messages title says so, next to the follow state.

```text
[frame stale 100x30]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  3
  ● 🧠 claude           planner         1 unread                                                now
  ○ ✋ codex            implementer     2 unread · holds src/auth/                               6m
  ● 🧪 tests            tester          holds docs/api.md                                       now

🔒 Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9                                          restart for 0.2.0 · following · k to browse
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now



  k browse · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame stale-noemoji 100x30]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  3
  ● claude           planner         1 unread                                                   now
  ○ codex            implementer     2 unread · holds src/auth/                                  6m
  ● tests            tester          holds docs/api.md                                          now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9                                             restart for 0.2.0 · following · k to browse
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now



  k browse · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame stale 60x20]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h
👥 Agents  3
  ● 🧠 claude       planner     1 unread                now
  ○ ✋ codex        implementer 2 unread · holds src/…   6m
  ● 🧪 tests        tester      holds docs/api.md       now
🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9  restart for 0.2.0 · following · k to browse
  … 4 earlier
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
  k browse · Enter open · / filter · ? help · q quit
```

```text
[frame stale-noemoji 60x20]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h
Agents  3
  ● claude       planner     1 unread                   now
  ○ codex        implementer 2 unread · holds src/aut…   6m
  ● tests        tester      holds docs/api.md          now
Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9     restart for 0.2.0 · following · k to browse
  … 4 earlier
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
  k browse · Enter open · / filter · ? help · q quit
```

### ASCII glyphs

`AGENTBUS_ASCII=1`, `TERM=linux`, or a terminal that draws ambiguous-width characters two columns wide: watch's own marks become ASCII (`* o | ... -> re:#6 +1 -`), the goal reads `goal:`, emoji are off and the header is reverse video. Same layout, same meaning.

```text
[frame ascii 100x30]
 agentbus  ~/src/acme-api                                                1 alert - 1 open question
  goal: auth on the new token API                                                         nate - 2h

Agents  3
  * claude           planner         1 unread                                                   now
  o codex            implementer     2 unread - holds src/auth/                                  6m
  * tests            tester          holds docs/api.md                                          now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left - token refactor

Facts  2
  baseline_sha        abc123                                                             codex - 7m
  runtime             python 3.9+                                                      claude - 14m

Messages  9                                                                 following - k to browse
  #1   claude -> everyone       note      Kickoff: auth moves to the new token API today. C...   1h
  #2   claude -> codex          handoff   Take src/auth/: swap the session cookie for the t...   1h
  #3   tests -> everyone        alert     CI on main is red since a1b2c3; hold merges until...   1h
  #4   claude -> codex          decision  Keep the refresh path. Tokens live 7 days and ref...   1h
  #5   codex -> claude          done      Refresh path done, tests green. +1                    11m
  #6   tests -> codex           question  Is the 401 body part of the contract, or can it c...   9m
  #7   codex -> tests           answer    re:#6 Plain text for now. A test will pin it once...   7m
  #8   claude -> codex          handoff   Next: the token endpoint in src/auth/token.py onc...   1m
| #9   tests -> claude          question  re:#7 Which signing algorithm should the tokens u...  now



  k browse - Enter open - / filter - p pause - Tab section - ? help - q quit
```

```text
[frame ascii 60x20]
 agentbus  ~/src/acme-api                   1 ALRT - 1 ask
  goal: auth on the new token API                 nate - 2h
Agents  3
  * claude       planner     1 unread                   now
  o codex        implementer 2 unread - holds src/a...   6m
  * tests        tester      holds docs/api.md          now
Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9                         following - k to browse
  ... 4 earlier
  #5  codex->claude  done Refresh path done, tes... +1  11m
  #6  tests->codex   ask  Is the 401 body part of t...   9m
  #7  codex->tests   ans  re:#6 Plain text for now....   7m
  #8  claude->codex  hand Next: the token endpoint ...   1m
| #9  tests->claude  ask  re:#7 Which signing algor...  now
  k browse - Enter open - / filter - ? help - q quit
```

### ASCII glyphs, message detail

Message 9 in ASCII mode, with its reply command.

```text
[frame ascii-detail 100x30]
 agentbus  ~/src/acme-api                                                               message #9
  goal: auth on the new token API                                                         nate - 2h

  #9  tests -> claude  question  re:#7  topic auth                                      16:44 - now

    Which signing algorithm should the tokens use? The spec draft says RS256, the old service used
    HS256, and the fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9 --kind answer "..."

Thread  3                                                                   j/k select - Enter open
  #6   tests -> codex           question  Is the 401 body part of the contract, or can it c...   9m
  #7   codex -> tests           answer    re:#6 Plain text for now. A test will pin it once...   7m
* #9   tests -> claude          question  re:#7 Which signing algorithm should the tokens u...  now















  j/k select - Enter open - y copy - t thread - Esc/q back - ? help
```

```text
[frame ascii-detail 60x20]
 agentbus  ~/src/acme-api                       message #9
  goal: auth on the new token API                 nate - 2h

  #9  tests -> claude  question  re:#7  topic auth
  16:44 - now

    Which signing algorithm should the tokens use? The spec
    draft says RS256, the old service used HS256, and the
    fixtures need one answer before I write them.

  reply     agentbus --as NAME post --to tests --reply-to 9
            --kind answer "..."

Thread  3                           j/k select - Enter open
  #6  tests->codex   ask  Is the 401 body part of t...   9m
  #7  codex->tests   ans  re:#6 Plain text for now....   7m
* #9  tests->claude  ask  re:#7 Which signing algor...  now


  j/k select - Enter open - t thread - Esc/q back - ? help
```

### ASCII glyphs, help

Help in ASCII mode lists the ASCII marks.

```text
[frame ascii-help 100x30]
 agentbus  ~/src/acme-api                                                                     keys
  watch only reads the bus. It never marks a message read and never changes a claim.

Move
  j k  Down Up    one row                          g G  Home End   first, last row
  PgUp PgDn       one page                         Ctrl-u Ctrl-d   half a page
  Tab  Shift-Tab  next, previous section           1 2 3 4         Agents, Claims, Facts, Messages

Look closer
  Enter           open the selected row; in a detail, open the selected related row
  t               show or hide the thread of an open message
  y               copy the selected id, or in a message its reply command (OSC 52; if paste fails,
                  the footer says where it is on screen)
  /               filter: from:NAME to:NAME kind:KIND topic:NAME, or any words
  p               pause the whole view, or follow again
  r               read the bus now
  Esc  q          back one level: a detail, the filter or this page; q quits from the overview
  Ctrl-C          quit from anywhere

Marks
  *     seen in the last 5 minutes  o     quiet for 5 minutes or more  >     selected row
  *     the record open in a detail  |     new in the last 3 seconds  goal: the team's goal
  re:#6 a reply to message 6       +1    one more line; Enter shows it

Words
  following          the newest messages, as they arrive
  paused at 16:44    the whole view is frozen as it was then; +N new counts what came since
  ... N earlier      rows above the window; ... N later, ... N more: rows not shown
  ... 10 more lines - PgDn
  j/k scroll - Esc/q back
```

```text
[frame ascii-help 60x20]
 agentbus  ~/src/acme-api                             keys
  watch only reads the bus. It never marks a message read
  and never changes a claim.

Move
  j k  Down Up    one row
  g G  Home End   first, last row
  PgUp PgDn       one page
  Ctrl-u Ctrl-d   half a page
  Tab  Shift-Tab  next, previous section
  1 2 3 4         Agents, Claims, Facts, Messages

Look closer
  Enter           open the selected row; in a detail, open
                  the selected related row
  t               show or hide the thread of an open
                  message
  y               copy the selected id, or in a message its
  ... 43 more lines - PgDn
  j/k scroll - Esc/q back
```

### One frame (`--once`, a pipe, or `TERM=dumb`)

Not a terminal, `--once`, or `TERM=dumb`/unset: one frame, content only, no footer, no hints, no escape codes; TERM=dumb also prints `agentbus: TERM=dumb, printing one frame. Use a terminal for the live view.` on stderr. Emoji are off whenever stdout is not a terminal; the emoji variant is what `--once` prints on one.

```text
[frame once 100x26]
 🚌 agentbus  ~/src/acme-api                                             1 alert · 1 open question
  🎯 auth on the new token API                                                            nate · 2h

👥 Agents  3
  ● 🧠 claude           planner         1 unread                                                now
  ○ ✋ codex            implementer     2 unread · holds src/auth/                               6m
  ● 🧪 tests            tester          holds docs/api.md                                       now

🔒 Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now
```

```text
[frame once-noemoji 100x26]
 agentbus  ~/src/acme-api                                                1 alert · 1 open question
  ◆ auth on the new token API                                                             nate · 2h

Agents  3
  ● claude           planner         1 unread                                                   now
  ○ codex            implementer     2 unread · holds src/auth/                                  6m
  ● tests            tester          holds docs/api.md                                          now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now
```

```text
[frame once 60x26]
 🚌 agentbus  ~/src/acme-api                1 ALRT · 1 ask
  🎯 auth on the new token API                    nate · 2h

👥 Agents  3
  ● 🧠 claude       planner     1 unread                now
  ○ ✋ codex        implementer 2 unread · holds src/…   6m
  ● 🧪 tests        tester      holds docs/api.md       now

🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left

📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m

💬 Messages  9
  #1  claude→all    📝 note Kickoff: auth moves to th…   1h
  #2  claude→codex  🤝 hand Take src/auth/: swap the …   1h
  #3  tests→all     🚨 ALRT CI on main is red since a…   1h
  #4  claude→codex  🧭 dec  Keep the refresh path. To…   1h
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
```

```text
[frame once-noemoji 60x26]
 agentbus  ~/src/acme-api                   1 ALRT · 1 ask
  ◆ auth on the new token API                     nate · 2h

Agents  3
  ● claude       planner     1 unread                   now
  ○ codex        implementer 2 unread · holds src/aut…   6m
  ● tests        tester      holds docs/api.md          now

Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left

Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m

Messages  9
  #1  claude→all    note Kickoff: auth moves to the n…   1h
  #2  claude→codex  hand Take src/auth/: swap the ses…   1h
  #3  tests→all     ALRT CI on main is red since a1b2…   1h
  #4  claude→codex  dec  Keep the refresh path. Token…   1h
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
```

### Short sections at 40x16

A section cut to one row still shows its selected row, and its title says how many rows are hidden (never `0 more`). Left: Facts focused with `runtime` selected. Right: Agents focused with `tests` selected.

```text
[frame facts-focus-noemoji 40x16]
 agentbus  …rc/acme-api 1 ALRT · 1 ask
  ◆ auth on the new token API
Agents  3
  ● claude       planner            now
  … 2 more
Claims  2
  docs/api.md    tests      42m left
  src/auth/      codex      1h 59m left
Facts  2         … 1 more · j/k · Enter
> runtime      python 3.9+          14m
Messages  9                   following
  … 6 earlier
  #7  codex→tests   ans  Plain te…   7m
  #8  claude→codex  hand Next: th…   1m
  #9  tests→claude  ask  Which si…  now
  j/k move · ? help · q quit
```

```text
[frame agents-focus-noemoji 40x16]
 agentbus  …rc/acme-api 1 ALRT · 1 ask
  ◆ auth on the new token API
Agents  3         j/k move · Enter open
> ● tests        tester             now
  … 2 more
Claims  2
  docs/api.md    tests      42m left
  src/auth/      codex      1h 59m left
Facts  2                       … 1 more
  baseline_sha abc123                7m
Messages  9                   following
  … 6 earlier
  #7  codex→tests   ans  Plain te…   7m
  #8  claude→codex  hand Next: th…   1m
  #9  tests→claude  ask  Which si…  now
  j/k move · ? help · q quit
```

### Under 40 columns

v0.1.0's one line, kept.

```text
[frame too-narrow 39x8]
watch needs 40+ columns
```
<!-- END states -->

## 2. Layout rules

`W` is the number of columns minus one: the last column always stays free, so a character a terminal draws wider than expected never wraps a row (v0.1.0). Wide means 72 columns or more; narrow is 40 to 71; below 40 the view is the single line above.

Frame, top to bottom: header bar, goal row, Agents, Claims, Facts, Messages, footer. The footer is always the last row.

- **Row shares** (v0.1.0, unchanged): Messages are offered up to `max(3, body_rows // 2)` rows first; Agents, Claims and Facts then get one row each and grow round-robin (`share_rows`); rows they do not need go back to Messages. `body_rows` is the height minus the header, goal, footer, four titles, any blank rows and the filter-error rows.
- **Blank rows** between sections only when the whole frame fits with them, or the screen has 30 rows or more (v0.1.0). That is why 100x30 has them and 60x20 does not.
- **The selection is never hidden.** A section's window is moved only as far as its selected row needs (Agents, Claims and Facts anchor at the top, Messages at the bottom). A section with two or more rows that is cut ends in a dim `… N more` row, where N is every row not shown (above and below); it adds `· agentbus who` (or `claims`, `ctx get`) when some are beyond the 200 the view holds. A section cut to one row shows its selected row (else its first) and its title says `… N more` on the right, before any hint. N is never 0: a section that is not cut has no marker.
- **Messages window**: `… N earlier` above it (with `· agentbus read` when some are older than the 200 held), `… N later` below it when the selection is above the newest rows.
- **Coverage**: watch holds the newest 200 rows per section. A filter on a section that holds fewer than exist says `N of newest 200` and adds a dim `… M older not searched · agentbus read` (or `who`, `claims`, `ctx get`). The header summary is prefixed `newest 200:` in the same case. Detail lists that scan the bus say `in newest 5000` when the bus has more.
- **Header**: ` agentbus  ` (` 🚌 agentbus  ` with emoji), the bus folder cut from the left, and the right-hand text: the summary `1 alert · 1 open question` in the overview (`1 ALRT · 1 ask` narrow), `message #7`, `agent codex`, `claim src/auth/`, `fact baseline_sha`, `keys`, or the error label. While the bus is busy, `waiting · 27s old` follows it (and replaces it when both do not fit). When the folder would get fewer than 8 columns it is dropped, then the 🚌.
- **Goal row**: `  ◆ goal`, then `nate · 2h` right-aligned (🎯 with emoji, `goal:` in ASCII). Narrow and too long: the goal keeps the row and `nate · 2h` is dropped.
- **Title rows**: `Agents  3` (with its icon when emoji are on). The right-hand side, by priority: a one-row section's `… N more`; Messages' follow state (`following · k to browse` when Messages has the focus, else `following`; or `paused at 16:44 · +N new · p or G to follow`, shortened to `paused · +N new · p or G to follow`, `paused · +N new`, then `paused`), preceded by `restart for X.Y.Z · ` when this process runs old code; any other focused section's `j/k move · Enter open` (or `j/k · Enter`, or nothing). A filtered section shows `N of M`; with no match its title row ends in `no match`; a section the filter does not apply to shows `n/a` and `kind: is for messages`; both take no other rows (except the coverage row).
- **Agents row**: mark, dot (`●` seen in the last 5 minutes, in the agent's colour; `○` dim otherwise), role emoji, name (16 wide, 12 narrow), then the role in 16 (12 narrow) and `2 unread · holds src/auth/` (`+N` for more claims) when 8 or more columns are left for it, else the role alone (narrow shows it when 8 or more columns are left); age right-aligned in 5.
- **Claims row**: mark, resource (`max(14, min(36, W // 3))`), holder in its colour (12 wide, 10 narrow), then dim `1h 59m left · purpose` (narrow: `1h 59m left` only).
- **Facts row**: mark, key (wide `max(10, min(24, W // 5))`, narrow `max(12, min(24, W // 4))`), value, then dim `author · age` right-aligned in `min(20, W // 4)` (narrow: the age alone, in 4).
- **Messages row**: column 0 is the mark (`>` selected, `*` the record open in a detail, `▌` in the kind colour for a message under 3 seconds old, else a space); then `#id` (5 wide, 4 narrow), `sender → recipient` in their colours (24 wide with spaces round the arrow; 13 narrow without, 14 in ASCII for the two-character arrow); a broadcast is `everyone` wide and `all` narrow; the kind (wide: the word in 9; narrow: the short code in 4; with emoji, the kind emoji first), `↳#N ` for a reply, the first body line, ` ↵+N` straight after the text when the body has more lines, and the age right-aligned in 4. Narrow rows drop `↳#N` when it would leave the body fewer than 8 columns.
- **Short kind codes**: `hand` handoff, `ask` question, `ans` answer, `done`, `dec` decision, `ALRT` alert, `note`. They are plain text, so a narrow row says its kind with no colour and no emoji, and `kind:` accepts them.
- **Selection**: `>` in column 0 and the whole row in reverse video. Nothing is selected while following; the first k in Messages selects the newest row and pauses.
- **Detail views** keep the header and goal rows, then the content. Nothing in a detail is cut: names, ids, resources, keys, values, history values, the body and the reply command wrap at the row width (labels hang, fields wrap between each other, a word longer than the row is broken). The rows that open something (thread, mentions, an agent's messages and claims) stay one-line summaries, because Enter shows them whole. The related rows are selectable with j/k; the page scrolls to keep the selection on screen, and rows off screen are counted (`… N lines above · PgUp`, `… N more lines · PgDn`). The open message is marked `*`; a detail opens with nothing selected.
- **Detail limits**: a message loads at most 20 ancestors and 20 direct replies. Beyond them: `Thread  41 shown`, `… #6 replies to #5 · open #6 to go further up` above, `… 5 more replies · agentbus read --since 26` below. An agent or claim lists the newest 5 messages, `5 of 6`, then `… 1 older · /codex lists them` (or `· agentbus read` when they are older than the 200 held). A fact shows the newest 20 values, then `… N older · agentbus ctx history KEY`.
- **Times** in detail views are local `HH:MM` today and `Mon D HH:MM` otherwise (v0.1.0's message header rule), followed by the age in words (`7m ago`).
- **Footer**: the keys for the current view, `key word` pairs joined by ` · `: keys bold, words at normal intensity, separators dim. When the row is too short the least important pair is dropped first; `q quit` and `? help` (or `Esc/q back`) go last. In filter input the footer is the input itself: `/`, the text, a `_` cursor, and `Enter keep · Esc clear` on the right, always; a long input scrolls so its end shows (`/…xxxx_`). With a kept filter the footer starts with `/TEXT`, cut so `Esc clear · ? help · q quit` always fit. After `y` the footer says `copied: 9 · if paste fails, select it here` (or `copied the reply command · if paste fails, select it above`) until the next key.
- **Safety** (v0.1.0, unchanged): every string from the bus passes through `clean()` and `fit()`; message bodies in detail pass `clean(newlines=True)` and are then wrapped. No row starts with bus text: rows start with a space, `>`, `*`, `▌` (`|` in ASCII), `/`, or a title agentbus wrote.

## 3. Key map

| Key | Overview | Detail | Help | Filter input |
|---|---|---|---|---|
| `j`, Down | next row in the focused section; nothing in Messages while following | next related row (scroll when there are none) | scroll down | `j` is text; Down ignored |
| `k`, Up | previous row; in Messages while following, selects the newest row and pauses | previous related row (scroll when there are none) | scroll up | `k` is text; Up ignored |
| `g`, Home / `G`, End | first / last row; `G` in Messages follows again | top / bottom | top / bottom | `g`, `G` are text |
| PgUp, PgDn, Ctrl-u, Ctrl-d | page / half page | scroll the page | scroll the page | ignored |
| Tab, Shift-Tab (`ESC [ Z`), `1` to `4` | next / previous section / jump to Agents, Claims, Facts, Messages | none | none | Tab ignored; digits are text |
| Enter | open the selected row (while following in Messages: the newest message) | open the selected related row on top of this one | none | keep the filter, close the input |
| `t` | none | show or hide the thread (message only) | none | text |
| `y` | copy the selected key (message id, agent name, claim resource, fact key) | copy the reply command (message), name, resource or value | none | text |
| `/` | open the filter input (with the kept filter, to edit it) | close every detail, open the input | none | text |
| `p` | pause the whole view, or follow again | none | none | text |
| `r` | read the bus now | read the bus and this detail again | read the bus now | text |
| `?` | help | help | close help | text |
| Esc | clear the kept filter, else nothing | back one level, as it was | back to where you were | clear the text, close the input |
| `q` | quit | back one level | back to where you were | text |
| Ctrl-C | quit | quit | quit | quit |

On a full-screen error (refused, newer, no bus) `r` retries now, `?` opens help and `q` quits. On a busy bus every key works as above.

In the filter input every printable character, including `q`, `j`, `k`, `g`, `p`, `r`, `t`, `y`, `?` and the digits, is text, so `kind:question` can be typed. Backspace deletes. Only Ctrl-C quits. Keys that are not printable (arrows, Tab, PgUp, PgDn, Home, End) are ignored.

Esc no longer quits from the overview (v0.1.0 did). Esc means "back" everywhere else in the view, and a stray Esc must not end a session people leave open. q quits only from the overview: in a detail or help it goes back one level, as in less and man. CHANGELOG lists both under Changed. `watch --help` gains `Keys: j/k move, Tab section, Enter open, / filter, p pause, y copy, ? help, q quit. Read-only.` and `Esc and q go back; q quits from the main view, Esc never quits.`

The selection is held by a stable key (agent name, claim resource, fact key, message id), never by row index, so a refresh never moves it. A selected row that disappears (a claim released, a filter that no longer matches it) moves the selection to the nearest remaining row.

Details stack. Enter on a related row opens it on top; Esc or q pops one level and shows the previous detail exactly as it was (selection and scroll); the footer names where back goes (`Esc/q back to #10`). `/` closes the whole stack. A detail's data is read when it opens and on `r`, not on every tick.

`y` writes OSC 52 (`ESC ] 52 ; c ; BASE64 BEL`) to the terminal and changes nothing in the bus. Some terminals ignore OSC 52 (or need tmux's `set-clipboard on`), so the footer says what was copied and where it is on screen to select by hand.

## 4. Filter

Whitespace-separated tokens; a row is shown when every token matches it. Matching ignores case.

| Token | Agents | Claims | Facts | Messages |
|---|---|---|---|---|
| `from:NAME` | name starts with NAME | holder starts with NAME | author starts with NAME | sender starts with NAME |
| `to:NAME` | n/a | n/a | n/a | recipient starts with NAME; `to:*`, `to:all` and `to:everyone` match broadcasts |
| `kind:KIND` | n/a | n/a | n/a | kind starts with KIND or its code is KIND (`kind:q`, `kind:ask`, `kind:ALRT`) |
| `topic:NAME` | n/a | n/a | n/a | topic starts with NAME |
| a word | in name or role | in resource, holder or purpose | in key, value or author | in id, sender, recipient or body; a broadcast also matches `everyone` and `all` |

`n/a`: a section with any token that does not apply to it is not filtered; its title says `n/a` and `kind: is for messages` (the first such field) and it gives its rows to the others.

A `kind:` that is neither a kind's start nor its code (`kind:fyi`) matches nothing and shows, in red on the rows above the footer, `kind must be one of: note, question (ask), answer (ans), handoff (hand), decision (dec), alert (ALRT), done`. The rows stay while that filter is kept. The filter applies as you type; Enter keeps it (the footer then starts with `/TEXT`), Esc clears it. The goal row is never filtered.

Coverage: the filter searches what watch holds, the newest 200 rows of each section. When a section has more, its count reads `N of newest 200` and a dim row says `… M older not searched · agentbus read`. Detail lists are not filtered.

## 5. Follow and pause

- Following: Messages show the newest rows and nothing is selected. A new message slides in at the bottom with the `▌` bar for 3 seconds. j does nothing in Messages, so the footer says `k browse` and the title `following · k to browse`.
- k (or Up, g, Home, PgUp) in Messages pauses, as does `p`. Pause keeps the snapshot it froze: the loaded records of every section, the selection and the viewport. Nothing a later read brings changes the screen except the count in the title: `paused at 16:44 · +N new · p or G to follow`, in yellow, where N is the messages that arrived since (it may exceed the 200 watch holds; the frozen records stay). Ages and the header summary are as of 16:44. Moving, filtering, opening a detail and resizing all work on the frozen records. With nothing on screen moving, pause is also the reduced-motion mode.
- p or G follows again: the frozen view is replaced by the newest snapshot, the count clears and the selection goes (G) or stays where it still exists (p).
- Older messages: the view holds the newest 200. Older ones are read with `agentbus read`; the `… N earlier · agentbus read` row says so when it applies. There is no paging inside the view.

## 6. Error and edge states

| State | Header right | Body |
|---|---|---|
| `schema_refused`, `schema_older` | `not readable` | `🚧 This bus could not be read, so the sections are not drawn.` (red), the reason (normal), `Run: agentbus upgrade DIR` |
| `schema_newer` | `not readable` | `This bus is newer than this watch, so the sections are not drawn.`, the reason, `This watch is agentbus X.Y.Z; the bus needs a newer one.`, `Run: agentbus upgrade DIR from a newer install` |
| `no_bus` (removed while open) | `no bus` | `There is no bus here any more, so the sections are not drawn.`, the reason, `Run: agentbus init DIR` |
| `busy` | the usual text, then `waiting · 27s old` (yellow on black) | the last frame, unchanged, and every key working |
| empty bus | `0 alerts · 0 open questions` | v0.1.0's empty lines: `no one yet. Join with: agentbus --as NAME join`, `nothing claimed`, `none yet`, `quiet so far`, and the `no goal yet` goal row |
| this process runs older code than the bus copy on disk | the usual header | Messages title right: `restart for 0.2.0 · following` (06 uses `bus_copy_version()` from 01) |
| `TERM=dumb` or unset | none | one frame as `--once`, exit 0, stderr `agentbus: TERM=dumb, printing one frame. Use a terminal for the live view.` |

On a full-screen error the sections are not drawn, so an old frame never passes for a current one; the body ends `Retrying every Ns. Last good frame: none.` (or `40s ago`) `Your place (filter, selection, pause, open detail) comes back with the bus.`, and the footer offers `r retry now`. The reason line is the error's own message from 01 (the `error.message` of the JSON error), cleaned and wrapped, at normal intensity. The `schema_older` row covers a read-only open of an older bus (01); `watch` never migrates.

Busy is not a full screen. watch waits at most 250 ms for the lock, then keeps the frame it has, with all of its state, and adds `waiting · Ns old` to the header, where N is the age of the last good read. Keys keep working on that frame; a detail that needs a read says `waiting` in its header the same way. The view state (mode, focus, selection, scroll, filter, pause, the detail stack) survives every error, busy or full screen.

## 7. Colour, contrast, terminals

| Role | SGR |
|---|---|
| header bar | `30;43` black on yellow, never bold (owner decision 1); `1;7` under `TERM=linux`, `AGENTBUS_ASCII` or an ambiguous-wide terminal |
| `waiting · Ns old` on the bar | `33;40` yellow on black |
| section and detail titles, keys in the footer and help | `1` |
| secondary text: roles, ages, hints, separators, the `… N more` rows | `2` |
| instructions: footer words, error reasons, `Run:` | none (normal intensity) |
| goal mark `◆`/`🎯` | `1;33`; the goal text `1` |
| agent names and dots | `AGENT_COLOURS` in roster order: 34, 36, 35, 32, 33, 94, 96, 95 (no red) |
| kinds and the `▌` bar | `KIND_COLOURS`: handoff 33, question 35, answer 36, done 32, decision 34, alert 31, note dim |
| selected row | `7` over the whole row; colours inside it are dropped so it reads as one bar |
| the open record's `*` and id | `1` |
| `paused`, `restart for` | `33` |
| refused, newer, no bus, filter error | `31` (the headline bold) |
| filter `/` and cursor `_` | `1;33` |

There is no theme switch. `NO_COLOR` (non-empty) turns every SGR off and is the high-contrast path: every meaning is also text (kind words or codes, `>` for the selection, `*` for the open record, `●`/`○`, `paused`, `no match`, `n/a`, `waiting`), so nothing depends on colour or dimming.

- **ASCII glyphs.** `AGENTBUS_ASCII=1`, `TERM=linux` (whose console fonts lack `↳ ↵ ▌`), or a terminal that draws East Asian Ambiguous characters two columns wide (06 probes this once at start: it writes `●` and asks for the cursor position, 100 ms at most) switch watch's own marks to ASCII: `●` `*`, `○` `o`, `▌` `|`, `…` `...`, `·` `-`, `→` `->`, `↳#6` `re:#6`, `↵+1` `+1`, `↓ ↑` `Down Up`, `◆` becomes the word `goal:`. Emoji are off and the header is `1;7`. The layout is the same; every ASCII golden is pure ASCII. Bus text is shown as written.
- Emoji only when stdout is a terminal, its encoding is UTF-8, `AGENTBUS_NO_EMOJI` is unset and ASCII mode is off (v0.1.0). All emoji are single East Asian Wide code points, no variation selectors, so the column arithmetic stays exact.
- Reduced motion: pause (section 5) freezes the whole display. The `▌` bar is the only animation and it is not drawn while paused.
- `TERM=dumb` or unset: no alternate screen, no cursor control, no key reading; one frame (the `once` frame) on stdout and the stderr line above; exit 0.
- SIGTERM and SIGHUP behave like `q` from the overview: restore termios, leave the alternate screen, show the cursor; exit 0 for SIGTERM and 129 for SIGHUP. Each cleanup step runs on its own, so a failing screen write cannot skip the termios restore.

## 8. Performance and responsiveness

These are rules for 06, with tests (`behaviour.json` and the addendum), not hopes.

- **The input loop never waits on SQL.** Reads (the snapshot each tick, a detail on open and on r) run on one reader thread; the loop selects on stdin, the wake pipe and a result pipe. At most one snapshot read is in flight; a tick that finds one running skips. A detail result is applied only if that detail is still open. Key to redraw stays under 100 ms with a read blocked.
- **Lock wait 250 ms.** The read connection's busy timeout is 250 ms (not v0.1.0's 15 s `BUSY_WAIT_S`). On timeout the frame and state stay and the header says `waiting · Ns old`. On quit, the loop calls `Connection.interrupt()` and does not join the reader for more than 50 ms; the connection is read-only, so nothing is left half-written.
- **Detail queries run on open and on `r`**, never on a tick. Each is one read-only open.
- **Bounded scans.** Every detail query reads at most the newest 5000 messages (`WHERE id > (SELECT MAX(id) FROM messages) - 5000`, which uses the primary key), counts its matches, and returns at most 5 rows (`LIMIT 5`; 20 for thread ancestors and replies, 20 for fact history). A list whose scan was cut says `in newest 5000`.
- **Mentions use `instr(body, ?) > 0`**, never `LIKE`: `_` and `%` in `src/my_mod/` are characters, not wildcards.
- **Wrapping is linear and cached** by (text, width): one pass over the characters; a 16 000-character word costs twice an 8 000-character one. A resize recomputes only the widths not cached.
- **The snapshot** stays v0.1.0's one short open per tick, plus the `topic` column and the `unread` counts (a read of `cursors`), both read-only.

## 9. v0.1.0 behaviours that must survive (task 5.1)

Read from `render_watch`, `cmd_watch`, `watch_snapshot` and `tests/test_watch.sh` at v0.1.0:

1. Row shares: Messages first up to `max(3, body_rows // 2)`, the others one row each then round-robin (`share_rows`), leftovers back to Messages.
2. Blank rows only when the frame fits with them or there are 30 rows or more.
3. The spare last column (`width = cols - 1`) and the width rules of `cell_width` (wide 2, combining 0, ambiguous 1; ASCII mode for terminals that draw ambiguous as 2).
4. Every bus string through `clean()` and `fit()`/`fit_left()`; every row starts with agentbus's text (`tests/test_watch.sh` TEST 1 asserts it for the one-frame output).
5. Agent colours in roster order, never red; a CRC fallback past eight agents.
6. The idle dot after 5 minutes; a new message marked for 3 seconds (`▌`, bold body) and its sender's name bold.
7. The header path cut from the left with `~` for HOME.
8. The goal pinned under the header and left out of Facts; `◆`, `◇` and `🎯`.
9. The empty-state lines, word for word.
10. `watch needs 40+ columns` below 40.
11. `--once` and a non-terminal stdout: one frame, content only, the last 20 messages, rows right-stripped, no escape codes, no key hint.
12. `--json`: one snapshot, shape unchanged except added keys (07's `omitted`; this design's `topic` per message and `unread` per agent, addendum R6).
13. Emoji rules (terminal, UTF-8, `AGENTBUS_NO_EMOJI`) and `NO_COLOR`.
14. `--interval` 0.2 to 60 seconds, default 1; the newest 200 rows per section.
15. SIGWINCH redraws at once through the wake pipe; Ctrl-C sets a flag and wakes the loop; SIGINT and SIGWINCH are unblocked at start; arrow keys never quit.
16. A busy or refused read is shown and retried on the next tick; the loop never dies on it.
17. watch never writes: no join, no `last_seen` refresh, cursors unchanged (`tests/test_watch.sh` compares every cursor). Not fully true at v0.1.0: `watch_snapshot` calls the full `open_bus`, which runs setup writes on first open; 01 adds `read_only=True` and 06 uses it for the snapshot and every detail read. `y` writes only to the terminal.

## 10. Golden files, behaviour cases and harness

- `tests/golden/watch/fixture.json`: the `sample`, `empty` and `big` snapshots (the `watch --json` shape plus `topic` and `unread`), the extra detail data (claim times, fact history, and every message the detail queries can read), the kind codes and limits, and one entry per golden: `name`, `cols`, `rows`, `t_now`, `where`, `view`, plus `emoji`, `ascii`, `live` (false for the one-frame output), `snapshot` and `held` (the frozen snapshot of a paused view; `view.frozen.t_now` is its time). `view` carries 06's View fields: `mode`, `focus`, `sel`, `paused`, `frozen`, `filter`, `filter_input`, `detail` (`section`, `key`, `thread`, `sel`, `stack`), `scroll`, `fresh`, `error`, `stale`, `copied`. Times are UTC and frames are rendered with `TZ=UTC`, colour off.
- `tests/golden/watch/<state>-<cols>x<rows>.txt`, and `-emoji` for the emoji frames: one file per frame, rows right-stripped, exactly `rows` lines. Every state at 100x30 and 60x20 with and without emoji and at 80x24 without; `overview`, `section-focus`, `message-detail`, `help` and `error-refused` also at 40x16, 60x24 and 120x40; ASCII states at 100x30, 60x20, 80x24 and 40x16; `once` at its natural height; `facts-focus-40x16`, `agents-focus-40x16`, `too-narrow-39x8`.
- `tests/golden/watch/behaviour.json`: the behaviour cases. `runs: mock` cases run in `python3 docs/design/watch_v2_mock.py --behaviour` today and 06 ports them to `bin/agentbus`'s render; `runs: 06` cases need the live loop and go in `tests/test_watch_keys.sh`.
- `tests/golden/watch/render.py`: the adapter. It loads `bin/agentbus` with `runpy` and renders every entry: with 06's `render` when it exists (06 owns the body of `render_v2` and adapts the call), else with v0.1.0's `render_watch` for default views only. A state it cannot draw is `null`.
- `tests/golden/watch/PENDING`: the goldens the current renderer does not reproduce. Today that is all of them; 06 empties it and asserts it empty.
- `tests/test_watch_golden.sh`: the fixture's sample bus and inventory; height, the free last column, one physical row per line on `tests/term_oracle.py`, no trailing spaces or control characters, rows starting with agentbus's text, ASCII goldens pure ASCII; no em-dash; the goldens, fixture, behaviour cases, doc frames and HTML equal what `docs/design/watch_v2_mock.py` draws (so no golden is edited by hand); `PENDING` exact; the same bytes with HOME and the wall clock changed; `scripts/check_frames.py` passes this doc and fails a too-wide and a too-tall frame; the mock's behaviour cases pass.
- To change a frame: edit `docs/design/watch_v2_mock.py`, run `python3 docs/design/watch_v2_mock.py`, and get the owner's sign-off again.

## 11. Review rounds (task 5.4)

Revision 2 answers two independent reviews (wd-opus, wd-astra); the table at the top is their disposition. The round below was revision 1's own, run inside this lane by the author reading only this doc and the goldens, one lens at a time.

| Lens | Finding | Disposition |
|---|---|---|
| keyboard only | The runbook draft had no frames for agent, claim and fact detail, though Enter opens them | Fixed: `agent-detail`, `claim-detail`, `fact-detail` added |
| keyboard only | How to leave a kept filter was not visible | Fixed: the `filter-kept` footer starts with `/auth · Esc clear · / edit` |
| keyboard only | Enter while following had no defined target | Fixed: opens the newest message (key map) |
| 40 columns, no colour | At 40 columns the header lost its leading space with emoji on | Fixed: the fallback drops the folder, then the 🚌, never the right-hand text |
| 40 columns, no colour | The goal was cut to make room for its author and age | Fixed: narrow rows drop the author and age first |
| 40 columns, no colour | `baseline_sha` cut to `baseline_s…` at 60 columns | Fixed: narrow fact keys get `max(12, W // 4)` since the author column is gone |
| 40 columns, no colour | The filter error was cut mid-word at 60 | Fixed: it wraps onto as many rows as it needs above the input |
| 40 columns, no colour | Every kind is still readable with no colour and no emoji | Checked: each narrow row carries the code (`ask`, `hand`, `ALRT`) |
| never seen it | The paused draft showed the new message while saying `+1 new` | Fixed, and in revision 2 the whole view freezes |
| never seen it | `… 4 earlier · agentbus read` suggested leaving the view for rows k can reach | Fixed: `· agentbus read` only for rows beyond the 200 held |
| never seen it | The draft overview at 80x24 drew blank rows the v0.1.0 rule does not allow | Fixed: every frame comes from the rules, at every size |
| never seen it | Help did not explain the emoji | Fixed: help lists the kind and role emoji when emoji are on |
| never seen it | `message 7 of 9` in the header read like a page count | Changed to `message #7` |

## 12. Changes from the runbook draft (for the brain to fold into #7)

- More states: `agent-detail`, `claim-detail`, `fact-detail`, `filter-kept`, `filter-error`, `filter-coverage`, `pause-rollover`, `detail-nav`, `detail-nested`, `copied`, `busy` (replacing `error-busy`), `error-nobus`, `stale`, `ascii`, `ascii-detail`, `ascii-help`, `once`, `too-narrow`, and the 40x16 section frames.
- More sizes: 100x30 and 60x20 with and without emoji (the owner's request), on top of the runbook's 80x24 and the 40x16, 60x24 and 120x40 set. The runbook's shorter draft heights (80x12, 80x10) became full 80x24 frames.
- Emoji goldens (`-emoji`), so the frames the owner signs are pinned with their emoji, not only without.
- Fixture entries carry `emoji`, `ascii`, `live`, `snapshot` and `held` besides the listed fields; `view` carries `frozen`, `filter_input`, `detail`, `scroll`, `fresh` and `copied`. `pending` is gone: the renderer counts it from the frozen and current snapshots.
- A sample bus whose times agree with each other (an agent that posted a minute ago is not shown idle); codex is the idle agent. A big bus (209 messages) for coverage and rollover.
- A generated-artifact check (`watch_v2_mock.py --check`) and the mock's behaviour cases in the harness, and a free-last-column check per row.
- Revision 2's build rules are in `docs/design/watch-v2-build-addendum.md`; 06 follows it where it differs from the 06 runbook.
