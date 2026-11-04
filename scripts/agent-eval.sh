#!/bin/bash
# Agent evals: do Claude Code and Codex agents complete the agentbus protocol on the installed command?
#   bash scripts/agent-eval.sh --dry-run --all             count the agent invocations a full run makes
#   bash scripts/agent-eval.sh --go --cell claude skill resume   one cell (the end-of-wave check)
#   bash scripts/agent-eval.sh --go --all                  the full matrix; ends: eval complete: 16 of 16 cells pass
#   bash scripts/agent-eval.sh --go --agent codex --arm skill --scenario handoff --attempts 3
# Real runs spend tokens and need --go. AGENTBUS_CMD names the installed command (default: agentbus on PATH).
# Traces stay in eval-out/ (local; they can hold anything an agent printed). Details: docs/evals/README.md.
exec "${PYTHON:-python3}" -B "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-eval/run.py" "$@"
