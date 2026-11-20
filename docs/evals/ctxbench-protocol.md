# ctxbench protocol (pre-registration)

Written and committed before any code computes a study number (issue #80, milestone B-M0). Nothing here may be edited
after the first counted call; every later change is a dated entry in the Change log at the end, with its reason, and
the text above it stays as it was.

## The question

As coordination history grows, how many tokens does an agent spend to learn the state it needs, and how often is it
right, when it uses the protocol's derived views (`brief`, inbox, open todos, live claims) instead of reading the raw
history with shell tools? This is a protocol question, not a storage one. The baseline is the same protocol kept as
raw text: one append-only Markdown file, ordinary shell tools, no helper and no maintained summary. A ledger with a
locking helper and reducers is the protocol on a second transport and belongs to a later study.

"The views save nothing", "the raw ledger wins" and "inconclusive" are all valid results and are reported as plainly
as a win.

## Stages

| Stage | What reads | Spends tokens | Measures |
| --- | --- | --- | --- |
| Stage 1 | a registered command list per arm and probe, run by code | no | delivered bytes, derivability |
| Stage 3 | a model with a shell over its arm's copy (B-M2) | yes | provider usage, tool calls, correctness |

There is no Stage 2 (dropped in runbook v2). Stage 1 runs the whole grid. Stage 3 runs a subset (Scope, below).

## Derived views (the semantics both arms are told)

These are the definitions every probe and the oracle use, written from agentbus 0.4.0 (`bin/agentbus` at `137f6e8`).
Once the spec PR for A-M1 (#79) lands, each gets the matching `P-` id from `docs/protocol.md` through a Change log
entry; a disagreement between this text and the spec is resolved in favour of the spec by that entry, before any
counted call. The same text goes, word for word, into the preamble of every arm.

- **D1 Roster.** An agent is on the roster from its `join` until its `leave`; a later `join` puts it back. A crashed
  agent never left, so it stays on the roster (`cmd_leave`, `bin/agentbus:4320`).
- **D2 Owner of a todo.** The named recipient, or the sender when the todo went to everyone (`_brief_open_todos`,
  `bin/agentbus:14293`).
- **D3 Open todo.** A message of kind `todo` with no message of kind `done` or `dropped` whose `reply_to` is its id.
  Nothing else closes it: not a reply of another kind, not a reply to a reply, not a `done` without `reply_to`, not
  reading, leaving or a claim expiring (`TODO_CLOSERS`, `bin/agentbus:98`; `open_todo_where`, `:14257`).
- **D4 Open question.** A message of kind `question` with no message of kind `answer` whose `reply_to` is its id. An
  answer closes only the message it replies to (`open_question_where`, `bin/agentbus:14247`).
- **D5 Live claim.** A claim row with `expires_at > now`. A claim lasts 120 minutes from its last `claim` of that
  resource by that holder; `release`, `leave` and a takeover (`claim --from`) end it (`_CLAIM_LIVE`,
  `bin/agentbus:4708`).
- **D6 Overlap.** Two resources overlap when they are equal, or one path is a folder holding the other, with or
  without the trailing `/` (`overlaps`, `bin/agentbus:3747`).
- **D7 Takeable todo.** An open todo I may take: its owner is me, or its owner is not on the roster now and a `leave`
  by that owner is recorded at or after the todo's time (`leave.ts >= todo.ts`, whole seconds). A todo whose owner is
  on the roster, never joined, or crashed is not takeable (`_brief_next`, `bin/agentbus:14315`, the query at `:14333`).
- **D8 Decision.** A message of kind `decision` with topic `decision`, as the skill records one
  (`skills/agentbus/SKILL.md`, "Record a decision"). Its subject is the text after `Subject: ` on the last line of its
  body.

## Probes

Every probe names an agent (`me`) and a checkpoint time (`now`); both are given to every arm. The answer is scored
against the oracle exactly (set equality, or equality of the pair for P5).

| Probe | Question | Answer |
| --- | --- | --- |
| P1 | My open todos | ids of open todos (D3) whose owner (D2) is `me` |
| P2 | Who holds path X | names holding a live claim (D5) that overlaps X (D6) |
| P3 | Questions to me with no answer | ids of open questions (D4) sent to `me` or to everyone, not sent by `me` |
| P4 | Todos I may take | ids of takeable todos (D7) |
| P5 | The latest decision | `(id, subject)` of the decision (D8) with the largest id, or `null` |
| P6 | Is anyone already working on Y | names of agents that hold a live claim overlapping `src/Y/`, or own an open todo with topic `Y` and are on the roster |
| P7 | Session: what is on my plate, K=5 times | at each refresh, the triple (P1, P3, P4); scored correct only if all 5 refreshes are |

P7 runs one session over one copy: refresh 1 at the checkpoint, then 10 further simulated events, refresh 2, and so
on to refresh 5 (40 interleaved events in all). Its token measure is the sum over the five refreshes.

Targets: X in P2 is, with probability 1/2, a file under a path some live claim covers at the checkpoint, else a file
drawn uniformly from the mix's path pool. Y in P6 is, with probability 1/2, an item someone is working on, else drawn
uniformly from the item list. Both draws come from the seed.

## Histories

A seeded simulator (`scripts/ctxbench/sim.py`, B-M1) writes one semantic event list per history. Both arms are
rendered from that one list; neither gets padding the other lacks.

**Grid.** N in {5, 8} agents; E in {50, 1000, 5000} events; three mixes. 18 histories per seed.

**Agents.** `lead` plus N-1 agents named from a fixed list of 40 first names, joined at the start (these N joins
count toward E). `lead` never leaves or crashes and sets the goal once at the start (one event). A `leave` takes a
random live agent other than `lead`; a `join` brings in a new name (never a reused one) when fewer than N agents are
live, and is otherwise redrawn. A crash picks a live agent other than `lead`, which then never acts again; it writes
nothing to either arm and stays on the bus roster. Crash rate per event: sparse 0.002, busy 0.004, handoff-heavy
0.008 (not counted in E).

**Event mixes** (share of E, per cent; the actor is a uniformly drawn live agent unless the event says otherwise):

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
| claim (new, renewal or takeover) | 18 | 14 | 12 |
| release | 14 | 10 | 8 |
| fact (`ctx set`) | 5 | 2 | 2 |
| join | 2 | 1 | 2 |
| leave | 1 | 1 | 2 |
| total | 100 | 100 | 100 |

| Parameter | sparse | busy | handoff-heavy |
| --- | ---: | ---: | ---: |
| mean seconds between events (exponential, rounded, 0 allowed) | 120 | 20 | 45 |
| work items (slugs; path `src/SLUG/`) | 30 | 15 | 20 |
| files per item | 4 | 4 | 4 |
| broadcast share of messages | 0.40 | 0.30 | 0.20 |
| topic set to an item slug | 0.60 | 0.60 | 0.60 |
| long body (12 to 30 sentences, usually over 2048 bytes) | 0.03 | 0.05 | 0.08 |
| answer or done sent as a non-closing kind (note), or replying to a reply | 0.05 | 0.05 | 0.05 |
| done with no `reply_to` (closes nothing) | 0.20 | 0.20 | 0.20 |
| decision with a topic other than `decision` (not a D8 decision) | 0.05 | 0.05 | 0.05 |
| takeover share of claim events | 0.05 | 0.10 | 0.20 |

Answers reply to an open question addressed to the answerer or to everyone; `done` and `dropped` reply to an open todo
the actor owns or may take (D7). Claims are on an item folder or one of its files, never refused: the simulator only
claims a resource no live claim overlaps, and a takeover names the current holder with `--from`. Every claim uses
the default 120-minute TTL. The clock starts at 2026-11-19T09:00:00Z.

**Bodies.** Realistic prose from a fixed corpus (`scripts/ctxbench/corpus.txt`, 200 sentences of engineering
coordination prose, committed in B-M1 with its sha256 recorded in the Change log before any counted call). A normal
body is 1 to 6 sentences. A handoff body follows the skill's shape `BRANCH; STATE; NEXT STEP; CHECKS`. A decision
body ends with the line `Subject: SLUG`.

**Inbox consumption.** After each of its own events, an agent runs a consuming `inbox` with probability 0.5 (the
skill: read inbox each turn and between steps). Consumption moves only that agent's bus cursor; it is not a
coordination event and is not rendered in the ledger (a ledger reader keeps its own private cursor).

**Checkpoints.** The simulator writes E + 40 events. For each (history, probe, instance) the checkpoint index c is
drawn uniformly from [ceil(0.9E), E], `me` uniformly from the agents live (on the roster, not crashed) at c, and
`now` = time of event c plus a uniform 1 to 300 seconds. P7's interleaved events are events c+1 to c+40. P1 to P6
never see an event after c.

### Clock rule

`AGENTBUS_TEST_NOW` is read once at module load and the clock then runs on with the wall clock
(`bin/agentbus:103-122`). So the replay starts a fresh process (or re-imports the module with `runpy`) for every
simulated event, with `AGENTBUS_TEST_NOW` set to that event's time in whole seconds, and every reader command in every
arm runs in its own process with `AGENTBUS_TEST_NOW` set to the checkpoint's `now`. A process stamps the intended
second as long as it finishes within one second of loading; the replay reads back every stored `ts` after a history
is built and treats any mismatch as a replay defect (see Voiding). Every reader command runs with `TZ=UTC` and
`LC_ALL=C`, so text times are the same on every machine.

## Arms

Each probe runs on a fresh copy of its history (the whole bus folder, or the ledger file) per arm, so presence and
cursor writes (`bin/agentbus:14921-14928`) never leak between trials. Bus commands run as `agentbus --as ME ...`.

### Ledger-raw file format

One file, `COORDINATION.md`, in R3's event format (research `r3-codex.md` section 1) without the helper:

```text
# COORDINATION.md

Append-only. One event per line; continuation lines of a body are indented two spaces.
Fields: eid ts kind id from to topic path reply_to | text. '-' means none; to=all is a broadcast.

- eid=E7 ts=2026-11-19T12:10:00Z kind=TODO id=1 from=lead to=carol topic=parser path=- reply_to=- | Carol, please ...
```

- One line per event, fields in the fixed order shown. `eid` counts events from 1 in file order; `ts` is the bus time
  (ISO UTC, whole seconds); `id` is the bus message id for a message and `-` otherwise; `to=all` is a broadcast.
- Metadata values are percent-encoded so they hold no space, `|`, `%`, `=`, tab or newline (`%20`, `%7C`, ...).
- Kinds: message kinds in capitals (`NOTE QUESTION ANSWER HANDOFF DECISION ALERT DONE TODO DROPPED`), plus `JOIN`,
  `LEAVE`, `CLAIM` (path = resource, text = purpose; also a renewal), `TAKEOVER` (from = new holder, to = old holder),
  `RELEASE`, `FACT` (topic = key, text = value) and `GOAL`.
- A `leave` is rendered as one `RELEASE` per claim it dropped, then `LEAVE`, all at the leave's time. A crash writes
  nothing. Inbox consumption writes nothing.
- The header carries no state section, and nothing is ever rewritten.

The reference renderer is `render_ledger` in `scripts/ctxbench/fixture_sufficiency.py`; B-M1's
`render_ledger.py` must produce byte-identical output for the fixture's two histories.

### Command table

Bus-default runs the commands the skill names, at their default limits, in text. Bus-complete runs a registered
procedure per probe that is sufficient to derive the answer from its own output, every call charged. Ledger-raw runs
R3's shell recipes (`grep -E` rather than `rg`, which is not on every machine; the patterns are R3's).

| Probe | Bus-default | Bus-complete | Ledger-raw |
| --- | --- | --- | --- |
| P1 | `brief`; `inbox --peek`; `read` | `--json brief --limit -1` | `grep -n -E 'kind=(TODO\|DONE\|DROPPED)( \|$)' COORDINATION.md` |
| P2 | `brief`; `inbox --peek`; `read` | `--json claims --limit -1` | `grep -n -E 'kind=(CLAIM\|TAKEOVER\|RELEASE\|LEAVE)( \|$)' COORDINATION.md` |
| P3 | `brief`; `inbox --peek`; `read` | `--json brief --limit -1` | `grep -n -E 'kind=(QUESTION\|ANSWER)( \|$)' COORDINATION.md` |
| P4 | `brief`; `inbox --peek`; `read` | `--json brief --limit -1`; `--json log show --limit -1` | `grep -n -E 'kind=(TODO\|DONE\|DROPPED\|JOIN\|LEAVE)( \|$)' COORDINATION.md` |
| P5 | `brief`; `inbox --peek`; `read --topic decision` | `--json read --topic decision --limit -1`; then `--json read --id N` for the newest decision when its body was cut | `grep -n -E 'kind=DECISION .* topic=decision ' COORDINATION.md`; then `sed -n 'L,$p' COORDINATION.md \| awk 'NR>1 && /^- eid=/{exit} {print}'` for the last hit's line L |
| P6 | `brief`; `inbox --peek`; `read` | `--json claims --limit -1`; `--json brief --limit -1` | `grep -n -E 'kind=(CLAIM\|TAKEOVER\|RELEASE\|JOIN\|LEAVE\|TODO\|DONE\|DROPPED)( \|$)' COORDINATION.md` |
| P7 (each refresh) | `brief`; `inbox` (consuming) | `--json brief --limit -1`; `--json log show --limit -1` | refresh 1: `grep -n -E 'kind=(TODO\|DONE\|DROPPED\|QUESTION\|ANSWER\|JOIN\|LEAVE)( \|$)' COORDINATION.md`; later: `tail -n +L COORDINATION.md` from the line after the last one read |

(`\|` above is a table escape; the command has a plain `|`.) Bus-default uses `inbox --peek` for P1 to P6, so a probe
never consumes; P7 is a session, so it consumes as the skill says. The P7 Ledger-raw reader keeps a private line
cursor and its own state between refreshes, which R3 allows; the bus arms recompute each refresh.

**Registration rule.** A Bus-complete or Ledger-raw procedure is registered as sufficient only after the sufficiency
fixture (below) and B-M1's hand fixtures show its reference parser derives the oracle's answer from its returned text
alone. A procedure that fails is a registration defect, fixed by a Change log entry before Stage 1 runs; it is never
patched after results exist.

### Stage 3 readers (B-M2)

- **Interface.** One Anthropic model through `claude -p` (stream-json) and one OpenAI model through `codex exec
  --json`, each with only a shell tool, in a scrubbed environment with a temp HOME, cwd = the arm's fresh copy.
- **Tools.** A POSIX shell with `grep`, `sed`, `awk`, `tail`, `head`, `wc`, `sort`, `uniq`, `cut`, `cat`, `ls`, and in
  the bus arms `agentbus` on PATH. No other interpreter is on PATH in either arm, so a reader may script with `awk`
  and the shell but brings no prepared helper. `rg` is not provided.
- **Output limit.** Each harness's own tool-output truncation applies, identically in every arm for that model:
  Claude Code with `BASH_MAX_OUTPUT_LENGTH=30000`; the Codex value is recorded in the model table below.
- **Preamble.** Matched in length within 10 per cent across arms: "You are ME, already joined; the time now is NOW;
  answer the probe in JSON", the D1 to D8 definitions, and the arm's commands from the table above (Bus-default: the
  skill's commands and that `--limit -1` and `--json` exist; Bus-complete: its procedure; Ledger-raw: the file format
  and recipes).
- **Ceiling.** 12 tool calls per trial (6 per refresh in P7), 10 minutes wall time per trial. Calls are an outcome,
  not the budget. A trial that hits a ceiling without an answer is scored incorrect, never dropped.
- **Answer.** One JSON object: `{"ids": [...]}` (P1, P3, P4), `{"names": [...]}` (P2, P6), `{"id": N, "subject":
  "SLUG"}` or `{"id": null}` (P5); P7 answers that triple after each refresh. Anything that does not parse is
  incorrect.

## Sufficiency fixture

Before the simulator exists: two histories that differ only in when bob left.

| Time | Both histories | History A | History B |
| --- | --- | --- | --- |
| 11:50 | lead, alice, bob, carol join | | |
| 12:00 | | bob leaves | |
| 12:10 | lead posts todo #1 to carol, todo #2 to bob | | |
| 12:20 | carol leaves | | bob leaves |
| 12:30 | checkpoint, `me` = alice | | |

Expected P4 answer: A = {1}, B = {1, 2} (D7: bob's leave in A precedes todo #2).

`scripts/ctxbench/fixture_sufficiency.py` builds both with the real CLI under a temp HOME, one process per timestamp,
renders the ledger, runs every registered P4 procedure on a fresh copy, and asserts that a reference parser given only
the returned text derives {1} and {1, 2}. It also asserts that Bus-default returns identical text for A and B (so it
cannot derive P4 here: the documented gap), and that without `log show` (bus) or the `LEAVE` lines (ledger) the two
histories read the same. `tests/test_ctxbench_fixture.sh` runs it in the suite. It computes no study numbers.

## Oracle

1. **Hand fixtures first.** The oracle (`scripts/ctxbench/oracle.py`, B-M1) must pass these before anything runs:
   F1 the two-history fixture above; F2 an answer that replies to an answer closes no question (only the direct
   reply closes one); F3 a `done` with no `reply_to` closes nothing; F4 a claim with `expires_at == now` is not live; F5 a
   broadcast todo's owner is its sender; F6 a decision with another topic is not a D8 decision; F7 a decision whose
   subject sits past byte 2048 of its body; F8 an owner who left and rejoined makes the todo not takeable; F9 a
   crashed holder's claim stays live until it expires.
2. **State machines from the spec.** The oracle folds the simulator's semantic event list with D1 to D8. It is written
   from this document and the spec, never by importing or calling `bin/agentbus`.
3. **Disagreement is a bus error.** When a bus arm's derived answer disagrees with the oracle and the oracle passes its
   fixtures, the trial is scored incorrect in the primary analysis and the case is filed as an issue. A rerun on a
   corrected bus is reported as secondary only.

### Voiding

Only a simulator or replay defect proven by a fixture (a new hand fixture that fails on the old code and passes on the
fix) voids a run. Voiding reruns every arm of that seed, never only the arm that looked wrong. Timeouts, ceilings,
wrong answers, unparseable answers and bus errors all stay in.

## Measures

**Stage 1** (no tokens spent):
- Delivered bytes per procedure: the UTF-8 bytes of stdout of every call, summed. Reported as estimated tokens =
  bytes / 4, labelled an estimate, and as calibrated tokens = bytes x k(arm, model), where k is the provider token
  count per byte measured in Stage 3 for that arm and model.
- Derivability: the arm's reference parser (`scripts/ctxbench/parsers.py`) computes the answer from the returned text
  alone; if it does not equal the oracle's answer, the probe is a miss for that arm. A parser that sees a listing
  marked incomplete (`has_more`, `omitted`, `... N more`) returns "no answer", which is a miss.
- Calls per procedure.

**Stage 3** (per trial):
- Provider usage per request, split into uncached input, cache write, cache read and output (normalised in Token
  accounting, below).
- Newly delivered retrieval tokens (the H2 denominator, below), cumulative input exposure, and cost at list price.
- Tool calls, ceiling hits, wall time.
- Correctness of the JSON answer against the oracle.

## Token accounting

| Field | Anthropic (`claude -p --output-format stream-json`) | OpenAI (`codex exec --json`) |
| --- | --- | --- |
| uncached input | `usage.input_tokens` | `usage.input_tokens - usage.cached_input_tokens` |
| cache write | `usage.cache_creation_input_tokens` | not reported: recorded as null, never as 0 |
| cache read | `usage.cache_read_input_tokens` | `usage.cached_input_tokens` |
| output | `usage.output_tokens` | `usage.output_tokens` (reasoning included; `reasoning_output_tokens` also recorded when present) |
| granularity | per assistant message | per turn (`turn.completed`) |

- **Newly delivered retrieval tokens** (H2's denominator): the tokens of the arm's tool results, each counted once,
  when it first enters the context. Measured as the growth of total input (uncached + cache write + cache read)
  between consecutive requests minus the previous request's output, summed over requests that follow a tool result.
  Where the interface reports only per-turn totals, it is bytes x k(arm, model) with k calibrated on that model's
  per-request data in the pilot, and labelled calibrated.
- **Cumulative input exposure**: the sum of total input over every request in the trial (what the context costs as it
  is re-read). Reported beside H2, never in place of it.
- **Cost**: list price per million tokens for each field, from the model table, reported beside both.
- A trial with any request missing usage stops the batch (Budget) and is rerun once as an infrastructure failure.
- The field names above are checked against a real trace of each interface in the pilot; a mismatch is fixed by a
  Change log entry before any counted call.

**Models (frozen before the pilot; filled by the maintainer in a Change log entry, never edited here):**

| Provider | Exact model id | Interface and version | Reasoning or effort setting | Tool output limit | List price (in / cache write / cache read / out, per MTok) |
| --- | --- | --- | --- | --- | --- |
| Anthropic | | `claude` CLI | | 30000 chars | |
| OpenAI | | `codex` CLI | | | |

## Analysis

- **Unit.** The seed. Each (N, E, mix, probe) cell has 10 seeds; Stage 1 draws M = 10 probe instances per seed
  (checkpoint and `me`), Stage 3 M = 5. Instances of one seed are a cluster, never independent replicates.
- **Token ratio.** Per cell and arm pair, the paired ratio-of-means estimator R = sum over trials of arm tokens / sum
  over the same trials of Ledger-raw tokens (Bus-default over Ledger-raw for the hypotheses; Bus-complete over
  Ledger-raw and Bus-default over Bus-complete reported beside it). Interval: seed-clustered percentile bootstrap,
  B = 10000 resamples of seeds with replacement, `random.Random(20261119)`, 95 per cent two-sided.
- **Accuracy.** Per cell, the paired difference in correct (Stage 3) or derivable (Stage 1) rate, Bus-default minus
  Ledger-raw, over instances (Stage 3: both models pooled, n = 100 per arm per cell; each model also reported).
  Non-inferiority margin -5 percentage points, one-sided alpha 0.05: the lower bound of the two-sided 90 per cent
  Tango score interval for paired proportions must exceed -0.05. The seed-clustered bootstrap lower bound (same B and
  RNG seed) is reported beside it, and when it is lower than Tango's, the bootstrap bound governs.
- **Reported cells.** Every (N, E, mix, probe) cell in Stage 1 and every Stage 3 cell, with both intervals,
  including the ones that go against the tool.
- **Primary family.** Stage 3, busy mix, E = 5000, N = 8, probes P1, P2, P3, P4, P7: five H2 tests, Holm-corrected at
  family-wise alpha 0.05. Each test's p-value is the larger of the non-inferiority p-value (Tango score test of
  H0: difference <= -0.05) and the ratio p-value (share of bootstrap ratios >= 0.5): an intersection-union test, since
  H2 needs both.
- **Everything else** (H1, P5, P6, other cells, Stage 1, the other arm pairs) is reported with nominal intervals and
  labelled secondary. A secondary win cannot rescue a primary null; it can only name a lead for a new registration.
- **Inconclusive** is a valid result and is reported as such.

## Hypotheses

- **H1** (secondary, per N and probe, Stage 3 busy mix and Stage 1 every mix). At E = 50 the Bus-default over
  Ledger-raw token ratio's 95 per cent interval lies inside the equivalence band [0.8, 1.25]. An interval that merely
  contains 1.0 but leaves the band is inconclusive, not equivalence.
- **H2** (primary family). At E = 5000, Bus-default is non-inferior to Ledger-raw on accuracy (margin -5 points) and
  the upper bound of its token ratio's interval is below 0.5.

| Result for an H2 test | Reported as |
| --- | --- |
| Holm-adjusted p < 0.05 | the derived views save at least half the retrieval tokens at no meaningful accuracy cost |
| ratio upper bound < 0.5, non-inferiority not shown | cheaper, accuracy not shown to hold |
| ratio lower bound > 1.0 | the raw ledger is cheaper |
| Bus-default accuracy upper bound below Bus-complete's lower bound | `brief`'s defaults are the wrong default (B-M3 candidate) |
| anything else | inconclusive |

Every row is reported whichever way it lands, including a ledger win.

## Seeds

Ten base seeds, fixed now, used in every cell so arms and cells are paired:

`4127, 9341, 1586, 7203, 2648, 5519, 8872, 3065, 6794, 1930`

A history's own seed is the first 8 bytes, big-endian, of `sha256("SEED:N:E:MIX")`; an instance's draws use
`sha256("SEED:N:E:MIX:PROBE:INSTANCE")`. The two sizing-pilot seeds are `9901, 9902` and never appear in a counted
result.

## Scope of Stage 3

Busy mix only; E in {50, 5000}; N in {5, 8}; P1 to P7; three arms; two models; 10 seeds; M = 5 instances per seed.
That is 2 x 2 x 7 x 3 x 2 x 10 x 5 = 8,400 trials (7,200 single-question, 1,200 P7 sessions). Stage 1 runs the full
grid (2 x 3 x 3 x 7 x 3 x 10 x 10 = 37,800 procedure runs), which costs CPU only.

## Budget

Stage 1 spends nothing. All Stage 3 spend runs on the owner's subscriptions with zero overage on every pool (no paid
credits, no top-ups).

**Analytic upper bound** (registered now; a bound, not an estimate). Assumptions: fixed prefix per request P = 25,000
tokens (harness system prompt, tool schema, preamble and probe); each tool result at most C = 7,500 tokens (30,000
characters / 4); each request's output at most O = 2,000 tokens; every trial uses its full call ceiling; nothing is
cached (every input token counted at full size). A trial of R requests, where request i (from 0) carries P plus i
earlier results and outputs, has input at most R x P + (C + O) x R(R-1)/2 and output at most R x O.

| Trial | Requests R | Input bound | Output bound | Total bound |
| --- | ---: | ---: | ---: | ---: |
| P1 to P6 (12 calls + answer) | 13 | 325,000 + 9,500 x 78 = 1,066,000 | 26,000 | 1,092,000 |
| P7 (5 x 6 calls + 5 answers) | 35 | 875,000 + 9,500 x 595 = 6,527,500 | 70,000 | 6,597,500 |

| Run | Trials | Bound (tokens) |
| --- | ---: | ---: |
| counted, P1 to P6 | 7,200 | 7,862,400,000 |
| counted, P7 | 1,200 | 7,917,000,000 |
| counted total | 8,400 | 15,779,400,000 (about 7.89 billion per model) |
| sizing pilot (2 seeds, M = 1) | 336 | 631,176,000 |

The bound is loose by design (full ceilings, no caching, maximum outputs); real use is expected to be a small fraction,
which is what the pilot measures.

**Sizing pilot.** Uncounted: seeds 9901 and 9902, M = 1, the Stage 3 cells above. Its numbers size the run and are
never reported as findings. From it the maintainer commits, in a Change log entry before the first counted call, a
numeric ceiling in tokens per model (input, cache write, cache read and output separately), and the per-trial
reservation (the pilot's largest observed trial of that kind times 2, capped at the analytic bound). If the ceiling
does not fit the plans' headroom, scope is cut in that same entry, before any counted call, in this order: M from 5 to
3, then P7's refreshes from 5 to 3; never by dropping an arm or a primary probe.

**Spend ledger and admission.** A persisted JSON Lines ledger (`ctxbench-spend.jsonl` in the run folder) records every
trial's reservation and its actual usage. Before each trial the runner reserves the per-trial reservation; if spent
plus reservation would cross the ceiling, the batch stops before the call. Trials run one at a time per model, so a
reservation is never shared. A trial whose usage is missing or unparseable stops the batch. An infrastructure failure
(sign-in, provider outage before the first tool call, harness crash) is retried at most once, and the retry is
charged. A stop leaves complete seed blocks analysed and the shortfall stated.

## Threats to validity

**Toward agentbus:**
- Bus-complete and the bus preambles were written by the tool's authors; R3's recipes were written by an advocate of
  the ledger, but the ledger's renderer and file format are ours. Mitigation: the format is R3's, the renderer is
  checked against the fixture, and the full ledger file for one seed per cell is published for inspection.
- The ledger reader may write `awk` reducers within its call ceiling, but it does not get R3's prepared helper, so a
  result here says nothing against the protocol on a Markdown transport.
- The bus's text output is designed for agents; a ledger format tuned for agents might read cheaper. Only R3's format
  is tested.
- Bus errors are scored against the bus, but a bus error the oracle shares (an oracle written with the same
  misreading) would be invisible. Mitigation: the oracle is written from D1 to D8, not from the code, and must pass the
  hand fixtures.

**Toward the ledger:**
- Histories have no refused claims, no name reuse, no malformed rows and no concurrency, so the bus's atomicity and
  hostile-data handling earn nothing here; this measures the read side only.
- Ledger-raw's P7 reader carries its own state between refreshes while the bus arms recompute, and its `tail` refresh
  benefits from a private cursor the bus arms do not use.
- `log show --limit -1` in Bus-complete returns the whole log (joins, claims, refusals), so Bus-complete pays for
  evidence a tighter procedure would skip; Stage 3 readers may page instead.
- Every ledger line holds a whole event, so `grep` returns exactly the events needed; a ledger written by agents would
  be messier.

**Either way:**
- Simulated histories and one prose corpus; real coordination may differ in mix, body length and how often probes'
  answers are empty. The three mixes are the sensitivity check, not a guarantee.
- Two models and one harness each; results are about those, at those settings.
- bytes / 4 is an estimate; JSON and prose tokenize differently, which is why Stage 3 calibrates k per arm and model.
- The checkpoint is always in the last tenth of a history, so "history size" means E events, not the state at an
  arbitrary point.

## Change log

Every change after this file's first commit is a new dated entry here, with its reason, appended below. Nothing above
is ever edited.
