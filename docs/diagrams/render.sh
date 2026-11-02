#!/bin/bash
# Regenerates every diagram image from source, in a light and a dark variant.
#   hero.py -> hero-{light,dark}.svg (hand-authored SVG), then rsvg-convert (librsvg) -> 2x PNG
#   *.mmd   -> {name}-{light,dark}.{svg,png} via the Mermaid CLI (needs Node; npx fetches it)
set -euo pipefail
cd "$(dirname "$0")"
python3 hero.py
for theme in light dark; do
  rsvg-convert -z 2 "hero-$theme.svg" -o "hero-$theme.png"
done
for f in *.mmd; do
  n="${f%.mmd}"
  for theme in light dark; do
    if [ "$theme" = dark ]; then bg='#0d1117'; else bg='#ffffff'; fi
    npx -y @mermaid-js/mermaid-cli@11 -q -i "$f" -o "$n-$theme.svg" -c "theme-$theme.json" -b "$bg"
    npx -y @mermaid-js/mermaid-cli@11 -q -i "$f" -o "$n-$theme.png" -c "theme-$theme.json" -b "$bg" -s 2
  done
done
