#!/usr/bin/env python3
"""Writes hero-light.svg and hero-dark.svg: the README's "how agents work together" diagram.

Hand-authored SVG instead of Mermaid: a hub with agents around it and numbered steps on the
edges needs fixed positions, which Mermaid's automatic layout does not give. Text stays real
<text>, so it is crisp at any size and searchable. render.sh turns both files into 2x PNGs.
"""
import pathlib
from xml.sax.saxutils import escape

W, H = 1100, 900
SANS = "Inter, -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"

THEMES = {
    "light": dict(bg="#ffffff", ink="#1f2328", muted="#57606a", box="#ffffff", boxline="#d0d7de",
                  bus="#FFF8DB", busline="#F5B800", card="#ffffff", cardline="#F0D47A",
                  head="#F5B800", headink="#1f2328", line="#1f2328", badge="#F5B800",
                  badgeink="#1f2328", bad="#cf222e", you="#FFF4CC"),
    "dark": dict(bg="#0d1117", ink="#e6edf3", muted="#9198a1", box="#161b22", boxline="#3d444d",
                 bus="#1c1a10", busline="#F5B800", card="#161b22", cardline="#6b5714",
                 head="#F5B800", headink="#1f2328", line="#c9d1d9", badge="#F5B800",
                 badgeink="#1f2328", bad="#f85149", you="#2a2410"),
}

# Agents: (x, y, w, h, name, role)
BOX_W, BOX_H = 230, 104
TOP = 40
CLAUDE = (40, TOP, BOX_W, BOX_H, "claude", "lead agent")
CODEX = (435, TOP, BOX_W, BOX_H, "codex", "implementer")
TESTS = (830, TOP, BOX_W, BOX_H, "tests", "test subagent")
BUS = (230, 330, 640, 300)
YOU = (435, 760, BOX_W, BOX_H, "You", "the human")


def text(x, y, s, size, c, weight=400, anchor="start", family=SANS):
    return (f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" font-weight="{weight}" '
            f'fill="{c}" text-anchor="{anchor}">{escape(s)}</text>')


def badge(cx, cy, n, t):
    return (f'<circle cx="{cx}" cy="{cy}" r="16" fill="{t["badge"]}" stroke="{t["bg"]}" stroke-width="3"/>'
            + text(cx, cy + 6.5, str(n), 18, t["badgeink"], 700, "middle"))


def label(x, y, n, s, t, anchor="start", sub=None):
    """A numbered step: badge, then the words. anchor is where the badge sits relative to the text."""
    out = []
    if anchor == "start":
        out.append(badge(x + 16, y - 6, n, t))
        out.append(text(x + 40, y, s, 19, t["ink"], 600))
        if sub:
            out.append(text(x + 40, y + 24, sub, 18, t["muted"], 400, family=MONO))
    else:  # badge on the right, text right-aligned before it
        out.append(badge(x - 16, y - 6, n, t))
        out.append(text(x - 40, y, s, 19, t["ink"], 600, "end"))
        if sub:
            out.append(text(x - 40, y + 24, sub, 18, t["muted"], 400, "end", MONO))
    return "".join(out)


def arrow(points, t, color=None, dashed=False, marker="arrow"):
    d = "M " + " L ".join(f"{x} {y}" for x, y in points)
    dash = ' stroke-dasharray="7 6"' if dashed else ""
    end = f' marker-end="url(#{marker})"' if marker else ""
    return (f'<path d="{d}" fill="none" stroke="{color or t["line"]}" stroke-width="2.5" '
            f'stroke-linejoin="round" stroke-linecap="round"{dash}{end}/>')


def agent(box, t, fill=None):
    x, y, w, h, name, role = box
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="18" fill="{fill or t["box"]}" '
            f'stroke="{t["boxline"]}" stroke-width="2"/>'
            + text(x + w / 2, y + 46, name, 26, t["ink"], 700, "middle")
            + text(x + w / 2, y + 78, role, 19, t["muted"], 400, "middle"))


def bus(t):
    x, y, w, h = BUS
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="22" fill="{t["bus"]}" '
           f'stroke="{t["busline"]}" stroke-width="3"/>',
           # Header strip: rounded top, square bottom.
           f'<path d="M {x} {y + 60} V {y + 22} Q {x} {y} {x + 22} {y} H {x + w - 22} '
           f'Q {x + w} {y} {x + w} {y + 22} V {y + 60} Z" fill="{t["head"]}"/>',
           text(x + 24, y + 39, "the bus", 24, t["headink"], 700),
           text(x + w - 24, y + 38, ".agentbus/bus.db", 18, t["headink"], 500, "end", MONO)]
    cards = [("goal", "auth on the new token API"),
             ("inboxes", "one per agent: post, inbox"),
             ("claims", "src/auth/ held by codex"),
             ("facts", "ctx set, ctx get")]
    pad, gap = 20, 16
    cw = (w - 2 * pad - gap) / 2
    ch = (h - 60 - 2 * pad - gap) / 2
    for i, (name, sub) in enumerate(cards):
        cx = x + pad + (i % 2) * (cw + gap)
        cy = y + 60 + pad + (i // 2) * (ch + gap)
        out.append(f'<rect x="{cx}" y="{cy}" width="{cw}" height="{ch}" rx="14" fill="{t["card"]}" '
                   f'stroke="{t["cardline"]}" stroke-width="2"/>')
        out.append(text(cx + 20, cy + 38, name, 21, t["ink"], 700))
        out.append(text(cx + 20, cy + 68, sub, 18, t["muted"]))
    return "".join(out)


def svg(t):
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
         f'role="img" aria-labelledby="title">',
         '<title id="title">How agents work together on agentbus</title>',
         '<defs>',
         f'<marker id="arrow" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="7" markerHeight="7" '
         f'orient="auto-start-reverse"><path d="M 1 1 L 11 6 L 1 11 Z" fill="{t["line"]}"/></marker>',
         f'<marker id="stop" viewBox="0 0 12 12" refX="6" refY="6" markerWidth="9" markerHeight="9" '
         f'orient="0"><path d="M 2 2 L 10 10 M 10 2 L 2 10" stroke="{t["bad"]}" stroke-width="2.6" '
         f'stroke-linecap="round"/></marker>',
         '</defs>',
         f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>']

    cx_claude = CLAUDE[0] + BOX_W / 2
    cx_codex = CODEX[0] + BOX_W / 2
    cx_tests = TESTS[0] + BOX_W / 2
    bx, by, bw, bh = BUS
    upper, lower = TOP + 34, TOP + 74          # two lanes between neighbouring agents

    # 2: claude hands off to codex (upper lane, left to right)
    o.append(arrow([(CLAUDE[0] + BOX_W, upper), (CODEX[0] - 4, upper)], t))
    # 5: codex posts done to claude (lower lane, right to left)
    o.append(arrow([(CODEX[0], lower), (CLAUDE[0] + BOX_W + 4, lower)], t))
    # 4: tests ask codex instead (upper lane, right to left)
    o.append(arrow([(TESTS[0], upper), (CODEX[0] + BOX_W + 4, upper)], t))
    # 5: codex answers tests (lower lane, left to right)
    o.append(arrow([(CODEX[0] + BOX_W, lower), (TESTS[0] - 4, lower)], t))

    # 3: codex claims src/auth/ (down into the bus), 5: releases it
    o.append(arrow([(cx_codex, TOP + BOX_H), (cx_codex, by - 4)], t))
    # 4: the tests subagent's claim is refused
    o.append(arrow([(TESTS[0] + 20, TOP + BOX_H), (TESTS[0] + 20, by - 16)], t, t["bad"],
                   dashed=True, marker="stop"))
    # 1: you set the goal (up), 6: you watch (down)
    ycx = YOU[0] + BOX_W / 2
    o.append(arrow([(ycx - 40, YOU[1]), (ycx - 40, by + bh + 4)], t))
    o.append(arrow([(ycx + 40, by + bh), (ycx + 40, YOU[1] - 4)], t, dashed=True))

    o.append(agent(CLAUDE, t))
    o.append(agent(CODEX, t))
    o.append(agent(TESTS, t))
    o.append(agent(YOU, t, t["you"]))
    o.append(bus(t))

    # Lane labels sit above the upper lane and below the lower lane, centred in each gap.
    gap1 = (CLAUDE[0] + BOX_W + CODEX[0]) / 2
    gap2 = (CODEX[0] + BOX_W + TESTS[0]) / 2
    o.append(label(gap1 - 70, upper - 16, 2, "hand off", t))
    o.append(label(gap1 - 70, lower + 40, 5, "done", t))
    o.append(label(gap2 - 70, upper - 16, 4, "ask codex", t))
    o.append(label(gap2 - 70, lower + 40, 5, "answer", t))

    o.append(label(cx_codex + 22, TOP + BOX_H + 62, 3, "claim src/auth/", t))
    o.append(label(cx_codex + 22, TOP + BOX_H + 120, 5, "release it", t))
    o.append(label(TESTS[0] + 42, TOP + BOX_H + 62, 4, "claim refused", t, sub="held by codex"))

    o.append(label(ycx - 62, by + bh + 74, 1, "set the goal", t, anchor="end"))
    o.append(label(ycx + 62, by + bh + 74, 6, "watch it live", t))

    # The arrows between agents are drawn direct for readability; say what really carries them.
    for i, line in enumerate(["Arrows between agents are", "messages: each post lands in",
                              "the reader's inbox on the bus."]):
        o.append(text(40, YOU[1] + 30 + i * 28, line, 18, t["muted"]))

    o.append('</svg>')
    return "".join(o)


if __name__ == "__main__":
    here = pathlib.Path(__file__).resolve().parent
    for name, t in THEMES.items():
        (here / f"hero-{name}.svg").write_text(svg(t) + "\n")
