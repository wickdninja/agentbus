#!/bin/bash
set -euo pipefail
# `agentbus update` (plan 13, Design 4 and 5): the tool step through a stub installer on PATH (never a real uv, pipx or
# pip), the bus step and setup step through the NEW executable, the outcome table of the release lookup, and the JSON
# contract. The lookup answers from tests/fixtures/release_server.py. Each case runs a fake install, not the checkout.
. "$(dirname "$0")/update_lib.sh"
T=$(mktemp -d); trap 'stop_servers; rm -rf "$T"' EXIT
mkdir "$T/srv"; start_server "$T/srv"; rel_latest 0.3.0
export CLAUDE_CONFIG_DIR="$T/cc"
repo_spec="git+$REPO_URL@v0.3.0"   # the source-build line, printed for a fork or for a release that has no wheel
wheel_url="$REPO_URL/releases/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl"   # what a person runs when update cannot run an installer
wheel_rel="downloads/agentbus-0.3.0-py3-none-any.whl"   # under the cache folder: where the verified release wheel is put
ej() { tail -n 1 "$2" | jx "$1"; }   # a field of the JSON error on the last line of a stderr file (an installer may print before it)
errof() { "$PY" -I -c 'import json,sys; print(json.loads(sys.stdin.read().strip().splitlines()[-1])["error"]["code"])'; }

echo "TEST 1: every installer is given the release wheel after its sha256 was checked, and runs from the cache folder"
for m in uv pipx pip; do
  new_case "argv-$m" "$m"
  out=$(ab update --no-buses --no-setup) || fail "$m: update failed: $out"
  grep -qF -- "ARGV:" "$STUB_LOG" && grep -qF -- "$(cache_path)/$wheel_rel" "$STUB_LOG" || fail "$m: the argv lacks the release wheel: $(cat "$STUB_LOG")"
  ! grep -qF -- "git+" "$STUB_LOG" || fail "$m: the installer was given a source tree to build: $(cat "$STUB_LOG")"
  grep -qxF "WHEEL_SHA: $(shasum -a 256 "$SERVER/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl" | cut -d' ' -f1)" "$STUB_LOG" || fail "$m: the installer did not get the verified wheel: $(cat "$STUB_LOG")"
  grep -qxF "CWD: $(cache_path)" "$STUB_LOG" || fail "$m: the installer did not run from the cache folder: $(cat "$STUB_LOG")"
  [ -z "$(ls -A "$(cache_path)/downloads" 2>/dev/null)" ] || fail "$m: the download was left behind: $(ls "$(cache_path)/downloads")"
  [ "$(installed_version)" = 0.3.0 ] || fail "$m: the stub did not move the install"
  grep -qF "agentbus 0.3.0 is installed." <<<"$out" && grep -qF "done: 0.2.0 -> 0.3.0. Restart Claude Code and Codex sessions, and any agentbus watch, to load it." <<<"$out" || fail "$m: output: $out"
done
grep -qF -- "ARGV: pip install --upgrade $(cache_path)/$wheel_rel" "$STUB_LOG" || fail "pip: $(cat "$STUB_LOG")"
ok "uv, pipx and pip: the verified release wheel, run from the cache folder, no source build, the download removed"

echo "TEST 2: a pip/ planted in the installer's working folder does not run under -I -m pip (the control without -I does)"
new_case plant pip
CACHE=$(cache_path); mkdir -p "$CACHE"; chmod 700 "$CACHE"   # the installer runs from here
mkdir -p "$CACHE/pip"; : >"$CACHE/pip/__init__.py"; printf 'open(%s, "w").write("planted")\n' "'$C/marker'" >"$CACHE/pip/__main__.py"
(cd "$CACHE" && "$PREFIX/bin/python" -m pip control >/dev/null 2>&1) || true
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
grep -qF "uv tool install --force $wheel_url" "$C/err" && ! grep -qF "git+" "$C/err" || fail "the manual_step does not print the release wheel's install command: $(cat "$C/err")"
[ ! -s "$STUB_LOG" ] || fail "a skipped installer ran: $(cat "$STUB_LOG")"
ab update --no-buses --no-setup >/dev/null || fail "the clean stub dir (control) did not run"
[ -s "$STUB_LOG" ] || fail "the control installer left no log"
ok "relative, in-repo and group-writable are skipped; the clean one (control) runs"

echo "TEST 3b: a group-writable installer folder is trusted only for the admin group (owner the caller or root); world-writable, another group and a group-writable installer file stay refused"
new_case admin uv
chmod 775 "$C/stubs"   # like /opt/homebrew/bin: drwxrwxr-x, owned by the caller, in a group that is not the admin group here
ab update --no-buses --no-setup --json 2>"$C/err" >/dev/null && fail "a group-writable folder of another group was used"
[ "$(errof <"$C/err")" = manual_step ] && [ ! -s "$STUB_LOG" ] || fail "another group: $(cat "$C/err")"
grep -qF "uv tool install --force $wheel_url" "$C/err" && ! grep -qF "git+" "$C/err" || fail "the refusal does not print the release wheel's install command: $(cat "$C/err")"
new_case adminwo uv; chmod 777 "$C/stubs"
ab update --no-buses --no-setup --json 2>"$C/err" >/dev/null && fail "a world-writable folder was used"
[ "$(errof <"$C/err")" = manual_step ] && [ ! -s "$STUB_LOG" ] || fail "world-writable: $(cat "$C/err")"
rel_latest 0.3.0 nowheel; new_case adminnowheel uv; chmod 775 "$C/stubs"
ab update --no-buses --no-setup --json 2>"$C/err" >/dev/null && fail "a release without a wheel was installed"
grep -qF "git+" "$C/err" && ! grep -qF "releases/download" "$C/err" || fail "a release with no wheel got a wheel URL: $(cat "$C/err")"
rel_latest 0.3.0
# The rule itself, called directly with the admin group passed in (no environment variable can loosen it in the shipped code).
# st_uid and st_mode are all it reads, so a stand-in stat can have an owner the test could not create without root.
cat >"$T/rules.py" <<'PY'
import importlib.machinery, importlib.util, os, stat, sys
sys.dont_write_bytecode = True  # -I ignores PYTHONDONTWRITEBYTECODE, and the loader would leave bin/__pycache__ in the checkout
loader = importlib.machinery.SourceFileLoader("agentbus_mod", os.environ["UPDATE_SRC"])
spec = importlib.util.spec_from_loader("agentbus_mod", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
import sys
class St:
    def __init__(self, uid, mode): self.st_uid, self.st_mode = uid, mode
D, F = stat.S_IFDIR, stat.S_IFREG
def rules():
    me = 1000
    ok = lambda uid, mode, group, admin="admin": m.installer_folder_ok(St(uid, D | mode), me, group, admin)
    assert ok(me, 0o755, "staff") is True, "a plain folder of the caller"
    assert ok(0, 0o755, "wheel") is True, "a folder of root"
    assert ok(me + 1, 0o755, "staff") is False, "a folder owned by another user"
    assert ok(me, 0o775, "admin") is True, "the admin group's group-writable folder was refused"
    assert ok(0, 0o775, "admin") is True, "the admin group's folder of root was refused"
    assert ok(me + 1, 0o775, "admin") is False, "the admin group's folder owned by another user was trusted"
    assert ok(me, 0o775, "staff") is False, "a group-writable folder of another group was trusted"
    assert ok(me, 0o775, None) is False, "a group-writable folder of an unknown group was trusted"
    assert ok(me, 0o777, "admin") is False, "a world-writable folder was trusted"
    assert ok(me, 0o757, "staff") is False, "a world-writable folder was trusted"
    assert ok(me, 0o775, "admin", admin=None) is (m.admin_group() == "admin"), "the default admin group is not admin_group()"
    assert m.admin_group() == ("admin" if m.sys.platform == "darwin" else None), m.admin_group()
    fo = lambda uid, mode: m.installer_file_ok(St(uid, F | mode), me)
    assert fo(me, 0o755) is True and fo(0, 0o755) is True, "a plain installer file"
    assert fo(me, 0o775) is False and fo(me, 0o757) is False, "a group- or world-writable installer file was trusted"
    assert fo(me + 1, 0o755) is False, "an installer file owned by another user was trusted"
try:
    rules()
except AssertionError as e:
    sys.exit(str(e))
PY
rules=$(UPDATE_SRC="$UPDATE_SRC" "$PY" -I "$T/rules.py" 2>&1) || fail "the installer trust rule is wrong: $rules"
# End to end through the real Homebrew shape, only where it can exist: macOS, a user who is in group admin can chgrp a folder to it.
if [ "$(uname)" = Darwin ] && id -Gn | tr ' ' '\n' | grep -qx admin; then
  new_case adminreal uv; chgrp admin "$C/stubs"; chmod 775 "$C/stubs"
  ab update --no-buses --no-setup >"$C/out" 2>&1 || fail "a real group-admin folder (drwxrwxr-x) was refused: $(cat "$C/out")"
  grep -qF "ARGV: " "$STUB_LOG" || fail "the installer in the real admin folder did not run: $(cat "$STUB_LOG")"
  new_case adminfile uv; chgrp admin "$C/stubs"; chmod 775 "$C/stubs" "$C/stubs/uv"
  ab update --no-buses --no-setup --json 2>"$C/err" >/dev/null && fail "a group-writable installer file in an admin folder was used"
  [ "$(errof <"$C/err")" = manual_step ] && [ ! -s "$STUB_LOG" ] || fail "writable file in an admin folder: $(cat "$C/err")"
  new_case adminwo2 uv; chgrp admin "$C/stubs"; chmod 777 "$C/stubs"
  ab update --no-buses --no-setup --json 2>"$C/err" >/dev/null && fail "a world-writable admin folder was used"
  ok "a real group-admin folder runs the installer; a writable installer file and a world-writable folder do not"
else
  echo "NOTE: not macOS, or the user is not in group admin: the end-to-end Homebrew folder (group admin, drwxrwxr-x) was not run; the rule itself is tested above"
fi
ok "another group, world-writable and a release without a wheel refused or printed right; the folder and file rules hold on stand-in stats"

echo "TEST 4: a hostile latest (1!9.0.0, 0.1.0, 9.0.0+x) never reaches an argv"
for tag in "1!9.0.0" "0.1.0" "9.0.0+x" "0.3.0;id" "0.3.0 --index-url=x"; do
  new_case hostile uv; reset_reqs
  "$PY" -I -c 'import json,sys; v=sys.argv[1]; print(json.dumps({"body": json.dumps({"tag_name": "v"+v, "assets": [{"name": "agentbus-%s-py3-none-any.whl" % v}, {"name": "SHA256SUMS"}]})}))' "$tag" >"$SERVER/answer.json"
  ab update --no-buses --no-setup >"$C/out" 2>&1 || true
  [ ! -s "$STUB_LOG" ] || fail "tag '$tag' reached an installer: $(cat "$STUB_LOG")"
  ! grep -q '/download/' "$SERVER/requests.log" || fail "tag '$tag' reached the download: $(cat "$SERVER/requests.log")"
done
ok "nothing was downloaded and no installer ran for any of them"

echo "TEST 5: --dry-run prints would run: with the exact argv and the planned rows, and changes nothing"
new_case dry uv; rel_latest 0.3.0
new_bus "$C/b1"; new_bus "$C/b2"; mkdir -p "$C/gone"; new_bus "$C/gone/b3"; rm -rf "$C/gone"
mkdir -p "$C/root/x"; new_bus "$C/root/x"
ab update "$C/root" --dry-run >/dev/null || fail "recording the root failed (dry-run records nothing, so this is the control for the next line)"
before=$(tree_sum "$PREFIX" "$C/b1" "$C/b2" "$C/root" "$(state_path)" "$HOME/.claude" )
out=$(ab update --dry-run --all-buses) || fail "dry run failed: $out"
grep -qF "would download agentbus-0.3.0-py3-none-any.whl and SHA256SUMS from github.com/wickdninja/agentbus/releases" <<<"$out" && grep -qF "would then run: $C/stubs/uv tool install --force <the downloaded wheel>" <<<"$out" || fail "no exact would run line: $out"
! grep -qF "$(cache_path)/$wheel_rel" <<<"$out" || fail "a dry run named a wheel file that does not exist yet: $out"
grep -qF "$C/b1" <<<"$out" || fail "a planned bus row is missing: $out"
grep -qF "dry run: nothing was changed." <<<"$out" || fail "dry run summary: $out"
after=$(tree_sum "$PREFIX" "$C/b1" "$C/b2" "$C/root" "$(state_path)" "$HOME/.claude")
[ "$before" = "$after" ] || fail "--dry-run changed the install, a bus folder or the state folder"
[ ! -e "$(state_path)/update.lock" ] || fail "--dry-run created update.lock"
[ ! -s "$STUB_LOG" ] || fail "--dry-run ran the installer"
j=$(ab update --dry-run --all-buses --json) || fail "dry run json failed"
[ "$(jx 'd["tool"]["argv"]' <<<"$j")" = None ] && [ "$(jx 'd["tool"]["download"]["install_with"][-1]' <<<"$j")" = --force ] \
  && [ "$(jx 'd["tool"]["download"]["wheel"]' <<<"$j")" = "https://127.0.0.1:$PORT/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl" ] || fail "dry-run json shows an installer argv for a file that does not exist: $j"
[ "$(jx 'd["tool"]["status"]' <<<"$j")" = dry_run ] && [ "$(jx 'd["restart"]' <<<"$j")" = False ] || fail "dry-run json: $j"
[ "$(jx 'sorted(r["directory"] for r in d["buses"] if r["status"] == "skipped")' <<<"$j")" = "['$C/gone/b3']" ] || fail "the vanished folder is not reported: $j"
ok "exact argv, vanished folder reported and still listed, nothing changed"

echo "TEST 6: installer exit 1, a hang killed by SIGTERM, an unchanged version: installer_failed with the recovery line and no bus step"
new_case fail uv; new_bus "$C/b"; before=$(bus_version "$C/b")
STUB_FAIL=1 ab update --json 2>"$C/err" >/dev/null && fail "a failing installer exited 0"
[ "$(errof <"$C/err")" = installer_failed ] && [ "$(ej 'd["error"]["reason"]' "$C/err")" = exit ] && [ "$(ej 'd["error"]["exit_status"]' "$C/err")" = 1 ] || fail "exit 1: $(cat "$C/err")"
[ "$(ej 'd["error"]["recovery"]' "$C/err")" = "agentbus update" ] || fail "no recovery command: $(cat "$C/err")"
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
  && grep -qF "agentbus-0.3.0-py3-none-any.whl" <<<"$(ej 'd["error"]["argv"]' "$C/err")" || fail "interrupted error: $(cat "$C/err")"
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
[ "$(jx 'd["argv"]' <<<"$j")" = None ] && [ "$(jx 'd["download"]["wheel"]' <<<"$j")" = "https://127.0.0.1:$PORT/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl" ] || fail "check json shows an installer argv for a file that does not exist: $j"
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

echo "TEST 20: a full update (setup included) succeeds on the real new executable when setup has nothing to change, and refreshes an older unedited skill"
rel_latest 0.3.0
new_case full uv; new_bus "$C/b"
export CLAUDE_CONFIG_DIR="$C/cc" CODEX_HOME="$C/cx"
out=$(ab update --all-buses "$C/b") || fail "a full update with nothing to refresh failed: $out"
grep -qF "done: 0.2.0 -> 0.3.0." <<<"$out" && ! grep -qF "  ! setup" <<<"$out" || fail "a full update printed a setup failure: $out"
[ ! -e "$C/cc" ] && [ ! -e "$C/cx" ] || fail "update --refresh installed something that was not there"
new_case full2 uv; new_bus "$C/b"
export CLAUDE_CONFIG_DIR="$C/cc" CODEX_HOME="$C/cx"
(cd "$C/cwd" && "$ENTRY" setup claude >/dev/null) || fail "setup of the fake install failed"
printf 'mine\n\n<!-- agentbus:managed -->\n' >"$C/cc/skills/agentbus/SKILL.md"
out=$(ab update --all-buses "$C/b") || fail "a full update with an edited skill failed: $out"
grep -qF "kept (edited). To replace it: agentbus setup claude" <<<"$out" && [ "$(head -1 "$C/cc/skills/agentbus/SKILL.md")" = mine ] || fail "an edited skill was not kept by a full update: $out"
unset CLAUDE_CONFIG_DIR CODEX_HOME
export CLAUDE_CONFIG_DIR="$T/cc"
ok "exit 0, nothing added, an edit kept"

echo "TEST 21: the release wheel is checked against SHA256SUMS: a good hash installs, a bad one is refused with nothing installed, a missing asset is manual_step"
rel_latest 0.3.0
new_case dl uv; reset_reqs
ab update --no-buses --no-setup >/dev/null || fail "update with a good download failed"
"$PY" -I - "$SERVER/requests.log" <<'PY2' || fail "the requests update made are not the asset list and the two files"
import json, sys
paths = sorted(json.loads(l)["path"] for l in open(sys.argv[1]))
assert paths == ["/download/v0.3.0/SHA256SUMS", "/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl", "/releases/latest"], paths
for l in open(sys.argv[1]):
    h = {k.lower(): v for k, v in json.loads(l)["headers"].items()}
    assert h["user-agent"] == "agentbus" and not {"authorization", "cookie"} & set(h), h
PY2
rel_latest 0.3.0 bad
new_case dlbad uv
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "a wheel with the wrong sha256 was installed"
[ "$(errof <"$C/err")" = download_failed ] && [ "$(ej 'd["error"]["reason"]' "$C/err")" = hash_mismatch ] || fail "bad hash: $(cat "$C/err")"
[ ! -s "$STUB_LOG" ] && [ "$(installed_version)" = 0.2.0 ] && [ -z "$(ls -A "$(cache_path)/downloads" 2>/dev/null)" ] || fail "a refused download was installed or left behind: $(cat "$STUB_LOG")"
for mode in nowheel nosums none; do
  rel_latest 0.3.0 "$mode"; new_case "dlmiss-$mode" uv; reset_reqs
  ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "$mode: update installed a release without a wheel or checksums"
  [ "$(errof <"$C/err")" = manual_step ] && [ "$(ej 'd["error"]["commands"]' "$C/err")" = "['uv tool install --force git+$REPO_URL@v0.3.0']" ] || fail "$mode: manual_step with the exact command: $(cat "$C/err")"
  ! grep -q '/download/' "$SERVER/requests.log" && [ ! -s "$STUB_LOG" ] || fail "$mode: update fetched or installed something: $(cat "$SERVER/requests.log")"
done
rel_latest 0.3.0; rm -f "$SERVER/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl"; new_case dl404 uv
ab update --no-buses --no-setup >"$C/out" 2>"$C/err" && fail "a wheel the server does not have was installed"
grep -qF "(HTTP 404)" "$C/err" && grep -qF "Nothing was installed" "$C/err" || fail "the 404 is not said in plain words: $(cat "$C/err")"
rel_latest 0.3.0 big; new_case dlbig uv
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "an oversized wheel was installed"
[ "$(ej 'd["error"]["reason"]' "$C/err")" = too_large ] || fail "oversized wheel: $(cat "$C/err")"
rel_latest 0.3.0; new_case dlredir uv
printf '{"status": 302, "location": "https://example.invalid/agentbus.whl"}' >"$SERVER/download-answer.json"
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "a redirect off GitHub was followed"
[ "$(ej 'd["error"]["reason"]' "$C/err")" = redirect ] && [ ! -s "$STUB_LOG" ] || fail "redirect: $(cat "$C/err")"
rm -f "$SERVER/download-answer.json"
ok "good hash installs; bad hash, oversized wheel, a 404 and an off-GitHub redirect refuse; a missing wheel or SHA256SUMS is manual_step with the source-build line and no download"

echo "TEST 22: setup --refresh in an update leaves a hook that already runs this install byte for byte, and repairs one that cannot run"
rel_latest 0.3.0
new_case hook uv; new_bus "$C/b"; export CLAUDE_CONFIG_DIR="$C/cc"
(cd "$CWD" && "$ENTRY" setup claude >/dev/null) || fail "setup of the fake install failed"
before=$(cat "$C/cc/settings.json")
grep -qF "$PREFIX/bin/agentbus" <<<"$before" || fail "the premise failed: the hook does not run the install's entry script: $before"
out=$(ab update --all-buses "$C/b") || fail "update with hooks failed: $out"
[ "$(cat "$C/cc/settings.json")" = "$before" ] || fail "update rewrote a hook that already runs this install"
tool_swap() {  # NEW-TOOL-TEXT: the hook command's tool part replaced
  "$PY" -I - "$C/cc/settings.json" "$1" <<'PY2'
import json, re, sys
p, tool = sys.argv[1:]
d = json.load(open(p))
for gs in d["hooks"].values():
    for g in gs:
        for h in g["hooks"]:
            h["command"] = re.sub(r"^.*?(?= hook claude)", lambda m: tool, h["command"], count=1)
json.dump(d, open(p, "w"), indent=2)
PY2
}
tool_swap "'$PREFIX/bin/python' '$SITE/agentbus.py'"; same=$(cat "$C/cc/settings.json")
reset_module
out=$(ab update --all-buses "$C/b") || fail "update with the python-and-module hook form failed: $out"
[ "$(cat "$C/cc/settings.json")" = "$same" ] || fail "update rewrote a python-and-module hook whose module is there"
tool_swap "'$PREFIX/bin/python' '$PREFIX/lib/python3.99/site-packages/agentbus.py'"
reset_module
out=$(ab update --all-buses "$C/b") || fail "update with a broken hook failed: $out"
[ "$(cat "$C/cc/settings.json")" = "$before" ] || fail "update did not repair a hook that names a module that is gone: $(cat "$C/cc/settings.json")"
unset CLAUDE_CONFIG_DIR; export CLAUDE_CONFIG_DIR="$T/cc"
ok "kept as it is, or repaired to the entry script"

echo "TEST 23: the bus list is checked again on read, and update never runs twice at once, whatever the state of its folders"
rel_latest 0.3.0
new_case lst uv; new_bus "$C/real"; new_bus "$C/gone/x"; rm -rf "$C/gone"; mkdir -p "$C/target"; ln -s "$C/target" "$C/link"; : >"$C/afile"
"$PY" -I - "$(state_path)/buses.json" "$C/link" "$C/afile" "$C/gone/x" "$C/real" <<'PY2'
import json, sys
json.dump({"v": 1, "roots": [], "buses": sys.argv[2:]}, open(sys.argv[1], "w"))
PY2
j=$(ab update --all-buses --no-setup --json) || fail "update with a poisoned list failed: $j"
dirs=$(jx 'sorted(r["directory"] for r in d["buses"])' <<<"$j")
[ "$dirs" = "['$C/gone/x', '$C/real']" ] || fail "the list entries were not re-checked: $dirs"
new_case ovl uv; mkdir -p "$(dirname "$(state_path)")"; rm -rf "$(state_path)"; : >"$(state_path)"
mkdir -p "$(cache_path)"; chmod 700 "$(cache_path)"
"$PY" -I - "$(cache_path)/update.lock" "$C/held" <<'PY2' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(30)
PY2
holder=$!
wait_for "$C/held"
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "ran beside a lock held in the cache folder (the state folder was unusable)"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
[ "$(errof <"$C/err")" = update_running ] && [ "$(ej 'd["error"]["lock"]' "$C/err")" = "$(cache_path)/update.lock" ] || fail "fallback lock: $(cat "$C/err")"
new_case nolock uv; mkdir -p "$(dirname "$(state_path)")" "$(dirname "$(cache_path)")"; rm -rf "$(state_path)" "$(cache_path)"; : >"$(state_path)"; : >"$(cache_path)"
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "ran with no place to keep a lock"
[ "$(errof <"$C/err")" = update_running ] && grep -qF "nowhere private to keep its lock" "$C/err" || fail "no lock anywhere: $(cat "$C/err")"
[ ! -s "$STUB_LOG" ] || fail "an installer ran with no lock"
new_case two uv; export STUB_STARTED="$C/started"
( cd "$CWD" && STUB_HANG=1 exec "$PY" -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
  "$ENTRY" update --json --no-buses --no-setup 2>"$C/err1" >/dev/null ) &
first=$!
wait_for "$C/started"; unset STUB_STARTED
ab update --json --no-buses --no-setup 2>"$C/err2" >/dev/null && fail "two overlapping updates both ran"
kill -INT "$first"; wait "$first" 2>/dev/null || true
[ "$(errof <"$C/err2")" = update_running ] || fail "overlapping run: $(cat "$C/err2")"
ok "a link, a file and a vanished folder in the list are dropped or reported; the lock falls back to the cache folder, else update refuses; two real overlapping runs: the second is update_running"

echo "TEST 24: a name lookup that never answers is bounded"
rel_latest 0.3.0
new_case dns uv
printf 'import zz_slowdns\n' >"$SITE/zz_slowdns.pth"
cat >"$SITE/zz_slowdns.py" <<'PY2'
import signal, socket, time
def slow(*a, **k):
    # like the C call it stands for, no signal interrupts it (a SIGALRM handler would wait until it returned)
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    time.sleep(120)
    raise OSError("no network in tests")
socket.getaddrinfo = slow
PY2
unset AGENTBUS_TEST_RELEASES_URL AGENTBUS_TEST_DOWNLOAD_URL
t0=$(now)
AGENTBUS_TEST_CHECK_TIMEOUT=2 ab update --check --json 2>"$C/err" >/dev/null && fail "a lookup that never answers returned"
took=$(( $(now) - t0 ))
[ "$(errof <"$C/err")" = release_offline ] && [ "$(ej 'd["error"]["reason"]' "$C/err")" = timeout ] || fail "dns hang: $(cat "$C/err")"
[ "$took" -lt 60 ] || fail "the lookup was not bounded: $took s"
server_env
ok "release_offline (timeout) long before the 120 s lookup ends"

echo "TEST 25: failures say what happened in plain words and end with the command to run next"
rel_latest 0.3.0
new_case msg uv; answer '{"status": 500}'
ab update --no-buses --no-setup >/dev/null 2>"$C/err" && fail "a 500 exited 0"
grep -qF "GitHub answered with an error (HTTP 500). Nothing was changed. Try again later: agentbus update" "$C/err" || fail "the 500 message: $(cat "$C/err")"
AGENTBUS_TEST_RELEASES_URL=https://127.0.0.1:1/releases ab update --no-buses --no-setup >/dev/null 2>"$C/err" && fail "offline exited 0"
grep -qF "When you are online, run: agentbus update" "$C/err" || fail "the offline message: $(cat "$C/err")"
rel_latest 0.3.0; new_case setupline uv; new_bus "$C/b"
export CLAUDE_CONFIG_DIR="$C/cc" CODEX_HOME="$C/cx"
out=$(ab update --all-buses "$C/b") || fail "update failed: $out"
grep -qxF "setup: nothing to refresh." <<<"$out" || fail "no setup line when nothing was refreshed: $out"
rel_latest 0.3.0; new_case setupline2 uv; new_bus "$C/b"; export CLAUDE_CONFIG_DIR="$C/cc" CODEX_HOME="$C/cx"
out=$(ab update --all-buses --no-setup "$C/b") || fail "update --no-setup failed: $out"
grep -qxF "setup: skipped (--no-setup)." <<<"$out" || fail "no setup line with --no-setup: $out"
rel_latest 0.3.0; new_case setupline3 uv; new_bus "$C/b"
out=$(ab update "$C/b") || fail "update in an agent session failed: $out"
grep -qxF "setup: skipped (agent session). Run with --all-buses to include it." <<<"$out" || fail "no setup line in an agent session: $out"
unset CLAUDE_CONFIG_DIR CODEX_HOME; export CLAUDE_CONFIG_DIR="$T/cc"
ok "HTTP status, the next command, and a setup line every time"

echo "TEST 26: the installed version must be the release that was downloaded and checked"
rel_latest 0.3.0
new_case mismatch uv; new_bus "$C/b"; before=$(bus_version "$C/b")
STUB_VERSION=0.2.5 ab update --json 2>"$C/err" >/dev/null && fail "an installer that put another version in place was accepted"
[ "$(errof <"$C/err")" = installer_failed ] && [ "$(ej 'd["error"]["reason"]' "$C/err")" = version_mismatch ] || fail "version mismatch: $(cat "$C/err")"
grep -qF "agentbus is 0.2.5, not the release 0.3.0 that was downloaded" "$C/err" && [ "$(ej 'd["error"]["committed"]' "$C/err")" = True ] || fail "version mismatch message: $(cat "$C/err")"
[ "$(bus_version "$C/b")" = "$before" ] || fail "a bus step ran after a version mismatch"
ok "installer_failed (version_mismatch), committed, no bus step"

echo "TEST 27: Ctrl-C while downloading says so (no installer ran); a slow server, a refused redirect and every download failure read right"
rel_latest 0.3.0
new_case dlint uv; reset_reqs
printf '{"wait_for": "%s/never"}' "$C" >"$SERVER/download-answer.json"
( cd "$CWD" && exec "$PY" -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
  "$ENTRY" update --json --no-buses --no-setup 2>"$C/err" >/dev/null ) &
pid=$!
w=0; until grep -q '/download/' "$SERVER/requests.log" 2>/dev/null; do sleep 0.1; w=$((w+1)); [ $w -lt 300 ] || fail "the download never started"; done
kill -INT "$pid"; rc=0; wait "$pid" || rc=$?
unset STUB_STARTED
[ "$rc" = 130 ] && [ "$(errof <"$C/err")" = interrupted ] || fail "Ctrl-C in the download: exit $rc: $(cat "$C/err")"
grep -qF "interrupted while downloading the release. Nothing was installed." "$C/err" && ! grep -qF "installer" "$C/err" && [ "$(ej 'd["error"]["argv"] if "argv" in d["error"] else None' "$C/err")" = None ] || fail "Ctrl-C in the download talks about the installer: $(cat "$C/err")"
[ ! -s "$STUB_LOG" ] || fail "an installer ran"
rm -f "$SERVER/download-answer.json"
new_case dlslow uv; printf '{"delay": 6}' >"$SERVER/download-answer.json"
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "a download that never arrives succeeded"
m=$(ej 'd["error"]["message"]' "$C/err")
grep -qF "no answer in time" <<<"$m" && ! grep -qF "online" <<<"$m" && [[ "$m" == *"agentbus update" ]] || fail "slow download message: $m"
printf '{"status": 302, "location": "https://example.invalid/x"}' >"$SERVER/download-answer.json"
new_case dlredir2 uv
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "a redirect off GitHub was followed"
m=$(ej 'd["error"]["message"]' "$C/err")
grep -qF "pointed somewhere that is not GitHub" <<<"$m" && ! grep -qF "302" <<<"$m" || fail "redirect message: $m"
rm -f "$SERVER/download-answer.json"
for mode in bad big; do
  rel_latest 0.3.0 "$mode"; new_case "dlend-$mode" uv
  ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "$mode: succeeded"
  m=$(ej 'd["error"]["message"]' "$C/err"); [[ "$m" == *"agentbus update" ]] || fail "$mode: the message does not end with the next command: $m"
done
rel_latest 0.3.0; rm -f "$SERVER/download/v0.3.0/agentbus-0.3.0-py3-none-any.whl"; new_case dlend404 uv
ab update --json --no-buses --no-setup 2>"$C/err" >/dev/null && fail "404: succeeded"
m=$(ej 'd["error"]["message"]' "$C/err"); [[ "$m" == *"agentbus update" ]] && grep -qF "HTTP 404" <<<"$m" || fail "404: the message: $m"
ok "interrupted while downloading; a slow server is not 'offline'; the redirect is named; every download_failed ends with agentbus update"

echo "TEST 28: a hook set up through a symlinked entry (uv's ~/.local/bin/agentbus) stays byte for byte, and one through another spelling that resolves elsewhere is repaired"
rel_latest 0.3.0
new_case lnk uv; new_bus "$C/b"; export CLAUDE_CONFIG_DIR="$C/cc"
mkdir -p "$C/localbin"; ln -s "$PREFIX/bin/agentbus" "$C/localbin/agentbus"
(cd "$CWD" && "$C/localbin/agentbus" setup claude >/dev/null) || fail "setup through the link failed"
before=$(cat "$C/cc/settings.json")
grep -qF "$C/localbin/agentbus" <<<"$before" || fail "the premise failed: the hook does not run the link: $before"
out=$(ab update --all-buses "$C/b") || fail "update failed: $out"
[ "$(cat "$C/cc/settings.json")" = "$before" ] || fail "update rewrote a hook set up through a link to this install: $(cat "$C/cc/settings.json")"
mkdir -p "$C/other/bin"; printf '#!/bin/sh\nexit 0\n' >"$C/other/bin/agentbus"; chmod 755 "$C/other/bin/agentbus"; ln -sf "$C/other/bin/agentbus" "$C/localbin/agentbus"
reset_module
out=$(ab update --all-buses "$C/b") || fail "update with a link to another program failed: $out"
! grep -qF "$C/localbin/agentbus" "$C/cc/settings.json" && grep -qF "$PREFIX/bin/agentbus" "$C/cc/settings.json" || fail "a hook that runs another program through a link was kept: $(cat "$C/cc/settings.json")"
unset CLAUDE_CONFIG_DIR; export CLAUDE_CONFIG_DIR="$T/cc"
ok "kept as spelled; repaired when the link goes elsewhere"

all_passed "All update tests passed"
