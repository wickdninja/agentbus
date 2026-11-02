#!/bin/bash
set -euo pipefail
# Every test script must ignore a caller's exported bus settings. Bug it catches: a test that
# inherits AGENTBUS_DB / AGENTBUS_AGENT and writes into the caller's real bus.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# And no test leaves anything in this checkout (a bus, a .agentbus/, a scratch file), ignored or not.
CHECKOUT="$(cd "$(dirname "$BIN")/.." && pwd)"
tree() { git -C "$CHECKOUT" status --porcelain --ignored --untracked-files=all; }
before=$(tree)
for t in "$(dirname "$0")"/test_*.sh; do
  case "$t" in *test_isolation.sh) continue ;; esac
  mkdir -p "$T/home"
  AGENTBUS_RACE_N=40 AGENTBUS_DB="$T/caller.db" AGENTBUS_AGENT=caller HOME="$T/home" \
    bash "$t" > "$T/log" 2>&1 || { cat "$T/log"; fail "$t failed under a caller's bus env"; }
  [ ! -e "$T/caller.db" ] || fail "$t wrote the caller's AGENTBUS_DB"
  [ ! -e "$T/home/.agentbus" ] || fail "$t wrote the caller's ~/.agentbus"
done
after=$(tree)
[ "$after" = "$before" ] || fail "the suite changed the checkout: $(diff <(echo "$before") <(echo "$after"))"
ok "no test touches the caller's bus or the checkout"
