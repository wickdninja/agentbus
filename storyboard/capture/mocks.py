#!/usr/bin/env python3
"""Build the PR B design frames from the captured ones.

  python3 storyboard/capture/mocks.py

Reads storyboard/frames/captured.js (the real tool's output) and writes storyboard/frames/mocked.js. Every
mocked frame starts from a captured watch screen and changes only what PR B changes: agent colours, the
claim hand-over mark, the empty-state copy and the demo caption. Each edit is a function below, so a
reviewer can see exactly what differs from today. Frames with nothing captured to start from (Codex's
own review screen, the new demo start, the example's check) are written out whole and say so.
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
FRAMES_DIR = os.path.join(os.path.dirname(HERE), "frames")
SGR = re.compile(r"\x1b\[([0-9;]*)m")
WIDE = re.compile("[\U0001F300-\U0001FAFF☀-➿]")

# Today agents take 34 36 35 32 33 94 96 95 in roster order, and kinds reuse the same hues (answer is cyan
# like the second agent). PR B: colour means who. Agents take blue, magenta, green, cyan, then the bright
# ones; no yellow (the bus accent and the change mark) and no red (alerts). Kinds lose their colour,
# except alert.
OLD = ("34", "36", "35", "32", "33", "94", "96", "95")
NEW = ("34", "35", "32", "36", "94", "95", "92", "96")
KIND = re.compile(r"^(\S+ )?(handoff|question|answer|done|decision|note|alert|hand|ask|ans|dec|ALRT)\s*$")
ACCENT, FLASH = "33", "30;43"


def parse(ansi):
    """A whole watch repaint as rows of [char, sgr] cells; a wide character is followed by a placeholder."""
    body = ansi.replace("\x1b[2J", "").replace("\x1b[H", "").replace("\x1b[J", "")
    rows = []
    for line in body.split("\r\n"):
        line = line.replace("\x1b[K", "").replace("\r", "")
        row, sgr, i = [], "", 0
        while i < len(line):
            m = SGR.match(line, i)
            if m:
                sgr = "" if m.group(1) in ("0", "") else m.group(1)
                i = m.end()
                continue
            c = line[i]
            row.append([c, sgr])
            if WIDE.match(c):
                row.append(["", sgr])
            i += 1
        rows.append(row)
    return rows


def serialize(rows):
    out = []
    for row in rows:
        parts, cur, buf = [], None, ""
        for c, sgr in row:
            if sgr != cur:
                if buf:
                    parts.append(f"\x1b[{cur}m{buf}\x1b[0m" if cur else buf)
                cur, buf = sgr, ""
            buf += c
        if buf:
            parts.append(f"\x1b[{cur}m{buf}\x1b[0m" if cur else buf)
        out.append("".join(parts) + "\x1b[K")
    return "\x1b[2J\x1b[H" + "\r\n".join(out) + "\x1b[J"


def text(row):
    return "".join(c if c else "\0" for c, _ in row)


def col(row, s, start=0):
    i = text(row).find(s, start)
    if i < 0:
        raise ValueError(f"{s!r} not in row {text(row)!r}")
    return i


def put(row, at, s, sgr):
    while len(row) < at + len(s):
        row.append([" ", ""])
    for k, ch in enumerate(s):
        row[at + k] = [ch, sgr]


def paint(row, at, n, sgr):
    for k in range(at, at + n):
        row[k][1] = sgr


def spans(row):
    """(start, end, sgr) runs of one SGR."""
    out, start = [], 0
    for i in range(1, len(row) + 1):
        if i == len(row) or row[i][1] != row[start][1]:
            out.append((start, i, row[start][1]))
            start = i
    return out


def section_rows(rows, title):
    """The rows under a section title ("👥 Agents  3", or "Agents  3" without emoji), up to the next unindented row."""
    start = next(i for i, r in enumerate(rows) if re.match(r"^(\S )?" + title + r"\b", text(r).replace("\0", "")))
    end = start + 1
    while end < len(rows) and text(rows[end])[:2] in ("  ", "▌ ", "> ", "| "):
        end += 1
    return range(start + 1, end)


def colours(rows):
    """PR B colours: agents in NEW, kinds plain (alert stays red), the agent's name in the roster coloured too."""
    msgs = section_rows(rows, "Messages")
    for i in msgs:
        for a, b, sgr in spans(rows[i]):
            if KIND.match(text(rows[i])[a:b].replace("\0", "")) and sgr != "31":
                paint(rows[i], a, b - a, "")
    for row in rows:
        for c in row:
            if c[1] in OLD and c[0] != "▌":
                c[1] = NEW[OLD.index(c[1])]
    # The roster's names take their agent's colour too, idle or not (watch assigns colours in roster order).
    k = 0
    for i in section_rows(rows, "Agents"):
        row = rows[i]
        if len(row) < 3 or row[2][0] not in "●○":
            continue
        agent = NEW[k] if k < len(NEW) else ""
        k += 1
        t = text(row)
        start = 7 if WIDE.match(t[4]) else 4
        end = t.find("  ", start)
        if agent:
            paint(row, start, end - start, ("1;" + agent) if row[start][1] == "1" else agent)
    return rows


def handover(rows, resource, holder, was, phase, colour=True):
    """The mark on a claim that just changed hands. phase 1: first paint (0 ms), 2: from 1000 ms, 3: from 3000 ms (gone)."""
    i = next(i for i in section_rows(rows, "Claims") if text(rows[i]).startswith("  " + resource))
    row = rows[i]
    if phase == 3:
        return rows
    h = col(row, holder, 2 + len(resource))
    after = h + len(holder)
    while after < len(row) and row[after][0] == " ":
        after += 1
    rest = text(row)[after:].rstrip().replace("\0", "")
    width = len(row)
    note = f"from {was}"
    tail = (" · " + rest) if rest else ""
    room = width - after
    if len(note) + len(tail) > room:
        tail = ""
    put(row, 0, "▌", ACCENT if colour else "")
    put(row, after, note.ljust(room), "")
    paint(row, after, len(note), ACCENT if colour else "")
    if tail:
        put(row, after + len(note), tail, "2" if colour else "")
    if colour:
        agent = row[h][1].split(";")[-1]
        paint(row, h, len(holder), FLASH if phase == 1 else "1;" + agent)
    return rows


def replace_rows(rows, at, new, total):
    """Rows `at` onward replaced by `new` (each a list of (text, sgr) parts); the frame keeps `total` rows."""
    built = []
    for parts in new:
        row = []
        for s, sgr in parts:
            for ch in s:
                row.append([ch, sgr])
        built.append(row)
    rows[at:at + 1] = built
    blank = next(i for i in range(len(rows) - 2, 0, -1) if not text(rows[i]).strip())
    while len(rows) > total:
        del rows[blank]
        blank -= 1
    return rows


def empty_state(rows, cols):
    i = next(i for i in section_rows(rows, "Agents"))
    if cols >= 80:
        new = [[("  no one yet. A Claude Code or Codex session started in ~/src/app joins by itself.", "")],
               [("  Codex not here? Trust its hooks: type ", "2"), ("/hooks", "1"), (" in Codex.", "2")],
               [("  Not sure? ", "2"), ("agentbus doctor", "1"), (" says what is missing.", "2")]]
    else:
        new = [[("  no one yet. Sessions started here join by themselves.", "")],
               [("  Codex not here? Trust its hooks: ", "2"), ("/hooks", "1"), (" in Codex.", "2")],
               [("  Not sure? Run ", "2"), ("agentbus doctor", "1"), (".", "2")]]
    return replace_rows(rows, i, new, len(rows))


def demo_caption(rows, cols, step, total, caption, command):
    """The demo's caption on the two rows above the key hints, and the header naming the demo bus."""
    head = rows[0]
    a = col(head, "~/src/app")
    label = "demo bus, gone when you quit"
    pad = col(head, "0 ") - a
    put(head, a, label.ljust(pad)[:pad], FLASH)
    n = len(rows)
    lines = []
    if step is None:
        done = "  Look around: Tab moves, Enter opens. q quits and removes the bus." if cols >= 80 else "  Look around. q quits and removes the bus."
        lines.append([("  ", ""), (" done ", FLASH), (done, "")])
        lines.append([("", "")])
    else:
        tag = f" {step}/{total} "
        cap = caption if len(caption) + len(tag) + 4 <= cols else caption[:cols - len(tag) - 5] + "…"
        lines.append([("  ", ""), (tag, FLASH), ("  " + cap, "")])
        cmd = "$ " + command
        if len(cmd) + 2 > cols:
            cmd = cmd[:cols - 3] + "…"
        lines.append([("  " + cmd, "2")])
    for k, parts in enumerate(lines):
        r = n - 3 + k
        if text(rows[r]).strip():
            raise SystemExit(f"demo caption would cover row {r}: {text(rows[r])!r}")
        row = []
        for s, sgr in parts:
            for ch in s:
                row.append([ch, sgr])
        rows[r] = row
    return rows


def frame(base, rows, note, source="mocked"):
    return {"cols": base["cols"], "rows": base["rows"], "cmd": base["cmd"], "ansi": serialize(rows),
            "source": source, "note": note, "from": base.get("_id")}


def plain(lines, cols, rows, cmd, note):
    """A frame written out whole: a list of rows, each a list of (text, sgr) parts."""
    out = []
    for parts in lines:
        out.append("".join(f"\x1b[{sgr}m{s}\x1b[0m" if sgr else s for s, sgr in parts))
    return {"cols": cols, "rows": rows, "cmd": cmd, "ansi": "\r\n".join(out), "source": "mocked", "note": note}


def main():
    src = open(os.path.join(FRAMES_DIR, "captured.js")).read()
    cap = json.loads(src[src.index("=") + 1:].rstrip().rstrip(";"))
    for k, v in cap.items():
        if isinstance(v, dict) and "ansi" in v:
            v["_id"] = k
    M = {}
    names = cap["names"]
    for cols in (100, 60):
        b = cap[f"first-watch-{cols}"]
        M[f"first-watch-{cols}"] = frame(b, colours(parse(b["ansi"])), "PR B colours: each agent one colour, everywhere it appears")
        b = cap[f"handover-before-{cols}"]
        M[f"handover-before-{cols}"] = frame(b, colours(parse(b["ansi"])), "before: worker holds src/auth/")
        b = cap[f"handover-after-{cols}"]
        for phase, note in ((1, "0 ms: the first paint that shows lead as holder"), (2, "1000 ms: the next paint"),
                            (3, "3000 ms: the mark is gone")):
            M[f"handover-{cols}-p{phase}"] = frame(b, handover(colours(parse(b["ansi"])), "src/auth/", "lead", "worker", phase), note)
        b = cap[f"handover-nocolor-{cols}"]
        M[f"handover-nocolor-{cols}"] = frame(b, handover(parse(b["ansi"]), "src/auth/", "lead", "worker", 2, colour=False),
                                              "NO_COLOR=1, 0 to 3000 ms: the bar and the words carry it")
        b = cap[f"empty-goal-{cols}"]
        M[f"empty-goal-{cols}"] = frame(b, empty_state(parse(b["ansi"]), cols), "nobody yet: the goal and facts stay, the hint points at the real causes")
    steps = cap["demo-steps"]
    total = len(steps)
    for cols in (100, 60):
        b = cap[f"demo-{cols}-0"]
        M[f"demo-{cols}-0"] = frame(b, demo_caption(colours(parse(b["ansi"])), cols, 0, total, "Starting the tour.", "agentbus init (a temporary bus)"),
                                    "watch opens at once; the tour starts behind it")
        for s in steps:
            i = s["step"]
            b = cap[f"demo-{cols}-{i}"]
            rows = colours(parse(b["ansi"]))
            if i == total:
                rows = handover(rows, "src/auth/", "lead", "worker", 2)
            M[f"demo-{cols}-{i}"] = frame(b, demo_caption(rows, cols, i, total, s["caption"] or "The second agent joins.", s["command"]), s["caption"] or "The second agent joins.")
        b = cap[f"demo-{cols}-end"]
        M[f"demo-{cols}-end"] = frame(b, demo_caption(colours(parse(b["ansi"])), cols, None, total, "", ""), "the tour is over; watch stays until q")

    claude, codex = names["claude"], names["codex"]
    M["codex-review"] = plain([
        [("", "")],
        [("  ", ""), ("Hooks need review", "1")],
        [("", "")],
        [("  4 hooks are new or changed.", "")],
        [("  Hooks can run outside the sandbox after you trust them.", "2")],
        [("", "")],
        [("  › ", "36"), ("Review hooks", "36")],
        [("    Trust all and continue", "")],
        [("    Continue without trusting (hooks won't run)", "")],
        [("", "")],
    ], 92, 10, "codex", "Codex's own screen: the words are Codex 0.166.0's, the layout is drawn")
    M["codex-review"]["source"] = "drawn"
    M["install"] = plain([
        [("\x1b[2m~\x1b[0m $ uv tool install https://github.com/wickdninja/agentbus/releases/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl", "")],
        [("Resolved 1 package in 412ms", "2")],
        [("Installed 1 package in 3ms", "2")],
        [(" + ", "32"), ("agentbus==0.3.0 (from https://github.com/wickdninja/agentbus/releases/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl)", "")],
        [("Installed 1 executable: ", ""), ("agentbus", "1")],
    ], 92, 7, "uv tool install", "uv's own lines, written out: nothing to capture until v0.3.0 is released")
    M["demo-start"] = plain([
        [("\x1b[2m~/src/app\x1b[0m $ agentbus demo", "")],
        [("agentbus demo: two scripted agents on a temporary bus, about 30 seconds.", "")],
        [("Nothing here touches your project. watch opens now and the tour runs inside it; q quits.", "")],
    ], 92, 4, "agentbus demo", "the first two lines, then watch takes the screen")
    M["demo-after"] = plain([
        [("\x1b[2m~/src/app\x1b[0m $ agentbus demo", "")],
        [("agentbus demo: two scripted agents on a temporary bus, about 30 seconds.", "")],
        [("Nothing here touches your project. watch opens now and the tour runs inside it; q quits.", "")],
        [("", "")],
        [("That was the whole loop, and the demo bus is already gone. To use it in your own repo:", "")],
        [("  agentbus init .", "")],
        [("  agentbus setup claude     (or: agentbus setup codex)", "")],
        [("  agentbus watch            (a live view for you; q quits)", "")],
        [("\x1b[2m~/src/app\x1b[0m $ ", "")],
    ], 92, 10, "agentbus demo", "after q: the closing lines are today's, unchanged")
    M["check"] = plain([
        [("\x1b[2m~/src/app\x1b[0m $ bash examples/first-handoff/check.sh", "")],
        [("upload limit in app/upload.py     5000000", "")],
        [("upload limit in tests/            5000000  (was 10485760 before codex read message #2)", "")],
        [("", "")],
        [("PASS", "1;32"), ("  codex's test changed because of claude's answer.", "")],
    ], 92, 6, "bash examples/first-handoff/check.sh", "the example checks its own result")
    M["names"] = names
    with open(os.path.join(FRAMES_DIR, "mocked.js"), "w") as f:
        f.write("// Generated by storyboard/capture/mocks.py from captured.js. Do not edit.\n")
        f.write("window.MOCKED = " + json.dumps(M, indent=1, ensure_ascii=False) + ";\n")
    print(f"wrote {len(M)} frames to storyboard/frames/mocked.js")


if __name__ == "__main__":
    main()
