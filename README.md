# claude-stats

A macOS menubar app showing your Claude Code usage from local JSONL session logs.
Two tabs: **Overview** (totals, trend, per-model) and **Projects** (per-project bars + drill-in).
No API keys, no daemons, no third-party services.

## Install

**Easiest:** download the latest [`ClaudeStats.dmg`](https://github.com/jappyjan/claude-stats/releases/latest), open it, and drag the app into `Applications`. Right-click → Open the first time so Gatekeeper lets it through.

**From source:**

    git clone https://github.com/jappyjan/claude-stats.git
    cd claude-stats
    ./scripts/install.sh

The app will appear in `~/Applications/ClaudeStats.app` and launch automatically.

## Where the data comes from

`~/.claude/projects/**/*.jsonl` — Claude Code's local session logs.
The app stores aggregations in `~/Library/Application Support/claude-stats/usage.db`.

## Pricing

Pulled from [LiteLLM's community pricing JSON](https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/model_prices_and_context_window_backup.json),
refreshed every 24h while the app runs. A bundled fallback ships inside the app for offline first-launch.

## Development

    swift test
    swift run

## License

MIT (see LICENSE).
