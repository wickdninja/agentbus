# Dogfood: building agentbus with agentbus

Maintainer notes. Lanes that work on this repo coordinate on its own bus.

- Friction posts start with a key: `[join-name] what happened`. Check `agentbus read --topic friction` first; if the key is there, post only `+1 [join-name]`.
- At each wave's close, `python3 scripts/wave_review.py --coordinator NAME` counts messages, answers, claim refusals, the coordinator's unread and friction keys. It only reads: no command runs as any agent. `--append FILE` adds one summary line.
- Any friction key at 3 or more gets an issue.
