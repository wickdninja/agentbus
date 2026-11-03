#!/bin/bash
set -euo pipefail
# bash tests/update_codes.sh OUTDIR: produces, with fake installs and the fixture release server, one failing
# `agentbus update --json` per update error code and writes its stderr (the JSON error) to OUTDIR/<code>.json.
# tests/test_contract.sh runs it and checks each file against the registry (code, exit status, fields, retryable).
. "$(dirname "$0")/update_lib.sh"
OUT=${1:?usage: update_codes.sh OUTDIR}
T=$(mktemp -d); trap 'stop_servers; rm -rf "$T"' EXIT
mkdir "$T/srv"; start_server "$T/srv"; rel_latest 0.3.0
export CLAUDE_CONFIG_DIR="$T/cc"
last() { tail -n 1 "$1"; }

new_case a uv
STUB_FAIL=1 ab update --json --no-buses --no-setup 2>"$T/err" >/dev/null || true; last "$T/err" >"$OUT/installer_failed.json"
mkdir -p "$C/clone/bin" "$C/clone/.git"; sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$UPDATE_SRC" >"$C/clone/bin/agentbus"; : >"$C/clone/pyproject.toml"
(cd "$CWD" && "$PREFIX/bin/python" "$C/clone/bin/agentbus" update --json 2>"$T/err" >/dev/null) || true; last "$T/err" >"$OUT/manual_step.json"
rm -rf "$(cache_path)"   # --check answers from a good cache entry under an hour old: start without one
AGENTBUS_TEST_RELEASES_URL=https://127.0.0.1:1/releases ab update --check --json 2>"$T/err" >/dev/null || true; last "$T/err" >"$OUT/release_offline.json"
answer '{"status": 429, "headers": {"Retry-After": "120"}}'
rm -rf "$(cache_path)"; ab update --check --json 2>"$T/err" >/dev/null || true; last "$T/err" >"$OUT/rate_limited.json"
answer '{"status": 500}'
rm -rf "$(cache_path)"; ab update --check --json 2>"$T/err" >/dev/null || true; last "$T/err" >"$OUT/release_unknown.json"
rel_latest 0.3.0 bad
rm -rf "$(cache_path)"; ab update --json --no-buses --no-setup 2>"$T/err" >/dev/null || true; last "$T/err" >"$OUT/download_failed.json"
rel_latest 0.3.0
mkdir -p "$(state_path)"; chmod 700 "$(state_path)"
"$PY" -I - "$(state_path)/update.lock" "$T/held" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(20)
PY
holder=$!
wait_for "$T/held"
ab update --json --no-buses --no-setup 2>"$T/err" >/dev/null || true; last "$T/err" >"$OUT/update_running.json"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
