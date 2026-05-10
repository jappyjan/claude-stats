#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="ClaudeStats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/claude-stats "$APP/Contents/MacOS/ClaudeStats"
cp Sources/ClaudeStats/Info.plist "$APP/Contents/Info.plist"

# Bundle SPM-generated resource bundle (contains pricing-fallback.json).
RESBUNDLE=".build/release/ClaudeStats_ClaudeStats.bundle"
if [ -d "$RESBUNDLE" ]; then
    cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
fi

echo "Built $APP"
