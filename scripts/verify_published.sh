#!/bin/bash
# bash scripts/verify_published.sh vX.Y.Z [--dry-run] [--allow-skip] [--sums SHA256SUMS]
# After the tag exists: runs the LITERAL pinned install lines from README.md, on a clean runner, in
# isolated tool folders and a temp HOME, then scripts/verify_installed.sh on each installed command (its
# output is shown whole, SKIP lines included). With --sums FILE it also downloads the release assets and
# compares their sha256 to the ones recorded when the files were verified before publishing. Never before the tag exists (before it, tests/test_readme.sh runs the
# Try-it block on the built wheel). A missing pipx is a failure unless --allow-skip.
# --dry-run prints the lines it would run. Last line on success: `published install verified: vX.Y.Z`.
set -u
TAG="${1:?usage: verify_published.sh vX.Y.Z [--dry-run] [--allow-skip] [--sums FILE]}"; shift
DRY=0; ALLOW=0; SUMS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --allow-skip) ALLOW=1 ;;
    --sums) shift; SUMS="${1:?--sums needs a file}"; [ -f "$SUMS" ] && SUMS="$(cd "$(dirname "$SUMS")" && pwd)/$(basename "$SUMS")" ;;   # absolute: the script moves to its temp folder
    *) echo "FAIL: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "FAIL: '$TAG' is not a release tag like v0.2.0" >&2; exit 2;; esac
case "$TAG" in *rc*) echo "FAIL: '$TAG' is a release candidate; the README pins the final version, so it is not checked here" >&2; exit 2;; esac
# The lines the README shows for this tag: the release wheel's URL once tests/released_wheels.txt lists the tag, else git+.
LINES=$(python3 "$ROOT/scripts/release_check.py" --lines "$TAG") || { echo "FAIL: cannot work out the install lines for $TAG" >&2; exit 2; }
UV_LINE=$(sed -n 1p <<<"$LINES")
PIPX_LINE=$(sed -n 2p <<<"$LINES")
for line in "$UV_LINE" "$PIPX_LINE"; do
  grep -qF -- "$line" "$ROOT/README.md" || { echo "FAIL: README.md does not contain the line: $line" >&2; exit 1; }
done
if [ "$DRY" = 1 ]; then printf '%s\n%s\n' "$UV_LINE" "$PIPX_LINE"; exit 0; fi
if ! git ls-remote --exit-code --tags https://github.com/wickdninja/agentbus "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "FAIL: the tag $TAG does not exist on GitHub yet" >&2; exit 1
fi
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME" "$T/cwd"
unset PYTHONPATH AGENTBUS_CMD AGENTBUS_BIN AGENTBUS_DB AGENTBUS_AGENT
cd "$T/cwd" || exit 1
want="${TAG#v}"
SKIPFLAG=(); [ "$ALLOW" = 1 ] && SKIPFLAG=(--allow-skip)
verify() { # LABEL COMMAND
  got=$("$2" --version 2>&1) || { echo "FAIL ($1): $2 --version: $got" >&2; exit 1; }
  [ "$got" = "agentbus $want" ] || { echo "FAIL ($1): '$got', wanted 'agentbus $want'" >&2; exit 1; }
  bash "$ROOT/scripts/verify_installed.sh" ${SKIPFLAG[@]+"${SKIPFLAG[@]}"} "$2" "$1" >"$T/verify.out" 2>&1; rc=$?
  cat "$T/verify.out"   # all of it: a skipped step must be visible
  [ "$rc" = 0 ] && [ "$(tail -n 1 "$T/verify.out" | cut -d'(' -f1 | sed 's/ *$//')" = "installed command verified: $1" ] || { echo "FAIL ($1): verify_installed.sh (exit $rc)" >&2; exit 1; }
  echo "ok   $1"
}
export UV_TOOL_DIR="$T/uv-tools" UV_TOOL_BIN_DIR="$T/uv-bin"
read -r -a cmd <<<"$UV_LINE"
"${cmd[@]}" || { echo "FAIL: $UV_LINE" >&2; exit 1; }
verify "uv tool install" "$UV_TOOL_BIN_DIR/agentbus"
if command -v pipx >/dev/null 2>&1; then
  export PIPX_HOME="$T/pipx-home" PIPX_BIN_DIR="$T/pipx-bin"
  read -r -a cmd <<<"$PIPX_LINE"
  "${cmd[@]}" || { echo "FAIL: $PIPX_LINE" >&2; exit 1; }
  verify "pipx install" "$PIPX_BIN_DIR/agentbus"
elif [ "$ALLOW" = 1 ]; then
  echo "SKIP step: pipx install (pipx not found)"
else
  echo "FAIL: pipx not found (use --allow-skip where that is expected)" >&2; exit 1
fi

if [ -n "$SUMS" ]; then
  [ -f "$SUMS" ] || { echo "FAIL: $SUMS not found" >&2; exit 1; }
  sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
  mkdir -p "$T/assets"
  while read -r recorded name; do
    curl -fsSL -o "$T/assets/$name" "https://github.com/wickdninja/agentbus/releases/download/$TAG/$name" || { echo "FAIL: cannot download the release asset $name" >&2; exit 1; }
    [ "$(sum "$T/assets/$name")" = "$recorded" ] || { echo "FAIL: release asset $name differs from the file that was verified before publishing" >&2; exit 1; }
    echo "ok   release asset $name matches the recorded sha256"
  done < "$SUMS"
fi
echo "published install verified: $TAG"
