#!/bin/bash
set -euo pipefail
# scripts/release_check.py against fixture repos: the clean one passes, and each mismatch fails with a
# message that names it. The fixtures are throwaway git repos in a temp dir.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
ROOT="$(cd "$(dirname "$BIN")/.." && pwd)"
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)

SKILL_TEXT=$'---\nname: agentbus\n---\n# skill\n\n<!-- agentbus:managed -->\n'
SHA=$(printf '%s' "$SKILL_TEXT" | shasum -a 256 | cut -d' ' -f1)
FX="$T/fixture"; mkdir -p "$FX/scripts" "$FX/bin" "$FX/skills/agentbus" "$FX/docs/how-to" "$FX/.claude-plugin"
cp "$ROOT/scripts/release_check.py" "$FX/scripts/"
ASHA=$(printf 'agents block\n' | shasum -a 256 | cut -d' ' -f1)
printf 'DIST_NAME = "agentbus"\n__version__ = "0.2.0"\nAGENTS_SNIPPET = (\n    "agents block\\n"\n)\nSKILL_SHA256_HISTORY = (\n    "%s",\n)\nAGENTS_SHA256_HISTORY = (\n    "%s",\n)\n' "$SHA" "$ASHA" >"$FX/bin/agentbus"
printf '%s' "$SKILL_TEXT" >"$FX/skills/agentbus/SKILL.md"
printf '[build-system]\nrequires = []\n\n[project]\nname = "agentbus"\ndynamic = ["version"]\n' >"$FX/pyproject.toml"
mkdir -p "$FX/tests"; printf '# Commands of each released tag\nv0.1.0: join leave\n' >"$FX/tests/released_commands.txt"
printf '# Changelog\n\n## Unreleased\n\n- next\n\n## 0.2.0 - 2026-11-20\n\nthings\n\n## 0.1.0 - 2026-11-01\n\nfirst\n' >"$FX/CHANGELOG.md"
printf '# agentbus\n\n```bash\nuv tool install git+https://github.com/wickdninja/agentbus@v0.2.0\n```\n\nor `pipx install --force git+https://github.com/wickdninja/agentbus@v0.2.0`.\n' >"$FX/README.md"
printf '# Set up\n\nuv tool install git+https://github.com/wickdninja/agentbus@v0.2.0\n' >"$FX/docs/how-to/setup.md"
printf '{"name": "agentbus", "version": "0.2.0"}\n' >"$FX/.claude-plugin/plugin.json"
printf '{"name": "m", "plugins": [{"name": "agentbus", "source": {"source": "git", "url": "https://github.com/wickdninja/agentbus.git", "ref": "v0.2.0"}}]}\n' >"$FX/.claude-plugin/marketplace.json"
git -C "$FX" init -q; git -C "$FX" add -A; "${G[@]}" -C "$FX" commit -q -m fixture
git -C "$FX" update-ref refs/remotes/origin/main HEAD
git -C "$FX" tag v0.1.0   # the last final release exists as a tag; v0.2.0 does not yet

# case NAME ARGS...: a fresh copy of the fixture in $D; the caller edits it, then `check` runs the script.
D=""; RC=0; OUT=""
fresh() { D="$T/case-$1"; rm -rf "$D"; cp -R "$FX" "$D"; }
commit() { git -C "$D" add -A; "${G[@]}" -C "$D" commit -q -m case; git -C "$D" update-ref refs/remotes/origin/main HEAD; }
check() { RC=0; OUT=$(cd "$D" && "$PY" scripts/release_check.py "$@" 2>&1) || RC=$?; }
expect_fail_with() { [ "$RC" = 1 ] || fail "$1: exit $RC, wanted 1: $OUT"; grep -qF -- "$2" <<<"$OUT" || { echo "$OUT" >&2; fail "$1: output lacks: $2"; }; }
edit() { "$PY" -I - "$@" <<'PY'
import sys
path, a, b = sys.argv[1:4]
s = open(path).read(); assert a in s, (path, a); open(path, 'w').write(s.replace(a, b))
PY
}

echo "TEST: the clean fixture passes (with and without --tag), and an rc tag matches the final version"
fresh clean; check
[ "$RC" = 0 ] && [ "$(tail -n 1 <<<"$OUT")" = "release check passed: 0.2.0" ] || fail "clean: exit $RC: $OUT"
check --tag v0.2.0
[ "$RC" = 0 ] && [ "$OUT" = "release check passed: 0.2.0" ] || fail "clean with --tag: exit $RC: $OUT"
fresh rc; edit "$D/bin/agentbus" '__version__ = "0.2.0"' '__version__ = "0.2.0rc1"'; edit "$D/.claude-plugin/plugin.json" '"0.2.0"' '"0.2.0rc1"'
# Until the final tag exists, main's public README keeps pinning the LAST FINAL release (v0.1.0).
edit "$D/README.md" 'agentbus@v0.2.0' 'agentbus@v0.1.0'; edit "$D/docs/how-to/setup.md" 'agentbus@v0.2.0' 'agentbus@v0.1.0'
edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.2.0"' '"ref": "v0.2.0rc1"'; commit; check --tag v0.2.0rc1
[ "$RC" = 0 ] && [ "$OUT" = "release check passed: 0.2.0rc1" ] || fail "rc tag (version 0.2.0rc1, pins v0.1.0): exit $RC: $OUT"
fresh rcpin; edit "$D/bin/agentbus" '__version__ = "0.2.0"' '__version__ = "0.2.0rc1"'; edit "$D/.claude-plugin/plugin.json" '"0.2.0"' '"0.2.0rc1"'
edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.2.0"' '"ref": "v0.2.0rc1"'; commit; check --tag v0.2.0rc1
[ "$RC" = 1 ] && grep -qF "must pin @v0.1.0 (the last final release" <<<"$OUT" || fail "an rc whose README already pins the unreleased final: exit $RC: $OUT"
# The rc commit may not invent a release: pinning the unreleased final and adding its line to
# released_commands.txt in the same commit must fail, because no v0.2.0 tag exists.
fresh rcfake; edit "$D/bin/agentbus" '__version__ = "0.2.0"' '__version__ = "0.2.0rc1"'; edit "$D/.claude-plugin/plugin.json" '"0.2.0"' '"0.2.0rc1"'
edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.2.0"' '"ref": "v0.2.0rc1"'; printf 'v0.2.0: join leave\n' >>"$D/tests/released_commands.txt"; commit; check --tag v0.2.0rc1
[ "$RC" = 1 ] && grep -qF "v0.2.0 is not a git tag" <<<"$OUT" || fail "an rc that pins a release with no tag: exit $RC: $OUT"
fresh finalpin; edit "$D/README.md" 'agentbus@v0.2.0' 'agentbus@v0.1.0'; commit; check --tag v0.2.0
[ "$RC" = 1 ] && grep -qF "must pin @v0.2.0" <<<"$OUT" || fail "a final tag whose README still pins the old release: exit $RC: $OUT"
fresh nofiles; git -C "$D" rm -rq .claude-plugin; commit; check
[ "$RC" = 0 ] || fail "no plugin files: exit $RC: $OUT"
# A development version (main between releases) passes untagged with the last release's CHANGELOG heading
# and pins; a tag still needs its exact version, and a dev tag is not a release tag.
devfix() { fresh "$1"; edit "$D/bin/agentbus" '__version__ = "0.2.0"' '__version__ = "0.2.0.dev0"'; edit "$D/.claude-plugin/plugin.json" '"0.2.0"' '"0.2.0.dev0"'
  edit "$D/CHANGELOG.md" $'## 0.2.0 - 2026-11-20\n\nthings\n\n' ''
  edit "$D/README.md" 'agentbus@v0.2.0' 'agentbus@v0.1.0'; edit "$D/docs/how-to/setup.md" 'agentbus@v0.2.0' 'agentbus@v0.1.0'
  edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.2.0"' '"ref": "v0.1.0"'; }   # between releases the marketplace keeps the last plugin release (the fixture's v0.1.0 tag carries the plugin)
devfix dev; commit; check
[ "$RC" = 0 ] && [ "$OUT" = "release check passed: 0.2.0.dev0" ] || fail "an untagged dev build: exit $RC: $OUT"
devfix devref; edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.1.0"' '"ref": "v0.2.0"'; commit; check
expect_fail_with "a dev build whose marketplace names a tag that does not exist yet" "source ref is v0.2.0, not v0.1.0 (the last plugin release"
devfix devmain; edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.1.0"' '"ref": "main"'; commit; check
expect_fail_with "a dev build whose marketplace follows main (plugin users would run untagged code)" "source ref is main, not v0.1.0 (the last plugin release"
devfix devplug; git -C "$D" tag v0.1.5; commit; check   # a newer plugin release exists: the dev build must keep THAT one
expect_fail_with "a dev build that keeps an older plugin release than the last" "not v0.1.5 (the last plugin release"
# Before any plugin release exists no tag carries the plugin: a dev build names the tag being prepared (v0.2.0), never main and never an old tag.
nopluginfix() { devfix "$1"; export GIT_INDEX_FILE="$T/idx-$1"; git -C "$D" read-tree HEAD; git -C "$D" rm -rq --cached .claude-plugin
  local tree c; tree=$(git -C "$D" write-tree); c=$("${G[@]}" -C "$D" commit-tree "$tree" -m noplugin); unset GIT_INDEX_FILE; git -C "$D" tag -f v0.1.0 "$c" >/dev/null; }
nopluginfix devnone; edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.1.0"' '"ref": "v0.2.0"'; commit; check
[ "$RC" = 0 ] && [ "$OUT" = "release check passed: 0.2.0.dev0" ] || fail "a dev build before any plugin release, ref the tag being prepared: exit $RC: $OUT"
nopluginfix devnone2; commit; check
expect_fail_with "a dev build before any plugin release, ref a tag that has no plugin" "source ref is v0.1.0, not v0.2.0 (no tag carries the plugin yet"
nopluginfix devnone3; edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.1.0"' '"ref": "main"'; commit; check
expect_fail_with "a dev build before any plugin release, ref main" "source ref is main, not v0.2.0 (no tag carries the plugin yet"
check --tag v0.2.0
expect_fail_with "a final tag on a dev version" "the tag v0.2.0 does not match __version__ 0.2.0.dev0"
check --tag v0.2.0.dev0
expect_fail_with "a dev tag" "is not a release tag (vX.Y.Z or vX.Y.ZrcN)"
devfix devpin; edit "$D/README.md" 'agentbus@v0.1.0`' 'agentbus@v0.2.0`'; commit; check
expect_fail_with "a dev build pinning an unreleased tag" "must pin @v0.1.0"
devfix devlog; edit "$D/CHANGELOG.md" '## 0.1.0 - 2026-11-01' '## 0.2.0 - 2026-11-20'; commit; check
expect_fail_with "a dev build with a dated heading for an unreleased version" "heading is for 0.2.0, not 0.1.0"
# Prose that names the pinned release goes stale silently: README "Setup in this release (vX)" and SECURITY.md "pins vX today".
STALE_README=$'\n| Agent | Setup in this release (v0.1.0) | From v0.2.0 |\n'
fresh stale1; printf '%s' "$STALE_README" >>"$D/README.md"; commit; check
expect_fail_with "a README that still says Setup in this release (v0.1.0) when it pins v0.2.0" "README.md: 'Setup in this release (v0.1.0)' names v0.1.0, but the install lines pin v0.2.0"
fresh stale2; printf 'Until that release (the README pins v0.1.0 today) the line is git+.\n' >"$D/SECURITY.md"; commit; check
expect_fail_with "a SECURITY.md that still says pins v0.1.0 today when the README pins v0.2.0" "SECURITY.md: 'pins v0.1.0 today' names v0.1.0, but the install lines pin v0.2.0"
fresh stale3; printf '%s' "${STALE_README//v0.1.0/v0.2.0}" >>"$D/README.md"; printf 'The README pins v0.2.0 today.\n' >"$D/SECURITY.md"; commit; check
[ "$RC" = 0 ] || fail "prose that names the pinned release passes (control): exit $RC: $OUT"
devfix stale4; printf '%s' "$STALE_README" >>"$D/README.md"; printf 'Until that release (the README pins v0.1.0 today) the line is git+.\n' >"$D/SECURITY.md"; commit; check
[ "$RC" = 0 ] || fail "a dev build whose prose names the last release it pins (control): exit $RC: $OUT"
ok "clean passes; rc tag passes; absent plugin files are skipped; a dev version passes untagged and never on a tag; the marketplace ref is always a tag; stale prose pins fail"

echo
echo "TEST: a release candidate tag must build the rc version; only rc pre-releases are accepted"
fresh rc2; check --tag v0.2.0rc1
expect_fail_with "rc tag on a final version" "the tag v0.2.0rc1 does not match __version__ 0.2.0"
fresh rc3; edit "$D/bin/agentbus" '__version__ = "0.2.0"' '__version__ = "0.2.0rc1"'; commit; check --tag v0.2.0
expect_fail_with "final tag on an rc version" "the tag v0.2.0 does not match __version__ 0.2.0rc1"
for t in v0.2.0a1 v0.2.0b2 v0.2.0.dev1 v0.2 v0.2.0-rc1 0.2.0; do
  fresh badtag; check --tag "$t"
  expect_fail_with "tag $t" "is not a release tag (vX.Y.Z or vX.Y.ZrcN)"
done
ok "rc builds 0.2.0rc1; a and b and every other shape are refused"

echo
echo "TEST: a release must come from main (the tagged commit is an ancestor of origin/main)"
fresh anc; echo more >"$D/more.txt"; git -C "$D" add -A; "${G[@]}" -C "$D" commit -q -m "off main"; check --tag v0.2.0
expect_fail_with "off main" "is not an ancestor of origin/main"
fresh anc2; git -C "$D" update-ref -d refs/remotes/origin/main; check --tag v0.2.0
expect_fail_with "no origin/main" "origin/main is not available"
fresh anc3; echo more >"$D/more.txt"; git -C "$D" add -A; "${G[@]}" -C "$D" commit -q -m "on main"; git -C "$D" update-ref refs/remotes/origin/main HEAD; check --tag v0.2.0
[ "$RC" = 0 ] || fail "a commit on main: exit $RC: $OUT"
fresh anc4; echo more >"$D/more.txt"; git -C "$D" add -A; "${G[@]}" -C "$D" commit -q -m "off main"; check
[ "$RC" = 0 ] || fail "without --tag the ancestry is not checked: exit $RC: $OUT"
ok "off-main tags fail; on-main tags pass"

echo
echo "TEST: each mismatch fails with a message naming it"
fresh tag; check --tag v0.2.1
expect_fail_with "tag vs version" "the tag v0.2.1 does not match __version__ 0.2.0"
fresh heading; edit "$D/CHANGELOG.md" '## 0.2.0 - 2026-11-20' '## 0.2.0'; commit; check
expect_fail_with "changelog heading" "the first CHANGELOG.md heading after Unreleased is '0.2.0'"
fresh heading2; edit "$D/CHANGELOG.md" '## 0.2.0 - 2026-11-20' '## 0.1.9 - 2026-11-20'; commit; check
expect_fail_with "changelog version" "heading is for 0.1.9, not 0.2.0"
fresh pin; edit "$D/README.md" 'agentbus@v0.2.0`' 'agentbus@v0.1.0`'; commit; check
expect_fail_with "readme pin" "README.md: the install line git+https://github.com/wickdninja/agentbus@v0.1.0 must pin @v0.2.0"
fresh unpinned; edit "$D/docs/how-to/setup.md" 'agentbus@v0.2.0' 'agentbus'; commit; check
expect_fail_with "docs pin" "docs/how-to/setup.md: the install line git+https://github.com/wickdninja/agentbus must pin @v0.2.0"
fresh dirty; echo x >"$D/stray.txt"; check
expect_fail_with "dirty tree" "git status is not clean"
fresh market; edit "$D/.claude-plugin/marketplace.json" '{"source": "git", "url": "https://github.com/wickdninja/agentbus.git", "ref": "v0.2.0"}' '"./"'; commit; check
expect_fail_with "marketplace path source" "marketplace.json source './' is a path"
fresh mref; edit "$D/.claude-plugin/marketplace.json" '"ref": "v0.2.0"' '"ref": "v0.1.0"'; commit; check
expect_fail_with "marketplace ref" "source ref is v0.1.0, not v0.2.0"
fresh pver; edit "$D/.claude-plugin/plugin.json" '"0.2.0"' '"0.1.0"'; commit; check
expect_fail_with "plugin version" "plugin.json version is 0.1.0, not 0.2.0"
fresh skillhash; printf 'one more rule\n' >>"$D/skills/agentbus/SKILL.md"; commit; check
expect_fail_with "skill hash" "not in SKILL_SHA256_HISTORY"
fresh agentshash; edit "$D/bin/agentbus" "$ASHA" "$SHA"; commit; check
expect_fail_with "agents block hash" "AGENTS.md block hash is not in AGENTS_SHA256_HISTORY"
fresh all; edit "$D/CHANGELOG.md" '## 0.2.0 - 2026-11-20' '## 0.2.0'; echo x >"$D/stray.txt"; check --tag v0.3.0
[ "$RC" = 1 ] && [ "$(grep -c '^release check failed' <<<"$OUT")" -ge 3 ] || fail "several problems must all be listed: $OUT"
grep -q 'release check passed' <<<"$OUT" && fail "printed success with problems"
ok "tag, heading, pins, dirty tree, marketplace, plugin version and skill hash each fail by name"

echo "TEST: DIST_NAME must equal the pyproject name, and a final tag may not sit below the highest final tag"
fresh dist; edit "$D/bin/agentbus" 'DIST_NAME = "agentbus"' 'DIST_NAME = "agentbus-other"'; commit; check
expect_fail_with "DIST_NAME vs pyproject" "DIST_NAME is agentbus-other, but pyproject.toml names the project agentbus"
fresh nodist; edit "$D/bin/agentbus" 'DIST_NAME = "agentbus"' 'XDIST_NAME = "agentbus"'; commit; check
expect_fail_with "no DIST_NAME" "bin/agentbus has no DIST_NAME"
fresh lower; git -C "$D" tag v0.3.0; check --tag v0.2.0
expect_fail_with "a final tag below the highest" "the tag v0.2.0 is below the highest final release tag v0.3.0"
fresh lowerrc; git -C "$D" tag v0.3.0rc1; check --tag v0.2.0
[ "$RC" = 0 ] || fail "an rc tag above the final one is ignored (control): exit $RC: $OUT"
fresh lowerok; git -C "$D" tag v0.1.5; check --tag v0.2.0
[ "$RC" = 0 ] || fail "a final tag above every existing final passes (control): exit $RC: $OUT"
ok "DIST_NAME is checked against pyproject; a final tag below the highest final fails, rc tags are ignored"

echo "TEST: check_sums.sh publishes exactly the files named in the sums: none extra, none missing, none changed"
fresh sums; cp "$ROOT/scripts/check_sums.sh" "$D/scripts/"
mkdir "$T/dist"; printf 'wheel bytes' >"$T/dist/a-1.0-py3-none-any.whl"; printf 'sdist bytes' >"$T/dist/a-1.0.tar.gz"
(cd "$T/dist" && shasum -a 256 a-1.0-py3-none-any.whl a-1.0.tar.gz >SHA256SUMS); cp "$T/dist/SHA256SUMS" "$T/expected"
RC=0; OUT=$(bash "$D/scripts/check_sums.sh" "$T/dist" "$T/expected" 2>&1) || RC=$?
[ "$RC" = 0 ] && [ "$(tail -n 1 <<<"$OUT")" = "files match the recorded sha256s: a-1.0-py3-none-any.whl a-1.0.tar.gz" ] || fail "good files: exit $RC: $OUT"
printf 'extra' >"$T/dist/extra.whl"
RC=0; OUT=$(bash "$D/scripts/check_sums.sh" "$T/dist" "$T/expected" 2>&1) || RC=$?
[ "$RC" = 1 ] && grep -qF "extra.whl is not in the recorded sums" <<<"$OUT" || fail "an extra file: exit $RC: $OUT"
rm "$T/dist/extra.whl"; rm "$T/dist/a-1.0.tar.gz"
RC=0; OUT=$(bash "$D/scripts/check_sums.sh" "$T/dist" "$T/expected" 2>&1) || RC=$?
[ "$RC" = 1 ] && grep -qF "a-1.0.tar.gz is missing" <<<"$OUT" || fail "a missing file: exit $RC: $OUT"
printf 'sdist bytes' >"$T/dist/a-1.0.tar.gz"; printf 'tampered' >"$T/dist/a-1.0-py3-none-any.whl"
RC=0; OUT=$(bash "$D/scripts/check_sums.sh" "$T/dist" "$T/expected" 2>&1) || RC=$?
[ "$RC" = 1 ] || fail "a changed file: exit $RC: $OUT"
printf 'wheel bytes' >"$T/dist/a-1.0-py3-none-any.whl"; printf '%s\n' "$(cat "$T/expected")" "0000000000000000000000000000000000000000000000000000000000000000  other.whl" >"$T/dist/SHA256SUMS"
RC=0; OUT=$(bash "$D/scripts/check_sums.sh" "$T/dist" "$T/expected" 2>&1) || RC=$?
[ "$RC" = 1 ] && grep -qF "differs from the sums the build job emitted" <<<"$OUT" || fail "a SHA256SUMS that is not the emitted one: exit $RC: $OUT"
ok "check_sums.sh: exact file set, exact bytes, exact SHA256SUMS"

echo
echo "TEST: the README's install lines are the generated ones: the release wheel's URL once the release is listed in tests/released_wheels.txt, git+ before"
WURL=https://github.com/wickdninja/agentbus/releases/download/v0.2.0/agentbus-0.2.0-py3-none-any.whl
fresh lines; RC=0; OUT=$(cd "$D" && "$PY" scripts/release_check.py --lines v0.2.0 2>&1) || RC=$?
[ "$RC" = 0 ] && [ "$OUT" = $'uv tool install git+https://github.com/wickdninja/agentbus@v0.2.0\npipx install --force git+https://github.com/wickdninja/agentbus@v0.2.0' ] || fail "--lines before the release is listed: exit $RC: $OUT"
OUT=$(cd "$D" && "$PY" scripts/release_check.py --wheel --lines v0.2.0 2>&1)
[ "$OUT" = $'uv tool install '"$WURL"$'\npipx install --force '"$WURL" ] || fail "--wheel --lines: $OUT"
RC=0; OUT=$(cd "$D" && "$PY" scripts/release_check.py --lines main 2>&1) || RC=$?
[ "$RC" != 0 ] && grep -qF "not a final release tag" <<<"$OUT" || fail "--lines main: exit $RC: $OUT"
wheelfix() { fresh "$1"; printf '# tags that publish a wheel\nv0.2.0\n' >"$D/tests/released_wheels.txt"
  printf '# agentbus\n\n```bash\nuv tool install %s\n```\n\nor `pipx install --force %s`.\n' "$WURL" "$WURL" >"$D/README.md"; }
wheelfix wheelok; commit; check
[ "$RC" = 0 ] || fail "a README with the wheel lines for a wheel release: exit $RC: $OUT"
wheelfix wheelgit; printf '# agentbus\n\n```bash\nuv tool install git+https://github.com/wickdninja/agentbus@v0.2.0\n```\n\nor `pipx install --force git+https://github.com/wickdninja/agentbus@v0.2.0`.\n' >"$D/README.md"; commit; check
expect_fail_with "git+ lines for a wheel release" "README.md must carry the install line: uv tool install $WURL"
grep -qF "still has a git+ install line, but v0.2.0 publishes a wheel" <<<"$OUT" || fail "the git+ line was not named: $OUT"
wheelfix wheelbad; edit "$D/README.md" "download/v0.2.0/agentbus-0.2.0" "download/v0.1.0/agentbus-0.2.0"; commit; check
expect_fail_with "a wheel URL naming another tag" "must name v0.2.0 in its path and 0.2.0 in its file name"
fresh gitok; printf '# tags that publish a wheel\nv0.1.0\n' >"$D/tests/released_wheels.txt"; commit; check
[ "$RC" = 0 ] || fail "a wheel list that names another release leaves the git+ README valid: exit $RC: $OUT"
ok "generated lines (--lines, --wheel); a wheel release needs the wheel URLs and no git+ line; any other needs git+"

echo
echo "TEST: verify_published.sh runs only the README's literal pinned lines, and refuses anything else"
fresh vp; cp "$ROOT/scripts/verify_published.sh" "$D/scripts/"
RC=0; OUT=$(bash "$D/scripts/verify_published.sh" v0.2.0 --dry-run 2>&1) || RC=$?
[ "$RC" = 0 ] || fail "dry run: exit $RC: $OUT"
[ "$OUT" = $'uv tool install git+https://github.com/wickdninja/agentbus@v0.2.0\npipx install --force git+https://github.com/wickdninja/agentbus@v0.2.0' ] || fail "dry run printed: $OUT"
RC=0; OUT=$(bash "$D/scripts/verify_published.sh" v0.3.0 --dry-run 2>&1) || RC=$?
[ "$RC" = 1 ] && grep -qF "README.md does not contain the line: uv tool install git+https://github.com/wickdninja/agentbus@v0.3.0" <<<"$OUT" || fail "a tag the README does not pin: exit $RC: $OUT"
RC=0; OUT=$(bash "$D/scripts/verify_published.sh" main --dry-run 2>&1) || RC=$?
[ "$RC" = 2 ] && grep -qF "'main' is not a release tag" <<<"$OUT" || fail "a branch name: exit $RC: $OUT"
RC=0; OUT=$(bash "$D/scripts/verify_published.sh" v0.2.0rc1 --dry-run 2>&1) || RC=$?
[ "$RC" = 2 ] && grep -qF "release candidate" <<<"$OUT" || fail "an rc tag: exit $RC: $OUT"
RC=0; OUT=$(bash "$D/scripts/verify_published.sh" v0.2.0 --bogus 2>&1) || RC=$?
[ "$RC" = 2 ] || fail "an unknown option: exit $RC: $OUT"
fresh vpw; printf 'v0.2.0\n' >"$D/tests/released_wheels.txt"; cp "$ROOT/scripts/verify_published.sh" "$D/scripts/"
printf '# agentbus\n\n```bash\nuv tool install %s\n```\n\nor `pipx install --force %s`.\n' "$WURL" "$WURL" >"$D/README.md"
RC=0; OUT=$(bash "$D/scripts/verify_published.sh" v0.2.0 --dry-run 2>&1) || RC=$?
[ "$RC" = 0 ] && [ "$OUT" = $'uv tool install '"$WURL"$'\npipx install --force '"$WURL" ] || fail "dry run for a wheel release: exit $RC: $OUT"
ok "verify_published.sh: literal lines from the README (the wheel URL for a wheel release), a tag shape, nothing else"

echo
echo "TEST: the real tree passes the checks that do not depend on a release commit"
# Before the release-prep commit the tree may be dirty or lack a dated heading; what must always hold is
# that the script runs and reads the real files (it names the checks it fails, never a traceback).
RC=0; OUT=$("$PY" "$ROOT/scripts/release_check.py" 2>&1) || RC=$?
grep -q Traceback <<<"$OUT" && fail "traceback on the real tree: $OUT"
[ "$RC" = 0 ] || grep -q '^release check failed: ' <<<"$OUT" || fail "unexpected output: $OUT"
ok "the real tree gives a verdict without a traceback"

echo
echo "All release check tests passed"
