#!/usr/bin/env python3
"""Golden adapter for tests/test_watch_golden.sh (issue #7): renders fixture entries with bin/agentbus.

    render.py BIN FIXTURE [--shift-clock]   prints {"name": "frame text" or null, ...} as JSON

A frame is its rows with trailing spaces removed, each ending in a newline, as in the golden files.
null means the renderer cannot produce that state.

- bin/agentbus is loaded with runpy, with TZ=UTC (detail times are local HH:MM; the fixture is UTC).
- If the module has `render` (06), render_v2 below calls it. 06 owns the body of render_v2 and may
  change how it calls its own render; it may not change fixture.json or a golden without a new owner
  sign-off.
- Otherwise (v0.1.0) only entries whose view is the default can be drawn, with render_watch; every
  other state is null. That is what fills PENDING on day one.
- --shift-clock moves the wall clock 400 days forward (time.time and datetime.now in the module), so
  the harness can prove a frame depends on the entry's t_now and never on the clock or HOME.
"""
import json
import os
import runpy
import sys
import time
from datetime import datetime, timedelta, timezone

DEFAULT_VIEW = {"mode": "overview", "focus": "messages", "sel": {}, "paused": False, "frozen": {},
                "filter": "", "filter_input": False, "detail": None, "scroll": 0,
                "fresh": [], "error": None, "stale": None, "copied": None}
SHIFT = timedelta(days=400)


def load(bin_, shift):
    os.environ["TZ"] = "UTC"
    time.tzset()
    mod = runpy.run_path(bin_, run_name="agentbus_golden")
    g = mod["render_watch"].__globals__  # the live module globals (run_path returns a copy)
    if shift:
        real_time, real_dt = time.time, g["datetime"]

        class Shifted(real_dt):
            @classmethod
            def now(cls, tz=None):
                return real_dt.now(tz) + SHIFT

            @classmethod
            def utcnow(cls):
                return real_dt.utcnow() + SHIFT
        g["datetime"] = Shifted
        time.time = lambda: real_time() + SHIFT.total_seconds()
    return g


def frame_text(rows, height):
    rows = [str(r).rstrip() for r in rows]
    return "".join(r + "\n" for r in rows)


def render_v2(g, e, snap, held, detail, paint, t_now):
    """06: adjust this call to match `render`; the inputs are fixed by fixture.json. `held` is the frozen
    snapshot of a paused view (None otherwise); paint carries emoji and the ASCII glyph set."""
    view = g["View"]()
    v = e["view"]
    for k, val in v.items():
        if k not in ("error", "stale", "fresh"):
            setattr(view, k, val)
    rows = g["render"](view, snap, e["where"], (e["cols"], e["rows"]), t_now, paint,
                       error=v["error"], stale=v["stale"], fresh=set(v["fresh"]), live=e["live"], detail=detail,
                       held=held)
    return frame_text(rows, e["rows"])


def render_v01(g, e, snap, paint, t_now):
    v = e["view"]
    if e.get("ascii") or any(v.get(k) != DEFAULT_VIEW[k] for k in DEFAULT_VIEW if k != "fresh"):
        return None
    rows = g["render_watch"](snap, e["where"], e["cols"], e["rows"], set(v["fresh"]), t_now, paint, live=e["live"])
    return frame_text(rows, e["rows"])


def main():
    bin_, fixture = sys.argv[1], sys.argv[2]
    shift = "--shift-clock" in sys.argv[3:]
    fx = json.load(open(fixture, encoding="utf-8"))
    g = load(bin_, shift)
    out = {}
    for e in fx["goldens"]:
        snap = json.loads(json.dumps(fx["snapshots"][e["snapshot"]]))
        t_now = datetime.strptime(e["t_now"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        paint = g["Paint"](False, e["emoji"])
        if e.get("ascii"):
            paint.ascii = True  # 06: AGENTBUS_ASCII, TERM=linux or an ambiguous-wide terminal
        if "render" in g and "View" in g:
            held = fx["snapshots"][e["held"]] if e.get("held") else None
            out[e["name"]] = render_v2(g, e, snap, held, fx["detail"], paint, t_now)
        else:
            out[e["name"]] = render_v01(g, e, snap, paint, t_now)
    json.dump(out, sys.stdout, ensure_ascii=False, sort_keys=True)


if __name__ == "__main__":
    main()
