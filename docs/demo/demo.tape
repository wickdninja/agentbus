# The README's demo. Do not run this file by hand: scripts/record_demo.sh builds the throwaway HOME and
# project it needs and sets DEMO_ATTACH. Everything on screen is the real tool in tmux; the script types the commands.
# The cursor is the background colour: tmux moves it through the watch pane on every redraw, and a recording shows that as a flash.
Output demo.gif
Output demo.mp4

Set Shell bash
Set FontFamily "Menlo,DejaVu Sans Mono,monospace"
Set FontSize 19
Set LineHeight 1.2
Set Width 1280
Set Height 720
Set Padding 8
Set Margin 0
Set Framerate 15
Set CursorBlink false
Set Theme { "name": "agentbus", "background": "#0d1117", "foreground": "#e6edf3", "cursor": "#0d1117", "cursorAccent": "#e6edf3", "selection": "#30363d", "black": "#484f58", "red": "#ff7b72", "green": "#3fb950", "yellow": "#d29922", "blue": "#58a6ff", "magenta": "#bc8cff", "cyan": "#39c5cf", "white": "#b1bac4", "brightBlack": "#6e7681", "brightRed": "#ffa198", "brightGreen": "#56d364", "brightYellow": "#e3b341", "brightBlue": "#79c0ff", "brightMagenta": "#d2a8ff", "brightCyan": "#56d4dd", "brightWhite": "#ffffff" }

Hide
Type `exec "$DEMO_ATTACH"`
Enter
Sleep 2s
Show

# The last thing the story prints, in claude's pane. watch draws the same message differently, so this cannot match early.
Wait+Screen@90s /codex -> claude \[done\]/
Sleep 4s
