#!/bin/bash
# bash scripts/verify_update_layout.sh uv|pipx
# CI only (the package job): proves `agentbus update` recognises REAL uv and pipx installs, not fakes. A local bare repo
# is tagged v9.0.0 and v9.1.0 (only __version__ differs); the tool installs v9.0.0 from it; the release fixture
# (tests/fixtures/release_server.py, HTTPS on 127.0.0.1) announces v9.1.0; `update --dry-run --json` must report the
# tool as the method, the git+file URL as a fork (so nothing is run) and tool.status manual whose commands hold the
# --force line for that URL at v9.1.0. For uv it also checks the premise the design rests on: `uv tool upgrade` leaves a
# tag-pinned install where it is, while `install --force` at the new tag moves it. Needs network for the build backend
# only, like the rest of the package job. Last line: update layout verified: uv|pipx
set -euo pipefail
tool=${1:?usage: verify_update_layout.sh uv|pipx}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset AGENTBUS_CMD AGENTBUS_BIN
. "$ROOT/tests/update_lib.sh"
unset -f agentbus   # lib.sh's helper runs the checkout; this script runs the INSTALLED command
W=$(mktemp -d); trap 'stop_servers; rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME" "$W/srv"
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
git clone -q "$ROOT" "$W/src"
setver() { sed "s/^__version__ = .*/__version__ = \"$1\"/" "$W/src/bin/agentbus" >"$W/v" && cp "$W/v" "$W/src/bin/agentbus"; }
setver 9.0.0; "${G[@]}" -C "$W/src" commit -qam v9.0.0; "${G[@]}" -C "$W/src" tag v9.0.0
setver 9.1.0; "${G[@]}" -C "$W/src" commit -qam v9.1.0; "${G[@]}" -C "$W/src" tag v9.1.0
git clone -q --bare "$W/src" "$W/remote.git"
URL="file://$W/remote.git"
case "$tool" in
  uv)
    export UV_TOOL_DIR="$W/uv-tools" UV_TOOL_BIN_DIR="$W/bin" UV_CACHE_DIR="${UV_CACHE_DIR:-$W/uv-cache}"
    uv tool install -q "git+$URL@v9.0.0"
    BIN_DIR="$W/bin" ;;
  pipx)
    export PIPX_HOME="$W/pipx-home" PIPX_BIN_DIR="$W/bin"
    pipx install -q "git+$URL@v9.0.0"
    BIN_DIR="$W/bin" ;;
  *) echo "usage: verify_update_layout.sh uv|pipx" >&2; exit 2 ;;
esac
export PATH="$BIN_DIR:$PATH"
[ "$(agentbus --version)" = "agentbus 9.0.0" ] || { echo "FAIL: installed $(agentbus --version)" >&2; exit 1; }
if [ "$tool" = uv ]; then
  uv tool upgrade agentbus >"$W/up.out" 2>&1 || true
  [ "$(agentbus --version)" = "agentbus 9.0.0" ] || { echo "FAIL: uv tool upgrade moved a tag-pinned install: $(agentbus --version)" >&2; cat "$W/up.out" >&2; exit 1; }
  grep -qi "nothing to upgrade" "$W/up.out" || { echo "FAIL: uv tool upgrade did not say 'Nothing to upgrade'" >&2; cat "$W/up.out" >&2; exit 1; }
fi
start_server "$W/srv"; rel_latest 9.1.0; server_env
unset CI
out=$(cd "$W" && agentbus update --dry-run --json) || { echo "FAIL: update --dry-run failed" >&2; exit 1; }
printf '%s' "$out" | "$PY" -I -c '
import json, sys
d = json.load(sys.stdin)
url = sys.argv[1]
assert d["from"] == "9.0.0" and d["latest"] == "9.1.0", d
assert d["install"]["method"] == sys.argv[2] and d["install"]["url"] == url, d["install"]
assert d["tool"]["status"] == "manual" and d["tool"]["argv"] is None, d["tool"]
want = {"uv": "uv tool install --force git+%s@v9.1.0", "pipx": "pipx install --force git+%s@v9.1.0"}[sys.argv[2]] % url
assert d["tool"]["commands"] == [want], (d["tool"]["commands"], want)
' "$URL" "$tool" || { echo "FAIL: update --dry-run --json: $out" >&2; exit 1; }
# The wheel route (what `update` itself installs): build the 9.0.0 wheel and install that local file with the real tool.
# Installed from the folder update downloads into (<cache>/downloads), `update` recognises the install as this
# repository's. The same wheel installed from anywhere else is not: update must not replace a hand-built or fork wheel.
git -C "$W/src" checkout -q v9.0.0
(cd "$W/src" && uv build -q --wheel --out-dir "$W/wheel" >/dev/null)
WHEEL=$(ls "$W"/wheel/agentbus-9.0.0-py3-none-any.whl)
install_wheel() {  # FILE
  case "$tool" in
    uv) uv tool install -q --force "$1" ;;
    pipx) pipx install -q --force "$1" ;;
  esac
}
rel_latest 9.1.0
mkdir -p "$(cache_path)/downloads"; chmod 700 "$(cache_path)"; cp "$WHEEL" "$(cache_path)/downloads/"
install_wheel "$(cache_path)/downloads/agentbus-9.0.0-py3-none-any.whl"
out=$(cd "$W" && agentbus update --dry-run --json) || { echo "FAIL: update --dry-run on a wheel install failed" >&2; exit 1; }
printf '%s' "$out" | "$PY" -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["from"] == "9.0.0" and d["install"] == {"method": sys.argv[1], "url": "https://github.com/wickdninja/agentbus"}, d["install"]
assert d["tool"]["status"] in ("dry_run", "manual"), d["tool"]
if d["tool"]["status"] == "dry_run":
    # the wheel does not exist yet, so there is no installer argv: the planned download is shown
    assert d["tool"]["argv"] is None and d["tool"]["download"]["wheel"].endswith("/v9.1.0/agentbus-9.1.0-py3-none-any.whl"), d["tool"]
' "$tool" || { echo "FAIL: update did not recognise a release-wheel install: $out" >&2; exit 1; }
install_wheel "$WHEEL"   # the same file from outside the downloads folder
out=$(cd "$W" && agentbus update --dry-run --json) || { echo "FAIL: update --dry-run on a hand-installed wheel failed" >&2; exit 1; }
printf '%s' "$out" | "$PY" -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["install"]["method"] == "unknown" and d["tool"]["status"] == "manual", d
' || { echo "FAIL: update would replace a wheel that was installed from outside its downloads folder: $out" >&2; exit 1; }
if [ "$tool" = uv ]; then
  uv tool install -q --force "git+$URL@v9.1.0"
  [ "$(agentbus --version)" = "agentbus 9.1.0" ] || { echo "FAIL: install --force at the new tag did not move it" >&2; exit 1; }
fi
echo "update layout verified: $tool"
