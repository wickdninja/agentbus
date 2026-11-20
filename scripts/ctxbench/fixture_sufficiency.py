#!/usr/bin/env python3
"""ctxbench Stage 1 fixtures (docs/evals/ctxbench-protocol.md, "Fixtures").

Every registered procedure, adapter, parser, generator rule, time check and report function in registered.py is run
here against hand-derived answers. Histories are built with the real CLI, one process per simulated second, and the
ledger is rendered from the same events. A parser sees only what its procedure delivered.

  F1 (N1)      when bob left decides P4: {1} vs {1, 2}
  F2           P5 anchored to header fields: (1, parser) vs (1, uploader); the v1 recipe cannot tell them apart
  F3           claims (expired, expiry == now, takeover, released), closure rules, own broadcast question: P1 P2 P3 P6
  F4 (Codex D) one open todo to an owner who left after it: Bus-default's parser cannot decide though `next` names it
  F5           a decision whose subject sits past byte 2,048: Bus-complete reads it whole
  F6           a P7 session of three refreshes with me's own actions in the windows
  CAP          the cap adapter: cut required source, cut JSON, cut unused source, adaptive P5 under a cut
  GEN          generator choice rules on scripted draws
  TIME, PARITY, REPORT  reader-time and stored-time checks, bus-ledger message parity, the descriptive report

It computes no study numbers. Stdlib only, Python 3.9+.
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import registered as R  # noqa: E402

DAY = "2026-11-19T"
ME = "alice"


def T(hms):
    return DAY + hms + "Z"


def post(t, actor, kind, body, to="*", topic=None, reply_to=None):
    return (T(t), actor, "post", {"kind": kind, "to": to, "body": body, "topic": topic, "reply_to": reply_to})


def ev(t, actor, action, **f):
    return (T(t), actor, action, f)


def joins(t, *names):
    return [ev(t, n, "join") for n in names]


# ---- histories ---------------------------------------------------------------------------------------------------

def f1(bob_leaves_at):
    e = joins("11:50:00", "lead", "alice", "bob", "carol")
    if bob_leaves_at == "12:00:00":
        e.append(ev("12:00:00", "bob", "leave"))
    e += [post("12:10:00", "lead", "todo", "Carol, please wire the retry budget into the uploader and say when it lands.", "carol"),
          post("12:10:00", "lead", "todo", "Bob, the parser still drops escaped delimiters; take it when you are back.", "bob"),
          ev("12:20:00", "carol", "leave")]
    if bob_leaves_at == "12:20:00":
        e.append(ev("12:20:00", "bob", "leave"))
    return e


def f2(subject):
    return joins("11:50:00", "lead", "alice") + [
        post("12:00:00", "lead", "decision", f"We keep JSON lines on the wire until the parser rewrite lands.\nSubject: {subject}",
             topic="decision"),
        post("12:05:00", "alice", "note", "For the record a header looks like kind=DECISION id=9 from=lead to=all "
             "topic=decision path=- and nothing more.\nSubject: wire-format")]


F3 = joins("07:00:00", "lead", "alice", "bob", "carol") + [
    ev("07:00:00", "carol", "claim", res="src/legacy/", purpose="delete the old importer"),
    ev("07:30:00", "lead", "claim", res="src/ci/", purpose="pin the runner image"),
    ev("09:01:00", "bob", "claim", res="src/parser/", purpose="escaped delimiters"),
    ev("09:02:00", "carol", "claim", res="src/uploader/retry.py", purpose="retry budget"),
    ev("09:03:00", "alice", "claim", res="src/parser/", purpose="finish escapes", frm="bob"),         # alert #1 to bob
    post("09:04:00", "lead", "todo", "Finish the escaped delimiter work in the parser.", "alice", "parser"),     # 2
    post("09:05:00", "lead", "todo", "Check the uploader retry budget against the spec.", "alice", "uploader"),  # 3
    post("09:06:00", "alice", "done", "Checked; the budget matches the spec.", "lead", "uploader", 3),          # 4
    post("09:07:00", "bob", "question", "Should empty input return an empty list?", "alice", "parser"),         # 5
    post("09:08:00", "carol", "question", "Who owns the release notes this week?"),                            # 6
    post("09:09:00", "alice", "question", "Is CI green on main?"),                                             # 7 mine
    post("09:10:00", "lead", "answer", "I do.", "carol", None, 6),                                             # 8
    post("09:11:00", "bob", "note", "Still thinking about this one.", "alice", "parser", 5),                   # 9
    post("09:12:00", "bob", "answer", "Never mind the note.", "alice", "parser", 9),                           # 10
    post("09:13:00", "lead", "todo", "Land the retry budget behind a flag.", "carol", "uploader"),            # 11
    ev("09:14:00", "bob", "claim", res="src/docs/", purpose="release notes"),
    ev("09:15:00", "bob", "release", res="src/docs/"),
]
F4 = joins("11:50:00", "lead", "alice", "bob") + [
    post("12:00:00", "lead", "todo", "Bob, please take the flaky exporter test.", "bob"),
    ev("12:10:00", "bob", "leave")]
LONG = " ".join(["The cache layer needs another pass under load before we turn the flag on for everyone."] * 25)
F5 = joins("11:50:00", "lead", "alice") + [post("12:00:00", "lead", "decision", LONG + "\nSubject: cache", topic="decision")]
F7 = joins("09:00:00", "lead", "alice", "bob") + [
    ev("09:00:00", "lead", "goal", text="Ship the uploader retry budget this week."),
    ev("09:01:00", "alice", "fact", key="release-branch", value="release/0.5 is cut from main every Thursday."),
    ev("09:02:00", "bob", "fact", key="api-base-url", value="Staging answers on the internal host only."),
    ev("09:03:00", "alice", "fact", key="release-branch", value="release/0.5 moved to Friday for this week only."),
    ev("09:04:00", "lead", "goal", text="Ship the uploader retry budget and the parser fix this week."),
    post("09:05:00", "lead", "todo", "Keep the release branch fact current.", "alice")]

ALL = R.ARMS
C = R.CANNOT


def same(ans, **over):
    d = {a: ans for a in ALL}
    d.update({k.replace("_", "-"): v for k, v in over.items()})
    return d


HISTORIES = {"F1-A": f1("12:00:00"), "F1-B": f1("12:20:00"), "F2-A": f2("parser"), "F2-B": f2("uploader"),
             "F3": F3, "F4": F4, "F5": F5, "F7": F7}
CASES = [  # (history, now, probe, inputs, expected per arm)
    ("F1-A", T("12:30:00"), "P4", {}, same({1}, bus_default=C)),
    ("F1-B", T("12:30:00"), "P4", {}, same({1, 2}, bus_default=C)),
    ("F2-A", T("12:30:00"), "P5", {}, same((1, "parser"))),
    ("F2-B", T("12:30:00"), "P5", {}, same((1, "uploader"))),
    ("F3", T("09:30:00"), "P1", {}, same({2})),
    ("F3", T("09:30:00"), "P3", {}, same({5})),
    ("F3", T("09:30:00"), "P2", {"x": "src/parser/lexer.py"}, same({"alice"})),
    ("F3", T("09:30:00"), "P2", {"x": "src/uploader/"}, same({"carol"})),
    ("F3", T("09:30:00"), "P2", {"x": "src/legacy/old.py"}, same(set())),
    ("F3", T("09:30:00"), "P2", {"x": "src/ci/run.sh"}, same(set())),   # expires_at == now: not live
    ("F3", T("09:30:00"), "P6", {"y": "uploader"}, same({"carol"})),
    ("F3", T("09:30:00"), "P6", {"y": "parser"}, same({"alice"})),
    ("F3", T("09:30:00"), "P6", {"y": "docs"}, same(set())),
    ("F4", T("12:30:00"), "P4", {}, same({1}, bus_default=C)),
    ("F5", T("12:30:00"), "P5", {}, same((1, "cache"), bus_default=C)),
    ("F7", T("09:30:00"), "P1", {}, same({1})),
    ("F7", T("09:30:00"), "P4", {}, same({1})),
]


# ---- helpers -----------------------------------------------------------------------------------------------------

class Fx:
    def __init__(self, run, tmp):
        self.run, self.tmp, self.n, self.built = run, tmp, 0, {}

    def history(self, name, events):
        if name not in self.built:
            bus = os.path.join(self.tmp, name, "bus")
            R.build_bus(self.run, bus, events)
            led = os.path.join(self.tmp, name, "ledger")
            os.makedirs(led)
            with open(os.path.join(led, "COORDINATION.md"), "w") as fh:
                fh.write(R.render_ledger(events))
            self.built[name] = (bus, led)
        return self.built[name]

    def copy(self, src):
        self.n += 1
        dst = os.path.join(self.tmp, "copies", str(self.n))
        shutil.copytree(src, dst)
        return dst

    def probe(self, name, arm, probe, now, inputs, cap=None):
        """Run on a fresh copy; a reader-time defect retries on a new copy (at most 3 tries, then fail)."""
        bus, led = self.history(name, HISTORIES[name])
        for _ in range(3):
            try:
                d = R.execute(self.run, arm, probe, self.copy(bus if arm.startswith("bus-") else led), ME, now, inputs, cap)
                return d, R.answer(arm, probe, d, ME, now, inputs)
            except R.ReplayDefect:
                continue
        raise SystemExit(f"FAIL: {name} {probe} {arm}: reader-time defect three times")


def check(cond, msg):
    if not cond:
        raise SystemExit("FAIL: " + msg)


# ---- the checks --------------------------------------------------------------------------------------------------

def parity(fx):
    for name, events in HISTORIES.items():
        bus, led = fx.history(name, events)
        con = sqlite3.connect(os.path.join(bus, "bus.db"))
        bus_msgs = [tuple(r) for r in con.execute("SELECT id, kind, sender, recipient, topic, reply_to, body FROM messages ORDER BY id")]
        con.close()
        con = sqlite3.connect(os.path.join(bus, "bus.db"))
        bus_facts = [tuple(r) for r in con.execute("SELECT key, value, updated_by, updated_at FROM context_history ORDER BY id")]
        con.close()
        with open(os.path.join(led, "COORDINATION.md")) as fh:
            text = fh.read()
        check(bus_msgs == R.ledger_messages(text), f"{name}: bus and ledger messages differ")
        check(bus_facts == ledger_facts(text), f"{name}: bus and ledger facts differ:\n{bus_facts}\n{ledger_facts(text)}")
    check(len(ledger_facts(open(os.path.join(fx.built["F7"][1], "COORDINATION.md")).read())) == 5, "PARITY F7 has five goal and fact writes")
    print(f"PASS: PARITY bus and ledger hold the same messages (takeover alert included) and the same goal and fact "
          f"writes ({len(HISTORIES)} histories)")


def ledger_facts(text):
    """(key, value, by, ts) of every GOAL and FACT line, values joined: for the parity check."""
    out, cur = [], None
    for line in text.splitlines():
        m = re.match(r"^- eid=E\d+ ts=(\S+) kind=(GOAL|FACT) id=\S+ from=(\S+) to=\S+ topic=(\S+) path=\S+ reply_to=\S+ \| ?(.*)$", line)
        if m:
            ts, kind, frm, topic, value = m.groups()
            cur = ["goal" if kind == "GOAL" else topic, value, frm, ts]
            out.append(cur)
        elif line.startswith("- "):
            cur = None
        elif cur is not None and line.startswith("  "):
            cur[1] += "\n" + line[2:]
    return [tuple(x) for x in out]


def cases(fx):
    out = {}
    for name, now, probe, inputs, want in CASES:
        for arm in ALL:
            d, got = fx.probe(name, arm, probe, now, inputs)
            check(got == want[arm], f"{name} {probe} {inputs} {arm}: derived {got!r}, expected {want[arm]!r}\n" + "\n---\n".join(d.texts))
            out[(name, probe, json.dumps(inputs), arm)] = d
    print(f"PASS: F1-F5 every arm's parser gives the hand-derived answer, or cannot decide where registered "
          f"({len(CASES)} cases x {len(ALL)} arms)")
    # F1: Bus-default delivers the same text for both histories; without leave evidence every arm does
    t = lambda h, a: out[(h, "P4", "{}", a)].texts
    check(t("F1-A", "bus-default") == t("F1-B", "bus-default"), "F1 Bus-default text differs between the histories")
    check(t("F1-A", "bus-complete")[0] == t("F1-B", "bus-complete")[0], "F1 brief --json alone differs")
    strip = lambda s: re.sub(r"(?m)^\d+:- eid=E\d+ ", "- ", s)
    a, b = (strip(fx.run.sh(fx.history(h, HISTORIES[h])[1], R.GREP.format("TODO|DONE|DROPPED"))) for h in ("F1-A", "F1-B"))
    check(a == b, "F1 the ledger's TODO lines differ")
    # F2: the v1 recipe prints identical text for both histories
    old = []
    for h in ("F2-A", "F2-B"):
        first = fx.run.sh(fx.built[h][1], R.P5_V1)
        line = first.strip().split("\n")[-1].split(":", 1)[0]
        old.append((first, fx.run.sh(fx.built[h][1], R.P5_EXPAND.format(line))))
    check(old[0] == old[1], "F2 the v1 P5 recipe now distinguishes the histories")
    # F4: brief's `next` names the takeable todo, but the registered Bus-default parser does not use it
    nxt = json.loads(out[("F4", "P4", "{}", "bus-default")].get("brief")[1])["next"]
    check(nxt.endswith("read --id 1"), f"F4 brief next is {nxt!r}; the state no longer shows the unused evidence")
    # F5: Bus-complete made the second call; Bus-default did not and could not
    check(out[("F5", "P5", "{}", "bus-complete")].get("whole") is not None, "F5 Bus-complete did not read the body whole")
    print("PASS: F1 same Bus-default text; F2 v1 recipe blind; F4 `next` unused; F5 read --id used")


def cap(fx):
    now = T("09:30:00")
    d, got = fx.probe("F3", "ledger-raw", "P1", now, {}, cap=100)
    check(got == C and d.calls[0][2], f"CAP a cut ledger source must be a miss, got {got!r}")
    d, got = fx.probe("F3", "bus-complete", "P1", now, {}, cap=100)
    check(got == C, f"CAP cut JSON must be a miss before json.loads, got {got!r}")
    d, got = fx.probe("F3", "bus-default", "P1", now, {}, cap={"inbox": 10})
    check(got == {2} and d.get("inbox")[2] and not d.get("brief")[2], f"CAP a cut unused source changed the answer: {got!r}")
    d, got = fx.probe("F5", "bus-complete", "P5", T("12:30:00"), {}, cap={"decisions": 100})
    check(got == C and d.get("whole") is None, "CAP adaptive P5 must not call read --id after a cut first output")
    d, got = fx.probe("F2-A", "ledger-raw", "P5", T("12:30:00"), {}, cap={"decisions": 10})
    check(got == C and d.get("record") is None, "CAP ledger P5 must not expand after a cut first output")
    marked = R.deliver("x" * 30001, R.CAP)
    check(marked[1] and marked[0].endswith(R.CAP_MARKER) and len(marked[0]) == 30000 + len(R.CAP_MARKER), "CAP marker")
    print("PASS: CAP cut required source is a miss; cut JSON never parsed; unused source ignored; adaptive P5 stops")


def p7(fx):
    base = joins("09:00:00", "lead", "alice", "bob") + [
        post("09:01:00", "lead", "todo", "Wire the retry budget.", "alice"),                  # 1
        post("09:02:00", "bob", "question", "Should empty input return an empty list?", "alice")]  # 2
    w1 = [post("09:06:00", "alice", "done", "Wired.", "lead", None, 1),                       # 3 (me acts)
          post("09:07:00", "lead", "todo", "Fix the flaky exporter test.", "bob"),           # 4
          ev("09:08:00", "bob", "leave")]
    w2 = [post("09:11:00", "alice", "answer", "Yes, an empty list.", "bob", None, 2),        # 5 (me acts)
          post("09:12:00", "lead", "question", "Who can review the cache change?")]          # 6
    refreshes = [T("09:05:00"), T("09:10:00"), T("09:15:00")]
    want = [({1}, {2}, {1}), (set(), {2}, {4}), (set(), {6}, {4})]
    want_default = [({1}, {2}, {1}), (set(), {2}, C), (set(), {6}, C)]
    bus, led = fx.history("F6", base)
    for arm in ALL:
        copy = fx.copy(bus if arm.startswith("bus-") else led)
        s, events = R.Session(fx.run, arm, copy, ME), list(base)
        for k, now in enumerate(refreshes):
            if k:
                for e in (w1, w2)[k - 1]:
                    events.append(e)
                    if arm.startswith("bus-"):
                        R.apply_event(fx.run, os.path.join(copy, "bus.db"), e)
                if not arm.startswith("bus-"):
                    with open(os.path.join(copy, "COORDINATION.md"), "w") as fh:
                        fh.write(R.render_ledger(events))  # append-only: a prefix renders a prefix
            for attempt in range(3):
                try:
                    _, triple = s.refresh(now)
                    break
                except R.ReplayDefect:
                    if attempt == 2 or arm == "bus-default":  # a consuming refresh cannot be retried in place
                        raise SystemExit(f"FAIL: F6 {arm} refresh {k + 1}: reader-time defect") from None
            exp = (want_default if arm == "bus-default" else want)[k]
            check(triple == exp, f"F6 {arm} refresh {k + 1}: {triple!r}, expected {exp!r}")
    print("PASS: F6 P7 three refreshes, me acting in the windows, every arm's session parser")
    # capped: cap 3 cuts every bus output, the ledger line count and every non-empty awk answer; nothing may raise
    capped_want = {"ledger-awk": [(C, C, C), (set(), C, C), (set(), C, C)]}
    for arm in ALL:
        copy = fx.copy(bus if arm.startswith("bus-") else led)
        s, events = R.Session(fx.run, arm, copy, ME), list(base)
        for k, now in enumerate(refreshes):
            if k:
                for e in (w1, w2)[k - 1]:
                    events.append(e)
                    if arm.startswith("bus-"):
                        R.apply_event(fx.run, os.path.join(copy, "bus.db"), e)
                if not arm.startswith("bus-"):
                    with open(os.path.join(copy, "COORDINATION.md"), "w") as fh:
                        fh.write(R.render_ledger(events))
            try:
                d, triple = s.refresh(now, cap=3)
            except R.ReplayDefect:
                raise SystemExit(f"FAIL: F6 capped {arm} refresh {k + 1}: reader-time defect") from None
            exp = capped_want.get(arm, [(C, C, C)] * 3)[k]
            check(triple == exp, f"F6 capped {arm} refresh {k + 1}: {triple!r}, expected {exp!r}")
            if k == 0:  # later refreshes are cannot-decide by state (a cut loses rows for good), with or without a cut
                check(any(c for _, _, c in d.calls), f"F6 capped {arm} refresh 1: nothing was cut")
    print("PASS: F6 capped P7: every arm returns cannot-decide for a cut source and never raises")


class Script:
    """A scripted stand-in for random.Random: random() and choice() return the next scripted value or index."""

    def __init__(self, randoms=(), choices=(), ints=()):
        self.r, self.c, self.i = list(randoms), list(choices), list(ints)

    def randint(self, a, b):
        v = self.i.pop(0)
        assert a <= v <= b, (a, v, b)
        return v

    def random(self):
        return self.r.pop(0)

    def choice(self, seq):
        return list(seq)[self.c.pop(0)]


def gen():
    # actor: the type is drawn first; an ineligible type is redrawn with its actor; the actor comes from that type's set
    elig = {"answer": set(), "note": {"alice", "bob"}}
    got = R.draw_event(Script([0.36, 0.10], [1]), "sparse", lambda k: elig.get(k, set()), {"alice", "bob", "lead"})
    check(got == ("note", "bob"), f"GEN draw_event {got}")
    got = R.draw_event(Script([0.36] * 11, [0]), "sparse", lambda k: set(), {"lead", "alice"})
    check(got == ("note", "alice"), f"GEN draw_event after 10 redraws {got}")
    # resources: one rule, folder sort with probability 0.3, else file; the other sort when one is empty
    check(R.choose_new_resource(Script([0.2], [0]), ["parser"], []) == "src/parser/", "GEN folder sort")
    check(R.choose_new_resource(Script([0.5], [0]), ["parser"], []) == "src/parser/f1.py", "GEN file sort")
    check(R.choose_new_resource(Script([0.2], [0]), ["parser"], ["src/parser/f1.py"]) == "src/parser/f2.py", "GEN folder taken -> file")
    check(R.choose_new_resource(Script([0.5], []), ["parser"], ["src/parser/"]) is None, "GEN nothing free")
    # empty target pools fall back to the uniform branch
    check(R.p2_target(Script([0.1], [5]), [], ["parser", "cache"]) == "src/cache/f2.py", "GEN P2 empty pool")
    check(R.p2_target(Script([0.1], [0, 2]), ["src/parser/"], ["parser"]) == "src/parser/f3.py", "GEN P2 covered folder")
    check(R.p6_target(Script([0.1], [1]), set(), ["parser", "cache"]) == "cache", "GEN P6 empty pool")
    # P7: alice leaves inside the window at c=45, so she is no candidate; the scan moves on and wraps
    cands = {45: set(), 46: {"carol", "dave"}}
    check(R.p7_pick(Script([], [1]), 45, 45, 50, lambda c: cands.get(c, set())) == (46, "dave"), "GEN P7 scan")
    check(R.p7_pick(Script([], [0]), 50, 45, 50, lambda c: {"erin"} if c == 45 else set()) == (45, "erin"), "GEN P7 wrap")
    check(R.p7_pick(Script(), 45, 45, 50, lambda c: set()) is None, "GEN P7 none")
    # checkpoint guard: a claim expiring at 12:01:00 forbids now in [11:59:00, 12:01:00)
    check(R.checkpoint_now(T("12:00:00"), 10, [T("12:01:00")]) == T("12:01:00"), "GEN guard scan")
    check(R.checkpoint_now(T("12:00:00"), 10, []) == T("12:00:10"), "GEN guard free")
    keys = R.load_list("fact_keys.txt")
    check(R.choose_fact_key(Script([0.9]), [], keys) == "release-branch", "GEN first fact key")
    check(R.choose_fact_key(Script([0.9]), ["release-branch"], keys) == "api-base-url", "GEN next unused key")
    check(R.choose_fact_key(Script([0.2], [0]), ["release-branch", "api-base-url"], keys) == "release-branch", "GEN update a set key")
    check(R.choose_fact_key(Script([0.9], [1]), keys, keys) == keys[1], "GEN key list exhausted")
    check(R.choose_fact_value(Script([], [0]), ["a", "b"], "a") == "b", "GEN fact value never the current one")
    check(R.make_body(Script([0.5], [1, 0], [2]), ["s1", "s2"], 0.05) == "s2 s1", "GEN normal body")
    check(R.make_body(Script([0.01], [0] * 24, [24]), ["s1"], 0.05) == " ".join(["s1"] * 24), "GEN long body")
    check(R.name_at(0) == "alice" and R.name_at(39) == "nolan" and R.name_at(40) == "alice2" and R.name_at(81) == "bob3", "GEN names")
    print("PASS: GEN actor and redraw, one resource rule, empty-pool fallbacks, P7 scan, checkpoint guard, name pool")


def times(fx, cli):
    slow = R.Runner(["sh", "-c", 'sleep 1.1; exec "$@"', "slow"] + cli, os.path.join(fx.tmp, "slow"))
    db = os.path.join(fx.history("F4", F4)[0], "bus.db")
    try:
        slow.bus(db, T("12:30:00"), "--json", "who", measured=True)
        check(False, "TIME a reader over one second was not a defect")
    except R.ReplayDefect:
        pass
    bad = fx.copy(fx.history("F3", F3)[0])
    con = sqlite3.connect(os.path.join(bad, "bus.db"))
    con.execute("UPDATE log SET ts='2026-11-19T09:15:01Z' WHERE id=(SELECT MAX(id) FROM log)")
    con.commit()
    con.close()
    try:
        R.check_stored_times(os.path.join(bad, "bus.db"), F3)
        check(False, "TIME a log row off the simulated times was not a defect")
    except R.ReplayDefect:
        pass
    # a renewal keeps the first claim's start and moves the expiry: the rule before this repair flagged every such history
    ren = joins("07:00:00", "lead", "alice", "bob", "carol") + [
        ev("07:00:00", "carol", "claim", res="src/legacy/", purpose="delete the old importer"),
        ev("09:00:00", "bob", "claim", res="src/parser/", purpose="escaped delimiters"),
        ev("09:30:00", "bob", "claim", res="src/parser/", purpose="escaped delimiters"),  # a renewal
        ev("09:40:00", "carol", "leave")]  # her claim expired at 09:00; the bus still deletes the row
    bus = os.path.join(fx.tmp, "F8", "bus")
    R.build_bus(fx.run, bus, ren)  # the repaired check accepts it (build_bus raises ReplayDefect otherwise)
    db = os.path.join(bus, "bus.db")
    con = sqlite3.connect(db)
    rows = list(con.execute("SELECT claimed_at, expires_at FROM claims"))
    check(rows == [(T("09:00:00"), T("11:30:00"))], f"TIME F8 renewal rows {rows}")
    old = lambda: [r for r in rows if r[1] != R.iso(R.parse_ts(r[0]) + R.TTL)]  # noqa: E731  (the old rule)
    check(old(), "TIME F8 the old claim rule no longer flags a renewal, so the fixture proves nothing")
    for sql in ("UPDATE claims SET expires_at='2026-11-19T11:30:01Z'", "UPDATE claims SET claimed_at='2026-11-19T08:59:59Z'"):
        bad = os.path.join(fx.tmp, "F8bad.db")
        shutil.copy(db, bad)
        c2 = sqlite3.connect(bad)
        c2.execute(sql)
        c2.commit()
        c2.close()
        try:
            R.check_stored_times(bad, ren)
            check(False, f"TIME a claim time off by one second was not a defect ({sql})")
        except R.ReplayDefect:
            pass
    con.close()
    print("PASS: TIME a slow reader and an off-time stored row are replay defects; a renewal is accepted, off by a second is not")


def report():
    rep = R.cell_report({"bus-default": [0, 0, 0], "bus-complete": [120, 80, 100], "ledger-raw": [0, 0, 0],
                         "ledger-awk": [10, 0, 20]},
                        {"bus-default": [["ok", "cannot"], ["ok", "ok"], ["wrong", "ok"]], "ledger-raw": [["ok", "ok"]] * 3})
    r = rep["ratios"]
    check(r["bus-complete/ledger-raw"]["ratio_of_sums"] == "n/a: empty (numerator 300, denominator 0)", f"REPORT zero denominator {r}")
    check(r["bus-default/ledger-raw"]["ratio_of_medians"] == "n/a: empty (numerator 0, denominator 0)", "REPORT 0/0")
    check(r["bus-default/ledger-awk"]["ratio_of_sums"] == 0.0, "REPORT zero numerator")
    check(r["bus-complete/ledger-awk"]["ratio_of_sums"] == 10.0 and r["bus-complete/ledger-awk"]["ratio_of_medians"] == 10.0, "REPORT ratios")
    check(rep["bytes"]["bus-complete"] == {"median": 100, "q1": 90.0, "q3": 110.0, "min": 80, "max": 120}, f"REPORT describe {rep['bytes']}")
    dv = rep["derivability"]["bus-default"]
    check(dv == {"derivable": 4, "run": 6, "cannot_decide": 1, "wrong": 1, "seeds_with_any_miss": 2, "seeds": 3}, f"REPORT {dv}")
    print("PASS: REPORT zero numerator, zero denominator and 0/0 kept and labelled; quartiles; derivability counts")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--group", choices=("core", "rules", "all"), default="all",
                    help="core: PARITY and F1-F5, F7; rules: CAP, F6, GEN, TIME, REPORT (the suite runs each in its own file)")
    ap.add_argument("--cli", help="the command that runs agentbus, split on whitespace (default: this Python and bin/agentbus)")
    args = ap.parse_args()
    cli = args.cli.split() if args.cli else [sys.executable, os.path.join(R.ROOT, "bin", "agentbus")]
    tmp = tempfile.mkdtemp(prefix="ctxbench-fixture.")
    try:
        fx = Fx(R.Runner(cli, tmp), tmp)
        if args.group in ("core", "all"):
            parity(fx)
            cases(fx)
        if args.group in ("rules", "all"):
            cap(fx)
            p7(fx)
            gen()
            times(fx, cli)
            report()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"ctxbench sufficiency fixture ({args.group}): all checks passed")


if __name__ == "__main__":
    main()
