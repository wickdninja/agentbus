#!/bin/bash
set -euo pipefail
# Discoverability: `help CMD`, per-command help (usage, flags with text, EXAMPLES, INHERITED FLAGS once), usage errors
# scoped to the command, `hook` hidden, completion scripts that load in their shells, the bare-command guides, every
# error naming its next command, the fact/decision vocabulary, readable log lines, init's next step and plurals.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; export T
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/bus.db"
cd "$T"
# One Python harness for the checks that read help text: run(...) is the CLI, help_(...) its --help.
cat > "$T/h.py" <<'PY'
import json, os, re, runpy, shlex, subprocess, sys, tempfile
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
BIN = os.path.join(os.path.dirname(os.environ["TESTS_DIR"]), "bin", "agentbus")
MOD = runpy.run_path(os.environ.get("AGENTBUS_BIN") or BIN, run_name="agentbus_help_test")
CONTRACT, KINDS = MOD["CONTRACT"], MOD["KINDS"]
def run(*args, env=None, stdin=None, cwd=None):
    e = dict(os.environ); e.update(env or {})
    with tempfile.TemporaryDirectory() as tmp:
        return subprocess.run([*agentbus_argv(), *args], cwd=cwd or tmp, capture_output=True, text=True, env=e, input=stdin, timeout=60)
def help_(*args):
    p = run(*args, "--help")
    if p.returncode != 0 or not p.stdout or p.stderr: fail("%s --help: rc %s %s" % (" ".join(args), p.returncode, p.stderr.strip()))
    return p.stdout
def fail(msg):
    print("FAIL: " + msg); sys.exit(1)
# Every command a person can type: the leaves and the groups, not the hidden ones.
LEAVES = [("join",), ("leave",), ("who",), ("post",), ("inbox",), ("read",), ("ctx", "set"), ("ctx", "get"), ("ctx", "history"),
          ("claim",), ("release",), ("claims",), ("log", "add"), ("log", "show"), ("status",), ("goal",), ("watch",), ("buses",),
          ("init",), ("upgrade",), ("schema",), ("help",), ("completion",), ("skill",), ("setup",), ("doctor",)]
GROUPS = [("ctx",), ("log",)]
PY

echo "TEST 1: agentbus help CMD prints the text CMD --help prints, for every command and subcommand"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
for path in LEAVES + GROUPS:
    a = run("help", *path)
    if a.returncode != 0 or a.stdout != help_(*path): fail("help %s differs from %s --help (rc %s): %s" % (" ".join(path), " ".join(path), a.returncode, a.stderr))
root = run("help")
if root.returncode != 0 or root.stdout != help_(): fail("bare help differs from agentbus --help")
j = json.loads(run("--json", "help", "ctx", "set").stdout)
if j.get("command") != "ctx set" or j.get("text") != help_("ctx", "set"): fail("help --json: " + repr(j)[:200])
for bad in (["help", "nope"], ["help", "hook"], ["help", "ctx", "nope"]):
    p = run(*bad)
    if p.returncode != 2 or p.stdout or "unknown command" not in p.stderr or "See: agentbus" not in p.stderr: fail("help %s: rc %s %r" % (bad[1:], p.returncode, p.stderr))
print("PASS: help CMD equals CMD --help, in text and --json; an unknown command gets a See: line")
PY
ok "help CMD works for every command"

echo "TEST 2: a usage error is the command's own: its usage, its flags, and See: agentbus CMD --help"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
cases = [
    (["--as", "a", "post", "--kind"], "agentbus post", "post", "--to, --kind, --topic, --reply-to, --request-id"),
    (["post", "x", "--bad"], "agentbus post", "post", "unrecognized arguments: --bad"),
    (["ctx", "set"], "agentbus ctx set KEY VALUE", "ctx set", "See: agentbus ctx set --help"),
    (["claim"], "agentbus claim RESOURCE", "claim", "--purpose, --request-id, --ttl-min"),
    (["post", "x", "--to", "a", "--to", "b"], "agentbus post", "post", "leave --to off to tell everyone. Usage: agentbus post"),
    (["inbox", "--before", "x"], "agentbus inbox", "inbox", "unrecognized arguments: --before x"),
    (["read", "--since", "x"], "agentbus read", "read", "not an integer"),
    (["log", "show", "--bogus"], "agentbus log show", "log show", "unrecognized arguments: --bogus"),
]
for args, usage, cmd, more in cases:
    p = run(*args)
    if p.returncode != 2 or p.stdout: fail("%s: rc %s out %r" % (args, p.returncode, p.stdout))
    err = " ".join(p.stderr.split())
    if "Usage: " + usage not in err or "See: agentbus %s --help" % cmd not in err: fail("%s: not scoped to its command: %s" % (args, err))
    if more not in err: fail("%s: lacks %r: %s" % (args, more, err))
    # the old text named agentbus as a whole, with every command in a braces list
    if "{join,leave" in err: fail("%s: usage is agentbus's own: %s" % (args, err))
p = run("--json", "post", "x", "--bad")
e = json.loads(p.stderr)["error"]
if p.returncode != 2 or e["code"] != "bad_input" or "See: agentbus post --help" not in e["message"]: fail("--json usage error: " + p.stderr)
p = run("--project", "who")
if p.returncode != 2 or "unrecognized arguments: --project" not in p.stderr or "See: agentbus --help" not in p.stderr: fail("top-level usage error: " + p.stderr)
p = run("completion")
if p.returncode != 2 or "Usage: agentbus completion {bash,zsh,fish}" not in " ".join(p.stderr.split()): fail("completion without a shell: " + p.stderr)
# `join NAME` is the likeliest first guess and joins as NAME; a different --as is a usage error naming both names.
jdb = {"AGENTBUS_DB": os.path.join(os.environ["T"], "join-name.db")}
p = run("join", "rel-prep", env=jdb)
if p.returncode != 0 or not p.stdout.startswith("joined as rel-prep on ") or "Keep using --as rel-prep" not in p.stdout: fail("join NAME: rc %s %s %s" % (p.returncode, p.stdout, p.stderr))
p = run("--as", "bob", "join", "rel-prep", env=jdb)
err = " ".join(p.stderr.split())
if p.returncode != 2 or p.stdout or "--as bob" not in err or "and rel-prep" not in err or not err.endswith("See: agentbus --as rel-prep join"): fail("join NAME with another --as: rc %s %s" % (p.returncode, err))
e = json.loads(run("--json", "--as", "bob", "join", "rel-prep", env=jdb).stderr)["error"]
if e["code"] != "bad_input" or e["next"] != "agentbus --as rel-prep join" or "--as bob" not in e["message"]: fail("join NAME with another --as --json: " + repr(e))
p = run("join", "--bogus")
if "See: agentbus join --help" not in " ".join(p.stderr.split()): fail("a bad flag on join: " + p.stderr)
p = run("join", "one", "two")
if p.returncode != 2 or "unrecognized arguments: two" not in p.stderr or "give it with --as" in p.stderr: fail("join with two names: " + p.stderr)
if "agentbus join NAME" not in " ".join(help_("join").split()): fail("join --help does not show the join NAME form")
print("PASS: usage errors are scoped to the command; join NAME joins as NAME")
PY
ok "usage errors are scoped"

echo "TEST 3: every command's help has usage, text for each flag and argument, 2 to 3 EXAMPLES that parse, and the inherited flags once"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
parser = MOD["build_parser"]()
def node(path):
    n = parser
    for w in path:
        n = MOD["subparsers_of"](n).choices[w]
    return n
for path in LEAVES + GROUPS:
    name = " ".join(path)
    h = help_(*path)
    if not h.startswith("usage: agentbus " + name): fail("%s: help does not start with its usage: %r" % (name, h[:80]))
    if h.count("INHERITED FLAGS") != 1 or "Your agent identity; overrides" in h: fail("%s: inherited flags are not one short block" % name)
    inherited = h.split("INHERITED FLAGS", 1)[1].split("\n\n", 1)[0].strip().splitlines()
    if len(inherited) != 3: fail("%s: INHERITED FLAGS has %d lines: %r" % (name, len(inherited), inherited))
    for x in MOD["own_actions"](node(path)):
        if not x.help: fail("%s: %s has no help text" % (name, x.option_strings or x.dest))
    ex = MOD["HELP_EXAMPLES"].get(name)
    if not ex or not 2 <= len(ex) <= 3: fail("%s: wants 2 to 3 examples, has %r" % (name, ex))
    if "EXAMPLES" not in h or h.index("EXAMPLES") < h.index("INHERITED FLAGS"): fail("%s: no EXAMPLES after the flags" % name)
    for what, line in ex:
        if line not in h: fail("%s: example missing from help: %s" % (name, line))
        # the example parses with the real parser: drop the shell parts (redirects, source <( ), then the program name
        m = re.search(r"<\((.*)\)", line) or re.search(r'"\$\((.*)\)"', line)
        text = m.group(1) if m else line
        text = re.split(r"\s+[<>]\s", text)[0]
        argv = shlex.split(text)
        assert argv[0] == "agentbus", line
        try:
            parser.parse_args(argv[1:])
        except SystemExit:
            fail("%s: example does not parse: %s" % (name, line))
last = [l for l in help_("post").splitlines() if l.strip()][-1]
if not last.startswith("JSON result: "): fail("the JSON result line is no longer last: " + last)
print("PASS: help structure, examples parse, inherited flags once")
PY
ok "per-command help is complete"

echo "TEST 4: flags that do nothing are gone; argument text fills the gaps"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
for args in (["--as", "a", "ctx", "set", "--limit", "3", "k", "v"], ["--as", "a", "log", "add", "--limit", "3", "w", "d"]):
    p = run(*args)
    if p.returncode != 2 or "unrecognized arguments: --limit" not in p.stderr: fail("%s still takes --limit: rc %s %s" % (args[2:4], p.returncode, p.stderr))
for cmd, flag in (("ctx get", "--limit"), ("ctx history", "--limit"), ("log show", "--limit")):
    if flag not in help_(*cmd.split()): fail("%s lost its %s" % (cmd, flag))
want = {("post",): "The message", ("claim",): "path relative to the bus folder", ("read",): "Only messages with this topic label",
        ("upgrade",): "The folder whose bus to upgrade", ("ctx", "set"): "The fact's value", ("log", "add"): "What happened", ("claim", "--purpose"): "Why you hold it"}
for path, text in want.items():
    h = " ".join(help_(*[w for w in path if not w.startswith("--")]).split())
    if text not in h: fail("%s help lacks %r" % (path, text))
print("PASS")
PY
ok "no no-op flags; the gaps have text"

echo "TEST 5: post --help says what each kind is for"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
h = help_("post")
if "KINDS (--kind)" not in h: fail("post --help has no KINDS section")
section = h.split("KINDS (--kind)", 1)[1].split("\n\n", 1)[0]
for kind in KINDS:
    m = re.search(r"^  %s +(\S.*)$" % kind, section, re.M)
    if not m: fail("post --help gives kind %s no meaning" % kind)
if set(MOD["KIND_MEANINGS"]) != set(KINDS): fail("KIND_MEANINGS and KINDS differ")
print("PASS")
PY
ok "every message kind has a one-line meaning"

echo "TEST 6: hook is hidden from help and from the usage choice list, and is never suggested"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
for args in ([], ["help"]):
    h = help_() if not args else run("help").stdout
    if re.search(r"\bhook\b", h) or "SUPPRESS" in h: fail("agentbus --help shows hook: " + h)
p = run("hoo")   # matched as a word: the public command hooks is not the hidden hook
if re.search(r"\bhook\b", p.stderr) or p.returncode != 2: fail("an unknown command suggests hook: " + p.stderr)
p = run("--as", "a", "hook", "SessionStart")   # still answers, silently
if p.returncode != 0: fail("hook stopped answering: rc %s %s" % (p.returncode, p.stderr))
for sh in ("bash", "zsh", "fish"):
    if re.search(r"\bhook\b", run("completion", sh).stdout): fail("%s completion offers hook" % sh)
print("PASS")
PY
ok "hook is hidden everywhere a person looks"

echo "TEST 7: the completion scripts name every command and flag, come from the parser, and load in their shells"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
if run("completion", "bash").returncode != 0: fail("agentbus completion bash does not exist: " + run("completion", "bash").stderr.strip())
parser = MOD["build_parser"]()
names = MOD["visible_choices"](parser)
for sh in ("bash", "zsh", "fish"):
    p = run("completion", sh)
    if p.returncode != 0 or not p.stdout.strip() or p.stderr: fail("completion %s: rc %s %s" % (sh, p.returncode, p.stderr))
    text = p.stdout
    for n in names:
        if not re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(n), text): fail("%s completion lacks command %s" % (sh, n))
    for flag in ("--request-id", "--takeover", "--ttl-min", "--if-held", "--dry-run", "--agents-md", "--peek"):
        if flag not in text and not (sh == "fish" and flag[2:] in text): fail("%s completion lacks %s" % (sh, flag))
    for kind in KINDS:
        if kind not in text: fail("%s completion lacks the kind %s" % (sh, kind))
bad = run("completion", "powershell")
if bad.returncode != 2 or "bash, zsh, fish" not in bad.stderr.replace("'", "").replace("{", "").replace("}", "") and "bash,zsh,fish" not in bad.stderr and "bash|zsh|fish" not in bad.stderr: fail("an unknown shell: " + bad.stderr)
print("PASS")
PY
for sh in bash zsh fish; do "${AB[@]}" completion "$sh" > "$T/comp.$sh"; done
if command -v bash >/dev/null; then
  bash -n "$T/comp.bash" || fail "bash completion: syntax error"
  # Load it the way the help says, then ask it: it must offer the commands, the flags of the command typed, and the kinds.
  cat > "$T/bash_probe.sh" <<'SH'
eval "$(cat "$1")"
complete -p agentbus | grep -q '_agentbus' || { echo "FAIL: complete -p agentbus did not name _agentbus"; exit 1; }
try() { COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); COMPREPLY=(); _agentbus; echo "${COMPREPLY[*]}"; }
has() { case " $1 " in *" $2 "*) ;; *) echo "FAIL: bash completion for [$3] lacks $2: got [$1]"; exit 1 ;; esac; }
has "$(try agentbus '')" post "agentbus <TAB>"
has "$(try agentbus '')" completion "agentbus <TAB>"
has "$(try agentbus po)" post "agentbus po<TAB>"
has "$(try agentbus post --)" --kind "agentbus post --<TAB>"
has "$(try agentbus post --)" --request-id "agentbus post --<TAB>"
has "$(try agentbus post --kind '')" handoff "agentbus post --kind <TAB>"
has "$(try agentbus --as alice post --)" --reply-to "agentbus --as alice post --<TAB>"
has "$(try agentbus ctx '')" history "agentbus ctx <TAB>"
has "$(try agentbus ctx set --)" --json "agentbus ctx set --<TAB>"
has "$(try agentbus log '')" show "agentbus log <TAB>"
has "$(try agentbus setup '')" codex "agentbus setup <TAB>"
has "$(try agentbus completion '')" fish "agentbus completion <TAB>"
has "$(try agentbus help ctx '')" history "agentbus help ctx <TAB>"
case " $(try agentbus '') " in *" hook "*) echo "FAIL: bash completion offers hook"; exit 1 ;; esac
echo "bash completion answers"
SH
  bash "$T/bash_probe.sh" "$T/comp.bash" || fail "bash completion did not load or answer (above)"
else
  echo "NOTE: bash is not installed; the bash script was not loaded"
fi
if command -v zsh >/dev/null; then
  zsh -n "$T/comp.zsh" || fail "zsh completion: syntax error"
  # Load it the way the help says (after compinit) and see that zsh registered the function for agentbus.
  got=$(zsh -f -c 'autoload -Uz compinit && compinit -u -d "$1/zcompdump" && source <(cat "$2") && print -r -- "${_comps[agentbus]}" && whence -w _agentbus' _ "$T" "$T/comp.zsh" 2>&1) \
    || fail "zsh completion did not load: $got"
  grep -q '^_agentbus$' <<<"$got" && grep -q '_agentbus: function' <<<"$got" || fail "zsh did not register _agentbus for agentbus: $got"
else
  echo "NOTE: zsh is not installed; the zsh script was not loaded"
fi
if command -v fish >/dev/null; then
  fish -n "$T/comp.fish" || fail "fish completion: syntax error"
  fish -c "source $T/comp.fish; complete -c agentbus | grep -q post" || fail "fish did not register the completions"
else
  echo "NOTE: fish is not installed; its script was checked for text only"
  grep -q "^complete -c agentbus" "$T/comp.fish" || fail "fish completion has no complete lines"
  grep -q "^function __agentbus_word" "$T/comp.fish" || fail "fish completion lost its helper"
  [ "$(grep -c '^function ' "$T/comp.fish")" = "$(grep -c '^end$' "$T/comp.fish")" ] || [ "$(grep -c '^end$' "$T/comp.fish")" -ge 1 ] || fail "fish completion: unbalanced function"
fi
ok "completion scripts for bash, zsh and fish are written from the parser and load (where the shell is installed)"

echo "TEST 8: bare agentbus prints the short guide and exits 0; bare ctx and log print their actions"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
p = run()
if p.returncode != 0 or p.stderr: fail("bare agentbus: rc %s %r" % (p.returncode, p.stderr))
for want in ("Start:", "Loop:", "Finish:", "See: agentbus --help"):
    if want not in p.stdout: fail("bare agentbus lacks %r: %s" % (want, p.stdout))
if len(p.stdout.splitlines()) > 12: fail("the bare guide is not short")
for group, actions in (("ctx", ("set", "get", "history")), ("log", ("add", "show"))):
    q = run(group)
    if q.returncode != 0 or q.stderr: fail("bare %s: rc %s %r" % (group, q.returncode, q.stderr))
    for act in actions:
        if not re.search(r"^  %s\b" % act, q.stdout, re.M): fail("bare %s lacks the action %s: %s" % (group, act, q.stdout))
    if q.stdout != help_(group): fail("bare %s is not its help" % group)
j = json.loads(run("--json").stdout)
if j.get("command") is not None or "Start:" not in j.get("text", ""): fail("bare agentbus --json: " + repr(j)[:100])
print("PASS")
PY
ok "bare commands guide instead of failing"

echo "TEST 9: every audited error names its exact next command"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
db = os.environ["AGENTBUS_DB"]
def err(*args, rc=None):
    p = run(*args)
    if p.returncode == 0: fail("%s succeeded" % (args,))
    if rc is not None and p.returncode != rc: fail("%s: rc %s, want %s: %s" % (args, p.returncode, rc, p.stderr))
    return " ".join(p.stderr.split())
assert run("--as", "a", "join").returncode == 0
want = [
    (["--as", "a", "read", "--before", "bad"], "Get one with: agentbus --json read"),
    (["--as", "a", "inbox", "--peek", "--after", "bad"], "Get one with: agentbus --as NAME --json inbox --peek"),
    (["--as", "a", "ctx", "history", "k", "--before", "bad"], "Get one with: agentbus --json ctx history KEY"),
    (["--as", "a", "release"], "See: agentbus --as NAME claims"),
    (["post", "hi"], 'say who you are with --as NAME or AGENTBUS_AGENT=NAME. For example: agentbus --as alice post "schema is ready; tests pass" --to bob --kind handoff'),
    (["claim", "x"], "For example: agentbus --as alice claim src/api/ --purpose"),
    (["ctx", "set", "k", "v"], 'For example: agentbus --as alice ctx set test-command "npm test"'),
    (["--as", "a", "log", "add", "test"], 'log add ACTION needs a detail. Use: agentbus --as NAME log add ACTION "DETAIL"'),
    (["--as", "a", "ctx", "set", "k"], 'ctx set KEY needs a value. Use: agentbus --as NAME ctx set KEY "VALUE"'),
    (["--as", "a", "goal", ""], 'the goal is empty. Use: agentbus --as NAME goal "TEXT"'),
    (["--as", "a", "ctx", "get", "nope"], "no fact named nope. List facts with: agentbus ctx get"),
    (["--as", "a", "read", "--since", "1", "--before", "x"], "Use one: agentbus read --since ID, or agentbus read --before NEXT"),
    (["--as", "a", "inbox", "--after", "x"], "agentbus --as NAME inbox --peek --after NEXT"),
    (["--as", "a", "claim", "/abs"], "For example: agentbus --as NAME claim src/app/ --purpose WHY"),
    (["--as", "a", "claim", "x", "--ttl-min", "0"], "For example: agentbus --as NAME claim PATH --ttl-min 120"),
    (["--as", "a", "ctx", "get", ""], "List facts with: agentbus ctx get"),
]
for args, text in want:
    got = err(*args)
    if text not in got: fail("%s: the error lacks its next step %r: %s" % (args, text, got))
if "log add" in err("--as", "a", "log", "add", "test") and "empty message" in err("--as", "a", "log", "add", "test"):
    fail("log add with no detail still says 'empty message'")
up = os.path.join(os.environ["T"], "upbus"); os.makedirs(up)
assert run("init", up).returncode == 0
p = run("--up", "4", "who", cwd=up, env={"AGENTBUS_DB": ""})
if p.returncode != 3 and p.returncode != 1 or "no bus at --up 4; no such outer bus. See: agentbus buses" not in " ".join(p.stderr.split()): fail("--up past the last bus: rc %s %s" % (p.returncode, p.stderr))
p = run("--up", "4", "buses", cwd=up, env={"AGENTBUS_DB": ""})
if "See: agentbus buses" not in " ".join(p.stderr.split()): fail("buses --up past the last: " + p.stderr)
# a claim conflict shows the purpose as purpose: "..."
assert run("--as", "a", "claim", "src/", "--purpose", "review").returncode == 0
assert run("--as", "b", "join").returncode == 0
got = err("--as", "b", "claim", "src/x.py")
if 'purpose: "review"' not in got: fail("claim conflict does not show purpose: \"review\": " + got)
assert run("--as", "a", "claim", "lib/").returncode == 0
if "(no purpose given)" not in err("--as", "b", "claim", "lib/y.py"): fail("claim conflict without a purpose")
print("PASS")
PY
ok "audited errors name their next command"

echo "TEST 10: vocabulary: fact and decision, never ruling, context or lane in help, the skill or the AGENTS.md block"
"$PY" - <<'PY'
import os; exec(open(os.path.join(os.environ["T"], "h.py")).read())
skill = run("skill").stdout
texts = {"the skill": skill, "the AGENTS.md block": run("skill", "--agents-md").stdout, "agentbus --help": help_()}
for path in LEAVES + GROUPS:
    texts[" ".join(path)] = help_(*path)
for name, t in texts.items():
    t = "\n".join(l for l in t.splitlines() if not l.startswith("JSON result:"))  # the JSON key stays "context"
    for word in (r"\bruling", r"\blane", r"\bcontext key"):
        if re.search(word, t, re.I): fail("%s uses %s" % (name, word))
    if name != "the skill" and re.search(r"\bcontext\b", t):
        fail("%s says context" % name)
if "Shared facts (key/value)" not in help_(): fail("ctx is not 'Shared facts (key/value)' in agentbus --help")
if "== facts" not in run("status").stdout or "== context" in run("status").stdout: fail("status header is not '== facts'")
for must in ("ctx history", "read --since", "request-id", "empty until a lead sets it", "read --topic decision"):
    if must not in skill: fail("the skill lacks %r" % must)
if len(skill.encode()) > 4800: fail("the skill is over its byte cap")
src = open(os.environ.get("AGENTBUS_BIN") or BIN).read()
for n in re.findall(r'die\(f?"([^"]*)"', src):
    if re.search(r"\ba lane\b", n): fail("an error message says lane: " + n)
print("PASS")
PY
ok "vocabulary is fact and decision; agent, not lane"

export AGENTBUS_DB="$T/bus11.db"
echo "TEST 11: log show prints readable lines (no JSON blobs, no dangling colon) and counts read right"
agentbus --as a join --tool claude --branch feat/api >/dev/null
agentbus --as b join >/dev/null
agentbus --as a claim lib/ >/dev/null
agentbus --as a claim src/ --purpose "rate limit" >/dev/null
o=$(outof agentbus log show)
grep -q 'join .*tool=claude branch=feat/api' <<<"$o" || fail "log show: join is not readable: $o"
grep -q '[{}"]' <<<"$(grep ' join ' <<<"$o")" && fail "log show: a join line still holds a JSON blob: $o"
grep -q 'join .*(no details)$' <<<"$o" || fail "log show: a join with no details reads '(no details)': $o"
grep -E ': *$' <<<"$o" && fail "log show: a line ends in a dangling colon: $o"
grep -q 'lib/ until ' <<<"$o" || fail "log show: the claim line: $o"
grep -q 'src/ until .*: rate limit' <<<"$o" || fail "log show: a claim purpose is kept: $o"
outof agentbus --json log show | "$PY" -c 'import json,sys; sys.exit(1 if any(r["action"]=="claim" and r["detail"].rstrip().endswith(":") for r in json.load(sys.stdin)["items"]) else 0)' || fail "log stores a dangling colon for a claim without a purpose"
# rows an older copy wrote: a bare ": " and "1 claims" read right too (the stored text is not touched)
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO log(ts,agent,action,detail) VALUES(?,?,?,?)", ("2026-01-01T00:00:00Z","old","claim","old.txt until 2026-01-01T02:00:00Z: ")); c.execute("INSERT INTO log(ts,agent,action,detail) VALUES(?,?,?,?)", ("2026-01-01T00:00:01Z","old","leave","released 1 claims: old.txt")); c.commit()' "$AGENTBUS_DB"
o=$(outof agentbus log show --limit 50)
grep -q 'old.txt until 2026-01-01T02:00:00Z$' <<<"$o" || fail "log show: an old row keeps its dangling colon: $o"
grep -q 'released 1 claim: old.txt' <<<"$o" || fail "log show: an old row says 1 claims: $o"
[ "$(outof agentbus --json log show --limit 50 | "$PY" -c 'import json,sys; print([r["detail"] for r in json.load(sys.stdin)["items"] if r["action"]=="join"][0])')" = '{"tool": "claude", "model": null, "branch": "feat/api", "role": null}' ] || fail "log show --json changed the stored join detail"
o=$(outof agentbus --as a release lib/); [ "$o" = "released lib/" ] || fail "release one: $o"
agentbus --as a claim lib/ >/dev/null
o=$(outof agentbus --as a release --all); [ "$o" = "$(printf 'released 2 claims\n  lib/\n  src/')" ] || [ "$(head -1 <<<"$o")" = "released 2 claims" ] || fail "release --all: $o"
agentbus --as a claim lib/ >/dev/null
o=$(outof agentbus --as a release --all); [ "$(head -1 <<<"$o")" = "released 1 claim" ] || fail "release --all with one claim: $o"
o=$(outof agentbus --as a release --all); [ "$o" = "released 0 claims" ] || fail "release --all with none: $o"
agentbus --as a claim lib/ >/dev/null
o=$(outof agentbus --as a leave); [ "$(head -1 <<<"$o")" = "left as a, released 1 claim" ] || fail "leave with one claim: $o"
grep -q 'released 1 claim:' <<<"$(outof agentbus log show)" || fail "the log records 'released 1 claim'"
ok "log show is readable and the counts read right"

echo "TEST 12: init prints the next step, and the setup commands when nothing is set up"
mkdir "$T/p1" "$T/p2"
o=$(outof agentbus init "$T/p1")
grep -Eq '^next: (install agentbus so your agents have it on PATH \(see the README\), then )?agentbus --as YOUR_NAME join$' <<<"$o" || fail "init lacks the join step: $o"
grep -q '^next: agentbus setup claude' <<<"$o" && grep -q '^next: agentbus setup codex' <<<"$o" || fail "init does not suggest setup when none is detected: $o"
agentbus setup claude >/dev/null
o=$(outof agentbus init "$T/p2")
grep -q 'agentbus setup' <<<"$o" && fail "init still suggests setup after setup claude: $o"
grep -Eq '^next: (install agentbus so your agents have it on PATH \(see the README\), then )?agentbus --as YOUR_NAME join$' <<<"$o" || fail "init lacks the join step after setup: $o"
ok "init says what to do next"

all_passed "All help tests passed"
