#!/bin/bash
# Regenerates every diagram image from its .mmd source (needs Node; npx fetches the mermaid CLI).
set -euo pipefail
cd "$(dirname "$0")"
for f in *.mmd; do
  n="${f%.mmd}"
  npx -y @mermaid-js/mermaid-cli@11 -i "$f" -o "$n.svg" -c theme.json -b white
  npx -y @mermaid-js/mermaid-cli@11 -i "$f" -o "$n.png" -c theme.json -b white -s 2
done
