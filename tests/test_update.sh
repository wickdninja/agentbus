#!/bin/bash
set -euo pipefail
# `agentbus update` (plan 13, Design 4 and 5): the tool step through a stub installer on PATH (never a real uv, pipx or
# pip), the bus step and setup step through the NEW executable, the outcome table of the release lookup, and the JSON
# contract. The lookup answers from tests/fixtures/release_server.py. Each case runs a fake install, not the checkout.
. "$(dirname "$0")/update_lib.sh"
T=$(mktemp -d); trap 'stop_servers; rm -rf "$T"' EXIT
mkdir "$T/srv"; start_server "$T/srv"; rel_latest 0.3.0
export CLAUDE_CONFIG_DIR="$T/cc"
repo_spec="git+$REPO_URL@v0.3.0"
ej() { tail -n 1 "$2" | jx "$1"; }   # a field of the JSON error on the last line of a stderr file (an installer may print before it)
errof() { "$PY" -I -c 'import json,sys; print(json.loads(sys.stdin.read().strip().splitlines()[-1])["error"]["code"])'; }

echo "TEST 1: every installer argv names the repository at a v tag and runs from HOME"
for m in uv pipx pip; do
  new_case "argv-$m" "$m"
  out=$(ab update --no-buses --no-setup) || fail "$m: update failed: $out"
  grep -qF -- "ARGV:" "$STUB_LOG" && grep -qF -- "$repo_spec" "$STUB_LOG" || fail "$m: the argv lacks $repo_spec: $(cat "$STUB_LOG")"
  grep -qxF "CWD: $(cd "$HOME" && pwd -P)" "$STUB_LOG" || fail "$m: the installer did not run from HOME: $(cat "$STUB_LOG")"
  [ "$(installed_version)" = 0.3.0 ] || fail "$m: the stub did not move the install"
  grep -qF "agentbus 0.3.0 is installed." <<<"$out" && grep -qF "done: 0.2.0 -> 0.3.0. Restart Claude Code and Codex sessions, and any agentbus watch, to load it." <<<"$out" || fail "$m: output: $out"
done
grep -qF -- "ARGV: pip install --upgrade $repo_spec" "$STUB_LOG" || fail "pip: $(cat "$STUB_LOG")"
ok "uv, pipx and pip: the repository at v0.3.0, cwd HOME"

echo "TEST 2: a pip/ planted in the working folder does not run under -I -m pip (the control without -I does)"
new_case plant pip
mkdir -p "$HOME/pip"; : >"$HOME/pip/__init__.py"; printf 'open(%s, "w").write("planted")\n' "'$C/marker'" >"$HOME/pip/__main__.py"
(cd "$HOME" && "$PREFIX/bin/python" -m pip control >/dev/null 2>&1) || true
[ -f "$C/marker" ] || fail "the control (no -I) did not run the planted pip: the test proves nothing"
rm -f "$C/marker"
ab update --no-buses --no-setup >/dev/null 2>&1 || true
[ ! -f "$C/marker" ] || fail "the planted pip ran under -I -m pip"
grep -qF "pip install --upgrade" "$STUB_LOG" || fail "the real (stub) pip did not run: $(cat "$STUB_LOG")"
ok "no marker with -I; the control writes one"

echo "TEST 3: an installer on a relative, in-repo or group-writable PATH entry is skipped (manual_step); a clean one runs"
new_case path uv
mkdir -p "$CWD/rel"; cp "$C/stubs/uv" "$CWD/rel/uv"
PATH="rel:/usr/bin:/bin" ab update --no-buses --no-setup --json 2>"$C/err" >/dev/null && fail "a relative PATH entry was used"
[ "$(errof <"$C/err")" = manual_step ] || fail "relative entry: $(cat "$C/err")"
mkdir -p "$C/inrepo/bin"; mkrepo "$C/inrepo"; cp "$C/stubs/uv" "$C/inrepo/bin/uv"; chmod 755 "$C/inrepo/bin"
(cd "$C/inrepo" && PATH="$C/inrepo/bin:/usr/bin:/bin" "$ENTRY" update --no-buses --no-setup --json 2>"$C/err" >/dev/null) && fail "an in-repo PATH entry was used"
[ "$(errof <"$C/err")" = manual_step ] || fail "in-repo entry: $(cat "$C/err")"
mkdir -p "$C/gw"; cp "$C/stubs/uv" "$C/gw/uv"; chmod 770 "$C/gw"
PATH="$C/gw:/usr/bin:/bin" ab update --no-buses --no-setup --json 2>"$C/err" >/dev/null && fail "a group-writable PATH entry was used"
[ "$(errof <"$C/err")" = manual_step ] || fail "group-writable entry: $(cat "$C/err")"
grep -qF "$repo_spec" "$C/err" || fail "the manual_step does not print the command: $(cat "$C/err")"
[ ! -s "$STUB_LOG" ] || fail "a skipped installer ran: $(cat "$STUB_LOG")"
ab update --no-buses --no-setup >/dev/null || fail "the clean stub dir (control) did not run"
[ -s "$STUB_LOG" ] || fail "the control installer left no log"
ok "relative, in-repo and group-writable are skipped; the clean one (control) runs"

echo "TEST 4: a hostile latest (1!9.0.0, 0.1.0, 9.0.0+x) never reaches an argv"
for tag in "1!9.0.0" "0.1.0" "9.0.0+x" "0.3.0;id" "0.3.0 --index-url=x"; do
  new_case hostile uv; answer "{\"body\": \"{\\\"tag_name\\\": \\\"v$tag\\\"}\"}"
  ab update --no-buses --no-setup >"$C/out" 2>&1 || true
  [ ! -s "$STUB_LOG" ] || fail "tag '$tag' reached an installer: $(cat "$STUB_LOG")"
done
ok "no installer ran for any of them"

echo "TEST 5: --dry-run prints would run: with the exact argv and the planned rows, and changes nothing"
new_case dry uv; rel_latest 0.3.0
new_bus "$C/b1"; new_bus "$C/b2"; mkdir -p "$C/gone"; new_bus "$C/gone/b3"; rm -rf "$C/gone"
mkdir -p "$C/root/x"; new_bus "$C/root/x"
ab update "$C/root" --dry-run >/dev/null || fail "recording the root failed (dry-run records nothing, so this is the control for the next line)"
before=$(tree_sum "$PREFIX" "$C/b1" "$C/b2" "$C/root" "$(state_path)" "$HOME/.claude" )
out=$(ab update --dry-run --all-buses) || fail "dry run failed: $out"
grep -qF "would run: $C/stubs/uv tool install --force $repo_spec" <<<"$out" || fail "no exact would run line: $out"
grep -qF "$C/b1" <<<"$out" || fail "a planned bus row is missing: $out"
grep -qF "dry run: nothing was changed." <<<"$out" || fail "dry run summary: $out"
after=$(tree_sum "$PREFIX" "$C/b1" "$C/b2" "$C/root" "$(state_path)" "$HOME/.claude")
[ "$before" = "$after" ] || fail "--dry-run changed the install, a bus folder or the state folder"
[ ! -e "$(state_path)/update.lock" ] || fail "--dry-run created update.lock"
[ ! -s "$STUB_LOG" ] || fail "--dry-run ran the installer"
j=$(ab update --dry-run --all-buses --json) || fail "dry run json failed"
[ "$(jx 'd["tool"]["status"]' <<<"$j")" = dry_run ] && [ "$(jx 'd["restart"]' <<<"$j")" = False ] || fail "dry-run json: $j"
[ "$(jx 'sorted(r["directory"] for r in d["buses"] if r["status"] == "skipped")' <<<"$j")" = "['$C/gone/b3']" ] || fail "the vanished folder is not reported: $j"
ok "exact argv, vanished folder reported and still listed, nothing changed"

echo "TEST 6: installer exit 1, a hang killed by SIGTERM, an unchanged version: installer_failed with the recovery line and no bus step"
new_case fail uv; new_bus "$C/b"; before=$(bus_version "$C/b")
STUB_FAIL=1 ab update --json 2>"$C/err" >/dev/null && fail "a failing installer exited 0"
[ "$(errof <"$C/err")" = installer_failed ] && [ "$(ej 'd["error"]["reason"]' "$C/err")" = exit ] && [ "$(ej 'd["error"]["exit_status"]' "$C/err")" = 1 ] || fail "exit 1: $(cat "$C/err")"
grep -qF "$repo_spec" <<<"$(ej 'd["error"]["recovery"]' "$C/err")" || fail "no recovery command: $(cat "$C/err")"
[ "$(bus_version "$C/b")" = "$before" ] || fail "a bus step ran after a failed installer"
: >"$STUB_LOG"
STUB_HANG=1 AGENTBUS_TEST_INSTALLER_TIMEOUT=1 AGENTBUS_TEST_INSTALLER_GRACE=5 ab update --json 2>"$C/err" >/dev/null && fail "a hanging installer exited 0"
[ "$(ej 'd["error"]["reason"]' "$C/err")" = timeout ] || fail "timeout: $(cat "$C/err")"
grep -qx "TERM" "$STUB_LOG" || fail "the hung installer was never sent SIGTERM: $(cat "$STUB_LOG")"
: >"$STUB_LOG"
STUB_NOBUMP=1 ab update --json 2>"$C/err" >/dev/null && fail "an installer that changed nothing exited 0"
[ "$(ej 'd["error"]["reason"]' "$C/err")" = version_unchanged ] || fail "unchanged: $(cat "$C/err")"
[ "$(bus_version "$C/b")" = "$before" ] || fail "a bus step ran after an unchanged version"
ok "exit, timeout (SIGTERM seen) and version_unchanged are installer_failed; no bus is touched"

echo "TEST 7: Ctrl-C during the installer is interrupted (130) with the argv and the rerun line"
new_case int uv; export STUB_STARTED="$C/started"
# A background job of a script ignores SIGINT, and python then never installs its Ctrl-C handler: reset it first.
( cd "$CWD" && STUB_HANG=1 exec "$PY" -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
  "$ENTRY" update --json --no-buses --no-setup 2>"$C/err" >/dev/null ) &
pid=$!
wait_for "$C/started"
kill -INT "$pid"
rc=0; wait "$pid" || rc=$?
unset STUB_STARTED
[ "$rc" = 130 ] || fail "Ctrl-C exited $rc, wanted 130: $(cat "$C/err")"
[ "$(errof <"$C/err")" = interrupted ] && [ "$(ej 'd["error"]["rerun"]' "$C/err")" = "agentbus update" ] \
  && grep -qF "$repo_spec" <<<"$(ej 'd["error"]["argv"]' "$C/err")" || fail "interrupted error: $(cat "$C/err")"
grep -qx "TERM" "$STUB_LOG" || fail "the installer was left running: $(cat "$STUB_LOG")"
ok "130, argv, rerun, installer stopped"

echo "TEST 8: the bus step runs in the NEW executable (the copy it writes is the new version), and a DIR with .agentbus is a bus"
new_case buses uv; new_bus "$C/b1"; new_bus "$C/b2"
[ "$(bus_version "$C/b1")" = 0.2.0 ] || fail "setup: the fake install's init wrote $(bus_version "$C/b1")"
out=$(ab update --no-setup --all-buses "$C/b1") || fail "update failed: $out"
[ "$(bus_version "$C/b1")" = 0.3.0 ] || fail "the bus got $(bus_version "$C/b1"): the old executable ran upgrade"
[ "$(bus_version "$C/b2")" = 0.2.0 ] || fail "a DIR named one bus, but b2 was upgraded"
grep -qF "bus folders: upgraded 1, current 0, skipped 0, failed 0" <<<"$out" || fail "counts: $out"
out=$(ab update --no-setup --all-buses) || fail "update of the list failed: $out"
[ "$(bus_version "$C/b2")" = 0.3.0 ] || fail "the recorded bus b2 was not upgraded by a plain update: $out"
ok "upgrade ran in 0.3.0; a DIR is one bus; the recorded list reaches the other"

echo "TEST 9: a folder that is not a bus is a root, remembered for next time"
new_case roots uv
mkdir -p "$C/src"; (HOME="$C/otherhome" && mkdir -p "$HOME" && new_bus "$C/src/a" && new_bus "$C/src/b")
out=$(ab update --no-setup "$C/src") || fail "update of a root failed: $out"
[ "$(bus_version "$C/src/a")" = 0.3.0 ] && [ "$(bus_version "$C/src/b")" = 0.3.0 ] || fail "the root's buses were not upgraded: $out"
grep -qF "$C/src" "$(state_path)/buses.json" || fail "the root was not remembered: $(cat "$(state_path)/buses.json")"
(HOME="$C/otherhome" new_bus "$C/src/c")
reset_module
ab update --no-setup --all-buses >/dev/null || fail "the second update failed"
[ "$(bus_version "$C/src/c")" = 0.3.0 ] || fail "a later bus under the remembered root was missed"
ok "roots come only from an explicit DIR and are used afterwards"

echo "TEST 10: an agent session is narrowed to the current bus, says why, and skips setup; --all-buses and a human terminal are not"
new_case scope uv; new_bus "$C/cur"; new_bus "$C/other"
use_fake_module
# reset_old: the installed module is the REAL script again at 0.2.0 (the stub installer replaces it with the fake one).
reset_old() { reset_module; : >"$FAKE_LOG"; }
exact_line() { echo "agent session ($1): upgrading this bus only and skipping setup. Run with --all-buses for the rest."; }
for sig in CLAUDECODE CODEX_THREAD_ID CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED; do
  reset_old
  out=$(cd "$C/cur" && env "$sig=1" "$ENTRY" update) || fail "$sig: $out"
  grep -qxF "$(exact_line "$sig is set")" <<<"$out" || fail "$sig: no narrowing line: $out"
  ! grep -q "ARGV: setup" "$FAKE_LOG" || fail "$sig: setup ran in an agent session"
  [ "$(grep -c '^ARGV: upgrade' "$FAKE_LOG")" = 1 ] || fail "$sig: more than the current bus: $(cat "$FAKE_LOG")"
  reset_old
  j=$(cd "$C/cur" && env "$sig=1" "$ENTRY" update --json) || fail "$sig json"
  [ "$(jx 'd["scope"]' <<<"$j")" = "{'narrowed': True, 'why': '$sig'}" ] || fail "$sig scope: $j"
done
reset_old
out=$(cd "$C/cur" && "$ENTRY" update) || fail "no terminal: $out"
grep -qxF "$(exact_line "no terminal")" <<<"$out" || fail "no-terminal narrowing line: $out"
reset_old
out=$(cd "$C/cur" && CLAUDECODE=1 "$ENTRY" update --all-buses) || fail "all-buses: $out"
! grep -qF "agent session" <<<"$out" || fail "--all-buses still narrowed: $out"
grep -q "ARGV: upgrade $C/other" "$FAKE_LOG" && grep -q "ARGV: setup claude --refresh --json" "$FAKE_LOG" || fail "--all-buses did not reach the list and setup: $(cat "$FAKE_LOG")"
reset_old
out=$(cd "$C/cur" && AGENTBUS_AGENT=x "$PY" "$TESTS_DIR/pty_run.py" -- "$ENTRY" --as x update)
! grep -qF "agent session" <<<"$out" || fail "a human terminal with AGENTBUS_AGENT and --as was narrowed: $out"
grep -q "ARGV: upgrade $C/other" "$FAKE_LOG" || fail "the human terminal did not reach the whole list: $(cat "$FAKE_LOG")"
ok "CLAUDECODE, each Codex marker and no terminal narrow with the exact line and scope.why; --all-buses and a terminal do not"

echo "TEST 11: setup refresh runs in the new executable: user scope from HOME, project scope from each upgraded folder; its report is relayed"
new_case setup uv; new_bus "$C/b1"; use_fake_module
cat >"$C/setup.json" <<EOF
{"target": "claude", "scope": "user", "dry_run": false, "changes": [
 {"path": "$HOME/.claude/skills/agentbus/SKILL.md", "detail": "updated (was 0.2.0's text)", "action": "updated"},
 {"path": "$HOME/.codex/AGENTS.md", "detail": "kept (edited). To replace it: agentbus setup codex", "action": "skipped"},
 {"path": "$HOME/.unchanged-marker", "detail": "no change", "action": "unchanged"}]}
EOF
export FAKE_SETUP="$C/setup.json"
out=$(ab update --all-buses "$C/b1") || fail "update failed: $out"
unset FAKE_SETUP
grep -q "ARGV: setup claude --refresh --json" "$FAKE_LOG" && grep -q "ARGV: setup codex --refresh --json" "$FAKE_LOG" \
  && grep -q "ARGV: setup claude --scope project --refresh --json" "$FAKE_LOG" || fail "setup calls: $(cat "$FAKE_LOG")"
grep -qxF "CWD: $(cd "$C/b1" && pwd -P)" "$FAKE_LOG" || fail "project scope did not run from the bus folder: $(cat "$FAKE_LOG")"
grep -qF "  ~ ~/.claude/skills/agentbus/SKILL.md   updated (was 0.2.0's text)" <<<"$out" || fail "updated piece not shown: $out"
grep -qF "  = ~/.codex/AGENTS.md   kept (edited). To replace it: agentbus setup codex" <<<"$out" || fail "kept piece not shown: $out"
! grep -qF "unchanged-marker" <<<"$out" || fail "an unchanged piece was listed: $out"
new_case setup2 uv; new_bus "$C/b1"; use_fake_module
ab update --no-setup "$C/b1" >/dev/null; ! grep -q "ARGV: setup" "$FAKE_LOG" || fail "--no-setup ran setup"
ok "setup --refresh --json from the right folders, the report relayed, --no-setup respected"

echo "TEST 12: a plugin install gets the plugin line; claude never runs and the plugin tree is unchanged"
new_case plugin uv; mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
printf '{"version": 2, "plugins": {"agentbus@agentbus": [{"scope": "user", "version": "0.2.0"}]}}\n' >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
printf '#!/bin/bash\necho ran >>"%s/claude.log"\n' "$C" >"$C/stubs/claude"; chmod 755 "$C/stubs/claude"
before=$(tree_sum "$CLAUDE_CONFIG_DIR")
out=$(ab update --no-buses --no-setup) || fail "update failed: $out"
grep -qF "plugin: Claude Code updates it. In Claude Code: /plugin marketplace update agentbus, then /reload-plugins" <<<"$out" || fail "no plugin line: $out"
[ ! -e "$C/claude.log" ] || fail "update ran claude"
[ "$(tree_sum "$CLAUDE_CONFIG_DIR")" = "$before" ] || fail "the plugin tree changed"
ok "the line prints; claude is never run"

echo "TEST 13: a second update while one holds the lock gets update_running"
new_case lock uv; mkdir -p "$(state_path)"; chmod 700 "$(state_path)"
"$PY" -I - "$(state_path)/update.lock" "$C/held" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(30)
PY
holder=$!
wait_for "$C/held"
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "ran beside the lock"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
[ "$(errof <"$C/err")" = update_running ] && [ "$(ej 'd["error"]["lock"]' "$C/err")" = "$(state_path)/update.lock" ] || fail "update_running: $(cat "$C/err")"
[ ! -s "$STUB_LOG" ] || fail "an installer ran while the lock was held"
ab update --no-buses --no-setup >/dev/null || fail "the lock was not released (control)"
ok "update_running with the lock path; released afterwards"

echo "TEST 14: --check twice within an hour makes one request; --check never changes an install"
new_case check uv; reset_reqs
ab update --check >/dev/null; ab update --check >/dev/null
[ "$(reqs)" = 1 ] || fail "two --check runs made $(reqs) requests"
[ ! -s "$STUB_LOG" ] && [ "$(installed_version)" = 0.2.0 ] || fail "--check changed something"
j=$(ab update --check --json)
[ "$(jx 'd["update_available"]' <<<"$j")" = True ] && [ "$(jx 'd["latest"]' <<<"$j")" = 0.3.0 ] && [ "$(jx 'd["notes"]' <<<"$j")" = "$REPO_URL/releases/tag/v0.3.0" ] || fail "check json: $j"
ok "one request, nothing changed"

echo "TEST 15: 403 with X-RateLimit-Remaining 0 and 429 are rate_limited with retry_after, and --check replays it until then"
for spec in '{"status": 403, "headers": {"X-RateLimit-Remaining": "0", "Retry-After": "120"}}' '{"status": 429, "headers": {"Retry-After": "120"}}'; do
  new_case rate uv; answer "$spec"; reset_reqs
  ab update --check --json 2>"$C/err" >/dev/null && fail "rate limited exited 0"
  [ "$(errof <"$C/err")" = rate_limited ] && [ "$(ej 'd["error"]["retry_after"]' "$C/err")" = 120 ] || fail "rate_limited: $(cat "$C/err")"
  ab update --check --json 2>"$C/err" >/dev/null && fail "the replay exited 0"
  [ "$(errof <"$C/err")" = rate_limited ] && [ "$(reqs)" = 1 ] || fail "--check did not replay the limit ($(reqs) requests): $(cat "$C/err")"
  [ "$(ej 'd["error"]["retry"+"able"]' "$C/err")" = True ] || fail "rate_limited must be retryable"
done
new_case rate403 uv; answer '{"status": 403, "headers": {"X-RateLimit-Remaining": "7"}}'
ab update --check --json 2>"$C/err" >/dev/null || true
[ "$(errof <"$C/err")" = release_unknown ] || fail "a 403 that is not a rate limit is release_unknown: $(cat "$C/err")"
ok "retry_after 120 from the headers; replayed; a plain 403 is not a rate limit"

echo "TEST 16: each row of the outcome table gives its code under update and --check; 404 is 'no release is published yet.'"
row() {  # NAME ANSWER CODE REASON-or-"" [EXTRA-ENV...]
  local name=$1 spec=$2 code=$3 why=$4; shift 4
  for cmd in "update" "update --check"; do
    new_case "row-$name" uv; answer "$spec"; : >"$STUB_LOG"
    env "$@" bash -c 'cd "$1" && shift && "$@"' _ "$CWD" "$ENTRY" $cmd --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "$name ($cmd) exited 0"
    [ "$(errof <"$C/err")" = "$code" ] || fail "$name ($cmd): code $(errof <"$C/err"), wanted $code: $(cat "$C/err")"
    [ -z "$why" ] || [ "$(ej 'd["error"]["reason"]' "$C/err")" = "$why" ] || fail "$name ($cmd): reason: $(cat "$C/err")"
    [ ! -s "$STUB_LOG" ] || fail "$name ($cmd): an installer ran with no tag chosen"
  done
}
row http500 '{"status": 500}' release_unknown http X=1
row redirect '{"status": 302, "location": "/x"}' release_unknown redirect X=1
row wrongtype '{"type": "text/plain", "body": "{}"}' release_unknown malformed X=1
row badtag '{"body": "{\"tag_name\": \"nope\"}"}' release_unknown malformed X=1
row huge '{"repeat": ["x", 2097152]}' release_unknown too_large X=1
row slow '{"delay": 6, "body": "{}"}' release_offline timeout X=1
row offline '{}' release_offline offline AGENTBUS_TEST_RELEASES_URL=https://127.0.0.1:1/releases
mkdir "$T/other"; mint_cert "$T/other"   # a certificate the server does not have: verification must fail
row tls '{}' release_unknown tls "AGENTBUS_TEST_CA_FILE=$T/other/cert.pem"
new_case row404 uv; answer '{"status": 404}'
out=$(ab update --no-buses --no-setup) || fail "404 must exit 0: $out"
grep -qF "no release is published yet." <<<"$out" && [ ! -s "$STUB_LOG" ] || fail "404 text or installer: $out"
j=$(ab update --check --json) && [ "$(jx 'd["latest"]' <<<"$j")" = None ] && [ "$(jx 'd["update_available"]' <<<"$j")" = False ] || fail "404 --check json: $j"
new_case rowlow uv; rel_latest 0.1.0
out=$(ab update --no-buses --no-setup) && grep -qF "agentbus 0.2.0 is the latest release." <<<"$out" && [ ! -s "$STUB_LOG" ] || fail "lower-only: $out"
ok "every failure row maps to its code and reason, no installer runs; 404 and lower-only exit 0"

echo "TEST 17: a clone and an unknown install give manual_step and no upgrade or setup child runs; a uv install runs both"
rel_latest 0.3.0   # TEST 16 left the server saying 0.1.0
new_case manual uv; new_bus "$C/b"; use_fake_module
mkdir -p "$C/clone/bin" "$C/clone/.git"; sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$UPDATE_SRC" >"$C/clone/bin/agentbus"; : >"$C/clone/pyproject.toml"
(cd "$CWD" && "$PREFIX/bin/python" "$C/clone/bin/agentbus" update --json --all-buses 2>"$C/err" >/dev/null) && fail "a clone updated itself"
[ "$(errof <"$C/err")" = manual_step ] || fail "clone: $(cat "$C/err")"
printf '' >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
ab update --json --all-buses 2>"$C/err" >/dev/null && fail "an unknown install updated itself"
[ "$(errof <"$C/err")" = manual_step ] || fail "unknown: $(cat "$C/err")"
[ ! -s "$FAKE_LOG" ] && [ ! -s "$STUB_LOG" ] || fail "a child ran after manual_step: $(cat "$FAKE_LOG" "$STUB_LOG")"
printf '{"url": "%s", "vcs_info": {"vcs": "git", "commit_id": "0123456789abcdef0123456789abcdef01234567"}}\n' "$REPO_URL" >"$SITE/agentbus-0.2.0.dist-info/direct_url.json"
ab update --all-buses >/dev/null || fail "the uv install (control) failed"
grep -q "^ARGV: upgrade" "$FAKE_LOG" && grep -q "^ARGV: setup" "$FAKE_LOG" || fail "the uv install did not run both: $(cat "$FAKE_LOG")"
ok "manual_step ends the run before steps 2 to 4"

echo "TEST 18: a failed bus is items_failed with the whole result on stdout; the tool step stands"
new_case itemfail uv; new_bus "$C/good"; new_bus "$C/bad"
rm "$C/bad/.agentbus/bin/agentbus"; ln -s /bin/sh "$C/bad/.agentbus/bin/agentbus"
ab update --json --no-setup --all-buses "$C/good" >/dev/null || fail "setup of the control"
reset_module
ab update --json --no-setup "$C/bad" >"$C/out" 2>"$C/err" && fail "a failed bus exited 0"
[ "$(errof <"$C/err")" = items_failed ] || fail "items_failed: $(cat "$C/err")"
[ "$(jx 'd["to"]' <"$C/out")" = 0.3.0 ] && [ "$(jx 'd["buses"][0]["status"]' <"$C/out")" = failed ] || fail "whole result on stdout: $(cat "$C/out")"
[ "$(ej 'd["error"]["committed"]' "$C/err")" = True ] || fail "committed must be true after the tool moved: $(cat "$C/err")"
ok "stdout holds the result, the error says committed"

echo "TEST 19: --json validates against 'schema update --json'"
new_case schema uv; new_bus "$C/b"; use_fake_module
"$ENTRY" schema update --json >"$C/schema.json" || fail "schema update"
validate() { "$PY" -I -B - "$C/schema.json" "$1" <<'PY'
import json, sys
sys.path.insert(0, __import__("os").environ["TESTS_DIR"])
from schema_check import validate
doc = json.load(open(sys.argv[1]))
value = json.load(open(sys.argv[2]))
errs = validate(value, doc["commands"]["update"]["result"], doc["objects"])
assert not errs, errs
PY
}
ab update --check --json >"$C/r1"; validate "$C/r1" || fail "check result"
ab update --dry-run --json >"$C/r2"; validate "$C/r2" || fail "dry-run result"
ab update --json --all-buses "$C/b" >"$C/r3" || fail "real update"; validate "$C/r3" || fail "real result"
ok "check, dry-run and real results validate"

all_passed "All update tests passed"
