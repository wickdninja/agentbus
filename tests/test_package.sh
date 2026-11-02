#!/bin/bash
set -euo pipefail
# The wheel and sdist, built and installed for real: the contents are exactly what the docs promise, and
# scripts/verify_installed.sh runs the installed executable (and only it). A negative control breaks the
# installed file alone and requires the verify to fail, which proves it was not running the source.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$BIN")/.." && pwd)"
if ! command -v uv >/dev/null 2>&1; then
  # A skipped test must not read as a pass: exit 77 is the suite's SKIP status (with ws10's run_all it is
  # counted, and AGENTBUS_NO_SKIP=1 fails it; this branch's run_all still treats 77 as a failure);
  # CI has uv, so there it is a failure.
  [ -z "${CI:-}" ] || fail "uv not found, and CI requires it"
  skip_test "uv not found (install uv to run the package tests)"
fi
# Without uv this file must SKIP (77) locally and FAIL on CI, never print that it passed.
NOUV=$(mktemp -d); # type -P: the file on PATH (lib.sh defines mktemp and trap as functions, which command -v would name instead)
for tool in bash dirname env sed grep cat mktemp rm tr; do ln -s "$(type -P $tool)" "$NOUV/$tool"; done
ln -s "$(type -P python3)" "$NOUV/python3"
rc=0; out=$(env -i PATH="$NOUV" HOME="$NOUV" bash "$0" 2>&1) || rc=$?
[ "$rc" = 77 ] && grep -q '^SKIP: uv not found' <<<"$out" || { rm -rf "$NOUV"; fail "without uv: exit $rc, wanted 77 and a SKIP line: $out"; }
rc=0; out=$(env -i PATH="$NOUV" HOME="$NOUV" CI=1 bash "$0" 2>&1) || rc=$?
[ "$rc" = 1 ] && grep -q 'uv not found, and CI requires it' <<<"$out" || { rm -rf "$NOUV"; fail "without uv on CI: exit $rc, wanted 1: $out"; }
rm -rf "$NOUV"
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset AGENTBUS_CMD AGENTBUS_BIN
sha_before=$(shasum -a 256 "$ROOT/bin/agentbus" | cut -d' ' -f1)

echo "TEST: uv build makes a wheel and an sdist"
uv build --out-dir "$T/dist" "$ROOT" >"$T/build.out" 2>&1 || { cat "$T/build.out" >&2; fail "uv build failed"; }
WHEEL=$(ls "$T"/dist/*.whl); SDIST=$(ls "$T"/dist/*.tar.gz)
ok "built $(basename "$WHEEL") and $(basename "$SDIST")"

echo
echo "TEST: the wheel contains agentbus.py equal to bin/agentbus and nothing else but metadata"
"$PY" -I - "$WHEEL" "$ROOT/bin/agentbus" <<'PY'
import re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
extra = [n for n in names if n != 'agentbus.py' and not re.match(r'agentbus-[^/]+\.dist-info/', n)]
assert 'agentbus.py' in names and not extra, ('unexpected wheel members', extra)
assert z.read('agentbus.py') == open(sys.argv[2], 'rb').read(), 'agentbus.py differs from bin/agentbus'
entry = z.read([n for n in names if n.endswith('entry_points.txt')][0]).decode()
assert 'agentbus = agentbus:' in entry, entry
PY
ok "wheel: agentbus.py + dist-info"

echo
echo "TEST: the sdist contains skills/agentbus/SKILL.md and scripts/"
tar tzf "$SDIST" >"$T/sdist.list"
for want in skills/agentbus/SKILL.md scripts/embed_skill.py scripts/verify_installed.sh docs/how-to/setup.md tests/test_package.sh bin/agentbus; do
  grep -qE "^[^/]+/$want\$" "$T/sdist.list" || fail "the sdist lacks $want"
done
ok "sdist has the skill, scripts, docs and tests"

echo
echo "TEST: an installed copy prints the same skill as the source, and scripts/verify_installed.sh passes on it"
uv venv --quiet --python "$PY" "$T/venv" >"$T/venv.out" 2>&1 || { cat "$T/venv.out" >&2; fail "uv venv failed"; }
uv pip install --quiet --python "$T/venv/bin/python" "$WHEEL" >"$T/pip.out" 2>&1 || { cat "$T/pip.out" >&2; fail "installing the wheel failed"; }
INSTALLED="$T/venv/bin/agentbus"
"$INSTALLED" skill | cmp -s - "$ROOT/skills/agentbus/SKILL.md" || fail "the installed skill differs from skills/agentbus/SKILL.md"
# The bare name `agentbus` (the documented gate form) must work: lib.sh defines a function of that name.
# Every step runs (the crash step and test_workflow_first_run.sh are in this tree): no skip is allowed.
PATH="$T/venv/bin:$PATH" bash "$ROOT/scripts/verify_installed.sh" agentbus wheel >"$T/verify.out" 2>&1 || { tail -n 30 "$T/verify.out" >&2; fail "verify_installed.sh failed on the wheel"; }
[ "$(tail -n 1 "$T/verify.out")" = "installed command verified: wheel" ] || fail "last line: $(tail -n 1 "$T/verify.out")"
! grep -q '^SKIP step: ' "$T/verify.out" || fail "verify_installed.sh skipped a step: $(grep '^SKIP step: ' "$T/verify.out")"
ok "installed wheel verified"

echo
echo "TEST: with only the installed executable broken, verify_installed.sh fails and names the step"
FILE=$("$T/venv/bin/python" -c 'import agentbus; print(agentbus.__file__)')
case "$FILE" in "$T"/venv/*) ;; *) fail "the installed module is not in the venv: $FILE";; esac
printf '\nimport sys; sys.exit(99)\n' >>"$FILE"
rc=0; bash "$ROOT/scripts/verify_installed.sh" "$INSTALLED" broken >"$T/neg.out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "verify_installed.sh exited $rc on a broken install, wanted 1: $(tail -n 5 "$T/neg.out")"
grep -qxF 'FAIL step: --version equals __version__' "$T/neg.out" || fail "the failure did not name the step: $(cat "$T/neg.out")"
grep -q 'installed command verified' "$T/neg.out" && fail "verify printed success on a broken install"
[ "$sha_before" = "$(shasum -a 256 "$ROOT/bin/agentbus" | cut -d' ' -f1)" ] || fail "the checkout's bin/agentbus changed"
ok "a broken installed executable fails verify; the checkout is untouched"

echo
echo "TEST: verify_dist.sh checks the built files, installs each, records sha256s, and fails on a tampered file"
cp -R "$T/dist" "$T/dist2"
bash "$ROOT/scripts/verify_dist.sh" --quick "$T/dist2" >"$T/vd.out" 2>&1 || { tail -n 30 "$T/vd.out" >&2; fail "verify_dist.sh failed on the built files"; }
[ "$(tail -n 1 "$T/vd.out")" = "dist verified: $(basename "$WHEEL") $(basename "$SDIST")" ] || fail "last line: $(tail -n 1 "$T/vd.out")"
(cd "$T/dist2" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "SHA256SUMS does not match the files"
[ "$(wc -l <"$T/dist2/SHA256SUMS" | tr -d ' ')" = 2 ] || fail "SHA256SUMS must list the wheel and the sdist: $(cat "$T/dist2/SHA256SUMS")"
cp -R "$T/dist" "$T/dist3"
"$PY" -I - "$T/dist3"/*.whl <<'PY'
import sys, zipfile, shutil
src = sys.argv[1]; tmp = src + '.new'
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(tmp, 'w') as zo:
    for i in zi.infolist():
        zo.writestr(i, zi.read(i.filename) + (b'\n# tampered\n' if i.filename == 'agentbus.py' else b''))
shutil.move(tmp, src)
PY
rc=0; bash "$ROOT/scripts/verify_dist.sh" --quick "$T/dist3" >"$T/vd3.out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q 'agentbus.py differs from bin/agentbus' "$T/vd3.out" || fail "a tampered wheel: exit $rc: $(tail -n 5 "$T/vd3.out")"
ok "verify_dist.sh: members, install, negative control, SHA256SUMS; a changed wheel fails"

echo
echo "TEST: a release candidate version builds as itself (0.2.0rc1), never as 0.2.0"
RC="$T/rctree"; mkdir -p "$RC"
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$RC"
sed -i.b 's/^__version__ = "[^"]*"/__version__ = "0.2.0rc1"/' "$RC/bin/agentbus"
uv build --wheel --out-dir "$T/rcdist" "$RC" >"$T/rcbuild.out" 2>&1 || { cat "$T/rcbuild.out" >&2; fail "building the rc tree failed"; }
[ -f "$T/rcdist/agentbus-0.2.0rc1-py3-none-any.whl" ] || fail "an rc version must build agentbus-0.2.0rc1: $(ls "$T/rcdist")"
ok "version 0.2.0rc1 builds agentbus-0.2.0rc1"

echo
echo "TEST: a skipped verify step prints SKIP and fails unless --allow-skip is given"
FX="$T/fx"; mkdir -p "$FX/scripts" "$FX/bin" "$FX/skills/agentbus" "$FX/examples" "$FX/tests"
cp "$ROOT/scripts/verify_installed.sh" "$FX/scripts/"; cp "$ROOT/skills/agentbus/SKILL.md" "$FX/skills/agentbus/"
cp "$ROOT/examples/two-agent-handoff.sh" "$FX/examples/"
sed 's/AGENTBUS_TEST_CRASH/AGENTBUS_TEST_CRASX/g' "$ROOT/bin/agentbus" >"$FX/bin/agentbus"
for t in test_example test_json test_dx; do printf '#!/bin/bash\nexit 0\n' >"$FX/tests/$t.sh"; done   # no test_workflow_first_run.sh
printf '#!/bin/bash\nexec %q %q "$@"\n' "$PY" "$ROOT/bin/agentbus" >"$T/fake-agentbus"; chmod +x "$T/fake-agentbus"
rc=0; bash "$FX/scripts/verify_installed.sh" "$T/fake-agentbus" fx >"$T/skip1.out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "skips without --allow-skip: exit $rc: $(tail -n 8 "$T/skip1.out")"
grep -q '^SKIP step: a crash prints an internal JSON error' "$T/skip1.out" && grep -q '^SKIP step: tests/test_workflow_first_run.sh' "$T/skip1.out" || fail "SKIP lines missing: $(cat "$T/skip1.out")"
grep -q 'installed command verified' "$T/skip1.out" && fail "printed success with skipped steps"
rc=0; bash "$FX/scripts/verify_installed.sh" --allow-skip "$T/fake-agentbus" fx >"$T/skip2.out" 2>&1 || rc=$?
[ "$rc" = 0 ] && grep -q '^SKIP step: ' "$T/skip2.out" && [ "$(tail -n 1 "$T/skip2.out")" = "installed command verified: fx (2 steps skipped)" ] || fail "--allow-skip: exit $rc: $(tail -n 4 "$T/skip2.out")"
ok "skips are loud: SKIP lines, exit 1 by default, an explicit --allow-skip to go on"

echo
echo "TEST: the sdist builds and installs to the same command (CI's package matrix runs the full verify on it)"
uv venv --quiet --python "$PY" "$T/venv2" >"$T/venv.out" 2>&1 || fail "uv venv failed"
uv pip install --quiet --python "$T/venv2/bin/python" "$SDIST" >"$T/pip2.out" 2>&1 || { cat "$T/pip2.out" >&2; fail "installing the sdist failed"; }
"$T/venv2/bin/agentbus" skill | cmp -s - "$ROOT/skills/agentbus/SKILL.md" || fail "the sdist-installed skill differs from skills/agentbus/SKILL.md"
[ "$("$T/venv2/bin/agentbus" --version)" = "agentbus $(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$ROOT/bin/agentbus")" ] || fail "the sdist-installed version differs from __version__"
ok "installed sdist prints the same skill and version"

echo
echo "All package tests passed"
