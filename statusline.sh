#!/bin/bash
# Claude Code Statusline v2 — auto-adapts for cloud (Claude) vs local (Ollama)
# Git file stats cached to /tmp to avoid slow git calls in large repos

# Force UTF-8 locale so ${#var} and wc -m count codepoints (not bytes)
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

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
TERM_W=\(.terminal.width // 0)
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

# === Helper: truncate long branch name (keeps prefix + suffix) ===
trunc_branch() {
  local b="$1" max=${2:-24}
  local len=${#b}
  [ $len -le $max ] && { echo "$b"; return; }
  if [[ "$b" == */* ]]; then
    local prefix="${b%%/*}"
    local rest="${b#*/}"
    local tail_len=$(( max - ${#prefix} - 2 ))
    if [ $tail_len -gt 5 ]; then
      echo "${prefix}/…${rest: -$tail_len}"
      return
    fi
  fi
  local head_len=$(( max / 2 ))
  local tail_len=$(( max - head_len - 1 ))
  echo "${b:0:$head_len}…${b: -$tail_len}"
}

# === Helper: truncate long repo name (middle ellipsis) ===
trunc_repo() {
  local r="$1" max=${2:-20}
  local len=${#r}
  [ $len -le $max ] && { echo "$r"; return; }
  local head_len=$(( max / 2 ))
  local tail_len=$(( max - head_len - 1 ))
  echo "${r:0:$head_len}…${r: -$tail_len}"
}

# === Helper: compact model name (Opus 4.6 (1M) -> O4.6·1M) ===
compact_model() {
  local m="$1" ctx=""
  [[ "$m" == *"(1M)"* ]] && ctx="·1M"
  if [[ "$m" =~ ^([A-Za-z])[A-Za-z]+\ ([0-9.]+) ]]; then
    echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}${ctx}"
  else
    echo "$m"
  fi
}

# === Helper: visible length (strip ANSI, count codepoints + wide-char compensation) ===
# Wide chars (emoji like 🌿) take 2 display cols but 1 codepoint — add +1 each.
# Currently only 🌿 is emitted; extend this if more wide chars are used.
visible_len() {
  local s
  s=$(printf '%b' "$1" | sed $'s/\x1b\\[[0-9;]*m//g')
  local stripped="${s//🌿/}"
  local wide=$(( ${#s} - ${#stripped} ))
  echo $(( ${#s} + wide ))
}

# === Helper: safety-net truncation when max degradation still overruns budget ===
# Strips ANSI (loses color) and truncates to BUDGET-1 + ellipsis. Prevents
# terminal-side wrap/truncation at the cost of losing color on extreme-narrow panes.
clamp_line() {
  local line=$1 budget=$2
  [ "$budget" -lt 4 ] && { echo "$line"; return; }
  if [ "$(visible_len "$line")" -gt "$budget" ]; then
    local plain
    plain=$(printf '%b' "$line" | sed $'s/\x1b\\[[0-9;]*m//g')
    echo "${plain:0:$((budget-1))}…"
  else
    echo "$line"
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
# LINE 1: Model + Repo:Branch + Context bar (progressive degradation)
# ══════════════════════════════════════════════════════════════
[ "$STATUSLINE_SHORT_MODEL" = "1" ] && MODEL="${MODEL// context/}"

# Terminal width detection (priority, since CC's .terminal.width is often 0
# and `tput cols` returns non-TTY default 80 — both lie):
#   1. .terminal.width from JSON (authoritative if CC provides it)
#   2. stty size </dev/tty (most reliable for actual pane width)
#   3. tput cols (unreliable, only used if sane)
#   4. $COLUMNS env
#   5. Fallback 80
ACTUAL_COLS=${TERM_W:-0}

# Probe stty + tput once upfront — used by fallback chain and reused by debug log.
# Wrap in { ... } 2>/dev/null so shell redirection errors from </dev/tty are swallowed
# in headless/no-TTY environments (CI, Docker without -t) where /dev/tty is absent.
STTY_COLS=$({ stty size </dev/tty 2>/dev/null; } 2>/dev/null | awk '{print $2}')
TPUT_COLS=$(tput cols 2>/dev/null)

if [ "$ACTUAL_COLS" = "0" ] || [ -z "$ACTUAL_COLS" ]; then
  if [ -n "$STTY_COLS" ] && [ "$STTY_COLS" -ge 10 ] && [ "$STTY_COLS" -le 500 ] 2>/dev/null; then
    ACTUAL_COLS=$STTY_COLS
  fi
fi

if [ "$ACTUAL_COLS" = "0" ] || [ -z "$ACTUAL_COLS" ]; then
  if [ -n "$TPUT_COLS" ] && [ "$TPUT_COLS" -ge 10 ] 2>/dev/null; then
    ACTUAL_COLS=$TPUT_COLS
  fi
fi

if [ "$ACTUAL_COLS" = "0" ] || [ -z "$ACTUAL_COLS" ]; then
  ACTUAL_COLS=${COLUMNS:-80}
fi

# Soft cap via STATUSLINE_MAX_WIDTH (only when actual wider than cap)
if [ -n "$STATUSLINE_MAX_WIDTH" ] && [ "$STATUSLINE_MAX_WIDTH" -gt 0 ] && [ "$ACTUAL_COLS" -gt "$STATUSLINE_MAX_WIDTH" ]; then
  COLS=$STATUSLINE_MAX_WIDTH
else
  COLS=$ACTUAL_COLS
fi

# Chrome padding: CC's statusline render area has L+R padding that eats cols.
# Observed ~4-5 cols eaten (stty reports 39 but render truncates at ~34).
# Tunable via STATUSLINE_CHROME_PAD env.
CHROME_PAD=${STATUSLINE_CHROME_PAD:-5}
BUDGET=$(( COLS - CHROME_PAD ))
L1_BUDGET=$BUDGET

# Diagnosis log (only when STATUSLINE_DEBUG=1) — uses cached probes, no extra subprocess
if [ -n "$STATUSLINE_DEBUG" ]; then
  {
    echo "$(date +%H:%M:%S) TERM_W=$TERM_W stty_cols=${STTY_COLS:-na} tput_cols=${TPUT_COLS:-na} COLUMNS=${COLUMNS:-unset} ACTUAL=$ACTUAL_COLS MAX=${STATUSLINE_MAX_WIDTH:-unset} PAD=$CHROME_PAD -> COLS=$COLS BUDGET=$BUDGET"
  } >> /tmp/statusline-diag.log 2>/dev/null
fi

# Build L1 at a given degradation level (0=full, 4=most compact).
# Order: least lossy first — strip decorations before sacrificing signal.
#   L1: Ctx label+suffix (pure decoration, no info loss)
#   L2: Branch trunc 24→16 (mid-branch ellipsis, small loss)
#   L3: Model compact (Opus 4.6 (1M) → O4.6·1M, medium loss)
#   L4: Drop repo name (can be inferred from CWD, largest loss)
build_l1() {
  local level=$1
  local m="$MODEL" bmax=24 show_repo=1 ctx_verbose=1
  [ $level -ge 1 ] && ctx_verbose=0
  [ $level -ge 2 ] && bmax=16
  [ $level -ge 3 ] && m=$(compact_model "$MODEL")
  [ $level -ge 4 ] && show_repo=0

  local L
  L=$(printf '[%s]' "$m")
  [ $show_repo -eq 1 ] && [ -n "$REPO" ] && L="${L} $(trunc_repo "$REPO")"
  [ -n "$BRANCH" ] && L="${L}${DIM}:$(trunc_branch "$BRANCH" "$bmax")${RST}"
  if [ $ctx_verbose -eq 1 ]; then
    L="${L} │ Ctx: $(cpct "$CTX_PCT") $(bar "$CTX_PCT")/${CTX_LABEL}"
  else
    L="${L} │ $(cpct "$CTX_PCT")$(bar "$CTX_PCT")"
  fi
  echo "$L"
}

# Pick lowest degradation level that fits budget
for _level in 0 1 2 3 4; do
  L1=$(build_l1 $_level)
  LEN=$(visible_len "$L1")
  [ "$LEN" -le "$L1_BUDGET" ] && break
done
L1=$(clamp_line "$L1" "$L1_BUDGET")

# Cost formatting (used on L2)
COST_FMT=$(printf '$%.2f' "$COST")
[ "$COST" = "0" ] || [ "$COST" = "0.0" ] && COST_FMT="${GRN}\$0.00${RST}"

# ══════════════════════════════════════════════════════════════
# LINE 2: Rate limits (cloud) OR Inference speed (local) + Cost
# Progressive degradation:
#   L0: full   L1: drop reset countdown / drop API duration
#   L2: drop 7d (cloud only)   L3: only cost
# ══════════════════════════════════════════════════════════════
FIVE_INT=$(echo "$FIVE_H_PCT" | cut -d. -f1)
SEVEN_INT=$(echo "$SEVEN_D_PCT" | cut -d. -f1)
API_SEC=0
TPS="?"
if [ "$API_DURATION_MS" -gt 0 ]; then
  API_SEC=$(echo "scale=1; $API_DURATION_MS / 1000" | bc 2>/dev/null || echo "0")
  [ "$API_SEC" != "0" ] && [ "$API_SEC" != "0.0" ] && TPS=$(echo "scale=1; $OUT_TOKENS / $API_SEC" | bc 2>/dev/null || echo "?")
fi

build_l2() {
  local level=$1
  [ $level -ge 3 ] && { echo "$COST_FMT"; return; }
  local L=""
  if [ -n "$FIVE_H_PCT" ] && [ "$FIVE_H_PCT" != "null" ]; then
    L="5h: $(cpct "$FIVE_INT")"
    [ $level -lt 1 ] && L="${L} ⟳$(fmt_reset "$FIVE_H_RESET")"
    if [ $level -lt 2 ]; then
      L="${L} │ 7d: $(cpct "$SEVEN_INT")"
      [ $level -lt 1 ] && L="${L} ⟳$(fmt_reset "$SEVEN_D_RESET")"
    fi
  else
    if [ "$API_DURATION_MS" -gt 0 ]; then
      L="Speed: ${CYN}${TPS} tok/s${RST}"
      [ $level -lt 1 ] && L="${L} │ API: $(fmt_dur "$API_DURATION_MS")"
    else
      L="Speed: waiting..."
    fi
  fi
  echo "${L} │ ${COST_FMT}"
}

for _lvl in 0 1 2 3; do
  L2=$(build_l2 $_lvl)
  [ "$(visible_len "$L2")" -le "$BUDGET" ] && break
done
L2=$(clamp_line "$L2" "$BUDGET")

# ══════════════════════════════════════════════════════════════
# LINE 3: Tokens + Cache + API wait
# Progressive degradation:
#   L0: full   L1: drop API wait
#   L2: drop cache r/w detail   L3: drop in/out tokens (cache hit % only)
# ══════════════════════════════════════════════════════════════
build_l3() {
  local level=$1
  local L=""
  if [ $level -lt 3 ]; then
    L="${DIM}in:${RST}${CYN}$(fmt_tok "$TOTAL_IN")${RST} ${DIM}out:${RST}${MAG}$(fmt_tok "$TOTAL_OUT")${RST}"
  fi
  local cache_seg="Cache: ${CACHE_HIT}% hit"
  [ $level -lt 2 ] && cache_seg="${cache_seg} ${DIM}(r:$(fmt_tok "$CACHE_READ") w:$(fmt_tok "$CACHE_CREATE"))${RST}"
  if [ -n "$L" ]; then L="${L} │ ${cache_seg}"; else L="$cache_seg"; fi
  [ $level -lt 1 ] && [ -n "$API_WAIT_PCT" ] && L="${L} │ ${DIM}API${RST} ${API_WAIT_PCT}"
  echo "$L"
}

for _lvl in 0 1 2 3; do
  L3=$(build_l3 $_lvl)
  [ "$(visible_len "$L3")" -le "$BUDGET" ] && break
done
L3=$(clamp_line "$L3" "$BUDGET")

# ══════════════════════════════════════════════════════════════
# LINE 4: Session + Lines + Git + Worktree + Agent + Version
# Progressive degradation (drop least important first):
#   L0: full   L1: drop version   L2: drop session duration
#   L3: drop agent   L4: drop worktree
#   Git stats + lines +/- always shown (if present) — highest signal
# ══════════════════════════════════════════════════════════════
build_l4() {
  local level=$1
  local show_ver=1 show_session=1 show_agent=1 show_wt=1
  [ $level -ge 1 ] && show_ver=0
  [ $level -ge 2 ] && show_session=0
  [ $level -ge 3 ] && show_agent=0
  [ $level -ge 4 ] && show_wt=0

  local parts=()
  [ $show_session -eq 1 ] && parts+=("Session: $(fmt_dur "$DURATION_MS")")
  if [ "$LINES_ADD" != "0" ] || [ "$LINES_DEL" != "0" ]; then
    parts+=("${GRN}+${LINES_ADD}${RST}/${RED}-${LINES_DEL}${RST}")
  fi
  [ -n "$GIT_STATS" ] && parts+=("$GIT_STATS")
  [ $show_wt -eq 1 ] && [ -n "$WORKTREE_NAME" ] && parts+=("${CYN}🌿${WORKTREE_NAME}${RST}${DIM}:${WORKTREE_BRANCH}${RST}")
  [ $show_agent -eq 1 ] && [ -n "$AGENT" ] && parts+=("${MAG}${AGENT}${RST}")
  [ $show_ver -eq 1 ] && [ -n "$VERSION" ] && parts+=("${DIM}v${VERSION}${RST}")

  local L=""
  if [ ${#parts[@]} -gt 0 ]; then
    for p in "${parts[@]}"; do
      if [ -n "$L" ]; then L="${L} │ ${p}"; else L="$p"; fi
    done
  fi
  echo "$L"
}

for _lvl in 0 1 2 3 4; do
  L4=$(build_l4 $_lvl)
  [ "$(visible_len "$L4")" -le "$BUDGET" ] && break
done
L4=$(clamp_line "$L4" "$BUDGET")

# === Output ===
echo -e "$L1"
echo -e "$L2"
echo -e "$L3"
echo -e "$L4"
