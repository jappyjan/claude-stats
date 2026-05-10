#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Ensure the app is built fresh.
./scripts/build.sh

DMG="ClaudeStats.dmg"
rm -f "$DMG"

create-dmg \
    --volname "ClaudeStats" \
    --background "assets/dmg-bg.png" \
    --window-pos 200 120 \
    --window-size 624 416 \
    --icon-size 128 \
    --icon "ClaudeStats.app" 156 200 \
    --hide-extension "ClaudeStats.app" \
    --app-drop-link 468 200 \
    --no-internet-enable \
    "$DMG" \
    "ClaudeStats.app"

echo "Built $DMG"
ls -lh "$DMG"
