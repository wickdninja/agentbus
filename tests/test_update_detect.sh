#!/bin/bash
set -euo pipefail
# How update tells where it was installed from (plan 13, Design 3): one fake install per row of the table. The method
# is read from `update --check --json` (install.method); only the canonical repository's uv, pipx and pip installs
# ever get an installer argv. The lookup answers from tests/fixtures/release_server.py.
. "$(dirname "$0")/update_lib.sh"
T=$(mktemp -d); trap 'stop_servers; rm -rf "$T"' EXIT
mkdir "$T/srv"; start_server "$T/srv"; rel_latest 0.3.0
export CLAUDE_CONFIG_DIR="$T/cc"

# probe: `update --check --json` of the current case, as "method|url|argv0|commands" (empty fields as -).
probe() {
  ab update --check --json | "$PY" -I -c '
import json, sys
d = json.load(sys.stdin)
print("|".join([d["install"]["method"], d["install"]["url"] or "-", (d["argv"] or ["-"])[0].rsplit("/", 1)[-1],
                (d["commands"] or ["-"])[0]]))'
}
want() {  # NAME METHOD-AND-REST
  local got; got=$(probe)
  [ "$got" = "$2" ] || fail "$1: got '$got', wanted '$2'"
}

echo "TEST 1: one fake install per method gives its row, and its installer (argv names the repository at a v tag)"
new_case uv uv; want "uv" "uv|$REPO_URL|uv|-"
new_case pipx pipx; want "pipx" "pipx|$REPO_URL|pipx|-"
new_case pip pip; want "pip" "pip|$REPO_URL|python|-"
out=$(ab update --check --json | "$PY" -I -c 'import json,sys; print(" ".join(json.load(sys.stdin)["argv"]))')
grep -qF -- "-I -m pip install --upgrade git+$REPO_URL@v0.3.0" <<<"$out" || fail "pip argv: $out"
ok "uv, pipx and pip each run their own installer"

echo "TEST 2: the .git suffix is stripped before the URL is compared; a fork gets a printed line and no argv"
new_case dotgit uv 0.2.0 "$REPO_URL.git"; want "dot git" "uv|$REPO_URL|uv|-"
new_case fork uv 0.2.0 "https://github.com/someone/agentbus"
want "fork" "uv|https://github.com/someone/agentbus|-|uv tool install --force git+https://github.com/someone/agentbus@v0.3.0"
ok "the canonical URL with .git runs; a fork prints its own --force line"

echo "TEST 3: no direct_url, an archive install and an EXTERNALLY-MANAGED python are unknown (the README lines are printed)"
new_case nodirect uv 0.2.0 ""; want "no direct_url" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
new_case archive uv; printf '{"url": "%s/archive/v0.2.0.zip", "archive_info": {}}\n' "$REPO_URL" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
want "archive_info" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
new_case managed pip; : >"$PREFIX/EXTERNALLY-MANAGED"
want "externally managed" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
ok "unknown installs never get an argv"

echo "TEST 4: a dist-info whose RECORD does not list this file gives unknown; the matching one (control) gives uv"
new_case record uv
sed -i.bak 's/^agentbus.py,,$/other.py,,/' "$SITE/agentbus-0.2.0.dist-info/RECORD"; rm -f "$SITE/agentbus-0.2.0.dist-info/RECORD.bak"
want "RECORD without the file" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
printf 'agentbus.py,,\n' >"$SITE/agentbus-0.2.0.dist-info/RECORD"
want "RECORD with the file (control)" "uv|$REPO_URL|uv|-"
ok "only a RECORD that lists the running file counts"

echo "TEST 5: a clone (the script beside pyproject.toml and .git) and an editable install are clones: git commands, no argv"
new_case clone uv
mkdir -p "$C/clone/bin" "$C/clone/.git"; sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$UPDATE_SRC" >"$C/clone/bin/agentbus"; : >"$C/clone/pyproject.toml"
got=$(cd "$CWD" && "$PREFIX/bin/python" "$C/clone/bin/agentbus" update --check --json | "$PY" -I -c 'import json,sys; d=json.load(sys.stdin); print(d["install"]["method"], d["argv"], d["commands"])')
[ "$got" = "clone None ['git -C $(cd "$C/clone" && pwd -P) fetch --tags', 'git -C $(cd "$C/clone" && pwd -P) checkout v0.3.0']" ] || fail "clone: $got"
new_case editable uv; printf '{"url": "file:///src/agentbus", "dir_info": {"editable": true}}\n' >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
got=$(probe | cut -d'|' -f1); [ "$got" = clone ] || fail "editable: $got"
ok "a clone and an editable install print git commands"

echo "TEST 6: a project copy is refused with the exact line, for update and update --check"
new_case project uv; new_bus "$C/proj"
for flags in "" "--check"; do
  err=$(cd "$C/proj" && "$PREFIX/bin/python" "$C/proj/.agentbus/bin/agentbus" update $flags 2>&1 >/dev/null) && fail "project copy ran update $flags"
  grep -qF "update runs from the installed agentbus, not a project copy. Run: agentbus update" <<<"$err" || fail "project copy message: $err"
done
ok "refused"

all_passed "All update detection tests passed"
