#!/bin/bash
# Claude Code statusline
# Rate-limit values are cached to a temp file so the section never goes blank
# between API calls — staleness is shown as "(cached Xm ago)".

input=$(cat)
_CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Scoped by uid AND config dir so cached rate-limit values never bleed across
# accounts/profiles on machines that run more than one CLAUDE_CONFIG_DIR.
CACHE_FILE="${TMPDIR:-/tmp}/.claude_rl_$(id -u 2>/dev/null || echo 0)_$(basename "$_CLAUDE_CFG")"

# ── parse JSON ────────────────────────────────────────────────────────────────
MODEL=$(echo "$input"     | jq -r '.model.display_name // "unknown"')
DIR=$(echo "$input"       | jq -r '.workspace.current_dir // ""')
SESSION_ID=$(echo "$input"| jq -r '.session_id // empty')
REPO_OWNER=$(echo "$input"| jq -r '.workspace.repo.owner // empty')
REPO_NAME=$(echo "$input" | jq -r '.workspace.repo.name // empty')
SESSION=$(echo "$input"   | jq -r '.session_name // empty')
VERSION=$(echo "$input"   | jq -r '.version // ""')
VIM_MODE=$(echo "$input"  | jq -r '.vim.mode // empty')
AGENT=$(echo "$input"     | jq -r '.agent.name // empty')
WT_BRANCH=$(echo "$input" | jq -r '.worktree.branch // empty')
WT_NAME=$(echo "$input"   | jq -r '.worktree.name // empty')
PROJ_DIR=$(echo "$input"  | jq -r '.workspace.project_dir // empty')
EFFORT=$(echo "$input"    | jq -r '.effort.level // empty')
THINKING=$(echo "$input"  | jq -r '.thinking.enabled // empty')
FAST_MODE=$(echo "$input" | jq -r '.fast_mode // empty')
# Tolerate output_style being either an object ({"name":"…"}) or a bare string.
OUT_STYLE=$(echo "$input" | jq -r '.output_style.name? // .output_style? // empty')
PR_NUM=$(echo "$input"    | jq -r '.pr.number // empty')
PR_STATE=$(echo "$input"  | jq -r '.pr.review_state // empty')

CTX_SIZE=$(echo "$input"  | jq -r '.context_window.context_window_size // 0')
EXCEEDS_200K=$(echo "$input" | jq -r '.exceeds_200k_tokens // empty')
USED_PCT=$(echo "$input"  | jq -r '.context_window.used_percentage // empty')
REM_PCT=$(echo "$input"   | jq -r '.context_window.remaining_percentage // empty')
IN_TOK=$(echo "$input"    | jq -r '.context_window.current_usage.input_tokens // empty')
OUT_TOK=$(echo "$input"   | jq -r '.context_window.current_usage.output_tokens // empty')
CACHE_W=$(echo "$input"   | jq -r '.context_window.current_usage.cache_creation_input_tokens // empty')
CACHE_R=$(echo "$input"   | jq -r '.context_window.current_usage.cache_read_input_tokens // empty')

COST_USD=$(echo "$input"  | jq -r '.cost.total_cost_usd // empty')
DUR_MS=$(echo "$input"    | jq -r '.cost.total_duration_ms // empty')
API_MS=$(echo "$input"    | jq -r '.cost.total_api_duration_ms // empty')
LINES_ADD=$(echo "$input" | jq -r '.cost.total_lines_added // empty')
LINES_DEL=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')

FIVE_HR=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_RST=$(echo "$input"  | jq -r '.rate_limits.five_hour.resets_at // empty')
SEVEN_DAY=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
SEVEN_RST=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# ── rate-limit caching ────────────────────────────────────────────────────────
# Claude Code only includes rate_limits when it gets fresh headers from the API.
# Persist the last known values so the bars don't disappear between messages.
RATE_FRESH=0
CACHE_TS=""
if [ -n "$FIVE_HR" ] || [ -n "$SEVEN_DAY" ]; then
  RATE_FRESH=1
  printf '%s\t%s\t%s\t%s\t%d\n' \
    "${FIVE_HR:-}" "${FIVE_RST:-}" "${SEVEN_DAY:-}" "${SEVEN_RST:-}" "$(date +%s)" \
    > "$CACHE_FILE" 2>/dev/null
elif [ -f "$CACHE_FILE" ]; then
  IFS=$'\t' read -r FIVE_HR FIVE_RST SEVEN_DAY SEVEN_RST CACHE_TS < "$CACHE_FILE"
fi

# ── claude.ai usage endpoint (accurate plan limits) ───────────────────────────
# The stdin rate_limits block only ever carries the 5-hour session window and
# the all-models weekly window. claude.ai's Usage panel additionally shows a
# per-model weekly limit (e.g. "Fable") — that extra data comes from
# GET /api/oauth/usage, the same endpoint the claude.ai settings page and the
# CLI's /usage screen read. We fetch it here too so the statusline matches
# claude.ai exactly: session / all-models weekly / per-model weekly / credits.
#
# Mechanics: the response is cached to a file and refreshed at most every
# USAGE_TTL seconds, and the refresh happens in a DETACHED BACKGROUND job so
# rendering never blocks on the network. The OAuth token is read from
# .credentials.json (Linux) or the macOS Keychain, used for one HTTPS call to
# api.anthropic.com, and never written to disk. Opt out entirely with
# CLAUDE_STATUSLINE_USAGE_API=0 (falls back to the stdin-provided windows).
USAGE_JSON=""
USAGE_AGE=""
if [ "${CLAUDE_STATUSLINE_USAGE_API:-1}" != "0" ]; then
  USAGE_CACHE="${TMPDIR:-/tmp}/.claude_usage_$(id -u 2>/dev/null || echo 0)_$(basename "$_CLAUDE_CFG")"
  _now=$(date +%s)
  _mt=0
  [ -f "$USAGE_CACHE" ] && _mt=$(stat -f %m "$USAGE_CACHE" 2>/dev/null || stat -c %Y "$USAGE_CACHE" 2>/dev/null || echo 0)
  if [ $(( _now - _mt )) -ge "${CLAUDE_STATUSLINE_USAGE_TTL:-180}" ]; then
    _lock="${USAGE_CACHE}.lock"
    _lmt=0
    [ -f "$_lock" ] && _lmt=$(stat -f %m "$_lock" 2>/dev/null || stat -c %Y "$_lock" 2>/dev/null || echo 0)
    # A lock younger than 30s means another render is already refreshing.
    if [ $(( _now - _lmt )) -ge 30 ]; then
      touch "$_lock" 2>/dev/null
      (
        _tok=""
        [ -f "$_CLAUDE_CFG/.credentials.json" ] \
          && _tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$_CLAUDE_CFG/.credentials.json" 2>/dev/null)
        [ -z "$_tok" ] && command -v security >/dev/null 2>&1 \
          && _tok=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
                    | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        if [ -n "$_tok" ]; then
          _resp=$(curl -sf -m 5 \
                    -H "Authorization: Bearer $_tok" \
                    -H "Content-Type: application/json" \
                    -H "anthropic-beta: oauth-2025-04-20" \
                    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
          if [ -n "$_resp" ] && printf '%s' "$_resp" | jq -e 'type == "object"' >/dev/null 2>&1; then
            printf '%s' "$_resp" > "${USAGE_CACHE}.tmp" 2>/dev/null \
              && mv -f "${USAGE_CACHE}.tmp" "$USAGE_CACHE" 2>/dev/null
          fi
        fi
        rm -f "$_lock"
      ) >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
  fi
  if [ -f "$USAGE_CACHE" ]; then
    USAGE_JSON=$(cat "$USAGE_CACHE" 2>/dev/null)
    [ "$_mt" -gt 0 ] 2>/dev/null && USAGE_AGE=$(( _now - _mt ))
  fi
fi

# ── account / plan ────────────────────────────────────────────────────────────
ACCOUNT_EMAIL="" ACCOUNT_ORG="" PLAN_NAME=""

for _cc in "$_CLAUDE_CFG/.claude.json" "$HOME/.claude.json"; do
  [ -f "$_cc" ] || continue
  _email=$(jq -r '.oauthAccount.emailAddress // empty' "$_cc" 2>/dev/null)
  [ -n "$_email" ] && [ "$_email" != "null" ] || continue
  ACCOUNT_EMAIL="$_email"
  ACCOUNT_ORG=$(jq -r '.oauthAccount.organizationName // empty' "$_cc" 2>/dev/null)
  _tier=$(jq -r '(.oauthAccount.userRateLimitTier // .oauthAccount.organizationRateLimitTier) // empty' "$_cc" 2>/dev/null)
  _extra=$(jq -r '.oauthAccount.hasExtraUsageEnabled // false' "$_cc" 2>/dev/null)
  case "$_tier" in
    *max_20x*)                   PLAN_NAME="Max 20x" ;;
    *max_5x*)                    PLAN_NAME="Max 5x" ;;
    *max_1x*)                    PLAN_NAME="Max 1x" ;;
    *claude_pro*|*default_claude_ai*)
      [ "$_extra" = "true" ] && PLAN_NAME="Max" || PLAN_NAME="Pro" ;;
    "") ;;
    *) PLAN_NAME="$_tier" ;;
  esac
  break
done
# Fallback: derive label from config dir name when no auth file found
if [ -z "$ACCOUNT_EMAIL" ]; then
  _dn=$(basename "$_CLAUDE_CFG")
  if [ "$_dn" != ".claude" ] && [ "$_dn" != "claude" ]; then
    ACCOUNT_EMAIL="${_dn#.claude-}"; ACCOUNT_EMAIL="${ACCOUNT_EMAIL#claude-}"
  fi
fi

# ── colours ───────────────────────────────────────────────────────────────────
# Vibrant 256-colour palette — neon-bright so the line pops in any terminal.
CYAN='\033[38;5;51m'      # electric cyan
BLUE='\033[38;5;39m'      # vivid azure
GREEN='\033[38;5;46m'     # neon green
YELLOW='\033[38;5;226m'   # bright yellow
RED='\033[38;5;196m'      # hot red
MAGENTA='\033[38;5;201m'  # hot pink/magenta
ORANGE='\033[38;5;208m'   # bright orange
PURPLE='\033[38;5;141m'   # soft violet
PINK='\033[38;5;213m'     # bubblegum pink
BOLD='\033[1m'; RESET='\033[0m'

# "DIM" is the colour of labels / secondary text. We want it WHITE on a dark
# background but GREY on a light one. A script can't see the terminal background
# directly, so detect it via $COLORFGBG ("foreground;background", exported by
# many terminals) when available. Terminals that DON'T export it (e.g. macOS
# Terminal.app) are assumed dark — the common case — so labels default to white.
# Force either mode explicitly with CLAUDE_STATUSLINE_BG=light|dark.
# Empty bar segments stay a fixed muted grey regardless of background, so the
# unfilled portion never lights up (a background-adaptive white DIM would make
# the bars look almost full on dark terminals).
BAR_EMPTY='\033[38;5;240m'
# 20-step green→yellow→orange→red ramp. Each bar cell is coloured by its own
# position, so a filling bar glides through the spectrum and a full bar is a
# green-to-red gradient — an at-a-glance "fuel gauge" of how deep into the red
# the usage is.
GRAD=(46 46 82 82 118 154 190 226 226 220 214 214 208 208 202 202 196 196 160 124)
DIM='\033[38;5;255m'   # default: assume dark background → white labels
case "$CLAUDE_STATUSLINE_BG" in
  light) DIM='\033[38;5;245m' ;;
  dark)  DIM='\033[38;5;255m' ;;
  *)
    if [ -n "$COLORFGBG" ]; then
      _bg="${COLORFGBG##*;}"
      case "$_bg" in
        7|9|10|11|12|13|14|15) DIM='\033[38;5;245m' ;;  # light background → grey
      esac
    fi
    ;;
esac

# Compact mode (CLAUDE_STATUSLINE_COMPACT=1) trims the line down to the
# essentials — model, plan, dir, branch + git status, the context bar, cost,
# and rate limits — hiding the many secondary badges. Everything is still
# computed the same way; the optional segments are just blanked before render.
COMPACT="${CLAUDE_STATUSLINE_COMPACT:-}"
[ "$COMPACT" = "0" ] || [ "$COMPACT" = "false" ] && COMPACT=""

# ── helpers ───────────────────────────────────────────────────────────────────
# make_spark PCT... — renders a sparkline from a series of integer percentages,
# each glyph sized by its value and coloured with the same green→red ramp as the
# bars, so the context-usage trend reads at a glance.
SPARK_CHARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
make_spark() {
  local out="" v idx cidx
  for v in "$@"; do
    [ "$v" -gt 100 ] 2>/dev/null && v=100; [ "$v" -lt 0 ] 2>/dev/null && v=0
    idx=$(( v * 7 / 100 ));   [ "$idx" -gt 7 ]   && idx=7
    cidx=$(( v * 19 / 100 )); [ "$cidx" -gt 19 ] && cidx=19
    out="${out}\033[38;5;${GRAD[cidx]}m${SPARK_CHARS[idx]}"
  done
  printf "%b" "$out"
}

# make_bar PCT — renders a 20-cell gradient bar. (A second colour arg is still
# accepted but ignored; the per-cell gradient replaces the old flat colour.)
make_bar() {
  local pct="${1:-0}"
  local ipct; ipct=$(printf '%.0f' "$pct" 2>/dev/null) || ipct=0
  [ "$ipct" -gt 100 ] && ipct=100
  [ "$ipct" -lt 0 ]   && ipct=0
  local filled=$(( (ipct * 20 + 50) / 100 ))
  [ "$filled" -gt 20 ] && filled=20
  local out="" i
  for (( i = 0; i < filled; i++ )); do
    out="${out}\033[38;5;${GRAD[i]}m█"
  done
  local empty=$(( 20 - filled ))
  printf -v E "%${empty}s" ""
  printf "%b%b%s" "$out" "$BAR_EMPTY" "${E// /░}"
}

fmt_k() {
  local n="${1:-}"
  [ -z "$n" ] || [ "$n" = "null" ] && echo "—" && return
  [ "$n" -ge 1000 ] 2>/dev/null && printf '%dk' $(( n / 1000 )) || printf '%d' "$n"
}

fmt_usd() {
  local n="${1:-}"
  [ -z "$n" ] || [ "$n" = "null" ] && echo "—" && return
  printf '$%.2f' "$n" 2>/dev/null || echo "—"
}

fmt_dur() {
  local ms="${1:-}"
  [ -z "$ms" ] || [ "$ms" = "null" ] && echo "—" && return
  local secs=$(( ms / 1000 ))
  # Sub-minute durations (common for API waits) show seconds instead of "0m".
  [ "$secs" -lt 60 ] && { printf '%ds' "$secs"; return; }
  local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
  [ "$h" -gt 0 ] && printf '%dh%dm' "$h" "$m" || printf '%dm' "$m"
}

fmt_reset() {
  local epoch="${1:-}"
  # Pass a non-empty second arg to prefix the date (e.g. weekly resets days out).
  local with_date="${2:-}"
  [ -z "$epoch" ] || [ "$epoch" = "null" ] && return
  local now; now=$(date +%s)
  local diff=$(( epoch - now ))
  [ "$diff" -le 0 ] && echo "now" && return
  local d=$(( diff / 86400 )) h=$(( (diff % 86400) / 3600 )) m=$(( (diff % 3600) / 60 ))
  # Absolute wall-clock time the limit resets at — BSD (macOS) vs GNU date.
  local fmt='+%-I:%M%p'
  [ -n "$with_date" ] && fmt='+%a %-m/%-d %-I:%M%p'
  local clock
  clock=$(date -r "$epoch" "$fmt" 2>/dev/null || date -d "@$epoch" "$fmt" 2>/dev/null)
  clock=$(echo "$clock" | tr '[:upper:]' '[:lower:]')
  local clock_part=""
  [ -n "$clock" ] && clock_part=" (${clock})"
  if   [ "$d" -gt 0 ]; then printf '%dd%dh%s' "$d" "$h" "$clock_part"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm%s' "$h" "$m" "$clock_part"
  else                      printf '%dm%s' "$m" "$clock_part"
  fi
}

# iso_to_epoch TS — accepts either epoch seconds (passed through) or an ISO-8601
# string (what /api/oauth/usage returns) and prints unix epoch seconds.
iso_to_epoch() {
  local ts="${1:-}"
  [ -z "$ts" ] || [ "$ts" = "null" ] && return
  case "$ts" in
    *[!0-9]*) ;;                      # not purely numeric → parse as ISO below
    *) printf '%s' "$ts"; return ;;
  esac
  printf '%s' "$ts" | jq -Rr '
    sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
    | try (fromdateiso8601 | tostring) catch empty' 2>/dev/null
}

# abbrev_path PATH — $HOME → ~, and deep paths collapse to "~/…/parent/base"
# so the directory segment stays readable without eating the whole line.
abbrev_path() {
  local p="${1:-}"
  [ -z "$p" ] && return
  case "$p" in
    "$HOME")   printf '~'; return ;;
    "$HOME"/*) p="~${p#"$HOME"}" ;;
  esac
  local IFS='/'
  # shellcheck disable=SC2206
  local parts=($p) n
  n=${#parts[@]}
  if [ "$n" -gt 4 ]; then
    printf '%s/…/%s/%s' "${parts[0]}" "${parts[n-2]}" "${parts[n-1]}"
  else
    printf '%s' "$p"
  fi
}

fmt_age() {
  local ts="${1:-}"
  [ -z "$ts" ] && return
  local now; now=$(date +%s)
  local age=$(( now - ts ))
  if   [ "$age" -lt 60 ];   then printf '%ds' "$age"
  elif [ "$age" -lt 3600 ]; then printf '%dm' $(( age / 60 ))
  else                           printf '%dh' $(( age / 3600 ))
  fi
}

# ── line 1: model / session / account / plan / dir / branch ──────────────────
SESSION_PART=""
[ -n "$SESSION" ] && SESSION_PART=" ${DIM}(${SESSION})${RESET}"

BRANCH=""
GIT_DIR=$(git -C "$DIR" rev-parse --git-dir 2>/dev/null)
if [ -n "$GIT_DIR" ]; then
  BR=$(git -C "$DIR" -c core.useReplacement=false branch --show-current 2>/dev/null)
  [ -n "$WT_BRANCH" ] && BR="$WT_BRANCH"

  # Worktree detection fallback: Claude Code passes .worktree.name for worktrees
  # it manages, but any linked worktree has "/worktrees/" in its git-dir. The
  # main repo root (for the 📂 segment) is the parent of the common git-dir.
  if [ -z "$WT_NAME" ]; then
    case "$GIT_DIR" in
      */worktrees/*)
        WT_NAME=$(basename "$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)")
        if [ -z "$PROJ_DIR" ] || [ "$PROJ_DIR" = "$DIR" ]; then
          _common=$(git -C "$DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
          [ -n "$_common" ] && PROJ_DIR=$(dirname "$_common")
        fi
        ;;
    esac
  fi

  # A single porcelain call yields both upstream divergence and working-tree
  # state, so we summarise the repo right next to the branch name:
  #   ⇡n ahead / ⇣n behind upstream · ●n staged · ✎n modified · …n untracked
  #   ✓ when the tree is clean.
  GIT_STATE=""
  _porc=$(git -C "$DIR" status --porcelain=v1 --branch 2>/dev/null)
  if [ -n "$_porc" ]; then
    _staged=0 _modified=0 _untracked=0 _ahead=0 _behind=0
    while IFS= read -r _l; do
      case "$_l" in
        '## '*)
          case "$_l" in *'[ahead '*)  _ahead=${_l##*'[ahead '};  _ahead=${_ahead%%[,\]]*} ;; esac
          case "$_l" in *'behind '*)   _behind=${_l##*'behind '}; _behind=${_behind%%]*} ;; esac
          ;;
        '??'*) _untracked=$(( _untracked + 1 )) ;;
        ??*)
          _x=${_l:0:1} _y=${_l:1:1}
          [ "$_x" != " " ] && _staged=$(( _staged + 1 ))
          [ "$_y" != " " ] && _modified=$(( _modified + 1 ))
          ;;
      esac
    done <<< "$_porc"

    _div=""
    [ "$_ahead"  -gt 0 ] 2>/dev/null && _div="${_div} ${CYAN}⇡${_ahead}${RESET}"
    [ "$_behind" -gt 0 ] 2>/dev/null && _div="${_div} ${YELLOW}⇣${_behind}${RESET}"

    _wt=""
    [ "$_staged"    -gt 0 ] && _wt="${_wt} ${GREEN}●${_staged}${RESET}"
    [ "$_modified"  -gt 0 ] && _wt="${_wt} ${ORANGE}✎${_modified}${RESET}"
    [ "$_untracked" -gt 0 ] && _wt="${_wt} ${DIM}…${_untracked}${RESET}"

    if [ -z "$_wt" ]; then
      GIT_STATE="${_div} ${GREEN}✓${RESET}"
    else
      GIT_STATE="${_div}${_wt}"
    fi

    # Last-commit age. Dim normally, but nudges amber once uncommitted work has
    # been sitting on a commit older than 30 minutes.
    _cts=$(git -C "$DIR" log -1 --format=%ct 2>/dev/null)
    case "$_cts" in ''|*[!0-9]*) _cts="" ;; esac
    if [ -n "$_cts" ]; then
      _cage=$(( $(date +%s) - _cts ))
      [ "$_cage" -lt 0 ] && _cage=0
      if   [ "$_cage" -lt 60 ];    then _cstr="${_cage}s"
      elif [ "$_cage" -lt 3600 ];  then _cstr="$(( _cage / 60 ))m"
      elif [ "$_cage" -lt 86400 ]; then _cstr="$(( _cage / 3600 ))h"
      else                              _cstr="$(( _cage / 86400 ))d"; fi
      _cc="$DIM"
      [ -n "$_wt" ] && [ "$_cage" -ge 1800 ] && _cc="$ORANGE"
      GIT_STATE="${GIT_STATE} ${_cc}🕐 ${_cstr}${RESET}"
    fi
  fi

  [ -n "$BR" ] && BRANCH=" ${DIM}on${RESET} ${BOLD}${MAGENTA}🌿 ${BR}${RESET}${GIT_STATE}"
fi

# Open-PR badge, coloured by review state.
PR_PART=""
if [ -n "$PR_NUM" ]; then
  case "$PR_STATE" in
    approved)          _pc="$GREEN";  _ps=" ✓" ;;
    changes_requested) _pc="$RED";    _ps=" ✗" ;;
    pending)           _pc="$YELLOW"; _ps="" ;;
    draft)             _pc="$DIM";    _ps=" ✎" ;;
    *)                 _pc="$CYAN";   _ps="" ;;
  esac
  PR_PART=" ${BOLD}${_pc}🔀 #${PR_NUM}${_ps}${RESET}"
fi

# Reasoning-effort badge — escalates from a calm turtle to a rocket. This tracks
# the /effort toggle and re-renders when it changes.
EFFORT_PART=""
if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low)    _ec="$BLUE";    _ee="🐢" ;;
    medium) _ec="$CYAN";    _ee="⚙️" ;;
    high)   _ec="$YELLOW";  _ee="⚡" ;;
    xhigh)  _ec="$ORANGE";  _ee="🔥" ;;
    max)    _ec="$MAGENTA"; _ee="🚀" ;;
    *)      _ec="$CYAN";    _ee="⚙️" ;;
  esac
  EFFORT_PART=" ${BOLD}${_ec}${_ee} ${EFFORT}${RESET}"
fi

# Extended-thinking indicator.
THINK_PART=""
[ "$THINKING" = "true" ] && THINK_PART=" ${PURPLE}💭${RESET}"

# Fast-mode toggle (/fast) — only shown when engaged.
FAST_PART=""
[ "$FAST_MODE" = "true" ] && FAST_PART=" ${BOLD}${GREEN}🏎️  fast${RESET}"

# Output style, shown only when it isn't the default.
STYLE_PART=""
[ -n "$OUT_STYLE" ] && [ "$OUT_STYLE" != "default" ] \
  && STYLE_PART=" ${PINK}🎨 ${OUT_STYLE}${RESET}"

AGENT_PART=""
[ -n "$AGENT" ] && AGENT_PART=" ${BOLD}${ORANGE}🛠️  ${AGENT}${RESET}"

VIM_PART=""
[ -n "$VIM_MODE" ] && VIM_PART=" ${BOLD}${BLUE}[${VIM_MODE}]${RESET}"

VER_PART=""
[ -n "$VERSION" ] && VER_PART=" ${DIM}v${VERSION}${RESET}"

ACCT_PART=""
if [ -n "$ACCOUNT_EMAIL" ]; then
  ACCT_PART=" ${DIM}as${RESET} ${PINK}👤 ${ACCOUNT_EMAIL}${RESET}"
  [ -n "$ACCOUNT_ORG" ] && ACCT_PART="${ACCT_PART} ${DIM}@ ${ACCOUNT_ORG}${RESET}"
fi

PLAN_PART=""
[ -n "$PLAN_NAME" ] && PLAN_PART=" ${DIM}[${RESET}${BOLD}${PURPLE}✨ ${PLAN_NAME}${RESET}${DIM}]${RESET}"

# Repo identity (owner/name) — handy when the folder name differs from the repo.
REPO_PART=""
[ -n "$REPO_OWNER" ] && [ -n "$REPO_NAME" ] \
  && REPO_PART=" ${DIM}(${RESET}${CYAN}${REPO_OWNER}/${REPO_NAME}${RESET}${DIM})${RESET}"

# Give each model family its own accent colour so the robot has a personality.
MODEL_COLOR="$CYAN"
case "$MODEL" in
  *[Oo]pus*)   MODEL_COLOR="$PURPLE" ;;
  *[Ss]onnet*) MODEL_COLOR="$CYAN" ;;
  *[Hh]aiku*)  MODEL_COLOR="$GREEN" ;;
esac

# Model-switch breadcrumb: remember the distinct models used this session (as a
# '|'-separated list in a per-session temp file) and show where we switched
# from. Only appears once you've actually changed models mid-session.
MODELSW_PART=""
if [ -n "$SESSION_ID" ] && [ -n "$MODEL" ] && [ "$MODEL" != "unknown" ]; then
  _msid="${SESSION_ID//[^A-Za-z0-9._-]/}"
  MODELS_FILE="${TMPDIR:-/tmp}/.claude_sparkmdl_$(id -u 2>/dev/null || echo 0)_${_msid}"
  _mlist=""; [ -f "$MODELS_FILE" ] && _mlist=$(cat "$MODELS_FILE" 2>/dev/null)
  if [ "$MODEL" != "${_mlist##*|}" ]; then       # model changed (or first sample)
    # Rebuild the list de-duped — drop any earlier use of the current model,
    # keeping recency order — then append the current model as most-recent, so
    # toggling between a few models keeps a true distinct set (not duplicates).
    _new=""; _oldIFS=$IFS; IFS='|'
    for _m in $_mlist; do
      [ "$_m" = "$MODEL" ] && continue
      _new="${_new:+$_new|}$_m"
    done
    IFS=$_oldIFS
    _mlist="${_new:+$_new|}$MODEL"
    while [ "$(printf '%s' "$_mlist" | tr -cd '|' | wc -c | tr -d ' ')" -ge 5 ]; do
      _mlist="${_mlist#*|}"                        # keep at most the last 5 models
    done
    printf '%s' "$_mlist" > "$MODELS_FILE" 2>/dev/null
  fi
  _prevlist="${_mlist%|*}"                         # everything before the current
  if [ "$_prevlist" != "$_mlist" ]; then          # there is a prior model
    _prev="${_prevlist##*|}"; _prev="${_prev%% (*}"   # drop " (1M context)" suffix
    MODELSW_PART=" ${DIM}↩ ${_prev}${RESET}"
  fi
fi

# In compact mode, drop line 1's secondary badges (keep model, plan, dir, branch).
if [ -n "$COMPACT" ]; then
  MODELSW_PART="" VER_PART="" EFFORT_PART="" THINK_PART="" FAST_PART="" STYLE_PART=""
  SESSION_PART="" AGENT_PART="" VIM_PART="" ACCT_PART="" REPO_PART="" PR_PART=""
fi

# Directory segment: abbreviated path (~ for $HOME, deep paths collapsed).
# Inside a worktree the 📂 shows the MAIN repo and a 🌳 badge names the
# worktree, so "where am I" and "which copy" both read at a glance.
WT_PART=""
if [ -n "$WT_NAME" ]; then
  DIR_LABEL=$(abbrev_path "${PROJ_DIR:-$DIR}")
  WT_PART=" ${BOLD}${GREEN}🌳 ${WT_NAME}${RESET}"
else
  DIR_LABEL=$(abbrev_path "$DIR")
fi
[ -z "$DIR_LABEL" ] && DIR_LABEL="${DIR##*/}"

# Assemble into a variable and print with a constant %b format so a literal '%'
# in any dynamic value (model, session, dir, branch, account) isn't treated as
# a printf format specifier.
LINE1="${BOLD}${MODEL_COLOR}🤖 ${MODEL}${RESET}${MODELSW_PART}${VER_PART}${EFFORT_PART}${THINK_PART}${FAST_PART}${STYLE_PART}${SESSION_PART}${AGENT_PART}${VIM_PART}${ACCT_PART}${PLAN_PART}  ${BOLD}${BLUE}📂 ${DIR_LABEL}${RESET}${WT_PART}${REPO_PART}${BRANCH}${PR_PART}"
printf '%b\n' "$LINE1"

# ── line 2: context window bar + token counts ─────────────────────────────────
if [ -n "$USED_PCT" ]; then
  PCT=$(printf '%.0f' "$USED_PCT" 2>/dev/null || echo 0)
  REM=$(printf '%.0f' "${REM_PCT:-$(( 100 - PCT ))}" 2>/dev/null || echo 0)

  if   [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
  elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
  else BAR_COLOR="$GREEN"; fi

  BAR=$(make_bar "$PCT" "$BAR_COLOR")

  # The brain reflects how full the window is: calm → sweating → overheating.
  CTX_EMOJI="🧠"
  if   [ "$PCT" -ge 90 ]; then CTX_EMOJI="🥵"
  elif [ "$PCT" -ge 70 ]; then CTX_EMOJI="😅"; fi

  TOK_DETAIL=""
  if [ -n "$IN_TOK" ]; then
    TOK_DETAIL=" ${DIM}in:${RESET}$(fmt_k "$IN_TOK") ${DIM}out:${RESET}$(fmt_k "$OUT_TOK")"
    [ -n "$CACHE_R" ] && [ "$CACHE_R" -gt 0 ] 2>/dev/null \
      && TOK_DETAIL="${TOK_DETAIL} ${DIM}cr:${RESET}$(fmt_k "$CACHE_R")"
    [ -n "$CACHE_W" ] && [ "$CACHE_W" -gt 0 ] 2>/dev/null \
      && TOK_DETAIL="${TOK_DETAIL} ${DIM}cw:${RESET}$(fmt_k "$CACHE_W")"

    # Cache-hit %: fraction of the input context served from prompt cache,
    # i.e. cache_read ÷ (input + cache_creation + cache_read).
    # Higher = more reuse = cheaper & faster.
    _cr=${CACHE_R:-0}; _cw=${CACHE_W:-0}; _it=${IN_TOK:-0}
    case "$_cr" in ''|*[!0-9]*) _cr=0 ;; esac
    case "$_cw" in ''|*[!0-9]*) _cw=0 ;; esac
    case "$_it" in ''|*[!0-9]*) _it=0 ;; esac
    _tot=$(( _it + _cw + _cr ))
    if [ "$_cr" -gt 0 ] && [ "$_tot" -gt 0 ]; then
      _hit=$(( _cr * 100 / _tot ))
      if   [ "$_hit" -ge 80 ]; then _hc="$GREEN"
      elif [ "$_hit" -ge 50 ]; then _hc="$YELLOW"
      else _hc="$ORANGE"; fi
      TOK_DETAIL="${TOK_DETAIL} ${_hc}💾 ${_hit}%${RESET}"
    fi
  fi

  # Flag when the conversation has crossed the 200k-token threshold.
  EXCEED_PART=""
  [ "$EXCEEDS_200K" = "true" ] && EXCEED_PART=" ${BOLD}${RED}⚠️ 200k+${RESET}"

  # Context-usage sparkline + runway. We keep a small per-session history of
  # (timestamp, used-%) pairs so we can both draw the trend and project how long
  # until the window is full. Samples are throttled to at most one every 8s (so
  # the line tracks real elapsed time, not render frequency) and capped at the
  # last 20 points. History lives in a per-session temp file.
  SPARK_PART=""
  RUNWAY_PART=""
  if [ -n "$SESSION_ID" ]; then
    # Sanitise the session id before putting it in a path — keep only filename-
    # safe characters so a stray '/' or space can't redirect the write.
    _safe_sid="${SESSION_ID//[^A-Za-z0-9._-]/}"
    SPARK_FILE="${TMPDIR:-/tmp}/.claude_spark2_$(id -u 2>/dev/null || echo 0)_${_safe_sid}"
    _now=$(date +%s); _hist=""
    if [ -f "$SPARK_FILE" ]; then
      _hist=$(cat "$SPARK_FILE" 2>/dev/null)
    else
      # First sample of a new session — opportunistically sweep spark files from
      # sessions untouched for a day so temp files don't accumulate forever.
      find "${TMPDIR:-/tmp}" -maxdepth 1 -name '.claude_spark*' -mtime +1 -delete 2>/dev/null
    fi
    # Parse the flat "ts val ts val …" list into parallel arrays.
    _ts=(); _vs=(); _i=0
    # shellcheck disable=SC2086
    for _tok in $_hist; do
      if [ $(( _i % 2 )) -eq 0 ]; then _ts+=("$_tok"); else _vs+=("$_tok"); fi
      _i=$(( _i + 1 ))
    done
    # Drop a trailing unpaired token from a truncated write, if any.
    [ "${#_ts[@]}" -gt "${#_vs[@]}" ] && _ts=("${_ts[@]:0:${#_vs[@]}}")
    _np=${#_vs[@]}
    _lastts=0; [ "$_np" -ge 1 ] && _lastts=${_ts[$(( _np - 1 ))]}
    case "$_lastts" in ''|*[!0-9]*) _lastts=0 ;; esac

    if [ $(( _now - _lastts )) -ge 8 ]; then
      _ts+=("$_now"); _vs+=("$PCT"); _np=${#_vs[@]}
      if [ "$_np" -gt 20 ]; then
        _ts=("${_ts[@]:$(( _np - 20 ))}"); _vs=("${_vs[@]:$(( _np - 20 ))}"); _np=20
      fi
      _out=""; for (( _i = 0; _i < _np; _i++ )); do _out="$_out ${_ts[_i]} ${_vs[_i]}"; done
      printf '%s\n' "${_out# }" > "$SPARK_FILE" 2>/dev/null
    fi

    [ "$_np" -ge 2 ] && SPARK_PART=" ${DIM}📈${RESET} $(make_spark "${_vs[@]}")${RESET}"

    # Runway: linear projection to 100% from the oldest→newest retained samples.
    # Only shown when context is genuinely climbing over a meaningful window, so
    # it stays quiet during noise or when usage is flat/shrinking.
    if [ "$_np" -ge 3 ]; then
      _v0=${_vs[0]}; _vn=${_vs[$(( _np - 1 ))]}
      _t0=${_ts[0]}; _tn=${_ts[$(( _np - 1 ))]}
      _dv=$(( _vn - _v0 )); _dt=$(( _tn - _t0 ))
      if [ "$_dv" -ge 2 ] && [ "$_dt" -ge 30 ] && [ "$_vn" -lt 100 ]; then
        _eta=$(( (100 - _vn) * _dt / _dv ))               # seconds to full
        [ "$_eta" -gt 0 ] && [ "$_eta" -lt 86400 ] \
          && RUNWAY_PART=" ${DIM}🛫${RESET} ${YELLOW}$(fmt_dur $(( _eta * 1000 )))${RESET}${DIM} to full${RESET}"
      fi
    fi
  fi

  CTX_K=$(fmt_k "$CTX_SIZE")
  # Compact mode keeps the bar, %, remaining and context size (plus the 200k
  # warning), dropping the sparkline, runway and token breakdown.
  [ -n "$COMPACT" ] && { SPARK_PART="" RUNWAY_PART="" TOK_DETAIL=""; }
  # Assemble and print with a constant %b format so a literal '%' in any dynamic
  # segment (e.g. the cache-hit badge) isn't treated as a printf format spec.
  LINE2="${BOLD}${PURPLE}${CTX_EMOJI} ctx${RESET} ${BAR}${RESET} ${BOLD}${BAR_COLOR}${PCT}%${RESET} ${DIM}rem:${RESET}${GREEN}${REM}%${RESET}${SPARK_PART}${RUNWAY_PART}${TOK_DETAIL} ${DIM}ctx:${RESET}${CYAN}${CTX_K}${RESET}${EXCEED_PART}"
  printf '%b\n' "$LINE2"
else
  printf "${PURPLE}🧠 ${DIM}ctx: waiting for first message…${RESET}\n"
fi

# ── line: session cost / duration / lines changed ─────────────────────────────
if [ -n "$COST_USD" ]; then
  LINES_PART=""
  LPH_PART=""
  if [ -n "$LINES_ADD" ] && [ -n "$LINES_DEL" ]; then
    LINES_PART=" ${DIM}(${RESET}${GREEN}+${LINES_ADD}${RESET}${DIM}/${RESET}${RED}-${LINES_DEL}${RESET}${DIM})${RESET}"
    # Code-change velocity: total lines touched per hour over the session.
    if [ -n "$DUR_MS" ] && [ "$DUR_MS" -gt 0 ] 2>/dev/null; then
      _la=$LINES_ADD; case "$_la" in ''|*[!0-9]*) _la=0 ;; esac
      _ld=$LINES_DEL; case "$_ld" in ''|*[!0-9]*) _ld=0 ;; esac
      _lph=$(( (_la + _ld) * 3600000 / DUR_MS ))
      [ "$_lph" -gt 0 ] && LPH_PART=" ${DIM}✏️  ${_lph}/hr${RESET}"
    fi
  fi
  DUR_PART=""
  [ -n "$DUR_MS" ] && DUR_PART=" ${DIM}·${RESET} ${DIM}⏱️  session:${RESET}${CYAN}$(fmt_dur "$DUR_MS")${RESET}"

  # How much of the session was spent waiting on the API.
  API_PART=""
  [ -n "$API_MS" ] && [ "$API_MS" -gt 0 ] 2>/dev/null \
    && API_PART=" ${DIM}·${RESET} ${DIM}🛰️  api:${RESET}${CYAN}$(fmt_dur "$API_MS")${RESET}"

  # Cost tier: 🪙 pocket change (<$1) · 💰 building up ($1–$9) · 💸 pricey (≥$10).
  COST_EMOJI="💰"
  _dollars=${COST_USD%%.*}; case "$_dollars" in ''|*[!0-9]*) _dollars=0 ;; esac
  if   [ "$_dollars" -ge 10 ]; then COST_EMOJI="💸"
  elif [ "$_dollars" -lt 1 ];  then COST_EMOJI="🪙"; fi

  # Cost velocity ($/hr) — spend rate over the whole session, with a burn emoji
  # that escalates: 🐢 <$1 · 🚶 $1–$4 · 🏃 $5–$14 · 🔥 ≥$15 per hour.
  VELO_PART=""
  if [ -n "$DUR_MS" ] && [ "$DUR_MS" -gt 0 ] 2>/dev/null; then
    _rate=$(awk -v c="$COST_USD" -v d="$DUR_MS" 'BEGIN{ printf "%.2f", c*3600000/d }' 2>/dev/null)
    _ri=${_rate%.*}; case "$_ri" in ''|*[!0-9]*) _ri=0 ;; esac
    if   [ "$_ri" -ge 15 ]; then _be="🔥"; _bc="$RED"
    elif [ "$_ri" -ge 5 ];  then _be="🏃"; _bc="$ORANGE"
    elif [ "$_ri" -ge 1 ];  then _be="🚶"; _bc="$YELLOW"
    else                         _be="🐢"; _bc="$GREEN"; fi
    [ -n "$_rate" ] && VELO_PART=" ${DIM}·${RESET} ${_bc}${_be} \$${_rate}/hr${RESET}"
  fi

  # Compact keeps cost, lines and session duration; drops the lines/hr, api-wait
  # and $/hr velocities (computed above, blanked here at render time).
  [ -n "$COMPACT" ] && { LPH_PART="" API_PART="" VELO_PART=""; }

  printf "${BOLD}${GREEN}${COST_EMOJI} cost${RESET} ${BOLD}${YELLOW}$(fmt_usd "$COST_USD")${RESET}${LINES_PART}${LPH_PART}${DUR_PART}${API_PART}${VELO_PART}\n"
fi

# ── lines 4-5: plan usage limits (mirrors claude.ai's Usage panel) ───────────
# Rows: "session" (5-hour window), "all models" (weekly), then one row per
# model-scoped weekly limit (e.g. "Fable"), plus the usage-credits toggle —
# the same rows, in the same order, as claude.ai › Settings › Usage.
# Data source: the /api/oauth/usage snapshot when available (accurate + has
# the model-scoped rows), otherwise the stdin five_hour/seven_day fallback.

# render_limit COLOR LABEL PCT RESET_EPOCH [with_date] — one "<label> <bar> N%
# used resets …" segment. Percent is floored like claude.ai does; the reset
# and the "used" suffix are dropped in compact mode.
render_limit() {
  local lc="$1" lbl="$2" pct="$3" rst="$4" wd="${5:-}"
  local p="${pct%%.*}"
  case "$p" in ''|*[!0-9]*) p=0 ;; esac
  local rc
  if   [ "$p" -ge 90 ]; then rc="$RED"
  elif [ "$p" -ge 70 ]; then rc="$YELLOW"
  else rc="$GREEN"; fi
  local bar; bar=$(make_bar "$p")
  local used_part="" rp=""
  if [ -z "$COMPACT" ]; then
    used_part="${DIM} used${RESET}"
    local r; r=$(fmt_reset "$rst" $wd)
    [ -n "$r" ] && rp=" ${DIM}resets${RESET} ${r}"
  fi
  printf '%s' "${BOLD}${lc}${lbl}${RESET} ${bar}${RESET} ${BOLD}${rc}${p}%${RESET}${used_part}${rp}"
}

SES_PCT="" SES_RST="" WK_PCT="" WK_RST="" MODEL_ROWS="" CREDITS_PART=""
if [ -n "$USAGE_JSON" ]; then
  SES_PCT=$(jq -r '.five_hour.utilization // empty' <<<"$USAGE_JSON" 2>/dev/null)
  SES_RST=$(iso_to_epoch "$(jq -r '.five_hour.resets_at // empty' <<<"$USAGE_JSON" 2>/dev/null)")
  WK_PCT=$(jq -r '.seven_day.utilization // empty' <<<"$USAGE_JSON" 2>/dev/null)
  WK_RST=$(iso_to_epoch "$(jq -r '.seven_day.resets_at // empty' <<<"$USAGE_JSON" 2>/dev/null)")

  # Per-model weekly rows: the named model buckets plus the server-driven
  # limits[] array (kind=weekly_scoped) that claude.ai renders as e.g. "Fable".
  MODEL_ROWS=$(jq -r '
    def row(name; w): w | select(. != null) | select(.utilization != null)
      | [name, (.utilization | tostring), (.resets_at // "")] | @tsv;
    (row("Opus";   .seven_day_opus)),
    (row("Sonnet"; .seven_day_sonnet)),
    (.limits[]?
      | select(.kind == "weekly_scoped")
      | select((.scope.model.display_name // "") != "")
      | select(.percent != null)
      | [.scope.model.display_name, (.percent | tostring), (.resets_at // "")] | @tsv)
  ' <<<"$USAGE_JSON" 2>/dev/null)

  # Usage-credits (extra usage) toggle, as shown at the bottom of the panel.
  _cen=$(jq -r '.extra_usage.is_enabled // false' <<<"$USAGE_JSON" 2>/dev/null)
  if [ "$_cen" = "true" ] && [ -z "$COMPACT" ]; then
    _cut=$(jq -r '.extra_usage.utilization // empty' <<<"$USAGE_JSON" 2>/dev/null)
    if [ -n "$_cut" ]; then
      CREDITS_PART="  ${PINK}💳 credits ${_cut%%.*}%${RESET}"
    else
      CREDITS_PART="  ${PINK}💳 credits on${RESET}"
    fi
  fi
fi

# Fall back to the stdin-provided (or file-cached) windows when the usage
# endpoint hasn't answered yet.
FELL_BACK=""
if [ -z "$SES_PCT" ] && [ -n "$FIVE_HR" ] && [ "$FIVE_HR" != "null" ]; then
  SES_PCT="$FIVE_HR" SES_RST="$FIVE_RST" FELL_BACK=1
fi
if [ -z "$WK_PCT" ] && [ -n "$SEVEN_DAY" ] && [ "$SEVEN_DAY" != "null" ]; then
  WK_PCT="$SEVEN_DAY" WK_RST="$SEVEN_RST" FELL_BACK=1
fi

if [ -n "$SES_PCT" ] || [ -n "$WK_PCT" ] || [ -n "$MODEL_ROWS" ]; then
  # Freshness marker: fallback data shows the old "(cached Xm ago)" note;
  # endpoint data only flags itself once it's gone noticeably stale (>10m).
  STALE_PART=""
  if [ -n "$FELL_BACK" ] && [ "$RATE_FRESH" -eq 0 ] && [ -n "$CACHE_TS" ]; then
    STALE_PART=" ${DIM}(cached $(fmt_age "$CACHE_TS") ago)${RESET}"
  elif [ -z "$FELL_BACK" ] && [ -n "$USAGE_AGE" ] && [ "$USAGE_AGE" -ge 600 ] 2>/dev/null; then
    STALE_PART=" ${DIM}(as of $(( USAGE_AGE / 60 ))m ago)${RESET}"
  fi

  SES_LINE=""
  [ -n "$SES_PCT" ] && SES_LINE=$(render_limit "$ORANGE" "⚡ session" "$SES_PCT" "$SES_RST")

  WEEK_LINE=""
  [ -n "$WK_PCT" ] && WEEK_LINE=$(render_limit "$PINK" "📅 all models" "$WK_PCT" "$WK_RST" with_date)
  if [ -n "$MODEL_ROWS" ]; then
    _seen="|"
    while IFS=$'\t' read -r _mn _mu _mr; do
      [ -n "$_mn" ] && [ -n "$_mu" ] || continue
      case "$_seen" in *"|${_mn}|"*) continue ;; esac   # dedupe by model name
      _seen="${_seen}${_mn}|"
      _mrow=$(render_limit "$PURPLE" "✨ ${_mn}" "$_mu" "$(iso_to_epoch "$_mr")" with_date)
      [ -n "$WEEK_LINE" ] && WEEK_LINE="${WEEK_LINE}  "
      WEEK_LINE="${WEEK_LINE}${_mrow}"
    done <<< "$MODEL_ROWS"
  fi
  WEEK_LINE="${WEEK_LINE}${CREDITS_PART}"

  if [ -n "$SES_LINE" ] && [ -n "$WEEK_LINE" ]; then
    printf '%b%b\n%b\n' "$SES_LINE" "$STALE_PART" "$WEEK_LINE"
  elif [ -n "$SES_LINE" ]; then
    printf '%b%b\n' "$SES_LINE" "$STALE_PART"
  elif [ -n "$WEEK_LINE" ]; then
    printf '%b%b\n' "$WEEK_LINE" "$STALE_PART"
  fi
fi
