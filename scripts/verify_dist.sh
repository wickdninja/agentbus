#!/bin/bash
# bash scripts/verify_dist.sh [--allow-skip] [--quick] DIR
# DIR holds the files a release will publish: one wheel and one sdist, built once (uv build --out-dir DIR).
# This checks THOSE files, not a rebuild: the wheel holds agentbus.py (the bytes of bin/agentbus) and
# metadata only, the version inside is __version__, the sdist has the skill, scripts and tests; each is
# installed into its own venv and scripts/verify_installed.sh runs against it; then the installed wheel is
# broken on purpose and the verify must fail (it ran the install, not the source). Last, DIR/SHA256SUMS
# records the sha256 of both files; later jobs re-check it so exactly these bytes are published.
# Last line: `dist verified: <wheel> <sdist>`. --allow-skip and --quick are passed on to verify_installed.sh.
set -u
ALLOW=()
while [ $# -gt 1 ]; do
  case "$1" in --allow-skip) ALLOW+=(--allow-skip) ;; --quick) ALLOW+=(--quick) ;; *) break ;; esac
  shift
done
DIR="${1:?usage: verify_dist.sh [--allow-skip] DIR}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$(cd "$DIR" && pwd -P)" || exit 1
unset PYTHONPATH AGENTBUS_CMD AGENTBUS_BIN AGENTBUS_DB AGENTBUS_AGENT
die() { echo "FAIL dist: $*" >&2; exit 1; }
command -v uv >/dev/null 2>&1 || die "uv not found"
shopt -s nullglob
wheels=("$DIR"/*.whl); sdists=("$DIR"/*.tar.gz)
[ ${#wheels[@]} = 1 ] && [ ${#sdists[@]} = 1 ] || die "$DIR must hold exactly one wheel and one sdist (found ${#wheels[@]} and ${#sdists[@]})"
WHEEL="${wheels[0]}"; SDIST="${sdists[0]}"
VERSION=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$ROOT/bin/agentbus")
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"

python3 -I - "$WHEEL" "$SDIST" "$ROOT/bin/agentbus" "$VERSION" <<'PY' || exit 1
import re, sys, tarfile, zipfile
wheel, sdist, binfile, version = sys.argv[1:]
z = zipfile.ZipFile(wheel)
names = z.namelist()
extra = [n for n in names if n != 'agentbus.py' and not re.match(r'agentbus-[^/]+\.dist-info/', n)]
if 'agentbus.py' not in names or extra:
    sys.exit(f'FAIL dist: unexpected wheel members: {extra}')
if z.read('agentbus.py') != open(binfile, 'rb').read():
    sys.exit('FAIL dist: agentbus.py differs from bin/agentbus')
meta = z.read([n for n in names if n.endswith('/METADATA')][0]).decode()
got = re.search(r'^Version: (.+)$', meta, re.M).group(1)
if got != version:
    sys.exit(f'FAIL dist: the wheel is version {got}, __version__ is {version}')
if f'agentbus-{version}-' not in wheel.rsplit('/', 1)[-1]:
    sys.exit(f'FAIL dist: the wheel file name does not carry version {version}')
listing = tarfile.open(sdist).getnames()
for want in ('skills/agentbus/SKILL.md', 'scripts/embed_skill.py', 'scripts/verify_installed.sh', 'bin/agentbus'):
    if not any(re.fullmatch(r'[^/]+/' + re.escape(want), n) for n in listing):
        sys.exit(f'FAIL dist: the sdist lacks {want}')
PY
echo "ok   members and version"

install() { # KIND ARTIFACT -> $T/KIND-venv
  uv venv --quiet "$T/$1-venv" >"$T/$1-venv.out" 2>&1 || { cat "$T/$1-venv.out" >&2; die "uv venv ($1)"; }
  uv pip install --quiet --python "$T/$1-venv/bin/python" "$2" >"$T/$1-pip.out" 2>&1 || { cat "$T/$1-pip.out" >&2; die "installing the $1"; }
}
for kind in wheel sdist; do
  art="$WHEEL"; [ "$kind" = sdist ] && art="$SDIST"
  install "$kind" "$art"
  out="$T/verify-$kind.out"
  bash "$ROOT/scripts/verify_installed.sh" ${ALLOW[@]+"${ALLOW[@]}"} "$T/$kind-venv/bin/agentbus" "$kind" >"$out" 2>&1 || { cat "$out" >&2; die "verify_installed.sh failed on the $kind"; }
  grep '^SKIP' "$out" || true
  tail -n 1 "$out"
done

# Negative control: break only the installed wheel; the verify must fail at its first step.
FILE=$("$T/wheel-venv/bin/python" -c 'import agentbus; print(agentbus.__file__)') || die "cannot find the installed module"
case "$FILE" in "$T"/wheel-venv/*) ;; *) die "the installed module is not in the venv: $FILE";; esac
printf '\nimport sys; sys.exit(99)\n' >>"$FILE"
rc=0; bash "$ROOT/scripts/verify_installed.sh" ${ALLOW[@]+"${ALLOW[@]}"} "$T/wheel-venv/bin/agentbus" broken >"$T/neg.out" 2>&1 || rc=$?
{ [ "$rc" = 1 ] && grep -qx 'FAIL step: --version equals __version__' "$T/neg.out"; } || { cat "$T/neg.out" >&2; die "verify_installed.sh did not fail on a broken install (it ran the source?)"; }
echo "ok   negative control"

(cd "$DIR" && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$(basename "$WHEEL")" "$(basename "$SDIST")"; else shasum -a 256 "$(basename "$WHEEL")" "$(basename "$SDIST")"; fi) >"$DIR/SHA256SUMS"
cat "$DIR/SHA256SUMS"
echo "dist verified: $(basename "$WHEEL") $(basename "$SDIST")"
