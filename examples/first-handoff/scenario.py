"""The first-handoff scenario: a tiny project, two tickets, and the check that decides the second one.

Alice's ticket gives her three answers from a partner call. Bob's ticket (feed/parse.py) cannot be done correctly
without them: the spec leaves them open and no file in the project holds them. The answers are drawn from a seed, so a
run cannot be passed from memory. Standard library only; works on Python 3.9.
"""
import datetime
import json
import os
import random
import subprocess
import sys
import textwrap

WEIGHT_UNITS = [("grams", 0.001), ("decagrams", 0.01), ("tenths of a kilogram", 0.1),
                ("half kilograms", 0.5), ("quarter kilograms", 0.25)]
DATE_FORMATS = [("DDMMYY", "%d%m%y"), ("YYMMDD", "%y%m%d"), ("MMDDYYYY", "%m%d%Y"),
                ("YYYYDDMM", "%Y%d%m"), ("DDMMYYYY", "%d%m%Y")]
MISSING_MARKERS = ["ZZ", "-9", "??", "0X", "XX"]
ZONES = ["N1", "S2", "E3", "W4", "C5"]

# The pieces of text only the answers contain; the project's files must never hold them.
def secret_strings(facts):
    return [facts["weight_unit"], facts["date_name"], facts["date_fmt"], facts["missing"]]


def facts(seed):
    r = random.Random("first-handoff-facts:%s" % seed)
    unit, factor = r.choice(WEIGHT_UNITS)
    date_name, date_fmt = r.choice(DATE_FORMATS)
    return {"weight_unit": unit, "weight_factor": factor, "date_name": date_name, "date_fmt": date_fmt,
            "missing": r.choice(MISSING_MARKERS)}


def feed_lines(seed, count=12):
    """[(line, expected dict)] for the hidden check."""
    f = facts(seed)
    r = random.Random("first-handoff-feed:%s" % seed)
    out = []
    for i in range(count):
        units = r.randint(3, 4000)
        day = datetime.date(2026, r.randint(1, 12), r.randint(13, 28))   # day > 12 and != month: no format reads two ways
        zone = None if i % 3 == 1 else r.choice(ZONES)
        pid = "P%05d" % r.randint(1, 99999)
        line = "|".join([pid, str(units), day.strftime(f["date_fmt"]), f["missing"] if zone is None else zone])
        out.append((line, {"id": pid, "weight_kg": units * f["weight_factor"], "shipped": day.isoformat(), "zone": zone}))
    return out


def notes_for_alice(seed):
    f = facts(seed)
    return textwrap.dedent("""\
        Partner call notes (you took the call with the carrier's integration contact; nobody else was on it):
        - Weights in the feed are whole numbers of %s.
        - Ship dates are written as %s, digits only, no separators.
        - A parcel with no delivery zone has %s in the zone column.""") % (f["weight_unit"], f["date_name"], f["missing"])


SPEC = """\
# Carrier feed

The carrier sends one parcel per line, four fields separated by `|`:

    ID|WEIGHT|SHIPPED|ZONE

`feed/parse.py` turns one line (no trailing newline) into a dict:

    {"id": str, "weight_kg": float, "shipped": "YYYY-MM-DD", "zone": str or None}

- A line without exactly four fields raises `ValueError`.
- WEIGHT is a whole number in the carrier's own unit; `weight_kg` is that weight in kilograms.
- SHIPPED is digits only, in the carrier's own date format; `shipped` is the ISO date.
- ZONE is a zone code, or the carrier's marker for "no zone", which becomes `None`.

Open: the carrier's weight unit, date format and no-zone marker. They were settled on a call; they are not
in this file and there is no sample feed yet. A wrong guess fails the integration.
"""

PARSE_STUB = '''\
"""Parse one line of the carrier's feed. See docs/spec.md."""


def parse_line(line):
    raise NotImplementedError("parse_line")
'''

REPORT_STUB = '''\
"""A one-line summary of a batch of parsed parcels."""


def format_summary(parcels):
    """parcels: list of dicts with "weight_kg" (float) and "zone" (str or None).

    Returns "N parcels, T kg total, Z without a zone": T has two decimals, and "1 parcel" is singular.
    An empty list gives "0 parcels, 0.00 kg total, 0 without a zone".
    """
    raise NotImplementedError("format_summary")
'''

TEST_PARSE = '''\
import unittest

from feed.parse import parse_line


class Shape(unittest.TestCase):
    def test_too_few_fields(self):
        with self.assertRaises(ValueError):
            parse_line("P00001|12|010126")

    def test_too_many_fields(self):
        with self.assertRaises(ValueError):
            parse_line("P00001|12|010126|N1|extra")


if __name__ == "__main__":
    unittest.main()
'''

TEST_REPORT = '''\
import unittest

from feed.report import format_summary


class Summary(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(format_summary([]), "0 parcels, 0.00 kg total, 0 without a zone")

    def test_one(self):
        self.assertEqual(format_summary([{"weight_kg": 1.5, "zone": None}]), "1 parcel, 1.50 kg total, 1 without a zone")

    def test_many(self):
        rows = [{"weight_kg": 0.25, "zone": "N1"}, {"weight_kg": 2.0, "zone": None}, {"weight_kg": 1.0, "zone": "S2"}]
        self.assertEqual(format_summary(rows), "3 parcels, 3.25 kg total, 1 without a zone")


if __name__ == "__main__":
    unittest.main()
'''

FILES = {
    "README.md": "# parcel-feed\n\nReads the carrier's parcel feed. Tests: `python3 -m unittest discover -s tests`.\n",
    "docs/spec.md": SPEC,
    "feed/__init__.py": "",
    "feed/parse.py": PARSE_STUB,
    "feed/report.py": REPORT_STUB,
    "tests/test_parse.py": TEST_PARSE,
    "tests/test_report.py": TEST_REPORT,
}


def make_project(dest):
    """Write the project into the (new or empty) folder dest. Nothing seed-dependent goes in: the answers live in notes_for_alice."""
    for rel, text in FILES.items():
        path = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)


_RUNNER = """\
import json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from feed.parse import parse_line
out = []
for line in json.load(sys.stdin):
    try:
        out.append({"ok": parse_line(line)})
    except Exception as exc:
        out.append({"error": "%s: %s" % (type(exc).__name__, exc)})
print(json.dumps(out))
"""


def check(project, seed):
    """(passed, detail). Runs the project's parse_line on the seed's feed in a child process. detail names what held:
    {"ok": bool, "id": n, "weight": n, "date": n, "zone": n, "of": n, "error": first error or None}."""
    pairs = feed_lines(seed)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    try:
        proc = subprocess.run([sys.executable, "-I", "-c", _RUNNER, project], input=json.dumps([l for l, _ in pairs]),
                              capture_output=True, text=True, timeout=30, env=env, cwd=project)
    except subprocess.TimeoutExpired:
        return False, {"ok": False, "of": len(pairs), "error": "timeout"}
    detail = {"id": 0, "weight": 0, "date": 0, "zone": 0, "of": len(pairs), "error": None}
    try:
        results = json.loads(proc.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        detail["ok"] = False
        detail["error"] = (proc.stderr.strip().splitlines() or ["no output"])[-1][:200]
        return False, detail
    for (line, want), got in zip(pairs, results):
        if "error" in got:
            detail["error"] = detail["error"] or got["error"][:200]
            continue
        row = got["ok"]
        if not isinstance(row, dict):
            detail["error"] = detail["error"] or "parse_line returned %s" % type(row).__name__
            continue
        detail["id"] += row.get("id") == want["id"]
        w = row.get("weight_kg")
        detail["weight"] += isinstance(w, (int, float)) and abs(w - want["weight_kg"]) < 1e-6
        detail["date"] += row.get("shipped") == want["shipped"]
        detail["zone"] += row.get("zone") == want["zone"]
    detail["ok"] = all(detail[k] == detail["of"] for k in ("id", "weight", "date", "zone"))
    return detail["ok"], detail


# ---- the tickets --------------------------------------------------------------------------------------------------
# The channel sentence is the only text that differs between conditions; its wording is the value eval's (KEEP_CURRENT and
# the per-condition sentence), so the ledger gets the same care as the bus.

KEEP_CURRENT = "Keep it current as you work: your session can end at any time, and someone may have to pick up from what you left there."
TAIL = "Work only in this folder. Do not commit; leave your changes in the working tree. When your ticket is finished, stop."


def channel_block(condition, name, peer, harness):
    if condition == "none":
        return ""   # the control: no channel, so bob cannot learn the answers
    how = "skill" if harness == "claude" else "section in AGENTS.md"
    if condition == "ledger":
        return "Coordinate with %s through COORDINATION.md at the repo root, following the ledger %s. Sign your entries as %s. %s" % (peer, how, name, KEEP_CURRENT)
    if condition == "agentbus":
        return "Coordinate with %s through agentbus, following the agentbus %s. Your name on the bus is %s. %s" % (peer, how, name, KEEP_CURRENT)
    raise ValueError(condition)


def prompt(role, condition, seed):
    """The session prompt for alice (Claude) or bob (Codex)."""
    if role == "alice":
        ticket = ("Your ticket: implement format_summary in feed/report.py so that tests/test_report.py passes; its docstring says what it returns. "
                  "Edit only feed/report.py and tests/test_report.py, and keep the call notes out of every repository file except the coordination channel.\n\n"
                  "%s\n\nBob writes feed/parse.py after you, from docs/spec.md. The spec's three open details (the weight unit, the date format "
                  "and the no-zone marker) are the answers in your notes, and Bob has no other way to get them." % notes_for_alice(seed))
        return "\n\n".join(x for x in ["You are alice. Bob also works on this repository, at a different time.", ticket,
                                       channel_block(condition, "alice", "bob", "claude"), TAIL] if x)
    if role == "bob":
        ticket = ("Your ticket: implement parse_line in feed/parse.py as docs/spec.md describes, so the carrier's feed parses correctly; tests/test_parse.py must pass. "
                  "The spec leaves three details open: the weight unit, the date format and the no-zone marker. Alice took the call with the carrier "
                  "and has the answers; you do not, and there is no sample feed. A wrong guess fails the integration, so find the answers out rather than guess.")
        return "\n\n".join(x for x in ["You are bob. Alice worked on this repository before you and has finished.", ticket,
                                       channel_block(condition, "bob", "alice", "codex"), TAIL] if x)
    raise ValueError(role)
