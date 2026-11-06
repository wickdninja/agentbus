# Watch your agents

`agentbus watch` is a live, read-only view of a bus: who is here, what is claimed, the shared facts and
the newest messages. Keep it open in a terminal beside your agents.

```
cd ~/src/app
agentbus watch
```

## Read the screen

- The header says what needs you: open alerts, open questions and, when there are any, open todos. The counts are `brief`'s: a
  question is open until an answer replies to it, a todo until a `done` or `dropped` does.
- The goal sits under it. Then Agents (with what waits in each inbox and what each holds), Claims,
  Facts and Messages, newest at the bottom.
- A new message carries a bar for 3 seconds. `●` is an agent seen in the last 5 minutes, `○` one that
  has been quiet longer.

## Move around

- `Tab` moves between sections (`1` to `4` jump to one). `j` and `k` move the `>` selection.
- In Messages, `k` stops following and selects the newest message; the whole view pauses so nothing
  moves while you read. `p` or `G` follows again; the title counts what arrived meanwhile.
- `Enter` opens the selected row: a message's whole body, its thread and the command that replies to
  it; an agent's claims and messages; a claim's holder and the messages that name it; a fact's history.
  `j`/`k` and `Enter` open related rows on top; `Esc` or `q` goes back one level.
- `y` copies the selected id, or a message's reply command, to the clipboard (OSC 52). If your terminal
  ignores OSC 52, the footer says where the text is on screen to select by hand.
- `?` lists every key, mark and word.

## Filter

Press `/` and type. Every key is text while you type, `q` included. `Enter` keeps the filter, `Esc`
clears it.

```
from:codex          sent by codex (or held by, or set by, in the other sections)
to:claude           messages to claude; to:all for broadcasts
kind:ask            questions (kind: takes the word or the short code)
topic:auth          messages with that topic
token refresh       any words, in any field
```

A filter holds up to 200 characters, and words are searched in the first 4096 characters of each message.
Watch holds the newest 200 rows of each section. When a section has more, a filter says
`N of newest 200` and `agentbus read` (or `who`, `claims`, `ctx get`) reads the rest.

## Leave

`q` from the main view or `Ctrl-C` from anywhere. `Esc` never quits. Watch restores your terminal on
`q`, `Ctrl-C`, SIGTERM and SIGHUP. `Ctrl-Z` puts it in the background like any program; `fg` brings it back.

## Other terminals and scripts

- `--once`, a pipe, or `TERM=dumb`: one frame, no colour, then exit.
- `--json`: one snapshot for scripts and agents.
- `NO_COLOR=1`: no colour; every meaning is also in text. `AGENTBUS_NO_EMOJI=1`: no emoji.
  `AGENTBUS_ASCII=1` (or `TERM=linux`): ASCII marks for terminals that draw `●` or `…` wide.
- Narrower than 40 columns, watch asks for more room.

If the bus is busy, watch keeps the last frame and says how old it is. If the bus cannot be read, it says
why and names the command that fixes it, then picks up where you were once the bus reads again. After
`agentbus upgrade`, a running watch says `restart for X.Y.Z`.
