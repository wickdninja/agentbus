#!/bin/bash
set -euo pipefail
# scripts/record_demo.sh cuts the README's demo from the real tool. `--check` runs the same story without recording.
# Bugs it catches: the demo drifts from the tool (the last cut showed a watch that no longer ships), the script reaches
# a real HOME or bus, the caption claims more than the recording shows, or the GIF outgrows the README.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ROOT=$(dirname "$TESTS_DIR")
SCRIPT="$ROOT/scripts/record_demo.sh"

echo "TEST: every step of the story does what the script says it does, on this tree's tool"
mkdir -p "$T/home" "$T/cwd" "$T/realbus" "$T/xdg-state" "$T/xdg-config" "$T/xdg-cache"
out=$(cd "$T/cwd" && HOME="$T/home" AGENTBUS_DB="$T/realbus/bus.db" AGENTBUS_AGENT=someone XDG_STATE_HOME="$T/xdg-state" \
      XDG_CONFIG_HOME="$T/xdg-config" XDG_CACHE_HOME="$T/xdg-cache" bash "$SCRIPT" --check 2>&1) || fail "record_demo.sh --check failed: $out"
[ "$(tail -n 1 <<<"$out")" = "demo story matches the tool" ] || fail "--check did not finish: $out"
grep -qF 'ok tests: agentbus claim src/auth/' <<<"$out" || fail "the claim conflict is gone from the story: $out"
ok "the story runs on the real tool"

echo "TEST: it leaves the caller's HOME, bus and folder alone"
[ -z "$(ls -A "$T/home")" ] || fail "--check wrote to the caller's HOME: $(ls -A "$T/home")"
[ -z "$(ls -A "$T/realbus")" ] || fail "--check touched the bus in AGENTBUS_DB: $(ls -A "$T/realbus")"
[ -z "$(ls -A "$T/cwd")" ] || fail "--check wrote to the current folder: $(ls -A "$T/cwd")"
# Bug it catches: the script moved HOME but kept the caller's XDG folders, so agentbus recorded the demo's bus in the caller's state.
for x in state config cache; do
  [ -z "$(ls -A "$T/xdg-$x")" ] || fail "--check wrote to the caller's XDG_$(tr a-z A-Z <<<"$x")_HOME: $(find "$T/xdg-$x" | head -5)"
done
# The same on macOS, where agentbus does not read the XDG variables: a stand-in tool records the environment it is run with.
mkdir -p "$T/xdgprobe/scripts" "$T/xdgprobe/bin"; cp "$SCRIPT" "$T/xdgprobe/scripts/"
printf '#!/bin/sh\nprintf "%%s\\n" "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" >"%s"\nexit 0\n' "$T/xdg.seen" >"$T/xdgprobe/bin/agentbus"
(cd "$T/cwd" && HOME="$T/home" XDG_STATE_HOME="$T/xdg-state" XDG_CONFIG_HOME="$T/xdg-config" XDG_CACHE_HOME="$T/xdg-cache" \
  bash "$T/xdgprobe/scripts/record_demo.sh" --check >/dev/null 2>&1) || true
"$PY" - "$T/xdg.seen" "$T" <<'PY2' || fail "the demo's agentbus ran with the caller's XDG folders: $(cat "$T/xdg.seen" 2>/dev/null)"
import os, sys
home, *xdg = open(sys.argv[1]).read().split("\n")[:4]
assert home and os.path.realpath(home) != os.path.realpath(os.path.join(sys.argv[2], "home")), home
assert all(x.startswith(home + "/") for x in xdg), (home, xdg)
PY2
ok "HOME, the XDG folders, AGENTBUS_DB and the current folder are untouched"

echo "TEST: a tool that stops matching the story fails the check (negative control)"
mkdir -p "$T/fake/scripts" "$T/fake/bin"; cp "$SCRIPT" "$T/fake/scripts/"
printf '#!/bin/sh\nexit 0\n' >"$T/fake/bin/agentbus"
rc=0; out=$(cd "$T/cwd" && HOME="$T/home" bash "$T/fake/scripts/record_demo.sh" --check 2>&1) || rc=$?
[ "$rc" != 0 ] && grep -qF 'FAIL: claude:' <<<"$out" || fail "a tool that prints nothing passed the check (rc $rc): $out"
ok "drift fails the check"

echo "TEST: the recording script has no way to reach a real HOME, and the README says what the GIF is"
grep -qF 'export HOME="$w/home"' "$SCRIPT" || fail "the script no longer moves HOME into its temp folder"
readme=$(cat "$ROOT/README.md")
grep -qF 'scripted session driving the real tool' <<<"$readme" || fail "the README's caption must say it is a scripted session driving the real tool"
! grep -qiE 'building agentbus|agents? (are )?build(ing)? agentbus' <<<"$readme" || fail "the README must not say agents are building agentbus in the demo"
grep -qF 'src="docs/demo.gif"' <<<"$readme" || fail "the README does not show docs/demo.gif"
grep -qF 'scripts/record_demo.sh' <<<"$readme" || fail "the README does not say how the demo is cut"
"$PY" - "$ROOT/docs/demo.gif" <<'PY' || fail "docs/demo.gif"
import os, struct, sys
data = open(sys.argv[1], "rb").read(10)
assert data[:6] in (b"GIF87a", b"GIF89a"), "not a GIF"
width, height = struct.unpack("<HH", data[6:10])
assert width <= 1280 and height <= 720, "too large: %dx%d" % (width, height)
assert os.path.getsize(sys.argv[1]) < 5 * 1024 * 1024, "over 5 MB"
PY
ok "the caption and the GIF are what the README promises"
echo "All record_demo tests passed"
