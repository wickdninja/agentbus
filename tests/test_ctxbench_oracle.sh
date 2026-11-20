#!/usr/bin/env bash
# Independent semantic fixtures only. No CLI or registered parser is run.
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHONDONTWRITEBYTECODE=1 python3 scripts/ctxbench/oracle_fixtures.py
