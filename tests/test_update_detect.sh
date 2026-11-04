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
print("|".join([d["install"]["method"], d["install"]["url"] or "-", (d["argv"] or (d["download"] or {}).get("install_with") or ["-"])[0].rsplit("/", 1)[-1],
                (d["commands"] or ["-"])[0]]))'
}
want() {  # NAME METHOD-AND-REST
  local got; got=$(probe)
  [ "$got" = "$2" ] || fail "$1: got '$got', wanted '$2'"
}

echo "TEST 1: one fake install per method gives its row, and its installer (argv names the release wheel)"
new_case uv uv; want "uv" "uv|$REPO_URL|uv|-"
new_case pipx pipx; want "pipx" "pipx|$REPO_URL|pipx|-"
new_case pip pip; want "pip" "pip|$REPO_URL|python|-"
out=$(ab update --check --json | "$PY" -I -c 'import json,sys; d=json.load(sys.stdin); assert d["argv"] is None, d; print(" ".join(d["download"]["install_with"]), d["download"]["wheel"])')
grep -qF -- "-I -m pip install --upgrade https://127.0.0.1:$PORT/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl" <<<"$out" || fail "pip plan: $out"
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

echo "TEST 3b: an install from a release wheel (what update itself installs) is recognised; a wheel from anywhere else is not"
new_case wheel uv; printf '{"url": "file://%s/downloads/agentbus-0.2.0-py3-none-any.whl", "archive_info": {"hash": "sha256=00"}}\n' "$(cache_path)" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
want "release wheel" "uv|$REPO_URL|uv|-"
printf '{"url": "file://%s/dl/agentbus-0.2.0-py3-none-any.whl", "archive_info": {}}\n' "$HOME" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
want "a wheel with the release name from a folder update does not use" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
printf '{"url": "file://%s/downloads/agentbus-0.2.0-py3-none-any.whl", "archive_info": {}}\n' "$HOME/elsewhere/agentbus" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
want "a dev wheel in another cache folder" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
printf '{"url": "file://%s/dl/other-0.2.0-py3-none-any.whl", "archive_info": {}}\n' "$HOME" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
want "another wheel" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
printf '{"url": "https://example.invalid/agentbus-0.2.0-py3-none-any.whl", "archive_info": {}}\n' >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
want "a wheel from a web address" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
ok "only the wheel update itself downloaded (into its own downloads folder) counts"

echo "TEST 3c: the README's first install (the release page URL, as uv and pipx record it) is a release install; lookalikes are not"
RELURL="$REPO_URL/releases/download/v0.2.0/agentbus-0.2.0-py3-none-any.whl"
for m in uv pipx pip; do
  new_case "relurl-$m" "$m"; printf '{"url": "%s", "archive_info": {"hash": "sha256=00"}}\n' "$RELURL" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
  case $m in pip) a0=python ;; *) a0=$m ;; esac
  want "release URL by $m" "$m|$REPO_URL|$a0|-"
done
new_case relurl-plan uv; printf '{"url": "%s", "archive_info": {}}\n' "$RELURL" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
out=$(ab update --check --json | "$PY" -I -c 'import json,sys; d=json.load(sys.stdin); print(d["install"]["url"], d["download"]["install_with"][1:3], d["download"]["wheel"].rsplit("/", 1)[-1])') || fail "plan of a release URL install"
grep -qF "$REPO_URL ['tool', 'install'] agentbus-0.3.0-py3-none-any.whl" <<<"$out" || fail "a release URL install did not get the wheel installer: $out"
NOT="unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
relcase() {  # NAME URL [EXTRA-JSON]: a recorded URL that must not count
  new_case relurl-x uv; printf '{"url": "%s", "archive_info": {}%s}\n' "$2" "${3:-}" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
  want "$1" "$NOT"
}
relcase "a fork's release URL" "https://github.com/someone/agentbus/releases/download/v0.2.0/agentbus-0.2.0-py3-none-any.whl"
relcase "another host" "https://example.invalid/wickdninja/agentbus/releases/download/v0.2.0/agentbus-0.2.0-py3-none-any.whl"
relcase "a lookalike repository" "https://github.com/wickdninja/agentbus-evil/releases/download/v0.2.0/agentbus-0.2.0-py3-none-any.whl"
relcase "a lookalike path" "$REPO_URL/raw/v0.2.0/agentbus-0.2.0-py3-none-any.whl"
relcase "a query string" "$RELURL?x=1"
relcase "a fragment" "$RELURL#sha256=00"
relcase "a tag that is not the wheel's version" "$REPO_URL/releases/download/v0.3.0/agentbus-0.2.0-py3-none-any.whl"
relcase "a wheel for another name" "$REPO_URL/releases/download/v0.2.0/other-0.2.0-py3-none-any.whl"
relcase "a tag outside the release shape" "$REPO_URL/releases/download/v0.2/agentbus-0.2-py3-none-any.whl"
relcase "a path after the wheel" "$RELURL/extra"
relcase "plain http" "http://github.com/wickdninja/agentbus/releases/download/v0.2.0/agentbus-0.2.0-py3-none-any.whl"
new_case relurl-noinfo uv; printf '{"url": "%s"}\n' "$RELURL" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
want "the release URL without archive_info" "$NOT"
ok "the documented first install is recognised and updated with the wheel installer; forks, other hosts and lookalikes are not"

echo "TEST 3d: update --check sends an install that can update itself to 'agentbus update', and any other to its printed commands"
new_case check-uv uv
out=$(ab update --check) || fail "check of a uv install"
grep -qxF "Run: agentbus update" <<<"$out" || fail "update --check did not name agentbus update for an install that can update itself: $out"
for kind in nodirect fork; do
  case $kind in nodirect) new_case "check-$kind" uv 0.2.0 "" ;; *) new_case "check-$kind" uv 0.2.0 "https://github.com/someone/agentbus" ;; esac
  out=$(ab update --check) || fail "check of a $kind install"
  grep -qxF "Run: agentbus update" <<<"$out" && fail "update --check sent a $kind install to agentbus update, which only exits manual_step: $out"
  grep -qF "  uv tool install" <<<"$out" || fail "update --check did not print the $kind install's commands: $out"
done
ok "--check names agentbus update only where it can run; elsewhere it prints the commands"

echo "TEST 4: a dist-info whose RECORD does not list this file gives unknown; the matching one (control) gives uv"
new_case record uv
sed -i.bak 's/^agentbus.py,,$/other.py,,/' "$SITE/agentbus-0.2.0.dist-info/RECORD"; rm -f "$SITE/agentbus-0.2.0.dist-info/RECORD.bak"
want "RECORD without the file" "unknown|-|-|uv tool install git+$REPO_URL@v0.3.0"
printf 'agentbus.py,,\n' >"$SITE/agentbus-0.2.0.dist-info/RECORD"
want "RECORD with the file (control)" "uv|$REPO_URL|uv|-"
ok "only a RECORD that lists the running file counts"

echo "TEST 5: a clone (the script beside pyproject.toml and .git) and an editable install are clones: git commands, no argv"
new_case clone uv
CL="$C/clone dir with 'quote"   # a folder name with a space and a quote: the printed commands must quote it
mkdir -p "$CL/bin" "$CL/.git"; sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$UPDATE_SRC" >"$CL/bin/agentbus"; : >"$CL/pyproject.toml"
REAL=$(cd "$CL" && pwd -P)
got=$(cd "$CWD" && "$PREFIX/bin/python" "$CL/bin/agentbus" update --check --json | "$PY" -I -c 'import json,sys; d=json.load(sys.stdin); print(d["install"]["method"], d["argv"], d["commands"])')
want=$("$PY" -I -c 'import shlex,sys; d=sys.argv[1]; print("clone None", [f"git -C {shlex.quote(d)} fetch --tags", f"git -C {shlex.quote(d)} checkout v0.3.0"])' "$REAL")
[ "$got" = "$want" ] || fail "clone commands are not quoted: $got"
human=$(cd "$CWD" && "$PREFIX/bin/python" "$CL/bin/agentbus" update --dry-run --no-buses --no-setup)
grep -qF "  git -C $("$PY" -I -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$REAL") fetch --tags" <<<"$human" || fail "the human clone line is not quoted: $human"
new_case editable uv; printf '{"url": "file:///src/agentbus", "dir_info": {"editable": true}}\n' >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
got=$(probe | cut -d'|' -f1); [ "$got" = clone ] || fail "editable: $got"
ok "a clone and an editable install print git commands"

echo "TEST 6: a project copy is refused with the exact line, for update and update --check"
new_case project uv; new_bus "$C/proj"
for flags in "" "--check"; do
  err=$(cd "$C/proj" && "$PREFIX/bin/python" "$C/proj/.agentbus/bin/agentbus" update $flags 2>&1 >/dev/null) && fail "project copy ran update $flags"
  grep -qF "update runs from the installed agentbus, not a project copy. Install it with the install line in the README (https://github.com/wickdninja/agentbus#quick-start), then run: agentbus update" <<<"$err" || fail "project copy message: $err"
done
ok "refused"

all_passed "All update detection tests passed"
