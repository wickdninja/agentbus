#!/usr/bin/env python3
"""Write the W1 storyboard pages (storyboard/w1/*.html) from the copy below.

  python3 storyboard/capture/w1.py && python3 storyboard/capture/w1_pages.py

The pages share one header and draw their terminals with storyboard/assets/term.js from
storyboard/frames/w1.js. The copy lives here so every page keeps the same words for the same thing.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "w1")

PAGES = [
    ("index.html", "Overview"),
    ("nothing.html", "Nothing needs you"),
    ("needs-you.html", "Two need you"),
    ("many.html", "Many"),
    ("narrow.html", "80 columns"),
    ("other-buses.html", "Other buses"),
    ("reply.html", "Reply"),
    ("themes.html", "Light and dark"),
]

HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,700&family=Inter:wght@400;600&family=JetBrains+Mono:wght@400;700&display=swap">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css">
<link rel="stylesheet" href="../assets/sb.css">
<script>
  window.SB_NEW = "W1";
  window.SB_LABELS = {{ captured: "today, drawn by the real watch", mocked: "W1 design, drawn with watch's own code" }};
</script>
</head>
<body>
<header class="top">
  <a class="brand" href="index.html">agentbus · W1</a>
  <nav class="nav">
{nav}
  </nav>
  <div class="themes" role="group" aria-label="Theme">
    <button type="button" data-theme-set="auto">Auto</button>
    <button type="button" data-theme-set="light">Light</button>
    <button type="button" data-theme-set="dark">Dark</button>
  </div>
</header>
<main>
"""

FOOT = """</main>
<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-unicode11@0.8.0/lib/addon-unicode11.js"></script>
<script src="../frames/w1.js"></script>
<script src="../assets/term.js"></script>
</body>
</html>
"""


def nav(current):
    return "\n".join(f'    <a href="{f}"' + (' aria-current="page"' if f == current else "") + f">{name}</a>"
                     for f, name in PAGES)


def term(frame, title="", compare=False, caption="", theme=""):
    attrs = f'data-compare="captured:{frame},mocked:{frame}"' if compare else f'data-set="mocked" data-frame="{frame}"'
    if title:
        attrs += f' data-title="{title}"'
    if caption:
        attrs += f' data-caption="{caption}"'
    if theme:
        attrs += f' data-term-theme="{theme}"'
    return f'<figure class="term" {attrs}></figure>'


def rules(rows):
    return '<div class="rules">' + "".join(f"<div><b>{k}</b><span>{v}</span></div>" for k, v in rows) + "</div>"


def lede(h1, p):
    return f'<div class="lede">\n  <h1>{h1}</h1>\n  <p>{p}</p>\n</div>\n'


def frame(n, h2, p, body):
    return f'<section class="frame">\n  <h2><span class="n">{n}</span>{h2}</h2>\n  <p>{p}</p>\n  {body}\n</section>\n'


BODY = {}

BODY["index.html"] = lede(
    "Watch opens on what needs you",
    "Today watch shows everything at once, and a question for you looks like every other line. With W1 it starts "
    "with the few things only you can settle, then who is working, then everything else.") + """
<section class="frame">
  <h2>The screens</h2>
  <div class="toc"><section><ol>
    <li><a href="nothing.html"><span class="n">1</span><span><b>Nothing needs you</b><em>One plain line, then who is working.</em></span></a></li>
    <li><a href="needs-you.html"><span class="n">2</span><span><b>Two things need you</b><em>A question and a handoff, each with its age, who sent it and a key.</em></span></a></li>
    <li><a href="many.html"><span class="n">3</span><span><b>Many things need you</b><em>The four that have waited longest, and a line for the rest.</em></span></a></li>
    <li><a href="narrow.html"><span class="n">4</span><span><b>A narrow terminal</b><em>The same screens at 80 columns.</em></span></a></li>
  </ol></section><section><ol>
    <li><a href="other-buses.html"><span class="n">5</span><span><b>Other buses</b><em>Work waiting in another folder, in one line.</em></span></a></li>
    <li><a href="reply.html"><span class="n">6</span><span><b>You press 1</b><em>What is copied, and what the screen says.</em></span></a></li>
    <li><a href="themes.html"><span class="n">7</span><span><b>Light and dark terminals</b><em>The same screen in both.</em></span></a></li>
  </ol></section></div>
</section>

<section class="frame">
  <h2>What counts as needing you</h2>
  <p>Two kinds of message, and only when they are sent to you by name.</p>
  """ + rules([
    ("A question", "Needs you until you answer it."),
    ("A handoff", "Needs you until you reply to it, with anything."),
    ("Order", "The one that has waited longest comes first."),
    ("Working now", "Every agent holding files right now, with what it is doing. This takes the place of the Agents and Claims lists; both are one Tab away."),
]) + """
</section>

<section class="frame">
  <h2>Turn it on</h2>
  <p>Watch needs to know which name is yours. Put this in your shell profile once:</p>
  <div class="context">export AGENTBUS_OWNER=nate</div>
  <p style="margin-top:18px">Your agents already send to you by this name. Without it, watch looks as it does today, with one line at the top saying how to turn this on.</p>
</section>

<section class="frame">
  <h2>How we will know it works</h2>
  <p>Two numbers, read from the bus on both machines, before and after W1 ships.</p>
  """ + rules([
    ("Time to your answer", "The middle value, in minutes, from a question sent to you until your answer. Lower is better."),
    ("Left waiting", "How many questions and handoffs to you waited more than an hour without a reply, per day. Lower is better."),
    ("And we ask you", "Once, in the next cycle: does watch show you what you need first?"),
]) + """
</section>
"""

BODY["nothing.html"] = lede(
    "Nothing needs you",
    "When nothing is waiting for you, watch says so in one line and moves straight on to the work.") + frame(
    "1", "Nothing needs you. 3 agents working.",
    "You answered both earlier. Switch between Today and W1: today you scan four lists to learn that nothing is "
    "waiting; in W1 the first line tells you.",
    '<div class="grid pair">' + term("calm-100", compare=True) + term("calm-80", title="80 columns", compare=True) + "</div>") + \
    frame("", "What the line counts", "Working means holding files right now. An agent that is around but holds nothing is not counted, and you are never counted.",
          rules([("Nothing needs you", "No question or handoff to you is waiting."),
                 ("N agents working", "Agents holding files right now, not you.")]))

BODY["needs-you.html"] = lede(
    "Two things need you",
    "A question from tests and a handoff from worker. Each shows how long it has waited, who sent it, its first "
    "line, and the key that copies your reply.") + frame(
    "2", "A question and a handoff",
    "Switch to Today to compare: today the question is message #4 in the list, the same size as everything around it.",
    term("needs-100", compare=True)) + frame(
    "", "How each line reads", "From left to right.",
    rules([("1", "The key. Press it to copy the reply for this one."),
           ("tests asks", "Who sent it, in that agent's colour, and what it wants: asks, or hands off."),
           ("Should an expired token…", "The first line of the message. Enter opens the whole thing."),
           ("12m", "How long it has waited. Bold once it has waited an hour."),
           ("waiting longest 12m", "The age of the oldest one, on the title line.")]))

BODY["many.html"] = lede(
    "Many things need you",
    "Nine are waiting, the oldest three hours. The four that have waited longest show; one line counts the rest.") + frame(
    "3", "The longest waits first",
    "The rest are a Tab away. Today all nine sit in the message list among the agents' own talk.",
    term("many-100", compare=True)) + frame(
    "", "The rules", "",
    rules([("Shown", "The four that have waited longest, each with a key, 1 to 4."),
           ("The rest", "One line: how many more are waiting. Tab moves to Needs you, then j and k reach every one."),
           ("Five or fewer", "All of them show; there is no extra line for one more."),
           ("Bold age", "Anything that has waited an hour or more.")]))

BODY["narrow.html"] = lede(
    "A narrow terminal",
    "At 80 columns every line keeps its key, sender and age; the message is cut to fit, and Enter opens it whole.") + frame(
    "4", "Two need you, at 80 columns", "", term("needs-80", title="80 columns", compare=True)) + frame(
    "", "Many, at 80 columns", "", term("many-80", title="80 columns", compare=True))

BODY["other-buses.html"] = lede(
    "Other buses",
    "Work in another folder can be waiting for you too. Watch adds one line under your list, and the count in the top bar.") + frame(
    "5", "Two other buses wait for you", "The hub has one thing for you and kidmath has two. The count in the top bar says 3 elsewhere.",
    term("others-100")) + frame(
    "", "Nothing here, one elsewhere", "Nothing waits in this folder, so the first line says so; the next says where to look.",
    '<div class="grid pair">' + term("calm-others-100") + term("others-80", title="80 columns") + "</div>") + frame(
    "", "The rules", "",
    rules([("Which buses", "The ones agentbus already remembers on this machine, the same list agentbus update uses."),
           ("What it says", "Each folder and how many things wait there for you. Too long for the line: just the totals."),
           ("To answer them", "Open watch in that folder.")]))

BODY["reply.html"] = lede(
    "You press 1",
    "Watch copies the reply command for the question, shows exactly what it copied under that line, and says what to do next.") + frame(
    "6", "Copied", "The command answers message #4 as you. Paste it, type your answer between the quotes, press Enter.",
    '<div class="grid pair">' + term("copied-100") + term("copied-80", title="80 columns") + "</div>") + frame(
    "", "What is copied", "For the question from tests:",
    '<div class="context">agentbus --as nate post --to tests --reply-to 4 --kind answer "..."</div>') + frame(
    "", "The rules", "",
    rules([("A question", "The copied command answers it, so it leaves your list once you send it."),
           ("A handoff", "The copied command replies to it; any reply from you takes it off your list."),
           ("How long", "The copied line stays until the next key you press."),
           ("If paste fails", "The command is on screen, so you can select it by hand.")]))

BODY["themes.html"] = lede(
    "Light and dark terminals",
    "Watch uses your terminal's own colours, so it follows whatever theme you run. Here is the same screen in both.") + frame(
    "7", "Two need you, light and dark", "Yellow is the one accent: the top bar, the Needs you title and its keys. Agents keep their own colours. Green appears only on \"copied\".",
    '<div class="grid two">' + term("needs-100", title="light terminal", theme="light") + term("needs-100", title="dark terminal", theme="dark") + "</div>") + frame(
    "", "Copied, light and dark", "",
    '<div class="grid two">' + term("copied-80", title="light terminal", theme="light") + term("copied-80", title="dark terminal", theme="dark") + "</div>")

TITLES = {"index.html": "Watch W1", "nothing.html": "Nothing needs you", "needs-you.html": "Two need you",
          "many.html": "Many need you", "narrow.html": "Narrow terminal", "other-buses.html": "Other buses",
          "reply.html": "Reply copied", "themes.html": "Terminal themes"}


def main():
    os.makedirs(OUT, exist_ok=True)
    for f, _ in PAGES:
        with open(os.path.join(OUT, f), "w") as fh:
            fh.write(HEAD.format(title=TITLES[f], nav=nav(f)) + BODY[f] + FOOT)
    print(f"wrote {len(PAGES)} pages to storyboard/w1/")


if __name__ == "__main__":
    main()
