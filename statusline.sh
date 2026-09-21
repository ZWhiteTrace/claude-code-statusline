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
SPEND_PCT=\(.rate_limits.spend_limit.used_percentage // "")
SPEND_RESET=\(.rate_limits.spend_limit.resets_at // "")
EXCEEDS_200K=\(.exceeds_200k_tokens // false)
EFFORT=\(.effort.level // "")
FAST_MODE=\(.fast_mode // false)
THINKING=\(if .thinking.enabled == false then "false" else "true" end)
REPO_NAME=\(.workspace.repo.name // "")
GIT_WORKTREE=\(.workspace.git_worktree // "")
PR_NUM=\(if (.pr.number // 0) > 0 then (.pr.number | tostring) else "" end)
PR_STATE=\(.pr.review_state // "")
PR_KIND=\(.pr.kind // "")
PC_PRESENT=\(if .prompt_cache then 1 else 0 end)
PC_OBSERVED=\(.prompt_cache.caching_observed // false)
PC_WARM=\(.prompt_cache.warm // false)
PC_TTL=\(.prompt_cache.ttl // "")
PC_EXPIRES=\(.prompt_cache.expires_at // "")
PC_HIT=\(if .prompt_cache.hit_ratio == null then "" else (.prompt_cache.hit_ratio * 100 | floor) end)
PC_MISSES=\(.prompt_cache.misses // 0)
PC_REBUILDS=\(.prompt_cache.expected_rebuilds // 0)
PC_RECACHE=\(.prompt_cache.recache_tokens_if_cold // "")
PC_CAUSE=\((try (.prompt_cache.last_miss_cause.causes) catch null) | if type == "array" then join(",") else "" end)
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
# Real ESC bytes, not the literal two-character sequence "\033". With the literal
# form every line had to be emitted through `echo -e` / `printf %b`, and those
# also expand escapes inside payload-supplied strings. A git worktree directory
# named `aa\nbb` then split line 4 into two and broke the exactly-four-lines
# contract; `aa\cbb` truncated the output entirely. (git rejects such *branch*
# names, but a worktree directory name allows them.)
RST=$'\033[0m'; DIM=$'\033[2m'
GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; MAG=$'\033[35m'

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
  local pct=$1 c
  if   [ "$pct" -ge 80 ]; then c=$RED
  elif [ "$pct" -ge 50 ]; then c=$YLW
  else c=$GRN
  fi
  # Colour goes through %s, never into the format string: a format string built
  # from data is a bug waiting for the first value containing a percent sign.
  printf '%s%s%%%s' "$c" "$pct" "$RST"
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
# Wide (2 display columns, 1 codepoint) chars that the builders emit THEMSELVES.
# visible_len and clamp_line both read this list, so those two cannot disagree.
#
# It does NOT cover wide characters arriving in payload strings — a repo, branch,
# worktree or agent name in CJK is counted as one column per character and the
# line overruns silently (measured: a 9-character Chinese repo name overshoots by
# 5 columns). Handling that needs a real East Asian Width table rather than a
# glyph list, which is why the subagent status line hands its measuring to perl.
# skipped: full East Asian Width handling here, add when a repo/branch/worktree
# name in CJK actually causes a visible wrap — the cost is a perl fork on a hot
# path, and this user's repo and branch names are ASCII.
#
# The literals below are checked: ⚡ U+26A1 and 🌿 U+1F33F are the only EAW=W
# glyphs the builders produce. ✓ ✗ ⟳ ░ are Neutral; █ │ · … are Ambiguous, which
# this script (like the terminals it targets) renders as one column.
WIDE_CHARS='🌿⚡'

visible_len() {
  local s stripped i ch
  s=$(sed $'s/\x1b\\[[0-9;]*m//g' <<<"$1")
  stripped="$s"
  for ((i = 0; i < ${#WIDE_CHARS}; i++)); do
    ch="${WIDE_CHARS:$i:1}"
    stripped="${stripped//"$ch"/}"
  done
  # length + one extra column per wide char
  echo $(( ${#s} + ${#s} - ${#stripped} ))
}

# === Helper: compact effort level (xhigh -> X) ===
compact_effort() {
  case "$1" in
    low)    echo "l" ;;
    medium) echo "m" ;;
    high)   echo "h" ;;
    xhigh)  echo "X" ;;
    max)    echo "M" ;;
    *)      echo "$1" ;;
  esac
}

# === Helper: safety-net truncation when max degradation still overruns budget ===
# Strips ANSI (loses color) and truncates to BUDGET-1 + ellipsis. Prevents
# terminal-side wrap/truncation at the cost of losing color on extreme-narrow panes.
clamp_line() {
  local line=$1 budget=$2
  [ "$budget" -lt 4 ] && { echo "$line"; return; }
  if [ "$(visible_len "$line")" -le "$budget" ]; then
    echo "$line"
    return
  fi
  local plain
  plain=$(sed $'s/\x1b\\[[0-9;]*m//g' <<<"$line")
  # Truncate by DISPLAY width, not by codepoint count. Slicing N codepoints of a
  # string holding W wide chars yields N+W columns, so a codepoint slice sized to
  # the budget still overruns it — by exactly the number of wide chars kept.
  local out="" w=0 ch cw i
  for ((i = 0; i < ${#plain}; i++)); do
    ch="${plain:$i:1}"
    cw=1
    [[ "$WIDE_CHARS" == *"$ch"* ]] && cw=2
    [ $(( w + cw )) -gt $(( budget - 1 )) ] && break
    out+="$ch"
    w=$(( w + cw ))
  done
  echo "${out}…"
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
  # workspace.repo.name is parsed by CC from the origin remote — free, no fork.
  # It is absent without an origin remote, so keep the git call as the fallback.
  if [ -n "$REPO_NAME" ]; then
    REPO="$REPO_NAME"
  else
    REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
  fi

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
    # Commits that exist only on this machine. Purely local — it compares two
    # local refs and needs no network, so it is always accurate.
    #
    # Deliberately NOT paired with "behind": origin/* only moves on fetch, pull
    # or push, so a behind count reports the state at the last fetch, not the
    # state now. Displayed permanently it would read as an all-clear the script
    # cannot actually give, and would invite skipping the `git fetch` that the
    # shared-file workflow depends on. Missing information beats false comfort.
    # '@{u}..HEAD' is quoted: unquoted, the braces read as a brace expansion to
    # both the shell's eye and shellcheck's (SC1083).
    GIT_AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    # Cache the NUMBERS, never the rendered string. A cache holding rendered
    # output outlives the code that rendered it: when the colour constants moved
    # from the literal "\033" to real ESC bytes, entries written by the previous
    # version were printed verbatim as `\033[33m1M\033[0m` and measured as seven
    # visible characters each, which pushed line 4 over budget and silently
    # dropped the version segment.
    echo "$GIT_M $GIT_A $GIT_AHEAD" > "$GIT_CACHE"
    rm -f "$GIT_LOCK" 2>/dev/null
  fi

  _gm=""; _ga=""; _gahead=""
  if [ -f "$GIT_CACHE" ]; then
    # A two-field entry is one written before the ahead count existed; the third
    # variable simply stays empty and the segment is skipped.
    read -r _gm _ga _gahead < "$GIT_CACHE" 2>/dev/null
    # Reject anything that is not integers — that is an entry written by the
    # pre-change version, in the rendered-string format.
    case "${_gm}:${_ga}:${_gahead}" in
      *[!0-9:]*) _gm=""; _ga=""; _gahead="" ;;
    esac
  fi
  if [ -n "$_gm" ] && [ "$_gm" -gt 0 ] 2>/dev/null; then
    GIT_STATS="${YLW}${_gm}M${RST}"
  fi
  if [ -n "$_ga" ] && [ "$_ga" -gt 0 ] 2>/dev/null; then
    [ -n "$GIT_STATS" ] && GIT_STATS="${GIT_STATS} "
    GIT_STATS="${GIT_STATS}${GRN}${_ga}A${RST}"
  fi
  # Shown only when non-zero, and absent entirely without an upstream — a repo
  # with no remote at all is a different problem, tracked elsewhere.
  if [ -n "$_gahead" ] && [ "$_gahead" -gt 0 ] 2>/dev/null; then
    [ -n "$GIT_STATS" ] && GIT_STATS="${GIT_STATS} "
    GIT_STATS="${GIT_STATS}${YLW}↑${_gahead}${RST}"
  fi
fi

# === Context size label ===
if [ "$CTX_SIZE" -ge 1000000 ]; then CTX_LABEL="1M"
elif [ "$CTX_SIZE" -ge 200000 ]; then CTX_LABEL="200K"
else CTX_LABEL="$(( CTX_SIZE / 1000 ))K"
fi

# === Cache hit rate ===
# Fallback: derived from the LAST response only, and it counts subagent traffic
# the same as main-conversation traffic.
CACHE_TOTAL=$(( CACHE_CREATE + CACHE_READ + INPUT_TOKENS ))
if [ "$CACHE_TOTAL" -gt 0 ]; then CACHE_HIT=$(( CACHE_READ * 100 / CACHE_TOTAL ))
else CACHE_HIT=0
fi
# Preferred: CC's own figure (v2.1.251+). Computed across the whole session and
# scoped to the main conversation, so it tracks actual spend rather than the
# last request's luck. Absent before the first API response of a session.
if [ "$PC_PRESENT" = "1" ] && [ -n "$PC_HIT" ]; then
  CACHE_HIT=$PC_HIT
fi

# === Helper: compact a cache-miss cause name ===
compact_cause() {
  case "${1%%,*}" in
    tools_changed)         echo "tools" ;;
    system_prompt_changed) echo "sysprompt" ;;
    ttl_expired_5m)        echo "ttl5m" ;;
    ttl_expired_1h)        echo "ttl1h" ;;
    likely_server_side)    echo "server" ;;
    *)                     echo "${1%%,*}" ;;
  esac
}

# === API wait percentage ===
API_WAIT_PCT=""
if [ "$DURATION_MS" -gt 0 ] && [ "$API_DURATION_MS" -gt 0 ]; then
  API_WAIT_PCT="$(( API_DURATION_MS * 100 / DURATION_MS ))%"
fi

# ══════════════════════════════════════════════════════════════
# LINE 1: Model + Repo:Branch + Context bar (progressive degradation)
# ══════════════════════════════════════════════════════════════
[ "$STATUSLINE_SHORT_MODEL" = "1" ] && MODEL="${MODEL// context/}"

# Terminal width detection.
#
# Claude Code captures the script's stdout instead of wiring it to the terminal,
# so width probes that go through stdout cannot see the real pane. CC sets
# COLUMNS/LINES itself before each run and the docs name them as the source to
# read, so $COLUMNS is authoritative.
#
# Two probes were removed after measuring a real 2.1.278 payload:
#   - .terminal.width: no such field exists in the payload (confirmed against a
#     live capture and the documented field list). `// 0` made it always 0, so
#     it never won and every run fell through it.
#   - tput cols: ncurses answers from $COLUMNS when it is in the env, so tput
#     just echoes back what we already have — one fork for zero information.
#     Without COLUMNS it would report the non-TTY default instead of the pane.
# `stty size </dev/tty` bypasses the captured stdout and does work in some
# terminals, but measured empty under CC, so it stays only as a fallback and is
# probed lazily — the common path now forks no subprocess at all.
ACTUAL_COLS=0
if [ -n "$COLUMNS" ] && [ "$COLUMNS" -ge 10 ] && [ "$COLUMNS" -le 1000 ] 2>/dev/null; then
  ACTUAL_COLS=$COLUMNS
fi

STTY_COLS=""
STTY_PROBED=""
if [ "$ACTUAL_COLS" = "0" ]; then
  STTY_PROBED=1
  # Wrap in { ... } 2>/dev/null so redirection errors from </dev/tty are swallowed
  # in headless environments (CI, Docker without -t) where /dev/tty is absent.
  STTY_COLS=$({ stty size </dev/tty 2>/dev/null; } 2>/dev/null | awk '{print $2}')
  if [ -n "$STTY_COLS" ] && [ "$STTY_COLS" -ge 10 ] && [ "$STTY_COLS" -le 1000 ] 2>/dev/null; then
    ACTUAL_COLS=$STTY_COLS
  fi
fi

[ "$ACTUAL_COLS" = "0" ] && ACTUAL_COLS=80

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
    # STTY_PROBE distinguishes "COLUMNS won, stty never ran" from "stty ran and
    # came back empty" — the previous label printed the same text for both.
    _stty_state="notprobed"
    [ -n "${STTY_PROBED:-}" ] && _stty_state="${STTY_COLS:-empty}"
    echo "$(date +%H:%M:%S) stty=$_stty_state COLUMNS=${COLUMNS:-unset} ACTUAL=$ACTUAL_COLS MAX=${STATUSLINE_MAX_WIDTH:-unset} PAD=$CHROME_PAD -> COLS=$COLS BUDGET=$BUDGET"
  } >> /tmp/statusline-diag.log 2>/dev/null
fi

# === CHROME_PAD calibration mode ===
# CC renders the status line inside a padded box, so the usable width is narrower
# than $COLUMNS by a fixed number of columns. That difference cannot be read from
# the payload, so it has to be measured once per terminal setup.
#
# Usage:  touch ~/.claude/.statusline-ruler   → the status line becomes a ruler
#         read off the last digit still visible, multiply by 10
#         rm ~/.claude/.statusline-ruler      → back to normal
if [ -f "$HOME/.claude/.statusline-ruler" ]; then
  # Marks every 10th column. Past 90 the marks continue as letters rather than
  # wrapping back to 0-9: a bare "2" would be ambiguous between column 20 and
  # column 120, which is exactly the range this measurement cares about.
  _rule=""
  for ((_i = 1; _i <= ACTUAL_COLS; _i++)); do
    if [ $((_i % 10)) -eq 0 ]; then
      _n=$(( _i / 10 ))
      if [ "$_n" -le 9 ]; then
        _rule+="$_n"
      else
        _rule+=$(printf "\\$(printf '%03o' $(( 87 + _n )))")   # 10->a, 11->b, ...
      fi
    else
      _rule+="."
    fi
  done
  # Second ruler, exactly BUDGET wide. Claude Code truncates an over-long line
  # and appends its own ellipsis, so this one ending in "]" rather than in that
  # ellipsis is the proof that the current padding fits.
  _check=""
  for ((_i = 1; _i <= BUDGET - 1; _i++)); do
    if [ $((_i % 10)) -eq 0 ]; then
      _n=$(( _i / 10 ))
      if [ "$_n" -le 9 ]; then _check+="$_n"; else _check+=$(printf "\\$(printf '%03o' $(( 87 + _n )))"); fi
    else
      _check+="="
    fi
  done
  _check+="]"

  echo "$_rule"
  echo "$_check"
  echo "line1 = COLUMNS ($ACTUAL_COLS). Its last visible mark is the real usable width."
  echo "line2 = current BUDGET ($BUDGET). It must end in ] — if it ends in an ellipsis, CHROME_PAD is too small."
  exit 0
fi

# Build L1 at a given degradation level (0=full, 5=most compact).
# Order: least lossy first — strip decorations before sacrificing signal.
#   L1: Ctx label+suffix (pure decoration, no info loss)
#   L2: Branch trunc 24→16 (mid-branch ellipsis, small loss)
#   L3: Effort abbreviated (xhigh → X, small loss)
#   L4: Model compact (Opus 4.6 (1M) → O4.6·1M, medium loss)
#   L5: Drop repo name (can be inferred from CWD, largest loss)
# The 200k marker and the mode flags are never dropped — they are the only
# signals on this line that the rest of the status line cannot imply.
build_l1() {
  local level=$1
  # rmax starts at 32, not at the old fixed 20. That 20 was chosen when the line
  # had ~70 columns to work with; with the budget now measured rather than
  # guessed there is room for a full repository name, and truncating one that
  # fits is the same kind of loss as the hard-coded width cap this replaced.
  # It still drops back to 20 as soon as the ladder starts compressing.
  local m="$MODEL" bmax=24 rmax=32 show_repo=1 ctx_verbose=1 eff_full=1
  [ $level -ge 1 ] && ctx_verbose=0
  [ $level -ge 2 ] && { bmax=16; rmax=20; }
  [ $level -ge 3 ] && eff_full=0
  [ $level -ge 4 ] && m=$(compact_model "$MODEL")
  [ $level -ge 5 ] && show_repo=0

  # Model segment: name + effort + mode flags. A flag is rendered only when the
  # state differs from the default, so an ordinary session spends no columns on
  # them and an unusual one is impossible to miss.
  local mseg="$m"
  if [ -n "$EFFORT" ]; then
    if [ $eff_full -eq 1 ]; then
      mseg="${mseg}${DIM}·${EFFORT}${RST}"
    else
      mseg="${mseg}${DIM}·$(compact_effort "$EFFORT")${RST}"
    fi
  fi
  [ "$FAST_MODE" = "true" ] && mseg="${mseg}${YLW}⚡${RST}"
  # Abbreviated rather than dropped: thinking being off is an unusual state and
  # is worth two columns even on a narrow pane. Left at full width it was the
  # one segment with no rung to shrink it, which forced clamp_line — and that
  # strips the colour off the entire line — at 40 and 41 columns.
  if [ "$THINKING" = "false" ]; then
    if [ $eff_full -eq 1 ]; then
      mseg="${mseg}${DIM}·nothink${RST}"
    else
      mseg="${mseg}${DIM}·nt${RST}"
    fi
  fi

  # Build repo and branch together so dropping the repo does not leave the
  # branch's ":" separator dangling off the model segment ("[O5·X]:main").
  local loc=""
  [ $show_repo -eq 1 ] && [ -n "$REPO" ] && loc="$(trunc_repo "$REPO" "$rmax")"
  if [ -n "$BRANCH" ]; then
    if [ -n "$loc" ]; then
      loc="${loc}${DIM}:$(trunc_branch "$BRANCH" "$bmax")${RST}"
    else
      loc="${DIM}$(trunc_branch "$BRANCH" "$bmax")${RST}"
    fi
  fi

  local L="[${mseg}]"

  # Position matters more than the ladder here. Appending this at the end of the
  # line put it first in the firing line of clamp_line, which cuts from the right
  # — so the marker disappeared exactly when the pane was tightest. Sitting right
  # after the model segment it survives every truncation.
  #
  # NOT a pricing boundary: Claude 4.6 and later bill the whole 1M window at the
  # standard rate ("a 900k-token request is billed at the same per-token rate as
  # a 9k-token request"). It marks the long-context mode — what /usage attributes
  # as the `long_context` behaviour when explaining where plan usage went. A mode
  # indicator, not an alarm, and coloured as one. The percentage cannot reveal it
  # on a 1M window: 220k reads as 22%.
  if [ "$EXCEEDS_200K" = "true" ]; then
    if [ $level -ge 6 ]; then
      L="${L} ${YLW}!${RST}"
    else
      L="${L} ${YLW}200k+${RST}"
    fi
  fi

  [ -n "$loc" ] && L="${L} ${loc}"
  if [ $ctx_verbose -eq 1 ]; then
    L="${L} │ Ctx: $(cpct "$CTX_PCT") $(bar "$CTX_PCT")/${CTX_LABEL}"
  else
    L="${L} │ $(cpct "$CTX_PCT")$(bar "$CTX_PCT")"
  fi
  echo "$L"
}

# Pick lowest degradation level that fits budget
for _level in 0 1 2 3 4 5 6; do
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
FIVE_INT=${FIVE_H_PCT%%.*}
SEVEN_INT=${SEVEN_D_PCT%%.*}
SPEND_INT=${SPEND_PCT%%.*}
API_SEC=0
TPS="?"
if [ "$API_DURATION_MS" -gt 0 ]; then
  API_SEC=$(echo "scale=1; $API_DURATION_MS / 1000" | bc 2>/dev/null || echo "0")
  [ "$API_SEC" != "0" ] && [ "$API_SEC" != "0.0" ] && TPS=$(echo "scale=1; $OUT_TOKENS / $API_SEC" | bc 2>/dev/null || echo "?")
fi

build_l2() {
  local level=$1
  [ $level -ge 3 ] && { echo "$COST_FMT"; return; }
  local parts=() seg L=""

  # Every window is independently optional, and Claude Code drops one once its
  # resets_at has passed. Gating the whole block on five_hour discarded a
  # seven_day figure that was already parsed — which is exactly the state after
  # a 5-hour window rolls over, i.e. several times a day.
  if [ -n "$FIVE_H_PCT" ]; then
    seg="5h: $(cpct "$FIVE_INT")"
    [ $level -lt 1 ] && seg="${seg} ⟳$(fmt_reset "$FIVE_H_RESET")"
    parts+=("$seg")
  fi
  if [ -n "$SEVEN_D_PCT" ] && [ $level -lt 2 ]; then
    seg="7d: $(cpct "$SEVEN_INT")"
    [ $level -lt 1 ] && seg="${seg} ⟳$(fmt_reset "$SEVEN_D_RESET")"
    parts+=("$seg")
  fi
  if [ -n "$SPEND_PCT" ] && [ $level -lt 2 ]; then
    seg="spend: $(cpct "$SPEND_INT")"
    [ $level -lt 1 ] && seg="${seg} ⟳$(fmt_reset "$SPEND_RESET")"
    parts+=("$seg")
  fi

  if [ ${#parts[@]} -gt 0 ]; then
    for seg in "${parts[@]}"; do
      if [ -n "$L" ]; then L="${L} │ ${seg}"; else L="$seg"; fi
    done
  elif [ "$API_DURATION_MS" -gt 0 ]; then
    # Responses have arrived, but no plan window came with them: an API key, a
    # cloud provider, or an account without the usage scope. Such a session has
    # no limits to show at all, so showing throughput beats a "waiting" that
    # would never resolve.
    L="Speed: ${CYN}${TPS} tok/s${RST}"
    [ $level -lt 1 ] && L="${L} │ API: $(fmt_dur "$API_DURATION_MS")"
  else
    # No responses yet either — genuinely too early to know which case this is.
    L="${DIM}limits: waiting${RST}"
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
  if [ $level -lt 4 ]; then
    L="${DIM}in:${RST}${CYN}$(fmt_tok "$TOTAL_IN")${RST} ${DIM}out:${RST}${MAG}$(fmt_tok "$TOTAL_OUT")${RST}"
  fi

  local cache_seg="Cache: ${CACHE_HIT}%"
  if [ "$PC_PRESENT" = "1" ]; then
    if [ "$PC_OBSERVED" != "true" ]; then
      cache_seg="Cache: ${DIM}not reported${RST}"
    elif [ "$PC_WARM" = "true" ]; then
      # A 5m TTL on a subscription means the session is drawing on usage credits
      # (the subscription TTL is 1h). It silently multiplies re-cache cost, so it
      # gets a colour rather than being one more dim token.
      local ttl_c="$GRN"
      [ "$PC_TTL" = "5m" ] && ttl_c="$RED"
      cache_seg="${cache_seg} ${ttl_c}${PC_TTL}${RST}"
      [ $level -lt 3 ] && [ -n "$PC_EXPIRES" ] && \
        cache_seg="${cache_seg}${DIM}⟳$(fmt_reset "$PC_EXPIRES")${RST}"
    else
      cache_seg="${cache_seg} ${RED}COLD${RST}"
    fi
  else
    cache_seg="${cache_seg} hit"
    [ $level -lt 2 ] && cache_seg="${cache_seg} ${DIM}(r:$(fmt_tok "$CACHE_READ") w:$(fmt_tok "$CACHE_CREATE"))${RST}"
  fi
  if [ -n "$L" ]; then L="${L} │ ${cache_seg}"; else L="$cache_seg"; fi

  # Misses and their diagnosed cause. Shown only when non-zero: a healthy session
  # says nothing, so anything here is worth reading.
  if [ "$PC_PRESENT" = "1" ] && [ $level -lt 3 ]; then
    if [ "$PC_MISSES" != "0" ]; then
      local ms="${YLW}miss:${PC_MISSES}${RST}"
      [ -n "$PC_CAUSE" ] && ms="${ms}${DIM}($(compact_cause "$PC_CAUSE"))${RST}"
      L="${L} │ ${ms}"
    fi
    [ "$PC_REBUILDS" != "0" ] && L="${L} ${DIM}rb:${PC_REBUILDS}${RST}"
  fi

  # What the next request re-caches if the cache goes cold first — the size of
  # the bill for walking away from the terminal.
  if [ "$PC_PRESENT" = "1" ] && [ $level -lt 2 ] && \
     [ -n "$PC_RECACHE" ] && [ "$PC_RECACHE" != "0" ]; then
    L="${L} │ ${DIM}cold:$(fmt_tok "$PC_RECACHE")${RST}"
  fi

  [ $level -lt 1 ] && [ -n "$API_WAIT_PCT" ] && L="${L} │ ${DIM}API${RST} ${API_WAIT_PCT}"
  echo "$L"
}

for _lvl in 0 1 2 3 4; do
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

  # Open PR / MR for this branch. Never dropped: it is the only place the status
  # line can say the branch is already approved or already has changes requested.
  if [ -n "$PR_NUM" ]; then
    local pr_sigil="#"
    [ "$PR_KIND" = "mr" ] && pr_sigil="!"
    local pr_seg="${pr_sigil}${PR_NUM}"
    case "$PR_STATE" in
      approved)          pr_seg="${GRN}${pr_seg}✓${RST}" ;;
      changes_requested) pr_seg="${RED}${pr_seg}✗${RST}" ;;
      draft)             pr_seg="${DIM}${pr_seg}·draft${RST}" ;;
      *)                 pr_seg="${YLW}${pr_seg}${RST}" ;;
    esac
    parts+=("$pr_seg")
  fi

  if [ $show_wt -eq 1 ]; then
    if [ -n "$WORKTREE_NAME" ]; then
      parts+=("${CYN}🌿${WORKTREE_NAME}${RST}${DIM}:${WORKTREE_BRANCH}${RST}")
    elif [ -n "$GIT_WORKTREE" ]; then
      # Any linked git worktree, not just a CC worktree session.
      parts+=("${CYN}🌿${GIT_WORKTREE}${RST}")
    fi
  fi
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
# printf '%s\n', never `echo -e`: the lines carry payload-supplied strings and
# %s expands nothing in them. See the note on the colour definitions.
printf '%s\n' "$L1" "$L2" "$L3" "$L4"
