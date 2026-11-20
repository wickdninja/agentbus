"""Hand-derived oracle checks from ctxbench-protocol.md, never from CLI output.

Every check names its deciding D-rules and supplies a literal expected answer.
F1-F6 test semantic answers, not transport truncation or parser completeness.
Only the independent oracle is imported; no registered code is executed.
"""

from copy import deepcopy

from oracle import oracle, p7


DAY = "2026-11-19T"
CHECKS = 0


def time(hms):
    return DAY + hms + "Z"


def event(hms, actor, action, **fields):
    return (time(hms), actor, action, fields)


def post(hms, actor, kind, to="*", topic=None, reply_to=None, body="Fixture text."):
    return event(hms, actor, "post", kind=kind, to=to, topic=topic,
                 reply_to=reply_to, body=body)


def joins(hms, *names):
    return [event(hms, name, "join") for name in names]


def check(name, rules, events, probe, expected, now="12:30:00", me="alice", **inputs):
    """Check a hand answer and confirm the pure function preserves its inputs."""
    global CHECKS
    before = deepcopy((events, inputs))
    actual = oracle(events, probe, me, time(now), inputs)
    assert actual == expected, (name, rules, probe, "expected", expected, "got", actual)
    assert (events, inputs) == before, (name, "mutated inputs")
    CHECKS += 1


def f1():
    """F1: D7 distinguishes leaving before a todo from leaving after it."""
    for variant, bob_leaves, expected in (("A", "12:00:00", {1}),
                                          ("B", "12:20:00", {1, 2})):
        history = joins("11:50:00", "lead", "alice", "bob", "carol")
        if variant == "A":
            history.append(event(bob_leaves, "bob", "leave"))
        history += [post("12:10:00", "lead", "todo", "carol"),
                    post("12:10:00", "lead", "todo", "bob"),
                    event("12:20:00", "carol", "leave")]
        if variant == "B":
            history.append(event(bob_leaves, "bob", "leave"))
        check("F1" + variant, "D1,D2,D3,D7", history, "P4", expected)


def f2():
    """F2: D8 reads the final subject line, ignoring a note's quoted header."""
    for subject in ("parser", "uploader"):
        history = joins("11:50:00", "lead", "alice") + [
            post("12:00:00", "lead", "decision", topic="decision",
                 body="Keep the current wire format.\nSubject: " + subject),
            post("12:05:00", "alice", "note",
                 body="kind=DECISION id=9 from=lead to=all topic=decision\nSubject: decoy")]
        check("F2 " + subject, "D8", history, "P5", (1, subject))


def f3():
    """F3: D3-D6 cover exact closure, takeover, expiry and release."""
    history = joins("07:00:00", "lead", "alice", "bob", "carol") + [
        event("07:00:00", "carol", "claim", res="src/legacy/"),
        event("07:30:00", "lead", "claim", res="src/ci/"),
        event("09:01:00", "bob", "claim", res="src/parser/"),
        event("09:02:00", "carol", "claim", res="src/uploader/retry.py"),
        event("09:03:00", "alice", "claim", res="src/parser/", frm="bob"),  # alert 1
        post("09:04:00", "lead", "todo", "alice", "parser"),  # 2
        post("09:05:00", "lead", "todo", "alice", "uploader"),  # 3
        post("09:06:00", "alice", "done", "lead", "uploader", 3),  # 4
        post("09:07:00", "bob", "question", "alice", "parser"),  # 5
        post("09:08:00", "carol", "question"),  # 6, broadcast
        post("09:09:00", "alice", "question"),  # 7, my broadcast
        post("09:10:00", "lead", "answer", "carol", reply_to=6),  # 8
        post("09:11:00", "bob", "note", "alice", "parser", 5),  # 9
        post("09:12:00", "bob", "answer", "alice", "parser", 9),  # 10
        post("09:13:00", "lead", "todo", "carol", "uploader"),  # 11
        event("09:14:00", "bob", "claim", res="src/docs/"),
        event("09:15:00", "bob", "release", res="src/docs/")]
    check("F3 todo", "D2,D3", history, "P1", {2}, now="09:30:00")
    check("F3 question", "D4", history, "P3", {5}, now="09:30:00")
    for path, expected in (("src/legacy/f1.py", set()), ("src/ci/f1.py", set()),
                           ("src/parser/f1.py", {"alice"}),
                           ("src/uploader/retry.py", {"carol"}),
                           ("src/docs/f1.py", set())):
        check("F3 path " + path, "D5,D6", history, "P2", expected,
              now="09:30:00", x=path)
    for item, expected in (("parser", {"alice"}), ("uploader", {"carol"}),
                           ("legacy", set()), ("ci", set()), ("docs", set())):
        check("F3 item " + item, "D1,D2,D3,D5,D6", history, "P6", expected,
              now="09:30:00", y=item)


def f4():
    """F4: D7 makes the only open todo takeable after its owner leaves."""
    history = joins("11:50:00", "lead", "alice", "bob") + [
        post("12:00:00", "lead", "todo", "bob"),
        event("12:10:00", "bob", "leave")]
    check("F4 departed owner", "D1,D2,D3,D7", history, "P4", {1})


def f5():
    """F5: D8's subject is read from the whole semantic body, past byte 2048."""
    body = "Long decision rationale. " * 120 + "\nSubject: cache"
    assert body.index("Subject: ") > 2048
    history = joins("11:50:00", "lead", "alice") + [
        post("12:00:00", "lead", "decision", topic="decision", body=body)]
    check("F5 long body", "D8", history, "P5", (1, "cache"))


def f6():
    """F6: D3, D4, D7 yield three literal P7 refresh triples."""
    base = joins("09:00:00", "lead", "alice", "bob") + [
        post("09:01:00", "lead", "todo", "alice"),  # 1
        post("09:02:00", "bob", "question", "alice")]  # 2
    window1 = [post("09:06:00", "alice", "done", "lead", reply_to=1),  # 3
               post("09:07:00", "lead", "todo", "bob"),  # 4
               event("09:08:00", "bob", "leave")]
    window2 = [post("09:11:00", "alice", "answer", "bob", reply_to=2),  # 5
               post("09:12:00", "lead", "question")]  # 6
    for name, history, now, expected in (
            ("first", base, "09:05:00", ({1}, {2}, {1})),
            ("second", base + window1, "09:10:00", (set(), {2}, {4})),
            ("third", base + window1 + window2, "09:15:00", (set(), {6}, {4}))):
        check("F6 " + name, "D1,D2,D3,D4,D7", history, "P7", expected, now=now)
        # The helper must also handle a one-pass event iterable.
        assert p7(iter(history), "alice", time(now)) == expected, ("F6 helper", name)
        for probe, answer in zip(("P1", "P3", "P4"), expected):
            check("F6 " + name + " " + probe, "D1,D2,D3,D4,D7", history,
                  probe, answer, now=now)


def required_oracle_cases():
    """The five extra Oracle-section cases, with their hand-derived answers."""
    base = joins("09:00:00", "lead", "alice", "bob")
    no_link = base + [post("09:01:00", "lead", "todo", "alice"),
                      post("09:02:00", "alice", "done")]
    check("done without reply_to", "D3", no_link, "P1", {1})
    check("done without reply_to takeable", "D3,D7", no_link, "P4", {1})

    broadcast = base + [post("09:01:00", "alice", "todo", topic="parser")]
    check("broadcast belongs to sender", "D2,D3", broadcast, "P1", {1})
    check("broadcast not another agent's", "D2,D3", broadcast, "P1", set(), me="bob")
    check("broadcast takeable by sender", "D2,D7", broadcast, "P4", {1})
    check("broadcast work owner", "D1,D2,D3", broadcast, "P6", {"alice"}, y="parser")

    wrong_topic = base + [post("09:01:00", "lead", "decision", topic="parser",
                              body="Choose a parser.\nSubject: ignored")]
    check("decision with another topic", "D8", wrong_topic, "P5", (None, None))

    rejoined = base + [post("09:01:00", "lead", "todo", "bob", "parser"),
                       event("09:02:00", "bob", "leave"),
                       event("09:03:00", "bob", "join")]
    check("owner rejoined", "D1,D7", rejoined, "P4", set())
    check("rejoined owner still owns todo", "D2,D3", rejoined, "P1", {1}, me="bob")
    check("rejoined owner is working", "D1,D2,D3", rejoined, "P6", {"bob"}, y="parser")

    # A crash writes no semantic event: bob simply stops acting, without leave.
    crashed = base + [event("09:01:00", "bob", "claim", res="src/parser/")]
    check("crashed holder live", "D1,D5,D6", crashed, "P2", {"bob"},
          now="11:00:59", x="src/parser/f1.py")
    check("crashed holder exact expiry", "D5", crashed, "P2", set(),
          now="11:01:00", x="src/parser/f1.py")
    check("crashed holder past expiry", "D5", crashed, "P2", set(),
          now="11:01:01", x="src/parser/f1.py")


def closure_boundaries():
    """D3-D4: only the prescribed direct replies close their target messages."""
    history = joins("09:00:00", "lead", "alice", "bob") + [
        post("09:01:00", "lead", "todo", "alice"),  # 1
        post("09:02:00", "bob", "note", reply_to=1),  # 2
        post("09:03:00", "bob", "done", reply_to=2),  # 3: reply to reply
        post("09:04:00", "bob", "answer", reply_to=1),  # 4: wrong kind
        post("09:05:00", "lead", "todo", "alice"),  # 5
        post("09:06:00", "bob", "dropped", reply_to=5),  # 6
        post("09:07:00", "bob", "question", "alice"),  # 7
        post("09:08:00", "lead", "done", reply_to=7),  # 8: wrong kind
        post("09:09:00", "lead", "answer"),  # 9: unlinked
        post("09:10:00", "lead", "question", "bob"),  # 10: other recipient
        event("09:11:00", "alice", "inbox"),
        event("09:12:00", "alice", "leave")]
    check("exact todo closure", "D3", history, "P1", {1})
    check("exact question closure", "D4", history, "P3", {7})
    answered = history + [post("09:13:00", "lead", "answer", reply_to=7)]
    check("direct answer closes question", "D4", answered, "P3", set())
    check("answer cannot close todo", "D3", answered, "P1", {1})


def takeable_boundaries():
    """D1, D7: roster presence and whole-second leave timing both matter."""
    history = joins("09:00:00", "lead", "alice", "bob", "carol", "stopped") + [
        event("09:01:00", "carol", "leave"),
        post("09:02:00", "lead", "todo", "alice"),  # 1: mine, on roster
        post("09:02:00", "lead", "todo", "bob"),  # 2: leaves same second
        event("09:02:00", "bob", "leave"),
        post("09:02:00", "lead", "todo", "bob"),  # 3: same second, later in list
        post("09:03:00", "lead", "todo", "carol"),  # 4: left before todo
        post("09:03:00", "lead", "todo", "unknown"),  # 5: never joined
        post("09:03:00", "lead", "todo", "stopped")]  # 6: stopped, never left
    check("takeable whole seconds", "D1,D2,D3,D7", history, "P4", {1, 2, 3})
    check("stopped owner remains on roster", "D1,D7", history, "P4", {2, 3, 6}, me="stopped")
    check("off-roster owner still owns", "D2,D3", history, "P1", {2, 3}, me="bob")


def claim_boundaries():
    """D5-D6: renewals reset TTL; overlap is symmetric and slash-bounded."""
    base = joins("09:00:00", "lead", "alice", "bob")
    renewed = base + [event("09:00:00", "bob", "claim", res="src/parser/"),
                      event("10:00:00", "bob", "claim", res="src/parser/")]
    check("renewal resets expiry", "D5", renewed, "P2", {"bob"},
          now="11:30:00", x="src/parser/f1.py")
    check("renewed exact expiry", "D5", renewed, "P2", set(),
          now="12:00:00", x="src/parser/f1.py")
    departed = renewed + [event("10:01:00", "bob", "leave"),
                          event("10:02:00", "bob", "join")]
    check("leave ends claim permanently", "D1,D5", departed, "P2", set(),
          now="10:03:00", x="src/parser/f1.py")
    files = base + [event("09:01:00", "alice", "claim", res="src/parser/f1.py"),
                    event("09:02:00", "bob", "claim", res="src/parser/f2.py")]
    for path, expected in (("src/parser", {"alice", "bob"}),
                           ("src/parser/", {"alice", "bob"}),
                           ("src/parser/f1.py", {"alice"}),
                           ("src/parser/f10.py", set()),
                           ("src/parse", set()), ("src/parser2/", set())):
        check("overlap " + path, "D5,D6", files, "P2", expected,
              now="09:30:00", x=path)
    folder = base + [event("09:01:00", "bob", "claim", res="src/parser")]
    check("folder without trailing slash", "D6", folder, "P2", {"bob"},
          now="09:30:00", x="src/parser/f1.py")
    check("folder equality with slash", "D6", folder, "P2", {"bob"},
          now="09:30:00", x="src/parser/")
    released = folder + [event("09:02:00", "bob", "release", res="src/parser")]
    check("release before expiry", "D5", released, "P2", set(),
          now="09:30:00", x="src/parser/f1.py")


def decision_boundaries():
    """D8: latest means largest message id among matching kind AND topic."""
    history = joins("09:00:00", "lead", "alice", "bob") + [
        post("09:01:00", "lead", "decision", topic="decision",
             body="Subject: earlier footer\nRationale.\nSubject: first"),  # 1
        event("09:02:00", "bob", "claim", res="src/parser/"),
        event("09:03:00", "alice", "claim", res="src/parser/", frm="bob"),  # alert 2
        post("09:04:00", "lead", "decision", topic="decision",
             body="Later rationale.\nSubject: second"),  # 3
        post("09:05:00", "lead", "decision", topic="parser",
             body="Wrong topic.\nSubject: decoy"),  # 4
        post("09:06:00", "lead", "note", topic="decision",
             body="Wrong kind.\nSubject: another decoy")]  # 5
    check("last line only", "D8", history[:4], "P5", (1, "first"))
    check("largest genuine decision id", "D8", history, "P5", (3, "second"))


def p6_boundaries():
    """P6 unions D5-D6 holders with D1-D3 rostered todo owners by exact topic."""
    history = joins("09:00:00", "lead", "alice", "bob", "carol", "stopped") + [
        event("09:01:00", "alice", "claim", res="src/parser/f1.py"),
        post("09:02:00", "lead", "todo", "bob", "parser"),  # 1
        post("09:02:00", "lead", "todo", "carol", "parser"),  # 2
        post("09:02:00", "lead", "todo", "stopped", "parser"),  # 3
        post("09:02:00", "lead", "todo", "unknown", "parser"),  # 4
        post("09:02:00", "lead", "todo", topic="parser"),  # 5, lead owns
        post("09:03:00", "lead", "done", reply_to=2),  # 6
        post("09:03:00", "carol", "note", topic="parser"),  # 7, not a todo
        event("09:04:00", "bob", "leave")]
    check("working union", "D1,D2,D3,D5,D6", history, "P6",
          {"alice", "lead", "stopped"}, now="09:30:00", y="parser")
    check("working exact topic", "D1,D2,D3,D5,D6", history, "P6",
          set(), now="09:30:00", y="parse")


def empty_and_prefix_cases():
    """D1-D8: empty answers and same-second P7 prefixes are deterministic."""
    for probe, expected, inputs in (
            ("P1", set(), {}), ("P2", set(), {"x": "src/parser/f1.py"}),
            ("P3", set(), {}), ("P4", set(), {}), ("P5", (None, None), {}),
            ("P6", set(), {"y": "parser"}), ("P7", (set(), set(), set()), {})):
        check("empty " + probe, "D1-D8", [], probe, expected, **inputs)
    base = joins("09:00:00", "lead", "alice")
    posted = base + [post("09:01:00", "lead", "todo", "alice")]
    closed = posted + [post("09:01:00", "alice", "done", reply_to=1)]
    check("same-second prefix before closure", "D3,D7", posted, "P7",
          ({1}, set(), {1}), now="09:01:00")
    check("same-second prefix after closure", "D3,D7", closed, "P7",
          (set(), set(), set()), now="09:01:00")


def main():
    for fixture in (f1, f2, f3, f4, f5, f6, required_oracle_cases, closure_boundaries,
                    takeable_boundaries, claim_boundaries, decision_boundaries,
                    p6_boundaries, empty_and_prefix_cases):
        fixture()
    print("ctxbench oracle: {} hand-derived checks passed (D1-D8, P1-P7)".format(CHECKS))


if __name__ == "__main__":
    main()
