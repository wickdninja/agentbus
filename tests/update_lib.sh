# Helpers for tests/test_update*.sh and tests/test_no_network.sh (source after lib.sh, which scrubs the agent and
# switch variables). Every case runs a FAKE INSTALL, never the checkout (a clone is never due): a stdlib venv in a
# temp dir outside any repo, the script copied in as site-packages/agentbus.py with a hand-written dist-info
# (RECORD, direct_url.json with vcs_info for the repository) and an entry script. The release lookup talks only to
# tests/fixtures/release_server.py on 127.0.0.1; nothing here reaches a network.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CI   # lib.sh keeps it for test_package.sh; here a CI runner would silence the release notice in every case
UPDATE_SRC="${AGENTBUS_BIN:-$BIN}"   # the script the fake installs copy (a mutation copy under mutate.py)
REPO_URL=https://github.com/wickdninja/agentbus
SERVER_PY="$TESTS_DIR/fixtures/release_server.py"
command -v openssl >/dev/null 2>&1 || skip_test "openssl is needed to mint the test certificate"

# mint_cert DIR: one self-signed leaf, IP SAN 127.0.0.1, CA:TRUE (the test trusts exactly this file).
mint_cert() {
  cat >"$1/ssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = 127.0.0.1
[v3]
subjectAltName = IP:127.0.0.1
basicConstraints = critical,CA:TRUE
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1/key.pem" -out "$1/cert.pem" -days 2 -config "$1/ssl.cnf" >/dev/null 2>&1 \
    || fail "openssl could not mint the test certificate"
}
# start_server DIR: the fixture server, in the background; DIR/port holds its port when it is up.
SERVER_PIDS=()
start_server() {
  mint_cert "$1"
  "$PY" "$SERVER_PY" "$1" >"$1/server.out" 2>&1 &
  SERVER_PIDS+=($!)
  local w=0; while [ ! -s "$1/port" ]; do sleep 0.05; w=$((w+1)); [ $w -lt 200 ] || { cat "$1/server.out" >&2; fail "the fixture server did not start"; }; done
  : >"$1/requests.log"
  SERVER="$1"; PORT=$(cat "$1/port")
}
stop_servers() { local p; for p in ${SERVER_PIDS[@]+"${SERVER_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; SERVER_PIDS=(); }
# answer JSON: what the server says to the next requests; reqs: how many it has logged; the log's last line.
answer() { printf '%s' "$1" >"$SERVER/answer.json.tmp" && mv "$SERVER/answer.json.tmp" "$SERVER/answer.json"; }
reqs() { wc -l <"$SERVER/requests.log" | tr -d ' '; }
reset_reqs() { : >"$SERVER/requests.log"; }
# publish V [MODE]: the release's files on the fixture server (/download/vV/): a fake wheel and a correct SHA256SUMS
# (MODE bad: SHA256SUMS names another hash; big: a wheel over the size limit; none: no files).
publish() {
  local v=$1 mode=${2:-full} d="$SERVER/download/v$1" name="agentbus-$1-py3-none-any.whl"
  rm -rf "$d"; [ "$mode" = none ] && return 0
  mkdir -p "$d"
  if [ "$mode" = big ]; then head -c 5300000 /dev/zero >"$d/$name"; else printf 'fake wheel bytes for %s\n' "$v" >"$d/$name"; fi
  local sum; sum=$(shasum -a 256 "$d/$name" | cut -d' ' -f1)
  [ "$mode" != bad ] || sum=$(printf '%064d' 0)
  printf '%s  %s\n' "$sum" "$name" >"$d/SHA256SUMS"
}
# assets_json V MODE: the assets list of the API answer (full: the wheel and SHA256SUMS; nowheel; nosums; none).
assets_json() {
  case "$2" in
    full|bad|big) printf '[{"name": "agentbus-%s-py3-none-any.whl"}, {"name": "agentbus-%s.tar.gz"}, {"name": "SHA256SUMS"}]' "$1" "$1" ;;
    nowheel) printf '[{"name": "agentbus-%s.tar.gz"}, {"name": "SHA256SUMS"}]' "$1" ;;
    nosums) printf '[{"name": "agentbus-%s-py3-none-any.whl"}]' "$1" ;;
    none) printf '[]' ;;
  esac
}
# rel_latest V [MODE]: the answer to /releases/latest, and the release's files (publish). rel_list V...: the list endpoint's.
rel_latest() {
  local mode=${2:-full}
  publish "$1" "$mode"
  "$PY" -I -c 'import json,sys; v,assets=sys.argv[1:]; print(json.dumps({"body": json.dumps({"tag_name": "v"+v, "draft": False, "prerelease": False, "assets": json.loads(assets)})}))' \
    "$1" "$(assets_json "$1" "$mode")" >"$SERVER/answer.json.tmp" && mv "$SERVER/answer.json.tmp" "$SERVER/answer.json"
}
rel_list() {
  local t items=""
  for t in "$@"; do publish "$t"; items="$items${items:+, }{\"tag_name\": \"v$t\", \"draft\": false, \"assets\": $(assets_json "$t" full)}"; done
  "$PY" -I -c 'import json,sys; print(json.dumps({"body": sys.argv[1]}))' "[$items]" >"$SERVER/answer.json.tmp" && mv "$SERVER/answer.json.tmp" "$SERVER/answer.json"
}

cache_path() {
  if [ "$(uname)" = Darwin ]; then echo "$HOME/Library/Caches/agentbus"; else echo "${XDG_CACHE_HOME:-$HOME/.cache}/agentbus"; fi
}
state_path() {
  if [ "$(uname)" = Darwin ]; then echo "$HOME/Library/Application Support/agentbus"; else echo "${XDG_STATE_HOME:-$HOME/.local/state}/agentbus"; fi
}
# cache_get FIELD: a field of the release cache (empty when there is no cache or the field is null).
cache_get() { "$PY" -I -c '
import json, sys
try:
    v = json.load(open(sys.argv[1]))[sys.argv[2]]
except (OSError, ValueError, KeyError):
    v = None
print("" if v is None else v if not isinstance(v, (dict, list)) else json.dumps(v))' "$(cache_path)/release-check.json" "$1"; }
# cache_put JSON: write the cache by hand (0700 folder, 0600 file).
cache_put() { mkdir -p "$(cache_path)"; chmod 700 "$(cache_path)"; printf '%s\n' "$1" >"$(cache_path)/release-check.json"; chmod 600 "$(cache_path)/release-check.json"; }
now() { "$PY" -c 'import time; print(int(time.time()))'; }
# wait_cache: until the detached check has written its answer (ok no longer null), at most 60 s (a loaded machine).
wait_cache() { local w=0; while :; do [ "$(cache_get ok)" != "" ] && return 0; sleep 0.1; w=$((w+1)); [ $w -lt 600 ] || fail "the detached check never wrote the cache"; done; }

# make_install ROOT METHOD VERSION URL: the fake install (see the top of this file). METHOD: uv, pipx or pip.
make_install() {
  local root=$1 method=${2:-uv} ver=${3:-0.2.0} url=${4-$REPO_URL} sp
  "$PY" -m venv --without-pip "$root/venv" || fail "cannot make the fake venv"
  sp=$("$root/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
  mkdir -p "$sp"
  sed "s/^__version__ = .*/__version__ = \"$ver\"/" "$UPDATE_SRC" >"$sp/agentbus.py"
  mkdir "$sp/agentbus-$ver.dist-info"
  printf 'Metadata-Version: 2.1\nName: agentbus\nVersion: %s\n' "$ver" >"$sp/agentbus-$ver.dist-info/METADATA"
  printf 'agentbus.py,,\nagentbus-%s.dist-info/METADATA,,\nagentbus-%s.dist-info/RECORD,,\n' "$ver" "$ver" >"$sp/agentbus-$ver.dist-info/RECORD"
  printf 'pip\n' >"$sp/agentbus-$ver.dist-info/INSTALLER"
  if [ -n "$url" ]; then
    printf '{"url": "%s", "vcs_info": {"vcs": "git", "requested_revision": "v%s", "commit_id": "0123456789abcdef0123456789abcdef01234567"}}\n' "$url" "$ver" >"$sp/agentbus-$ver.dist-info/direct_url.json"
  fi
  case "$method" in
    uv) printf '[tool]\nrequirements = [{ name = "agentbus" }]\n' >"$root/venv/uv-receipt.toml" ;;
    pipx) printf '{"pipx_metadata_version": "0.5"}\n' >"$root/venv/pipx_metadata.json" ;;
  esac
  printf '#!%s\nfrom agentbus import cli\ncli()\n' "$root/venv/bin/python" >"$root/venv/bin/agentbus"
  chmod 755 "$root/venv/bin/agentbus"
  SITE="$sp"; ENTRY="$root/venv/bin/agentbus"; PREFIX="$root/venv"
}
# make_stubs DIR: uv, pipx and a pip module that log their argument list and working folder to $STUB_LOG and move the
# fake install to the version in the last argument (...@vX.Y.Z). STUB_FAIL=1 exits 1; STUB_NOBUMP=1 leaves the
# version; STUB_HANG=1 waits for SIGTERM (logging it) or STUB_IGNORE_TERM=1 for SIGKILL; STUB_INT=1 reports it has started.
make_stubs() {
  mkdir -p "$1"; chmod 700 "$1"
  local name
  for name in uv pipx; do
    cat >"$1/$name" <<'EOF'
#!/bin/bash
echo "ARGV: $0 $*" >>"$STUB_LOG"; echo "CWD: $PWD" >>"$STUB_LOG"
last="${@: -1}"; if [ -f "$last" ]; then echo "WHEEL_SHA: $(shasum -a 256 "$last" | cut -d' ' -f1)" >>"$STUB_LOG"; else echo "WHEEL_MISSING: $last" >>"$STUB_LOG"; fi
[ -z "${STUB_STARTED:-}" ] || : >"$STUB_STARTED"
if [ -n "${STUB_HANG:-}" ]; then
  if [ -n "${STUB_IGNORE_TERM:-}" ]; then trap 'echo "TERM ignored" >>"$STUB_LOG"' TERM; else trap 'echo "TERM" >>"$STUB_LOG"; exit 143' TERM; fi
  while :; do sleep 0.1; done
fi
[ -z "${STUB_FAIL:-}" ] || { echo "stub installer failing" >&2; exit 1; }
echo "stub installer output"
if [ -z "${STUB_NOBUMP:-}" ]; then
  v="${@: -1}"; v="${v##*/agentbus-}"; v="${v%%-py3-none-any.whl}"; v="${STUB_VERSION:-$v}"
  sed "s/^__version__ = .*/__version__ = \"$v\"/" "${STUB_FAKE:-$STUB_MODULE}" >"$STUB_MODULE.new" && mv "$STUB_MODULE.new" "$STUB_MODULE"
  rm -rf "$(dirname "$STUB_MODULE")/__pycache__"   # a same-size rewrite in the same second would be served from the old bytecode
fi
EOF
    chmod 755 "$1/$name"
  done
}
# make_pip_stub SITE: site-packages/pip/__main__.py with the same behaviour (python -I -m pip ...).
make_pip_stub() {
  mkdir -p "$1/pip"; : >"$1/pip/__init__.py"
  cat >"$1/pip/__main__.py" <<'EOF'
import os, re, sys
log = os.environ["STUB_LOG"]
open(log, "a").write("ARGV: pip %s\nCWD: %s\n" % (" ".join(sys.argv[1:]), os.getcwd()))
import hashlib
if os.path.isfile(sys.argv[-1]):
    open(log, "a").write("WHEEL_SHA: %s\n" % hashlib.sha256(open(sys.argv[-1], "rb").read()).hexdigest())
else:
    open(log, "a").write("WHEEL_MISSING: %s\n" % sys.argv[-1])
if os.environ.get("STUB_FAIL"):
    sys.exit(1)
if not os.environ.get("STUB_NOBUMP"):
    v = os.environ.get("STUB_VERSION") or os.path.basename(sys.argv[-1])[len("agentbus-"):-len("-py3-none-any.whl")]
    p = os.environ["STUB_MODULE"]
    s = open(os.environ.get("STUB_FAKE") or p).read()
    open(p, "w").write(re.sub(r'(?m)^__version__ = .*$', '__version__ = "%s"' % v, s))
    import shutil
    shutil.rmtree(os.path.join(os.path.dirname(p), "__pycache__"), ignore_errors=True)
EOF
}
# ab ARGS: the fake install's entry script, from a neutral folder, with the environment of a script (no terminal).
ab() { (cd "$CWD" && "$ENTRY" "$@"); }
# abtty [--tty in,out,err] -- ARGS: the same on a pseudo-terminal (a person at a terminal); prints its text and RC=n.
abtty() {
  local opts=()
  while [ "$1" != "--" ]; do opts+=("$1"); shift; done
  shift
  (cd "$CWD" && "$PY" "$TESTS_DIR/pty_run.py" ${opts[@]+"${opts[@]}"} -- "$ENTRY" "$@")
}
# new_case NAME [METHOD VERSION URL]: a fresh HOME, working folder, fake install and stubs for one case.
# PATH is the stubs and the system's /usr/bin:/bin only, so a real uv or pipx is never reachable.
new_case() {
  local name=$1; shift
  rm -rf "$T/$name"; mkdir -p "$T/$name"; C=$(cd "$T/$name" && pwd -P); mkdir -p "$C/home" "$C/cwd"   # real path: tmp is a link on macOS
  export HOME="$C/home"; CWD="$C/cwd"
  unset XDG_CACHE_HOME XDG_STATE_HOME
  make_install "$C/fake" "$@"
  make_stubs "$C/stubs"; make_pip_stub "$SITE"
  unset STUB_VERSION STUB_FAKE FAKE_LOG FAKE_SETUP STUB_FAIL STUB_NOBUMP STUB_HANG STUB_IGNORE_TERM STUB_STARTED   # a case starts with the real module and no fault
  export STUB_LOG="$C/stub.log" STUB_MODULE="$SITE/agentbus.py"
  : >"$STUB_LOG"
  export PATH="$C/stubs:/usr/bin:/bin"   # never the real uv or pipx
  server_env
}
PY=$(command -v "$PY")   # absolute: PATH is narrowed per case
server_env() {
  if [ -n "${SERVER:-}" ]; then
    export AGENTBUS_TEST_RELEASES_URL="https://127.0.0.1:$PORT/releases" AGENTBUS_TEST_DOWNLOAD_URL="https://127.0.0.1:$PORT/download" AGENTBUS_TEST_CA_FILE="$SERVER/cert.pem"
    export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
    unset HTTPS_PROXY https_proxy ALL_PROXY all_proxy
  fi
}
installed_version() { "$PY" -I -c 'import re,sys; print(re.search(r"(?m)^__version__ = \"(.*)\"", open(sys.argv[1]).read()).group(1))' "$SITE/agentbus.py"; }
NOTICE_RE='agentbus: a new release is available: '
# new_bus DIR: a bus folder made by the fake install's own init (so it is a real, current bus).
new_bus() { mkdir -p "$1"; (cd "$CWD" && "$ENTRY" init "$1" >/dev/null 2>&1) || fail "init of $1 failed"; }
# jx EXPR: print a python expression of the JSON on stdin (d is the value).
jx() { "$PY" -I -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
# tree_sum DIR...: a checksum of every file under the folders (names and bytes), to prove nothing changed.
tree_sum() { { find "$@" -type f 2>/dev/null || true; } | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum <"$f")"; done | cksum; }
# bus_version DIR: the bus folder's recorded copy version.
bus_version() { cat "$1/.agentbus/VERSION"; }
# reset_module: the installed module is the REAL script again at 0.2.0. Its compiled copy goes too: `python -I -m agentbus`
# (what update runs) does write one, and a same-size rewrite within the same second would be served from it.
reset_module() { sed 's/^__version__ = .*/__version__ = "0.2.0"/' "$UPDATE_SRC" >"$SITE/agentbus.py"; rm -rf "$SITE/__pycache__"; }
# use_fake_module: the next stub install replaces the module with tests/fixtures/fake_agentbus.py (at the new version).
use_fake_module() { export STUB_FAKE="$TESTS_DIR/fixtures/fake_agentbus.py" FAKE_LOG="$C/fake.log"; : >"$FAKE_LOG"; }
