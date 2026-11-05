#!/usr/bin/env python3
"""python3 scripts/release_check.py [--tag vX.Y.Z]
python3 scripts/release_check.py --lines vX.Y.Z [--wheel]      print the two install lines the README shows for the tag

Every check a release needs, in one place; RELEASING.md is the checklist around it. Prints one line per
problem and exits 1, or prints `release check passed: X.Y.Z`. Checks:
  - the tag is vX.Y.Z or vX.Y.ZrcN (no a, b, dev or other shape), and __version__ is exactly the tag
    without the v: a release candidate builds 0.2.0rc1, never 0.2.0. Without --tag, __version__ may also
    be a development version (0.2.0.dev0, main between releases): it then has the CHANGELOG heading and
    the install pins of the last final release, as an rc's pins do;
  - the tagged commit is an ancestor of origin/main (releases come from main; with --tag only);
  - the first CHANGELOG heading after Unreleased is `## X.Y.Z - YYYY-MM-DD` for the final version;
  - every install line in README.md and docs/ pins v<version> for a final tag, and the LAST FINAL release
    (the newest tag in tests/released_commands.txt) for an rc: main's public README must never point at
    a tag that does not exist yet, so the pin bump and the final tag land in one commit;
  - .claude-plugin/plugin.json has the version and marketplace.json names the plugin with a git source
    whose ref is always a release tag, never main, a branch or a ./ source (skipped when the files are absent):
    a release or release-candidate tree (and any --tag run) names its own tag; a development build keeps the
    last published plugin release, the highest final tag that carries .claude-plugin/plugin.json, so a plugin
    installed from the default branch between releases never runs untagged code. Before any plugin release
    exists, a development build names the tag being prepared (v0.2.0 for 0.2.0.dev0): that tag does not exist
    yet, so the install fails until the release, and it never runs main. Only the release-prep commit moves
    the ref;
  - the lines that name the pinned release in prose (README.md "Setup in this release (vX.Y.Z)", SECURITY.md
    "pins vX.Y.Z today") name the release the install lines pin;
  - the current SKILL.md and AGENTS.md block hashes are in SKILL_SHA256_HISTORY and AGENTS_SHA256_HISTORY
    (python3 scripts/embed_skill.py --release);
  - DIST_NAME in bin/agentbus equals the name in pyproject.toml (the update check names no other project);
  - a final tag is not below the highest final tag that already exists (git tag --list 'v*', rc tags
    ignored), so GitHub's "latest release" (the most recent by date) is also the highest final version;
  - the README's install lines are the ones --lines prints for the pinned release: the release wheel's URL once the
    release is listed in tests/released_wheels.txt (releases that publish a wheel and SHA256SUMS), the git+ lines
    before; every wheel URL in README.md and docs/ names the pinned tag in its path and its file name;
  - git status is clean.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_URL = r"git\+https://github\.com/wickdninja/agentbus(@[^\s`\"')]*)?"
WHEEL_URL = r"https://github\.com/wickdninja/agentbus/releases/download/(v[^/\s`\"')]+)/agentbus-([^/\s`\"')]+?)-py3-none-any\.whl"


def wheel_tags():
    """The tags in tests/released_wheels.txt: releases that publish a wheel and SHA256SUMS (one `vX.Y.Z` per line)."""
    try:
        return {ln.split()[0] for ln in read("tests", "released_wheels.txt").splitlines() if ln.strip() and not ln.startswith("#")}
    except OSError:
        return set()


def plugin_release_tags():
    """The final release tags (vX.Y.Z) whose tree carries .claude-plugin/plugin.json, lowest first: the releases a plugin
    install can come from."""
    listed = subprocess.run(["git", "-C", ROOT, "tag", "--list", "v*"], capture_output=True, text=True).stdout.split()
    finals = [t for t in listed if re.fullmatch(r"v(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})", t)]
    carries = [t for t in finals if subprocess.run(["git", "-C", ROOT, "cat-file", "-e", f"{t}:.claude-plugin/plugin.json"],
                                                  capture_output=True).returncode == 0]
    return sorted(carries, key=lambda t: tuple(int(x) for x in t[1:].split(".")))


def install_lines(tag, wheel):
    """(the uv line, the pipx line) of the README for the tag. The wheel form installs the release's wheel by URL (no
    build, no package index; the file `agentbus update` installs); the git form builds from source."""
    if wheel:
        url = f"https://github.com/wickdninja/agentbus/releases/download/{tag}/agentbus-{tag[1:]}-py3-none-any.whl"
        return f"uv tool install {url}", f"pipx install --force {url}"
    return f"uv tool install git+https://github.com/wickdninja/agentbus@{tag}", f"pipx install --force git+https://github.com/wickdninja/agentbus@{tag}"


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tag", help="the tag being released, for example v0.2.0 or v0.2.0rc1")
    ap.add_argument("--lines", metavar="TAG", help="print the README install lines for TAG (wheel URL if TAG is in tests/released_wheels.txt or with --wheel)")
    ap.add_argument("--wheel", action="store_true", help="with --lines: the wheel-URL form even before the tag is listed")
    a = ap.parse_args()
    if a.lines:
        if not re.fullmatch(r"v\d+\.\d+\.\d+", a.lines):
            sys.exit(f"release_lines: {a.lines} is not a final release tag like v0.2.0")
        print("\n".join(install_lines(a.lines, a.wheel or a.lines in wheel_tags())))
        return
    problems = []
    src = read("bin", "agentbus")
    m = re.search(r'^__version__ = "([^"]+)"$', src, re.M)
    if not m:
        sys.exit("release check failed: no __version__ in bin/agentbus")
    version = m.group(1)
    final = re.sub(r"rc\d+$", "", version)  # the version the CHANGELOG and the README pins name
    dev = re.fullmatch(r"\d+\.\d+\.\d+\.dev\d+", version) is not None
    tag = a.tag or f"v{version}"
    if a.tag:
        if not re.fullmatch(r"v\d+\.\d+\.\d+(rc\d+)?", a.tag):
            problems.append(f"the tag {a.tag} is not a release tag (vX.Y.Z or vX.Y.ZrcN)")
        elif a.tag != f"v{version}":
            problems.append(f"the tag {a.tag} does not match __version__ {version} (bin/agentbus)")
        rev = f"refs/tags/{a.tag}^{{commit}}"
        if subprocess.run(["git", "-C", ROOT, "rev-parse", "-q", "--verify", rev], capture_output=True).returncode != 0:
            rev = "HEAD"
        if subprocess.run(["git", "-C", ROOT, "rev-parse", "-q", "--verify", "refs/remotes/origin/main"], capture_output=True).returncode != 0:
            problems.append("origin/main is not available (git fetch origin main), so the tag cannot be checked against main")
        elif subprocess.run(["git", "-C", ROOT, "merge-base", "--is-ancestor", rev, "refs/remotes/origin/main"]).returncode != 0:
            problems.append(f"the tagged commit is not an ancestor of origin/main; releases come from main")

    dist = re.search(r'^DIST_NAME = "([^"]+)"$', src, re.M)
    try:
        proj = re.search(r'^\[project\]\n(?:.*\n)*?name = "([^"]+)"', read("pyproject.toml"), re.M)
    except OSError:
        proj = None
    if not dist:
        problems.append("bin/agentbus has no DIST_NAME")
    elif not proj:
        problems.append("pyproject.toml has no [project] name")
    elif dist.group(1) != proj.group(1):
        problems.append(f"DIST_NAME is {dist.group(1)}, but pyproject.toml names the project {proj.group(1)}")

    if a.tag and re.fullmatch(r"v\d+\.\d+\.\d+", a.tag):
        listed = subprocess.run(["git", "-C", ROOT, "tag", "--list", "v*"], capture_output=True, text=True).stdout.split()
        finals = [t for t in listed if re.fullmatch(r"v(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})", t) and t != a.tag]
        key = lambda t: tuple(int(x) for x in t[1:].split("."))
        if finals and key(a.tag) < key(max(finals, key=key)):
            problems.append(f"the tag {a.tag} is below the highest final release tag {max(finals, key=key)}; "
                            "GitHub's latest release must be the highest final version")

    pin_to = final
    if version != final or (dev and not a.tag):  # an rc or a dev build: the README keeps naming the last final release
        tags = []
        try:
            for line in read("tests", "released_commands.txt").splitlines():
                m = re.match(r"v(\d+\.\d+\.\d+):", line)
                if m:
                    tags.append(tuple(int(x) for x in m.group(1).split(".")))
        except OSError:
            pass
        if tags:
            pin_to = ".".join(str(x) for x in max(tags))
            # The line comes from a file this very commit may edit, so the release must also exist as a tag.
            if subprocess.run(["git", "-C", ROOT, "rev-parse", "-q", "--verify", f"refs/tags/v{pin_to}"], capture_output=True).returncode != 0:
                problems.append(f"v{pin_to} is not a git tag (git fetch --tags); an rc's README must pin a final release that exists")
        else:
            problems.append("tests/released_commands.txt lists no final release, so the pin for an rc is unknown")
    if dev and not a.tag:
        final = pin_to  # nothing is being released: the newest CHANGELOG heading is the last release

    headings = re.findall(r"^## (.+)$", read("CHANGELOG.md"), re.M)
    first = next((h for h in headings if not h.lower().startswith("unreleased")), None)
    if first is None or not re.fullmatch(r"\d+\.\d+\.\d+ - \d{4}-\d{2}-\d{2}", first):
        problems.append(f"the first CHANGELOG.md heading after Unreleased is '{first}', not '## {final} - YYYY-MM-DD'")
    elif first.split(" - ")[0] != final:
        problems.append(f"the first CHANGELOG.md heading is for {first.split(' - ')[0]}, not {final}")

    pinned = 0
    names = ["README.md"]
    for d, _, files in os.walk(os.path.join(ROOT, "docs")):
        names += [os.path.relpath(os.path.join(d, f), ROOT) for f in files if f.endswith(".md")]
    for name in sorted(names):
        for pin in re.finditer(REPO_URL, read(name)):
            pinned += 1
            if pin.group(1) != f"@v{pin_to}":
                why = "" if pin_to == final else " (the last final release; the final tag moves it)"
                problems.append(f"{name}: the install line {pin.group(0)} must pin @v{pin_to}{why}")
        for pin in re.finditer(WHEEL_URL, read(name)):
            pinned += 1
            if pin.group(1) != f"v{pin_to}" or pin.group(2) != pin_to:
                problems.append(f"{name}: the wheel URL {pin.group(0)} must name v{pin_to} in its path and {pin_to} in its file name")
    if pinned == 0:
        problems.append("README.md has no pinned install line (" + install_lines("v" + pin_to, f"v{pin_to}" in wheel_tags())[0] + ")")
    # The README's first-install lines are exactly the generated ones, in the form the pinned release supports.
    wheel = f"v{pin_to}" in wheel_tags()
    readme = read("README.md")
    for line in install_lines(f"v{pin_to}", wheel):
        if line not in readme:
            problems.append(f"README.md must carry the install line: {line} (python3 scripts/release_check.py {'--wheel ' if wheel else ''}--lines v{pin_to})")
    if wheel and re.search(REPO_URL, readme):
        problems.append(f"README.md still has a git+ install line, but v{pin_to} publishes a wheel (tests/released_wheels.txt): use the wheel URL")

    # Prose that names the pinned release goes stale silently: each such line must name the release the install lines pin.
    for name, rule in (("README.md", r"Setup in this release \((v[^)\s]*)\)"), ("SECURITY.md", r"pins (v\d+\.\d+\.\d+(?:rc\d+)?) today")):
        try:
            text = read(name)
        except OSError:
            continue
        for line in text.splitlines():
            for named in re.findall(rule, line):
                if named != f"v{pin_to}":
                    problems.append(f"{name}: '{re.search(rule, line).group(0)}' names {named}, but the install lines pin v{pin_to}")

    plugin = os.path.join(ROOT, ".claude-plugin", "plugin.json")
    market = os.path.join(ROOT, ".claude-plugin", "marketplace.json")
    if os.path.exists(plugin):
        pv = json.load(open(plugin, encoding="utf-8")).get("version")
        if pv != version:
            problems.append(f".claude-plugin/plugin.json version is {pv}, not {version}")
    if os.path.exists(market):
        data = json.load(open(market, encoding="utf-8"))
        entries = [p for p in data.get("plugins", []) if p.get("name") == "agentbus"]
        if not entries:
            problems.append(".claude-plugin/marketplace.json does not name the agentbus plugin")
        # The ref always names a published tag; only the release-prep commit moves it. A tagged or release-versioned
        # tree names exactly its own tag. A development build (main between releases) keeps the last plugin release:
        # plugin users installing from the default branch must not run untagged code.
        want_ref, why = tag, ""
        if dev and not a.tag:
            have = plugin_release_tags()
            if have:
                want_ref, why = have[-1], " (the last plugin release; the release-prep commit moves it)"
            else:
                want_ref, why = "v" + re.sub(r"\.dev\d+$", "", version), " (no tag carries the plugin yet, so the tag being prepared)"
        for p in entries:
            s = p.get("source")
            if isinstance(s, str):
                problems.append(f".claude-plugin/marketplace.json source '{s}' is a path; it must be a git source with ref {want_ref}")
            elif not isinstance(s, dict) or s.get("ref") != want_ref:
                problems.append(f".claude-plugin/marketplace.json source ref is {s.get('ref') if isinstance(s, dict) else s}, not {want_ref}{why}")

    skill = open(os.path.join(ROOT, "skills", "agentbus", "SKILL.md"), "rb").read()
    history = re.search(r"^SKILL_SHA256_HISTORY = \((.*?)^\)", src, re.S | re.M)
    hashes = re.findall(r'"([0-9a-f]{64})"', history.group(1)) if history else []
    if hashlib.sha256(skill).hexdigest() not in hashes:
        problems.append("the current skills/agentbus/SKILL.md hash is not in SKILL_SHA256_HISTORY; run python3 scripts/embed_skill.py --release")

    import ast
    snippet = None
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "AGENTS_SNIPPET" for t in node.targets):
            snippet = ast.literal_eval(node.value)
    agents = re.search(r"^AGENTS_SHA256_HISTORY = \((.*?)^\)", src, re.S | re.M)
    agent_hashes = re.findall(r'"([0-9a-f]{64})"', agents.group(1)) if agents else []
    if snippet is None or hashlib.sha256(snippet.encode("utf-8")).hexdigest() not in agent_hashes:
        problems.append("the current AGENTS.md block hash is not in AGENTS_SHA256_HISTORY; run python3 scripts/embed_skill.py --release")

    status = subprocess.run(["git", "-C", ROOT, "status", "--porcelain"], capture_output=True, text=True)
    if status.returncode != 0:
        problems.append("git status failed: " + status.stderr.strip())
    elif status.stdout.strip():
        problems.append("git status is not clean (commit or remove): " + ", ".join(l[3:] for l in status.stdout.splitlines()[:5]))

    if problems:
        for p in problems:
            print("release check failed: " + p)
        sys.exit(1)
    print(f"release check passed: {version}")


if __name__ == "__main__":
    main()
