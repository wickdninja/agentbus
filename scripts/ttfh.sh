#!/bin/bash
# bash scripts/ttfh.sh [INSTALL LINE...]
# Time to first handoff: from the install command to agent B's `inbox` printing agent A's handoff, in a
# fresh temp HOME and repo, through the installed command only. The human types three commands (install,
# `agentbus init .`, `agentbus setup claude`); the agents' commands are not counted. Prints
# `ttfh: 41s, 3 human commands`. It records a number and has no pass/fail time: it mostly measures the
# network. Default install line: the pinned tag of this tree's version; CI passes the built wheel.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$ROOT/bin/agentbus")
if [ $# -gt 0 ]; then INSTALL=("$@"); else INSTALL=(uv tool install "git+https://github.com/wickdninja/agentbus@v$VERSION"); fi
unset PYTHONPATH AGENTBUS_CMD AGENTBUS_BIN AGENTBUS_DB AGENTBUS_AGENT CLAUDE_CONFIG_DIR
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" UV_TOOL_DIR="$T/uv-tools" UV_TOOL_BIN_DIR="$T/uv-bin" PIPX_HOME="$T/pipx-home" PIPX_BIN_DIR="$T/uv-bin"
mkdir -p "$HOME" "$T/repo"
export PATH="$UV_TOOL_BIN_DIR:$PATH"
git -C "$T/repo" init -q || exit 1
cd "$T/repo" || exit 1
die() { echo "ttfh failed at: $1" >&2; exit 1; }
start=$(date +%s)
"${INSTALL[@]}" >"$T/install.out" 2>&1 || { tail -n 5 "$T/install.out" >&2; die "${INSTALL[*]}"; }
agentbus init . >"$T/init.out" 2>&1 || { cat "$T/init.out" >&2; die "agentbus init ."; }
agentbus setup claude >"$T/setup.out" 2>&1 || { cat "$T/setup.out" >&2; die "agentbus setup claude"; }
agentbus --as A join >/dev/null 2>&1 || die "A join"
agentbus --as B join >/dev/null 2>&1 || die "B join"
agentbus --as A post "ttfh handoff: parser done, tests next" --to B --kind handoff >/dev/null 2>&1 || die "A post"
agentbus --as B inbox >"$T/inbox.out" 2>&1 || die "B inbox"
grep -qF "ttfh handoff: parser done, tests next" "$T/inbox.out" || { cat "$T/inbox.out" >&2; die "B's inbox did not show A's handoff"; }
end=$(date +%s)
echo "ttfh: $((end - start))s, 3 human commands"
