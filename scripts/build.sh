#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Resolve version: prefer caller-supplied $VERSION, else most recent git tag.
if [ -z "${VERSION:-}" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo '0.0.0-dev')"
fi
echo "Building ClaudeStats version: $VERSION"

# 1. Build the release binary.
swift build -c release

APP="ClaudeStats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/claude-stats "$APP/Contents/MacOS/ClaudeStats"
cp Sources/ClaudeStats/Info.plist "$APP/Contents/Info.plist"

# Inject the version into the .app's Info.plist so Sparkle and the popover
# both see the same number.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION"            "$APP/Contents/Info.plist"

# 2. Copy pricing-fallback.json directly into Resources/ so Bundle.main finds it.
cp Sources/ClaudeStats/Resources/pricing-fallback.json "$APP/Contents/Resources/"

# 3. Generate AppIcon.icns from assets/icon.png and bundle it.
ICON_SRC="assets/icon.png"
if [ ! -f "$ICON_SRC" ]; then
    echo "Missing $ICON_SRC — cannot generate icon" >&2
    exit 1
fi

ICONSET="$(mktemp -d -t claudestats-iconset.XXXXXX)/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png"   >/dev/null
cp "$ICON_SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# 4. Ad-hoc codesign so Gatekeeper recognizes the bundle as signed rather than
#    "damaged" after the DMG is quarantined by the browser. Without this,
#    downloaded copies hit "is damaged and can't be opened" with no bypass.
#    Re-run this step in CI after SUPublicEDKey is injected, so the signature
#    covers the final Info.plist contents.
codesign --force --deep --sign - "$APP"

echo "Built $APP at version $VERSION"
