#!/bin/bash
# usage-refresh.sh — keep the usage figures on the status line's second row fresh.
# Run it on a schedule (launchd / cron, e.g. every 15 minutes). It calls no model
# and spends no quota.
#
# 1. Claude: `claude -p /usage` makes Claude Code refetch its usage and rewrite
#    cachedUsageUtilization in ~/.claude.json, which the status line reads for the
#    per-model weekly limits and usage credits. Claude Code refetches that cache
#    only when something asks for usage, never on a timer. Measured on 2.1.328:
#    num_turns 0 and total_cost_usd 0; without disableAllHooks every run also
#    fires the SessionStart hooks; --bare cannot be used because it turns off
#    OAuth sign-in; --no-session-persistence leaves no session file behind.
# 2. Codex: `codex app-server` answers account/rateLimits/read — usage, reset
#    times and the free resets on the account — without starting a thread. The
#    answer is reduced to the fields the status line shows (no account or
#    reset-credit ids) and written atomically to $STATUSLINE_CODEX_FILE.
#    Only the read is ever sent: account/rateLimitResetCredit/consume would spend
#    a reset, and the request list is checked against an allow-list before
#    anything is written to the server.
#
# Skips everything when no interactive Claude Code session (a `claude` process
# with a terminal) is running — nobody is looking at a status line. A scheduled
# run has no terminal, so it never counts itself.
#
# After the Claude refresh the cache is checked: refreshed just now, for the
# signed-in account, and still in the shape the status line reads. A change of
# shape after a Claude Code update would otherwise make the per-model limits
# vanish without a trace — indistinguishable from a week with no such limit.
#
# Each run records its outcome in $STATUSLINE_REFRESH_STATUS_FILE (an empty
# problem list when all went well); the status line shows `usage✗` while the
# last run reported a problem. Problems are also printed, one line each, so a
# scheduler's log stays empty while it works. A figure that has stopped updating
# also grows an age tag on the status line past 20 minutes.
# The Codex part needs python3 and is skipped without it; the checks need jq.
set -u

CODEX_FILE="${STATUSLINE_CODEX_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/codex-rate-limits.json}"
USAGE_FILE="${STATUSLINE_USAGE_FILE:-$HOME/.claude.json}"
STATUS_FILE="${STATUSLINE_REFRESH_STATUS_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/refresh-status.json}"
TIMEOUT="${USAGE_REFRESH_TIMEOUT:-60}"  # seconds per call; a hung call must not outlive the schedule

if ! ps -ax -o tty=,args= | awk '$1 != "??" && $2 == "claude" { found = 1 } END { exit !found }'; then
  exit 0
fi

stamp() { date '+%F %T'; }
status=0
problems=()
fail() {  # fail <source> <message>: print it and keep it for the status file
  local message
  message=$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300)
  printf '%s %s %s\n' "$(stamp)" "$1" "$message"
  problems+=("$1: $message")
  status=1
}

claude_bin=$(command -v claude || true)
[ -z "$claude_bin" ] && [ -x "$HOME/.local/bin/claude" ] && claude_bin="$HOME/.local/bin/claude"
if [ -n "$claude_bin" ]; then
  errors=$( (cd "$HOME" && perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
    env -u CLAUDECODE "$claude_bin" -p "/usage" \
      --no-session-persistence \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --settings '{"disableAllHooks":true}') 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail claude "exit=$rc $errors"
  else
    # 300 s, not "this second": Claude Code skips the write when the cache was
    # written less than a minute ago, so a refresh right after /usage is fine.
    problem=$(jq -r --argjson now "$(date +%s)" '
      (.cachedUsageUtilization // null) as $c
      | (.oauthAccount | if type == "object" then .accountUuid else null end) as $account
      | if ($c | type) != "object" then "no cachedUsageUtilization"
        elif ($c.fetchedAtMs | type) != "number" then "no fetchedAtMs"
        elif ($now - $c.fetchedAtMs / 1000) > 300 then "not refreshed (\(($now - $c.fetchedAtMs / 1000) | floor)s old)"
        elif ($account | type) != "string" or $c.accountUuid != $account then "account does not match the signed-in one"
        elif ($c.utilization | type) != "object" or ($c.utilization.limits | type) != "array"
             or ([$c.utilization.limits[] | select(type == "object" and (.kind | type) == "string"
                                                   and (.percent | type) == "number")] | length) == 0
          then "shape not recognised (no limits[] entry with kind and percent)"
        else empty end' "$USAGE_FILE" 2>&1) || problem="unreadable ($problem)"
    [ -n "$problem" ] && fail claude "usage cache: $problem"
  fi
fi

# Kept out of $(...): bash 3.2 mis-parses a here-document inside a command
# substitution once the body holds parentheses.
read -r -d '' CODEX_PY <<'PY'
import json, os, queue, subprocess, sys, tempfile, threading, time

codex, out_path, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])
ALLOWED = {"initialize", "initialized", "account/rateLimits/read"}
deadline = time.monotonic() + timeout
proc = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, bufsize=1)

def send(message):
    if message["method"] not in ALLOWED:
        raise SystemExit("refusing to send " + message["method"])
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()

# A reader thread, not select() + readline(): readline buffers ahead, so a reply
# that arrives in the same chunk as a notification would sit in Python's buffer
# while select() waits on an empty pipe until the deadline.
lines = queue.Queue()

def pump():
    for raw in proc.stdout:
        lines.put(raw)
    lines.put(None)

threading.Thread(target=pump, daemon=True).start()

def reply_to(request_id):
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit("codex app-server did not answer in time")
        try:
            line = lines.get(timeout=remaining)
        except queue.Empty:
            continue
        if line is None:
            raise SystemExit("codex app-server closed its output")
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if isinstance(message, dict) and message.get("id") == request_id:
            return message

try:
    send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "usage-refresh", "version": "1"}}})
    reply_to(1)
    send({"method": "initialized"})
    send({"id": 2, "method": "account/rateLimits/read"})
    reply = reply_to(2)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

result = reply.get("result")
if not isinstance(result, dict):
    raise SystemExit("account/rateLimits/read failed: " + json.dumps(reply.get("error"))[:200])
limits = result.get("rateLimits") if isinstance(result.get("rateLimits"), dict) else {}

def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None

windows = []
for key in ("primary", "secondary"):
    window = limits.get(key)
    if not isinstance(window, dict):
        continue
    fields = {"usedPercent": number(window.get("usedPercent")),
              "windowMins": number(window.get("windowDurationMins")),
              "resetsAt": number(window.get("resetsAt"))}
    if None not in fields.values():
        windows.append(fields)
if not windows:
    raise SystemExit("account/rateLimits/read returned no usable window")

credits = result.get("rateLimitResetCredits")
credits = credits if isinstance(credits, dict) else {}
available = [credit for credit in (credits.get("credits") or [])
             if isinstance(credit, dict) and credit.get("status") == "available"]
count = number(credits.get("availableCount"))
expiries = [number(credit.get("expiresAt")) for credit in available if number(credit.get("expiresAt")) is not None]
plan = limits.get("planType")
document = {
    "fetchedAt": int(time.time()),
    "planType": plan if isinstance(plan, str) else None,
    "windows": windows,
    "resets": {"available": int(count) if count is not None else len(available),
               "nextExpiresAt": int(min(expiries)) if expiries else None},
}

directory = os.path.dirname(out_path) or "."
os.makedirs(directory, exist_ok=True)
handle, temp_path = tempfile.mkstemp(dir=directory, prefix=".codex-rate-limits.", suffix=".tmp")
try:
    with os.fdopen(handle, "w") as temp_file:
        json.dump(document, temp_file)
    os.replace(temp_path, out_path)
except BaseException:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    raise
PY

codex_bin=$(command -v codex || true)
if [ -n "$codex_bin" ] && command -v python3 >/dev/null 2>&1; then
  errors=$(python3 -I -c "$CODEX_PY" "$codex_bin" "$CODEX_FILE" "$TIMEOUT" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail codex "exit=$rc $errors"
  fi
fi

# ${problems[@]+...}: bash 3.2 treats an empty array as unbound under set -u.
mkdir -p "$(dirname "$STATUS_FILE")" &&
  status_tmp=$(mktemp "$STATUS_FILE.XXXXXX") &&
  jq -n --argjson at "$(date +%s)" '{checkedAt: $at, problems: $ARGS.positional}' \
     --args ${problems[@]+"${problems[@]}"} > "$status_tmp" &&
  mv "$status_tmp" "$STATUS_FILE" ||
  { printf '%s status file not written: %s\n' "$(stamp)" "$STATUS_FILE"; status=1; }

exit "$status"
