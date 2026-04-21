# claude-code-statusline

Fast, informative statusline for [Claude Code](https://docs.claude.com/en/docs/claude-code) — **~20x faster than common implementations**, with graceful fallback and built-in debug mode.

```
[Opus 4.6 (1M context)] my-project:main │ Ctx: 5% ░░░░░░░░░░/1M
5h: 44% ⟳2h4m │ 7d: 31% ⟳5d10h │ $0.20
in:343 out:18 │ Cache: 36% hit (r:17.5K w:30.7K) │ API 12%
Session: 30s │ 1M │ v2.1.104
```

Adapts automatically for cloud (Claude API) and local (Ollama) modes.

---

## Why this exists

Most Claude Code statusline scripts I've seen follow the same pattern:

```bash
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
VERSION=$(echo "$input" | jq -r '.version // empty')
AGENT=$(echo "$input" | jq -r '.agent.name // empty')
# ...and so on, 20+ times
```

Each call spawns a new `jq` process. On a busy system (multiple CC sessions, concurrent builds, high load average) the cumulative 400ms–1s latency exceeds the Claude Code statusline timeout, and the statusline renders **partially or not at all**.

This implementation makes **one** `jq` call using `@sh` to emit shell assignments, then `eval` them in-place. Execution time drops from ~500ms to ~25ms.

---

## Benchmark

| | Common pattern (20+ jq calls) | This statusline (1 jq call) |
|---|---|---|
| `jq` process count | 20–25 | **1** |
| Execution time | 400ms–1s | **~25ms** |
| Timeout risk under load | High | Negligible |
| Lines of extraction code | 25+ | 26 (one block) |

Benchmarked on macOS 15 (Darwin 24.5.0), bash 3.2, jq 1.7.

---

## Features

- **Single-pass JSON parsing** via `jq @sh` + `eval` — no repeated process spawn
- **4-line layout** with semantic grouping (identity / rate limits / usage / session)
- **Responsive across all 4 lines** — each line independently degrades through multiple levels to fit the actual pane width. Split a tab into 4 panes and the statusline compresses instead of wrapping or getting truncated
- **Robust width detection** — `.terminal.width` from JSON (if Claude Code provides it) → `stty size </dev/tty` (reliable fallback in non-TTY subprocess) → `tput cols` → `$COLUMNS` → 80. Works when Claude Code omits terminal width and `tput` returns its non-TTY default of 80
- **Chrome padding aware** — subtracts Claude Code's left+right UI padding (~5 cols) from the budget so terminal-side truncation (`C…`) doesn't happen
- **Auto-adapts** for cloud Claude (shows 5h / 7d rate limits) vs local Ollama (shows inference tok/s)
- **Git stats cached** to `/tmp` with 30-second TTL and lockfile-based concurrency control — works with 10+ simultaneous Claude Code sessions
- **Graceful fallback** — if `jq` parsing fails, prints a minimal error line instead of breaking the UI
- **Debug mode** — set `STATUSLINE_DEBUG=1` to dump jq output to stderr and append per-refresh width diagnostics to `/tmp/statusline-diag.log`
- **No dependencies** beyond `jq`, `bc`, `git` (standard on macOS/Linux)

---

## Example output (annotated)

```
[Opus 4.6 (1M context)] my-project:main │ Ctx: 5% ░░░░░░░░░░/1M
│  Model name            │  Repo:Branch       │ Context window usage + bar + total size

5h: 44% ⟳2h4m │ 7d: 31% ⟳5d10h │ $0.20
│ 5-hour rate limit + time until reset │ 7-day rate limit + time until reset │ Session cost

in:343 out:18 │ Cache: 36% hit (r:17.5K w:30.7K) │ API 12%
│ Total in/out tokens  │ Cache hit rate (reads / writes) │ % of session spent on API calls

Session: 30s │ 1M │ v2.1.104
│ Session duration │ Git: 1 Modified │ Claude Code version
```

Conditional fields appear only when relevant:
- `+10/-3` lines changed (when you've edited files this session)
- `2M 3A` git stats (when in a git repo with modified/untracked files)
- `🌿worktree:branch` (when in a [git worktree](https://git-scm.com/docs/git-worktree))
- `agent-name` (when a sub-agent is running via Task tool)

---

## Installation

### 1. Download

```bash
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/ZWhiteTrace/claude-code-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

### 2. Enable in Claude Code settings

Edit `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "refreshInterval": 30
  }
}
```

### 3. Restart Claude Code

Open a new session. The statusline will appear at the bottom of the terminal.

---

## Configuration

### Debug mode

If the statusline looks wrong, set `STATUSLINE_DEBUG=1` (in `settings.json` under `env`, then restart the session). Two outputs are produced:

- **stderr**: the expanded jq variable assignments (same as before)
- **`/tmp/statusline-diag.log`**: one line per refresh with width detection state — `TERM_W` (from JSON), `stty_cols`, `tput_cols`, `COLUMNS`, the chosen `ACTUAL`, the final `COLS`, and `BUDGET`. Invaluable for diagnosing why lines aren't degrading as expected.

```
15:06:31 TERM_W=0 stty_cols=39 tput_cols=80 COLUMNS=unset ACTUAL=39 MAX=75 PAD=5 -> COLS=39 BUDGET=34
```

The log appends forever while `STATUSLINE_DEBUG=1` is set — unset it when done.

### Short model name

Set `STATUSLINE_SHORT_MODEL=1` to strip the word `context` from the model display name. For example, `Opus 4.6 (1M context)` becomes `Opus 4.6 (1M)` — the context window size stays visible but the label is shorter. Unset (default) keeps the full model name.

### Width detection and degradation

The statusline computes a budget for each line as `COLS - CHROME_PAD`, where:

- `COLS` = first usable value from `.terminal.width` → `stty size </dev/tty` → `tput cols` → `$COLUMNS` → `80`, optionally capped by `STATUSLINE_MAX_WIDTH`
- `CHROME_PAD` = subtracted safety margin (default 5) for Claude Code's UI padding

Each line runs a small loop that tries progressively shorter variants until one fits the budget.

**`STATUSLINE_MAX_WIDTH`** (default: unset) — soft cap. When the actual terminal is wider than this value, `COLS` is capped here (prevents content from spreading too thin on very wide screens). When the terminal is narrower, the real width is used as-is. Common values: `75` for a compact look, unset for "use whatever the pane is".

**`STATUSLINE_CHROME_PAD`** (default: `5`) — columns to subtract from `COLS` to account for Claude Code's left+right UI padding. Observed on macOS: `stty` reports 39 but rendering truncates around column 34, hence 5. If the last 1–2 characters still get truncated on your setup, bump this to `6` or `7`.

**Per-line degradation levels:**

| Line | Order (least-to-most lossy) |
|---|---|
| L1 (identity) | Strip `Ctx: ` label → branch truncate 24→16 → compact model (`Opus 4.6 (1M)` → `O4.6·1M`) → drop repo |
| L2 (resources) | Drop reset countdown → drop 7d limit (or API duration for local) → cost only |
| L3 (usage) | Drop API wait % → drop cache `(r:/w:)` detail → drop in/out tokens (cache hit % only) |
| L4 (session) | Drop version → drop session duration → drop agent → drop worktree (git stats + lines `+/-` always kept) |

Long repo names (>20 chars) are always truncated with a middle ellipsis (`dungeon-delvers-metadata-server` → `dungeon-de…ta-server`) regardless of level.

### Refresh interval

`refreshInterval` in `settings.json` (in seconds). A value like `30` balances freshness against script invocation cost. Lower values show live git/token updates more frequently but spawn the script more often.

### Git stats caching

Git file counts (`M` / `A`) are cached at `/tmp/claude-statusline-git-{hash}` for 30 seconds to avoid slow `git diff` on large repositories. A lockfile prevents thundering-herd when multiple sessions refresh simultaneously.

---

## How the speedup works

**Before** — 20+ subprocess spawns:
```bash
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
VERSION=$(echo "$input" | jq -r '.version // empty')
# ...
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
```

**After** — single `jq` call, shell-escaped output, evaluated once:
```bash
JQ_OUT=$(echo "$input" | jq -r '@sh "
MODEL=\(.model.display_name // "?")
VERSION=\(.version // "")
COST=\(.cost.total_cost_usd // 0)
..."' 2>&1)

[ $? -ne 0 ] && echo "[statusline jq error] $JQ_OUT" && exit 0
eval "$JQ_OUT"
```

### Why `eval` is safe here

The input JSON comes from Claude Code itself (trusted source), and `jq @sh` shell-escapes every value with single quotes — even malicious content like `"; rm -rf /"` would be emitted as `'"; rm -rf /"'`, which is a literal string, not an executable command.

Still want to avoid `eval`? You can rewrite with `IFS=$'\t' read ... <<< "$(jq -r '[...] | @tsv')"` but maintaining field-order alignment across the `jq` array and the `read` variable list is error-prone. The `@sh` + `eval` approach ties variable names to their `jq` expressions directly.

---

## Layout philosophy

The 4-line layout groups fields by semantic role so each line has a single theme:

| Line | Theme | Fields |
|---|---|---|
| L1 | **Identity & capacity** | Model, Repo:Branch, Context window |
| L2 | **Resource consumption** | 5h / 7d rate limits (or inference speed for local), session cost |
| L3 | **Usage & cache** | Tokens in/out, cache hit rate, API wait % |
| L4 | **Session state** | Duration, lines changed, git stats, worktree, agent, version |

Each line independently budgets against the detected pane width — in a 4-pane tmux/terminal split (~34 usable columns after Claude Code chrome), the statusline degrades gracefully rather than wrapping or getting terminal-side truncated.

Early versions used 3 lines but L1 grew to 85+ characters with all conditional fields active, causing truncation. Splitting to 4 lines trades one row of vertical space for reliable rendering, and per-line responsive degradation handles the narrow-pane case that MAX_WIDTH alone couldn't.

---

## Credits

Inspired by the observation that many public Claude Code statusline scripts duplicate `jq` calls unnecessarily. The `jq @sh` + `eval` trick is standard shell scripting — applied here to the statusline context.

---

## License

MIT
