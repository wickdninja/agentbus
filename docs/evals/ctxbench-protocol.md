# ctxbench protocol (pre-registration, Stage 1)

Issue #80, milestone B-M0. This document freezes Stage 1: what is measured, on which histories, by which procedures
and parsers, and how the numbers are reported. Stage 1 runs only after this document merges.

**Freeze rule.** After merge nothing in this document, `scripts/ctxbench/registered.py`, `scripts/ctxbench/ledger_awk/`
or `scripts/ctxbench/data/` changes, with one exception: a registration repair proven by a new failing fixture (a
fixture that fails on the registered text or code and passes on the repair), recorded as a dated entry in the Change
log at the end. The text above the log is never edited. Stage 3 (a model reading) is not registered here; the appendix
lists what its separate registration must contain.

## The question

As coordination history grows, how much text does an agent have to take in to learn the state it needs, and can it
get the right answer from that text, when it uses the protocol's derived views (`brief`, inbox, open todos, live
claims) instead of reading the raw history with shell tools? This is a protocol question, not a storage one. The
baseline is the same protocol kept as raw text: one append-only Markdown file and ordinary shell tools, with no
maintained summary. A ledger with a locking helper and reducers is the protocol on a second transport; the Ledger-awk
arm below is a sensitivity check toward it, not a test of it.

## What Stage 1 is

**A deterministic measurement, with no inferential claim.** Code, not a model, runs a registered command list per arm
and probe on a fresh copy of a simulated history, counts the bytes those commands print, and gives the printed text to
that arm's registered reference parser, whose answer is compared with an independent oracle. Stage 1 reports what the
registered procedures return on the registered histories: no p-values, no hypothesis tests, no confidence intervals,
no verdicts. No tokens are spent. Bytes are the unit: tokens per byte differ between JSON and Markdown, so Stage 1 makes
no token claim; Stage 3 measures tokens. Its results are the input to Stage 3's registration, which carries the
hypotheses.

## Definitions (the reader text)

Both arms, and any later reader, are given exactly this text. It carries no source references.

- **D1 Roster.** An agent is on the roster from its join until its leave; a later join puts it back. An agent that
  stopped without leaving stays on the roster.
- **D2 Owner of a todo.** The named recipient, or the sender when the todo went to everyone.
- **D3 Open todo.** A todo with no `done` or `dropped` message whose reply_to is its id. Nothing else closes it: not a
  reply of another kind, not a reply to a reply, not a `done` without reply_to, not reading, leaving or a claim
  expiring.
- **D4 Open question.** A question with no `answer` message whose reply_to is its id. An answer closes only the
  message it replies to.
- **D5 Live claim.** A claim whose expiry is later than now. A claim expires 120 minutes after its last claim or
  takeover; release, leave and a takeover by someone else end it.
- **D6 Overlap.** Two resources overlap when they are equal, or one path is a folder holding the other, with or
  without the trailing `/`.
- **D7 Takeable todo.** An open todo whose owner is me, or whose owner is not on the roster now and left at or after
  the todo's time (whole seconds). A todo whose owner is on the roster, never joined, or stopped without leaving is
  not takeable.
- **D8 Decision.** A message of kind `decision` with topic `decision`. Its subject is the text after `Subject: ` on
  the last line of its body. (The `Subject:` footer is a convention of this benchmark's synthetic histories, not a
  rule of the skill, which prescribes only the kind and topic.)

Sources, for maintainers only (agentbus 0.4.0, `137f6e8`): D1 `cmd_leave`; D2 `_brief_open_todos`; D3
`TODO_CLOSERS`, `open_todo_where`; D4 `open_question_where`; D5 `_CLAIM_LIVE`; D6 `overlaps`; D7 the takeable query in
`_brief_next`; D8 `skills/agentbus/SKILL.md` "Record a decision". When the spec PR for A-M1 (#79) lands, each D gets
its `P-` id by a Change log entry; a disagreement between this text and the spec is a registration repair and needs a
failing fixture like any other.

## Probes

Every probe names an agent (`me`) and a checkpoint time (`now`), given to every arm. Answers are compared exactly.

| Probe | Question | Answer |
| --- | --- | --- |
| P1 | My open todos | ids of open todos (D3) whose owner (D2) is `me` |
| P2 | Who holds path X | names holding a live claim (D5) that overlaps X (D6) |
| P3 | Questions to me with no answer | ids of open questions (D4) to `me` or to everyone, not sent by `me` |
| P4 | Todos I may take | ids of takeable todos (D7) |
| P5 | The latest decision | `(id, subject)` of the decision (D8) with the largest id, or `(null, null)` |
| P6 | Is anyone already working on Y | names holding a live claim that overlaps `src/Y/`, plus owners on the roster of an open todo with topic `Y` |
| P7 | Session: what is on my plate, K = 3 times | at each refresh the triple (P1, P3, P4); derivable only if all three refreshes are |

## Histories

A seeded simulator (`scripts/ctxbench/sim.py`, B-M1) writes one semantic event list per history and calls the
registered choice rules in `registered.py` (`draw_event`, `choose_new_resource`, `p2_target`, `p6_target`,
`checkpoint_now`, `p7_pick`, `name_at`, `choose_fact_key`, `choose_fact_value`, `make_body`) and replays through
`apply_event`; it does not re-implement them. Both arms are rendered from that one list.

**Grid.** N in {5, 8} agents; E in {50, 1000, 5000} events; three mixes (sparse, busy, handoff-heavy). 18 histories
per seed.

**Randomness.** One `random.Random` per history, seeded with the first 8 bytes, big-endian, of
`sha256("SEED:N:E:MIX")`; one per instance, seeded from `sha256("SEED:N:E:MIX:PROBE:INSTANCE")`. Every draw named
below comes from these, in the order the rules state.

**Time.** The clock starts at 2026-11-19T09:00:00Z. Each event's time is the previous event's time plus
`round(rng.expovariate(1 / mean))` seconds (Python's `round`; 0 allowed), with the mix's mean, so times never go
backwards. Events are applied in list order.

**Start.** At the start time: `lead` joins, then `name_at(0)` to `name_at(N-2)` join (no join options: no role, tool,
model or branch), then `lead` sets the goal (`goal TEXT`) to a uniform corpus line. These N + 1 events count toward E.
The goal never changes after that in a simulated history.

**What counts toward E.** Joins, the goal, messages, claims (new, renewal, takeover), releases, facts and leaves. Not
inbox reads, crashes, or the alert a takeover generates.

**Agents and names.** `lead` plus N-1 agents join at the start. Names come from
`data/names.txt` in order; after the 40th the list repeats with a suffix (`alice2`, ..., then `alice3`, ...), so the
pool never runs out and a name is never reused (`name_at`). `lead` never leaves or crashes, and sets the goal once at
the start (see Start). Live means on the roster and not crashed.

**Event type and actor** (`draw_event`). The type is drawn from the mix table; the actor is then drawn uniformly
among the live agents for which that type is eligible. A type with no eligible actor is redrawn, type and actor
together, up to 10 times; after that the event is a `note` by a uniformly drawn live agent. Eligible actors:
- `note`, `question`, `decision`, `alert`, `handoff`, `todo`, `fact`: every live agent.
- `answer`: a live agent with an open question addressed to it or to everyone and not sent by it.
- `done`, `dropped`: a live agent that owns or may take (D7) an open todo.
- `claim`: a live agent for which at least one claim sort (below) is possible.
- `release`: a live agent holding a live claim.
- `join`: when fewer than N agents are live; the actor is the next name from the pool (not drawn).
- `leave`: a live agent other than `lead`, when at least 2 live agents besides `lead` exist.

**Draw order inside a step.** Time gap; type and actor; then the event's own draws in the order this section lists them
(claim sort and target, recipient, topic, reply target, body); then the actor's inbox read; then the crash draw. The
next subsection fixes every draw's form and order.

**Targets inside an event.** A reply's target is drawn uniformly among the actor's eligible open items. A release
drops a uniform claim among the actor's live claims; a renewal renews a uniform one of them. A `done` has
no reply_to with probability 0.20 (it closes nothing). With probability 0.05 an answer or done is sent instead as a
`note` replying to the same message, or as an `answer` replying to the latest reply to it (it closes nothing).

**Crashes.** Separately from E, after each event a live agent other than `lead` crashes with the mix's crash
probability (uniform among them). It never acts again, writes nothing to either arm, and stays on the bus roster (D1).
Crash probability per event: sparse 0.002, busy 0.004, handoff-heavy 0.008.

**Recipients.** A message goes to everyone with the mix's broadcast share, else to one named agent other than the
actor. The named recipient is, with probability 0.10 when any agent has left, drawn uniformly from agents that have
left (so a todo to an owner who already left, the hard case of D7, occurs at a registered rate); otherwise uniformly
from the agents on the roster (crashed ones included, since others cannot tell).

**Claims.** A claim's sort is drawn by the shares below among the sorts possible for the actor (shares renormalised
over the possible ones): a renewal (the actor claims again a resource it holds live), a takeover
(`claim RESOURCE --from HOLDER` on a uniformly drawn live claim of another agent) or a new claim. Renewals and takeovers
are exempt from the no-overlap rule; a new claim must overlap no live claim of any agent and its resource comes from
`choose_new_resource`, the one resource rule: the folder sort (`src/SLUG/`) with probability 0.3, else the file sort
(`src/SLUG/f1.py` to `f4.py`), uniformly among that sort's free resources, else the other sort's; not possible when
none is free. Every claim uses the default 120-minute TTL, so the bus logs no refusal. Purpose: a new claim and a
takeover get a uniform corpus line; a renewal keeps the claim's current purpose (so the bus logs nothing for it).

**Takeover expansion.** A takeover is one event in E. On the bus it ends the old holder's claim, starts the new one,
logs `claim_taken` and inserts an `alert` message (the next message id, same time, topic `claim`) from the new holder
to the old one, with the body `NEW took your claim on RES with claim --from and now holds RES (purpose: "P").` The
ledger renders it as a `TAKEOVER` line followed by that `ALERT` line with the same id, body and time. Fixture PARITY
checks this.

**Topics.** A decision gets topic `decision` with probability 0.95, else a uniform item slug (that message is not a D8
decision); this rule overrides the general topic rule. Every other message gets a uniform item slug as topic with
probability 0.6, else none.

**Event mixes** (share of E, per cent; the order is the draw order of `draw_type`):

| Event | sparse | busy | handoff-heavy |
| --- | ---: | ---: | ---: |
| note | 30 | 20 | 12 |
| question | 5 | 10 | 8 |
| answer | 4 | 8 | 7 |
| decision | 3 | 4 | 3 |
| alert | 1 | 3 | 1 |
| handoff | 2 | 4 | 14 |
| todo | 8 | 12 | 16 |
| done | 6 | 9 | 10 |
| dropped | 1 | 2 | 3 |
| claim | 18 | 14 | 12 |
| release | 14 | 10 | 8 |
| fact (`ctx set`) | 5 | 2 | 2 |
| join | 2 | 1 | 2 |
| leave | 1 | 1 | 2 |
| total | 100 | 100 | 100 |

| Parameter | sparse | busy | handoff-heavy |
| --- | ---: | ---: | ---: |
| mean seconds between events | 120 | 20 | 45 |
| work items (the first k lines of `data/items.txt`) | 30 | 15 | 20 |
| broadcast share of messages | 0.40 | 0.30 | 0.20 |
| claim sort shares: renewal / takeover / new | 0.20 / 0.05 / 0.75 | 0.20 / 0.10 / 0.70 | 0.20 / 0.20 / 0.60 |
| long-body share | 0.03 | 0.05 | 0.08 |

**Bodies** (`make_body`). Sentences from `data/corpus.txt`, drawn uniformly with replacement. One draw against the
mix's long-body share: a long body is k sentences, k uniform on 24 to 40 (usually over 2,048 bytes, so a listing cuts
it); else a normal body, k uniform on 1 to 6; joined by a space. Every message kind uses `make_body` except: a handoff
body is `branch SLUG; S1; S2; S3` (three sentences; SLUG is the message's topic, else a uniform item); a decision body
is `make_body`, a line break and `Subject: SLUG` with a uniform item.

**Facts** (`ctx set KEY VALUE`). The key comes from `choose_fact_key` over `data/fact_keys.txt` (24 keys): one uniform
draw; below 0.5 with any key already set, or once every key is used, a uniform key among those already set; otherwise
the next unused key in list order. The value (`choose_fact_value`) is a uniform corpus line other than the key's current
value, because the bus records nothing for an unchanged write. Any live agent may write a fact.

**Inbox consumption.** After each of its own events, an agent runs a consuming `inbox` with probability 0.5 (the skill
says to read inbox each turn). It is a step in the event list but not one of the E events. It moves only that agent's
bus cursor and is not rendered in the ledger (a ledger reader keeps its own private cursor).

**Checkpoints, P1 to P6.** The simulator writes E + 20 events. For each (history, probe, instance): c is drawn
uniformly from [ceil(0.9E), E] and u0 uniformly from 1 to 300; `me` is drawn uniformly from the agents live at c.
`now` = `checkpoint_now`: the time of event c plus u seconds, u scanned from u0 to 300 then 1 to u0-1, the first for
which no claim live at c expires in (now, now + 120 s]. If no u qualifies, c moves to the next index (c+1, wrapping
from E to ceil(0.9E)) and `me` is drawn again. P1 to P6 never see an event after c.

**Targets.** X in P2 (`p2_target`): one uniform draw; below 0.5 and with any claim live at `now`, a file that a
uniformly drawn live claim covers (the claimed file, or a uniform file of a claimed folder); otherwise, including when
no claim is live, a uniform file of a uniform item. Y in P6 (`p6_target`): below 0.5 and with any active item (one
someone works on by P6's rule), a uniform active item; otherwise, including when none is active, a uniform item.

**P7 construction** (`p7_pick`). The history is shared by all instances and is never altered for one. c0 is drawn
uniformly from [ceil(0.9E), E]. A candidate at c is an agent live at c and at c+20 with no leave or crash at events
c+1 to c+20, provided no claim live at each refresh time expires within 120 s after it. The scan starts at c0 and
follows the same next-index rule, each index at most once; at the first index with candidates, `me` is a uniform
candidate. If no index qualifies, the instance is recorded as "no P7 candidate" and counted. Refresh 1 runs at the time
of event c, refresh 2 after events c+1 to c+10 at the time of event c+10, refresh 3 after events c+11 to c+20 at the
time of event c+20, so refresh times never go backwards. `me`'s own events and scheduled inbox reads inside the window
happen as the history says. P7's bytes are the sum over its three refreshes.

**Development seeds.** B-M1 builds and debugs on seeds 9901 and 9902 only. A run whose seeds are all development seeds may use cells off the registered grid (any N >= 2, E >= 10) so tests stay small; counted seeds take only the grid, and the runner refuses otherwise. Their output is inspected for defects
(crashes, parity, replay checks, oracle-parser disagreements) and never summarised by arm; no comparison between arms
is computed on any seed before Stage 1's registered run.

### Simulator draw order

Every random draw of a history comes from its one `random.Random`, in this order. Draws a registered function makes
(`draw_event`, `choose_new_resource`, `choose_fact_key`, `choose_fact_value`, `make_body`, `p7_pick`, and the target
rules) are made inside it; "draw" below means the call named. `choice(L)` is `rng.choice(L)` on the list `L` sorted
ascending (names, resources and ids, ids numerically), except `corpus` and `items`, which stay in file order.

1. **Start.** After the N joins, `lead`'s goal is `choice(corpus)` over `data/corpus.txt` in file order. The start makes no
   time, inbox or crash draw: its events are not steps, so they have no inbox read and no crash draw.
2. **Time gap.** A step's first draw is its gap, `round(rng.expovariate(1 / mean))` seconds, before the type, because
   `release` and `claim` eligibility depend on which claims are live at the step's time.
3. **Type and actor.** `draw_event`.
4. **Claim.** The sort is one `rng.random()` scaled by the sum of the shares of the sorts possible for the actor, walked
   in the order renewal, takeover, new (the first sort whose share exceeds the remainder; the last sort when none
   does). Then the target: a renewal, `choice` over the actor's live claims; a takeover, `choice` over the live claims of
   other agents; a new claim, `choose_new_resource` with every live claim's resource. Then, for a new claim and a
   takeover only, the purpose `choice(corpus)` (file order); a renewal keeps the purpose it holds.
5. **Release.** `choice` over the actor's live claims.
6. **Fact.** `choose_fact_key`, then `choose_fact_value`.
7. **Message** (every kind but a claim, release, fact, join or leave), in this order:
   a. Recipient: `rng.random() < broadcast share` means everyone. Else, when any agent has left, `rng.random() < 0.10`
      means `choice` over the agents that have left; else (and when nobody has left, with no
      draw for that 0.10) `choice` over the agents on the roster other than the actor. Every kind draws its recipient
      this way, replies included: a reply is not addressed to the sender of what it answers.
   b. Topic: a decision, `rng.random() < 0.95` means `decision`, else `choice(items)`; any other kind,
      `rng.random() < 0.6` means `choice(items)`, else none.
   c. Reply target (an answer, done or dropped only): `choice` over the actor's eligible open items. A done then draws
      `rng.random() < 0.20`, which drops its `reply_to`. An answer or a done that kept its `reply_to` then draws
      `rng.random() < 0.05`; on a hit, when some message already replies to the target, one more `rng.random() < 0.5`
      sends an `answer` replying to the latest reply to the target, and otherwise (or when nothing replies to it yet)
      a `note` replying to the target. A dropped draws neither.
   d. Body: a handoff, its topic or else `choice(items)` as SLUG, then three `choice(corpus)` sentences; a decision,
      `make_body` then `choice(items)` for the subject; any other kind, `make_body`.
8. **Inbox read.** `rng.random() < 0.5`; the draw is made even when the actor just left, and then no read is written (a
   left agent has no inbox).
9. **Crash.** `rng.random() < crash probability`; on a hit, `choice` over the live agents other than `lead`.

Message ids count posts and takeover alerts in order. A checkpoint after event k includes that step's own inbox read and
nothing of step k + 1; an agent is live at k when it is on the roster and has not crashed after step k's crash draw.
Instances are numbered from 0 in their seed string. A P7 instance's outcome is "wrong" when any of its nine slots (three
refreshes, three answers each) is wrong, else "cannot decide" when any is, else derivable. The parameter table above is
`PARAMS` in `registered.py`, and a test compares the two.

### Clock rule and time checks

`AGENTBUS_TEST_NOW` is read once at module load and the clock then runs on with the wall clock. So the replay starts a
fresh process (or re-imports the module with `runpy`) for every simulated step, with `AGENTBUS_TEST_NOW` set to that
step's time, and every reader command runs in its own process with `AGENTBUS_TEST_NOW` set to `now`. Every command runs
with `TZ=UTC`, `LC_ALL=C`, `AGENTBUS_NO_UPDATE_CHECK=1` and `AGENTBUS_NO_UPDATE_NOTICE=1`.

- **Reader time.** Each measured bus command is bracketed by a monotonic clock; the clock it ran on started at `now`
  exactly (a whole second), so it stayed on `now`'s second only if the command took under one second. A command that
  takes one second or more is a replay defect (`Runner.bus(measured=True)`). The checkpoint guard keeps any claim
  expiry at least 120 s after `now` in any case.
- **Stored times.** After a history is built, every stored time is read back (`check_stored_times`): message times in
  order, every log row, every claim's start (with expiry exactly 120 minutes later), every `last_seen`, every fact.
  Each must be a simulated step time; a mismatch is a replay defect.
- **Defects.** A replay defect reruns every arm of that seed. It is never scored.

## Arms

Each probe runs on a fresh copy of its history (the whole bus folder, or the ledger file) per arm and instance; a P7
session runs on one copy for its three refreshes. Bus commands run as `agentbus --as ME ...`. Before bytes are counted,
every occurrence of the copy's folder in the output is replaced by the fixed string `/ctxbench`.

### Ledger file format

One file, `COORDINATION.md`, in R3's event format (research `r3-codex.md` section 1), without the helper:

```text
# COORDINATION.md

Append-only. One event per line; continuation lines of a body are indented two spaces.
Fields: eid ts kind id from to topic path reply_to | text. '-' means none; to=all is a broadcast.
A claim lasts 120 minutes from its CLAIM or TAKEOVER line unless renewed.

- eid=E7 ts=2026-11-19T12:10:00Z kind=TODO id=1 from=lead to=carol topic=parser path=- reply_to=- | Carol, please ...
```

- One header line per event, fields in the fixed order shown, then ` | ` and the first body line; later body lines are
  indented two spaces. `eid` counts events from 1 in file order; `ts` is the bus time; `id` is the bus message id for a
  message and `-` otherwise.
- Values before `|` are percent-encoded so they hold no space, `|`, `%`, `=`, tab or newline.
- Kinds: message kinds in capitals (`NOTE QUESTION ANSWER HANDOFF DECISION ALERT DONE TODO DROPPED`), plus `JOIN`,
  `LEAVE`, `CLAIM` (path = resource, text = purpose; also a renewal), `TAKEOVER` (from = new holder, to = old holder,
  followed by its `ALERT`), `RELEASE`, `FACT` (from = writer, topic = key, text = value) and `GOAL` (from = setter,
  text = goal).
- A leave is rendered as one `RELEASE` per claim row the agent holds, live or expired (the bus deletes every row the agent holds), then `LEAVE`, at the leave's time. A crash writes nothing.
  Inbox consumption writes nothing. Nothing is ever rewritten and there is no state section.

The renderer is `render_ledger` in `registered.py`; rendering a prefix of the events gives a prefix of the file.

### The four arms

- **Bus-default.** The skill's literal start sequence, in `--json` as the skill says to parse: `brief`, then
  `inbox --limit 20 --peek` (peek so a probe never consumes), plus `read --topic decision` for P5 only. Default limits:
  `brief` shows 5 rows per section, so at N = 8 a roster-sized answer (P2, P6) is often cut. No parser uses the inbox
  output; it is charged because the skill's sequence includes it.
- **Bus-complete.** A registered procedure per probe that is sufficient to derive the answer from its own output, every
  call charged, including `log show` for leave times (P4) and `read --id` for a body a listing cut at 2,048 bytes (P5).
- **Ledger-raw.** R3's shell recipes over `COORDINATION.md` (`grep -E` in place of `rg`, which not every machine has),
  cut to the header fields (`cut -d'|' -f1`) wherever the probe needs no body.
- **Ledger-awk** (sensitivity). One registered POSIX awk reducer per probe over the raw file
  (`scripts/ctxbench/ledger_awk/`), printing only the answer. It stands in for the strongest ledger reader short of a
  maintained helper. The reducers' own text is a prepared helper and is not counted as delivered bytes.

### Command table

`GREP(K)` stands for `grep -n -E 'kind=(K)( |$)' COORDINATION.md | cut -d'|' -f1`. `AWK(p, vars)` stands for
`awk vars -f ledger_awk/common.awk -f ledger_awk/p.awk COORDINATION.md`. Bus commands are written without the leading
`agentbus --as ME`. The exact strings are in `registered.py` (`static_calls`, `execute`, `Session`).

| Probe | Bus-default | Bus-complete | Ledger-raw | Ledger-awk |
| --- | --- | --- | --- | --- |
| P1 | `--json brief`; `--json inbox --limit 20 --peek` | `--json brief --limit -1` | `GREP(TODO\|DONE\|DROPPED)` | `AWK(p1, -v me=ME)` |
| P2 | same as P1 | `--json claims --limit -1` | `GREP(CLAIM\|TAKEOVER\|RELEASE\|LEAVE)` | `AWK(p2, -v x=X -v now=NOW)` |
| P3 | same as P1 | `--json brief --limit -1` | `GREP(QUESTION\|ANSWER)` | `AWK(p3, -v me=ME)` |
| P4 | same as P1 | `--json brief --limit -1`; `--json log show --limit -1` | `GREP(TODO\|DONE\|DROPPED\|JOIN\|LEAVE)` | `AWK(p4, -v me=ME)` |
| P5 | P1's two, then `--json read --topic decision` | `--json read --topic decision --limit -1`; then `--json read --id N` for the newest decision only when its body was cut | see P5 below | `AWK(p5, )` |
| P6 | same as P1 | `--json claims --limit -1`; `--json brief --limit -1` | `GREP(CLAIM\|TAKEOVER\|RELEASE\|JOIN\|LEAVE\|TODO\|DONE\|DROPPED)` | `AWK(p6, -v y=Y -v now=NOW)` |
| P7 (each refresh) | `--json brief`; `--json inbox --limit 20` (consuming) | P4's two commands | see P7 below | P1's, P3's and P4's reducers |

(`\|` is a table escape for `|`.)

**Ledger-raw P5.** Anchored to the parsed header fields, so a body that quotes a header cannot match, then the newest
genuine decision is expanded:
1. `grep -n -E '^- eid=E[0-9]+ ts=[^ ]+ kind=DECISION id=[^ ]+ from=[^ ]+ to=[^ ]+ topic=decision ' COORDINATION.md | cut -d'|' -f1 | tail -n 1`
2. when step 1 printed line L: `awk -v L=L 'NR==L{p=1; print; next} p && /^- eid=/{exit} p{print}' COORDINATION.md`

**Ledger-raw P7.** The reader keeps a private line cursor and its folded rows, as R3 allows. Each refresh first runs
`awk 'END{print NR}' COORDINATION.md` (giving n; awk, not `wc -l`, whose padding differs between BSD and GNU and would change the byte count by platform). Refresh 1 then runs `GREP(TODO|DONE|DROPPED|QUESTION|ANSWER|JOIN|LEAVE)`;
refresh k > 1 runs `sed -n 'L,np' COORDINATION.md | grep -n -E 'kind=(TODO|DONE|DROPPED|QUESTION|ANSWER|JOIN|LEAVE)( |$)' | cut -d'|' -f1`
with L one past the previous refresh's n. The bus arms recompute each refresh.

**Adaptive calls.** Only P5's second call depends on earlier output, and it is decided from delivered evidence alone:
when the first output was cut by the cap, no second call is made and the probe cannot be decided.

### Reference parsers and the adapter

Every parser of every arm, P1 to P7, is registered in `registered.py` (`parse_bus`, `parse_ledger_raw`,
`parse_ledger_awk`, `Session`) and fixture-tested in this commit. B-M1 imports them and does not rewrite them. A parser
sees only what its procedure delivered and the probe's inputs (`me`, `now`, X, Y). Every parser filters claims by
`expires_at > now` (D5), never by the bus's `state` field, and excludes `me`'s own questions in P3 by sender.

**The cap and completeness adapter** (`deliver`, `answer`). Each call's output is tagged with the evidence source it
provides. Before any parsing, a source the probe requires that was cut by the cap makes the outcome "cannot decide",
so cut JSON never reaches a JSON parser; a cut source the probe does not use changes nothing. Ledger arms require every
call they made. After that, a parser returns "cannot decide" when a required source says rows were left out
(`has_more`, `omitted.<section>`, `claims_omitted`):

| Probe | Bus-default requires | Bus-complete requires | Ledger arms |
| --- | --- | --- | --- |
| P1 | `brief` todos | `brief` todos | every call |
| P2 | `brief` agents and each agent's claims | `claims` | every call |
| P3 | `brief` questions | `brief` questions | every call |
| P4 | `brief` todos (and see below) | `brief` todos, `log` | every call |
| P5 | the newest decision present with its whole body | the newest decision, whole after `read --id` | every call |
| P6 | `brief` agents, claims and todos | `claims`; `brief` todos | every call |

**Bus-default and `next`.** `brief`'s `next` command sometimes names a takeable todo (fixture F4), but it is chosen
after unread messages and open questions and shows at most one todo, so whether it settles P4 depends on state a
fixture cannot exhaust. The registered Bus-default parser does not use it: when an open todo's owner is off the roster,
it cannot decide P4.

**Output cap.** Every measure is reported twice: uncapped, and with each call's output cut at 30,000 characters (the
default cap of a common agent harness) followed by the line `[ctxbench: output cut at 30000 characters]`. Capped bytes
count what was kept plus the marker.

## Measures

Stage 1 runs every arm on one machine in one batch. The results file records the OS, the Python version, and the `awk`, `grep`, `sed`, `cut` and `tail` versions; byte counts are compared only within that run, because tool output can differ in whitespace between BSD and GNU tools.

Per instance and arm, uncapped and capped:
- **Delivered bytes**: UTF-8 bytes of the output of every call, summed after path normalisation. Zero is a normal value
  (an empty answer from a ledger arm): it is kept and reported, never dropped or replaced.
- **Outcome**: "derivable by the registered parser" when the parser returns the oracle's answer; "the registered parser
  cannot decide" when it returns that; "wrong" otherwise. The last two are misses. A miss says what the registered
  parser could do with the delivered text, not that no reader could.
- **Calls** in the procedure.

## Oracle

1. **Independent.** The oracle (`scripts/ctxbench/oracle.py`, B-M1) is written from this document by a lane that has
   not read `bin/agentbus`, and folds the simulator's semantic event list with D1 to D8.
2. **Hand fixtures first.** It must pass F1 to F6 and these before Stage 1 runs: a `done` with no reply_to closes
   nothing; a broadcast todo's owner is its sender; a decision with another topic is not a D8 decision; an owner who
   left and rejoined makes the todo not takeable; a crashed holder's claim stays live until it expires.
3. **Three-way agreement.** Per cell, Stage 1 reports agreement between the oracle and each arm's parser.
4. **Disagreement.** A bus arm whose procedure was complete but whose answer disagrees with the oracle is "wrong" (a bus
   error) in the report and filed as an issue; a rerun on a corrected bus is reported separately.

## Report

The report is built only for the counted run (`--counted`). Every run, development runs included, writes a defects
summary: defect rows, seed-cells excluded after three attempts, oracle-parser disagreements and defects a rerun
cleared, with no per-arm aggregate. A seed-cell whose replay still fails on its third attempt is left out of the report
whole and listed.

Per (N, E, mix, probe) cell and arm, uncapped and capped (`cell_report`):

- **Bytes.** Per seed, the mean delivered bytes over its 10 instances. Across the 30 seeds: median, first and third
  quartiles (`statistics.quantiles`, method `inclusive`), minimum and maximum. The per-seed values are in the results
  file.
- **Ratios.** For each bus arm over Ledger-raw and over Ledger-awk: the ratio of the medians and the ratio of the sums
  of the per-seed values. A zero denominator is reported as `n/a: empty (numerator X, denominator 0)`, never imputed; a
  zero numerator is a ratio of 0.
- **Outcomes.** Instances derivable by the registered parser, of instances run; instances the parser cannot decide;
  wrong instances; seeds with any miss, of 30.
- **Agreement.** Oracle against each arm's parser, and the count of "no P7 candidate" instances.

Results go to `docs/evals/ctxbench-results.md` with the run's commit and the data-file hashes. No sentence in it says
more than these numbers.

## Fixtures

`scripts/ctxbench/fixture_sufficiency.py`, run by `tests/test_ctxbench_fixture.sh` in the suite, builds histories
with the real CLI (one process per step), renders each ledger, and checks every registered procedure, adapter, parser,
choice rule, time check and report function. Each also fails when the rule it covers is broken. The suite runs them in two files, each under 60 s:
`tests/test_ctxbench_fixture.sh` (PARITY, F1 to F5, F7, and the data-file hashes) and `tests/test_ctxbench_rules.sh`
(CAP, F6, GEN, TIME, REPORT).

- **F1 (N1).** lead, alice, bob and carol join at 11:50; lead posts todo #1 to carol and #2 to bob at 12:10; carol
  leaves at 12:20; bob leaves at 12:00 (A) or 12:20 (B). `me` alice at 12:30. P4 = {1} in A, {1, 2} in B for
  Bus-complete and both ledger arms; Bus-default's parser cannot decide and its text is identical for A and B; without
  `log show` or the `LEAVE` lines the two histories read the same.
- **F2 (Codex finding 4).** Decision #1 with its subject on a continuation line (`parser` or `uploader`), then a note
  whose body quotes a decision header. P5 = (1, parser) and (1, uploader) in every arm; the v1 recipe
  (`grep 'kind=DECISION .* topic=decision '`, expand the last hit) prints identical text for both and is not registered.
- **F3.** An expired claim, a claim whose expiry equals `now`, a takeover, a todo closed by a linked `done`, a question
  replied to only by a note and an answer to that note, a broadcast question answered, `me`'s own broadcast question,
  a claimed then released folder. P1, P3, P2 on four paths, P6 on three items, every arm.
- **F4 (Codex re-check D).** The only open todo is to bob, who left after it was posted; P4 = {1}. Bus-default's parser
  cannot decide, while `brief`'s `next` names `read --id 1` (recorded, not used).
- **F5.** A decision whose subject sits past byte 2,048: Bus-complete reads it whole with `read --id`; Bus-default's
  parser cannot decide.
- **F6 (P7).** Three refreshes with `me` closing a todo and answering a question inside the windows and a todo owner
  leaving: every arm's session parser gives the hand-derived triples. Capped (cap 3), every arm returns "cannot decide"
  for each cut source, checked before any parsing, and never raises; an empty Ledger-awk answer is not cut and stays
  derivable.
- **F7.** A goal, a goal change, three fact writes (one key written twice) and a todo: P1 and P4 in every arm, and
  PARITY over the goal and fact writes.
- **CAP.** A cut ledger source is a miss; cut JSON is a miss without parsing; a cut unused source (Bus-default's inbox)
  changes nothing; a cut first P5 output makes no second call, in both arms that have one.
- **GEN.** On scripted draws: type then actor, redraw with the actor, the note fallback; the resource rule and its
  fallbacks; P2 and P6 with empty pools; the P7 scan (an agent leaving in the window is no candidate; the scan wraps;
  no candidate at all); the checkpoint guard; the name pool past 40; fact keys (first, next unused, update, list
  exhausted) and values (never the current one); normal and long bodies.
- **TIME.** A reader taking over a second is a replay defect; a stored log time off the simulated times is a replay
  defect.
- **PARITY.** In every fixture history the bus's messages (the takeover alert included) equal the ledger's message
  lines, and the bus's goal and fact history (key, value, writer, time) equals the ledger's `GOAL` and `FACT` lines.
- **REPORT.** A zero numerator, a zero denominator and 0/0 are kept and labelled; quartiles; outcome counts.

## Data files

Committed in this PR; a change is a registration repair. `data/corpus.txt` is generated by `gen_corpus.py`
(a fixed grammar and `random.Random(20261119)`; 200 unique lines, 40 to 200 bytes each, corpus mean 90 to 130 (the committed file: 47 to
123 bytes, mean 92.8);
`gen_corpus.py --check` proves the committed file is its output). The test checks these hashes.

| File | sha256 |
| --- | --- |
| `scripts/ctxbench/gen_corpus.py` | `dcb32a3b4b0e1f936e2cbd7d4cf54360969eb1be4ad0ceb47215a1061cb60d78` |
| `scripts/ctxbench/data/corpus.txt` | `eb1338e9a99c90d55a99c7d4b7323e8256a744e734413670952ab174b9756321` |
| `scripts/ctxbench/data/names.txt` | `1e01307a202d7dc90f3174e4f5d611d5a8fa47fbc97cd3d8047e9676569b78c2` |
| `scripts/ctxbench/data/items.txt` | `ee3a22da6fbdba8307c1e17c0f3f030fbf45aad5e48376fd0f7a2a4fdf5921eb` |
| `scripts/ctxbench/data/fact_keys.txt` | `15e183e299dd8ef88294f86aa5e21f193d3b4832d857603e06ed6515079d21a0` |

## Seeds

Thirty base seeds, fixed now and used in every cell so arms and cells are paired:

`4127, 9341, 1586, 7203, 2648, 5519, 8872, 3065, 6794, 1930, 2417, 8156, 3742, 6081, 1299,`
`7534, 4860, 9617, 5203, 3388, 7915, 1046, 6452, 2771, 8309, 4594, 9022, 5867, 3150, 7688`

M = 10 instances per seed, cell and probe. Stage 1 runs 2 x 3 x 3 x 7 x 4 x 30 x 10 = 151,200 procedure runs. It
costs CPU time only and spends no tokens; its runner refuses to start if a model credential or harness is configured
in its environment.

## Threats to validity

**Toward agentbus:**
- The bus procedures and this document were written by the tool's authors. Mitigations: R3's format and recipes, the
  Ledger-awk arm, the independent oracle, and publication of one full ledger per cell.
- Ledger-raw gets no prepared helper, so a bus result here says nothing against the protocol on a Markdown transport.
- Bus errors that the oracle shares would be invisible; the oracle is written without reading the code.

**Toward the ledger:**
- No refused claims, no name reuse, no malformed rows, no concurrency: the bus's atomicity and hostile-data handling
  earn nothing. This is the read side only.
- Ledger-raw's P7 keeps a private cursor and state; the bus arms recompute each refresh.
- Bus-complete's `log show --limit -1` returns the whole log, including events P4 does not need.
- Bus-default's parser does not use `next`, so some P4 states a reader could settle count as "cannot decide".
- Ledger-awk's reducer text is not counted, and every ledger line holds a whole event, so `grep` returns exactly the
  events needed; a ledger written by agents would be messier.
- JSON may cost more tokens per byte than Markdown, or fewer; Stage 1 says nothing about tokens.

**Either way:**
- Simulated histories and one generated corpus; the three mixes are a sensitivity check, not a guarantee.
- Checkpoints sit in the last tenth of a history, so "history size" means E events.
- Code reads the procedures; a model may read fewer or more. Stage 3 measures that.

## Appendix: Stage 3 requirements (registered separately after Stage 1)

Stage 3 (a model with a shell answers the probes) is not registered by this document. Its own pre-registration,
written after Stage 1's results, must contain at least the following, each made concrete:

1. **One cluster-valid procedure** for every interval, test and p-value, seeds as the unit (per-seed paired
   differences and per-seed log ratios with t intervals, or exact sign-flip tests), with explicit bounds and p-values
   for degenerate samples (perfect ties, all-equal differences). Never instance-level counts. The complete decision
   procedure, Holm included, validated by simulation under clustered nulls and perfect ties (Codex re-check A).
2. **One estimand per claim.** The point estimate, its interval and the wording of the claim concern the same
   quantity; a geometric mean of per-seed ratios is reported and worded as that, never as "half the text" (Codex
   re-check F).
3. **Hypotheses, registered there:** H1, at small scale the token ratio's interval lies inside an equivalence band
   (for example [0.8, 1.25]); an interval that merely contains 1 is inconclusive. H2, at large scale Bus-default is
   non-inferior on correctness (for example a margin of -5 points) and its token ratio's upper bound is below 0.5. A
   primary family with Holm correction and an intersection-union rule for H2.
4. **A decision table** with rows for a correctness loss, correctness not shown, cheaper by half, equivalent, cheaper,
   more expensive and inconclusive (and an inferior row), a precedence order, and a study-level rule; a correctness
   loss is reported before any saving.
5. **More seeds over more instances**, for example 30 seeds x M = 2 rather than 10 x 5.
6. **Power shown by clustered simulation** of the complete decision procedure, covering perfect ties, heavy-tailed
   per-seed costs and every permitted scope cut.
7. **The H2 denominator** is each logged tool result tokenized once with the provider's own count of that exact text;
   no bytes-to-tokens calibration factor.
8. **Ratios per model**, never silently pooled across models.
9. **Admission** that reserves a worst case enforced per request (a hard output limit and a hard tool-result limit,
   both in tokens) before dispatch, and charges unknown or missing usage pessimistically. Zero overage on every pool.
10. **Whole paired seed blocks admitted before they start**, a fixed block order, arms interleaved inside a block, a
    rule for every incomplete block, and a minimum confirmatory sample.
11. **A pilot blinded to arm outcomes**: it reports usage and errors only, never correctness or ratios by arm.
12. **Failures after the first tool call are arm outcomes**, never infrastructure replacements.
13. **An exact answer-extraction rule** (the JSON object, where it must appear, what counts as unparseable).
14. **Interpreter parity**: every arm's commands run through a wrapper with an absolute interpreter path; `python3` is
    absent from PATH in every arm, and the harness asserts it before each trial.
15. **A P7 delivery specification**: how refreshes and interleaved events reach the model, and what each refresh
    prompt says.
16. **The harness output cap** decided as part of the treatment (and then equal for all arms of a model) or raised
    above every arm's largest output.
17. Whether each arm is an enforced procedure or an instruction package, with permitted actions, batching, scratch
    state, call counting, and how departures from the arm's procedure are reported.
18. **Zero-safe ratios**: the registered handling of zero numerators and denominators, tested.

## Change log

Every change after this document merges is a new dated entry here, appended below: a registration repair with the
failing fixture that proves it, or a value this document says is recorded later (the spec's `P-` ids). Nothing above
is ever edited.
