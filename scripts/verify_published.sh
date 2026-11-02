#!/bin/bash
# bash scripts/verify_published.sh vX.Y.Z [--dry-run] [--allow-skip] [--sums SHA256SUMS] [--pypi]
# After the tag exists: runs the LITERAL pinned install lines from README.md, on a clean runner, in
# isolated tool folders and a temp HOME, then scripts/verify_installed.sh on each installed command (its
# output is shown whole, SKIP lines included). With --sums FILE it also downloads the release assets and
# compares their sha256 to the ones recorded when the files were verified before publishing; --pypi does
# the same for the files on PyPI. Never before the tag exists (before it, tests/test_readme.sh runs the
# Try-it block on the built wheel). A missing pipx is a failure unless --allow-skip.
# --dry-run prints the lines it would run. Last line on success: `published install verified: vX.Y.Z`.
set -u
TAG="${1:?usage: verify_published.sh vX.Y.Z [--dry-run] [--allow-skip] [--sums FILE] [--pypi]}"; shift
DRY=0; ALLOW=0; SUMS=""; PYPI=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --allow-skip) ALLOW=1 ;;
    --pypi) PYPI=1 ;;
    --sums) shift; SUMS="${1:?--sums needs a file}" ;;
    *) echo "FAIL: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "FAIL: '$TAG' is not a release tag like v0.2.0" >&2; exit 2;; esac
case "$TAG" in *rc*) echo "FAIL: '$TAG' is a release candidate; the README pins the final version, so it is not checked here" >&2; exit 2;; esac
UV_LINE="uv tool install git+https://github.com/wickdninja/agentbus@$TAG"
PIPX_LINE="pipx install git+https://github.com/wickdninja/agentbus@$TAG"
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
  mkdir -p "$T/assets" "$T/pypi"
  while read -r recorded name; do
    curl -fsSL -o "$T/assets/$name" "https://github.com/wickdninja/agentbus/releases/download/$TAG/$name" || { echo "FAIL: cannot download the release asset $name" >&2; exit 1; }
    [ "$(sum "$T/assets/$name")" = "$recorded" ] || { echo "FAIL: release asset $name differs from the file that was verified before publishing" >&2; exit 1; }
    echo "ok   release asset $name matches the recorded sha256"
  done < "$SUMS"
  if [ "$PYPI" = 1 ]; then
    python3 -m pip download "agentbus==$want" --no-deps -d "$T/pypi" >/dev/null 2>&1 || { echo "FAIL: pip cannot download agentbus==$want from PyPI" >&2; exit 1; }
    python3 -m pip download "agentbus==$want" --no-deps --no-binary :all: -d "$T/pypi" >/dev/null 2>&1 || { echo "FAIL: pip cannot download the agentbus==$want sdist from PyPI" >&2; exit 1; }
    while read -r recorded name; do
      [ "$(sum "$T/pypi/$name")" = "$recorded" ] || { echo "FAIL: PyPI file $name differs from the file that was verified before publishing" >&2; exit 1; }
      echo "ok   PyPI file $name matches the recorded sha256"
    done < "$SUMS"
  fi
fi
echo "published install verified: $TAG"
