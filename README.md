# claude-code-statusline

Fast, informative statusline for [Claude Code](https://docs.claude.com/en/docs/claude-code) — **~20x faster than common implementations**, with graceful fallback and built-in debug mode. Ships a matching subagent status line.

```
[Opus 5 (1M)·xhigh] 200k+ my-project:main │ Ctx: 59% ██░░░/1M
5h: 23% ⟳1h29m │ 7d: 41% ⟳3d15h │ $0.20
in:594.9K out:1.4K │ Cache: 96% 1h⟳42m │ cold:219.9K │ API 3%
Session: 2h28m │ +1714/-332 │ 1M ↑2 │ v2.1.278
```

Adapts automatically for cloud (Claude API) and local (Ollama) modes.

The guiding rule for what earns a column: **a normal session spends no space on
"everything is fine"**. Reasoning effort, fast mode, extended thinking, cache
misses and unpushed commits are rendered only when they differ from the
default — so anything visible is worth reading.

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
- **Width detection that matches reality** — `$COLUMNS` first, with `stty size </dev/tty` as a lazy fallback. Claude Code captures the script's stdout, so `tput cols` cannot reach the terminal (it only echoes `$COLUMNS` back) and there is no `.terminal.width` field in the payload at all — both were removed after measuring a real one. The common path now forks no subprocess for width
- **Chrome padding aware, and measurable** — subtracts Claude Code's UI padding from the budget so its own truncation (`…`) never fires. `touch ~/.claude/.statusline-ruler` turns the status line into a ruler that shows the real usable width instead of guessing it
- **Prompt cache diagnostics** — TTL (a red `5m` means the session is drawing on usage credits, where the subscription default is `1h`), time to expiry, miss count with its diagnosed cause (`miss:2(tools)`), and the tokens a cold cache would rewrite. Figures come from Claude Code's own `prompt_cache` object, which is scoped to the main conversation and excludes subagent traffic
- **Session state that is otherwise invisible** — reasoning effort, fast mode (`⚡`, which doubles the per-token price on Opus), extended thinking being off, and `200k+` for the long-context mode
- **Rate limits per window** — `5h` / `7d` / gateway `spend`. Each is independently optional and Claude Code drops a window once it resets, so they are read individually rather than gated on one another
- **Open PR / MR state** — `#123✓` approved, `#123✗` changes requested, `#123·draft`
- **Unpushed commits** — `↑2` means those commits exist only on this machine. Deliberately without a "behind" count: `origin/*` only moves on fetch, so a behind figure would report the state at the last fetch and read as an all-clear the script cannot give
- **Auto-adapts** for cloud Claude (shows rate limits) vs local Ollama or an API key (shows inference tok/s, since no plan limits exist there)
- **Git stats cached** to `/tmp` with 30-second TTL and lockfile-based concurrency control — works with 10+ simultaneous Claude Code sessions
- **Graceful fallback** — if `jq` parsing fails, prints a minimal error line instead of breaking the UI
- **Debug mode** — set `STATUSLINE_DEBUG=1` to dump jq output to stderr and append per-refresh width diagnostics to `/tmp/statusline-diag.log`
- **No dependencies** beyond `jq`, `bc`, `git` (standard on macOS/Linux)

---

## Example output (annotated)

```
[Opus 5 (1M)·xhigh] 200k+ my-project:main │ Ctx: 59% ██░░░/1M
│  Model + effort      │ long ctx │ Repo:Branch │ Context window usage + bar + size

5h: 23% ⟳1h29m │ 7d: 41% ⟳3d15h │ $0.20
│ 5-hour window + reset │ 7-day window + reset │ Session cost (list price, not your bill on a plan)

in:594.9K out:1.4K │ Cache: 96% 1h⟳42m │ cold:219.9K │ API 3%
│ Session in/out     │ Hit rate, TTL, time to expiry │ Tokens rewritten if it goes cold │ % of session waiting on API

Session: 2h28m │ +1714/-332 │ 1M ↑2 │ v2.1.278
│ Duration │ Lines changed │ Git: 1 modified, 2 unpushed │ Claude Code version
```

Conditional fields appear only when they say something:

| Field | Appears when |
|---|---|
| `·xhigh` | the model supports a reasoning effort level |
| `200k+` | the last response exceeded 200k tokens — the long-context mode `/usage` attributes separately. **Not** a pricing tier: 4.6+ bill the whole 1M window at standard rates |
| `⚡` | fast mode is on — **doubles the per-token price** on Opus 5 / 4.8 |
| `·nothink` | extended thinking has been turned off |
| `COLD` / red `5m` | the cache has expired / its TTL dropped to 5 minutes, which means usage credits are in play |
| `miss:2(tools)` | cache misses, with the diagnosed cause (`tools`, `sysprompt`, `ttl5m`, `server`) |
| `spend: 88%` | behind a Claude apps gateway with a spend limit |
| `#123✗` | the branch has an open PR / MR, with its review state |
| `↑2` | commits exist locally that are not on the upstream |
| `+10/-3`, `2M 3A` | lines changed this session / git modified + untracked |
| `🌿worktree:branch` | inside a [git worktree](https://git-scm.com/docs/git-worktree) |
| `agent-name` | a subagent is running |

---

## Installation

### 1. Download

```bash
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/ZWhiteTrace/claude-code-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh

# optional: the subagent status line (see below)
curl -o ~/.claude/subagent-statusline.sh https://raw.githubusercontent.com/ZWhiteTrace/claude-code-statusline/main/subagent-statusline.sh
chmod +x ~/.claude/subagent-statusline.sh
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
- **`/tmp/statusline-diag.log`**: one line per refresh with width detection state — whether `stty` was probed at all (`notprobed` means `$COLUMNS` already won), `COLUMNS`, the chosen `ACTUAL`, the final `COLS`, and `BUDGET`. Invaluable for diagnosing why lines aren't degrading as expected.

```
18:10:26 stty=notprobed COLUMNS=132 ACTUAL=132 MAX=unset PAD=4 -> COLS=132 BUDGET=128
```

The log appends forever while `STATUSLINE_DEBUG=1` is set — unset it when done.

### Short model name

Set `STATUSLINE_SHORT_MODEL=1` to strip the word `context` from the model display name. For example, `Opus 5 (1M context)` becomes `Opus 5 (1M)` — the context window size stays visible but the label is shorter. Unset (default) keeps the full model name.

### Width detection and degradation

The statusline computes a budget for each line as `COLS - CHROME_PAD`, where:

- `COLS` = `$COLUMNS`, falling back to `stty size </dev/tty` and then `80`, optionally capped by `STATUSLINE_MAX_WIDTH`
- `CHROME_PAD` = subtracted safety margin (default 5) for Claude Code's UI padding

Claude Code captures the script's stdout rather than wiring it to the terminal, so anything that measures through stdout is blind: `tput cols` answers from `$COLUMNS` when it is set and reports the non-TTY default when it is not. There is also no `.terminal.width` field in the payload — both probes were in earlier versions of this script and both were removed after measuring a real payload.

Each line runs a small loop that tries progressively shorter variants until one fits the budget.

#### Measuring `CHROME_PAD` instead of guessing it

```bash
touch ~/.claude/.statusline-ruler      # status line becomes a ruler
# ...read it, then:
rm ~/.claude/.statusline-ruler
```

Line 1 is a ruler `$COLUMNS` wide, marked every 10 columns (`1`=10 … `9`=90, then `a`=100, `b`=110, `c`=120). **Claude Code truncates an over-long line and appends its own `…`, so the position of that ellipsis is the real usable width.** Subtract it from `COLUMNS` to get your `CHROME_PAD`.

Line 2 is a second ruler exactly `BUDGET` wide, ending in `]`. If you can see the `]`, the current padding fits; if it ends in an ellipsis instead, `CHROME_PAD` is too small.

**`STATUSLINE_CHROME_PAD`** (default: `5`) — columns to subtract for Claude Code's UI padding. Measured as `4` on macOS with an external display (`COLUMNS=132`, usable 128). Measure your own with the ruler rather than adopting that number.

**`STATUSLINE_MAX_WIDTH`** (default: unset) — soft cap; when the terminal is wider than this, `COLS` is capped here. **Most setups should leave it unset.** It exists from a time when no reliable width source was available and a hand-set number was the best substitute; now that `$COLUMNS` is read correctly, a fixed cap mostly just wastes columns — and it goes stale the moment you switch between a laptop screen and an external display. The degradation ladder already handles narrow panes.

**Per-line degradation levels:**

| Line | Order (least-to-most lossy) |
|---|---|
| L1 (identity) | Strip `Ctx: ` label → branch truncate 24→16 and repo 32→20 → abbreviate effort (`xhigh`→`X`) → compact model (`Opus 5 (1M)` → `O5·1M`) → drop repo → shrink `200k+` to `!` |
| L2 (resources) | Drop reset countdowns → drop 7d and spend windows → cost only |
| L3 (usage) | Drop API wait % → drop `cold:` → drop cache expiry and miss detail → drop in/out tokens |
| L4 (session) | Drop version → drop session duration → drop agent → drop worktree (git stats, lines `+/-`, unpushed count and PR state always kept) |

Repo names longer than the current limit are truncated with a middle ellipsis (`dungeon-delvers-metadata-server` → `dungeon-delvers-…tadata-server` at full width, `dungeon-de…ta-server` once compressed).

Two caveats worth knowing: wide characters **inside payload strings** (a CJK repo, branch or worktree name) are counted as one column each and can overrun the line — the width table covers only the glyphs this script emits itself. And East Asian Ambiguous characters (`│ █ · …`) are assumed to be one column, as most terminals render them.

### Refresh interval

`refreshInterval` in `settings.json` (in seconds). A value like `30` balances freshness against script invocation cost. Lower values show live git/token updates more frequently but spawn the script more often.

### Git stats caching

Git file counts (`M` / `A`) are cached at `/tmp/claude-statusline-git-{hash}` for 30 seconds to avoid slow `git diff` on large repositories. A lockfile prevents thundering-herd when multiple sessions refresh simultaneously.

---

## Subagent status line

`subagentStatusLine` is a separate setting that renders each row of the agent
panel. The built-in row is `name · description · token count`, which omits the
one thing worth checking at a glance: **which model a delegation actually got**.

```json
{
  "subagentStatusLine": {
    "type": "command",
    "command": "~/.claude/subagent-statusline.sh"
  }
}
```

```
▸ Review the width math ·Opus·1M ·142.2K 14% ·9m37s · Measuring CJK overflow in vis_len
▸ Cloud task ☁ ·Sonnet ·5.0K 2% ·9m37s
✓ Run the tests $ ·300 0% · go test ./...
```

Status mark, title, execution kind (only when it is not a plain local agent),
model (Opus magenta, Sonnet cyan, Haiku dim, with a `1M` marker), tokens against
*that task's* context window, elapsed time, and the live activity.

That last segment is the point. `label` changes every tick and is the highest
information field on the row — but the obvious `.description // .label` never
reaches it, because `description` is always populated and jq's `//` treats any
string as truthy.

**The payload does not match the documented field list**, measured against
Claude Code 2.1.278 across 62 real rows:

| Documented | Actually |
|---|---|
| tasks have a `name` | no `name` field at all — the title falls back to `description` |
| `type` is the agent kind | it is the *execution* kind (`local_agent`, `local_bash`, `remote_agent`, …) |
| `effort` is present | absent whenever the subagent inherits the session's effort, which is the common case |
| — | `model` carries a `[1m]` suffix (`claude-opus-5[1m]`) |

Two child processes per tick regardless of row count — one `jq` to extract and
sanitise, one `perl` to measure and emit. `perl` because width has to be counted
in display columns: counting codepoints made a 126-column budget render as 221
columns and wrap, and subagent descriptions are frequently CJK.

Sanitisation happens in `jq` because the failure modes it prevents take out more
than one row. A non-integer reaching `$(( ))` aborts the subshell running the
read loop, so that row *and every row after it* vanish — and a non-zero exit
makes Claude Code discard the whole panel. A control character inside a field
either splits the record into a bogus extra row with a fabricated id, or shifts
every later field by one position, rendering status as model and effort as a
token count.

---

## Tests

```bash
tests/run_tests.sh        # main status line
tests/test_subagent.sh    # subagent status line
```

Three assertions on every case:

1. **exactly four lines** — the hard contract. A worktree directory named
   `aa\nbb` used to split line 4 in two, because `echo -e` expands escapes
   inside payload strings
2. **no line over budget** — measured by an independent oracle
   (`tests/width_oracle.py`) that counts *display* columns via `unicodedata`,
   deliberately not reusing the shell script's own width function
3. **no line falling back to the clamp at a sane width** — the safety net strips
   colour and hard-truncates, so a broken rung of the degradation ladder still
   "fits" and hides behind assertion 2. This is the assertion that catches it

Widths are swept from 20 to 200 **one at a time rather than sampled**: a wide
character the script undercounts only overruns at the exact width where the
chosen variant sits one column under budget, and sampling walks straight past
it. The subagent suite brute-forces all 2⁶ combinations of present/absent
optional fields.

The fixture is a real captured payload with the identifying fields replaced.
It ages: if Claude Code changes the payload shape the suite stays green while
testing a format that no longer exists. Recapture by having the script write its
stdin to a file once, then removing that line.

CI runs `shellcheck -S warning` over the whole repository on every push.

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
| L1 | **Identity & capacity** | Model, effort, mode flags, long-context marker, Repo:Branch, context window |
| L2 | **Resource consumption** | 5h / 7d / spend windows (or inference speed where no plan limits exist), session cost |
| L3 | **Usage & cache** | Tokens in/out, cache hit rate, TTL and expiry, misses with cause, re-cache cost, API wait % |
| L4 | **Session state** | Duration, lines changed, git stats, unpushed commits, PR state, worktree, agent, version |

Each line independently budgets against the detected pane width — in a 4-pane tmux/terminal split (~34 usable columns after Claude Code chrome), the statusline degrades gracefully rather than wrapping or getting terminal-side truncated.

Early versions used 3 lines but L1 grew to 85+ characters with all conditional fields active, causing truncation. Splitting to 4 lines trades one row of vertical space for reliable rendering, and per-line responsive degradation handles the narrow-pane case that a fixed width cap alone couldn't.

What keeps four lines readable as fields accumulate is the rule stated at the
top: a field earns a column only while it is saying something. Effort, mode
flags, cache misses, PR state and unpushed commits are all absent from a healthy
session, so the lines above are close to their widest — not their typical.

---

## Credits

Inspired by the observation that many public Claude Code statusline scripts duplicate `jq` calls unnecessarily. The `jq @sh` + `eval` trick is standard shell scripting — applied here to the statusline context.

---

## License

MIT
