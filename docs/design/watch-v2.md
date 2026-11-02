# agentbus watch v2: the design

Issue #7 (workstream 05). Status: **proposal, waiting for the owner's sign-off**. Nothing in `bin/agentbus` changes until it is approved; 06 then builds to these frames character for character.

How to read it:

- `docs/design/watch-v2.html` shows every frame below in colour on a dark terminal, with a NO_COLOR switch. It is the quickest read.
- Every frame here is the exact text. Colour only adds SGR codes; it never adds, removes or moves a character, so the text you see is also the no-colour rendering.
- Each state is shown at 100x30 and 60x20, with emoji (what a UTF-8 terminal shows) and without (`AGENTBUS_NO_EMOJI=1`, a non-UTF-8 terminal, or any non-terminal). Trailing blank rows are left out here; the golden files keep them.
- The sample bus is the same everywhere: 3 agents, 2 claims, 2 facts, 9 messages and a goal, at 16:44 UTC on 2026-11-01, in `~/src/acme-api`. The frames are drawn by `docs/design/watch_v2_mock.py` from `tests/golden/watch/fixture.json`, so the columns are exact.

## Decisions for the owner

One at a time, recommended answer first. Each has a fallback that only changes colour or a glyph, not the layout.

1. **Header bar in bus yellow** (bold black on yellow, SGR `1;30;43`) instead of v0.1.0's reverse video (`1;7`). It ties the view to the yellow bus in the README art and marks the top of the screen at a glance. Fallback: `1;7`.
2. **🚌 before `agentbus` in the header when emoji are on.** One glyph, the project's mascot; it costs 3 columns and is the first thing dropped below 72 columns when the header is tight. Fallback: no glyph.
3. **Three new section icons for the detail views:** 🧵 Thread, 📜 History, 🔗 Mentioned in, plus one icon per error state (🚧 refused or newer, ⏳ busy, 🌱 no bus). Same rule as v0.1.0's icons: single wide code points, shown only with emoji on. Fallback: titles without icons in detail and error views.
4. **A filter that leaves a section empty collapses it to its title row** (`Agents  0 of 3 ... no match`), so the matching messages get the rows. The runbook draft gave each empty section a `no match` row. Fallback: the draft's extra row.
5. **Claim detail lists the messages that name the claim** (`Mentioned in`, the last 5 whose body contains the resource). It answers "why is this claimed?" without leaving the view; 06 needs one bounded read-only query. Fallback: drop the list.
6. **Narrow rows (40 to 71 columns) show both the kind emoji and the short code** (`🤝 hand`). Emoji alone would give the body 5 more columns at 40, but you would have to learn seven emoji to read a row. Fallback: emoji alone when emoji are on, code alone otherwise.
7. **Esc no longer quits from the overview** (already decided in the runbook; listed under Changed in CHANGELOG). Shown here so the sign-off covers it.

## What changes from v0.1.0, in one list

- Browse: Tab and 1 to 4 move the focus between Agents, Claims, Facts and Messages; j/k move a `>` selection; g/G, PgUp/PgDn and Ctrl-u/Ctrl-d jump.
- Inspect: Enter opens any row. A message shows its whole body and its thread; an agent its claims and last messages; a claim its holder, times and mentions; a fact its value and history.
- Filter: `/` with `from:`, `to:`, `kind:` and plain words; counts read `N of M`.
- Read in peace: k in Messages pauses the stream; new messages are counted, not drawn; p or G follows again.
- Learn in place: a footer that names the keys for the current view, and `?` for every key and mark.
- Honest failures: a bus that cannot be read gets a full-screen explanation and the fix, never a frame of empty sections.
- The rest is v0.1.0's: the sections, their order, the row shares, the blank-row rule, escaping, the emoji tables, the colours of agents and kinds.

## 1. States and frames

### Overview, following

<!-- BEGIN frames overview -->
What opens. Everything at a glance: the pinned goal, who is here, what is claimed, the shared facts and the newest messages. Messages follow the stream (`following`); message 9 arrived in the last 3 seconds, so it carries the `▌` bar in its kind colour and a bold body. The footer teaches the keys.

```text
[frame overview 100x30]
 🚌 agentbus  ~/src/acme-api                                      3 agents · 2 claims · 9 messages
  🎯 auth on the new token API                                                          · nate · 2h

👥 Agents  3
  ● 🧠 claude           planner                                                                 now
  ○ ✋ codex            implementer                                                              6m
  ● 🧪 tests            tester                                                                  now

🔒 Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

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
▌ #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now



  j/k move · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame overview-noemoji 100x30]
 agentbus  ~/src/acme-api                                         3 agents · 2 claims · 9 messages
  ◆ auth on the new token API                                                           · nate · 2h

Agents  3
  ● claude           planner                                                                    now
  ○ codex            implementer                                                                 6m
  ● tests            tester                                                                     now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

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
▌ #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now



  j/k move · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame overview 60x20]
 🚌 agentbus  ~/src/acme-api  3 agents · 2 claims · 9 msgs
  🎯 auth on the new token API                  · nate · 2h
👥 Agents  3
  ● 🧠 claude       planner                             now
  ○ ✋ codex        implementer                          6m
  ● 🧪 tests        tester                              now
🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9                                    following
  … 4 earlier
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
▌ #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
  j/k move · Enter open · / filter · ? help · q quit
```

```text
[frame overview-noemoji 60x20]
 agentbus  ~/src/acme-api     3 agents · 2 claims · 9 msgs
  ◆ auth on the new token API                   · nate · 2h
Agents  3
  ● claude       planner                                now
  ○ codex        implementer                             6m
  ● tests        tester                                 now
Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9                                       following
  … 4 earlier
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
▌ #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
  j/k move · Enter open · / filter · ? help · q quit
```
<!-- END frames overview -->

### A section focused, a row selected

<!-- BEGIN frames section-focus -->
After Tab, Tab, j: Claims has the focus, so its title says `j/k move · Enter open`, and `src/auth/` is selected (`>` and reverse video). Messages keep following underneath.

```text
[frame section-focus 100x30]
 🚌 agentbus  ~/src/acme-api                                      3 agents · 2 claims · 9 messages
  🎯 auth on the new token API                                                          · nate · 2h

👥 Agents  3
  ● 🧠 claude           planner                                                                 now
  ○ ✋ codex            implementer                                                              6m
  ● 🧪 tests            tester                                                                  now

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



  j/k move · Enter open · Tab next section · / filter · ? help · q quit
```

```text
[frame section-focus-noemoji 100x30]
 agentbus  ~/src/acme-api                                         3 agents · 2 claims · 9 messages
  ◆ auth on the new token API                                                           · nate · 2h

Agents  3
  ● claude           planner                                                                    now
  ○ codex            implementer                                                                 6m
  ● tests            tester                                                                     now

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



  j/k move · Enter open · Tab next section · / filter · ? help · q quit
```

```text
[frame section-focus 60x20]
 🚌 agentbus  ~/src/acme-api  3 agents · 2 claims · 9 msgs
  🎯 auth on the new token API                  · nate · 2h
👥 Agents  3
  ● 🧠 claude       planner                             now
  ○ ✋ codex        implementer                          6m
  ● 🧪 tests        tester                              now
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
 agentbus  ~/src/acme-api     3 agents · 2 claims · 9 msgs
  ◆ auth on the new token API                   · nate · 2h
Agents  3
  ● claude       planner                                now
  ○ codex        implementer                             6m
  ● tests        tester                                 now
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
<!-- END frames section-focus -->

### Messages paused

<!-- BEGIN frames messages-paused -->
After k in Messages: the stream stops so you can read. A message that arrives while paused is counted (`+1 new`) and does not move the view; p or G follows again. Agents, claims and facts keep refreshing.

```text
[frame messages-paused 100x30]
 🚌 agentbus  ~/src/acme-api                                      3 agents · 2 claims · 9 messages
  🎯 auth on the new token API                                                          · nate · 2h

👥 Agents  3
  ● 🧠 claude           planner                                                                 now
  ○ ✋ codex            implementer                                                              6m
  ● 🧪 tests            tester                                                                  now

🔒 Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9                                                   paused · +1 new · p or G to follow
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
> #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m




  j/k move · Enter open · p follow · g/G top/bottom · / filter · ? help · q quit
```

```text
[frame messages-paused-noemoji 100x30]
 agentbus  ~/src/acme-api                                         3 agents · 2 claims · 9 messages
  ◆ auth on the new token API                                                           · nate · 2h

Agents  3
  ● claude           planner                                                                    now
  ○ codex            implementer                                                                 6m
  ● tests            tester                                                                     now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9                                                      paused · +1 new · p or G to follow
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
> #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m




  j/k move · Enter open · p follow · g/G top/bottom · / filter · ? help · q quit
```

```text
[frame messages-paused 60x20]
 🚌 agentbus  ~/src/acme-api  3 agents · 2 claims · 9 msgs
  🎯 auth on the new token API                  · nate · 2h
👥 Agents  3
  ● 🧠 claude       planner                             now
  ○ ✋ codex        implementer                          6m
  ● 🧪 tests        tester                              now
🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9           paused · +1 new · p or G to follow
  … 3 earlier
  #4  claude→codex  🧭 dec  Keep the refresh path. To…   1h
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
> #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  j/k move · Enter open · p follow · ? help · q quit
```

```text
[frame messages-paused-noemoji 60x20]
 agentbus  ~/src/acme-api     3 agents · 2 claims · 9 msgs
  ◆ auth on the new token API                   · nate · 2h
Agents  3
  ● claude       planner                                now
  ○ codex        implementer                             6m
  ● tests        tester                                 now
Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9              paused · +1 new · p or G to follow
  … 3 earlier
  #4  claude→codex  dec  Keep the refresh path. Token…   1h
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
> #8  claude→codex  hand Next: the token endpoint in …   1m
  j/k move · Enter open · p follow · ? help · q quit
```
<!-- END frames messages-paused -->

### Message detail with its thread

<!-- BEGIN frames message-detail -->
Enter on message 7: the whole body, wrapped, never cut, and the thread (the messages it replies to and the replies to it). t hides the thread; Esc goes back to exactly the frame you left.

```text
[frame message-detail 100x30]
 🚌 agentbus  ~/src/acme-api                                                            message #7
  🎯 auth on the new token API                                                          · nate · 2h

  #7  codex → tests  💬 answer  ↳ re #6                                              16:37 · 7m ago

    Plain text for now. A test will pin it once the spec says otherwise, and the handler returns
    the same body for every 401.

🧵 Thread  3                                                                             t hides it
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
> #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now

















  j/k scroll · t thread · Esc back · ? help · q quit
```

```text
[frame message-detail-noemoji 100x30]
 agentbus  ~/src/acme-api                                                               message #7
  ◆ auth on the new token API                                                           · nate · 2h

  #7  codex → tests  answer  ↳ re #6                                                 16:37 · 7m ago

    Plain text for now. A test will pin it once the spec says otherwise, and the handler returns
    the same body for every 401.

Thread  3                                                                                t hides it
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
> #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now

















  j/k scroll · t thread · Esc back · ? help · q quit
```

```text
[frame message-detail 60x20]
 🚌 agentbus  ~/src/acme-api                    message #7
  🎯 auth on the new token API                  · nate · 2h

  #7  codex → tests  💬 answer  ↳ re #6      16:37 · 7m ago

    Plain text for now. A test will pin it once the spec
    says otherwise, and the handler returns the same body
    for every 401.

🧵 Thread  3                                     t hides it
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
> #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now






  j/k scroll · t thread · Esc back · ? help · q quit
```

```text
[frame message-detail-noemoji 60x20]
 agentbus  ~/src/acme-api                       message #7
  ◆ auth on the new token API                   · nate · 2h

  #7  codex → tests  answer  ↳ re #6         16:37 · 7m ago

    Plain text for now. A test will pin it once the spec
    says otherwise, and the handler returns the same body
    for every 401.

Thread  3                                        t hides it
  #6  tests→codex   ask  Is the 401 body part of the …   9m
> #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now






  j/k scroll · t thread · Esc back · ? help · q quit
```
<!-- END frames message-detail -->

### Agent detail

<!-- BEGIN frames agent-detail -->
Enter on an agent: its role, when it was last seen, what it holds, and its last 5 messages (sent by it or addressed to it).

```text
[frame agent-detail 100x30]
 🚌 agentbus  ~/src/acme-api                                                                 agent
  🎯 auth on the new token API                                                          · nate · 2h

  ○ ✋ codex  implementer
  last seen 16:38, 6m ago · joined 14:41

🔒 Claims  1
  src/auth/                         codex        1h 59m left · token refactor

💬 Messages  5 of 6                                                                from or to codex
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m














  j/k scroll · Esc back · ? help · q quit
```

```text
[frame agent-detail-noemoji 100x30]
 agentbus  ~/src/acme-api                                                                    agent
  ◆ auth on the new token API                                                           · nate · 2h

  ○ codex  implementer
  last seen 16:38, 6m ago · joined 14:41

Claims  1
  src/auth/                         codex        1h 59m left · token refactor

Messages  5 of 6                                                                   from or to codex
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m














  j/k scroll · Esc back · ? help · q quit
```

```text
[frame agent-detail 60x20]
 🚌 agentbus  ~/src/acme-api                         agent
  🎯 auth on the new token API                  · nate · 2h

  ○ ✋ codex  implementer
  last seen 16:38, 6m ago · joined 14:41

🔒 Claims  1
  src/auth/           codex      1h 59m left

💬 Messages  5 of 6                        from or to codex
  #4  claude→codex  🧭 dec  Keep the refresh path. To…   1h
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m




  j/k scroll · Esc back · ? help · q quit
```

```text
[frame agent-detail-noemoji 60x20]
 agentbus  ~/src/acme-api                            agent
  ◆ auth on the new token API                   · nate · 2h

  ○ codex  implementer
  last seen 16:38, 6m ago · joined 14:41

Claims  1
  src/auth/           codex      1h 59m left

Messages  5 of 6                           from or to codex
  #4  claude→codex  dec  Keep the refresh path. Token…   1h
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m




  j/k scroll · Esc back · ? help · q quit
```
<!-- END frames agent-detail -->

### Claim detail

<!-- BEGIN frames claim-detail -->
Enter on a claim: holder, purpose, when it was taken and when it runs out, and the messages that name it.

```text
[frame claim-detail 100x30]
 🚌 agentbus  ~/src/acme-api                                                                 claim
  🎯 auth on the new token API                                                          · nate · 2h

  claim     src/auth/
  held by   ● ✋ codex · implementer
  purpose   token refactor
  claimed   15:30, 1h ago
  expires   18:43, 1h 59m left

🔗 Mentioned in  2                                                            messages that name it
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m

















  j/k scroll · Esc back · ? help · q quit
```

```text
[frame claim-detail-noemoji 100x30]
 agentbus  ~/src/acme-api                                                                    claim
  ◆ auth on the new token API                                                           · nate · 2h

  claim     src/auth/
  held by   ● codex · implementer
  purpose   token refactor
  claimed   15:30, 1h ago
  expires   18:43, 1h 59m left

Mentioned in  2                                                               messages that name it
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m

















  j/k scroll · Esc back · ? help · q quit
```

```text
[frame claim-detail 60x20]
 🚌 agentbus  ~/src/acme-api                         claim
  🎯 auth on the new token API                  · nate · 2h

  claim     src/auth/
  held by   ● ✋ codex · implementer
  purpose   token refactor
  claimed   15:30, 1h ago
  expires   18:43, 1h 59m left

🔗 Mentioned in  2                    messages that name it
  #2  claude→codex  🤝 hand Take src/auth/: swap the …   1h
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m







  j/k scroll · Esc back · ? help · q quit
```

```text
[frame claim-detail-noemoji 60x20]
 agentbus  ~/src/acme-api                            claim
  ◆ auth on the new token API                   · nate · 2h

  claim     src/auth/
  held by   ● codex · implementer
  purpose   token refactor
  claimed   15:30, 1h ago
  expires   18:43, 1h 59m left

Mentioned in  2                       messages that name it
  #2  claude→codex  hand Take src/auth/: swap the ses…   1h
  #8  claude→codex  hand Next: the token endpoint in …   1m







  j/k scroll · Esc back · ? help · q quit
```
<!-- END frames claim-detail -->

### Fact detail

<!-- BEGIN frames fact-detail -->
Enter on a fact: the whole value and its history, newest first (what `agentbus ctx history KEY` prints).

```text
[frame fact-detail 100x30]
 🚌 agentbus  ~/src/acme-api                                                                  fact
  🎯 auth on the new token API                                                          · nate · 2h

  key       baseline_sha
  value     abc123
  set by    codex, 16:37, 7m ago

📜 History  2                                                                          newest first
  16:37  codex        abc123
  15:02  claude       9f8e7d6



















  j/k scroll · Esc back · ? help · q quit
```

```text
[frame fact-detail-noemoji 100x30]
 agentbus  ~/src/acme-api                                                                     fact
  ◆ auth on the new token API                                                           · nate · 2h

  key       baseline_sha
  value     abc123
  set by    codex, 16:37, 7m ago

History  2                                                                             newest first
  16:37  codex        abc123
  15:02  claude       9f8e7d6



















  j/k scroll · Esc back · ? help · q quit
```

```text
[frame fact-detail 60x20]
 🚌 agentbus  ~/src/acme-api                          fact
  🎯 auth on the new token API                  · nate · 2h

  key       baseline_sha
  value     abc123
  set by    codex, 16:37, 7m ago

📜 History  2                                  newest first
  16:37  codex        abc123
  15:02  claude       9f8e7d6









  j/k scroll · Esc back · ? help · q quit
```

```text
[frame fact-detail-noemoji 60x20]
 agentbus  ~/src/acme-api                             fact
  ◆ auth on the new token API                   · nate · 2h

  key       baseline_sha
  value     abc123
  set by    codex, 16:37, 7m ago

History  2                                     newest first
  16:37  codex        abc123
  15:02  claude       9f8e7d6









  j/k scroll · Esc back · ? help · q quit
```
<!-- END frames fact-detail -->

### Help

<!-- BEGIN frames help -->
? from anywhere: every key and every mark, in plain words. With emoji on it also explains the emoji. Esc closes it. Where the page is taller than the terminal, j/k scroll it.

```text
[frame help 100x30]
 🚌 agentbus  ~/src/acme-api                                                                  keys
  watch only reads the bus. It never marks a message read and never changes a claim.

Move
  j k  ↓ ↑        one row                          g G  Home End   first, last row
  PgUp PgDn       one page                         Ctrl-u Ctrl-d   half a page
  Tab  Shift-Tab  next, previous section           1 2 3 4         Agents, Claims, Facts, Messages

Look closer
  Enter           open the selected row; a message opens with its thread
  t               show or hide the thread of an open message
  /               filter: from:NAME to:NAME kind:KIND, or any words
  p               pause the messages, or follow them again
  r               read the bus now
  Esc             back: closes a detail, the filter or this page
  q  Ctrl-C       quit (Esc never quits)

Marks
  ●   seen in the last 5 minutes   ○   quiet for 5 minutes or more  >   selected row
  ▌   new in the last 3 seconds    🎯  the team's goal              ↳#6 a reply to message 6
  ↵+1 one more line; Enter shows it

Kinds  the short form is used under 72 columns
  🤝 hand handoff   ❓ ask question   💬 ans answer   ✅ done   🧭 dec decision   🚨 ALRT alert
  📝 note

Roles  matched on words in the role
  🧠 brain, lead, planner   ✋ hand, implementer   🧪 tests   🔍 review   📚 docs   🚀 ops, release
  🎨 design   🙋 human   🤖 anyone else
  j/k scroll · Esc back · q quit
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
  Enter           open the selected row; a message opens with its thread
  t               show or hide the thread of an open message
  /               filter: from:NAME to:NAME kind:KIND, or any words
  p               pause the messages, or follow them again
  r               read the bus now
  Esc             back: closes a detail, the filter or this page
  q  Ctrl-C       quit (Esc never quits)

Marks
  ●   seen in the last 5 minutes   ○   quiet for 5 minutes or more  >   selected row
  ▌   new in the last 3 seconds    ◆   the team's goal              ↳#6 a reply to message 6
  ↵+1 one more line; Enter shows it

Kinds  the short form is used under 72 columns
  hand handoff   ask question   ans answer   done   dec decision   ALRT alert   note





  j/k scroll · Esc back · q quit
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
  Enter           open the selected row; a message opens
                  with its thread
  t               show or hide the thread of an open
                  message
  /               filter: from:NAME to:NAME kind:KIND, or
  … 24 more lines · j to scroll
  j/k scroll · Esc back · q quit
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
  Enter           open the selected row; a message opens
                  with its thread
  t               show or hide the thread of an open
                  message
  /               filter: from:NAME to:NAME kind:KIND, or
  … 19 more lines · j to scroll
  j/k scroll · Esc back · q quit
```
<!-- END frames help -->

### Filter, typing

<!-- BEGIN frames filter -->
/ then `kind:question`: the input sits in the footer and every key is text (q types a q). Sections narrow as you type and say `N of M`; a section with nothing left says `no match` on its title row and gives its rows to the others. Enter keeps the filter, Esc clears it.

```text
[frame filter 100x30]
 🚌 agentbus  ~/src/acme-api                                      3 agents · 2 claims · 9 messages
  🎯 auth on the new token API                                                          · nate · 2h

👥 Agents  0 of 3                                                                          no match

🔒 Claims  0 of 2                                                                          no match

📌 Facts  0 of 2                                                                           no match

💬 Messages  2 of 9                                                                       following
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now

















/kind:question_                                                              Enter keep · Esc clear
```

```text
[frame filter-noemoji 100x30]
 agentbus  ~/src/acme-api                                         3 agents · 2 claims · 9 messages
  ◆ auth on the new token API                                                           · nate · 2h

Agents  0 of 3                                                                             no match

Claims  0 of 2                                                                             no match

Facts  0 of 2                                                                              no match

Messages  2 of 9                                                                          following
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now

















/kind:question_                                                              Enter keep · Esc clear
```

```text
[frame filter 60x20]
 🚌 agentbus  ~/src/acme-api  3 agents · 2 claims · 9 msgs
  🎯 auth on the new token API                  · nate · 2h

👥 Agents  0 of 3                                  no match

🔒 Claims  0 of 2                                  no match

📌 Facts  0 of 2                                   no match

💬 Messages  2 of 9                               following
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now







/kind:question_                      Enter keep · Esc clear
```

```text
[frame filter-noemoji 60x20]
 agentbus  ~/src/acme-api     3 agents · 2 claims · 9 msgs
  ◆ auth on the new token API                   · nate · 2h

Agents  0 of 3                                     no match

Claims  0 of 2                                     no match

Facts  0 of 2                                      no match

Messages  2 of 9                                  following
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now







/kind:question_                      Enter keep · Esc clear
```
<!-- END frames filter -->

### Filter kept

<!-- BEGIN frames filter-kept -->
After Enter: the filter stays on (here the word `auth`), the footer shows it, Esc clears it and / edits it.

```text
[frame filter-kept 100x30]
 🚌 agentbus  ~/src/acme-api                                      3 agents · 2 claims · 9 messages
  🎯 auth on the new token API                                                          · nate · 2h

👥 Agents  0 of 3                                                                          no match

🔒 Claims  1 of 2
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  0 of 2                                                                           no match

💬 Messages  4 of 9                                                                       following
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m














  /auth · Esc clear · / edit · j/k move · Enter open · ? help · q quit
```

```text
[frame filter-kept-noemoji 100x30]
 agentbus  ~/src/acme-api                                         3 agents · 2 claims · 9 messages
  ◆ auth on the new token API                                                           · nate · 2h

Agents  0 of 3                                                                             no match

Claims  1 of 2
  src/auth/                         codex        1h 59m left · token refactor

Facts  0 of 2                                                                              no match

Messages  4 of 9                                                                          following
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m














  /auth · Esc clear · / edit · j/k move · Enter open · ? help · q quit
```

```text
[frame filter-kept 60x20]
 🚌 agentbus  ~/src/acme-api  3 agents · 2 claims · 9 msgs
  🎯 auth on the new token API                  · nate · 2h

👥 Agents  0 of 3                                  no match

🔒 Claims  1 of 2
  src/auth/           codex      1h 59m left

📌 Facts  0 of 2                                   no match

💬 Messages  4 of 9                               following
  #1  claude→every… 📝 note Kickoff: auth moves to th…   1h
  #2  claude→codex  🤝 hand Take src/auth/: swap the …   1h
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m




  /auth · Esc clear · / edit · j/k move · ? help · q quit
```

```text
[frame filter-kept-noemoji 60x20]
 agentbus  ~/src/acme-api     3 agents · 2 claims · 9 msgs
  ◆ auth on the new token API                   · nate · 2h

Agents  0 of 3                                     no match

Claims  1 of 2
  src/auth/           codex      1h 59m left

Facts  0 of 2                                      no match

Messages  4 of 9                                  following
  #1  claude→every… note Kickoff: auth moves to the n…   1h
  #2  claude→codex  hand Take src/auth/: swap the ses…   1h
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #8  claude→codex  hand Next: the token endpoint in …   1m




  /auth · Esc clear · / edit · j/k move · ? help · q quit
```
<!-- END frames filter-kept -->

### Filter with an unknown kind

<!-- BEGIN frames filter-error -->
A `kind:` no kind starts with matches nothing and says which kinds exist, on the row above the input.

```text
[frame filter-error 100x30]
 🚌 agentbus  ~/src/acme-api                                      3 agents · 2 claims · 9 messages
  🎯 auth on the new token API                                                          · nate · 2h

👥 Agents  0 of 3                                                                          no match

🔒 Claims  0 of 2                                                                          no match

📌 Facts  0 of 2                                                                           no match

💬 Messages  0 of 9                                                                        no match


















  kind must be one of: note, question, answer, handoff, decision, alert, done
/kind:fyi_                                                                   Enter keep · Esc clear
```

```text
[frame filter-error-noemoji 100x30]
 agentbus  ~/src/acme-api                                         3 agents · 2 claims · 9 messages
  ◆ auth on the new token API                                                           · nate · 2h

Agents  0 of 3                                                                             no match

Claims  0 of 2                                                                             no match

Facts  0 of 2                                                                              no match

Messages  0 of 9                                                                           no match


















  kind must be one of: note, question, answer, handoff, decision, alert, done
/kind:fyi_                                                                   Enter keep · Esc clear
```

```text
[frame filter-error 60x20]
 🚌 agentbus  ~/src/acme-api  3 agents · 2 claims · 9 msgs
  🎯 auth on the new token API                  · nate · 2h

👥 Agents  0 of 3                                  no match

🔒 Claims  0 of 2                                  no match

📌 Facts  0 of 2                                   no match

💬 Messages  0 of 9                                no match







  kind must be one of: note, question, answer, handoff,
  decision, alert, done
/kind:fyi_                           Enter keep · Esc clear
```

```text
[frame filter-error-noemoji 60x20]
 agentbus  ~/src/acme-api     3 agents · 2 claims · 9 msgs
  ◆ auth on the new token API                   · nate · 2h

Agents  0 of 3                                     no match

Claims  0 of 2                                     no match

Facts  0 of 2                                      no match

Messages  0 of 9                                   no match







  kind must be one of: note, question, answer, handoff,
  decision, alert, done
/kind:fyi_                           Enter keep · Esc clear
```
<!-- END frames filter-error -->

### Bus refused

<!-- BEGIN frames error-refused -->
The bus could not be read (here a v0.1.0 bus whose tables differ). The sections are not drawn at all, so nothing stale passes for current. The fix is one command. watch keeps retrying; r retries now.

```text
[frame error-refused 100x30]
 🚌 agentbus  ~/src/acme-api                                                          not readable

  🚧 This bus could not be read, so the sections are not drawn.
     bus schema is not agentbus's: table messages differs (no column request_id)
     Run: agentbus upgrade ~/src/acme-api

     Retrying every 1s. Last good frame: none.






















  r retry now · ? help · q quit
```

```text
[frame error-refused-noemoji 100x30]
 agentbus  ~/src/acme-api                                                             not readable

  This bus could not be read, so the sections are not drawn.
  bus schema is not agentbus's: table messages differs (no column request_id)
  Run: agentbus upgrade ~/src/acme-api

  Retrying every 1s. Last good frame: none.






















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

     Retrying every 1s. Last good frame: none.










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

  Retrying every 1s. Last good frame: none.










  r retry now · ? help · q quit
```
<!-- END frames error-refused -->

### Bus newer than this watch

<!-- BEGIN frames error-newer -->
The bus was upgraded by a newer agentbus than the one running this watch.

```text
[frame error-newer 100x30]
 🚌 agentbus  ~/src/acme-api                                                          not readable

  🚧 This bus is newer than this watch, so the sections are not drawn.
     bus schema 3 is newer than this agentbus understands (2)
     This watch is agentbus 0.2.0; the bus needs a newer one.
     Run: agentbus upgrade ~/src/acme-api from a newer install

     Retrying every 1s. Last good frame: none.





















  r retry now · ? help · q quit
```

```text
[frame error-newer-noemoji 100x30]
 agentbus  ~/src/acme-api                                                             not readable

  This bus is newer than this watch, so the sections are not drawn.
  bus schema 3 is newer than this agentbus understands (2)
  This watch is agentbus 0.2.0; the bus needs a newer one.
  Run: agentbus upgrade ~/src/acme-api from a newer install

  Retrying every 1s. Last good frame: none.





















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

     Retrying every 1s. Last good frame: none.







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

  Retrying every 1s. Last good frame: none.










  r retry now · ? help · q quit
```
<!-- END frames error-newer -->

### Bus busy

<!-- BEGIN frames error-busy -->
Another process held the bus past the 15 s wait. Not an error in the bus, so yellow, not red.

```text
[frame error-busy 100x30]
 🚌 agentbus  ~/src/acme-api                                                               waiting

  ⏳ Another process holds the bus. Retrying every 1s.
     the bus stayed locked for 15s

     Last good frame: 12s ago.























  r retry now · ? help · q quit
```

```text
[frame error-busy-noemoji 100x30]
 agentbus  ~/src/acme-api                                                                  waiting

  Another process holds the bus. Retrying every 1s.
  the bus stayed locked for 15s

  Last good frame: 12s ago.























  r retry now · ? help · q quit
```

```text
[frame error-busy 60x20]
 🚌 agentbus  ~/src/acme-api                       waiting

  ⏳ Another process holds the bus. Retrying every 1s.
     the bus stayed locked for 15s

     Last good frame: 12s ago.













  r retry now · ? help · q quit
```

```text
[frame error-busy-noemoji 60x20]
 agentbus  ~/src/acme-api                          waiting

  Another process holds the bus. Retrying every 1s.
  the bus stayed locked for 15s

  Last good frame: 12s ago.













  r retry now · ? help · q quit
```
<!-- END frames error-busy -->

### Bus gone

<!-- BEGIN frames error-nobus -->
The bus folder was removed while watch was open.

```text
[frame error-nobus 100x30]
 🚌 agentbus  ~/src/acme-api                                                                no bus

  🌱 There is no bus here any more, so the sections are not drawn.
     no bus here or in any parent folder
     Run: agentbus init ~/src/acme-api

     Retrying every 1s. Last good frame: 40s ago.






















  r retry now · ? help · q quit
```

```text
[frame error-nobus-noemoji 100x30]
 agentbus  ~/src/acme-api                                                                   no bus

  There is no bus here any more, so the sections are not drawn.
  no bus here or in any parent folder
  Run: agentbus init ~/src/acme-api

  Retrying every 1s. Last good frame: 40s ago.






















  r retry now · ? help · q quit
```

```text
[frame error-nobus 60x20]
 🚌 agentbus  ~/src/acme-api                        no bus

  🌱 There is no bus here any more, so the sections are not
     drawn.
     no bus here or in any parent folder
     Run: agentbus init ~/src/acme-api

     Retrying every 1s. Last good frame: 40s ago.











  r retry now · ? help · q quit
```

```text
[frame error-nobus-noemoji 60x20]
 agentbus  ~/src/acme-api                           no bus

  There is no bus here any more, so the sections are not
  drawn.
  no bus here or in any parent folder
  Run: agentbus init ~/src/acme-api

  Retrying every 1s. Last good frame: 40s ago.











  r retry now · ? help · q quit
```
<!-- END frames error-nobus -->

### Empty bus

<!-- BEGIN frames empty-bus -->
A fresh bus: every section says how to fill it (the v0.1.0 lines, kept).

```text
[frame empty-bus 100x30]
 🚌 agentbus  ~/src/acme-api                                      0 agents · 0 claims · 0 messages
  🎯 no goal yet · agentbus --as NAME goal "..."

👥 Agents  0
  no one yet. Join with: agentbus --as NAME join

🔒 Claims  0
  nothing claimed

📌 Facts  0
  none yet

💬 Messages  0                                                                            following
  quiet so far















  j/k move · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame empty-bus-noemoji 100x30]
 agentbus  ~/src/acme-api                                         0 agents · 0 claims · 0 messages
  ◇ no goal yet · agentbus --as NAME goal "..."

Agents  0
  no one yet. Join with: agentbus --as NAME join

Claims  0
  nothing claimed

Facts  0
  none yet

Messages  0                                                                               following
  quiet so far















  j/k move · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame empty-bus 60x20]
 🚌 agentbus  ~/src/acme-api  0 agents · 0 claims · 0 msgs
  🎯 no goal yet · agentbus --as NAME goal "..."

👥 Agents  0
  no one yet. Join with: agentbus --as NAME join

🔒 Claims  0
  nothing claimed

📌 Facts  0
  none yet

💬 Messages  0                                    following
  quiet so far





  j/k move · Enter open · / filter · ? help · q quit
```

```text
[frame empty-bus-noemoji 60x20]
 agentbus  ~/src/acme-api     0 agents · 0 claims · 0 msgs
  ◇ no goal yet · agentbus --as NAME goal "..."

Agents  0
  no one yet. Join with: agentbus --as NAME join

Claims  0
  nothing claimed

Facts  0
  none yet

Messages  0                                       following
  quiet so far





  j/k move · Enter open · / filter · ? help · q quit
```
<!-- END frames empty-bus -->

### Running old code

<!-- BEGIN frames stale -->
The bus copy on disk was upgraded to 0.2.0 while this watch kept running older code; the Messages title says so, next to the follow state.

```text
[frame stale 100x30]
 🚌 agentbus  ~/src/acme-api                                      3 agents · 2 claims · 9 messages
  🎯 auth on the new token API                                                          · nate · 2h

👥 Agents  3
  ● 🧠 claude           planner                                                                 now
  ○ ✋ codex            implementer                                                              6m
  ● 🧪 tests            tester                                                                  now

🔒 Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

📌 Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

💬 Messages  9                                                        restart for 0.2.0 · following
  #1   claude → everyone        📝 note      Kickoff: auth moves to the new token API today. …   1h
  #2   claude → codex           🤝 handoff   Take src/auth/: swap the session cookie for the …   1h
  #3   tests → everyone         🚨 alert     CI on main is red since a1b2c3; hold merges unti…   1h
  #4   claude → codex           🧭 decision  Keep the refresh path. Tokens live 7 days and re…   1h
  #5   codex → claude           ✅ done      Refresh path done, tests green. ↵+1                11m
  #6   tests → codex            ❓ question  Is the 401 body part of the contract, or can it …   9m
  #7   codex → tests            💬 answer    ↳#6 Plain text for now. A test will pin it once …   7m
  #8   claude → codex           🤝 handoff   Next: the token endpoint in src/auth/token.py on…   1m
  #9   tests → claude           ❓ question  ↳#7 Which signing algorithm should the tokens us…  now



  j/k move · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame stale-noemoji 100x30]
 agentbus  ~/src/acme-api                                         3 agents · 2 claims · 9 messages
  ◆ auth on the new token API                                                           · nate · 2h

Agents  3
  ● claude           planner                                                                    now
  ○ codex            implementer                                                                 6m
  ● tests            tester                                                                     now

Claims  2
  docs/api.md                       tests        42m left
  src/auth/                         codex        1h 59m left · token refactor

Facts  2
  baseline_sha        abc123                                                             codex · 7m
  runtime             python 3.9+                                                      claude · 14m

Messages  9                                                           restart for 0.2.0 · following
  #1   claude → everyone        note      Kickoff: auth moves to the new token API today. Cla…   1h
  #2   claude → codex           handoff   Take src/auth/: swap the session cookie for the tok…   1h
  #3   tests → everyone         alert     CI on main is red since a1b2c3; hold merges until t…   1h
  #4   claude → codex           decision  Keep the refresh path. Tokens live 7 days and refre…   1h
  #5   codex → claude           done      Refresh path done, tests green. ↵+1                   11m
  #6   tests → codex            question  Is the 401 body part of the contract, or can it cha…   9m
  #7   codex → tests            answer    ↳#6 Plain text for now. A test will pin it once the…   7m
  #8   claude → codex           handoff   Next: the token endpoint in src/auth/token.py once …   1m
  #9   tests → claude           question  ↳#7 Which signing algorithm should the tokens use? …  now



  j/k move · Enter open · / filter · p pause · Tab section · ? help · q quit
```

```text
[frame stale 60x20]
 🚌 agentbus  ~/src/acme-api  3 agents · 2 claims · 9 msgs
  🎯 auth on the new token API                  · nate · 2h
👥 Agents  3
  ● 🧠 claude       planner                             now
  ○ ✋ codex        implementer                          6m
  ● 🧪 tests        tester                              now
🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
💬 Messages  9                restart for 0.2.0 · following
  … 4 earlier
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
  j/k move · Enter open · / filter · ? help · q quit
```

```text
[frame stale-noemoji 60x20]
 agentbus  ~/src/acme-api     3 agents · 2 claims · 9 msgs
  ◆ auth on the new token API                   · nate · 2h
Agents  3
  ● claude       planner                                now
  ○ codex        implementer                             6m
  ● tests        tester                                 now
Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left
Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m
Messages  9                   restart for 0.2.0 · following
  … 4 earlier
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
  j/k move · Enter open · / filter · ? help · q quit
```
<!-- END frames stale -->

### One frame (`--once`, a pipe, or `TERM=dumb`)

<!-- BEGIN frames once -->
Not a terminal, `--once`, or `TERM=dumb`/unset: one frame, content only, no footer, no hints, no escape codes; TERM=dumb also prints `agentbus: TERM=dumb, printing one frame. Use a terminal for the live view.` on stderr. Emoji are off whenever stdout is not a terminal; the emoji variant is what `--once` prints on one.

```text
[frame once 100x26]
 🚌 agentbus  ~/src/acme-api                                      3 agents · 2 claims · 9 messages
  🎯 auth on the new token API                                                          · nate · 2h

👥 Agents  3
  ● 🧠 claude           planner                                                                 now
  ○ ✋ codex            implementer                                                              6m
  ● 🧪 tests            tester                                                                  now

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
 agentbus  ~/src/acme-api                                         3 agents · 2 claims · 9 messages
  ◆ auth on the new token API                                                           · nate · 2h

Agents  3
  ● claude           planner                                                                    now
  ○ codex            implementer                                                                 6m
  ● tests            tester                                                                     now

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
 🚌 agentbus  ~/src/acme-api  3 agents · 2 claims · 9 msgs
  🎯 auth on the new token API                  · nate · 2h

👥 Agents  3
  ● 🧠 claude       planner                             now
  ○ ✋ codex        implementer                          6m
  ● 🧪 tests        tester                              now

🔒 Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left

📌 Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m

💬 Messages  9
  #1  claude→every… 📝 note Kickoff: auth moves to th…   1h
  #2  claude→codex  🤝 hand Take src/auth/: swap the …   1h
  #3  tests→every…  🚨 ALRT CI on main is red since a…   1h
  #4  claude→codex  🧭 dec  Keep the refresh path. To…   1h
  #5  codex→claude  ✅ done Refresh path done, te… ↵+1  11m
  #6  tests→codex   ❓ ask  Is the 401 body part of t…   9m
  #7  codex→tests   💬 ans  ↳#6 Plain text for now. A…   7m
  #8  claude→codex  🤝 hand Next: the token endpoint …   1m
  #9  tests→claude  ❓ ask  ↳#7 Which signing algorit…  now
```

```text
[frame once-noemoji 60x26]
 agentbus  ~/src/acme-api     3 agents · 2 claims · 9 msgs
  ◆ auth on the new token API                   · nate · 2h

Agents  3
  ● claude       planner                                now
  ○ codex        implementer                             6m
  ● tests        tester                                 now

Claims  2
  docs/api.md         tests      42m left
  src/auth/           codex      1h 59m left

Facts  2
  baseline_sha   abc123                                  7m
  runtime        python 3.9+                            14m

Messages  9
  #1  claude→every… note Kickoff: auth moves to the n…   1h
  #2  claude→codex  hand Take src/auth/: swap the ses…   1h
  #3  tests→every…  ALRT CI on main is red since a1b2…   1h
  #4  claude→codex  dec  Keep the refresh path. Token…   1h
  #5  codex→claude  done Refresh path done, tests… ↵+1  11m
  #6  tests→codex   ask  Is the 401 body part of the …   9m
  #7  codex→tests   ans  ↳#6 Plain text for now. A te…   7m
  #8  claude→codex  hand Next: the token endpoint in …   1m
  #9  tests→claude  ask  ↳#7 Which signing algorithm …  now
```
<!-- END frames once -->

### Under 40 columns

v0.1.0's one line, kept.

<!-- BEGIN frames too-narrow -->
```text
[frame too-narrow 39x8]
watch needs 40+ columns
```
<!-- END frames too-narrow -->

## 2. Layout rules

`W` is the number of columns minus one: the last column always stays free, so a character a terminal draws wider than expected never wraps a row (v0.1.0). Wide means 72 columns or more; narrow is 40 to 71; below 40 the view is the single line above.

Frame, top to bottom: header bar, goal row, Agents, Claims, Facts, Messages, footer. The footer is always the last row.

- **Row shares** (v0.1.0, unchanged): Messages are offered up to `max(3, body_rows // 2)` rows first; Agents, Claims and Facts then get one row each and grow round-robin (`share_rows`); rows they do not need go back to Messages. `body_rows` is the height minus the header, goal, footer, four titles and any blank rows.
- **Blank rows** between sections only when the whole frame fits with them, or the screen has 30 rows or more (v0.1.0). That is why 100x30 has them and 60x20 does not.
- **A section cut short** ends in a dim `… N more` row; it adds `· agentbus who` (or `claims`, `ctx get`) only when the rest is beyond the 200 rows the view holds. Messages say `… N earlier` above the window, with `· agentbus read` only when some of those are older than the 200 the view holds.
- **Header**: ` agentbus  ` (` 🚌 agentbus  ` with emoji), the bus folder cut from the left, and the right-hand text: `3 agents · 2 claims · 9 messages` in the overview (`msgs` when narrow), `message #7`, `agent`, `claim`, `fact`, `keys`, or the error label. When the folder would get fewer than 8 columns it is dropped, then the 🚌.
- **Goal row**: `  ◆ goal · who · age` (🎯 with emoji), as v0.1.0. Narrow and too long: the goal keeps the row and `· who · age` is dropped.
- **Title rows**: `Agents  3` (with its icon when emoji are on). The right-hand side is, by priority: Messages always show the follow state (`following`, or `paused · +N new · p or G to follow`, shortened to `paused · +N new` and then `paused` when the row is short), preceded by `restart for X.Y.Z · ` when this process runs old code. Any other focused section shows `j/k move · Enter open` (or `j/k · Enter`, or nothing). A filtered section shows `N of M`; with no match its title row ends in `no match` and it takes no other rows.
- **Agents row**: mark, dot (`●` seen in the last 5 minutes, in the agent's colour; `○` dim otherwise), role emoji, name (16 wide, 12 narrow), role (dim; narrow shows it when 8 or more columns are left), age right-aligned in 5.
- **Claims row**: mark, resource (`max(14, min(36, W // 3))`), holder in its colour (12 wide, 10 narrow), then dim `1h 59m left · purpose` (narrow: `1h 59m left` only).
- **Facts row**: mark, key (wide `max(10, min(24, W // 5))`, narrow `max(12, min(24, W // 4))`), value, then dim `author · age` right-aligned in `min(20, W // 4)` (narrow: the age alone, in 4).
- **Messages row**: column 0 is the mark (`>` selected, `▌` in the kind colour for a message under 3 seconds old, else a space); then `#id` (5 wide, 4 narrow), `sender → recipient` in their colours (24 wide with spaces round the arrow, 13 narrow without), the kind (wide: the word in 9; narrow: the short code in 4; with emoji, the kind emoji first), `↳#N ` for a reply, the first body line, ` ↵+N` straight after the text when the body has more lines, and the age right-aligned in 4. Narrow rows drop `↳#N` when it would leave the body fewer than 8 columns.
- **Short kind codes**: `hand` handoff, `ask` question, `ans` answer, `done`, `dec` decision, `ALRT` alert, `note`. They are plain text, so a narrow row says its kind with no colour and no emoji.
- **Selection**: `>` in column 0 and the whole row in reverse video. Nothing is selected while following; the first k in Messages selects the newest row and pauses.
- **Detail views** keep the header and goal rows, then the content, scrolled by j/k when taller than the screen (a dim `… N more lines · j to scroll` row says so). Bodies and values are wrapped at the row width, never cut; a word longer than the row is broken. Bodies are indented 4, everything else 2.
- **Times** in detail views are local `HH:MM` today and `Mon D HH:MM` otherwise (v0.1.0's message header rule), followed by the age in words (`7m ago`).
- **Footer**: the keys for the current view, `key word` pairs joined by ` · `, keys bold and words dim. When the row is too short the least important pair is dropped first; `q quit` and `? help` (or `Esc back`) go last. In filter input the footer is the input itself: `/`, the text, a `_` cursor, and `Enter keep · Esc clear` on the right.
- **Safety** (v0.1.0, unchanged): every string from the bus passes through `clean()` and `fit()`; message bodies in detail pass `clean(newlines=True)` and are then wrapped. No row starts with bus text: rows start with a space, `>`, `▌`, `/`, or a title agentbus wrote.

## 3. Key map

| Key | Overview | Detail | Help | Filter input |
|---|---|---|---|---|
| `j`, Down | next row in the focused section | scroll down | scroll down | `j` is text; Down ignored |
| `k`, Up | previous row; in Messages while following, selects the newest row and pauses | scroll up | scroll up | `k` is text; Up ignored |
| `g`, Home / `G`, End | first / last row; `G` in Messages follows again | top / bottom | top / bottom | `g`, `G` are text |
| PgUp, PgDn, Ctrl-u, Ctrl-d | page / half page | page / half page | page / half page | ignored |
| Tab, Shift-Tab (`ESC [ Z`), `1` to `4` | next / previous section / jump to Agents, Claims, Facts, Messages | none | none | Tab ignored; digits are text |
| Enter | open the selected row (while following in Messages: the newest message) | none | none | keep the filter, close the input |
| `t` | none | show or hide the thread (message only) | none | text |
| `/` | open the filter input (with the kept filter, to edit it) | close the detail, open the input | none | text |
| `p` | pause, or follow again | none | none | text |
| `r` | read the bus now | read the bus now | read the bus now | text |
| `?` | help | help | close help | text |
| Esc | clear the kept filter, else nothing | back to the overview, as it was | back to where you were | clear the text, close the input |
| `q` | quit | quit | quit | text |
| Ctrl-C | quit | quit | quit | quit |

In the filter input every printable character, including `q`, `j`, `k`, `g`, `p`, `r`, `t`, `?` and the digits, is text, so `kind:question` can be typed. Backspace deletes. Only Ctrl-C quits. Keys that are not printable (arrows, Tab, PgUp, PgDn, Home, End) are ignored.

Esc no longer quits from the overview (v0.1.0 did). Esc means "back" everywhere else in the view, and a stray Esc must not end a session people leave open. CHANGELOG lists it under Changed. `watch --help` gains `Keys: j/k move, Tab section, Enter open, / filter, p pause, ? help, q quit. Read-only.` and `Esc goes back; it no longer quits from the main view.`

The selection is held by a stable key (agent name, claim resource, fact key, message id), never by row index, so a refresh never moves it. A selected row that disappears (a claim released, a filter that no longer matches it) moves the selection to the nearest remaining row.

## 4. Filter

Whitespace-separated tokens; a row is shown when every token matches it. Matching ignores case.

| Token | Agents | Claims | Facts | Messages |
|---|---|---|---|---|
| `from:NAME` | name starts with NAME | holder starts with NAME | author starts with NAME | sender starts with NAME |
| `to:NAME` | no match | no match | no match | recipient starts with NAME; `to:*` and `to:everyone` match broadcasts |
| `kind:KIND` | no match | no match | no match | kind starts with KIND (`kind:q` is question) |
| a word | in name or role | in resource, holder or purpose | in key, value or author | in id, sender, recipient or body |

A `kind:` that no kind starts with (`kind:fyi`) matches nothing and shows, in red on the row above the input, `kind must be one of: note, question, answer, handoff, decision, alert, done`. The filter applies as you type; Enter keeps it (the footer then starts with `/TEXT`), Esc clears it. The goal row is never filtered.

## 5. Follow and pause

- Following: Messages show the newest rows and nothing is selected. A new message slides in at the bottom with the `▌` bar for 3 seconds.
- k (or Up, g, Home, PgUp) in Messages pauses. The title says `paused · +N new · p or G to follow` in yellow. While paused, the message list is frozen at the last message shown; new messages are counted, not drawn, and the view does not move. Agents, Claims and Facts keep refreshing.
- p or G follows again: the list jumps to the newest message and the count clears. p on a following view pauses without selecting.
- Older messages: the view holds the newest 200. Older ones are read with `agentbus read`; the `… N earlier · agentbus read` row says so when it applies. There is no paging inside the view.

## 6. Error and edge states

| State | Header right | Body |
|---|---|---|
| `schema_refused`, `schema_older` | `not readable` | `🚧 This bus could not be read, so the sections are not drawn.` (red), the reason (dim), `Run: agentbus upgrade DIR` |
| `schema_newer` | `not readable` | `This bus is newer than this watch, so the sections are not drawn.`, the reason, `This watch is agentbus X.Y.Z; the bus needs a newer one.`, `Run: agentbus upgrade DIR from a newer install` |
| `busy` | `waiting` | `⏳ Another process holds the bus. Retrying every Ns.` (yellow), the reason |
| `no_bus` (removed while open) | `no bus` | `🌱 There is no bus here any more, so the sections are not drawn.`, `Run: agentbus init DIR` |
| empty bus | the usual header | v0.1.0's empty lines: `no one yet. Join with: agentbus --as NAME join`, `nothing claimed`, `none yet`, `quiet so far`, and the `no goal yet` goal row |
| this process runs older code than the bus copy on disk | the usual header | Messages title right: `restart for 0.2.0 · following` (06 uses `bus_copy_version()` from 01) |
| `TERM=dumb` or unset | none | one frame as `--once`, exit 0, stderr `agentbus: TERM=dumb, printing one frame. Use a terminal for the live view.` |

On every error the sections are not drawn, so an old frame never passes for a current one; the body ends `Retrying every Ns. Last good frame: none.` or `Last good frame: 12s ago.`, and the footer offers `r retry now`. The reason line is the error's own message from 01 (the `error.message` of the JSON error), cleaned and wrapped. The `schema_older` row covers a read-only open of an older bus (01); `watch` never migrates.

## 7. Colour, contrast, terminals

| Role | SGR |
|---|---|
| header bar | `1;30;43` bold black on yellow (owner decision 1; fallback `1;7`) |
| section and detail titles, keys in the footer and help | `1` |
| secondary text: roles, ages, hints, reasons, footer words | `2` |
| goal mark `◆`/`🎯` | `1;33`; the goal text `1` |
| agent names and dots | `AGENT_COLOURS` in roster order: 34, 36, 35, 32, 33, 94, 96, 95 (no red) |
| kinds and the `▌` bar | `KIND_COLOURS`: handoff 33, question 35, answer 36, done 32, decision 34, alert 31, note dim |
| selected row | `7` over the whole row; colours inside it are dropped so it reads as one bar |
| `paused`, `restart for`, busy | `33` |
| refused, newer, no bus, filter error | `31` (the headline bold) |
| filter `/` and cursor `_` | `1;33` |

There is no theme switch. `NO_COLOR` (non-empty) turns every SGR off and is the high-contrast path: every meaning is also text (kind words or codes, `>` for the selection, `●`/`○`, `paused`, `no match`), so nothing depends on colour or dimming.

- Emoji only when stdout is a terminal, its encoding is UTF-8 and `AGENTBUS_NO_EMOJI` is unset (v0.1.0). All emoji are single East Asian Wide code points, no variation selectors, so the column arithmetic stays exact.
- `TERM=dumb` or unset: no alternate screen, no cursor control, no key reading; one frame (the `once` frame) on stdout and the stderr line above; exit 0.
- SIGTERM and SIGHUP behave like `q`: restore termios, leave the alternate screen, show the cursor; exit 0 for SIGTERM and 129 for SIGHUP. Each cleanup step runs on its own, so a failing screen write cannot skip the termios restore.

## 8. v0.1.0 behaviours that must survive (task 5.1)

Read from `render_watch`, `cmd_watch`, `watch_snapshot` and `tests/test_watch.sh` at v0.1.0:

1. Row shares: Messages first up to `max(3, body_rows // 2)`, the others one row each then round-robin (`share_rows`), leftovers back to Messages.
2. Blank rows only when the frame fits with them or there are 30 rows or more.
3. The spare last column (`width = cols - 1`) and the width rules of `cell_width` (wide 2, combining 0, ambiguous 1).
4. Every bus string through `clean()` and `fit()`/`fit_left()`; every row starts with agentbus's text (`tests/test_watch.sh` TEST 1 asserts it for the one-frame output).
5. Agent colours in roster order, never red; a CRC fallback past eight agents.
6. The idle dot after 5 minutes; a new message marked for 3 seconds (`▌`, bold body) and its sender's name bold.
7. The header path cut from the left with `~` for HOME; plural stats.
8. The goal pinned under the header and left out of Facts; `◆`, `◇` and `🎯`.
9. The empty-state lines, word for word.
10. `watch needs 40+ columns` below 40.
11. `--once` and a non-terminal stdout: one frame, content only, the last 20 messages, rows right-stripped, no escape codes, no key hint.
12. `--json`: one snapshot, shape unchanged (07 adds `omitted` only).
13. Emoji rules (terminal, UTF-8, `AGENTBUS_NO_EMOJI`) and `NO_COLOR`.
14. `--interval` 0.2 to 60 seconds, default 1; the newest 200 rows per section.
15. SIGWINCH redraws at once through the wake pipe; Ctrl-C sets a flag and wakes the loop; SIGINT and SIGWINCH are unblocked at start; arrow keys never quit.
16. A busy or refused read is shown and retried on the next tick; the loop never dies on it.
17. watch never writes: no join, no `last_seen` refresh, cursors unchanged (`tests/test_watch.sh` compares every cursor). Not fully true at v0.1.0: `watch_snapshot` calls the full `open_bus`, which runs setup writes on first open; 01 adds `read_only=True` and 06 uses it for the snapshot and every detail read.

## 9. Golden files and harness

- `tests/golden/watch/fixture.json`: the sample and empty snapshots (the `watch --json` shape), the extra detail data (claim times, fact history), and one entry per golden: `name`, `cols`, `rows`, `t_now`, `where`, `view`, plus `emoji`, `live` (false for the one-frame output) and `snapshot`. `view` carries 06's View fields: `mode`, `focus`, `sel`, `paused`, `frozen`, `pending`, `filter`, `filter_input`, `detail`, `scroll`, `fresh`, `error`, `stale`. Times are UTC and frames are rendered with `TZ=UTC`, colour off.
- `tests/golden/watch/<state>-<cols>x<rows>.txt`, and `<state>-<cols>x<rows>-emoji.txt` for the emoji frames: one file per frame, rows right-stripped, exactly `rows` lines. Every state at 100x30 and 60x20 with and without emoji and at 80x24 without; `overview`, `section-focus`, `message-detail`, `help` and `error-refused` also at 40x16, 60x24 and 120x40; `once` at its natural height; `too-narrow-39x8`.
- `tests/golden/watch/render.py`: the adapter. It loads `bin/agentbus` with `runpy` and renders every entry: with 06's `render` when it exists (06 owns the body of `render_v2` and adapts the call), else with v0.1.0's `render_watch` for default views only. A state it cannot draw is `null`.
- `tests/golden/watch/PENDING`: the goldens the current renderer does not reproduce. Today that is all of them; 06 empties it and asserts it empty.
- `tests/test_watch_golden.sh`: the fixture's sample bus and inventory; height, the free last column, one physical row per line on `tests/term_oracle.py`, no trailing spaces or control characters, rows starting with agentbus's text; no em-dash; the goldens, fixture, doc frames and HTML equal what `docs/design/watch_v2_mock.py` draws (so no golden is edited by hand); `PENDING` exact; the same bytes with HOME and the wall clock changed; `scripts/check_frames.py` passes this doc and fails a too-wide and a too-tall frame.
- To change a frame: edit `docs/design/watch_v2_mock.py`, run `python3 docs/design/watch_v2_mock.py`, and get the owner's sign-off again.

## 10. Review round (task 5.4)

Run inside this lane by the author reading only this doc and the goldens, one lens at a time. It is not the independent review the runbook asks for (three lenses and a Codex reader); those stay open for the brain to run.

| Lens | Finding | Disposition |
|---|---|---|
| keyboard only | The runbook draft had no frames for agent, claim and fact detail, though Enter opens them | Fixed: `agent-detail`, `claim-detail`, `fact-detail` added |
| keyboard only | How to leave a kept filter was not visible | Fixed: `filter-kept` footer starts with `/auth · Esc clear · / edit` |
| keyboard only | Enter while following had no defined target | Fixed: opens the newest message (key map) |
| 40 columns, no colour | At 40 columns the header lost its leading space and cut `msgs` with emoji on (v0.1.0's fallback collapses spaces) | Fixed: fallback drops the folder, then the 🚌, never the stats |
| 40 columns, no colour | The goal was cut to make room for `· nate · 2h` | Fixed: narrow rows drop the author and age first |
| 40 columns, no colour | `baseline_sha` cut to `baseline_s…` at 60 columns | Fixed: narrow fact keys get `max(12, W // 4)` since the author column is gone |
| 40 columns, no colour | The filter error was cut mid-word at 60 | Fixed: it wraps onto as many rows as it needs above the input |
| 40 columns, no colour | Every kind is still readable with no colour and no emoji | Checked: each narrow row carries the code (`ask`, `hand`, `ALRT`) |
| never seen it | The paused draft showed the new message while saying `+1 new` | Fixed: the frozen list stops at the last message shown |
| never seen it | `… 4 earlier · agentbus read` suggested leaving the view for rows k can reach | Fixed: `· agentbus read` only for rows beyond the 200 held |
| never seen it | The draft overview at 80x24 drew blank rows the v0.1.0 rule does not allow | Fixed: every frame now comes from the rules, at every size |
| never seen it | Help did not explain the emoji | Fixed: help lists the kind and role emoji when emoji are on |
| never seen it | `message 7 of 9` in the header read like a page count | Changed to `message #7` |

## 11. Changes from the runbook draft (for the brain to fold into #7)

- More states: `agent-detail`, `claim-detail`, `fact-detail`, `filter-kept`, `filter-error`, `error-nobus`, `stale`, `once`, `too-narrow`.
- More sizes: 100x30 and 60x20 with and without emoji (the owner's request), on top of the runbook's 80x24 and the 40x16, 60x24 and 120x40 set. The runbook's shorter draft heights (80x12, 80x10) became full 80x24 frames.
- Emoji goldens (`-emoji`), so the frames the owner signs are pinned with their emoji, not only without.
- Fixture entries carry `emoji`, `live` and `snapshot` besides the listed fields, and `view` carries `frozen`, `pending`, `filter_input`, `detail`, `scroll` and `fresh`.
- A sample bus whose times agree with each other (an agent that posted a minute ago is not shown idle); codex is the idle agent.
- A generated-artifact check (`watch_v2_mock.py --check`) in the harness, and a free-last-column check per row.
