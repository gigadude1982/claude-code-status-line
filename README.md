# claude-status-line

A vibrant, information-dense statusline for [Claude Code](https://claude.ai/code) — model, live toggles, context usage, cost, git status, and rate limits, rendered with a neon 256-color palette and emoji glyphs.

![statusline example](https://img.shields.io/badge/Claude_Code-statusline-blue)

## What it shows

**Line 1 — identity & live state**
- 🤖 **model**, tinted by family (Opus = violet, Sonnet = cyan, Haiku = green) + version
- ↩ **model-switch breadcrumb** — the model you switched from, once you change mid-session
- **effort badge** tracking `/effort`: 🐢 low · ⚙️ medium · ⚡ high · 🔥 xhigh · 🚀 max
- 💭 **thinking** (when extended thinking is on) · 🏎️ **fast** (when `/fast` is engaged)
- 🎨 **output style** (when not `default`) · session name · 🛠️ agent · vim mode
- 👤 **account** & org · ✨ **plan**
- 📂 **directory** (`~`-abbreviated, deep paths collapsed to `~/…/parent/base`) · 🌳 **worktree** badge — inside a git worktree, 📂 shows the *main* repo and 🌳 names the worktree
- `(owner/name)` repo identity, 🌿 **branch** + git status, 🕐 **last-commit age**, 🔀 **PR**

**Line 2 — context window**
- 🧠 **mood emoji** by fullness: 🧠 (<70%) → 😅 (70–89%) → 🥵 (≥90%)
- gradient **usage bar** (green → yellow → orange → red as it fills)
- used % · remaining % · 📈 **usage sparkline** (trend over time) · 🛫 **runway** (ETA to full)
- token breakdown: input, output, cache read/write · 💾 **cache-hit %** · context size
- ⚠️ **200k+** badge when the conversation crosses 200k tokens

**Line 3 — cost & timing**
- **cost emoji** by tier: 🪙 (<$1) · 💰 ($1–$9) · 💸 (≥$10) + total cost
- lines changed (+added / −removed) · ✏️ **lines/hr** velocity
- ⏱️ session duration · 🛰️ time spent waiting on the API · 💵 **cost velocity** ($/hr with a 🐢→🔥 burn emoji)

**Lines 4–5 — plan usage limits (mirrors claude.ai › Settings › Usage)**
- ⚡ **session** (5-hour window) · 📅 **all models** (weekly) · ✨ **per-model weekly** rows (e.g. *Fable*) · 💳 **usage credits** toggle
- the same rows, values, and floor-rounded percentages as claude.ai's Usage panel, with gradient bars and reset countdowns (weekly resets show days + the absolute day/time, e.g. `5d18h (sun 8/9 3:00am)`)

### Git status

Next to the branch, from a single `git status` call:

| Marker | Meaning |
|--------|---------|
| `⇡n` / `⇣n` | commits ahead / behind upstream |
| `●n` | staged changes |
| `✎n` | modified (unstaged) |
| `…n` | untracked files |
| `✓` | clean working tree |
| `🕐 <age>` | time since the last commit — turns amber when uncommitted work sits on a commit older than 30 min |

The PR badge (`🔀 #123`) is colored by review state: approved ✓ (green), changes requested ✗ (red), pending (yellow), draft ✎ (grey).

### Context-usage sparkline & runway

The 📈 sparkline (`▁▂▃▄▅▆▇█`) tracks the context used-% over time. History is kept per-session in a temp file as `(timestamp, used-%)` pairs, sampled at most once every 8 seconds (so it reflects real elapsed time, not render frequency) and capped at the last 20 points. Stale files from old sessions are swept automatically.

The 🛫 **runway** projects an ETA to a full context window from that history, shown only when context is genuinely climbing over a ≥30s window — so it stays quiet during noise, flat usage, or when the context is compacted and usage drops.

### Derived metrics

- **💾 Cache-hit %** — `cache_read ÷ (input + cache_creation + cache_read)`, colored green (≥80%) / yellow (≥50%) / orange. Higher = more prompt-cache reuse = cheaper & faster.
- **💵 Cost velocity** — session spend rate ($/hr) with a burn emoji: 🐢 <$1 · 🚶 $1–$4 · 🏃 $5–$14 · 🔥 ≥$15 per hour.
- **✏️ Code-change velocity** — total lines touched per hour over the session.
- **↩ Model-switch breadcrumb** — the distinct models used this session are tracked (per-session, recency-ordered); when you change models, line 1 shows where you came from.

### Bar gradient ("fuel gauge")

Bars color each cell by its position along a green → red ramp, so color signals how full something is: a low bar is all green ("plenty of room"), and it warms through yellow and orange to red as it fills.

### Accurate usage limits (claude.ai parity)

The statusline JSON that Claude Code pipes in only ever carries the 5-hour session window and the all-models weekly window — the **per-model weekly limits** (e.g. the "Fable" row) and the **usage-credits** state shown on claude.ai never appear in it. To display those, the script queries `GET https://api.anthropic.com/api/oauth/usage` — the *same endpoint the claude.ai Usage panel and Claude Code's own `/usage` screen read* — so the numbers match claude.ai exactly.

How it behaves:

- **Non-blocking** — the response is cached to a temp file (default TTL 180s, tune with `CLAUDE_STATUSLINE_USAGE_TTL`); refreshes happen in a detached background job, so rendering never waits on the network. Data older than 10 minutes is flagged `(as of Xm ago)`.
- **Auth** — the OAuth token is read from `~/.claude/.credentials.json` (Linux) or the macOS Keychain (`Claude Code-credentials`), used for the one HTTPS call to `api.anthropic.com`, and never written to disk. On macOS the first call may pop a Keychain permission prompt for `security` — click "Always Allow" once.
- **Opt-out** — set `CLAUDE_STATUSLINE_USAGE_API=0` to disable the fetch entirely; the limits section then falls back to the stdin-provided windows.

### Rate limit caching (fallback path)

Claude Code only includes rate limit data in the statusline JSON when it receives fresh headers from the API. Without caching, the rate limit bars disappear between messages. This script persists the last known values to a temp file and shows a `(cached Xm ago)` label when displaying stale data, so the bars are always visible even when the usage endpoint is disabled or unreachable.

## Requirements

- [Claude Code](https://claude.ai/code)
- `jq` on PATH (comes with Git Bash on Windows; `brew install jq` on Mac)
- Bash (Git Bash on Windows, native on Mac/Linux)
- A terminal with emoji and 256-color support (iTerm2, Ghostty, VS Code, Terminal.app, most modern terminals)

## Installation

```bash
git clone git@github.com:gigadude1982/claude-status-line.git
cd claude-status-line
bash install.sh
```

The install script copies `statusline.sh` to `~/.claude/statusline.sh` and prints the exact block to add to `~/.claude/settings.json`.

### Manual settings.json update

Add the `statusLine` block printed by `install.sh` to `~/.claude/settings.json`:

**Mac / Linux**
```json
"statusLine": {
  "type": "command",
  "command": "/Users/<you>/.claude/statusline.sh",
  "padding": 2
}
```

**Windows (Git Bash)**
```json
"statusLine": {
  "type": "command",
  "command": "C:\\Program Files\\Git\\bin\\bash.exe /c/Users/<you>/.claude/statusline.sh",
  "padding": 2
}
```

## Configuration

### Light vs dark backgrounds

Labels/secondary text render **white on dark** backgrounds and **grey on light** ones. The script detects the background from `$COLORFGBG` when the terminal exports it; otherwise it assumes dark (the common case, e.g. macOS Terminal.app). If you use a light-background terminal that doesn't set `COLORFGBG`, force it:

```bash
export CLAUDE_STATUSLINE_BG=light   # or: dark
```

### Compact mode

Set `CLAUDE_STATUSLINE_COMPACT=1` to trim the line down to the essentials — model, plan, directory + worktree, branch + git status, the context bar, cost, and the usage-limit bars — hiding the many secondary badges (effort/thinking/fast/style/session/account/repo/PR, sparkline/runway/token breakdown, api-wait/velocities, and the "used"/reset annotations on the limit bars). Everything is still computed the same way; the optional segments are just hidden.

```bash
export CLAUDE_STATUSLINE_COMPACT=1
```

## Updating

```bash
git pull
bash install.sh
```

## Plan detection

The script reads `~/.claude.json` to determine your subscription tier and displays it in the header:

| Tier | Label |
|------|-------|
| `default_claude_max_5x` | Max 5x |
| `default_claude_max_20x` | Max 20x |
| `default_claude_max_1x` | Max 1x |
| `claude_pro` | Pro (or Max if extra usage enabled) |

## Graceful degradation

Every field is parsed defensively (`// empty`), so badges only appear when their data is present. Older Claude Code versions that don't emit newer fields (effort, thinking, fast mode, PR, repo, etc.) simply render without those badges — nothing breaks.
