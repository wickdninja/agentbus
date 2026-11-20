# ctxbench protocol (pre-registration, Stage 1)

Issue #80, milestone B-M0. This document freezes Stage 1: what is measured, on which histories, by which procedures
and parsers, and how the numbers are read. Stage 1 runs only after this document merges.

**Freeze rule.** After merge nothing in this document changes, with one exception: a registration repair proven by a
new failing fixture (a fixture that fails on the registered text or code and passes on the repair), recorded as a dated
entry in the Change log at the end. The text above the log is never edited. Stage 3 (a model reading) is not
registered here; the appendix lists what its separate registration must contain.

## The question

As coordination history grows, how much text does an agent have to take in to learn the state it needs, and can it
get the right answer from that text, when it uses the protocol's derived views (`brief`, inbox, open todos, live
claims) instead of reading the raw history with shell tools? This is a protocol question, not a storage one. The
baseline is the same protocol kept as raw text: one append-only Markdown file and ordinary shell tools, with no
maintained summary. A ledger with a locking helper and reducers is the protocol on a second transport; the Ledger-awk
arm below is a sensitivity check toward it, not a test of it.

"The views save nothing", "the raw ledger wins" and "inconclusive" are all valid results and are reported as plainly
as a win.

## Stage 1 in one paragraph

Code, not a model, runs a registered command list per arm and probe on a fresh copy of a simulated history, counts
the bytes those commands print, and gives the printed text to that arm's registered reference parser. The parser's
answer is compared with an independent oracle. No tokens are spent. Bytes are the unit: tokens per byte differ between
JSON and Markdown, so Stage 1 makes no token claim and never reports bytes / 4 as a finding; Stage 3 measures tokens.

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

Every probe names an agent (`me`) and a checkpoint time (`now`), given to every arm. Answers are scored exactly.

| Probe | Question | Answer |
| --- | --- | --- |
| P1 | My open todos | ids of open todos (D3) whose owner (D2) is `me` |
| P2 | Who holds path X | names holding a live claim (D5) that overlaps X (D6) |
| P3 | Questions to me with no answer | ids of open questions (D4) to `me` or to everyone, not sent by `me` |
| P4 | Todos I may take | ids of takeable todos (D7) |
| P5 | The latest decision | `(id, subject)` of the decision (D8) with the largest id, or `(null, null)` |
| P6 | Is anyone already working on Y | names holding a live claim that overlaps `src/Y/`, plus owners on the roster of an open todo with topic `Y` |
| P7 | Session: what is on my plate, K = 3 times | at each refresh the triple (P1, P3, P4); derivable only if all three refreshes are |

**P7.** One session on one copy. Refresh 1 runs at checkpoint event c with `now` = the time of event c; then exactly 10
simulated events are applied (events c+1 to c+10), refresh 2 runs with `now` = the time of event c+10; 10 more events,
refresh 3 at the time of event c+20. Refresh times therefore never go backwards. `me` may act inside the interleaved
events like any agent (post, claim, close a todo), but cannot leave or crash there, and its own scheduled inbox reads
are suppressed: in a P7 session the refreshes are `me`'s reads. P7's bytes are the sum over its three refreshes.

**Targets.** X in P2 is, with probability 1/2, a file under a resource some live claim covers at the checkpoint, else
a file drawn uniformly from the path pool. Y in P6 is, with probability 1/2, an item someone works on (by P6's rule),
else drawn uniformly from the item list. Both draws come from the instance seed.

## Histories

A seeded simulator (`scripts/ctxbench/sim.py`, B-M1) writes one semantic event list per history; both arms are
rendered from that one list.

**Grid.** N in {5, 8} agents; E in {50, 1000, 5000} events; three mixes (sparse, busy, handoff-heavy). 18 histories
per seed.

**Time.** The clock starts at 2026-11-19T09:00:00Z. Each event's time is the previous event's time plus a gap drawn
from an exponential distribution with the mix's mean and rounded to whole seconds (0 allowed), so times never go
backwards. Events of one history are applied in list order.

**Agents and names.** `lead` plus N-1 agents join at the start (these N joins count toward E). Names come from a fixed
list of 40 first names in order; after the 40th the list repeats with a suffix (`alice2`, ..., then `alice3`, ...), so
the pool never runs out and a name is never reused. `lead` never leaves or crashes, and sets the goal once at the
start (one event). Live means on the roster and not crashed.

**Eligibility and redraw.** Each event's type is drawn from the mix. If the drawn type is not eligible (rules below),
it is redrawn from the full mix, up to 10 times; after that the event is a `note`. Eligibility:
- `join`: fewer than N agents live. The newcomer takes the next name from the pool.
- `leave`: at least 2 live agents besides `lead` (and, inside a P7 window, not `me`). A random eligible agent leaves.
- `answer`: an open question addressed to the actor or to everyone, not sent by the actor, exists.
- `done`, `dropped` with reply_to: the actor owns or may take (D7) an open todo.
- `claim` (see Claims): a claim of the drawn sort is possible.
- `release`: the actor holds a live claim.

**Crashes.** Separately from E, after each event a live agent other than `lead` (and, inside a P7 window, other than
`me`) crashes with the mix's crash probability. It never acts again, writes nothing to either arm, and stays on the bus
roster (D1). Crash probability per event: sparse 0.002, busy 0.004, handoff-heavy 0.008.

**Recipients.** A message goes to everyone with the mix's broadcast share, else to one named agent other than the
actor. The named recipient is, with probability 0.10 when any agent has left, drawn uniformly from agents that have
left (so a todo to an owner who already left, the hard case of D7, occurs at a registered rate); otherwise uniformly
from the agents on the roster (crashed ones included, since others cannot tell).

**Claims.** Each claim event is, by the mix's shares, a renewal, a takeover or a new claim. Precedence: a renewal (the
actor claims again a resource it holds live) and a takeover (`claim RESOURCE --from HOLDER` on a resource another agent
holds live) are exempt from the no-overlap rule; a new claim must overlap no live claim of any agent. A renewal needs a
live claim of the actor; a takeover needs a live claim of another agent (it takes that exact resource from its
holder); a new claim draws a resource uniformly among the pool's resources that overlap no live claim. Resources are an
item folder `src/SLUG/` (probability 0.3) or one of its files `src/SLUG/fN.py`. Every claim uses the default 120-minute
TTL. Claims are never refused, so the bus logs no refusal.

**Takeover expansion.** A takeover is one event in E. On the bus it ends the old holder's claim, starts the new one,
logs `claim_taken` and inserts an `alert` message (the next message id, same time, topic `claim`) from the new holder
to the old one, with the body `NEW took your claim on RES with claim --from and now holds RES (purpose: "P").` The
ledger renders it as a `TAKEOVER` line followed by that `ALERT` line with the same id, body and time. The fixture
checks this parity.

**Topics.** A decision gets topic `decision` with probability 0.95, else an item slug (that message is not a D8
decision); this rule overrides the general topic rule. Every other message gets an item slug as topic with probability
0.6, else none.

**Replies.** `answer` replies to an eligible open question. `done` and `dropped` reply to an eligible open todo, except
that a `done` has no reply_to with probability 0.20 (it closes nothing). With probability 0.05 an answer or done is
sent instead as a `note` replying to the same message, or as an answer replying to a reply (it closes nothing).

**Event mixes** (share of E, per cent):

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
| work items (slug, folder `src/SLUG/`, files `f1.py` to `f4.py`) | 30 | 15 | 20 |
| broadcast share of messages | 0.40 | 0.30 | 0.20 |
| claim events that are renewals | 0.20 | 0.20 | 0.20 |
| claim events that are takeovers | 0.05 | 0.10 | 0.20 |
| long-body share | 0.03 | 0.05 | 0.08 |

**Bodies.** Prose from a fixed corpus, `scripts/ctxbench/corpus.txt`, committed in B-M1 before Stage 1 runs, with its
sha256 recorded in the Change log. The corpus is generated once by this rule: 200 lines, one English sentence each, of
engineering coordination prose (status, intent, findings, requests) written for this benchmark; each line 40 to 200
bytes of printable ASCII, with a corpus mean between 90 and 130 bytes; no line contains an agent name, `kind=`, `eid=`
or a line break. A normal body is k sentences drawn with replacement, k uniform on 1 to 6, joined by a space. A long
body is k uniform on 12 to 30 (usually over 2,048 bytes, so a listing cuts it). A handoff body is
`BRANCH; STATE; NEXT STEP; CHECKS`, each part one corpus sentence (the branch part prefixed `branch ` and a slug). A
decision body is a normal or long body followed by a line break and `Subject: SLUG`. A fact value is one sentence.

**Inbox consumption.** After each of its own events, an agent runs a consuming `inbox` with probability 0.5 (the skill
says to read inbox each turn). Consumption moves only that agent's bus cursor; it is not a coordination event and is
not rendered in the ledger (a ledger reader keeps its own private cursor).

**Checkpoints.** The simulator writes E + 20 events. For each (history, probe, instance), the checkpoint index c is
drawn uniformly from [ceil(0.9E), E], `me` uniformly from the agents live at c, and, for P1 to P6, `now` = the time of
event c plus a uniform 1 to 300 seconds. P1 to P6 never see an event after c; P7 sees events up to c+20.

### Clock rule

`AGENTBUS_TEST_NOW` is read once at module load and the clock then runs on with the wall clock. So the replay starts a
fresh process (or re-imports the module with `runpy`) for every simulated event, with `AGENTBUS_TEST_NOW` set to that
event's time, and every reader command runs in its own process with `AGENTBUS_TEST_NOW` set to the reader's `now`. A
process stamps the intended second as long as it finishes within one second of loading; the replay reads back every
stored time after a history is built and treats a mismatch as a replay defect. Every command runs with `TZ=UTC`,
`LC_ALL=C`, `AGENTBUS_NO_UPDATE_CHECK=1` and `AGENTBUS_NO_UPDATE_NOTICE=1`.

## Arms

Each probe runs on a fresh copy of its history (the whole bus folder, or the ledger file) per arm and instance, so
presence and cursor writes never leak between trials. Bus commands run as `agentbus --as ME ...`. Before bytes are
counted, every occurrence of the copy's folder in the output is replaced by the fixed string `/ctxbench`, so a byte
count never depends on a temp path.

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
  followed by its `ALERT`), `RELEASE`, `FACT` (topic = key, text = value) and `GOAL`.
- A leave is rendered as one `RELEASE` per claim it dropped, then `LEAVE`, at the leave's time. A crash writes nothing.
  Inbox consumption writes nothing. Nothing is ever rewritten and there is no state section.

The reference renderer is `render_ledger` in `scripts/ctxbench/fixture_sufficiency.py`; B-M1's renderer must produce
byte-identical output on every fixture history.

### The four arms

- **Bus-default.** The skill's literal start sequence, in `--json` as the skill says to parse: `brief`, then
  `inbox --limit 20 --peek` (peek so a probe never consumes), plus `read --topic decision` for P5 only. Default limits:
  `brief` shows 5 rows per section (`BRIEF_LIMIT`), so at N = 8 a roster-sized answer (P2, P6) is often cut and its
  probe a miss. Those misses are structural, a property of the default, not of a parser. No parser uses the inbox
  output; it is charged because the skill's sequence includes it.
- **Bus-complete.** A registered procedure per probe that is sufficient to derive the answer from its own output, every
  call charged, including `log show` for leave times (P4) and `read --id` for a body a listing cut at 2,048 bytes
  (P5).
- **Ledger-raw.** R3's shell recipes over `COORDINATION.md` (`grep -E`, which every machine has, in place of `rg`), cut
  to the header fields (`cut -d'|' -f1`) wherever the probe needs no body.
- **Ledger-awk** (sensitivity). One registered POSIX awk reducer per probe over the raw file
  (`scripts/ctxbench/ledger_awk/`), printing only the answer. It stands in for the strongest ledger reader short of a
  maintained helper. The reducers' own text is a prepared helper and is not counted as delivered bytes.

### Command table

`GREP(K)` stands for `grep -n -E 'kind=(K)( |$)' COORDINATION.md | cut -d'|' -f1`. `AWK(p, vars)` stands for
`awk vars -f ledger_awk/common.awk -f ledger_awk/p.awk COORDINATION.md`. Bus commands are written without the leading
`agentbus --as ME`.

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

The v1 recipe (`grep 'kind=DECISION .* topic=decision '`, expand the last hit) is not registered: fixture F2 shows two
histories with different answers on which it prints identical text (Codex re-check, finding 4).

**Ledger-raw P7.** The reader keeps a private line cursor and its own state, as R3 allows. Each refresh first runs
`wc -l < COORDINATION.md` (giving n). Refresh 1 then runs `GREP(TODO|DONE|DROPPED|QUESTION|ANSWER|JOIN|LEAVE)`;
refresh k > 1 runs `sed -n 'L,np' COORDINATION.md | grep -n -E 'kind=(TODO|DONE|DROPPED|QUESTION|ANSWER|JOIN|LEAVE)( |$)' | cut -d'|' -f1`
with L one past the previous refresh's n. The bus arms recompute each refresh.

### Reference parsers

Each arm has one registered parser per probe (P7 applies P1's, P3's and P4's at each refresh). A parser sees only the
text its procedure printed and the probe's inputs (`me`, `now`, X, Y). The parsers for P1 to P6 in all four arms are
registered in this commit, in `scripts/ctxbench/fixture_sufficiency.py`, and fixture-tested there; B-M1 imports them
or moves them verbatim with the fixture still passing, and does not rewrite them. Ledger-raw's P7 parser (state carried
between refreshes) and the Bus-default P7 refresh parser are written in B-M1 and pass a P7 fixture before Stage 1
runs. Every parser:
- filters claims by `expires_at > now` (D5), never by the bus's `state` field;
- excludes `me`'s own questions in P3 by sender;
- returns "no answer" (a miss) when an evidence source the probe needs is incomplete, as below.

**Completeness, per probe and source.** A source is incomplete when it says rows were left out (`has_more`,
`omitted.<section>`, `claims_omitted`), was cut by the output cap, or does not parse. Only the sources the probe uses
count; an omitted roster, for example, does not invalidate a complete todo list.

| Probe | Bus-default needs complete | Bus-complete needs complete | Ledger arms |
| --- | --- | --- | --- |
| P1 | `brief` todos | `brief` todos | the command's output |
| P2 | `brief` agents and each agent's claims | `claims` | the command's output |
| P3 | `brief` questions | `brief` questions | the command's output |
| P4 | `brief` todos, and no open todo whose owner is off the roster (no leave times: structural miss) | `brief` todos, `log` | the command's output |
| P5 | the newest decision present with its whole body | the newest decision present; its whole body after `read --id` | the commands' output |
| P6 | `brief` agents, claims and todos | `claims`; `brief` todos | the command's output |

**Output cap.** Every measure is reported twice: uncapped, and with each call's output cut at 30,000 characters (the
default cap of a common agent harness), followed by the line `[ctxbench: output cut at 30000 characters]`. A cut
source is incomplete. Capped bytes count what was kept plus the marker line.

## Sufficiency fixtures

`scripts/ctxbench/fixture_sufficiency.py`, run by `tests/test_ctxbench_fixture.sh` in the suite, builds hand-derived
histories with the real CLI (one process per timestamp), renders each ledger, and checks every arm's procedure and
parser on a fresh copy. A procedure that fails is not registered.

- **F1 (N1).** lead, alice, bob and carol join at 11:50; lead posts todo #1 to carol and #2 to bob at 12:10; carol
  leaves at 12:20; bob leaves at 12:00 (history A) or 12:20 (history B). Checkpoint 12:30, `me` alice. P4 = {1} in A
  and {1, 2} in B for Bus-complete, Ledger-raw and Ledger-awk; Bus-default prints identical text for A and B, so its
  P4 is a structural miss; without `log show` or the `LEAVE` lines the two histories read the same.
- **F2 (Codex finding 4).** Decision #1 with the subject on a continuation line (`parser` in A, `uploader` in B), then a
  note whose body quotes a decision header. P5 = (1, parser) and (1, uploader) in every arm; the v1 Ledger-raw recipe
  prints identical text for A and B.
- **F3.** An expired claim, a claim whose expiry equals `now` (not live, though the 0.4.0 `claims` listing calls it
  held), a takeover, a todo closed by a linked `done`, a question replied to only by a note and an answer to that
  note, a broadcast question answered, `me`'s own broadcast question, and a claimed then released folder. P1 = {2},
  P3 = {5}, P2 for four paths, P6 for three items, every arm.
- **Parity.** In every fixture history, the bus's messages, the takeover's alert included, equal the ledger's message
  lines (id, kind, sender, recipient, topic, reply_to, body).

## Oracle

1. **Independent.** The oracle (`scripts/ctxbench/oracle.py`, B-M1) is written from this document by a lane that has
   not read `bin/agentbus`, and folds the simulator's semantic event list with D1 to D8.
2. **Hand fixtures first.** It must pass F1 to F3 and these before Stage 1 runs: a `done` with no reply_to closes
   nothing; a broadcast todo's owner is its sender; a decision with another topic is not a D8 decision; a decision whose
   subject sits past byte 2,048 of its body; an owner who left and rejoined makes the todo not takeable; a crashed
   holder's claim stays live until it expires.
3. **Three-way agreement.** For every instance Stage 1 records the oracle's answer and each arm's parser answer, and
   reports agreement between the oracle and each parser per cell.
4. **Disagreement.** A bus arm whose procedure was complete but whose answer disagrees with the oracle is scored a miss
   (a bus error) in the primary analysis and filed as an issue; a rerun on a corrected bus is reported as secondary
   only.

**Voiding.** Only a simulator or replay defect proven by a new failing fixture voids a run, and voiding reruns every arm
of that seed, never only the arm that looked wrong.

## Measures

Per instance and arm, uncapped and capped:
- **Delivered bytes**: UTF-8 bytes of the output of every call in the procedure, summed (after path normalisation).
- **Derivability**: 1 when the arm's parser returns the oracle's answer, else 0 (a miss, including "no answer").
- **Calls** in the procedure.

## Analysis

- **Unit.** The seed. Each (N, E, mix, probe) cell has 30 seeds and M = 10 instances per seed. Per seed and arm: mean
  bytes b over its instances, and derivability rate r over its instances.
- **Bytes ratio** (arm A over arm B, per cell). Point estimate: the ratio of seed means, mean_s b_A(s) / mean_s
  b_B(s). Interval: the per-seed log ratios d_s = ln(b_A(s) / b_B(s)) get a two-sided 95 per cent t interval (29 degrees
  of freedom), exponentiated; the decision rules below use this interval (a geometric-mean ratio). The per-seed values
  are published with the results.
- **Derivability.** Per arm, the mean of r over seeds with a two-sided 95 per cent seed-level t interval. Differences
  (arm A minus arm B) use the per-seed differences r_A(s) - r_B(s) the same way. When every per-seed value is equal
  (for example every instance derivable in both arms), the t interval is undefined: the result is reported as the exact
  counts, and its one-sided bound is the exact binomial bound on the instances (for 300 of 300, a miss rate below 1.23
  per cent at one-sided 97.5 per cent).
- **One convention.** Every interval in Stage 1 is two-sided 95 per cent at the seed level; every test below is the
  matching one-sided t test (alpha 0.025 per side). In the all-equal case the non-inferiority p is exact: with zero
  Bus-default misses among n instances where Ledger-raw also had none, p = 0.95^n (H0: a miss rate of at least 5 per
  cent); with all per-seed differences equal to a value c, p = 0 when c > -0.05 and 1 otherwise.
- **Comparisons** per cell: Bus-default / Ledger-raw (the hypotheses), Bus-complete / Ledger-raw, Ledger-awk /
  Ledger-raw, and Bus-default / Bus-complete (whether `brief`'s defaults lose answers, the B-M3 question).

### Hypotheses (Stage 1, Bus-default against Ledger-raw, uncapped)

- **H1** (secondary). At E = 50, for each N, mix and probe, the bytes ratio's interval lies inside the equivalence band
  [0.8, 1.25]. An interval that contains 1.0 but leaves the band is inconclusive, not equivalence.
- **H2** (primary family). At E = 5000, Bus-default is non-inferior on derivability (margin -5 percentage points) and
  the bytes ratio's upper bound is below 0.5.
- **Primary family.** N = 8, busy mix, E = 5000, probes P1, P2, P3, P4, P7: five H2 tests, Holm-corrected at
  family-wise alpha 0.025 (one-sided). Each test's p-value is the larger of the non-inferiority p (one-sided t test of
  mean r difference > -0.05) and the ratio p (one-sided t test of mean d_s < ln 0.5): H2 needs both (an
  intersection-union test).
- Everything else (H1, P5, P6, other cells, capped results, the other comparisons) is secondary, with the same
  intervals and no correction. A secondary win cannot rescue a primary null.

### Decision table (per cell and comparison)

Applied top to bottom; the first row that matches is the cell's label.

| Order | Row | Rule |
| --- | --- | --- |
| 1 | derivability loss | the derivability difference's upper bound is below -0.05 |
| 2 | derivability not shown | the derivability difference's lower bound is below -0.05 |
| 3 | cheaper by half | bytes ratio upper bound below 0.5 |
| 4 | equivalent | bytes ratio interval inside [0.8, 1.25] |
| 5 | cheaper | bytes ratio upper bound below 1.0 |
| 6 | more expensive | bytes ratio lower bound above 1.0 |
| 7 | inconclusive | anything else |

Rows 1 and 2 report the bytes ratio beside the label but never as a saving.

**Study-level rule.** The result says "the derived views save at least half the text at scale" only if H2 holds,
after Holm, for all five primary probes; "for some probes" names the ones it holds for; otherwise "not shown". A
derivability loss (row 1) on any primary probe is reported first, before any saving. A Bus-default loss to Bus-complete
(row 1 in that comparison) is reported as "`brief`'s default limits are the wrong default" and is B-M3's input.

## Seeds

Thirty base seeds, fixed now and used in every cell so arms and cells are paired:

`4127, 9341, 1586, 7203, 2648, 5519, 8872, 3065, 6794, 1930, 2417, 8156, 3742, 6081, 1299,`
`7534, 4860, 9617, 5203, 3388, 7915, 1046, 6452, 2771, 8309, 4594, 9022, 5867, 3150, 7688`

A history's seed is the first 8 bytes, big-endian, of `sha256("SEED:N:E:MIX")`; an instance's draws use
`sha256("SEED:N:E:MIX:PROBE:INSTANCE")`. Stage 1 runs 2 x 3 x 3 x 7 x 4 x 30 x 10 = 151,200 procedure runs. It costs
CPU time only.

## Budget

Stage 1 spends no tokens. Its runner refuses to start if any model credential or harness is configured in its
environment.

## Threats to validity

**Toward agentbus:**
- The bus procedures and this document were written by the tool's authors. Mitigations: R3's format and recipes, the
  Ledger-awk sensitivity arm, the independent oracle, and publication of one full ledger per cell.
- Ledger-raw gets no prepared helper, so a bus win here says nothing against the protocol on a Markdown transport.
- Bus errors that the oracle shares would be invisible; the oracle is written without reading the code.

**Toward the ledger:**
- No refused claims, no name reuse, no malformed rows, no concurrency: the bus's atomicity and hostile-data handling
  earn nothing. This is the read side only.
- Ledger-raw's P7 keeps a private cursor and state; the bus arms recompute each refresh.
- Bus-complete's `log show --limit -1` returns the whole log, including events P4 does not need.
- Ledger-awk's reducer text is not counted, and every ledger line holds a whole event, so `grep` returns exactly the
  events needed; a ledger written by agents would be messier.
- Bus output is JSON, which may cost more tokens per byte than Markdown or less; Stage 1 says nothing about tokens.

**Either way:**
- Simulated histories and one corpus; the three mixes are a sensitivity check, not a guarantee.
- Checkpoints sit in the last tenth of a history, so "history size" means E events.
- Code reads the procedures; a model may read fewer or more. Stage 3 measures that.

## Appendix: Stage 3 requirements (registered separately after Stage 1)

Stage 3 (a model with a shell answers the probes) is not registered by this document. Its own pre-registration,
written after Stage 1's results, must contain at least the following, each made concrete:

1. **Inference at the seed level.** Seeds are the unit (clusters); per-seed paired differences and per-seed log
   ratios with t intervals, or exact sign-flip tests. No instance-level tests that treat a seed's instances as
   independent.
2. **More seeds over more instances**, for example 30 seeds x M = 2 rather than 10 x 5.
3. **Power shown by clustered simulation** of the complete decision procedure (including Holm), covering perfect ties,
   heavy-tailed per-seed costs and every permitted scope cut.
4. **The H2 denominator** is each logged tool result tokenized once with the provider's own count of that exact text;
   no bytes-to-tokens calibration factor.
5. **Ratios per model**, never silently pooled across models.
6. **Admission** that reserves a worst case enforced per request (a hard output limit and a hard tool-result limit,
   both in tokens) before dispatch, and charges unknown or missing usage pessimistically.
7. **Whole paired seed blocks admitted before they start**, a fixed block order, arms interleaved inside a block, a
   rule for every incomplete block, and a minimum confirmatory sample.
8. **A pilot blinded to arm outcomes**: it reports usage and errors only, never correctness or ratios by arm.
9. **A decision table** with rows for inferior, cheaper but not by half, and the others, a precedence order, and a
   study-level rule.
10. **Failures after the first tool call are arm outcomes**, never infrastructure replacements.
11. **An exact answer-extraction rule** (the JSON object, where it must appear, what counts as unparseable).
12. **Interpreter parity**: every arm's commands run through a wrapper with an absolute interpreter path; `python3` is
    absent from PATH in every arm, and the harness asserts it before each trial.
13. **A P7 delivery specification**: how refreshes and interleaved events reach the model, and what each refresh
    prompt says.
14. **The harness output cap** decided as part of the treatment (and then equal for all arms of a model) or raised
    above every arm's largest output.
15. Whether each arm is an enforced procedure or an instruction package, with permitted actions, batching, scratch
    state, call counting, and how departures from the arm's procedure are reported.

## Change log

Every change after this document merges is a new dated entry here, appended below: a registration repair with the
failing fixture that proves it, or a value this document says is recorded later (the corpus hash, the spec's `P-`
ids). Nothing above is ever edited.
