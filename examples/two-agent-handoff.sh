#!/usr/bin/env bash
(
set -euo pipefail

# AGENTBUS may include an interpreter, e.g. "python3 /path/to/bin/agentbus".
read -r -a installed_bus <<< "${AGENTBUS:-agentbus}"
for name in ${!AGENTBUS_@}; do unset "$name"; done

demo_dir=$(mktemp -d)
cleanup() {
  if [[ ${KEEP:-0} == 1 ]]; then
    printf 'Kept demo directory: %s\n' "$demo_dir"
  else
    rm -rf "$demo_dir"
    printf 'Removed demo directory: %s\n' "$demo_dir"
  fi
}
trap cleanup EXIT
run() { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }
printf 'Demo directory: %s\n' "$demo_dir"
run mkdir "$demo_dir/home"
export HOME="$demo_dir/home"
run git init -q "$demo_dir/repo"
run cd "$demo_dir/repo"
run "${installed_bus[@]}" init .
bus=.agentbus/bin/agentbus

run "$bus" --as claude join --tool claude --role planner
run "$bus" --as codex join --tool codex --role implementer
run "$bus" --as claude post "Please review src/api/; reply with the result." \
  --to codex --kind handoff
run "$bus" --as codex inbox
run "$bus" --as codex claim src/api/ --purpose "demo review"
run "$bus" claims
run "$bus" --as codex release src/api/
run "$bus" --as codex post "Demo review complete; no files changed." \
  --to claude --kind answer --reply-to 1
run "$bus" --as claude inbox
run "$bus" --as codex leave
run "$bus" --as claude leave
run "$bus" watch --once
)
