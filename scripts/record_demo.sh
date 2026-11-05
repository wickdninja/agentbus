#!/bin/bash
# Re-cut the README's demo from this tree's real tool: three agents and `agentbus watch` in tmux.
#
#   bash scripts/record_demo.sh OUTDIR     writes OUTDIR/demo.gif and OUTDIR/demo.mp4 (needs vhs, tmux, ffmpeg, gifsicle)
#   bash scripts/record_demo.sh --check    runs the same story with no terminal and no recording tools, and checks each step
#
# Then, to publish a new cut: cp OUTDIR/demo.gif docs/demo.gif
#
# It works only in a mktemp folder: a throwaway HOME, a throwaway project at ~/src/app inside it, a copy of bin/agentbus.
# It never writes to the real HOME, a real bus or this checkout, and OUTDIR is the only folder outside the temp one it touches.
set -euo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
ROOT=$(dirname "$(dirname "$SELF")")

# The story: the agent whose pane runs each command, the command, text its output must contain, and `refused` if it must
# fail. A step that stops matching the tool fails --check, so the demo cannot drift from it. A long command breaks with a
# backslash so the pane shows it whole, at a word.
story() {
  step claude 'agentbus post "auth is yours" \
  --to codex --kind handoff' 'posted #1 to codex [handoff]'
  step codex  'agentbus inbox' 'auth is yours'
  step codex  'agentbus claim src/auth/ \
  --purpose "token API"' 'claimed src/auth/'
  step tests  'agentbus claim src/auth/' 'src/auth/ is claimed by codex' refused
  step tests  'agentbus post "cookie path gone?" \
  --to codex --kind question' 'posted #2 to codex [question]'
  step codex  'agentbus inbox' 'cookie path gone?'
  step codex  'agentbus post "yes, tokens only" \
  --to tests --reply-to 2 --kind answer' 'posted #3 to tests [answer]'
  step codex  'agentbus release src/auth/' 'released src/auth/'
  step codex  'agentbus post "done, tests green" \
  --to claude --reply-to 1 --kind done' 'posted #4 to claude [done]'
  step tests  'agentbus inbox' 'yes, tokens only'
  step tests  'agentbus claim src/auth/' 'claimed src/auth/'
  step claude 'agentbus inbox' 'codex -> claude [done]'
}

# make_project W: the throwaway HOME, tool and project; agents already joined and the goal set.
make_project() {
  local w=$1
  mkdir -p "$w/home/src/app" "$w/bin"
  cp "$ROOT/bin/agentbus" "$w/bin/agentbus"; chmod +x "$w/bin/agentbus"
  export HOME="$w/home" PATH="$w/bin:$PATH" AGENTBUS_NO_UPDATE_CHECK=1 GIT_CONFIG_NOSYSTEM=1
  export XDG_STATE_HOME="$w/home/.local/state" XDG_CONFIG_HOME="$w/home/.config" XDG_CACHE_HOME="$w/home/.cache"   # not the caller's
  unset AGENTBUS_DB AGENTBUS_AGENT CODEX_HOME CLAUDE_CONFIG_DIR CLAUDE_CODE_MESSAGING_SOCKET TMUX
  cd "$HOME/src/app"
  git init -q -b main
  agentbus init . >/dev/null
  agentbus --as claude join --tool claude-code --role lead >/dev/null
  agentbus --as codex join --tool codex --role auth >/dev/null
  agentbus --as tests join --tool claude-code --role tests >/dev/null
  agentbus --as claude goal "auth on the new token API" >/dev/null
}

newtemp() { W=$(cd "$(mktemp -d)" && pwd -P); trap 'TMUX_TMPDIR="$W" tmux -L demo kill-server 2>/dev/null || true; rm -rf "$W"' EXIT; case "$W" in "$ROOT"/*) echo "record_demo: temp folder is inside the checkout: $W" >&2; exit 1;; esac; }

check() {
  newtemp
  make_project "$W"
  step() {
    local out rc=0
    out=$(AGENTBUS_AGENT=$1 bash -c "$2" 2>&1) || rc=$?
    if [ "${4:-}" = refused ]; then
      [ "$rc" != 0 ] || { echo "FAIL: $1: $2: should have been refused: $out" >&2; exit 1; }
    else
      [ "$rc" = 0 ] || { echo "FAIL: $1: $2: exit $rc: $out" >&2; exit 1; }
    fi
    case "$out" in *"$3"*) ;; *) echo "FAIL: $1: $2: output lacks '$3': $out" >&2; exit 1;; esac
    echo "ok $1: $2"
  }
  story
  check_end
  echo "demo story matches the tool"
}

# What the story must have left on the bus, in either mode.
check_end() {
  local claims
  claims=$(agentbus claims)
  case "$claims" in *src/auth/*tests*) ;; *) echo "FAIL: at the end tests should hold src/auth/: $claims" >&2; exit 1;; esac
  agentbus read --id 4 >/dev/null || { echo "FAIL: the story did not reach message 4" >&2; exit 1; }
}

# --drive W: runs inside the recording, after the panes exist: types each step into its pane at reading speed.
drive() {
  local w=$1
  tm() { tmux -L demo "$@"; }
  step() {
    local pane i line
    pane=$(cat "$w/pane.$1")
    tm select-pane -t "$pane"
    while IFS= read -r line; do
      for ((i = 0; i < ${#line}; i += 2)); do tm send-keys -t "$pane" -l -- "${line:$i:2}"; done
      sleep 0.15
      tm send-keys -t "$pane" Enter
    done <<<"$2"
    if [ "${4:-}" = refused ]; then sleep 3.2; else sleep 1.5; fi
  }
  sleep 2.8
  story
  touch "$w/story.done"
}

record() {
  local out=$1 t
  for t in vhs tmux ffmpeg gifsicle ttyd; do command -v "$t" >/dev/null || { echo "record_demo: needs $t on PATH" >&2; exit 1; }; done
  mkdir -p "$out"; out=$(cd "$out" && pwd -P)
  newtemp
  make_project "$W"
  # tmux and the panes, on a socket under the temp folder. The prompt names the agent and nothing else.
  export TMUX_TMPDIR="$W" BASH_SILENCE_DEPRECATION_WARNING=1
  cat >"$W/tmux.conf" <<'CONF'
set -g status off
set -g default-terminal "screen-256color"
set -g terminal-overrides ",*:Tc"
set -g pane-border-style "fg=#30363d"
set -g pane-active-border-style "fg=#30363d"
set -g pane-border-lines single
set -sg escape-time 0
CONF
  for a in claude codex tests; do
    printf 'export AGENTBUS_AGENT=%s\nPS1='"'"'\\[\\e[1;33m\\]%s\\[\\e[0m\\] $ '"'"'\nPS2=\nunset HISTFILE\n' "$a" "$a" >"$W/rc.$a"
  done
  tm() { tmux -L demo -f "$W/tmux.conf" "$@"; }
  tm new-session -d -s demo -x 104 -y 29 -c "$HOME/src/app" -P -F '#{pane_id}' "bash --noprofile --rcfile '$W/rc.claude' -i" >"$W/pane.claude"
  tm split-window -h -t "$(cat "$W/pane.claude")" -l 58 -c "$HOME/src/app" -P -F '#{pane_id}' "agentbus watch" >"$W/pane.watch"
  tm split-window -v -t "$(cat "$W/pane.claude")" -l 19 -c "$HOME/src/app" -P -F '#{pane_id}' "bash --noprofile --rcfile '$W/rc.codex' -i" >"$W/pane.codex"
  tm split-window -v -t "$(cat "$W/pane.codex")" -l 9 -c "$HOME/src/app" -P -F '#{pane_id}' "bash --noprofile --rcfile '$W/rc.tests' -i" >"$W/pane.tests"
  printf '#!/bin/bash\nbash %q --drive %q >%q 2>&1 &\nexec tmux -L demo attach -t demo\n' "$SELF" "$W" "$W/drive.log" >"$W/attach.sh"; chmod +x "$W/attach.sh"
  mkdir "$W/out"; cd "$W/out"
  DEMO_ATTACH="$W/attach.sh" vhs "$ROOT/docs/demo/demo.tape"
  cd "$HOME/src/app"
  [ -e "$W/story.done" ] || { cat "$W/drive.log" >&2; echo "record_demo: the story did not finish" >&2; exit 1; }
  check_end
  gifsicle -O3 --colors 96 "$W/out/demo.gif" -o "$out/demo.gif"
  cp "$W/out/demo.mp4" "$out/demo.mp4"
  echo "wrote $out/demo.gif and $out/demo.mp4"
}

case "${1:-}" in
  --check) check ;;
  --drive) drive "$2" ;;
  ""|-h|--help) sed -n '2,10p' "$SELF" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] ;;
  -*) echo "record_demo: unknown option $1" >&2; exit 2 ;;
  *) record "$1" ;;
esac
