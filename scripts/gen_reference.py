#!/usr/bin/env python3
"""Render the machine-contract tables of docs/reference.md from the registry in bin/agentbus.

    python3 scripts/gen_reference.py           rewrite the generated blocks in place
    python3 scripts/gen_reference.py --check   exit 1 (and say which blocks) when the file is stale
    python3 scripts/gen_reference.py --file PATH   work on another copy of the page (tests)

A generated block sits between `<!-- generated:NAME -->` and `<!-- /generated:NAME -->`. Everything
between the markers is replaced; the prose around them is written by hand. The registry is read by
running `agentbus schema --json`, so the tables document what the tool says, not a second copy.
AGENTBUS_BIN (a copy of the script) or AGENTBUS_CMD (an installed command) pick the tool, as in tests.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REFERENCE = os.path.join(ROOT, "docs", "reference.md")


def tool_argv():
    cmd = os.environ.get("AGENTBUS_CMD")
    if cmd:
        return cmd.split()
    return [os.environ.get("PYTHON") or "python3", os.environ.get("AGENTBUS_BIN") or os.path.join(ROOT, "bin", "agentbus")]


def load_schema():
    env = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_") or k in ("AGENTBUS_CMD", "AGENTBUS_BIN")}
    with tempfile.TemporaryDirectory() as home:
        env["HOME"] = home
        p = subprocess.run(tool_argv() + ["--json", "schema"], cwd=home, env=env, capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        sys.exit("gen_reference: `agentbus --json schema` failed: " + p.stderr.strip())
    return json.loads(p.stdout)


def type_text(schema):
    """A schema as one phrase, the same wording as the --help result line."""
    if "$ref" in schema:
        return schema["$ref"].rsplit("/", 1)[-1]
    if "anyOf" in schema:
        return " or ".join(type_text(s) for s in schema["anyOf"])
    t = schema.get("type")
    if isinstance(t, list):
        return " or ".join(t)
    if t == "array":
        return "[" + type_text(schema["items"]) + "]"
    if t == "object" and "required" in schema:
        return "{" + ", ".join('"%s": %s' % (k, type_text(schema["properties"][k])) for k in schema["required"]) + "}"
    return t or "any"


def cell(text):
    return str(text).replace("|", "\\|")


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    out += ["| " + " | ".join(cell(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def block_results(doc):
    rows = []
    for name, c in doc["commands"].items():
        text = c["help"].split("JSON result: ", 1)[1].rsplit(". Retry: ", 1)[0]
        rows.append(["`%s`" % name, "`%s`" % text])
    return table(["Command", "`--json` result"], rows)


def block_objects(doc):
    rows = []
    for name, o in doc["objects"].items():
        if name == "Envelope":
            continue
        fields = ", ".join("`%s`%s" % (k, "" if k in o["required"] else " (optional)") for k in o["properties"])
        rows.append(["`%s`" % name, fields])
    return table(["Object", "Fields"], rows)


def block_errors(doc):
    rows = []
    for code, e in doc["errors"].items():
        fields = ", ".join(["`%s`" % f for f in e["fields"]] + ["`%s` (optional)" % f for f in e.get("optional_fields", [])]) or "none"
        rows.append(["`%s`" % code, e["exit"], "yes" if e["retryable"] else "no", fields, e["meaning"] + " " + e["action"]])
    return table(["Code", "Exit", "Retryable", "Extra fields", "Meaning and what to do"], rows)


def block_exit_codes(doc):
    return table(["Exit", "Meaning"], [["`%s`" % k, v] for k, v in doc["exit_codes"].items()])


def block_retry(doc):
    rows = []
    for name, c in doc["commands"].items():
        r = c["retry"]
        how = r["how"]
        for flag, sub in r.get("with", {}).items():
            how += "; with `%s`: %s (%s)" % (flag, sub["class"].replace("_", " "), sub["how"])
        rows.append(["`%s`" % name, r["class"].replace("_", " "), how])
    return table(["Command", "Class", "How to retry safely"], rows)


def block_env(doc):
    return table(["Variable", "Meaning", "Default"], [["`%s`" % k, v["meaning"], v["default"]] for k, v in doc["env"].items()])


def block_error_fields(doc):
    return table(["Field", "Type", "Meaning"], [["`%s`" % k, v["type"], v["meaning"]] for k, v in doc["error_fields"].items()])


BLOCKS = {"error-fields": block_error_fields, "results": block_results, "objects": block_objects, "errors": block_errors,
          "exit-codes": block_exit_codes, "retry": block_retry, "env": block_env}


def render(text, doc):
    """text with every generated block rewritten; also the names found, to catch a missing marker."""
    found = []

    def one(m):
        name = m.group(1)
        if name not in BLOCKS:
            sys.exit("gen_reference: unknown block %r in docs/reference.md" % name)
        found.append(name)
        return "<!-- generated:%s -->\n%s\n<!-- /generated:%s -->" % (name, BLOCKS[name](doc), name)

    out = re.sub(r"<!-- generated:([a-z-]+) -->\n(?:.*?\n)?<!-- /generated:\1 -->", one, text, flags=re.S)
    missing = sorted(set(BLOCKS) - set(found))
    if missing:
        sys.exit("gen_reference: docs/reference.md has no marker for: " + ", ".join(missing))
    return out


def main(argv):
    argv = list(argv)
    check = "--check" in argv
    path = REFERENCE
    if check:
        argv.remove("--check")
    if len(argv) == 2 and argv[0] == "--file":
        path = argv[1]
    elif argv:
        sys.exit(__doc__)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    new = render(text, load_schema())
    if check:
        if new != text:
            stale = [n for n in BLOCKS if render_block(text, n) != render_block(new, n)]
            sys.exit("gen_reference: %s is stale (%s); run: python3 scripts/gen_reference.py" % (path, ", ".join(stale)))
        print("reference tables are current")
        return
    if new != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print("rewrote " + path)
    else:
        print("reference tables are current")


def render_block(text, name):
    m = re.search(r"<!-- generated:%s -->\n((?:.*?\n)?)<!-- /generated:%s -->" % (name, name), text, re.S)
    return m.group(1).rstrip("\n") if m else None


if __name__ == "__main__":
    main(sys.argv[1:])
