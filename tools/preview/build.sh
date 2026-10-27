#!/bin/bash
# Regenerate the README screenshots in assets/ from a real statusline.sh render.
# Everything shown is synthetic (demo account, throwaway git repo), so nothing
# from your own machine ends up in the images.
# usage: bash tools/preview/build.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/statusline-preview.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

bash "$HERE/demo.sh" "$REPO/statusline.sh" "$WORK"
mkdir -p "$REPO/assets"
python3 -I "$HERE/ansi2svg.py" "$WORK/full.ansi" "$REPO/assets/statusline-full.svg" \
  "claude — ~/dev/rocket-app" 114
python3 -I "$HERE/ansi2svg.py" "$WORK/compact.ansi" "$REPO/assets/statusline-compact.svg" \
  "CLAUDE_STATUSLINE_COMPACT=1" 114
