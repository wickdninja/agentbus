#!/usr/bin/env bash
(
set -euo pipefail

# AGENTBUS may include an interpreter, e.g. "python3 /path/to/bin/agentbus".
read -r -a installed_bus <<< "${AGENTBUS:-agentbus}"
# The script changes directory below: a relative path in AGENTBUS (python3 bin/agentbus) is made absolute first.
for i in "${!installed_bus[@]}"; do
  word=${installed_bus[$i]}
  if [[ $word == */* && $word != /* && -e $word ]]; then installed_bus[$i]=$PWD/$word; fi
done
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

run "${installed_bus[@]}" --as claude join --tool claude --role planner
run "${installed_bus[@]}" --as codex join --tool codex --role implementer
run "${installed_bus[@]}" --as claude post "Please review src/api/; reply with the result." \
  --to codex --kind handoff
run "${installed_bus[@]}" --as codex inbox
run "${installed_bus[@]}" --as codex claim src/api/ --purpose "demo review"
run "${installed_bus[@]}" claims
run "${installed_bus[@]}" --as codex release src/api/
run "${installed_bus[@]}" --as codex post "Demo review complete; no files changed." \
  --to claude --kind answer --reply-to 1
run "${installed_bus[@]}" --as claude inbox
run "${installed_bus[@]}" --as codex leave
run "${installed_bus[@]}" --as claude leave
run "${installed_bus[@]}" watch --once
)
