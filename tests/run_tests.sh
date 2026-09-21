#!/bin/bash
# Statusline test suite.
#
# Three assertions on every case:
#   1. exactly 4 lines  — the hard contract; a payload string carrying a
#      backslash escape used to split or swallow line 4
#   2. no line over budget — measured by an independent oracle (display columns,
#      not codepoints), not by the script's own width function
#   3. no line clamped at a sane width — clamp_line strips colour and hard-cuts,
#      so a broken degradation rung still "fits" and hides behind assertion 2
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SL="${STATUSLINE_UNDER_TEST:-$DIR/../statusline.sh}"
REAL="$DIR/fixture-payload.json"
PAD=5
FAIL=0

# Render from inside a real git repo: from a non-repo directory REPO, BRANCH and
# GIT_STATS are empty, which disables the repo/branch rungs of the L1 ladder and
# the git segment of L4, making a whole class of regressions untestable.
# STATUSLINE_MAX_WIDTH is unset here so COLUMNS alone drives the budget; it has
# its own case below.
REPO_CWD="${STATUSLINE_TEST_CWD:-$DIR/..}"
render() (
  cd "$REPO_CWD" 2>/dev/null || cd "$DIR"
  unset STATUSLINE_MAX_WIDTH
  COLUMNS="$2" bash "$SL" <<<"$1"
)

mut() { jq -c "$1" "$REAL"; }

assert() {
  local name=$1 out=$2 budget=$3 quiet=${4:-}
  local n bad=0
  n=$(printf '%s' "$out" | grep -c '' )
  if [ "$n" != "4" ]; then
    echo "  *** FAIL $name: 輸出 $n 行，契約要求 4 行"
    printf '%s\n' "$out" | cat -v | sed 's/^/      /'
    bad=1
  fi
  if ! printf '%s\n' "$out" | python3 "$DIR/width_oracle.py" "$budget" -q; then
    echo "  *** FAIL $name: 有行超出預算或被 clamp"
    bad=1
  fi
  [ "$bad" = 1 ] && FAIL=$((FAIL + 1))
  return 0
}

check() {
  local name=$1 payload=$2 cols=$3 budget out
  budget=$(( cols - PAD ))
  out=$(render "$payload" "$cols")
  echo "--- $name @ COLUMNS=$cols (budget=$budget) ---"
  printf '%s\n' "$out"
  assert "$name" "$out" "$budget"
  echo
}

# Sweep every width in a range rather than sampling. A wide char the script
# undercounts only overruns at the exact width where the chosen variant sits one
# column under budget; sampling walks straight past it.
sweep() {
  local name=$1 payload=$2 lo=$3 hi=$4 w budget out bad=0
  for ((w = lo; w <= hi; w++)); do
    budget=$(( w - PAD ))
    out=$(render "$payload" "$w")
    local n; n=$(printf '%s' "$out" | grep -c '')
    if [ "$n" != "4" ] || ! printf '%s\n' "$out" | python3 "$DIR/width_oracle.py" "$budget" -q >/dev/null; then
      if [ "$bad" -lt 3 ]; then
        echo "--- SWEEP FAIL: $name @ COLUMNS=$w (budget=$budget, lines=$n) ---"
        printf '%s\n' "$out"
        printf '%s\n' "$out" | python3 "$DIR/width_oracle.py" "$budget" -q
      fi
      bad=$((bad + 1))
    fi
  done
  if [ "$bad" -eq 0 ]; then echo "sweep ok: $name (COLUMNS $lo..$hi)"
  else echo "*** sweep FAIL: $name — $bad 個寬度失敗"; FAIL=$((FAIL + bad)); fi
  echo
}

BASE=$(cat "$REAL")

echo "############ 寬度掃描 ############"
sweep "real payload"                "$BASE" 20 200
sweep "fast+nothink (wide chars)"   "$(mut '.fast_mode = true | .thinking = {enabled:false}')" 20 200
sweep "worktree (wide char)"        "$(mut '.worktree = {name:"wt-alpha",path:"/p",branch:"b",original_cwd:"/o",original_branch:"m"}')" 20 200
sweep "everything"                  "$(mut '.fast_mode = true | .pr = {number:123,review_state:"changes_requested",url:"u"} | .workspace.git_worktree = "wt" | .agent = {name:"general-purpose"} | .prompt_cache.misses = 2 | .prompt_cache.last_miss_cause = {causes:["tools_changed"]}')" 20 200

echo "############ 回歸：review 找到的缺陷 ############"

echo "### R1: thinking.enabled=false 必須顯示（jq // 會吃掉 false） ###"
out=$(render "$(mut '.thinking = {enabled:false}')" 132)
if printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g' | head -1 | grep -q "nothink"; then
  echo "  PASS  nothink 有出現"
else
  echo "  *** FAIL  nothink 不見了（// 又把 false 當 null 了）"; FAIL=$((FAIL+1))
fi
printf '%s\n' "$out" | head -1

echo "### R2: five_hour 過期被 drop、seven_day 還在 ###"
out=$(render "$(mut 'del(.rate_limits.five_hour)')" 132)
l2=$(printf '%s\n' "$out" | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g')
if [[ "$l2" == *"7d:"* ]]; then echo "  PASS  7d 仍顯示: $l2"; else echo "  *** FAIL  7d 被丟掉了: $l2"; FAIL=$((FAIL+1)); fi

echo "### R3: 完全沒有 rate_limits 但已有 API 回應（API key / Bedrock） ###"
out=$(render "$(mut 'del(.rate_limits)')" 132)
l2=$(printf '%s\n' "$out" | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g')
if [[ "$l2" == *"tok/s"* ]]; then echo "  PASS  改顯示吞吐: $l2"; else echo "  *** FAIL  永久 waiting: $l2"; FAIL=$((FAIL+1)); fi

echo "### R4: 沒有 rate_limits 也沒有 API 回應（session 剛開始） ###"
out=$(render "$(mut 'del(.rate_limits) | .cost.total_api_duration_ms = 0')" 132)
l2=$(printf '%s\n' "$out" | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g')
if [[ "$l2" == *"waiting"* ]]; then echo "  PASS  顯示 waiting: $l2"; else echo "  *** FAIL  $l2"; FAIL=$((FAIL+1)); fi

echo "### R5: spend_limit（gateway） ###"
out=$(render "$(mut '.rate_limits.spend_limit = {used_percentage:88,resets_at:1790301600}')" 132)
l2=$(printf '%s\n' "$out" | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g')
if [[ "$l2" == *"spend:"* ]]; then echo "  PASS  $l2"; else echo "  *** FAIL  spend_limit 沒顯示: $l2"; FAIL=$((FAIL+1)); fi

echo "### R6: payload 字串含 backslash 必須仍是 4 行 ###"
for v in 'aa\nbb' 'aa\cbb' 'aa\tbb' 'aa\\bb'; do
  out=$(render "$(jq -c --arg v "$v" '.workspace.git_worktree = $v' "$REAL")" 132)
  n=$(printf '%s' "$out" | grep -c '')
  if [ "$n" = "4" ]; then echo "  PASS  git_worktree='$v' → 4 行"
  else echo "  *** FAIL  git_worktree='$v' → $n 行"; FAIL=$((FAIL+1)); fi
done

echo "### R7: last_miss_cause 型別異常不得讓整條 statusline 塌掉 ###"
for j in '.prompt_cache.last_miss_cause = "a string"' '.prompt_cache.last_miss_cause = 123' '.prompt_cache.last_miss_cause = {causes:"not-an-array"}'; do
  out=$(render "$(mut "$j")" 132)
  n=$(printf '%s' "$out" | grep -c '')
  if [ "$n" = "4" ] && ! printf '%s' "$out" | grep -q "jq error"; then echo "  PASS  $j"
  else echo "  *** FAIL  $j → $n 行"; printf '%s\n' "$out" | head -2 | sed 's/^/      /'; FAIL=$((FAIL+1)); fi
done

echo "### R8: pr.number = 0 不得顯示 #0 ###"
out=$(render "$(mut '.pr = {number:0,url:"u"}')" 132)
if printf '%s' "$out" | grep -q "#0"; then echo "  *** FAIL  顯示了 #0"; FAIL=$((FAIL+1)); else echo "  PASS  未顯示 #0"; fi

echo "### R9: 丟掉 repo 名後不得留下孤立冒號 ###"
bad=0
for w in $(seq 20 60); do
  l1=$(render "$BASE" "$w" | head -1 | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$l1" == *"]:"* ]] && { echo "  *** FAIL  COLUMNS=$w → $l1"; bad=1; break; }
done
[ "$bad" = 0 ] && echo "  PASS  20..60 欄都沒有孤立冒號" || FAIL=$((FAIL+1))

echo "### R10: 200k 標記在窄寬度仍看得見（不得被硬截） ###"
bad=0
for w in $(seq 20 132); do
  l1=$(render "$BASE" "$w" | head -1 | sed $'s/\x1b\\[[0-9;]*m//g')
  case "$l1" in
    *"200k+"*|*" !"*) : ;;
    *) echo "  *** FAIL  COLUMNS=$w 標記消失 → $l1"; bad=1; break ;;
  esac
done
[ "$bad" = 0 ] && echo "  PASS  20..132 欄標記都在" || FAIL=$((FAIL+1))

echo "### R11: git stats 快取存的是數字，不是渲染字串 ###"
# The cache key is derived from the payload's workspace.current_dir, NOT from
# $PWD — writing to a $PWD-derived path produced a green test that never touched
# the cache at all. Hence the positive control before the real cases.
GIT_CACHE_PATH="/tmp/claude-statusline-git-$(printf '%s\n' "$(jq -r '.workspace.current_dir' "$REAL")" | md5 -q)"
_cache_l4() { printf '%s\n' "$1" | tee "$GIT_CACHE_PATH" >/dev/null
              render "$BASE" 132 | sed -n 4p | sed $'s/\x1b\\[[0-9;]*m//g'; }

if [[ "$(_cache_l4 '99 88')" == *"99M"*"88A"* ]]; then
  echo "  PASS  控制組：快取確實被讀取（99M 88A）"
else
  echo "  *** FAIL  控制組失敗 — 下面的案例測不到東西"; FAIL=$((FAIL+1))
fi

for c in '\033[33m5M\033[0m \033[32m2A\033[0m' 'garbage' '5 2 3' '-1 2' ''; do
  out=$(printf '%s\n' "$c" | tee "$GIT_CACHE_PATH" >/dev/null; render "$BASE" 132)
  n=$(printf '%s' "$out" | grep -c '')
  esc=$(printf '%s' "$out" | grep -c '033\[' || true)
  if [ "$n" = "4" ] && [ "$esc" = "0" ]; then
    echo "  PASS  壞快取 '$c' → 4 行、無字面 ESC"
  else
    echo "  *** FAIL  壞快取 '$c' → $n 行、字面 ESC $esc 處"; FAIL=$((FAIL+1))
  fi
done
if [[ "$(_cache_l4 '7 3')" == *"7M 3A"* ]]; then echo "  PASS  正常快取 '7 3' → 7M 3A"
else echo "  *** FAIL  正常快取沒渲染出來"; FAIL=$((FAIL+1)); fi
printf '1 1\n' | tee "$GIT_CACHE_PATH" >/dev/null

echo "############ 使用者真實設定 ############"
echo "### STATUSLINE_MAX_WIDTH=75 + SHORT_MODEL=1（settings.json 實際值） ###"
out=$( cd "$REPO_CWD"; COLUMNS=132 STATUSLINE_MAX_WIDTH=75 STATUSLINE_SHORT_MODEL=1 bash "$SL" <<<"$BASE" )
printf '%s\n' "$out"
assert "user real settings" "$out" 70

echo "############ 各情境 ############"
check "cache COLD"            "$(mut '.prompt_cache.warm = false')" 132
check "cache TTL=5m (吃 credits)" "$(mut '.prompt_cache.ttl = "5m"')" 132
check "cache misses + cause"  "$(mut '.prompt_cache.misses = 3 | .prompt_cache.last_miss_cause = {causes:["tools_changed"],tools_added:2}')" 132
check "caching not observed"  "$(mut '.prompt_cache.caching_observed = false')" 132
check "no prompt_cache (舊版 CC)" "$(mut 'del(.prompt_cache)')" 132
check "hit_ratio null"        "$(mut '.prompt_cache.hit_ratio = null')" 132
check "fast_mode on"          "$(mut '.fast_mode = true')" 132
check "PR approved"           "$(mut '.pr = {number:123,url:"u",review_state:"approved"}')" 132
check "PR changes requested"  "$(mut '.pr = {number:4567,url:"u",review_state:"changes_requested"}')" 132
check "GitLab MR"             "$(mut '.pr = {number:77,url:"u",review_state:"approved",kind:"mr"}')" 132
check "limits high"           "$(mut '.rate_limits.five_hour.used_percentage = 92 | .rate_limits.seven_day.used_percentage = 81')" 132
check "float percentages"     "$(mut '.rate_limits.five_hour.used_percentage = 23.5 | .rate_limits.seven_day.used_percentage = 41.2')" 132
check "empty object"          '{}' 132
check "empty object narrow"   '{}' 30
check "nulls everywhere"      '{"model":null,"cost":null,"context_window":null,"prompt_cache":null,"rate_limits":null,"thinking":null,"pr":null}' 132

echo "================================"
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "$FAIL FAILING CASE(S)"; fi
exit $FAIL
