"""Turn an agent harness's JSON event stream into one ordered list of tool events.

capture_events(lines, agent, harness) takes the harness's raw lines, each wrapped by the capture step as
{"ts": seconds, "line": "<raw JSON line>"}, and returns events in the order the agent made the calls:

  {"ts": float, "agent": "A", "kind": "bus" | "edit" | "other", "tool": "Bash",
   "verb": "inbox" | "claim" | ... (bus), "arg": first argument of the verb or None, "path": str | None (edit),
   "ok": bool | None, "text": first 400 characters of the tool's result}

kind "bus" is a shell command that runs agentbus; "edit" is a file edit tool call, or a shell command that
writes a file (redirection, tee, sed -i, cp/mv/install/rsync/ln, touch, a python open(..., "w")). `ok` is False when the result shows a claim conflict or an
error. Formats parsed (UNVERIFIED against a live run until the baseline eval, see docs/evals/README.md):
Claude Code `--output-format stream-json --verbose` (assistant tool_use blocks, user tool_result blocks)
and `codex exec --json` (command_execution and file_change items).
"""
import json
import re
import shlex

EDIT_TOOLS = {"Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path"}
CONFLICT = re.compile(r"claim_conflict|is claimed by|overlaps .*claimed by|Do not edit it yet")
GLOBAL_OPTS = {"--as": 1, "--up": 1, "--json": 0}
VALUE_OPTS = {"--limit", "--purpose", "--to", "--kind", "--topic", "--reply-to", "--request-id", "--ttl-min", "--since",
              "--tool", "--model", "--role", "--interval"}
BUS_WORD = re.compile(r"(?:^|[\s;&|(`'\"])(?:\S*/)?agentbus(?=[\s'\"]|$)")


def bus_commands_at(command):
    """[(position, verb, first argument or None)] for every agentbus invocation in a shell command line."""
    found = []
    for m in BUS_WORD.finditer(command):
        rest = command[m.end():]
        rest = re.split(r"&&|\|\||;|\||\n", rest, maxsplit=1)[0].rstrip("'\" ")
        try:
            words = shlex.split(rest, posix=True)
        except ValueError:
            words = rest.split()
        i = 0
        while i < len(words) and words[i] in GLOBAL_OPTS:
            i += 1 + GLOBAL_OPTS[words[i]]
        if i < len(words) and re.fullmatch(r"[a-z][a-z-]*", words[i]):
            arg, j = None, i + 1
            while j < len(words):
                if words[j] in VALUE_OPTS:
                    j += 2
                elif words[j].startswith("-"):
                    j += 1
                else:
                    arg = words[j]
                    break
            found.append((m.start(), words[i], arg))
    return found


def bus_commands(command):
    """[(verb, first argument or None)] for every agentbus invocation in a shell command line."""
    return [(v, a) for _, v, a in bus_commands_at(command)]


COPY_LIKE = {"cp", "mv", "install", "rsync", "ln"}
REMOVE_LIKE = {"rm", "rmdir", "unlink", "touch", "truncate", "mkdir"}
PREFIX_WORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "time", "nohup", "command", "exec", "builtin",
                "nice", "ionice", "stdbuf", "env", "sudo", "doas"}
# Options that take their value as the next word (so the value is not mistaken for a path).
PREFIX_VALUE_OPTS = {"sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U"}, "doas": {"-u"}, "nice": {"-n"}, "ionice": {"-c", "-n"},
                     "env": {"-u", "-C", "-S"}, "time": {"-f", "-o"}, "stdbuf": set()}
CMD_VALUE_OPTS = {"cp": {"-S", "--suffix"}, "mv": {"-S", "--suffix"}, "install": {"-m", "-o", "-g", "-S", "-b", "--mode", "--owner", "--group"},
                  "rsync": {"-e", "--exclude", "--include", "--filter", "--rsh", "--exclude-from", "--include-from", "--chmod", "--chown"},
                  "ln": {"-S"}}
OPEN_WRITE = re.compile(r"""open\(\s*r?['"]([^'"]+)['"]\s*,\s*['"][wax]""")
PATH_WRITE = re.compile(r"""Path\(\s*r?['"]([^'"]+)['"]\s*\)\s*\.\s*write_(?:text|bytes)\(""")
REDIRECT = re.compile(r"(?:\d*>>?&?\d*-?|&>>?|<<?<?)\s*[^\s;&|()]*")
HEREDOC = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n.*?\n\s*\1\b", re.S)


def _strip_for_parsing(command):
    """The command with heredoc bodies and redirections removed, so `cp a b 2>&1` parses as cp a b."""
    command = HEREDOC.sub(" ", command)
    return REDIRECT.sub(" ", command)


def _simple_commands(command):
    """[(position, [words])] for each simple command: split on ; & && || | newlines, ( ) { }, with redirections gone and
    leading shell keywords and prefix commands (sudo -u x, time, env VAR=1, nohup, command, if ... then) dropped."""
    out = []
    cleaned = _strip_for_parsing(command)
    for m in re.finditer(r"[^;&|()\n{}]+", cleaned):
        try:
            words = shlex.split(m.group(0), posix=True)
        except ValueError:
            words = m.group(0).split()
        while words:
            w = words[0]
            if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=\S*", w):
                words = words[1:]
            elif w in PREFIX_WORDS:
                words = words[1:]
                while words and words[0].startswith("-"):
                    opt = words[0]
                    words = words[1:]
                    if opt in PREFIX_VALUE_OPTS.get(w, set()) and words:
                        words = words[1:]
                while w == "env" and words and re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=\S*", words[0]):
                    words = words[1:]
            else:
                break
        if words:
            out.append((m.start(), words))
    return out


def _segment_writes(command):
    """[(position, path)] written by cp, mv, install, rsync, ln (the destination; for mv the sources too, since moving a
    file out of a path changes it), rm, touch, truncate and mkdir, in each simple command of the line."""
    found = []
    for pos, words in _simple_commands(command):
        name = words[0].rsplit("/", 1)[-1]
        if name not in COPY_LIKE and name not in REMOVE_LIKE:
            continue
        value_opts = CMD_VALUE_OPTS.get(name, set())
        args, target_dir, i = [], None, 1
        while i < len(words):
            w = words[i]
            if w.startswith("--target-directory="):
                target_dir = w.split("=", 1)[1]
            elif w in ("-t", "--target-directory") and i + 1 < len(words):
                target_dir, i = words[i + 1], i + 1
            elif w in value_opts and i + 1 < len(words):
                i += 1
            elif w == "--":
                args += words[i + 1:]
                break
            elif not w.startswith("-"):
                args.append(w)
            i += 1
        if name in REMOVE_LIKE:
            found += [(pos, a) for a in args]
        elif target_dir:
            found.append((pos, target_dir))
            if name == "mv":
                found += [(pos, a) for a in args]
        elif len(args) >= 2:
            found.append((pos, args[-1]))
            if name == "mv":
                found += [(pos, a) for a in args[:-1]]
    return found


def written_paths_at(command):
    """[(position, path)] for every file a shell command writes: redirection, tee, sed -i, cp/mv/install/rsync/ln,
    touch/truncate, and a python one-liner or heredoc that opens a file for writing."""
    paths = []
    for m in re.finditer(r"(?<![<>&0-9])>>?\s*([^\s;&|<>]+)", command):
        p = m.group(1).strip("'\"")
        if p not in ("/dev/null", "/dev/stderr", "/dev/stdout") and not p.startswith("&"):
            paths.append((m.start(), p))
    for m in re.finditer(r"\btee\s+(?:-a\s+)?([^\s;&|]+)", command):
        paths.append((m.start(), m.group(1).strip("'\"")))
    for m in re.finditer(r"\bsed\s+(?:-[a-zA-Z]*i|-i)", command):
        tail = re.findall(r"[^\s;&|'\"]+\.[A-Za-z]+\b", command[m.start():])
        if tail:
            paths.append((m.start(), tail[-1]))
    paths += _segment_writes(command)
    for rx in (OPEN_WRITE, PATH_WRITE):
        paths += [(m.start(), m.group(1)) for m in rx.finditer(command)]
    return paths


def written_paths(command):
    return [p for _, p in written_paths_at(command)]


def _shell_events(command, ts, agent, tool):
    """Every agentbus call and every file write in one shell command, in the order they appear in it. A call
    that runs agentbus and also writes a file records both: a write must never hide behind a bus verb."""
    found = [(pos, "bus", verb, arg) for pos, verb, arg in bus_commands_at(command)]
    found += [(pos, "edit", None, path) for pos, path in written_paths_at(command)]
    events = []
    for _, kind, verb, arg in sorted(found, key=lambda x: x[0]):
        events.append({"ts": ts, "agent": agent, "kind": kind, "tool": tool, "verb": verb,
                       "arg": arg if kind == "bus" else None, "path": arg if kind == "edit" else None,
                       "ok": None, "text": ""})
    if not events:
        events.append({"ts": ts, "agent": agent, "kind": "other", "tool": tool, "verb": None, "arg": None,
                       "path": None, "ok": None, "text": ""})
    return events


def _result(events, text, is_error):
    text = (text or "")[:400]
    bad = bool(is_error) or bool(CONFLICT.search(text))
    for e in events:
        e["text"] = text
        e["ok"] = not bad if e["kind"] == "bus" else (not bool(is_error))


def _flatten(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def claude_events(lines, agent):
    events, by_id, final = [], {}, ""
    for wrapped in lines:
        try:
            ts, obj = wrapped["ts"], json.loads(wrapped["line"])
        except (KeyError, ValueError, TypeError):
            continue
        kind = obj.get("type")
        content = (obj.get("message") or {}).get("content")
        if kind == "assistant" and isinstance(content, list):
            for block in content:
                if block.get("type") == "tool_use":
                    name, inp = block.get("name", ""), block.get("input") or {}
                    if name in EDIT_TOOLS:
                        made = [{"ts": ts, "agent": agent, "kind": "edit", "tool": name, "verb": None, "arg": None,
                                 "path": inp.get(EDIT_TOOLS[name]), "ok": None, "text": ""}]
                    elif name == "Bash":
                        made = _shell_events(inp.get("command", ""), ts, agent, name)
                    else:
                        made = [{"ts": ts, "agent": agent, "kind": "other", "tool": name, "verb": None, "arg": None,
                                 "path": None, "ok": None, "text": ""}]
                    by_id[block.get("id")] = made
                    events += made
                elif block.get("type") == "text":
                    final = block.get("text", final)
        elif kind == "user" and isinstance(content, list):
            for block in content:
                if block.get("type") == "tool_result" and block.get("tool_use_id") in by_id:
                    _result(by_id[block["tool_use_id"]], _flatten(block.get("content")), block.get("is_error"))
        elif kind == "result" and isinstance(obj.get("result"), str):
            final = obj["result"]
    return events, final


def codex_events(lines, agent):
    events, open_items, final = [], {}, ""
    for wrapped in lines:
        try:
            ts, obj = wrapped["ts"], json.loads(wrapped["line"])
        except (KeyError, ValueError, TypeError):
            continue
        etype, item = obj.get("type", ""), obj.get("item") or {}
        if not etype.startswith("item."):
            continue
        itype, iid = item.get("type"), item.get("id")
        if itype == "command_execution":
            command = item.get("command", "")
            if isinstance(command, list):
                command = " ".join(command)
            if iid not in open_items:
                open_items[iid] = _shell_events(command, ts, agent, "Bash")
                events += open_items[iid]
            if etype == "item.completed":
                failed = item.get("exit_code") not in (0, None) or item.get("status") == "failed"
                _result(open_items[iid], item.get("aggregated_output", ""), failed)
        elif itype == "file_change" and etype == "item.completed":
            for ch in item.get("changes") or []:
                events.append({"ts": ts, "agent": agent, "kind": "edit", "tool": "file_change", "verb": None,
                               "arg": None, "path": ch.get("path"), "ok": item.get("status") != "failed", "text": ""})
        elif itype == "agent_message" and etype == "item.completed":
            final = item.get("text", final)
    return events, final


def capture_events(lines, agent, harness):
    return {"claude": claude_events, "codex": codex_events}[harness](lines, agent)
