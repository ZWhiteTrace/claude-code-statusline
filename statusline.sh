#!/bin/bash
# Claude Code Statusline v2 — auto-adapts for cloud (Claude) vs local (Ollama)
# Git file stats cached to /tmp to avoid slow git calls in large repos

input=$(cat)

# === Extract all fields in ONE jq call (vs 20+ before) ===
# Uses @sh to emit shell-escaped assignments, then eval into current shell.
# Safe because input is trusted (Claude Code's own JSON), and @sh escapes values.
JQ_OUT=$(echo "$input" | jq -r '@sh "
MODEL=\(.model.display_name // .model.id // "?")
VERSION=\(.version // "")
AGENT=\(.agent.name // "")
WORKTREE_NAME=\(.worktree.name // "")
WORKTREE_BRANCH=\(.worktree.branch // "")
CTX_PCT=\((.context_window.used_percentage // 0) | floor)
CTX_SIZE=\(.context_window.context_window_size // 0)
LINES_ADD=\(.cost.total_lines_added // 0)
LINES_DEL=\(.cost.total_lines_removed // 0)
CWD=\(.workspace.current_dir // "")
CACHE_CREATE=\(.context_window.current_usage.cache_creation_input_tokens // 0)
CACHE_READ=\(.context_window.current_usage.cache_read_input_tokens // 0)
INPUT_TOKENS=\(.context_window.current_usage.input_tokens // 0)
OUT_TOKENS=\(.context_window.current_usage.output_tokens // 0)
TOTAL_IN=\(.context_window.total_input_tokens // 0)
TOTAL_OUT=\(.context_window.total_output_tokens // 0)
FIVE_H_PCT=\(.rate_limits.five_hour.used_percentage // "")
FIVE_H_RESET=\(.rate_limits.five_hour.resets_at // "")
SEVEN_D_PCT=\(.rate_limits.seven_day.used_percentage // "")
SEVEN_D_RESET=\(.rate_limits.seven_day.resets_at // "")
COST=\(.cost.total_cost_usd // 0)
DURATION_MS=\(.cost.total_duration_ms // 0)
API_DURATION_MS=\(.cost.total_api_duration_ms // 0)
"' 2>&1)
JQ_EXIT=$?

# Debug mode: STATUSLINE_DEBUG=1 prints jq output to stderr
[ -n "$STATUSLINE_DEBUG" ] && echo "---JQ OUTPUT---" >&2 && echo "$JQ_OUT" >&2 && echo "---" >&2

# Fallback: if jq failed, print minimal error line instead of broken statusline
if [ $JQ_EXIT -ne 0 ]; then
  echo "[statusline jq error] ${JQ_OUT:0:120}"
  exit 0
fi

eval "$JQ_OUT"

# === Colors ===
RST='\033[0m'; DIM='\033[2m'
GRN='\033[32m'; YLW='\033[33m'; RED='\033[31m'; CYN='\033[36m'; MAG='\033[35m'

# === Helper: context bar ===
bar() {
  local pct=$1 width=5
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local b=""
  for ((i=0; i<filled; i++)); do b+="█"; done
  for ((i=0; i<empty; i++)); do b+="░"; done
  echo "$b"
}

# === Helper: format duration ===
fmt_dur() {
  local sec=$(( $1 / 1000 ))
  if [ $sec -lt 60 ]; then echo "${sec}s"
  elif [ $sec -lt 3600 ]; then echo "$(( sec / 60 ))m$(( sec % 60 ))s"
  elif [ $sec -lt 86400 ]; then echo "$(( sec / 3600 ))h$(( sec % 3600 / 60 ))m"
  else echo "$(( sec / 86400 ))d$(( sec % 86400 / 3600 ))h"
  fi
}

# === Helper: format reset countdown ===
fmt_reset() {
  local reset_epoch=$1
  [ -z "$reset_epoch" ] || [ "$reset_epoch" = "null" ] && { echo "?"; return; }
  local diff=$(( reset_epoch - $(date +%s) ))
  [ $diff -le 0 ] && { echo "now"; return; }
  if [ $diff -lt 3600 ]; then echo "$(( diff / 60 ))m"
  elif [ $diff -lt 86400 ]; then echo "$(( diff / 3600 ))h$(( diff % 3600 / 60 ))m"
  else echo "$(( diff / 86400 ))d$(( diff % 86400 / 3600 ))h"
  fi
}

# === Helper: color by percentage (returns colored string) ===
cpct() {
  local pct=$1
  if [ "$pct" -ge 80 ]; then printf "${RED}%s%%${RST}" "$pct"
  elif [ "$pct" -ge 50 ]; then printf "${YLW}%s%%${RST}" "$pct"
  else printf "${GRN}%s%%${RST}" "$pct"
  fi
}

# === Helper: format token count ===
fmt_tok() {
  local t=$1
  [ -z "$t" ] || [ "$t" = "null" ] || [ "$t" = "0" ] && { echo "0"; return; }
  if [ "$t" -ge 1000000 ]; then printf "%.1fM" "$(echo "scale=1; $t / 1000000" | bc 2>/dev/null)"
  elif [ "$t" -ge 1000 ]; then printf "%.1fK" "$(echo "scale=1; $t / 1000" | bc 2>/dev/null)"
  else echo "$t"
  fi
}

# === Git info (branch + repo = fast, file stats = cached) ===
BRANCH="" REPO="" GIT_STATS=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")

  # Git file stats: cache for 30 seconds + lock to handle 10+ concurrent sessions
  GIT_HASH=$(echo "$CWD" | md5 -q 2>/dev/null || echo "$CWD" | md5sum 2>/dev/null | cut -d' ' -f1)
  GIT_CACHE="/tmp/claude-statusline-git-${GIT_HASH}"
  GIT_LOCK="/tmp/claude-statusline-git-${GIT_HASH}.lock"
  CACHE_AGE=999
  [ -f "$GIT_CACHE" ] && CACHE_AGE=$(( $(date +%s) - $(stat -f%m "$GIT_CACHE" 2>/dev/null || stat -c%Y "$GIT_CACHE" 2>/dev/null || echo 0) ))

  if [ "$CACHE_AGE" -ge 30 ] && ! [ -f "$GIT_LOCK" ]; then
    # Lock: prevent concurrent git calls from multiple sessions
    touch "$GIT_LOCK" 2>/dev/null
    GIT_M=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
    GIT_A=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    PARTS=""
    [ "$GIT_M" -gt 0 ] && PARTS="${YLW}${GIT_M}M${RST}"
    [ "$GIT_A" -gt 0 ] && { [ -n "$PARTS" ] && PARTS="${PARTS} "; PARTS="${PARTS}${GRN}${GIT_A}A${RST}"; }
    echo "$PARTS" > "$GIT_CACHE"
    rm -f "$GIT_LOCK" 2>/dev/null
  fi
  GIT_STATS=$(cat "$GIT_CACHE" 2>/dev/null)
fi

# === Context size label ===
if [ "$CTX_SIZE" -ge 1000000 ]; then CTX_LABEL="1M"
elif [ "$CTX_SIZE" -ge 200000 ]; then CTX_LABEL="200K"
else CTX_LABEL="$(( CTX_SIZE / 1000 ))K"
fi

# === Cache hit rate ===
CACHE_TOTAL=$(( CACHE_CREATE + CACHE_READ + INPUT_TOKENS ))
if [ "$CACHE_TOTAL" -gt 0 ]; then CACHE_HIT=$(( CACHE_READ * 100 / CACHE_TOTAL ))
else CACHE_HIT=0
fi

# === API wait percentage ===
API_WAIT_PCT=""
if [ "$DURATION_MS" -gt 0 ] && [ "$API_DURATION_MS" -gt 0 ]; then
  API_WAIT_PCT="$(( API_DURATION_MS * 100 / DURATION_MS ))%"
fi

# ══════════════════════════════════════════════════════════════
# LINE 1: Model + Repo:Branch + Context bar
# ══════════════════════════════════════════════════════════════
# Opt-in: strip " context" from model name (e.g. "Opus 4.6 (1M context)" -> "Opus 4.6 (1M)")
[ "$STATUSLINE_SHORT_MODEL" = "1" ] && MODEL="${MODEL// context/}"
L1=$(printf '[%s]' "$MODEL")
[ -n "$REPO" ] && L1="${L1} ${REPO}"
[ -n "$BRANCH" ] && L1="${L1}${DIM}:${BRANCH}${RST}"
L1="${L1} │ Ctx: $(cpct "$CTX_PCT") $(bar "$CTX_PCT")/${CTX_LABEL}"

# Cost formatting (used on L2)
COST_FMT=$(printf '$%.2f' "$COST")
[ "$COST" = "0" ] || [ "$COST" = "0.0" ] && COST_FMT="${GRN}\$0.00${RST}"

# ══════════════════════════════════════════════════════════════
# LINE 2: Rate limits (cloud) OR Inference speed (local) + Cost
# ══════════════════════════════════════════════════════════════
L2=""
if [ -n "$FIVE_H_PCT" ] && [ "$FIVE_H_PCT" != "null" ]; then
  FIVE_INT=$(echo "$FIVE_H_PCT" | cut -d. -f1)
  SEVEN_INT=$(echo "$SEVEN_D_PCT" | cut -d. -f1)
  L2="5h: $(cpct "$FIVE_INT") ⟳$(fmt_reset "$FIVE_H_RESET") │ 7d: $(cpct "$SEVEN_INT") ⟳$(fmt_reset "$SEVEN_D_RESET")"
else
  if [ "$API_DURATION_MS" -gt 0 ]; then
    API_SEC=$(echo "scale=1; $API_DURATION_MS / 1000" | bc 2>/dev/null || echo "0")
    TPS="?"
    [ "$API_SEC" != "0" ] && [ "$API_SEC" != "0.0" ] && TPS=$(echo "scale=1; $OUT_TOKENS / $API_SEC" | bc 2>/dev/null || echo "?")
    L2="Speed: ${CYN}${TPS} tok/s${RST} │ API: $(fmt_dur "$API_DURATION_MS")"
  else
    L2="Speed: waiting..."
  fi
fi
L2="${L2} │ ${COST_FMT}"

# ══════════════════════════════════════════════════════════════
# LINE 3: Tokens + Cache + API wait
# ══════════════════════════════════════════════════════════════
L3="${DIM}in:${RST}${CYN}$(fmt_tok "$TOTAL_IN")${RST} ${DIM}out:${RST}${MAG}$(fmt_tok "$TOTAL_OUT")${RST}"
L3="${L3} │ Cache: ${CACHE_HIT}% hit ${DIM}(r:$(fmt_tok "$CACHE_READ") w:$(fmt_tok "$CACHE_CREATE"))${RST}"
[ -n "$API_WAIT_PCT" ] && L3="${L3} │ ${DIM}API${RST} ${API_WAIT_PCT}"

# ══════════════════════════════════════════════════════════════
# LINE 4: Session + Lines + Git + Worktree + Agent + Version
# ══════════════════════════════════════════════════════════════
L4="Session: $(fmt_dur "$DURATION_MS")"
[ "$LINES_ADD" != "0" ] || [ "$LINES_DEL" != "0" ] && L4="${L4} │ ${GRN}+${LINES_ADD}${RST}/${RED}-${LINES_DEL}${RST}"
[ -n "$GIT_STATS" ] && L4="${L4} │ ${GIT_STATS}"
[ -n "$WORKTREE_NAME" ] && L4="${L4} │ ${CYN}🌿${WORKTREE_NAME}${RST}${DIM}:${WORKTREE_BRANCH}${RST}"
[ -n "$AGENT" ] && L4="${L4} │ ${MAG}${AGENT}${RST}"
[ -n "$VERSION" ] && L4="${L4} │ ${DIM}v${VERSION}${RST}"

# === Output ===
echo -e "$L1"
echo -e "$L2"
echo -e "$L3"
echo -e "$L4"
