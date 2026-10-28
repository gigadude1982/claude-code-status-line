#!/bin/bash
# Render statusline.sh against a fully synthetic environment (no real account,
# no network, no tmux) and write raw ANSI output to OUT/{full,compact}.ansi.
# usage: demo.sh STATUSLINE OUT
set -e
SCRIPT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$2"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/statusline-demo.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/home/.claude" "$ROOT/tmp"
export HOME="$ROOT/home" TMPDIR="$ROOT/tmp/" CLAUDE_CONFIG_DIR="$ROOT/home/.claude"
export CLAUDE_STATUSLINE_USAGE_API=0 CLAUDE_STATUSLINE_BG=dark
unset TMUX_PANE COLORFGBG CLAUDE_STATUSLINE_COMPACT

cat > "$HOME/.claude.json" <<'EOF'
{"oauthAccount":{"emailAddress":"you@example.com","organizationName":"Acme Labs","userRateLimitTier":"default_claude_max_20x"}}
EOF

# Throwaway repo with a little of everything: staged, modified, untracked.
REPO="$HOME/dev/rocket-app"
mkdir -p "$REPO"; cd "$REPO"
git init -q -b feat/warp-drive
git -c user.name=demo -c user.email=demo@example.com commit -q --allow-empty -m init
for f in engine.ts fuel.ts nav.ts; do echo "x" > "$f"; done
git add engine.ts
GIT_COMMITTER_DATE="$(( $(date +%s) - 720 )) +0000" GIT_AUTHOR_DATE="$(( $(date +%s) - 720 )) +0000" \
  git -c user.name=demo -c user.email=demo@example.com commit -q -m wip
echo y >> engine.ts; echo staged > fuel.ts; git add fuel.ts; echo z > todo.md

SID="demo-session-42"
NOW=$(date +%s)
# Seed sparkline history: a climbing context over ~5 minutes.
h=""; v=8
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13; do
  h="$h $(( NOW - 300 + i * 20 )) $v"; v=$(( v + 3 + (i % 3) ))
done
echo "${h# }" > "${TMPDIR}.claude_spark2_$(id -u)_${SID}"
printf '%s' "Claude Opus 5.5" > "${TMPDIR}.claude_sparkmdl_$(id -u)_${SID}"

# Turn cost: a transcript whose latest prompt matches a seeded baseline, so the
# render shows a mid-session turn rather than the "first sight" blank.
TRANSCRIPT="$ROOT/transcript.jsonl"
echo '{"type":"user","uuid":"demo-prompt-7","message":{"content":"add the warp drive"}}' > "$TRANSCRIPT"
echo "demo-prompt-7 7.06 7.30" > "${TMPDIR}.claude_turncost_$(id -u)_${SID}"

# CI badge: a stub gh that always reports passing checks, so the render never
# talks to GitHub (or depends on gh being installed and logged in).
mkdir -p "$ROOT/bin"
printf '#!/bin/sh\necho '"'"'[{"bucket":"pass"}]'"'"'\n' > "$ROOT/bin/gh"
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
echo "$(date +%s) pass" > "${TMPDIR}.claude_ci_$(id -u)_acme_rocket-app_128"

# Today's spend: one other session earlier today, so the 📆 total shows.
SPEND="$HOME/.local/state/claude-statusline/spend-.claude/$(date +%F)"
mkdir -p "$SPEND"; echo "0 4.18" > "$SPEND/earlier-session"

json() {
  cat <<EOF
{"session_id":"$SID","session_name":"warp-drive","version":"2.4.12","transcript_path":"$TRANSCRIPT",
 "model":{"display_name":"Fable 5.1"},
 "workspace":{"current_dir":"$REPO","project_dir":"$REPO","repo":{"owner":"acme","name":"rocket-app"}},
 "effort":{"level":"xhigh"},"thinking":{"enabled":true},"fast_mode":false,
 "pr":{"number":128,"review_state":"approved"},
 "context_window":{"context_window_size":1000000,"used_percentage":$1,"remaining_percentage":$((100-$1)),
   "current_usage":{"input_tokens":4210,"output_tokens":18800,"cache_creation_input_tokens":32100,"cache_read_input_tokens":512000}},
 "cost":{"total_cost_usd":$2,"total_duration_ms":2280000,"total_api_duration_ms":1310000,"total_lines_added":842,"total_lines_removed":117},
 "rate_limits":{"five_hour":{"used_percentage":$3,"resets_at":$((NOW+7800))},"seven_day":{"used_percentage":$4,"resets_at":$((NOW+410000))}}}
EOF
}
json 61 7.42 64 22 | bash "$SCRIPT" > "$OUT/full.ansi"
json 61 7.42 64 22 | CLAUDE_STATUSLINE_COMPACT=1 bash "$SCRIPT" > "$OUT/compact.ansi"
