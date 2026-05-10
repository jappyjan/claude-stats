#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/ClaudeStats.app"
cp -R "ClaudeStats.app" "$DEST/"
open "$DEST/ClaudeStats.app"
echo "Installed to $DEST/ClaudeStats.app"
