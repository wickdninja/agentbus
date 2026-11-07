#!/usr/bin/env python3
"""Hooks for the ledger condition, the counterpart of the hooks `agentbus setup` installs (docs/evals/value-protocol.md, addenda).
Hooks are a harness feature, not the tool's, so the flat file gets them too, on the same events:

  SessionStart  how many entries COORDINATION.md holds, the entries addressed to you, and how many TODOs are open (only when any
                are, as the tool's own hook counts open todos)
  UserPromptSubmit  entries addressed to you that this session has not been told about (the bus's unread note at the prompt)
  PreToolUse    before an edit: a warning when someone else holds an open CLAIM on the path, once per path a nudge when the path has
                no claim at all, and new entries addressed to you, once each (the bus's unread note before an edit)

  python3 ledger_hook.py claude|codex EVENT     reads the hook payload on stdin; your name is $LEDGER_NAME

A hook never blocks and never writes the ledger. It prints the harness's additionalContext JSON, or nothing. Standard library only.
The parser here is also what the graders use to read a ledger, so the hook and the graders agree on what an entry is.
"""
import json
import os
import re
import sys
import tempfile

LEDGER = "COORDINATION.md"
# TIME NAME KIND[ to NAME| KEY]: TEXT   (a FACT names its key where a message names its recipient)
HEADER = re.compile(r"^(\d{1,2}:\d{2}(?::\d{2})?)\s+([A-Za-z0-9_.-]+)\s+(JOIN|CLAIM|RELEASE|QUESTION|ANSWER|HANDOFF|DONE|FACT|NOTE|TODO|DROPPED)"
                    r"(?:\s+to\s+([A-Za-z0-9_.-]+)|\s+([^:\s]+))?\s*:\s?(.*)$")
PATCH_MARKERS = ("*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: ")
MAX_SHOWN = 6


def parse(text):
    """[{"time", "name", "kind", "to", "key", "text"}] in file order. An entry is a header line plus every line under it up to the
    next header; blank lines separate entries and are dropped from the text. Lines before the first header are ignored."""
    entries = []
    for line in text.splitlines():
        m = HEADER.match(line.strip())
        if m:
            entries.append({"time": m.group(1), "name": m.group(2), "kind": m.group(3), "to": m.group(4), "key": m.group(5),
                            "text": m.group(6).strip()})
        elif entries and line.strip():
            entries[-1]["text"] += "\n" + line.rstrip()
    return entries


def facts(entries):
    """{KEY: value}: the latest FACT for each key wins."""
    out = {}
    for e in entries:
        if e["kind"] == "FACT" and e["key"]:
            out[e["key"]] = e["text"]
    return out


def open_todos(entries):
    """{ID: entry} for every TODO that no later DONE ID or DROPPED ID names. Any name may close one. A TODO with no ID can never be
    closed, so it stays open under its position in the file."""
    open_ = {}
    for i, e in enumerate(entries):
        if e["kind"] == "TODO":
            open_[e["key"] or "#%d" % i] = e
        elif e["kind"] in ("DONE", "DROPPED") and e["key"]:
            open_.pop(e["key"], None)
    return open_


def _paths(text):
    """The paths a CLAIM or RELEASE names: the text before any '(', split on commas, first word of each."""
    head = text.split("\n", 1)[0].split("(", 1)[0]
    return [part.split()[0].strip("`'\"") for part in head.split(",") if part.split()]


TAKEOVER = re.compile(r"\(from ([A-Za-z0-9_.-]+)")


def open_claims(entries):
    """{(name, path): why} for every claim whose holder has not released it since. A CLAIM that says `(from HOLDER)` takes the path
    over: the holder's claim on it ends there."""
    held = {}
    for e in entries:
        if e["kind"] == "CLAIM":
            why = e["text"].split("(", 1)[1].rsplit(")", 1)[0] if "(" in e["text"] else ""
            taken = TAKEOVER.search(e["text"].split("\n", 1)[0])
            for p in _paths(e["text"]):
                if taken:
                    held.pop((taken.group(1), p.rstrip("/") or p), None)
                held[(e["name"], p.rstrip("/") or p)] = why
        elif e["kind"] == "RELEASE":
            for p in _paths(e["text"]):
                held.pop((e["name"], p.rstrip("/") or p), None)
    return held


def covers(claim, path):
    claim, path = claim.rstrip("/"), path.rstrip("/")
    return path == claim or path.startswith(claim + "/")


def find_root(cwd):
    d = os.path.abspath(cwd)
    while True:
        if os.path.exists(os.path.join(d, LEDGER)):
            return d
        if os.path.dirname(d) == d:
            return None
        d = os.path.dirname(d)


def edit_paths(payload):
    """Paths an edit tool call is about to touch: file_path for Claude's tools, the patch's file markers for Codex's apply_patch."""
    tool_input = payload.get("tool_input") or {}
    paths = [tool_input[k] for k in ("file_path", "notebook_path", "path") if isinstance(tool_input.get(k), str)]
    command = tool_input.get("command")
    if isinstance(command, str) and "*** Begin Patch" in command:
        for line in command.splitlines():
            for marker in PATCH_MARKERS:
                if line.startswith(marker):
                    paths.append(line[len(marker):].strip())
    return paths


def relative(path, root, cwd):
    full = os.path.realpath(path if os.path.isabs(path) else os.path.join(cwd, path))
    rel = os.path.relpath(full, os.path.realpath(root))
    return None if rel.startswith("..") else rel


def nudged(session, path):
    """True the first time this session is nudged about this path, False after: state lives in TMPDIR, keyed by session."""
    state = os.path.join(tempfile.gettempdir(), "ledger-hook-%s" % re.sub(r"[^A-Za-z0-9_-]", "_", str(session))[:80])
    seen = open(state).read().splitlines() if os.path.exists(state) else []
    if path in seen:
        return False
    with open(state, "a") as f:
        f.write(path + "\n")
    return True


def _state(session, kind):
    return os.path.join(tempfile.gettempdir(), "ledger-hook-%s.%s" % (re.sub(r"[^A-Za-z0-9_-]", "_", str(session))[:80], kind))


def new_for(session, entries, name):
    """How many entries addressed to name this session has not been told about; afterwards they count as told. The file only grows,
    so a count is enough."""
    mine = sum(1 for e in entries if name and e["to"] == name)
    path = _state(session, "told")
    told = int(open(path).read() or 0) if os.path.exists(path) else 0
    with open(path, "w") as f:
        f.write(str(mine))
    return max(0, mine - told)


def context(event, payload, name):
    """The text this event shows the agent, or None."""
    cwd = payload.get("cwd") or os.getcwd()
    root = find_root(cwd)
    if event == "SessionStart":
        if root is None:
            return "ledger: there is no %s here yet. Create it with your first entry." % LEDGER
        entries = parse(open(os.path.join(root, LEDGER), errors="replace").read())
        mine = [e for e in entries if name and e["to"] == name]
        todos = len(open_todos(entries))
        clause = ", %d open TODO%s" % (todos, "" if todos == 1 else "s") if todos else ""
        lines = ["ledger: %s has %d entries, %d addressed to %s%s." % (LEDGER, len(entries), len(mine), name or "you", clause)]
        for e in mine[-MAX_SHOWN:]:
            lines.append("  %s %s %s to %s: %s" % (e["time"], e["name"], e["kind"], e["to"], e["text"].split("\n", 1)[0][:200]))
        lines.append("Read the whole file with: cat %s" % LEDGER)
        new_for(payload.get("session_id"), entries, name)   # said here: the prompt and edit notes do not say these again
        return "\n".join(lines)
    if event == "UserPromptSubmit" and root is not None:
        n = new_for(payload.get("session_id"), parse(open(os.path.join(root, LEDGER), errors="replace").read()), name)
        if n:
            return "ledger: %d %s addressed to %s since you last read. Read them with: cat %s" % (n, "entry" if n == 1 else "entries", name, LEDGER)
        return None
    if event == "PreToolUse" and root is not None:
        entries = parse(open(os.path.join(root, LEDGER), errors="replace").read())
        held = open_claims(entries)
        notes, project = [], False
        for raw in edit_paths(payload):
            rel = relative(raw, root, cwd)
            if rel is None or os.path.basename(rel) == LEDGER:
                continue
            project = True
            others = [(n, p, why) for (n, p), why in held.items() if n != name and covers(p, rel)]
            if others:
                n, p, why = others[0]
                notes.append("ledger: %s is claimed by %s in %s%s. Claims are advisory; ask the holder or work elsewhere."
                             % (rel, n, LEDGER, " (%s)" % why if why else ""))
            elif not any(n == name and covers(p, rel) for (n, p) in held) and nudged(payload.get("session_id"), rel):
                notes.append("ledger: %s has no CLAIM in %s. If you are editing it, append: CLAIM: %s (WHY)" % (rel, LEDGER, rel))
        n = new_for(payload.get("session_id"), entries, name) if project else 0
        if n:
            notes.append("ledger: %d new %s addressed to %s. Read with: cat %s" % (n, "entry" if n == 1 else "entries", name, LEDGER))
        return "\n".join(notes) or None
    return None


def main(argv):
    event = argv[1]   # argv[0] names the harness; both get the same text
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    text = context(event, payload if isinstance(payload, dict) else {}, os.environ.get("LEDGER_NAME", ""))
    if text:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
