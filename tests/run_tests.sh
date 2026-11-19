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
# Pin every input the width maths depends on, rather than inheriting it. $PAD is
# compared against the script's own padding, so letting the script read a
# different STATUSLINE_CHROME_PAD from the environment makes every case that
# fills its budget fail by exactly that difference — which is what happened the
# day the user's settings.json changed the value from 5 to 4.
# The per-model limits come from a file, not the payload. Unpinned, every case
# would read this machine's real ~/.claude.json and change with the live usage.
# USAGE_FILE_UNDER_TEST selects a fixture; by default no file exists.
render() (
  cd "$REPO_CWD" 2>/dev/null || cd "$DIR" || exit 1
  unset STATUSLINE_MAX_WIDTH STATUSLINE_SHORT_MODEL STATUSLINE_DEBUG
  STATUSLINE_USAGE_FILE="${USAGE_FILE_UNDER_TEST:-$DIR/no-such-usage-file}" \
    STATUSLINE_CODEX_FILE="${CODEX_FILE_UNDER_TEST:-$DIR/no-such-codex-file}" \
    STATUSLINE_CHROME_PAD="$PAD" COLUMNS="$2" bash "$SL" <<<"$1"
)

mut() { jq -c "$1" "$REAL"; }

assert() {
  local name=$1 out=$2 budget=$3
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

echo "### R13: 只有一個時窗（Ultra 自 2026-10-31 只送 7d）時，任何寬度都不得把它丟掉 ###"
# The L2 rung drops 7d and spend, which reads as if a single-window plan would lose
# its only limit and fall through to the tok/s line meant for sessions without plan
# limits. It does not today — one window's L1 line is short enough to fit wherever
# L2 would — so this pins that down rather than a past bug. Checked against the
# two-window payload instead of hard-coded widths: wherever that one still shows a
# window, the 7d-only plan must show its own.
_l2() { render "$1" "$2" | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g'; }
SEVEN_ONLY=$(mut 'del(.rate_limits.five_hour)')
SPEND_ONLY=$(mut '.rate_limits = {spend_limit:{used_percentage:88,resets_at:1790301600}}')
l2_rung=0 bad=0
for ((w = 20; w <= 200; w++)); do
  ref=$(_l2 "$BASE" "$w")
  [[ "$ref" == *"5h:"* && "$ref" != *"7d:"* ]] && l2_rung=$((l2_rung + 1))
  seven=$(_l2 "$SEVEN_ONLY" "$w")
  spend=$(_l2 "$SPEND_ONLY" "$w")
  if [[ "$ref" == *"5h:"* && "$seven" != *"7d:"* ]]; then
    echo "  *** FAIL  7d-only @ COLUMNS=$w → ${seven}（兩時窗版仍顯示：${ref}）"; bad=1; break
  fi
  case "$seven$spend" in
    *"tok/s"*|*"waiting"*) echo "  *** FAIL  有時窗卻退回無限額畫面 @ COLUMNS=$w → $seven ／ $spend"; bad=1; break ;;
  esac
done
if [ "$l2_rung" -eq 0 ]; then
  echo "  *** FAIL  控制組：20..200 欄沒有任何寬度落在 L2，這個案例測不到東西"; FAIL=$((FAIL+1))
elif [ "$bad" = 0 ]; then
  echo "  PASS  20..200 欄單一時窗都保留（其中 $l2_rung 個寬度落在 L2）"
else
  FAIL=$((FAIL+1))
fi

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

# NB: '5 2 3' is no longer listed here — a third field is the valid ahead count
# since R12, and leaving it labelled "壞快取" would mislead the next reader.
for c in '\033[33m5M\033[0m \033[32m2A\033[0m' 'garbage' '5 2 3 4' '-1 2' '' '5.5 2'; do
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

echo "### R12: unpushed commit 數（ahead）###"
# Two-field entries predate the ahead count; they must degrade to "no arrow",
# not to a broken field.
if [[ "$(_cache_l4 '7 3')" != *"↑"* ]]; then echo "  PASS  舊兩欄快取 → 不顯示箭頭"
else echo "  *** FAIL  舊兩欄快取誤顯示箭頭"; FAIL=$((FAIL+1)); fi
if [[ "$(_cache_l4 '7 3 0')" != *"↑"* ]]; then echo "  PASS  ahead=0 → 不顯示"
else echo "  *** FAIL  ahead=0 仍顯示"; FAIL=$((FAIL+1)); fi
out=$(_cache_l4 '7 3 2')
if [[ "$out" == *"↑2"* ]]; then echo "  PASS  ahead=2 → $out"
else echo "  *** FAIL  ahead=2 沒顯示：$out"; FAIL=$((FAIL+1)); fi
if [[ "$(_cache_l4 '0 0 5')" == *"↑5"* ]]; then echo "  PASS  只有 ahead（乾淨工作區）→ 仍顯示"
else echo "  *** FAIL  只有 ahead 時沒顯示"; FAIL=$((FAIL+1)); fi
for c in '7 3 garbage' '7 3 -1' '7 3 2 9'; do
  o=$(printf '%s\n' "$c" | tee "$GIT_CACHE_PATH" >/dev/null; render "$BASE" 132)
  n=$(printf '%s' "$o" | grep -c '')
  if [ "$n" = "4" ]; then echo "  PASS  壞 ahead 欄 '$c' → 仍 4 行"
  else echo "  *** FAIL  壞 ahead 欄 '$c' → $n 行"; FAIL=$((FAIL+1)); fi
done
# The arrow must be counted as one display column, like the other box glyphs.
out=$(printf '7 3 12\n' | tee "$GIT_CACHE_PATH" >/dev/null; render "$BASE" 132)
if printf '%s\n' "$out" | python3 "$DIR/width_oracle.py" 127 -q; then
  echo "  PASS  含箭頭時寬度計算正確"
else
  echo "  *** FAIL  含箭頭時寬度算錯"; FAIL=$((FAIL+1))
fi
printf '1 1 0\n' | tee "$GIT_CACHE_PATH" >/dev/null

echo "############ 每個模型的週額度與加購額度（讀 ~/.claude.json 的用量快取） ############"
# Times in the fixture are relative to now, so the age and reset checks see the
# same thing on every run. fixture-usage.json is synthetic: fake account id, no
# real usage figures.
USAGE_TMP=$(mktemp -d)
trap 'rm -rf "$USAGE_TMP"' EXIT
usage() {  # usage <file name> [jq mutation applied after the times are set]
  local now; now=$(date +%s)
  jq --argjson now "$now" '
    .cachedUsageUtilization.fetchedAtMs = (($now - 60) * 1000)
    | .cachedUsageUtilization.utilization.limits[].resets_at = ((($now + 43200) | todate) | sub("Z$"; ".141149+00:00"))
    | '"${2:-.}" "$DIR/fixture-usage.json" > "$USAGE_TMP/$1"
  printf '%s' "$USAGE_TMP/$1"
}
_ul2() { ( USAGE_FILE_UNDER_TEST=$1; render "$2" "${3:-132}" ) | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g'; }
_ucheck() {  # _ucheck <name> <file> <expected substring, or !substring that must be absent>...
  local name=$1 file=$2 l2 want ok=1; shift 2
  l2=$(_ul2 "$file" "$BASE")
  for want in "$@"; do
    if [[ "$want" == "!"* ]]; then [[ "$l2" == *"${want#!}"* ]] && ok=0
    else [[ "$l2" == *"$want"* ]] || ok=0; fi
  done
  if [ $ok = 1 ]; then echo "  PASS  $name: $l2"; else echo "  *** FAIL  $name: ${l2}（期望 $*）"; FAIL=$((FAIL+1)); fi
}

echo "### U1: 控制組 —— fixture 確實被讀到（下面的負向案例才有意義） ###"
# "!scoped" catches the overall weekly_all entry leaking in as a per-model one.
_ucheck "Fable 100% 與倒數" "$(usage base.json)" "fable: 100% ⟳1" "7d: 41%" "!scoped" "!41% ⟳1"
_ucheck "不給檔案 → 與改版前相同" "$DIR/no-such-usage-file" "!fable" "!credits" "5h: 23%" "7d: 41%"

echo "### U2: 加購額度只在用了、或有時窗滿了時出現 ###"
_ucheck "Fable 滿、已用 0 → 顯示" "$(usage full-unused.json)" "credits: \$0.00/\$10 │"
_ucheck "已用 \$1.23 → 顯示" "$(usage used.json '.cachedUsageUtilization.utilization.limits[1].percent = 40 | .cachedUsageUtilization.utilization.spend.used.amount_minor = 123')" "fable: 40%" "credits: \$1.23/\$10 │"
_ucheck "沒滿也沒用 → 不顯示" "$(usage idle.json '.cachedUsageUtilization.utilization.limits[1].percent = 40')" "fable: 40%" "!credits"
_ucheck "加購關閉 → 不顯示" "$(usage off.json '.cachedUsageUtilization.utilization.spend.enabled = false')" "fable: 100%" "!credits"
_ucheck "非美元 → 幣別代碼" "$(usage eur.json '.cachedUsageUtilization.utilization.spend.used = {amount_minor:5,currency:"EUR",exponent:2}')" "credits: EUR 0.05/EUR 10 │"
_ucheck "上限非整數" "$(usage odd.json '.cachedUsageUtilization.utilization.spend.limit.amount_minor = 1050')" "/\$10.50 │"
out=$(_ul2 "$(usage seven-full.json 'del(.cachedUsageUtilization.utilization.limits[1])')" "$(mut '.rate_limits.seven_day.used_percentage = 100')")
if [[ "$out" == *"credits: \$0.00/\$10 │"* && "$out" != *"fable"* ]]; then echo "  PASS  沒有 Fable 桶、payload 的 7d=100 也觸發: $out"
else echo "  *** FAIL  payload 的 7d=100 沒觸發: $out"; FAIL=$((FAIL+1)); fi
_ucheck "沒有 Fable 桶、7d 未滿 → 不顯示" "$(usage seven-ok.json 'del(.cachedUsageUtilization.utilization.limits[1])')" "!fable" "!credits"

echo "### U3: 過時與過期 ###"
_ucheck "11 分鐘前 → 還不標（背景每 15 分鐘更新）" "$(usage recent.json '.cachedUsageUtilization.fetchedAtMs -= 600000')" "fable: 100%" "!m)"
_ucheck "21 分鐘前 → 標年齡" "$(usage stale.json '.cachedUsageUtilization.fetchedAtMs -= 1200000')" "fable: 100%" "(21m)"
_ucheck "剛抓 → 不標年齡" "$(usage fresh.json)" "!m)"
# A fixed weekly window only rises, so an old figure is a floor: kept, with its age.
_ucheck "3 小時前 → 仍顯示並標 (3h)" "$(usage old.json '.cachedUsageUtilization.fetchedAtMs -= 10800000')" "fable: 100% ⟳" "credits: \$0.00/\$10 (3h)"
# Credits count per month and carry no reset time: dropped after a day.
_ucheck "超過 1 天 → 加購不顯示、Fable 仍在 (1d)" "$(usage day.json '.cachedUsageUtilization.fetchedAtMs -= 86400000')" "fable: 100% ⟳" "(1d)" "!credits"
_ucheck "抓取時間在未來 → 不顯示" "$(usage future.json '.cachedUsageUtilization.fetchedAtMs += 600000')" "!fable"
_ucheck "重置時間已過 → 該項不顯示" "$(usage reset.json '.cachedUsageUtilization.utilization.limits[1].resets_at = "2020-01-01T00:00:00.000000+00:00"')" "!fable"
_ucheck "重置時間格式不明 → 顯示但不倒數" "$(usage noreset.json '.cachedUsageUtilization.utilization.limits[1].resets_at = "soon"')" "fable: 100%" "!fable: 100% ⟳"
out=$(_ul2 "$(usage stale-narrow.json '.cachedUsageUtilization.fetchedAtMs -= 1200000')" "$BASE" 60)
if [[ "$out" == *"fable: 100% (21m)"* ]]; then echo "  PASS  窄寬度仍保留年齡: $out"; else echo "  *** FAIL  窄寬度丟了年齡: $out"; FAIL=$((FAIL+1)); fi

echo "### U4: 帳號 ###"
_ucheck "帳號不同 → 不顯示" "$(usage other-account.json '.oauthAccount.accountUuid = "00000000-0000-4000-8000-000000000002"')" "!fable" "!credits"
_ucheck "快取沒帶帳號 → 不顯示" "$(usage no-account.json 'del(.cachedUsageUtilization.accountUuid)')" "!fable"
_ucheck "已登出（無 oauthAccount） → 不顯示" "$(usage logged-out.json 'del(.oauthAccount)')" "!fable"

echo "### U5: 格式異常一律不得弄壞 statusline ###"
printf 'not json' > "$USAGE_TMP/garbage.json"
for f in "$USAGE_TMP/garbage.json" \
         "$(usage limits-string.json '.cachedUsageUtilization.utilization.limits = "x"')" \
         "$(usage pct-string.json '.cachedUsageUtilization.utilization.limits[1].percent = "100"')" \
         "$(usage util-array.json '.cachedUsageUtilization.utilization = []')" \
         "$(usage cache-string.json '.cachedUsageUtilization = "x"')" \
         "$(usage spend-string.json '.cachedUsageUtilization.utilization.spend = "x"')" \
         "$(usage exp-huge.json '.cachedUsageUtilization.utilization.spend.used.exponent = 40')" \
         "$(usage root-array.json '[.]')"; do
  out=$( USAGE_FILE_UNDER_TEST=$f; render "$BASE" 132 )
  n=$(printf '%s' "$out" | grep -c '')
  l2=$(printf '%s\n' "$out" | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g')
  if [ "$n" = "4" ] && [[ "$l2" == *"7d: 41%"* ]] && ! printf '%s' "$out" | grep -q "jq error"; then
    echo "  PASS  $(basename "$f") → 4 行、原本的時窗還在: $l2"
  else
    echo "  *** FAIL  $(basename "$f") → $n 行: $l2"; FAIL=$((FAIL+1))
  fi
done
_ucheck "scope 為 null 的桶仍顯示（名稱退為 scoped）" "$(usage scope-null.json '.cachedUsageUtilization.utilization.limits[1].scope = null')" "scoped: 100%"
_ucheck "名稱只留安全字元" "$(usage weird-name.json '.cachedUsageUtilization.utilization.limits[1].scope.model.display_name = "Fa;ble $(id) 5\u001b[31m"')" "fableid531m: 100%" '!$(' "!;"
_ucheck "負的百分比 → 0" "$(usage negative.json '.cachedUsageUtilization.utilization.limits[1].percent = -5')" "fable: 0%"
_ucheck "兩個模型桶都顯示" "$(usage two.json '.cachedUsageUtilization.utilization.limits += [.cachedUsageUtilization.utilization.limits[1] | .percent = 30 | .scope.model.display_name = "Opus"]')" "fable: 100%" "opus: 30%"

echo "### U6: 寬度契約（有用量檔時） ###"
# Not in a subshell: sweep adds to FAIL, and a subshell would throw the count away.
USAGE_FILE_UNDER_TEST=$(usage sweep-base.json)
sweep "usage: fable full + credits" "$BASE" 20 200
USAGE_FILE_UNDER_TEST=$(usage sweep-all.json '.cachedUsageUtilization.fetchedAtMs -= 1500000 | .cachedUsageUtilization.utilization.spend.used.amount_minor = 98765')
sweep "usage: 所有段落＋年齡" "$(mut '.rate_limits.spend_limit = {used_percentage:88,resets_at:1790301600}')" 20 200
unset USAGE_FILE_UNDER_TEST

echo "### U7: 只有 7d 的方案＋Fable 桶：任何寬度都不得退回無限額畫面，有時窗就有 Fable ###"
SEVEN_ONLY_U=$(mut 'del(.rate_limits.five_hour)')
U7_FILE=$(usage u7.json)
bad=0 seen_l2=0
for ((w = 20; w <= 200; w++)); do
  l2=$(_ul2 "$U7_FILE" "$SEVEN_ONLY_U" "$w")
  case "$l2" in *"tok/s"*|*"waiting"*) echo "  *** FAIL  @ COLUMNS=$w 退回無限額畫面 → $l2"; bad=1; break ;; esac
  if [[ "$l2" == *"7d:"* && "$l2" != *"fable:"* ]]; then
    echo "  *** FAIL  @ COLUMNS=$w 有 7d 卻沒有 Fable → $l2"; bad=1; break
  fi
  [[ "$l2" == *"fable:"* && "$l2" != *"7d:"* ]] && seen_l2=$((seen_l2 + 1))
done
if [ "$seen_l2" -eq 0 ]; then echo "  *** FAIL  控制組：沒有任何寬度落在 L2（7d 被丟、Fable 保留）"; FAIL=$((FAIL+1))
elif [ "$bad" = 0 ]; then echo "  PASS  20..200 欄都保留 Fable（其中 $seen_l2 個寬度落在 L2）"
else FAIL=$((FAIL+1)); fi

echo "############ Codex 額度（讀 usage-refresh.sh 寫的檔） ############"
cxfile() {  # cxfile <file name> [jq mutation applied after the times are set]
  local now; now=$(date +%s)
  jq --argjson now "$now" '
    .fetchedAt = ($now - 60)
    | .windows[].resetsAt = ($now + 43200)
    | .resets.nextExpiresAt = ($now + 864000)
    | '"${2:-.}" "$DIR/fixture-codex.json" > "$USAGE_TMP/$1"
  printf '%s' "$USAGE_TMP/$1"
}
_cl2() { ( CODEX_FILE_UNDER_TEST=$1; USAGE_FILE_UNDER_TEST=${3:-}; render "${2:-$BASE}" "${4:-132}" ) | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g'; }
_ccheck() {  # _ccheck <name> <codex file> <expected substring, or !substring>...
  local name=$1 file=$2 l2 want ok=1; shift 2
  l2=$(_cl2 "$file")
  for want in "$@"; do
    if [[ "$want" == "!"* ]]; then [[ "$l2" == *"${want#!}"* ]] && ok=0
    else [[ "$l2" == *"$want"* ]] || ok=0; fi
  done
  if [ $ok = 1 ]; then echo "  PASS  $name: $l2"; else echo "  *** FAIL  $name: ${l2}（期望 $*）"; FAIL=$((FAIL+1)); fi
}

echo "### X1: 控制組與基本顯示 ###"
_ccheck "單一時窗 → codex: 4% 與倒數、重置次數" "$(cxfile base.json)" "codex: 4% ⟳1" "· 3 resets │" "7d: 41%"
_ccheck "不給檔案 → 不顯示" "$DIR/no-such-codex-file" "!codex" "7d: 41%"
_ccheck "兩個時窗 → 各自標長度" "$(cxfile two.json '.windows = [{usedPercent:12,windowMins:300,resetsAt:($now+3600)}, {usedPercent:4,windowMins:10080,resetsAt:($now+86400)}]')" "codex 5h: 12% ⟳" "codex 7d: 4% ⟳" "!codex: "
_ccheck "長度不是整小時 → 用分鐘" "$(cxfile odd.json '.windows = [{usedPercent:1,windowMins:90,resetsAt:($now+3600)}, {usedPercent:2,windowMins:10080,resetsAt:($now+86400)}]')" "codex 90m: 1%" "codex 7d: 2%"
_ccheck "1 次重置 → 單數" "$(cxfile one.json '.resets.available = 1')" "· 1 reset │"
_ccheck "沒有重置 → 不顯示次數" "$(cxfile none.json '.resets.available = 0')" "codex: 4% ⟳" "!reset"
_ccheck "用量 100% → 照實顯示" "$(cxfile full.json '.windows[0].usedPercent = 100')" "codex: 100%"
_ccheck "負的百分比 → 0" "$(cxfile neg.json '.windows[0].usedPercent = -3')" "codex: 0%"

echo "### X2: 過時與過期 ###"
_ccheck "21 分鐘前 → 標年齡" "$(cxfile stale.json '.fetchedAt -= 1200')" "· 3 resets (21m)"
_ccheck "11 分鐘前 → 不標" "$(cxfile recent.json '.fetchedAt -= 600')" "codex: 4%" "!m)"
_ccheck "抓取時間在未來 → 不顯示" "$(cxfile future.json '.fetchedAt += 600')" "!codex"
_ccheck "時窗已重置 → 該時窗不顯示" "$(cxfile reset.json '.windows[0].resetsAt = 1')" "!codex"
_ccheck "兩個時窗其一已重置 → 只留另一個（不再標長度）" "$(cxfile half.json '.windows = [{usedPercent:12,windowMins:300,resetsAt:1}, {usedPercent:4,windowMins:10080,resetsAt:($now+86400)}]')" "codex: 4%" "!codex 5h" "!codex 7d"
# Each source carries its own age: a fresh Claude cache must not hide a stale Codex one.
out=$(_cl2 "$(cxfile own-age.json '.fetchedAt -= 1500')" "$BASE" "$(usage own-age-u.json)")
if [[ "$out" == *"credits: \$0.00/\$10 │ codex: 4%"*"(26m)"* && "$out" != *"/\$10 ("* ]]; then echo "  PASS  年齡各自計算: $out"
else echo "  *** FAIL  年齡沒有各自計算: $out"; FAIL=$((FAIL+1)); fi

echo "### X3: 格式異常一律不得弄壞 statusline ###"
printf 'not json' > "$USAGE_TMP/codex-garbage.json"
for f in "$USAGE_TMP/codex-garbage.json" \
         "$(cxfile windows-string.json '.windows = "x"')" \
         "$(cxfile pct-string.json '.windows[0].usedPercent = "4"')" \
         "$(cxfile mins-zero.json '.windows[0].windowMins = 0')" \
         "$(cxfile no-fetched.json 'del(.fetchedAt)')" \
         "$(cxfile resets-string.json '.resets = "x"')" \
         "$(cxfile root-array.json '[.]')"; do
  out=$( CODEX_FILE_UNDER_TEST=$f; render "$BASE" 132 )
  n=$(printf '%s' "$out" | grep -c '')
  l2=$(printf '%s\n' "$out" | sed -n 2p | sed $'s/\x1b\\[[0-9;]*m//g')
  if [ "$n" = "4" ] && [[ "$l2" == *"7d: 41%"* ]] && ! printf '%s' "$out" | grep -q "jq error"; then
    echo "  PASS  $(basename "$f") → 4 行、原本的時窗還在: $l2"
  else
    echo "  *** FAIL  $(basename "$f") → $n 行: $l2"; FAIL=$((FAIL+1))
  fi
done
_ccheck "時窗長度 0 → 不顯示" "$(cxfile mins-zero-hidden.json '.windows[0].windowMins = 0')" "!codex" "7d: 41%"
_ccheck "resets 異常 → 時窗照常、不顯示次數" "$(cxfile resets-bad.json '.resets.available = "3"')" "codex: 4% ⟳" "!reset"

echo "### X4: 寬度契約與降級順序（Claude 用量檔＋Codex 檔都在） ###"
USAGE_FILE_UNDER_TEST=$(usage x4-usage.json '.cachedUsageUtilization.fetchedAtMs -= 1500000')
CODEX_FILE_UNDER_TEST=$(cxfile x4-codex.json '.fetchedAt -= 1500 | .windows = [{usedPercent:12,windowMins:300,resetsAt:($now+3600)}, {usedPercent:4,windowMins:10080,resetsAt:($now+86400)}]')
sweep "usage + codex 兩時窗＋年齡" "$(mut '.rate_limits.spend_limit = {used_percentage:88,resets_at:1790301600}')" 20 200
unset USAGE_FILE_UNDER_TEST CODEX_FILE_UNDER_TEST
# Codex is kept after 7d is dropped (L2) and dropped before the cost-only rung (L3).
X4_USAGE=$(usage x4b-usage.json) X4_CODEX=$(cxfile x4b-codex.json)
seen_l2=0 seen_l3=0 bad=0
for ((w = 20; w <= 200; w++)); do
  l2=$(_cl2 "$X4_CODEX" "$SEVEN_ONLY_U" "$X4_USAGE" "$w")
  case "$l2" in *"tok/s"*|*"waiting"*) echo "  *** FAIL  @ COLUMNS=$w 退回無限額畫面 → $l2"; bad=1; break ;; esac
  [[ "$l2" == *"codex:"* && "$l2" != *"7d:"* ]] && seen_l2=$((seen_l2 + 1))
  [[ "$l2" == *"fable:"* && "$l2" != *"codex"* ]] && seen_l3=$((seen_l3 + 1))
  if [[ "$l2" == *"7d:"* && "$l2" != *"codex:"* ]]; then
    echo "  *** FAIL  @ COLUMNS=$w 7d 還在、codex 卻先被丟 → $l2"; bad=1; break
  fi
done
if [ "$seen_l2" -eq 0 ] || [ "$seen_l3" -eq 0 ]; then
  echo "  *** FAIL  控制組：L2（codex 留、7d 丟）$seen_l2 個寬度、L3（codex 丟、fable 留）$seen_l3 個寬度，至少要各有一個"; FAIL=$((FAIL+1))
elif [ "$bad" = 0 ]; then echo "  PASS  降級順序正確（L2 $seen_l2 個寬度、L3 $seen_l3 個寬度）"
else FAIL=$((FAIL+1)); fi

echo "### X5: 很窄時第 2 行要乾淨地退到只剩費用，不能被硬截 ###"
# width_oracle.py flags a clamp only from budget 35 up; below that only this
# catches a missing cost-only rung, which would hard-cut "fable: 10…" instead.
bad=0
for ((w = 20; w <= 40; w++)); do
  l2=$(_cl2 "$X4_CODEX" "$SEVEN_ONLY_U" "$X4_USAGE" "$w")
  if [[ "$l2" == *"…" ]]; then echo "  *** FAIL  @ COLUMNS=$w 被硬截 → $l2"; bad=1; break; fi
done
[ "$bad" = 0 ] && echo "  PASS  20..40 欄都沒有被硬截" || FAIL=$((FAIL+1))

echo "############ 使用者真實設定 ############"
echo "### STATUSLINE_MAX_WIDTH=75 + SHORT_MODEL=1（settings.json 實際值） ###"
out=$( cd "$REPO_CWD" || exit 1; STATUSLINE_USAGE_FILE="$DIR/no-such-usage-file" STATUSLINE_CODEX_FILE="$DIR/no-such-codex-file" COLUMNS=132 STATUSLINE_MAX_WIDTH=75 STATUSLINE_SHORT_MODEL=1 bash "$SL" <<<"$BASE" )
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
