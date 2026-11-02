#!/bin/bash
# bash scripts/check_sums.sh DIR EXPECTED
# DIR holds the files about to be published (a wheel, an sdist, SHA256SUMS). EXPECTED is the sha256 list the
# build job emitted as a job output (lines `<sha256>  <name>`), which is not stored in DIR. Fails unless:
# DIR holds exactly the files EXPECTED names plus SHA256SUMS (no extra, none missing), every file has the
# recorded bytes, and DIR/SHA256SUMS is the emitted list itself. Last line:
# `files match the recorded sha256s: <names>`.
set -u
DIR="${1:?usage: check_sums.sh DIR EXPECTED}"; EXPECTED="${2:?usage: check_sums.sh DIR EXPECTED}"
[ -d "$DIR" ] && [ -s "$EXPECTED" ] || { echo "FAIL: $DIR or $EXPECTED is missing or empty" >&2; exit 1; }
names=$(awk '{print $2}' "$EXPECTED" | sort)
[ -n "$names" ] || { echo "FAIL: $EXPECTED names no files" >&2; exit 1; }
for n in $names; do
  [ -f "$DIR/$n" ] || { echo "FAIL: $n is missing from $DIR" >&2; exit 1; }
done
for f in $(ls -A "$DIR"); do
  [ "$f" = SHA256SUMS ] && continue
  grep -qxF "$f" <<<"$names" || { echo "FAIL: $f is not in the recorded sums; it would be published without being verified" >&2; exit 1; }
done
[ -f "$DIR/SHA256SUMS" ] && cmp -s "$DIR/SHA256SUMS" "$EXPECTED" || { echo "FAIL: SHA256SUMS differs from the sums the build job emitted" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then (cd "$DIR" && sha256sum -c "$(cd "$(dirname "$EXPECTED")" && pwd)/$(basename "$EXPECTED")" >/dev/null) || { echo "FAIL: a file differs from its recorded sha256" >&2; exit 1; }
else (cd "$DIR" && shasum -a 256 -c "$(cd "$(dirname "$EXPECTED")" && pwd)/$(basename "$EXPECTED")" >/dev/null) || { echo "FAIL: a file differs from its recorded sha256" >&2; exit 1; }; fi
echo "files match the recorded sha256s: $(tr '\n' ' ' <<<"$names" | sed 's/ $//')"
