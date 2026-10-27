#!/bin/bash
# Install the Claude Code statusline on a new machine.
# Run from the repo root: bash install.sh
#
# What it does:
#   1. Copies statusline.sh → ~/.claude/statusline.sh
#   2. Prints the statusLine block to add to ~/.claude/settings.json
#      (uses the Git Bash path auto-detected on Windows; plain path elsewhere)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/statusline.sh"

# Neon accents when printing to a terminal; plain text when piped or logged.
if [ -t 1 ]; then
  B='\033[1m' R='\033[0m' CY='\033[38;5;51m' GR='\033[38;5;46m'
  PK='\033[38;5;213m' YL='\033[38;5;226m' VI='\033[38;5;141m'
else
  B='' R='' CY='' GR='' PK='' YL='' VI=''
fi

printf '\n%b\n' "${B}${CY}🤖✨ claude-code-status-line${R} ${VI}installer${R}"
printf '%b\n\n' "${PK}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"

cp "$SCRIPT_DIR/statusline.sh" "$DEST"
chmod +x "$DEST"
printf '%b\n' "${GR}✅ Installed:${R} ${B}$DEST${R}"

# Detect Git Bash path on Windows only (Mac/Linux ship /usr/bin/bash too, so
# that path can't be used as a Windows signal — gate on uname first).
GIT_BASH=""
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    for candidate in \
        "/c/Program Files/Git/bin/bash.exe" \
        "/c/Users/$USERNAME/AppData/Local/Programs/Git/bin/bash.exe"; do
      [ -x "$candidate" ] && GIT_BASH="$candidate" && break
    done
    ;;
esac

echo ""
printf '%b\n' "${YL}📝 Add the following to ~/.claude/settings.json:${R}"
echo ""
if [ -n "$GIT_BASH" ]; then
  # Convert to the Windows-style path Claude Code expects
  WIN_BASH=$(cygpath -w "$GIT_BASH" 2>/dev/null || echo "$GIT_BASH")
  WIN_DEST=$(cygpath -w "$DEST" 2>/dev/null | sed 's|\\|/|g' || echo "$DEST")
  echo "  \"statusLine\": {"
  echo "    \"type\": \"command\","
  echo "    \"command\": \"${WIN_BASH//\\/\\\\} ${WIN_DEST}\","
  echo "    \"padding\": 2"
  echo "  }"
else
  echo "  \"statusLine\": {"
  echo "    \"type\": \"command\","
  echo "    \"command\": \"$DEST\","
  echo "    \"padding\": 2"
  echo "  }"
fi
echo ""
printf '%b\n\n' "${B}${PK}🎉 Done!${R} Restart Claude Code (or send a message) to see your new status line."
