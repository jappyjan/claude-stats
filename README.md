# claude-stats

A macOS menubar app showing your Claude Code usage from local JSONL session logs.
Two tabs: **Overview** (totals, trend, per-model) and **Projects** (per-project bars + drill-in).
No API keys, no daemons, no third-party services.

## Install

**Easiest:** download the latest [`ClaudeStats.dmg`](https://github.com/jappyjan/claude-stats/releases/latest), open it, and drag the app into `Applications`. Right-click → Open the first time so Gatekeeper lets it through.

> If macOS says **"ClaudeStats is damaged and can't be opened"**, that's just Gatekeeper's quarantine on unsigned apps. Remove the quarantine flag once and you're done:
>
>     xattr -dr com.apple.quarantine /Applications/ClaudeStats.app

**From source:**

    git clone https://github.com/jappyjan/claude-stats.git
    cd claude-stats
    ./scripts/install.sh

The app will appear in `~/Applications/ClaudeStats.app` and launch automatically.

## Where the data comes from

`~/.claude/projects/**/*.jsonl` — Claude Code's local session logs.
The app stores aggregations in `~/Library/Application Support/claude-stats/usage.db`.

## Updates

Auto-update first shipped in v1.0.4 — earlier installs need a one-time
manual upgrade to start receiving prompts.

The app checks for new releases once a day via [Sparkle](https://sparkle-project.org/).
When a new version is available, you'll see a prompt with release notes and
an Install button. You can disable automatic checks from
**Settings → Automatically check for updates** at any time; the "Check for
updates now" button still works regardless.

## Limits

A progress strip above the popover tabs shows how much of your
subscription window you've consumed:

- **5h** — the rolling 5-hour quota Anthropic enforces on Pro and Max
  plans.
- **7d** — the rolling 7-day cap on Max plans only.

Pick your plan in **Settings → Limits** (Pro / Max 5x / Max 20x); the
bar stays hidden until you do. Numbers are derived from local JSONL
data compared against documented plan limits, so they're
approximations. If you also use Claude Code on other machines under
the same account, the local estimate may read low.

## Pricing

Pulled from [LiteLLM's community pricing JSON](https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/model_prices_and_context_window_backup.json),
refreshed every 24h while the app runs. A bundled fallback ships inside the app for offline first-launch.

## Development

    swift test
    swift run

## License

MIT (see LICENSE).
