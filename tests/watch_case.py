"""Helpers for tests/test_watch_keys.sh: bin/agentbus's pure watch core on the golden fixture, and real buses
built from it for the pty sessions.

    from watch_case import W
    W.g                     the module globals of bin/agentbus (the copy agentbus_argv() names), loaded with TZ=UTC
    W.text_of(cols, rows, view, snap="sample", ...)   a rendered frame as rows of text (the design mock's helper)
    W.view(**fields)        a View with the fixture's field names
    W.make_bus(path, snap)  a real bus holding a fixture snapshot, every time moved back `days` days
"""
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

TESTS = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(TESTS, "golden", "watch")
sys.path.insert(0, TESTS)
sys.path.insert(0, GOLDEN)
from agentbus_cmd import agentbus_argv  # noqa: E402
import render as R  # noqa: E402  (tests/golden/watch/render.py: the golden adapter)


def bin_path():
    """The script the CLI helpers run: a mutation copy (AGENTBUS_BIN) or the checkout's bin/agentbus."""
    if os.environ.get("AGENTBUS_CMD"):
        return None
    return agentbus_argv()[-1]


class _W:
    def __init__(self):
        self.fx = json.load(open(os.path.join(GOLDEN, "fixture.json"), encoding="utf-8"))
        self.g = R.load(bin_path(), False) if bin_path() else None
        self.snaps = self.fx["snapshots"]
        self.t = {}
        for e in self.fx["goldens"]:
            self.t.setdefault(e["snapshot"], e["t_now"])
        self.T_NOW = self.t["sample"]
        self.FROZEN = {"snapshot": "sample", "t_now": self.T_NOW}
        self.WHERE = "~/src/acme-api"

    def when(self, s):
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

    def snap(self, name):
        return json.loads(json.dumps(self.snaps[name]))

    def view(self, **fields):
        v = self.g["View"]()
        for k, val in fields.items():
            if k not in ("error", "stale", "fresh"):
                setattr(v, k, val)
        return v

    def frame(self, cols, rows, fields, snap="sample", held=None, ascii=False, emoji=False, live=True, snapshot=None,
              paint_on=False):
        s = snapshot or self.snap(snap)
        v = self.view(**fields)
        h = self.snap(held) if held else None
        paint = self.g["Paint"](paint_on, emoji, ascii)
        return self.g["render"](v, s, self.WHERE, (cols, rows), self.when(self.t.get(snap, self.T_NOW)), paint,
                                error=fields.get("error"), stale=fields.get("stale"), fresh=set(fields.get("fresh", ())),
                                live=live, detail=R.detail_data(self.g, v, s, h, self.fx["detail"]), held=h)

    def text_of(self, cols, rows, fields, **kw):
        return [r.rstrip() for r in self.frame(cols, rows, fields, **kw)]

    @staticmethod
    def ids_in(lines):
        return [int(m.group(1)) for l in lines for m in [re.match(r"^[ >*▌|] #(\d+)", l)] if m]

    def detail_for(self, view, snap, held=None):
        return R.detail_data(self.g, view, snap, held, self.fx["detail"])

    def make_bus(self, db, snap="sample", days=3, run=None):
        """Fill db (a bus the CLI already created) with a fixture snapshot and its detail rows, every time moved
        back `days` days so ages are whole days and stay put while a test runs. Claims are left out (their
        time left moves with the clock). Returns the shift as a timedelta."""
        shift = timedelta(days=days)
        s = self.snaps[snap]
        old = lambda ts: (self.when(ts) - shift).strftime("%Y-%m-%dT%H:%M:%SZ")
        c = sqlite3.connect(db)
        for t in ("messages", "agents", "cursors", "context", "context_history", "claims", "log"):
            c.execute(f"DELETE FROM {t}")
        top = max(m["id"] for m in s["messages"]) if s["messages"] else 0
        msgs = {m["id"]: m for m in self.fx["detail"]["messages"] if m["id"] <= top}
        for i in sorted(msgs):
            m = msgs[i]
            c.execute("INSERT INTO messages(id, ts, sender, recipient, kind, topic, body, reply_to) VALUES(?,?,?,?,?,?,?,?)",
                      (m["id"], old(m["ts"]), m["sender"], m["recipient"], m["kind"], m.get("topic"), m["body"], m["reply_to"]))
        for a in s["agents"]:
            c.execute("INSERT INTO agents(name, role, joined_at, last_seen) VALUES(?,?,?,?)",
                      (a["name"], a["role"], old(a["joined_at"]), old(a["last_seen"])))
            c.execute("INSERT INTO cursors(agent, last_read_id, bcast_from) VALUES(?,?,0)", (a["name"], top))
        for x in s["context"]:
            c.execute("INSERT INTO context(key, value, updated_by, updated_at) VALUES(?,?,?,?)",
                      (x["key"], x["value"], x["updated_by"], old(x["updated_at"])))
        if s.get("goal"):
            g = s["goal"]
            c.execute("INSERT INTO context(key, value, updated_by, updated_at) VALUES('goal',?,?,?)",
                      (g["goal"], g["set_by"], old(g["set_at"])))
        c.commit()
        c.close()
        return shift


W = _W()


def bus_state(db):
    """The bus as bytes and as a full table dump (every table, every row), to prove watch wrote nothing."""
    import shutil
    import tempfile
    data = open(db, "rb").read()
    wal = open(db + "-wal", "rb").read() if os.path.exists(db + "-wal") else b""
    d = tempfile.mkdtemp()
    try:  # dump a copy: a connection on the bus itself could checkpoint it on close and change its bytes
        with open(os.path.join(d, "bus.db"), "wb") as f:
            f.write(data)
        if wal:
            with open(os.path.join(d, "bus.db-wal"), "wb") as f:
                f.write(wal)
        c = sqlite3.connect(os.path.join(d, "bus.db"))
        try:
            dump = [(t, c.execute(f'SELECT * FROM "{t}" ORDER BY rowid').fetchall())
                    for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        finally:
            c.close()
    finally:
        shutil.rmtree(d)
    return data, wal, dump
