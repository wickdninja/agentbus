"""ctxbench Stage 1 simulator (docs/evals/ctxbench-protocol.md, "Histories"; issue #80, B-M1).

Writes one seeded semantic event list per history (seed, N, E, mix) and draws the probe instances from it. Every choice
rule the protocol registers (draw_event, choose_new_resource, choose_fact_key, choose_fact_value, make_body, name_at,
p2_target, p6_target, checkpoint_now, p7_pick, next_index) is called from registered.py and never re-implemented here.
What this file adds is bookkeeping of the simulated state the rules ask about (who is live, which claims are live, which
todos and questions are open) and the uniform draws the protocol states in prose but registered.py has no function for;
each of those is listed under "Draws with no registered function" below and reported with the B-M1 hand-off.

Event tuples are registered.py's: (iso_time, actor, action, fields). One extra kind of entry, `inbox`, is a step in the
list but not one of the E events. The takeover alert is not an entry (the bus and render_ledger generate it).

Draws with no registered function, in the order a step makes them:
  1. the step's time gap: round(rng.expovariate(1 / mean)), first, because `release` and `claim` eligibility depend on
     which claims are live at the event's time;
  2. draw_event (registered);
  3. the event's own draws:
     claim: sort (one rng.random() scaled by the sum of the possible sorts' shares, walking renewal, takeover, new),
            then the target (rng.choice over the sorted candidates, or choose_new_resource), then a purpose
            (rng.choice(corpus)) for a new claim and a takeover;
     release: rng.choice over the actor's sorted live claims;
     fact: choose_fact_key, choose_fact_value;
     message: recipient (rng.random() < broadcast share; else, when anyone has left, rng.random() < 0.10 picks the left
            agents, then rng.choice over the sorted pool), topic (decision: rng.random() < 0.95; others
            rng.random() < 0.6; then rng.choice(items)), reply target (rng.choice over the sorted eligible ids; for a
            done then rng.random() < 0.20 drops reply_to; for an answer or done that kept its reply_to
            rng.random() < 0.05 swaps it, and when a reply to the target exists rng.random() < 0.5 picks the answer
            variant over the note variant), body (make_body, or the handoff and decision shapes);
  4. the actor's inbox read: rng.random() < 0.5;
  5. the crash draw: rng.random() < p, then rng.choice over the sorted live agents other than lead.
Start: lead's goal is rng.choice(corpus), drawn after the N joins, before any step.
"""
import hashlib
import math
import os
import random
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import registered as R  # noqa: E402

START = "2026-11-19T09:00:00Z"
EXTRA = 20  # the simulator writes E + 20 events
BROADCAST_TO = "*"
GRID_N = (5, 8)
GRID_E = (50, 1000, 5000)
GRID_MIX = ("sparse", "busy", "handoff-heavy")
PROBES = ("P1", "P2", "P3", "P4", "P5", "P6", "P7")
M_INSTANCES = 10
SEEDS = [4127, 9341, 1586, 7203, 2648, 5519, 8872, 3065, 6794, 1930, 2417, 8156, 3742, 6081, 1299,
         7534, 4860, 9617, 5203, 3388, 7915, 1046, 6452, 2771, 8309, 4594, 9022, 5867, 3150, 7688]
DEV_SEEDS = [9901, 9902]

PARAMS = R.PARAMS  # registered.py holds the table; the test compares it with the document
DECISION_TOPIC_SHARE = 0.95
TOPIC_SHARE = 0.6
NO_REPLY_DONE = 0.20
SWAP_REPLY = 0.05
LEFT_RECIPIENT = 0.10
INBOX_SHARE = 0.5
MESSAGE_KINDS = ("note", "question", "answer", "decision", "alert", "handoff", "todo", "done", "dropped")


def seeded(key):
    """random.Random seeded with the first 8 bytes, big-endian, of sha256(key)."""
    return random.Random(int.from_bytes(hashlib.sha256(key.encode("utf-8")).digest()[:8], "big"))


def history_key(seed, n, e, mix):
    return f"{seed}:{n}:{e}:{mix}"


def instance_key(seed, n, e, mix, probe, instance):
    return f"{history_key(seed, n, e, mix)}:{probe}:{instance}"


class Snap:
    """The simulated state after a step (its crash draw included): what the instance rules ask about."""

    __slots__ = ("time", "roster", "live", "claims", "open_todos")

    def __init__(self, time, roster, live, claims, open_todos):
        self.time, self.roster, self.live, self.claims, self.open_todos = time, roster, live, claims, open_todos

    def live_claims(self, now):
        """[(resource, holder, expires_at)] live at `now` (expiry later than now)."""
        return [(r, h, x) for r, h, x in self.claims if x > now]


class History:
    def __init__(self, seed, n, e, mix):
        self.seed, self.n, self.e, self.mix = seed, n, e, mix
        self.events = []      # registered.py event tuples, in order; inbox reads included
        self.step_end = [0]   # step_end[k]: how many entries the first k counted events (and their inbox reads) take
        self.times = [None]   # times[k]: the time of counted event k (1-based)
        self.snaps = {}       # k -> Snap, for k in [lo, E + EXTRA]
        self.items = []
        self.lo = math.ceil(0.9 * e)
        self.hi = e

    @property
    def total(self):
        return len(self.step_end) - 1

    def counted(self):
        return [ev for ev in self.events if ev[2] != "inbox"]

    def upto(self, k):
        """The entries a probe at checkpoint k sees: counted events 1..k and their inbox reads."""
        return self.events[:self.step_end[k]]


class Sim:
    def __init__(self, seed, n, e, mix):
        if mix not in PARAMS:
            raise SystemExit(f"FAIL: unknown mix {mix}")
        if e + EXTRA <= n + 1:
            raise SystemExit(f"FAIL: E={e} is too small for N={n} (the start takes {n + 1} events)")
        self.p = PARAMS[mix]
        self.mix = mix
        self.rng = seeded(history_key(seed, n, e, mix))
        self.h = History(seed, n, e, mix)
        self.n = n
        self.corpus = R.load_list("corpus.txt")
        self.keys = R.load_list("fact_keys.txt")
        self.items = R.load_list("items.txt")[:self.p["items"]]
        self.h.items = self.items
        self.dt = datetime.strptime(START, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        self.roster, self.crashed, self.left, self.leave_ts = set(), set(), [], {}
        self.next_name = 0           # index into the name pool of the next agent to join
        self.claims = {}             # resource -> [holder, start (datetime), purpose]; expired ones stay until replaced
        self.mid = 0                 # message ids: posts and takeover alerts
        self.open_todos = {}         # id -> (ts, owner, topic)
        self.open_questions = {}     # id -> (sender, to)
        self.replies = {}            # id -> [ids replying to it]
        self.fact_order, self.facts = [], {}
        self.count = 0

    # ---- state the rules ask about ---------------------------------------------------------------------------
    @property
    def live(self):
        return sorted(self.roster - self.crashed)

    def live_claims(self):
        return {r: c for r, c in self.claims.items() if c[1] + R.TTL > self.dt}

    def takeable(self, ts, owner):
        """D7 for someone other than the owner: the owner is off the roster and left at or after the todo's time."""
        return owner not in self.roster and owner in self.leave_ts and self.leave_ts[owner] >= ts

    def todos_of(self, actor):
        return sorted(i for i, (ts, owner, _) in self.open_todos.items() if owner == actor or self.takeable(ts, owner))

    def questions_for(self, actor):
        return sorted(i for i, (s, to) in self.open_questions.items() if s != actor and to in (BROADCAST_TO, actor))

    def free_resource_exists(self, live_res):
        return any(not any(R.overlaps(r, c) for c in live_res) for i in self.items for r in R.item_resources(i))

    def claim_sorts(self, actor):
        """The sorts possible for the actor, with their shares, in the registered order renewal, takeover, new."""
        live = self.live_claims()
        mine = sorted(r for r, c in live.items() if c[0] == actor)
        others = sorted(r for r, c in live.items() if c[0] != actor)
        sh = self.p["claim"]
        out = []
        if mine:
            out.append(("renewal", sh[0], mine))
        if others:
            out.append(("takeover", sh[1], others))
        if self.free_resource_exists(list(live)):
            out.append(("new", sh[2], None))
        return out

    def eligible(self, kind):
        live = self.live
        if kind in ("note", "question", "decision", "alert", "handoff", "todo", "fact"):
            return set(live)
        if kind == "answer":
            return {a for a in live if self.questions_for(a)}
        if kind in ("done", "dropped"):
            return {a for a in live if self.todos_of(a)}
        if kind == "claim":
            return {a for a in live if self.claim_sorts(a)}
        if kind == "release":
            held = {c[0] for c in self.live_claims().values()}
            return {a for a in live if a in held}
        if kind == "join":
            return {R.name_at(self.next_name)} if len(live) < self.n else set()
        if kind == "leave":
            rest = [a for a in live if a != "lead"]
            return set(rest) if len(rest) >= 2 else set()
        raise SystemExit(f"FAIL: unknown event type {kind}")

    # ---- recording ---------------------------------------------------------------------------------------------
    def put(self, actor, action, fields):
        self.h.events.append((R.iso(self.dt), actor, action, fields))

    def close_step(self):
        self.count += 1
        self.h.step_end.append(len(self.h.events))
        self.h.times.append(R.iso(self.dt))

    def snapshot(self):
        if self.count < self.h.lo:
            return
        claims = tuple(sorted((r, c[0], R.iso(c[1] + R.TTL)) for r, c in self.claims.items()))
        todos = tuple(sorted((i, owner, topic) for i, (_, owner, topic) in self.open_todos.items()))
        self.h.snaps[self.count] = Snap(R.iso(self.dt), frozenset(self.roster), tuple(self.live), claims, todos)

    # ---- the start ---------------------------------------------------------------------------------------------
    def start(self):
        for name in ["lead"] + [R.name_at(i) for i in range(self.n - 1)]:
            self.roster.add(name)
            self.put(name, "join", {})
            self.close_step()
        self.next_name = self.n - 1
        self.put("lead", "goal", {"text": self.rng.choice(self.corpus)})
        self.close_step()

    # ---- one step ----------------------------------------------------------------------------------------------
    def step(self):
        self.dt += timedelta(seconds=round(self.rng.expovariate(1 / self.p["mean"])))
        kind, actor = R.draw_event(self.rng, self.mix, self.eligible, set(self.live))
        getattr(self, "do_" + ("message" if kind in MESSAGE_KINDS else kind))(kind, actor)
        self.close_step()
        if self.rng.random() < INBOX_SHARE and actor in self.roster:  # a left agent has no inbox to read
            self.put(actor, "inbox", {})
            self.h.step_end[-1] = len(self.h.events)
        if self.rng.random() < self.p["crash"]:
            cands = [a for a in self.live if a != "lead"]
            if cands:
                self.crashed.add(self.rng.choice(cands))
        self.snapshot()

    def do_join(self, kind, actor):
        self.roster.add(actor)
        self.next_name += 1
        self.put(actor, "join", {})

    def do_leave(self, kind, actor):
        for r in [r for r, c in self.claims.items() if c[0] == actor]:
            del self.claims[r]
        self.roster.discard(actor)
        self.left.append(actor)
        self.leave_ts[actor] = R.iso(self.dt)
        self.put(actor, "leave", {})

    def do_release(self, kind, actor):
        mine = sorted(r for r, c in self.live_claims().items() if c[0] == actor)
        res = self.rng.choice(mine)
        del self.claims[res]
        self.put(actor, "release", {"res": res})

    def do_fact(self, kind, actor):
        key = R.choose_fact_key(self.rng, self.fact_order, self.keys)
        value = R.choose_fact_value(self.rng, self.corpus, self.facts.get(key))
        if key not in self.facts:
            self.fact_order.append(key)
        self.facts[key] = value
        self.put(actor, "fact", {"key": key, "value": value})

    def do_claim(self, kind, actor):
        sorts = self.claim_sorts(actor)
        u = self.rng.random() * sum(s[1] for s in sorts)
        pick = sorts[-1]
        for s in sorts:
            if u < s[1]:
                pick = s
                break
            u -= s[1]
        name, _, cands = pick
        live = self.live_claims()
        fields = {}
        if name == "renewal":
            res = self.rng.choice(cands)
            purpose = live[res][2]
        elif name == "takeover":
            res = self.rng.choice(cands)
            fields["frm"] = live[res][0]
            purpose = self.rng.choice(self.corpus)
        else:
            res = R.choose_new_resource(self.rng, self.items, list(live))
            purpose = self.rng.choice(self.corpus)
        self.claims[res] = [actor, self.dt, purpose]
        if name == "takeover":
            self.mid += 1  # the alert the bus sends the old holder
        self.put(actor, "claim", dict(fields, res=res, purpose=purpose))

    # messages: recipient, topic, reply target, body
    def recipient(self, actor):
        if self.rng.random() < self.p["broadcast"]:
            return BROADCAST_TO
        if self.left and self.rng.random() < LEFT_RECIPIENT:
            return self.rng.choice(sorted(self.left))
        return self.rng.choice(sorted(self.roster - {actor}))

    def topic(self, kind):
        if kind == "decision":
            return "decision" if self.rng.random() < DECISION_TOPIC_SHARE else self.rng.choice(self.items)
        return self.rng.choice(self.items) if self.rng.random() < TOPIC_SHARE else None

    def reply_target(self, kind, actor):
        """(kind, reply_to) after the target draw, the done's no-reply draw and the swap draw."""
        if kind not in ("answer", "done", "dropped"):
            return kind, None
        pool = self.questions_for(actor) if kind == "answer" else self.todos_of(actor)
        target = self.rng.choice(pool)
        if kind == "done" and self.rng.random() < NO_REPLY_DONE:
            return kind, None
        if kind in ("answer", "done") and self.rng.random() < SWAP_REPLY:
            latest = self.replies.get(target)
            if latest and self.rng.random() < 0.5:
                return "answer", latest[-1]
            return "note", target
        return kind, target

    def body(self, kind, topic):
        if kind == "handoff":
            slug = topic or self.rng.choice(self.items)
            return "branch " + slug + "; " + "; ".join(self.rng.choice(self.corpus) for _ in range(3))
        text = R.make_body(self.rng, self.corpus, self.p["long"])
        if kind == "decision":
            return text + "\nSubject: " + self.rng.choice(self.items)
        return text

    def do_message(self, kind, actor):
        to = self.recipient(actor)
        topic = self.topic(kind)
        sent, reply_to = self.reply_target(kind, actor)
        body = self.body(sent, topic)
        self.mid += 1
        mid = self.mid
        if reply_to is not None:
            self.replies.setdefault(reply_to, []).append(mid)
        if sent == "todo":
            self.open_todos[mid] = (R.iso(self.dt), actor if to == BROADCAST_TO else to, topic)
        elif sent == "question":
            self.open_questions[mid] = (actor, to)
        elif sent in ("done", "dropped"):
            self.open_todos.pop(reply_to, None)
        elif sent == "answer":
            self.open_questions.pop(reply_to, None)
        self.put(actor, "post", {"kind": sent, "to": to, "body": body, "topic": topic, "reply_to": reply_to})

    def run(self):
        self.start()
        while self.count < self.h.e + EXTRA:
            self.step()
        return self.h


def build_history(seed, n, e, mix):
    """The semantic event list of one history, E + 20 counted events (the first N + 1 are the start)."""
    return Sim(seed, n, e, mix).run()


# ---- probe instances ---------------------------------------------------------------------------------------------

def active_items(snap, now, items):
    """Items someone works on by P6's rule: a live claim overlapping src/Y/ at now, or an open todo with topic Y whose
    owner is on the roster."""
    live = [r for r, _, _ in snap.live_claims(now)]
    out = set()
    for y in items:
        if any(R.overlaps(r, f"src/{y}/") for r in live):
            out.add(y)
    out |= {topic for _, owner, topic in snap.open_todos if topic in items and owner in snap.roster}
    return out


def draw_instance(hist, seed, probe, idx):
    """One probe instance of a history. P1 to P6: {"probe", "instance", "c", "me", "now", "inputs"}. P7: {"probe",
    "instance", "c", "me", "refreshes": [step, step, step], "times": [...]}. None when P7 has no candidate. Raises when
    P1 to P6 find no checkpoint at all (a defect of the history, never scored)."""
    rng = seeded(instance_key(seed, hist.n, hist.e, hist.mix, probe, idx))
    lo, hi = hist.lo, hist.hi
    if probe == "P7":
        c0 = rng.randint(lo, hi)

        def candidates_at(c):
            a, b, z = hist.snaps[c], hist.snaps[c + 10], hist.snaps[c + 20]
            for s in (a, b, z):
                if not R.guard_ok(s.time, [x for _, _, x in s.live_claims(s.time)]):
                    return set()
            return set(a.live) & set(z.live)  # live at c and c+20: no leave or crash in between (never rejoin)

        pick = R.p7_pick(rng, c0, lo, hi, candidates_at)
        if pick is None:
            return None
        c, me = pick
        steps = [c, c + 10, c + 20]
        return {"probe": probe, "instance": idx, "c": c, "me": me, "refreshes": steps,
                "times": [hist.times[k] for k in steps]}
    c = rng.randint(lo, hi)
    u0 = rng.randint(1, 300)
    for _ in range(hi - lo + 1):
        snap = hist.snaps[c]
        me = rng.choice(sorted(snap.live))
        now = R.checkpoint_now(hist.times[c], u0, [x for _, _, x in snap.live_claims(hist.times[c])])
        if now is not None:
            break
        c = R.next_index(c, lo, hi)
    else:
        raise SystemExit(f"FAIL: no checkpoint for {probe} instance {idx} of {history_key(seed, hist.n, hist.e, hist.mix)}")
    inputs = {}
    if probe == "P2":
        inputs["x"] = R.p2_target(rng, [r for r, _, _ in snap.live_claims(now)], hist.items)
    elif probe == "P6":
        inputs["y"] = R.p6_target(rng, active_items(snap, now, hist.items), hist.items)
    return {"probe": probe, "instance": idx, "c": c, "me": me, "now": now, "inputs": inputs}
