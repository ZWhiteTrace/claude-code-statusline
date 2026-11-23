#!/bin/bash
# usage-refresh.sh tests. `ps`, `claude` and `codex` are replaced by fakes put
# first on PATH, so the script runs its real code path — the process check, the
# claude invocation and the JSON-RPC exchange with `codex app-server` — against
# processes whose behaviour each case sets. Nothing reaches the network.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${USAGE_REFRESH_UNDER_TEST:-$DIR/../usage-refresh.sh}"
PASS=0 FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAKES="$WORK/bin"
mkdir -p "$FAKES"

cat > "$FAKES/ps" <<'EOF'
#!/bin/bash
cat "$FAKE_PS_FILE"
EOF

# Like the real one, a successful `claude -p /usage` rewrites the usage cache in
# ~/.claude.json; FAKE_CLAUDE_CACHE picks what it leaves there.
cat > "$FAKES/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_LOG_DIR/claude-args"
now_ms=$(( $(date +%s) * 1000 ))
id1=00000000-0000-4000-8000-000000000001
limits='[{"kind":"weekly_all","percent":40},{"kind":"weekly_scoped","percent":100}]'
cache() { printf '{"fetchedAtMs":%s,"accountUuid":"%s","utilization":{"%s":%s}}' "$1" "$id1" "$2" "$limits"; }
case "${FAKE_CLAUDE_CACHE:-ok}" in
  ok)      body="{\"oauthAccount\":{\"accountUuid\":\"$id1\"},\"cachedUsageUtilization\":$(cache "$now_ms" limits)}" ;;
  stale)   body="{\"oauthAccount\":{\"accountUuid\":\"$id1\"},\"cachedUsageUtilization\":$(cache $(( now_ms - 3600000 )) limits)}" ;;
  shape)   body="{\"oauthAccount\":{\"accountUuid\":\"$id1\"},\"cachedUsageUtilization\":$(cache "$now_ms" windows)}" ;;
  account) body="{\"oauthAccount\":{\"accountUuid\":\"00000000-0000-4000-8000-000000000002\"},\"cachedUsageUtilization\":$(cache "$now_ms" limits)}" ;;
  missing) body="{\"oauthAccount\":{\"accountUuid\":\"$id1\"}}" ;;
  garbage) body="not json" ;;
esac
printf '%s' "$body" > "$HOME/.claude.json"
exit "${FAKE_CLAUDE_EXIT:-0}"
EOF

# A stand-in for `codex app-server`: logs every method it is sent, sends a
# notification first (the client must skip it), then answers per FAKE_CODEX_MODE.
cat > "$FAKES/codex" <<'EOF'
#!/bin/bash
[ "$1" = "app-server" ] || exit 64
[ "${FAKE_CODEX_MODE:-ok}" = "close" ] && exit 0
while IFS= read -r line; do
  method=$(printf '%s' "$line" | jq -r '.method // empty')
  id=$(printf '%s' "$line" | jq -r '.id // empty')
  printf '%s\n' "$method" >> "$FAKE_LOG_DIR/codex-methods"
  case "$method" in
    initialize)
      printf '%s\n' '{"method":"account/updated","params":{}}'
      printf '{"id":%s,"result":{"userAgent":"fake"}}\n' "$id" ;;
    account/rateLimits/read)
      case "${FAKE_CODEX_MODE:-ok}" in
        hang)  sleep 30 ;;
        error) printf '{"id":%s,"error":{"code":-32000,"message":"not signed in"}}\n' "$id" ;;
        empty) printf '{"id":%s,"result":{"rateLimits":{"primary":null,"secondary":null}}}\n' "$id" ;;
        *)     jq -c --argjson id "$id" '{id: $id, result: .}' "$FAKE_CODEX_RESULT" ;;
      esac ;;
  esac
done
EOF
# agy must never be called: the status line only reads the file agy's own status
# line writes (Antigravity's terms forbid third-party software reaching the
# service through its sign-in). This stand-in records any call; section 8 checks.
cat > "$FAKES/agy" <<'EOF'
#!/bin/bash
touch "$FAKE_LOG_DIR/agy-called"
EOF
chmod +x "$FAKES/ps" "$FAKES/claude" "$FAKES/codex" "$FAKES/agy"

NOW=$(date +%s)
RESULT="$WORK/result.json"
jq -n --argjson now "$NOW" '{
  ordinaryUsageAllowed: true,
  rateLimits: {
    limitId: "codex", planType: "plus",
    primary:   {usedPercent: 12, windowDurationMins: 300,   resetsAt: ($now + 3600)},
    secondary: {usedPercent: 4,  windowDurationMins: 10080, resetsAt: ($now + 86400)},
    credits: {hasCredits: false, unlimited: false, balance: "0"}
  },
  rateLimitResetCredits: {
    availableCount: 3,
    credits: [
      {id: "RateLimitResetCredit_used", status: "used", expiresAt: ($now + 100)},
      {id: "RateLimitResetCredit_aaaa", status: "available", expiresAt: ($now + 9000)},
      {id: "RateLimitResetCredit_bbbb", status: "available", expiresAt: ($now + 5000)}
    ]
  },
  accountId: "11111111-2222-4333-8444-555555555555"
}' > "$RESULT"

INTERACTIVE='ttys001 claude --dangerously-skip-permissions'
BACKGROUND_ONLY=$'??       claude -p /usage\nttys002  /bin/zsh\nttys003  vim claude'

# run <case dir> [VAR=value ...] → exit code in $RC, stdout in ${OUT}
run() {
  local case_dir=$1; shift
  mkdir -p "$case_dir/logs" "$case_dir/home"
  [ -f "$case_dir/ps" ] || printf '%s\n' "$INTERACTIVE" > "$case_dir/ps"
  OUT=$(env -i PATH="$FAKES:/usr/bin:/bin" HOME="$case_dir/home" \
        FAKE_PS_FILE="$case_dir/ps" FAKE_LOG_DIR="$case_dir/logs" FAKE_CODEX_RESULT="$RESULT" \
        STATUSLINE_CODEX_FILE="$case_dir/cache/codex.json" STATUSLINE_REFRESH_STATUS_FILE="$case_dir/cache/status.json" \
        USAGE_REFRESH_TIMEOUT=3 \
        "$@" /bin/bash "$SCRIPT" 2>&1)
  RC=$?
}
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  *** FAIL  $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 — ${3:-}"; fi; }

echo "### 1. 正常：Claude 與 Codex 都更新 ###"
C="$WORK/happy"; run "$C"
check "exit 0、不輸出任何東西" '[ "$RC" = 0 ] && [ -z "$OUT" ]' "rc=$RC out=$OUT"
args=$(tr '\n' ' ' < "$C/logs/claude-args" 2>/dev/null)
check "claude 以 -p /usage 執行，關 hooks、不留 session、不載 MCP" \
  '[[ "$args" == "-p /usage "* && "$args" == *"--no-session-persistence"* && "$args" == *"disableAllHooks"* && "$args" == *"--strict-mcp-config"* ]]' "$args"
check "Codex 只收到 initialize → initialized → account/rateLimits/read" \
  '[ "$(tr "\n" " " < "$C/logs/codex-methods")" = "initialize initialized account/rateLimits/read " ]' "$(tr '\n' ' ' < "$C/logs/codex-methods")"
F="$C/cache/codex.json"
check "寫出兩個時窗（順序 primary、secondary）" \
  '[ "$(jq -c "[.windows[] | [.usedPercent, .windowMins, .resetsAt - $NOW]]" "$F")" = "[[12,300,3600],[4,10080,86400]]" ]' "$(cat "$F" 2>/dev/null)"
check "重置次數取 availableCount（不是列出的張數）、最早到期只算可用的" \
  '[ "$(jq -c "[.resets.available, .resets.nextExpiresAt - $NOW, .planType]" "$F")" = "[3,5000,\"plus\"]" ]' "$(jq -c .resets "$F" 2>/dev/null)"
check "不存帳號 id、重置券 id" '! grep -qE "11111111-2222|RateLimitResetCredit_|accountId" "$F"'
check "抓取時間是現在" '[ $(( $(jq .fetchedAt "$F") - NOW )) -ge 0 ] && [ $(( $(jq .fetchedAt "$F") - NOW )) -le 30 ]'
check "檔案權限 600" '[ "$(stat -f %Lp "$F")" = "600" ]' "$(stat -f %Lp "$F")"
check "沒有殘留暫存檔" '[ "$(find "$C/cache" -name ".codex-rate-limits.*" -o -name "status.json.*" | wc -l | tr -d " ")" = 0 ]'
S="$C/cache/status.json"
check "狀態檔：剛寫、沒有問題" '[ "$(jq -c ".problems" "$S")" = "[]" ] && [ $(( NOW - $(jq .checkedAt "$S") )) -le 30 ]' "$(cat "$S" 2>/dev/null)"

echo "### 2. 沒有互動 session → 什麼都不做 ###"
C="$WORK/idle"; mkdir -p "$C"; printf '%s\n' "$BACKGROUND_ONLY" > "$C/ps"; run "$C"
check "exit 0、claude 與 codex 都沒被叫、不寫狀態檔" '[ "$RC" = 0 ] && [ ! -e "$C/logs/claude-args" ] && [ ! -e "$C/logs/codex-methods" ] && [ ! -e "$C/cache/codex.json" ] && [ ! -e "$C/cache/status.json" ]' "rc=$RC"

echo "### 3. Codex 回錯誤 / 沒有可用時窗 / 直接關閉 / 卡住 → 保留舊檔、exit 1、留一行 log ###"
for mode in error empty close hang; do
  C="$WORK/codex-$mode"; mkdir -p "$C/cache"; printf '{"old":true}' > "$C/cache/codex.json"
  started=$(date +%s); run "$C" FAKE_CODEX_MODE="$mode"; took=$(( $(date +%s) - started ))
  check "${mode}：exit 1、舊檔原封不動、log 一行（${took}s）" \
    '[ "$RC" = 1 ] && [ "$(cat "$C/cache/codex.json")" = "{\"old\":true}" ] && [[ "$OUT" == *"codex exit=1"* ]] && [ "$(printf "%s\n" "$OUT" | grep -c "")" = 1 ]' "rc=$RC out=$OUT"
  check "${mode}：在時限內結束" '[ "$took" -le 10 ]' "${took}s"
  check "${mode}：狀態檔只記下 codex 的問題" '[ "$(jq -r ".problems | length" "$C/cache/status.json")" = 1 ] && jq -r ".problems[0]" "$C/cache/status.json" | grep -q "^codex: exit=1"' "$(cat "$C/cache/status.json" 2>/dev/null)"
done

C="$WORK/codex-error-reason"; mkdir -p "$C/cache"; run "$C" FAKE_CODEX_MODE=error
check "錯誤回應：log 帶出伺服器說的原因" '[[ "$OUT" == *"not signed in"* ]]' "$OUT"

echo "### 4. claude 失敗不影響 Codex ###"
C="$WORK/claude-fail"; run "$C" FAKE_CLAUDE_EXIT=3
check "exit 1、log 寫 claude exit=3、Codex 照樣更新" '[ "$RC" = 1 ] && [[ "$OUT" == *"claude exit=3"* ]] && [ -s "$C/cache/codex.json" ]' "rc=$RC out=$OUT"
check "狀態檔記下 claude 的問題" 'jq -r ".problems[0]" "$C/cache/status.json" | grep -q "^claude: exit=3"' "$(cat "$C/cache/status.json" 2>/dev/null)"

echo "### 4b. claude 跑完了，但用量資料不對 → 記下原因（格式一變、靜默消失就靠這條抓） ###"
for cache in stale shape account missing garbage; do
  case $cache in
    stale)   want="not refreshed" ;;
    shape)   want="shape not recognised" ;;
    account) want="account does not match" ;;
    missing) want="no cachedUsageUtilization" ;;
    garbage) want="unreadable" ;;
  esac
  C="$WORK/cache-$cache"; run "$C" FAKE_CLAUDE_CACHE="$cache"
  check "${cache}：exit 1、log 與狀態檔都寫「${want}」、Codex 照樣更新" \
    '[ "$RC" = 1 ] && [[ "$OUT" == *"claude usage cache: ${want}"* ]] && jq -r ".problems[0]" "$C/cache/status.json" | grep -q "^claude: usage cache: ${want}" && [ -s "$C/cache/codex.json" ]' \
    "rc=$RC out=$OUT status=$(cat "$C/cache/status.json" 2>/dev/null)"
done

echo "### 5. 沒有 codex → 只更新 Claude ###"
C="$WORK/no-codex"; NOCODEX="$WORK/bin-no-codex"; mkdir -p "$NOCODEX"; cp "$FAKES/ps" "$FAKES/claude" "$NOCODEX/"
mkdir -p "$C/logs" "$C/home"; printf '%s\n' "$INTERACTIVE" > "$C/ps"
OUT=$(env -i PATH="$NOCODEX:/usr/bin:/bin" HOME="$C/home" FAKE_PS_FILE="$C/ps" FAKE_LOG_DIR="$C/logs" \
      STATUSLINE_CODEX_FILE="$C/cache/codex.json" /bin/bash "$SCRIPT" 2>&1); RC=$?
check "exit 0、claude 有跑、沒有 Codex 檔" '[ "$RC" = 0 ] && [ -e "$C/logs/claude-args" ] && [ ! -e "$C/cache/codex.json" ]' "rc=$RC out=$OUT"

echo "### 6. availableCount 缺 → 改數 status=available 的張數 ###"
NOCOUNT="$WORK/result-nocount.json"; jq 'del(.rateLimitResetCredits.availableCount)' "$RESULT" > "$NOCOUNT"
C="$WORK/no-count"; run "$C" FAKE_CODEX_RESULT="$NOCOUNT"
check "available = 2" '[ "$(jq .resets.available "$C/cache/codex.json")" = 2 ]' "$(jq -c .resets "$C/cache/codex.json" 2>/dev/null)"

echo "### 7. 只送允許的請求：對照組 ###"
# The allow-list must reject a method outside it before anything is written. Feed
# the embedded program a list that contains the consume call and check it refuses.
CODEX_PY=$(awk "/^read -r -d '' CODEX_PY <<'PY'/{on=1; next} /^PY\$/{on=0} on" "$SCRIPT")
probe=$(printf '%s' "$CODEX_PY" | sed 's#send({"id": 2, "method": "account/rateLimits/read"})#send({"id": 2, "method": "account/rateLimitResetCredit/consume"})#')
if [ "$probe" = "$CODEX_PY" ]; then
  bad "對照組沒有真的改到送出的方法（測不到東西）"
else
  C="$WORK/consume"; mkdir -p "$C/logs"
  out=$(env -i PATH="$FAKES:/usr/bin:/bin" FAKE_LOG_DIR="$C/logs" FAKE_CODEX_RESULT="$RESULT" \
        python3 -I -c "$probe" "$FAKES/codex" "$C/out.json" 3 2>&1); rc=$?
  check "consume 被拒絕、沒有送出、沒有寫檔" \
    '[ "$rc" != 0 ] && [[ "$out" == *"refusing to send account/rateLimitResetCredit/consume"* ]] && ! grep -q consume "$C/logs/codex-methods" && [ ! -e "$C/out.json" ]' "rc=$rc out=$out"
fi

echo "### 8. 從不呼叫 agy（agy 的額度只讀 agy 自己寫的檔，不刷新） ###"
C="$WORK/agy-control"; mkdir -p "$C"
env -i PATH="$FAKES:/usr/bin:/bin" FAKE_LOG_DIR="$C" /bin/bash -c 'agy --version'
check "對照組：假的 agy 在 PATH 上找得到、被叫會留記號" '[ -e "$C/agy-called" ]'
called=$(find "$WORK" -name agy-called -not -path "$C/*")
check "以上所有情境都沒有呼叫 agy" '[ -z "$called" ]' "$called"

echo "================================"
echo "PASS=$PASS  FAIL=$FAIL"
exit "$FAIL"
