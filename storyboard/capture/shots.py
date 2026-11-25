#!/usr/bin/env python3
"""Screenshot every W1 storyboard page: light and dark, desktop and phone (issue 89).

  python3 storyboard/capture/shots.py

Headless, through agent-browser (never a visible window). Writes storyboard/shots/<page>-<theme>-<device>.png
for every page that w1_pages.py lists, and exits non-zero if any of them is missing or empty afterwards, so a
skipped shot cannot go unnoticed. A shot waits until every drawn terminal has painted before it is taken.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SB = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from w1_pages import PAGES  # noqa: E402

OUT = os.path.join(SB, "shots")
DEVICES = (("desktop", 1280, 900), ("phone", 390, 844))
THEMES = ("light", "dark")
SESSION = "agentbus-storyboard-shots"

READY = ("(function(){var f=document.querySelectorAll('figure.term');"
         "return f.length>0&&document.querySelectorAll('figure.term .xterm-rows').length===f.length"
         "&&!document.querySelector('figure.term .missing')})()")


def ab(*args, check=True):
    p = subprocess.run(["agent-browser", "--session", SESSION, *args], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    if check and p.returncode:
        raise SystemExit(f"agent-browser {' '.join(args)}: {p.stdout}")
    return p.stdout


def main():
    os.makedirs(OUT, exist_ok=True)
    wanted = []
    try:
        for page, _ in PAGES:
            name = page[:-5]
            for dev, w, h in DEVICES:
                ab("set", "viewport", str(w), str(h))
                for theme in THEMES:
                    path = os.path.join(OUT, f"{name}-{theme}-{dev}.png")
                    wanted.append(path)
                    if os.path.exists(path):
                        os.remove(path)
                    url = "file://" + os.path.join(SB, "w1", page) + f"?theme={theme}"
                    ab("open", url)
                    for _ in range(40):  # up to 10 s for fonts and terminals
                        if "true" in ab("eval", READY, check=False):
                            break
                        ab("wait", "250")
                    ab("wait", "500")
                    ab("screenshot", "--full", path)
    finally:
        ab("close", check=False)
    bad = [p for p in wanted if not os.path.exists(p) or os.path.getsize(p) == 0]
    if bad:
        raise SystemExit("missing shots:\n" + "\n".join(bad))
    print(f"wrote {len(wanted)} shots to storyboard/shots/")


if __name__ == "__main__":
    main()
