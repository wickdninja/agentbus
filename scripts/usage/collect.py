#!/usr/bin/env python3
"""Deterministic, read-only agentbus usage collection (Python 3.9+, stdlib only).

Example: collect.py --cycle 1 --bus-root ~/src --work-pattern '*src/client*'
Every root flag is repeatable and REPLACES that source's defaults. Missing roots
are empty populations. --work-pattern is a case-sensitive fnmatch rule on cwd
(or the encoded Claude project directory when cwd is absent); all else is personal.
--brain-name explicitly identifies coordinators, and is never exported.
--exclude-pattern (fnmatch on a transcript's file path or any cwd it records) and
--exclude-entrypoint (Claude entrypoint) drop scripted sessions from every metric;
sources.excluded_sessions counts them. Cycle 0 used two populations:
  Claude transcripts report (trial cohort out): --exclude-pattern '*/-*value-run*'
    '*/-*axtrial*' '*/-*hauntd-lab*' '*/-private-var-folders-*' '*/never-lost/ax-trial*'
  hooks report (eval out): --exclude-entrypoint sdk-cli --exclude-pattern
    '/private/var/folders/*' '/var/folders/*' '/tmp/*' '/private/tmp/*'
Hooks are Claude Code hook records only; the codex-lane "## Agentbus" brief is
prompt text. Stop runs and wall time come from stop_hook_summary when present;
Stop timeouts always come from hook_cancelled. An own-claim warning is a held
warning whose edited file an earlier claim attempt by this session covers, refused
or not.

Windows are inclusive UTC epoch seconds (ISO 8601 is also accepted on the CLI).
Omitted bounds come from observed activity, never the clock. Undated events are
included only without explicit bounds. Snapshot claims/cursors are current state,
not historical reconstruction. No release population can be inferred reliably.

Ported from cycle 0: quote/heredoc/alias-aware invocation parsing; text failure
rules and verb attribution; Claude tool_use/result matching; Codex completed
CommandExecution extraction; nearest-rank p90 and median p50; hook repetition
against the preceding injection of the same type, and action within ten tools
before the next typed prompt (orientation may cross one prompt).
Output sizes belong only to single-invocation shell calls; chained commands and
filters can affect the observed output. Tokens are estimates (UTF-8 bytes / 4).
Hook action is temporal association, not a causal claim. Handoff pickup is an
explicit reply by its recipient; cursor coverage is reported separately because
reading is not proof of acting. Answers must link to a directed question and come
from its recipient. Identity reuse uses observed names across distinct sessions.

The exact schema is schema(); validate_cycle rejects missing/extra keys, strings,
containers at numeric leaves, booleans and nonfinite numbers. Unknown verbs/events
are counted in fixed buckets. Source text never becomes a public key or value.
Unavailable metrics use fixed reason keys: historical_roster (never-on-roster
cannot be proved from today's roster), historical_claims (reused names holding
old claims cannot be reconstructed after claims are released or replaced),
historical_worktrees (join logs normally omit cwd; worktree share is available
only where historical cwd metadata exists, with a classified denominator),
human_review (real collision vs false positive), release_metadata, annotations
(cycle cost/findings/reversals), tokenizer (exact tokens/cost), unobserved_runs
(hooks without recorded events), reference_data (cycle-0 1% gate needs raw corpus
and baseline), and brain_configuration (no --brain-name). Numeric zero with a
zero denominator is not evidence of a measured zero rate.
"""

import argparse
import copy
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import sqlite3
import statistics
import sys
from datetime import datetime, timezone
from urllib.parse import quote


KNOWN = tuple("join inbox brief post claim release read wait ctx goal status watch leave claims who log init setup doctor skill help upgrade buses schema update hooks hook demo completion".split())
VERBS = KNOWN + ("help_flag", "version_flag", "no_verb", "dynamic", "unknown")
EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "other")
KINDS = ("orientation", "unread", "no_claim", "held_claim", "other")
RULES = (
    ("claim_conflict", r"is claimed by|already claimed|held by \S+ until", "claim"),
    ("name_active", r"may be another live session|is in use by a live session|looks live", "join"),
    ("wait_timeout", r"no unread messages for \S+ after", "wait"),
    ("not_held", r"you do not hold|not held by|is not claimed", "release"),
    ("bad_kind", r"kind must be one of|unknown kind", "post"),
    ("as_after_verb", r"unrecognized arguments: --as\b", None),
    ("positional_name", r"unrecognized arguments: (claude|lane|codex|me-|rosstech|offload|src-|alice|bob|td-)[\w-]*\s*($|\(|\.)", None),
    ("unknown_flag", r"unrecognized arguments: -|Did you mean --", None),
    ("extra_args", r"unrecognized arguments:", None),
    ("unknown_command", r"unknown command|argument cmd: invalid choice|invalid choice:", None),
    ("missing_arg", r"the following arguments are required|needs a resource|empty message|nothing to post", None),
    ("bad_value", r"must be at least|must be between|invalid int|invalid value|not a valid", None),
    ("no_identity", r"say who you are|no identity|needs --as", None),
    ("not_on_roster", r"is not on the roster(?!; the message waits)", None),
    ("abs_path", r"bus-relative path", "claim"),
    ("no_message", r"no message #?\d+|no such message", None),
    ("no_bus", r"no bus here|no bus found|no project\. Run inside", None),
    ("db_mismatch", r"AGENTBUS_DB names", None),
    ("schema_newer", r"bus is newer than this copy|schema_newer", None),
    ("refused_path", r"refusing .*(symlink|not owned|unsafe)|refused \d+ file", None),
    ("busy_locked", r'database is locked|bus is busy|"busy"', None),
    ("stdout_closed", r"reader closed stdout", None),
    ("interrupted", r"interrupted before the command finished", None),
    ("internal", r"Traceback \(most recent call last\)|internal error", None),
)
FAILURES = tuple(r[0] for r in RULES) + ("other_error",)
NOTICE = re.compile(r"the message waits for that name|^agentbus: (note|tip|hint|warning:)|nothing to release|already (joined|on the roster)|left the bus|you are already", re.I)
DIAG = re.compile(r'^(?:STDERR: )?(agentbus(?: [a-z]+)?: .*|usage: agentbus.*|\{"error":\s*\{.*|error: unrecognized arguments.*|Traceback \(most recent call last\).*)$')
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
FUNC = re.compile(r"(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{([^}]*)\}")
PREFIX = set("then do else elif { ( ! time command exec sudo nohup if while until xargs builtin noglob".split())
GLOBAL_ARGS = {"--as", "--up", "--db", "--project"}
PYTHON = re.compile(r"^(?:.*/)?python3?(?:\.\d+)?$")
INTERPRETER = re.compile(r"^(?:.*/)?(?:python3?(?:\.\d+)?|node|ruby|perl)$")


def zeros(keys):
    return dict.fromkeys(keys, 0)


def schema():
    """A closed, position-specific allowlist; never derived from input data."""
    hook = zeros(("injections", "bytes", "tokens_estimate", "repeats", "repeat_share", "actions", "action_rate", "tokens_per_action"))
    verb = zeros(("calls", "failures", "failure_share", "output_samples", "output_bytes", "output_bytes_p50", "output_bytes_p90"))
    verb["failures_by_text"] = zeros(FAILURES)
    bucket = {
        "verbs": {s: {v: copy.deepcopy(verb) for v in VERBS} for s in ("claude", "codex")},
        "human": {"commands": zeros(VERBS)},
        "hooks": {"events": {e: copy.deepcopy(hook) for e in EVENTS},
                  "types": {k: copy.deepcopy(hook) for k in KINDS},
                  "runs": zeros(EVENTS), "timeouts": zeros(EVENTS),
                  "wall_ms": zeros(EVENTS), "compact_orientations": 0, "own_claim_warnings": 0},
        "claims": zeros(("claims", "refusals", "transcript_refusals", "cross_worktree_refusals", "worktree_classified_refusals", "cross_worktree_share", "snapshot_claims", "expired_at_end", "claims_output_rows", "expired_output_rows", "expired_output_share", "edits_after_refusal", "refusals_with_observed_followup")),
        "identity": zeros(("sessions_with_names", "names_per_session_p50", "names_per_session_p90", "multiple_names_sessions", "distinct_names", "reused_names", "sessions_with_reused_names")),
        "peer": zeros(("messages", "directed_asks", "answered_asks", "answer_rate", "answer_minutes_samples", "answer_minutes_p50", "handoffs", "picked_up_handoffs", "handoff_pickup_rate", "handoffs_cursor_covered", "broadcasts", "rulings", "broadcasts_per_ruling", "handoffs_to_brains", "brain_handoffs_answered", "brain_handoff_answer_rate", "recipients_absent_from_current_roster")),
        "adoption": {s: zeros(("sessions", "using_bus", "not_using_bus", "subagent_sessions", "subagents_using_bus")) for s in ("claude", "codex")},
        "buses": 0,
    }
    return {
        "schema_version": 1, "cycle": 0, "window": zeros(("start", "end", "explicit_start", "explicit_end")),
        "sources": zeros(("bus_files", "deduplicated_buses", "bus_read_errors", "missing_bus_tables", "claude_files", "codex_files", "history_files", "excluded_sessions", "input_read_errors", "malformed_records", "duplicate_records", "undated_records", "unresolved_tool_calls", "unparsed_exec_calls")),
        "unavailable": {k: 1 for k in ("historical_roster", "historical_claims", "human_review", "release_metadata", "annotations", "tokenizer", "unobserved_runs", "reference_data", "brain_configuration", "historical_worktrees")},
        "workspaces": {b: copy.deepcopy(bucket) for b in ("personal", "work")},
    }


def validate_cycle(value, allowed=None):
    """Raise ValueError without echoing potentially private input."""
    if allowed is None:
        allowed = schema()
    if isinstance(allowed, dict):
        if not isinstance(value, dict) or value.keys() != allowed.keys():
            raise ValueError("cycle schema keys do not match allowlist")
        for key in allowed:
            validate_cycle(value[key], allowed[key])
    elif type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError("cycle schema requires finite numeric values")


def timestamp(value):
    if isinstance(value, (float, int)) and math.isfinite(value):
        return float(value)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.replace(tzinfo=parsed.tzinfo or timezone.utc).timestamp()
    except (ValueError, TypeError, AttributeError, OverflowError):
        return None


def quantile(values, p):
    if not values:
        return 0
    return statistics.median(values) if p == .5 else sorted(values)[min(len(values) - 1, int(p * len(values)))]


def share(a, b):
    return a / b if b else 0


def tokenize(command):
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>")
        lex.whitespace_split = True
        lex.commenters = "#"
        return list(lex)
    except ValueError:
        return command.split()


def is_bus(word):
    # Quotes survive when shlex falls back to split() (e.g. a trailing "\\").
    return os.path.basename(word.strip("\"'")) in ("agentbus", "agentbus.py")


def open_quote(line):
    """The quote character a shell line leaves open, or None."""
    quote, i = None, 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and quote != "'":
            i += 1
        elif quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        i += 1
    return quote


def logical_lines(command):
    """Physical lines, with heredoc bodies dropped and an interpreter's quoted
    multi-line program (python3 -c "...") joined into one line: text inside a
    program is not a command word."""
    lines = command.splitlines()
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        i += 1
        quote = open_quote(line)
        if quote and any(INTERPRETER.match(w.strip("\"'")) for w in tokenize(line)):
            while quote and i < len(lines):
                line += "\n" + lines[i]
                i += 1
                quote = open_quote(line)
            tail = line.rsplit("\n", 1)[-1]
        else:
            tail = line
        out.append(line)
        for match in HEREDOC.finditer(tail):
            while i < len(lines) and lines[i].strip() != match[2]:
                i += 1
            i += 1
    return out


def parse(command):
    """Cycle-0 shell parser: parse executable positions, never quoted prose."""
    aliases = {}
    for match in FUNC.finditer(command):
        body = tokenize(match[2])
        for j, word in enumerate(body):
            if is_bus(word):
                aliases[match[1]] = [w for w in body[j + 1:] if w not in ("$@", ";")]
                break
    command = FUNC.sub(" ; ", command)
    segments = []
    for line in (l.replace("$(", " ; ").replace("`", " ; ") for l in logical_lines(command)):
        seg = []
        for word in tokenize(line):
            if word and set(word) <= set(";&|()<>"):
                if word[0] in "<>" and seg and seg[-1].isdigit():
                    seg.pop()
                if seg:
                    segments.append(seg)
                seg = ["__REDIR__"] if word in ("<", ">", ">>", "<<") else []
            else:
                seg.append(word)
        if seg:
            segments.append(seg)
    calls = []
    for seg in segments:
        i, env_name = 0, None
        while i < len(seg):
            word = seg[i]
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word):
                name, val = word.split("=", 1)
                if name == "AGENTBUS_AGENT":
                    env_name = val
                words = val.split()
                if words and is_bus(words[0]):
                    aliases[name] = words[1:]
                elif len(words) > 1 and PYTHON.match(words[0]) and is_bus(words[1]):
                    aliases[name] = words[2:]
                i += 1
            elif word in PREFIX:
                i += 1
            elif word == "env":
                i += 1
                while i < len(seg) and seg[i].startswith("-"):
                    i += 2 if seg[i] in ("-u", "--unset") else 1
            elif word in ("timeout", "gtimeout"):
                i += 1
                while i < len(seg) and (seg[i].startswith("-") or re.match(r"^\d+[smh]?$", seg[i])):
                    i += 1
            elif word == "nice":
                i += 1
                if i < len(seg) and seg[i] == "-n":
                    i += 2
            else:
                break
        if i >= len(seg):
            continue
        word, pre = seg[i], None
        if is_bus(word):
            pre, i = [], i + 1
        elif PYTHON.match(word) and i + 1 < len(seg):
            j = i + 1
            while j < len(seg) and seg[j].startswith("-"):
                j += 1
            if j < len(seg) and is_bus(seg[j]):
                pre, i = [], j + 1
        if pre is None:
            alias = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", word)
            name = alias[1] if alias else word
            if name in aliases:
                pre, i = aliases[name], i + 1
        if pre is None:
            continue
        rest, name, k = list(pre) + seg[i:], env_name, 0
        while k < len(rest):
            arg = rest[k]
            if arg in GLOBAL_ARGS and k + 1 < len(rest):
                if arg == "--as":
                    name = rest[k + 1]
                k += 2
            elif arg.startswith("--as="):
                name, k = arg[5:], k + 1
            elif arg in ("--json", "-q", "--quiet"):
                k += 1
            else:
                break
        raw = rest[k] if k < len(rest) else ""
        args = rest[k + 1:]
        for j, arg in enumerate(args):
            if arg == "--as" and j + 1 < len(args):
                name = args[j + 1]
            elif arg.startswith("--as="):
                name = arg[5:]
        if raw in KNOWN:
            verb = raw
        elif raw in ("-h", "--help"):
            verb = "help_flag"
        elif raw in ("--version", "-V"):
            verb = "version_flag"
        else:
            verb = "dynamic" if raw.startswith("$") else "unknown" if raw else "no_verb"
        if raw == "join" and args and not args[0].startswith("-"):
            name = args[0]
        calls.append({"verb": verb, "args": args, "name": name, "as_after": "--as" in args or any(a.startswith("--as=") for a in args)})
    return calls


def text_of(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(text_of(v) for v in value)
    if isinstance(value, dict):
        return text_of(value.get("text", ""))
    return ""


def failure_lines(output):
    found, seen = [], set()
    for line in output.splitlines():
        line = line.strip()
        if not DIAG.match(line) or NOTICE.search(line):
            continue
        result = next(((kind, verb) for kind, rx, verb in RULES if re.search(rx, line)), None)
        if result is None and (re.search(r'"error"\s*:', line) or re.search(r"error|cannot|can't|refus|not |no |unknown|invalid|must", line, re.I)):
            result = ("other_error", None)
        if result and (result[0], line[:80]) not in seen:
            found.append((*result, line))
            seen.add((result[0], line[:80]))
    return found


def hook_kind(text):
    if text.startswith("agentbus: you are on") or text.startswith("## Agentbus\n"):
        return "orientation"
    if "unread message" in text or "unread direct messages" in text:
        return "unread"
    if "no claim" in text:
        return "no_claim"
    if "different name" in text:
        return "held_claim"
    return "other"


def injected_names(text):
    names = set(re.findall(r"--as ([\w.-]+)", text))
    names.update(re.findall(r"\bas ([\w.-]+)\.(?=\s|$)", text))
    return names


def command_signature(command):
    invocations = parse(command)
    return tuple((c["verb"], tuple(c["args"])) for c in invocations) if invocations else command


class Collector:
    def __init__(self, args):
        self.args = args
        self.result = schema()
        self.times = []
        self.sessions = []
        self.buses = []
        self.seen = set()
        self.inputs = set()
        self.history = []

    def bucket(self, workspace):
        return "work" if any(fnmatch.fnmatchcase(workspace or "", rule) for rule in self.args.work_pattern) else "personal"

    def observe(self, value):
        t = timestamp(value)
        if t is not None:
            self.times.append(t)
        return t

    def within(self, value):
        t = timestamp(value)
        if t is None:
            return self.args.start is None and self.args.end is None
        return (self.args.start is None or t >= self.args.start) and (self.args.end is None or t <= self.args.end)

    def files(self, roots, suffix):
        found = set()
        for root in roots:
            p = Path(root).expanduser()
            if p.is_file() and p.name.endswith(suffix):
                found.add(p.resolve())
            elif p.is_dir():
                for directory, dirs, names in os.walk(p):
                    dirs.sort()
                    for name in sorted(names):
                        if (name == suffix if suffix == "bus.db" else name.endswith(suffix)):
                            found.add((Path(directory) / name).resolve())
        self.inputs.update(found)
        return sorted(found)

    def records(self, path):
        try:
            with path.open(encoding="utf-8", errors="replace") as source:
                for line in source:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        self.result["sources"]["malformed_records"] += 1
                        continue
                    if isinstance(row, dict):
                        yield row
                    else:
                        self.result["sources"]["malformed_records"] += 1
        except OSError:
            self.result["sources"]["input_read_errors"] += 1

    def read_buses(self):
        roots = self.args.bus_root + self.args.retired_root
        for path in self.files(roots, "bus.db"):
            self.result["sources"]["bus_files"] += 1
            con = None
            try:
                # mode=ro, NEVER immutable: a committed WAL is part of the bus.
                con = sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=ro", uri=True)
                con.row_factory = sqlite3.Row
                con.execute("PRAGMA query_only=ON")
                con.execute("PRAGMA trusted_schema=OFF")
                con.execute("BEGIN")  # one consistent snapshot across all tables
                tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if "messages" not in tables:
                    self.result["sources"]["bus_read_errors"] += 1
                    continue
                data = {"bucket": self.bucket(str(path.parent.parent))}
                for table in ("messages", "agents", "claims", "log", "cursors"):
                    if table not in tables:
                        self.result["sources"]["missing_bus_tables"] += 1
                        data[table] = []
                    else:
                        data[table] = [dict(r) for r in con.execute('SELECT * FROM "' + table + '" ORDER BY rowid')]
                # Compare full message content before window filtering, independent
                # of schema additions and unrelated snapshot/log table changes.
                data["fingerprints"] = tuple(hashlib.sha256(json.dumps([m.get(k) for k in ("id", "ts", "sender", "recipient", "kind", "topic", "body", "reply_to")], ensure_ascii=True).encode()).digest() for m in data["messages"])
                self.buses.append(data)
            except (sqlite3.Error, OSError, ValueError, TypeError):
                self.result["sources"]["bus_read_errors"] += 1
            finally:
                if con is not None:
                    con.close()
        kept = []
        for bus in sorted(self.buses, key=lambda b: -len(b["fingerprints"])):
            fp = bus["fingerprints"]
            # Empty buses provide no evidence of shared lineage.
            if fp and any(other["fingerprints"][:len(fp)] == fp for other in kept):
                self.result["sources"]["deduplicated_buses"] += 1
            else:
                kept.append(bus)
        self.buses = kept
        for bus in kept:
            for table in ("messages", "log"):
                for row in bus[table]:
                    self.observe(row.get("ts"))
            for row in bus["agents"]:
                self.observe(row.get("last_seen"))

    def read_transcripts(self, roots, source):
        candidates = []
        for path in self.files(roots, ".jsonl"):
            self.result["sources"][source + "_files"] += 1
            # Read one transcript at a time, ordered by its first record, as in
            # cycle 0's earliest-starting transcript ownership rule.
            first = next(self.records(path), {})
            candidates.append((str(first.get("timestamp", "")), path))
        for _, path in sorted(candidates):
            rows = list(self.records(path))
            session = {"path": str(path), "entry": "", "cwds": set(), "source": source, "id": (source, str(path)), "workspace": str(path.parent), "sub": "subagents" in path.parts, "events": [], "names": set()}
            tools, requests, completions = {}, {}, []
            completed_commands = {}
            for row in rows:
                payload = row.get("payload")
                item = payload.get("item") if isinstance(payload, dict) else None
                if isinstance(item, dict) and item.get("type") == "CommandExecution" and payload.get("type") == "item_completed":
                    cmd = item.get("command") or ""
                    cmd = cmd[-1] if isinstance(cmd, list) and cmd else cmd
                    signature = command_signature(cmd)
                    completed_commands[signature] = completed_commands.get(signature, 0) + 1
            stop_summaries = any(r.get("type") == "system" and r.get("subtype") == "stop_hook_summary" and any(isinstance(info, dict) and "hook claude" in info.get("command", "") for info in r.get("hookInfos") or []) for r in rows)
            occurrences = {}
            # A Claude hook's source ("SessionStart:compact") is named on its
            # hook_success attachment; the injected text arrives on a separate
            # hook_additional_context record whose parentUuid is that record.
            hook_names = {r["uuid"]: (r.get("attachment") or {}).get("hookName") or "" for r in rows if r.get("uuid") and r.get("type") == "attachment" and (r.get("attachment") or {}).get("type") == "hook_success"}
            last_hook_name = {}
            if source == "codex":
                meta = next((r["payload"] for r in rows if r.get("type") == "session_meta" and isinstance(r.get("payload"), dict)), {})
                session["id"] = (source, meta.get("id") or str(path))
            for row in rows:
                ts = row.get("timestamp")
                self.observe(ts)
                if not ts:
                    self.result["sources"]["undated_records"] += 1
                uid = row.get("uuid")
                if uid:
                    key = (source, "uuid", uid)
                    if key in self.seen:
                        self.result["sources"]["duplicate_records"] += 1
                        continue
                    self.seen.add(key)
                if source == "codex":
                    # An ordinal preserves identical repeated injections within
                    # one file while suppressing copied rollout records.
                    digest = hashlib.sha256(json.dumps(row, sort_keys=True).encode()).digest()
                    ordinal = occurrences.get(digest, 0)
                    occurrences[digest] = ordinal + 1
                    key = (source, "record", session["id"], digest, ordinal)
                    if key in self.seen:
                        self.result["sources"]["duplicate_records"] += 1
                        continue
                    self.seen.add(key)
                if row.get("cwd"):
                    session["workspace"] = row["cwd"]
                    session["cwds"].add(row["cwd"])
                if row.get("entrypoint") and not session["entry"]:
                    session["entry"] = row["entrypoint"]
                if source == "claude" and row.get("sessionId") and not session["sub"]:
                    session["id"] = (source, row["sessionId"])
                if row.get("type") in ("assistant", "user", "session_meta"):
                    session["events"].append({"type": "activity", "ts": ts})
                payload = row.get("payload") or {}
                if not isinstance(payload, dict):
                    payload = {}
                if source == "codex":
                    if row.get("type") == "session_meta":
                        session["workspace"] = payload.get("cwd") or session["workspace"]
                        session["cwds"].add(session["workspace"])
                        session["id"] = (source, payload.get("id") or str(path))
                    hook = payload.get("hookSpecificOutput", payload)
                    if isinstance(hook, dict) and hook.get("additionalContext"):
                        texts = hook["additionalContext"]
                        for tx in texts if isinstance(texts, list) else [texts]:
                            if isinstance(tx, str) and tx.startswith("agentbus:"):
                                self.injection(session, ts, hook.get("hookEventName") or hook.get("hookEvent"), tx)
                    item = payload.get("item") or {}
                    if not isinstance(item, dict):
                        item = {}
                    if payload.get("type") == "item_completed" and item.get("type") == "CommandExecution":
                        command = item.get("command", "")
                        command = command[-1] if isinstance(command, list) and command else command
                        key = (source, "command", session["id"], item.get("id") or (ts, command))
                        if key in self.seen:
                            self.result["sources"]["duplicate_records"] += 1
                            continue
                        self.seen.add(key)
                        session["events"].append({"type": "tool", "ts": ts, "cmd": command or "", "out": (item.get("aggregated_output") or "") if parse(command or "") else "", "cwd": item.get("cwd"), "complete": True})
                    elif payload.get("type") == "item_completed" and item.get("type") == "FileChange":
                        session["events"].append({"type": "edit", "ts": ts, "paths": list((item.get("changes") or {}).keys())})
                    elif row.get("type") == "response_item":
                        typ = payload.get("type")
                        if typ in ("function_call", "custom_tool_call"):
                            commands = []
                            if payload.get("name", "").split(".")[-1] == "exec_command":
                                try:
                                    commands = [json.loads(payload.get("arguments", "{}")).get("cmd", "")]
                                except (ValueError, AttributeError):
                                    pass
                            elif payload.get("name", "").split(".")[-1] == "exec":
                                # Literal JS commands only: variables require execution,
                                # which a read-only collector must never do.
                                commands = [json.loads(m[1]) for m in re.finditer(r'exec_command\(\{\s*(?:"cmd"|cmd)\s*:\s*("(?:[^"\\]|\\.)*")', payload.get("input", ""))]
                                if "exec_command" in payload.get("input", "") and not commands:
                                    self.result["sources"]["unparsed_exec_calls"] += 1
                            missing = []
                            for cmd in commands:
                                signature = command_signature(cmd)
                                if completed_commands.get(signature, 0):
                                    completed_commands[signature] -= 1
                                else:
                                    missing.append(cmd)
                            commands = missing
                            ev = {"type": "tool", "ts": ts, "cmd": "\n".join(commands), "out": "", "complete": False}
                            requests[payload.get("call_id")] = ev
                            if commands:
                                session["events"].append(ev)
                        elif typ in ("function_call_output", "custom_tool_call_output"):
                            completions.append(payload)
                        elif typ == "message":
                            if payload.get("role") == "user":
                                session["events"].append({"type": "prompt", "ts": ts})
                            for content in payload.get("content", []):
                                tx = text_of(content)
                                block = re.search(r"## Agentbus\n.*?(?=\n---|\n## (?!Agentbus)|\Z)", tx, re.S)
                                # The codex-lane "## Agentbus" brief is prompt text, not a
                                # hook injection (cycle 0: zero hook context reached Codex).
                                if not block and tx.startswith("agentbus:"):
                                    self.injection(session, ts, "other", tx)
                                match = re.search(r"You are (\S+) on the (\S+) bus", tx)
                                if match:
                                    session["names"].add(match[1])
                    continue
                msg = row.get("message") or {}
                content = msg.get("content") if isinstance(msg, dict) else None
                if row.get("type") == "assistant" and isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        tid = block.get("id")
                        key = (source, "tool", tid) if tid else None
                        if key and key in self.seen:
                            self.result["sources"]["duplicate_records"] += 1
                            continue
                        if key:
                            self.seen.add(key)
                        inp = block.get("input") or {}
                        ev = {"type": "tool", "ts": ts, "id": tid, "cmd": inp.get("command", "") if block.get("name") == "Bash" else "", "out": "", "complete": False}
                        if block.get("name") in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                            ev["paths"] = [inp.get("file_path") or inp.get("notebook_path") or ""]
                        session["events"].append(ev)
                        tools[tid] = ev
                elif row.get("type") == "user":
                    results = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"] if isinstance(content, list) else []
                    for block in results:
                        ev = tools.get(block.get("tool_use_id"))
                        if ev is not None:
                            ev.update(out=text_of(block.get("content")) if parse(ev["cmd"]) else "", complete=True)
                    typed = text_of(content).lstrip()
                    # A typed prompt: not a task notification or a slash/local command echo.
                    if not results and not row.get("isMeta") and typed and not typed.startswith(("<task-notification", "<command-", "<local-command")):
                        session["events"].append({"type": "prompt", "ts": ts})
                elif row.get("type") == "attachment":
                    attachment = row.get("attachment") or {}
                    typ = attachment.get("type")
                    event = attachment.get("hookEvent")
                    if typ == "hook_success" and attachment.get("hookName"):
                        last_hook_name[event] = attachment["hookName"]
                    if typ == "hook_additional_context":
                        texts = attachment.get("content")
                        name = attachment.get("hookName", "")
                        if ":" not in name:
                            name = hook_names.get(row.get("parentUuid")) or last_hook_name.get(event) or name
                        for tx in texts if isinstance(texts, list) else [texts]:
                            if isinstance(tx, str) and tx.startswith("agentbus:"):
                                self.injection(session, ts, event, tx, name)
                                session["events"][-1]["tool_id"] = attachment.get("toolUseID")
                    elif typ in ("hook_success", "hook_cancelled", "hook_error", "hook_non_blocking_error", "hook_blocking_error") and ("hook claude" in attachment.get("command", "") or "agentbus:" in attachment.get("stdout", "")):
                        # Stop runs and wall time come from stop_hook_summary when the
                        # transcript has one; its timeouts still come from hook_cancelled.
                        summarized = event == "Stop" and stop_summaries
                        if not summarized or typ == "hook_cancelled":
                            session["events"].append({"type": "hook_run", "ts": ts, "event": event if event in EVENTS else "other", "run": int(not summarized), "timeout": int(typ == "hook_cancelled"), "ms": 0 if summarized else attachment.get("durationMs") or 0})
                elif row.get("type") == "system" and row.get("subtype") == "stop_hook_summary":
                    for info in row.get("hookInfos") or []:
                        if isinstance(info, dict) and "hook claude" in info.get("command", ""):
                            session["events"].append({"type": "hook_run", "ts": ts, "event": "Stop", "run": 1, "timeout": 0, "ms": info.get("durationMs") or 0})
            for completion in completions:
                ev = requests.get(completion.get("call_id"))
                if ev is not None:
                    output = text_of(completion.get("output"))
                    try:
                        wrapped = json.loads(output)
                        if isinstance(wrapped, dict) and isinstance(wrapped.get("output"), str):
                            output = wrapped["output"]
                    except ValueError:
                        if "\nOutput:\n" in output:
                            output = output.split("\nOutput:\n", 1)[1]
                    ev.update(out=output, complete=True)
            self.sessions.append(session)

    @staticmethod
    def injection(session, ts, event, text, hook_name=""):
        session["events"].append({"type": "injection", "ts": ts, "event": event if event in EVENTS else "other", "text": text, "kind": hook_kind(text), "compact": int(hook_name.rsplit(":", 1)[-1] == "compact")})

    def read_history(self):
        for root in self.args.history:
            path = Path(root).expanduser().resolve()
            self.inputs.add(path)
            if not path.exists():
                continue
            self.result["sources"]["history_files"] += 1
            try:
                with path.open(encoding="utf-8", errors="replace") as source:
                    logical = ""
                    for line in source:
                        logical += line.rstrip("\n")
                        if logical.endswith("\\"):
                            logical = logical[:-1] + "\n"
                            continue
                        match = re.match(r"^: (\d+):\d+;(.*)$", logical, re.S)
                        ts, cmd = (int(match[1]), match[2]) if match else (None, logical)
                        self.observe(ts)
                        self.history.append((ts, cmd))
                        logical = ""
            except OSError:
                self.result["sources"]["input_read_errors"] += 1

    def measure_buses(self, end):
        for bus in self.buses:
            bucket = self.result["workspaces"][bus["bucket"]]
            bucket["buses"] += 1
            peer, claims = bucket["peer"], bucket["claims"]
            msgs = [m for m in bus["messages"] if self.within(m.get("ts"))]
            roster = {a.get("name") for a in bus["agents"]}
            cursors = {c.get("agent"): c.get("last_read_id", 0) for c in bus["cursors"]}
            peer["messages"] += len(msgs)
            latencies = []
            by_parent = {}
            for msg in msgs:
                if msg.get("reply_to") is not None:
                    by_parent.setdefault(msg["reply_to"], []).append(msg)
            for msg in msgs:
                recipient = msg.get("recipient")
                broadcast = recipient in ("*", "all", "everyone")
                peer["broadcasts"] += int(broadcast)
                peer["rulings"] += int(msg.get("topic") == "ruling")
                peer["recipients_absent_from_current_roster"] += int(not broadcast and recipient not in roster)
                if broadcast:
                    continue
                replies = [r for r in by_parent.get(msg.get("id"), []) if r.get("sender") == recipient and r.get("kind") != "question" and r.get("id", 0) > msg.get("id", 0)]
                if msg.get("kind") == "question":
                    answers = [r for r in replies if r.get("kind") == "answer"]
                    peer["directed_asks"] += 1
                    peer["answered_asks"] += bool(answers)
                    start = timestamp(msg.get("ts"))
                    times = [timestamp(r.get("ts")) for r in answers]
                    times = [t for t in times if t is not None and start is not None and t >= start]
                    if times:
                        latencies.append((min(times) - start) / 60)
                elif msg.get("kind") == "handoff":
                    peer["handoffs"] += 1
                    peer["picked_up_handoffs"] += bool(replies)
                    peer["handoffs_cursor_covered"] += cursors.get(recipient, 0) >= msg.get("id", 0)
                    if recipient in self.args.brain_name:
                        peer["handoffs_to_brains"] += 1
                        peer["brain_handoffs_answered"] += bool(replies)
            bus["latencies"] = latencies
            for claim in bus["claims"]:
                claims["snapshot_claims"] += 1
                expiry = timestamp(claim.get("expires_at"))
                claims["expired_at_end"] += expiry is not None and expiry <= end
            # Replay join metadata; current roster cwd cannot classify old refusals.
            cwd = {}
            for row in bus["log"]:
                try:
                    detail = json.loads(row.get("detail") or "{}")
                except (ValueError, TypeError):
                    detail = {}
                if row.get("action") == "join" and isinstance(detail, dict):
                    cwd[row.get("agent")] = detail.get("cwd")
                if not self.within(row.get("ts")):
                    continue
                claims["claims"] += row.get("action") == "claim"
                if row.get("action") == "claim_refused":
                    claims["refusals"] += 1
                    conflicts = detail.get("conflicts", []) if isinstance(detail, dict) else []
                    holder_cwds = [cwd.get(c.get("holder")) for c in conflicts if isinstance(c, dict)]
                    claimant_cwd = cwd.get(row.get("agent"))
                    if claimant_cwd and holder_cwds and all(holder_cwds):
                        claims["worktree_classified_refusals"] += 1
                        claims["cross_worktree_refusals"] += any(c != claimant_cwd for c in holder_cwds)
            # Some historical releases omitted cwd in join log metadata. Keep
            # those refusals out of the classified denominator, never guess
            # from an agent's present-day roster entry.
        for name, bucket in self.result["workspaces"].items():
            p, c = bucket["peer"], bucket["claims"]
            p["answer_rate"] = share(p["answered_asks"], p["directed_asks"])
            p["handoff_pickup_rate"] = share(p["picked_up_handoffs"], p["handoffs"])
            p["brain_handoff_answer_rate"] = share(p["brain_handoffs_answered"], p["handoffs_to_brains"])
            p["broadcasts_per_ruling"] = share(p["broadcasts"], p["rulings"])
            latencies = [t for b in self.buses if b["bucket"] == name for t in b["latencies"]]
            p["answer_minutes_samples"] = len(latencies)
            p["answer_minutes_p50"] = quantile(latencies, .5)
            c["cross_worktree_share"] = share(c["cross_worktree_refusals"], c["worktree_classified_refusals"])

    def excluded(self, session):
        """Scripted populations (cycle 0: eval and trial runs) leave every metric."""
        places = [session["path"]] + sorted(session["cwds"])
        return session["entry"] in self.args.exclude_entrypoint or any(fnmatch.fnmatchcase(place, rule) for place in places for rule in self.args.exclude_pattern)

    def measure_sessions(self):
        sizes, identities, adopted = {}, {}, set()
        for session in self.sessions:
            if self.excluded(session):
                self.result["sources"]["excluded_sessions"] += 1
                continue
            bucket_name = self.bucket(session["workspace"])
            bucket = self.result["workspaces"][bucket_name]
            events = [e for e in session["events"] if self.within(e.get("ts"))]
            if not events:
                continue
            used, names, prev = False, set(session["names"]), {}
            for i, ev in enumerate(events):
                typ = ev["type"]
                if typ == "tool":
                    invocations = parse(ev["cmd"])
                    ev["invocations"] = invocations
                    used = used or bool(invocations)
                    names.update(c["name"] for c in invocations if c["name"])
                    names.update(re.findall(r"joined as (\S+)", ev["out"]))
                    if invocations and not ev["complete"]:
                        self.result["sources"]["unresolved_tool_calls"] += 1
                    for inv in invocations:
                        bucket["verbs"][session["source"]][inv["verb"]]["calls"] += 1
                    if len(invocations) == 1 and ev["complete"]:
                        key = (bucket_name, session["source"], invocations[0]["verb"])
                        sizes.setdefault(key, []).append(len(ev["out"].encode("utf-8")))
                    failed, attributed = set(), {}
                    for kind, implied, line in failure_lines(ev["out"]) if invocations else []:
                        candidates = [j for j, inv in enumerate(invocations) if inv["verb"] == implied]
                        if kind == "unknown_command":
                            candidates = [j for j, inv in enumerate(invocations) if inv["verb"] == "unknown"]
                        elif kind == "as_after_verb":
                            candidates = [j for j, inv in enumerate(invocations) if inv["as_after"]]
                        offset = attributed.get((kind, implied), 0)
                        j = candidates[min(offset, len(candidates) - 1)] if candidates else 0
                        attributed[(kind, implied)] = offset + 1
                        metric = bucket["verbs"][session["source"]][invocations[j]["verb"]]
                        metric["failures_by_text"][kind] += 1
                        failed.add(j)
                        if kind == "claim_conflict":
                            self.refusal_followup(bucket, line, events[i + 1:])
                    for j in failed:
                        bucket["verbs"][session["source"]][invocations[j]["verb"]]["failures"] += 1
                    if any(c["verb"] == "claims" for c in invocations):
                        self.claim_output(bucket["claims"], ev)
                elif typ == "hook_run":
                    bucket["hooks"]["runs"][ev["event"]] += ev["run"]
                    bucket["hooks"]["timeouts"][ev["event"]] += ev["timeout"]
                    bucket["hooks"]["wall_ms"][ev["event"]] += ev["ms"]
                elif typ == "injection":
                    text, kind = ev["text"], ev["kind"]
                    names.update(injected_names(text))
                    tools, prompts = [], 0
                    for nxt in events[i + 1:]:
                        if nxt["type"] == "prompt":
                            prompts += 1
                            if kind != "orientation" or prompts > 1:
                                break
                        if nxt["type"] == "tool":
                            tools.append(nxt)
                        if len(tools) >= 10:
                            break
                    verbs = {c["verb"] for tool in tools for c in parse(tool["cmd"])}
                    wanted = {"unread": {"inbox", "brief", "read"}, "no_claim": {"claim"}, "held_claim": {"claims", "claim", "post"}}
                    acted = bool(verbs & wanted[kind]) if kind in wanted else bool(verbs)
                    repeat = prev.get(kind) == text
                    prev[kind] = text
                    for metric in (bucket["hooks"]["events"][ev["event"]], bucket["hooks"]["types"][kind]):
                        metric["injections"] += 1
                        metric["bytes"] += len(text.encode("utf-8"))
                        metric["repeats"] += repeat
                        metric["actions"] += acted
                    bucket["hooks"]["compact_orientations"] += ev["compact"] if kind == "orientation" else 0
                    if kind == "held_claim":
                        target = next((t for t in events[:i] if t.get("id") == ev.get("tool_id") and ev.get("tool_id")), {})
                        owned = False
                        for tool in events[:i]:
                            # Cycle 0 rule: an earlier claim attempt under a name this
                            # session used, refused or not (refusals included 10 of 107).
                            if tool["type"] != "tool" or not tool["complete"]:
                                continue
                            for call in parse(tool["cmd"]):
                                if call["verb"] != "claim" or not call["name"] or call["name"] not in names:
                                    continue
                                resources = []
                                for arg in call["args"]:
                                    if arg.startswith("-"):
                                        break
                                    resources.append(arg.rstrip("*/"))
                                owned = owned or any(p.endswith("/" + res) or ("/" + res + "/") in p or p == res for p in target.get("paths", []) for res in resources if res)
                        bucket["hooks"]["own_claim_warnings"] += owned
            identities.setdefault(bucket_name, {})[session["id"]] = identities.setdefault(bucket_name, {}).get(session["id"], set()) | names
            adoption_key = (session["id"], bucket_name)
            if adoption_key not in adopted:
                adopted.add(adoption_key)
                adoption = bucket["adoption"][session["source"]]
                adoption["sessions"] += 1
                adoption["using_bus"] += used
                adoption["not_using_bus"] += not used
                adoption["subagent_sessions"] += session["sub"]
                adoption["subagents_using_bus"] += session["sub"] and used
        for (bucket, source, verb), values in sizes.items():
            metric = self.result["workspaces"][bucket]["verbs"][source][verb]
            metric.update(output_samples=len(values), output_bytes=sum(values), output_bytes_p50=quantile(values, .5), output_bytes_p90=quantile(values, .9))
        for name, bucket in self.result["workspaces"].items():
            identities_here = identities.get(name, {})
            counts = [len(ns) for ns in identities_here.values() if ns]
            by_name = {}
            for sid, ns in identities_here.items():
                for n in ns:
                    by_name.setdefault(n, set()).add(sid)
            reused = [sids for sids in by_name.values() if len(sids) > 1]
            bucket["identity"].update(sessions_with_names=len(counts), names_per_session_p50=quantile(counts, .5), names_per_session_p90=quantile(counts, .9), multiple_names_sessions=sum(n > 1 for n in counts), distinct_names=len(by_name), reused_names=len(reused), sessions_with_reused_names=len(set().union(*reused)) if reused else 0)
            for metrics in bucket["verbs"].values():
                for metric in metrics.values():
                    metric["failure_share"] = share(metric["failures"], metric["calls"])
            for group in ("events", "types"):
                for metric in bucket["hooks"][group].values():
                    metric["repeat_share"] = share(metric["repeats"], metric["injections"])
                    metric["action_rate"] = share(metric["actions"], metric["injections"])
                    metric["tokens_estimate"] = metric["bytes"] / 4
                    metric["tokens_per_action"] = share(metric["tokens_estimate"], metric["actions"])
            claims = bucket["claims"]
            claims["expired_output_share"] = share(claims["expired_output_rows"], claims["claims_output_rows"])

    def refusal_followup(self, bucket, line, following):
        claims = bucket["claims"]
        claims["transcript_refusals"] += 1
        match = re.search(r"agentbus: (\S+) is claimed by", line)
        if not match:
            return
        path = match[1].rstrip("/")
        claims["refusals_with_observed_followup"] += bool(following)
        for ev in following:
            if any(p.rstrip("/") == path or p.endswith("/" + path) for p in ev.get("paths", [])):
                claims["edits_after_refusal"] += 1
                break

    @staticmethod
    def claim_output(metric, ev):
        try:
            data = json.loads(ev["out"])
        except ValueError:
            data = None
        rows = data.get("items") if isinstance(data, dict) else data
        if isinstance(rows, list):
            for row in rows:
                if not isinstance(row, dict) or "resource" not in row:
                    continue
                metric["claims_output_rows"] += 1
                expiry, now = timestamp(row.get("expires_at")), timestamp(ev.get("ts"))
                metric["expired_output_rows"] += row.get("state") == "expired" or (expiry is not None and now is not None and expiry <= now)
        else:
            for line in ev["out"].splitlines():
                if re.search(r"\b(?:expired|for \d+[smhdw])\b", line):
                    metric["claims_output_rows"] += 1
                    metric["expired_output_rows"] += bool(re.search(r"\bexpired\b", line))

    def collect(self):
        self.read_buses()
        self.read_transcripts(self.args.claude_root, "claude")
        self.read_transcripts(self.args.codex_root, "codex")
        self.read_history()
        observed = [t for t in self.times if self.within(t)]
        start = self.args.start if self.args.start is not None else min(observed, default=self.args.end or 0)
        end = self.args.end if self.args.end is not None else max(observed, default=start)
        self.result["cycle"] = self.args.cycle
        self.result["window"].update(start=start, end=end, explicit_start=int(self.args.start is not None), explicit_end=int(self.args.end is not None))
        self.result["unavailable"]["brain_configuration"] = int(not self.args.brain_name)
        self.measure_buses(end)
        self.measure_sessions()
        for ts, cmd in self.history:
            if self.within(ts):
                bucket = self.result["workspaces"][self.bucket(self.args.history_workspace)]
                for inv in parse(cmd):
                    bucket["human"]["commands"][inv["verb"]] += 1
        validate_cycle(self.result)
        return self.result


def time_arg(value):
    try:
        number = float(value)
    except ValueError:
        number = timestamp(value)
    if number is None or not math.isfinite(number):
        raise argparse.ArgumentTypeError("expected UTC epoch seconds or ISO 8601 time")
    return number


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cycle", required=True, type=int)
    parser.add_argument("--output", type=Path, help="default: docs/usage/cycles/NNNN.json; '-' writes stdout")
    for flag in ("bus-root", "retired-root", "claude-root", "codex-root", "history"):
        parser.add_argument("--" + flag, action="append", help="repeatable; overrides this source's defaults")
    parser.add_argument("--work-pattern", action="append", default=[], help="fnmatch rule on cwd/project; all other workspaces are personal")
    parser.add_argument("--exclude-pattern", action="append", default=[], help="fnmatch rule on a transcript's file path or any cwd it records; matching sessions leave every metric")
    parser.add_argument("--exclude-entrypoint", action="append", default=[], help="Claude entrypoint (e.g. sdk-cli) whose sessions leave every metric")
    parser.add_argument("--history-workspace", default="", help="workspace used to bucket human commands (history has no cwd)")
    parser.add_argument("--brain-name", action="append", default=[])
    parser.add_argument("--start", type=time_arg)
    parser.add_argument("--end", type=time_arg)
    args = parser.parse_args(argv)
    if args.cycle < 0 or (args.start is not None and args.end is not None and args.end < args.start):
        parser.error("cycle must be nonnegative and end must not precede start")
    defaults = {"bus_root": [str(Path.home() / "src")], "retired_root": [str(Path.home() / ".agentbus/retired")], "claude_root": [str(Path.home() / ".claude/projects")], "codex_root": [str(Path.home() / ".codex/sessions")] + [str(p) for p in sorted((Path.home() / ".claude/codex-lanes").glob("*/sessions"))], "history": [str(Path.home() / ".zsh_history")]}
    for key, value in defaults.items():
        if getattr(args, key) is None:
            setattr(args, key, value)
    return args


def main(argv=None):
    args = arguments(argv)
    collector = Collector(args)
    result = collector.collect()
    output = args.output or Path("docs/usage/cycles/%04d.json" % args.cycle)
    encoded = json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + "\n"
    if str(output) == "-":
        sys.stdout.write(encoded)
    else:
        if output.resolve() in collector.inputs or output.name.endswith((".jsonl", ".db", ".db-wal", ".db-shm")):
            raise ValueError("output must not overwrite a source")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded, encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, sqlite3.Error):
        sys.exit("usage collector: collection or output failed")
