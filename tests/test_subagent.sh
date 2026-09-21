#!/bin/bash
# Regression suite for subagent-statusline.sh, one case per finding from the
# adversarial review. Each case states what the old version did wrong.
set -u
S="${SUBAGENT_SL:-$(cd "$(dirname "$0")" && pwd)/../subagent-statusline.sh}"
PASS=0; FAIL=0

# strip ANSI for readability
plain() { sed $'s/\x1b\\[[0-9;]*m//g'; }

# run, and report: row count, whether stdout is valid JSONL, any stderr
run() { printf '%s' "$1" | bash "$S" 2>/tmp/subagent-test-stderr; }

expect_rows() {
  local name=$1 payload=$2 want=$3
  local out n bad_json stderr
  out=$(run "$payload")
  n=$(printf '%s' "$out" | grep -c . || true)
  stderr=$(cat /tmp/subagent-test-stderr)
  bad_json=""
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | jq -e 'has("id") and has("content")' >/dev/null 2>&1 || bad_json="INVALID-JSON"
  fi
  if [ "$n" = "$want" ] && [ -z "$bad_json" ] && [ -z "$stderr" ]; then
    printf '  PASS  %-46s rows=%s\n' "$name" "$n"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-46s rows=%s (want %s) %s\n' "$name" "$n" "$want" "$bad_json"; FAIL=$((FAIL+1))
    [ -n "$stderr" ] && echo "        stderr: $(head -2 <<<"$stderr")"
  fi
}

T='{"id":"ok1","status":"running","description":"first","model":"claude-opus-5","tokenCount":100,"contextWindowSize":200000,"startTime":1789970000000}'
U='{"id":"ok2","status":"running","description":"third","model":"claude-sonnet-5","tokenCount":200,"contextWindowSize":200000,"startTime":1789970000000}'

echo "=== S2: 非整數進算術，不得吃掉自己與後續 row ==="
expect_rows "float tokenCount (中間那列)" \
  "{\"columns\":126,\"tasks\":[$T,{\"id\":\"bad\",\"status\":\"running\",\"description\":\"x\",\"tokenCount\":1.5},$U]}" 3
expect_rows "columns = 126.0 (整盤清空過)" \
  "{\"columns\":126.0,\"tasks\":[$T,$U]}" 2
expect_rows "columns = \"12abc\"" \
  "{\"columns\":\"12abc\",\"tasks\":[$T,$U]}" 2
expect_rows "columns = -5" \
  "{\"columns\":-5,\"tasks\":[$T,$U]}" 2

echo "=== S3: 除以零 ==="
expect_rows "contextWindowSize = \"unknown\"" \
  '{"columns":126,"tasks":[{"id":"z","status":"running","description":"d","tokenCount":1000,"contextWindowSize":"unknown"}]}' 1
expect_rows "contextWindowSize = 0.0" \
  '{"columns":126,"tasks":[{"id":"z","status":"running","description":"d","tokenCount":1000,"contextWindowSize":0.0}]}' 1
expect_rows "tokenCount 為字串" \
  '{"columns":126,"tasks":[{"id":"z","status":"running","description":"d","tokenCount":"lots","contextWindowSize":200000}]}' 1

echo "=== S6: 控制字元注入不得造出假 row / 錯位 ==="
expect_rows "title 含換行 (曾吐出假 id)" \
  '{"columns":126,"tasks":[{"id":"nl","status":"running","description":"Explo\nrer","model":"claude-opus-5","tokenCount":100,"contextWindowSize":200000}]}' 1
expect_rows "title 含 0x1f (曾整排左移)" \
  '{"columns":126,"tasks":[{"id":"us","status":"running","description":"Ex\u001fhello","model":"claude-opus-5","effort":"high","tokenCount":100,"contextWindowSize":200000}]}' 1
expect_rows "id 含換行" \
  '{"columns":126,"tasks":[{"id":"a\nb","status":"running","description":"d"}]}' 1
expect_rows "model 含 0x1f" \
  '{"columns":126,"tasks":[{"id":"m","status":"running","description":"d","model":"claude-opus-5\u001fx","tokenCount":5,"contextWindowSize":200000}]}' 1

echo "=== S7: description 型別錯誤不得中斷 jq ==="
expect_rows "description 是數字 (曾砍掉後續 row)" \
  "{\"columns\":126,\"tasks\":[$T,{\"id\":\"bt\",\"status\":\"running\",\"description\":12345},$U]}" 3
expect_rows "description 是物件" \
  "{\"columns\":126,\"tasks\":[$T,{\"id\":\"bo\",\"status\":\"running\",\"description\":{\"a\":1}},$U]}" 3
expect_rows "description 是 null" \
  "{\"columns\":126,\"tasks\":[$T,{\"id\":\"bn\",\"status\":\"running\",\"description\":null},$U]}" 3

echo "=== S1: 真實 payload 沒有 name，身分必須仍看得見 ==="
out=$(run '{"columns":126,"tasks":[{"id":"a4840b","type":"local_agent","status":"running","description":"Review the width math","label":"Measuring CJK overflow","startTime":1789976016431,"model":"claude-opus-5[1m]","contextWindowSize":1000000,"tokenCount":82488,"tokenSamples":[0,81837,82488],"cwd":"/home/dev/project"}]}')
content=$(jq -r '.content' <<<"$out" | plain)
echo "  實際輸出: $content"
if [[ "$content" == *"Review the width math"* ]] && [[ "$content" == *"Opus"* ]] && [[ "$content" == *"1M"* ]]; then
  echo "  PASS  標題/模型/1M 都在"; PASS=$((PASS+1))
else
  echo "  FAIL  身分或模型資訊缺失"; FAIL=$((FAIL+1))
fi

echo "=== S5: ESC 注入必須被清掉 ==="
out=$(run '{"columns":126,"tasks":[{"id":"pwn","status":"running","description":"pwn\u001b[2J\u001b[H\u001b[5;41;97mBANNER\u001b[0m"}]}')
# count ESC bytes in the emitted content after JSON-decoding
esc=$(jq -r '.content' <<<"$out" | od -An -c | grep -o '033' | wc -l | tr -d ' ')
# our own colouring uses ESC, so compare against a clean control row
clean=$(run '{"columns":126,"tasks":[{"id":"pwn","status":"running","description":"pwn BANNER"}]}')
esc_clean=$(jq -r '.content' <<<"$clean" | od -An -c | grep -o '033' | wc -l | tr -d ' ')
if [ "$esc" = "$esc_clean" ]; then
  echo "  PASS  注入的 ESC 已清除 (ESC 數 $esc == 乾淨對照 $esc_clean)"; PASS=$((PASS+1))
else
  echo "  FAIL  注入的 ESC 殘留 (ESC 數 $esc vs 乾淨對照 $esc_clean)"; FAIL=$((FAIL+1))
fi

echo "=== S4: CJK 寬度 (曾溢出 95 欄) ==="
CJK="這是一段很長的繁體中文描述文字用來測試顯示寬度是否被正確計算因為每個中文字佔兩欄而不是一欄"
for c in 126 80 60 40; do
  out=$(run "{\"columns\":$c,\"tasks\":[{\"id\":\"cjk\",\"status\":\"running\",\"description\":\"$CJK\",\"model\":\"claude-opus-5\",\"tokenCount\":1000,\"contextWindowSize\":200000}]}")
  w=$(jq -r '.content' <<<"$out" | python3 -c '
import sys,re,unicodedata
s=re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read().rstrip("\n"))
print(sum(2 if unicodedata.east_asian_width(ch) in ("W","F") else 1 for ch in s))')
  if [ "$w" -le "$c" ]; then
    printf '  PASS  columns=%-4s 實際顯示寬度=%s\n' "$c" "$w"; PASS=$((PASS+1))
  else
    printf '  FAIL  columns=%-4s 實際顯示寬度=%s (溢出 %s)\n' "$c" "$w" $((w-c)); FAIL=$((FAIL+1))
  fi
done

echo "=== S8: 過長前綴也要截斷 ==="
out=$(run '{"columns":30,"tasks":[{"id":"long","status":"running","description":"very-long-agent-name-here-that-keeps-going","model":"claude-opus-5","effort":"xhigh","tokenCount":178000,"contextWindowSize":200000,"startTime":1789970000000}]}')
w=$(jq -r '.content' <<<"$out" | plain | awk '{print length($0)}')
if [ "$w" -le 30 ]; then echo "  PASS  columns=30 實際=$w"; PASS=$((PASS+1)); else echo "  FAIL  columns=30 實際=$w"; FAIL=$((FAIL+1)); fi

echo "=== 欄位在/缺 窮舉 (2^6 = 64 組) ==="
bad=0
for mask in $(seq 0 63); do
  t='{"id":"x","status":"running"'
  (( mask & 1  )) && t="$t,\"description\":\"d\""
  (( mask & 2  )) && t="$t,\"model\":\"claude-opus-5\""
  (( mask & 4  )) && t="$t,\"effort\":\"high\""
  (( mask & 8  )) && t="$t,\"tokenCount\":1000"
  (( mask & 16 )) && t="$t,\"contextWindowSize\":200000"
  (( mask & 32 )) && t="$t,\"startTime\":1789970000000"
  t="$t}"
  o=$(run "{\"columns\":126,\"tasks\":[$t]}")
  n=$(printf '%s' "$o" | grep -c . || true)
  e=$(cat /tmp/subagent-test-stderr)
  { [ "$n" = "1" ] && [ -z "$e" ]; } || { bad=$((bad+1)); echo "    mask=$mask rows=$n stderr=$(head -1 <<<"$e")"; }
done
if [ "$bad" -eq 0 ]; then echo "  PASS  64/64 組合全通過"; PASS=$((PASS+1)); else echo "  FAIL  $bad/64 組合失敗"; FAIL=$((FAIL+1)); fi

echo "=== 邊界 ==="
expect_rows "空 tasks" '{"columns":80,"tasks":[]}' 0
expect_rows "空物件" '{}' 0
expect_rows "非 JSON" 'not json at all' 0
expect_rows "tasks 不是陣列" '{"columns":80,"tasks":"nope"}' 0
expect_rows "task 缺 id" '{"columns":80,"tasks":[{"status":"running","description":"d"}]}' 0

echo "=== S9: 效能 ==="
big='{"columns":126,"tasks":['
for i in $(seq 1 10); do
  [ "$i" -gt 1 ] && big="$big,"
  big="$big{\"id\":\"t$i\",\"status\":\"running\",\"description\":\"task number $i doing something\",\"model\":\"claude-sonnet-5\",\"tokenCount\":$((i*5000)),\"contextWindowSize\":200000,\"startTime\":1789970000000}"
done
big="$big]}"
st=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
for i in $(seq 1 10); do run "$big" >/dev/null; done
en=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
echo "  10 列 × 10 次 = $(( (en-st)/10000000 )) ms/次"

echo "================================"
echo "PASS=$PASS  FAIL=$FAIL"
exit $FAIL
