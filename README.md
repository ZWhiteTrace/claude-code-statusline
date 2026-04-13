# claude-code-statusline

Fast, informative statusline for [Claude Code](https://docs.claude.com/en/docs/claude-code) — **~20x faster than common implementations**, with graceful fallback and built-in debug mode.

```
[Opus 4.6 (1M context)] lobster-survivor:main │ Ctx: 5% ░░░░░░░░░░/1M
5h: 44% ⟳2h4m │ 7d: 31% ⟳5d10h
in:343 out:18 │ Cache: 36% hit (r:17.5K w:30.7K) │ API 12%
Session: 30s │ 1M │ $0.20 │ v2.1.104
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

Benchmarked on macOS 14 (Darwin 24.5.0), bash 3.2, jq 1.7.

---

## Features

- **Single-pass JSON parsing** via `jq @sh` + `eval` — no repeated process spawn
- **4-line layout** with semantic grouping (identity / rate limits / usage / session)
- **Auto-adapts** for cloud Claude (shows 5h / 7d rate limits) vs local Ollama (shows inference tok/s)
- **Git stats cached** to `/tmp` with 30-second TTL and lockfile-based concurrency control — works with 10+ simultaneous Claude Code sessions
- **Graceful fallback** — if `jq` parsing fails, prints a minimal error line instead of breaking the UI
- **Debug mode** — set `STATUSLINE_DEBUG=1` to dump the expanded `jq` output to stderr
- **No dependencies** beyond `jq`, `bc`, `git` (standard on macOS/Linux)

---

## Example output (annotated)

```
[Opus 4.6 (1M context)] lobster-survivor:main │ Ctx: 5% ░░░░░░░░░░/1M
│  Model name            │  Repo:Branch       │ Context window usage + bar + total size

5h: 44% ⟳2h4m │ 7d: 31% ⟳5d10h
│ 5-hour rate limit + time until reset │ 7-day rate limit + time until reset

in:343 out:18 │ Cache: 36% hit (r:17.5K w:30.7K) │ API 12%
│ Total in/out tokens  │ Cache hit rate (reads / writes) │ % of session spent on API calls

Session: 30s │ 1M │ $0.20 │ v2.1.104
│ Session duration │ Git: 1 Modified │ Session cost │ Claude Code version
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

If the statusline looks wrong, run with `STATUSLINE_DEBUG=1` to see the expanded variable assignments:

```bash
STATUSLINE_DEBUG=1 ~/.claude/statusline.sh < test-input.json
```

You can also inspect by piping the Claude Code JSON structure from a live session. See [Claude Code statusline docs](https://docs.claude.com/en/docs/claude-code/statusline) for the input JSON schema.

### Refresh interval

`refreshInterval` in `settings.json` (in seconds). Default `30`. Lower values show live git/token updates more frequently but spawn the script more often.

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
| L2 | **Rate limits** (cloud) or **Inference speed** (local) | 5h / 7d limits, or tok/s |
| L3 | **Usage & cache** | Tokens in/out, cache hit rate, API wait % |
| L4 | **Session state** | Duration, lines changed, git stats, worktree, agent, cost, version |

Each line stays under ~65 characters in typical sessions, so narrow terminal windows don't truncate.

Early versions used 3 lines but L1 grew to 85+ characters with all conditional fields active, causing truncation. Splitting to 4 lines trades one row of vertical space for reliable rendering.

---

## Credits

Inspired by the observation that many public Claude Code statusline scripts duplicate `jq` calls unnecessarily. The `jq @sh` + `eval` trick is standard shell scripting — applied here to the statusline context.

---

## License

MIT
