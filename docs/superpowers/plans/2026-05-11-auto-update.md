# Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Sparkle 2 auto-update to ClaudeStats with a user-side opt-out toggle, plus a tag-driven GitHub Actions release pipeline that publishes signed update artifacts to GitHub Releases and an appcast feed to GitHub Pages.

**Architecture:** Sparkle's `SPUStandardUpdaterController` is wired into `AppContainer` and exposed to `SettingsView` via a thin `UpdaterController` wrapper. The wrapper just forwards `automaticallyChecksForUpdates` (which Sparkle persists in UserDefaults) and `checkForUpdates(_:)`. The app's `Info.plist` ships an `SUFeedURL` pointing at `https://jappyjan.github.io/claude-stats/appcast.xml` and an `SUPublicEDKey` placeholder that CI replaces at build time. Tag pushes (`v*.*.*`) trigger `.github/workflows/release.yml`, which derives the version from the tag, injects it into `Info.plist`, builds the `.app` ad-hoc-signed, produces both a DMG (user download) and a ZIP (Sparkle artifact), signs the ZIP with the EdDSA private key from secrets, generates `appcast.xml`, uploads release assets, and force-pushes the appcast to a `gh-pages` branch.

**Tech Stack:** Swift 5.9 / SwiftPM, macOS 14+, AppKit, SwiftUI, Sparkle 2.6+, GitHub Actions on `macos-14`, bash, `create-dmg`, `PlistBuddy`, `ditto`, Sparkle's `sign_update` tool, `gh` CLI, `softprops/action-gh-release@v2`, `peaceiris/actions-gh-pages@v4`.

**Reference:** `docs/superpowers/specs/2026-05-11-auto-update-design.md`.

---

## Files touched

**Create:**
- `Sources/ClaudeStats/Updates/UpdaterController.swift`
- `Tests/ClaudeStatsTests/UpdaterControllerTests.swift`
- `Tests/ClaudeStatsTests/AppcastGenerationTests.swift`
- `Tests/ClaudeStatsTests/Fixtures/releases-sample.json`
- `Tests/ClaudeStatsTests/Fixtures/appcast-expected.xml`
- `scripts/make-appcast.sh`
- `.github/workflows/release.yml`
- `docs/RELEASING.md`

**Modify:**
- `Package.swift` — add Sparkle dependency
- `Sources/ClaudeStats/App/AppContainer.swift` — add `updater` property
- `Sources/ClaudeStats/Views/SettingsView.swift` — version from Bundle, auto-update toggle, "Check now" button
- `Sources/ClaudeStats/Info.plist` — Sparkle keys
- `scripts/build.sh` — `VERSION` env var + PlistBuddy injection
- `README.md` — note auto-update behavior

---

### Task 0: Verify baseline

**Files:** none (read-only checks)

- [ ] **Step 1: Confirm git state**

Run: `git status && git rev-parse HEAD && git log -1 --format=%s`

Expected: working tree clean (except possibly the just-committed spec/plan docs), HEAD on `t3code/8f3d7d49`, most recent commit either the version bump or the spec commit.

- [ ] **Step 2: Confirm fast-forward to origin/main is complete**

Run: `git fetch origin && git log --oneline origin/main..HEAD && git log --oneline HEAD..origin/main`

Expected: both outputs empty OR the first shows only commits we already added in this session (spec + plan). Nothing remote-only that we haven't picked up.

- [ ] **Step 3: Run baseline test suite**

Run: `swift test 2>&1 | tail -20`

Expected: every test passes. Note the count for comparison after our changes.

- [ ] **Step 4: Verify the latest GitHub release is intact**

Run: `gh release view v1.0.3 --repo jappyjan/claude-stats --json tagName,assets -q '{tag: .tagName, assets: [.assets[].name]}'`

Expected: `{"tag":"v1.0.3","assets":["ClaudeStats.dmg"]}` or similar — proves the existing distribution channel is healthy before we touch anything.

No commit (read-only).

---

### Task 1: Add Sparkle SPM dependency

**Files:**
- Modify: `Package.swift`
- Create: `Tests/ClaudeStatsTests/SparkleImportTests.swift`

- [ ] **Step 1: Write failing import test**

Create `Tests/ClaudeStatsTests/SparkleImportTests.swift`:

```swift
import XCTest
import Sparkle

final class SparkleImportTests: XCTestCase {
    func test_sparkleStandardUpdaterControllerTypeExists() {
        // Compile-time check that Sparkle is wired up correctly.
        // If Sparkle is missing from Package.swift, this file won't build.
        XCTAssertNotNil(SPUStandardUpdaterController.self)
    }
}
```

- [ ] **Step 2: Run test, expect compile failure**

Run: `swift test --filter SparkleImportTests 2>&1 | tail -10`

Expected: build error along the lines of "no such module 'Sparkle'".

- [ ] **Step 3: Add Sparkle to Package.swift**

Replace the current `Package.swift` body with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-stats", targets: ["ClaudeStats"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeStats",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Info.plist", "Resources"]
        ),
        .testTarget(
            name: "ClaudeStatsTests",
            dependencies: ["ClaudeStats"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 4: Resolve and build**

Run: `swift package resolve && swift build 2>&1 | tail -5`

Expected: "Build complete!" with no errors. First run may take 30-60s while Sparkle downloads.

- [ ] **Step 5: Run import test, expect pass**

Run: `swift test --filter SparkleImportTests 2>&1 | tail -5`

Expected: `Test Suite 'SparkleImportTests' passed`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Tests/ClaudeStatsTests/SparkleImportTests.swift
git commit -m "deps: add Sparkle 2.6 for auto-update"
```

---

### Task 2: UpdaterController wrapper with tests

**Files:**
- Create: `Sources/ClaudeStats/Updates/UpdaterController.swift`
- Create: `Tests/ClaudeStatsTests/UpdaterControllerTests.swift`

- [ ] **Step 1: Write failing test for the wrapper**

Create `Tests/ClaudeStatsTests/UpdaterControllerTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

@MainActor
final class UpdaterControllerTests: XCTestCase {
    func test_initWithoutStartingUpdater_doesNotCrash() {
        let controller = UpdaterController(startingUpdater: false)
        XCTAssertNotNil(controller.updater)
    }

    func test_automaticallyChecks_setterUpdatesGetter() {
        let controller = UpdaterController(startingUpdater: false)
        let original = controller.automaticallyChecks

        controller.automaticallyChecks = false
        XCTAssertFalse(controller.automaticallyChecks)

        controller.automaticallyChecks = true
        XCTAssertTrue(controller.automaticallyChecks)

        controller.automaticallyChecks = original  // restore
    }
}
```

- [ ] **Step 2: Run test, expect compile failure (no UpdaterController)**

Run: `swift test --filter UpdaterControllerTests 2>&1 | tail -10`

Expected: "cannot find 'UpdaterController' in scope" or similar.

- [ ] **Step 3: Create the wrapper**

Create directory and file:

```bash
mkdir -p Sources/ClaudeStats/Updates
```

Create `Sources/ClaudeStats/Updates/UpdaterController.swift`:

```swift
import Foundation
import Sparkle

@MainActor
final class UpdaterController {
    let updater: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        self.updater = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecks: Bool {
        get { updater.updater.automaticallyChecksForUpdates }
        set { updater.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `swift test --filter UpdaterControllerTests 2>&1 | tail -10`

Expected: both tests pass. Sparkle may log warnings about missing Info.plist keys to Console — that's fine; we're not asserting log output.

- [ ] **Step 5: Run full test suite**

Run: `swift test 2>&1 | tail -10`

Expected: all tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStats/Updates/ Tests/ClaudeStatsTests/UpdaterControllerTests.swift
git commit -m "updates: add UpdaterController wrapping Sparkle"
```

---

### Task 3: Wire UpdaterController into AppContainer

**Files:**
- Modify: `Sources/ClaudeStats/App/AppContainer.swift`

- [ ] **Step 1: Add the property to AppContainer**

In `Sources/ClaudeStats/App/AppContainer.swift`, find the property declarations block (lines 7-15). Add `updater` after `viewModel`:

Before:
```swift
@MainActor
final class AppContainer {
    let store: UsageStore
    let reader: UsageReader
    let monitor: ActivityMonitor
    let pricingFetcher: PricingFetcher
    let viewModel: StatsViewModel

    private var midnightTimer: Timer?
```

After:
```swift
@MainActor
final class AppContainer {
    let store: UsageStore
    let reader: UsageReader
    let monitor: ActivityMonitor
    let pricingFetcher: PricingFetcher
    let viewModel: StatsViewModel
    let updater: UpdaterController

    private var midnightTimer: Timer?
```

- [ ] **Step 2: Initialize it at the end of `init()`**

In the same file, find the end of `init()` (the closing brace before `func rebuildIndex()`). Add the line that constructs `updater` just before that closing brace:

Before:
```swift
        monitor.onTick = { [weak viewModel, weak monitor] in
            guard let viewModel = viewModel, let monitor = monitor else { return }
            Task { @MainActor in
                viewModel.isActive = monitor.isActive
                await viewModel.refresh()
            }
        }
    }

    func rebuildIndex() async {
```

After:
```swift
        monitor.onTick = { [weak viewModel, weak monitor] in
            guard let viewModel = viewModel, let monitor = monitor else { return }
            Task { @MainActor in
                viewModel.isActive = monitor.isActive
                await viewModel.refresh()
            }
        }

        self.updater = UpdaterController()
    }

    func rebuildIndex() async {
```

`startingUpdater` defaults to `true`, so Sparkle starts polling on app launch — which is what we want.

- [ ] **Step 3: Build, expect success**

Run: `swift build 2>&1 | tail -5`

Expected: "Build complete!" with no errors.

- [ ] **Step 4: Run full test suite**

Run: `swift test 2>&1 | tail -10`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/App/AppContainer.swift
git commit -m "app: instantiate UpdaterController in AppContainer"
```

---

### Task 4: Sparkle keys in Info.plist

**Files:**
- Modify: `Sources/ClaudeStats/Info.plist`

- [ ] **Step 1: Add Sparkle keys**

In `Sources/ClaudeStats/Info.plist`, find the closing `</dict>` and `</plist>` at the bottom. Insert the Sparkle keys just before `</dict>`:

```xml
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://jappyjan.github.io/claude-stats/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>PLACEHOLDER_REPLACED_BY_CI</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
```

`PLACEHOLDER_REPLACED_BY_CI` is intentional and committed. CI overwrites it with the real public key before codesigning the `.app`. For local builds, Sparkle will log a warning at startup about an invalid key — that's acceptable for dev mode.

- [ ] **Step 2: Validate the plist**

Run: `plutil -lint Sources/ClaudeStats/Info.plist`

Expected: `Sources/ClaudeStats/Info.plist: OK`.

- [ ] **Step 3: Run full test suite (sanity)**

Run: `swift test 2>&1 | tail -5`

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStats/Info.plist
git commit -m "info.plist: add Sparkle feed URL and key placeholders"
```

---

### Task 5: Display version from Bundle in SettingsView

**Files:**
- Modify: `Sources/ClaudeStats/Views/SettingsView.swift`

- [ ] **Step 1: Replace hardcoded version string**

In `Sources/ClaudeStats/Views/SettingsView.swift`, find the version line near the bottom (~line 41):

Before:
```swift
            HStack {
                Spacer()
                Text("v1.0.3").font(.caption2).foregroundStyle(.secondary)
            }
```

After:
```swift
            HStack {
                Spacer()
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
```

When running `swift run` from source (no .app bundle), this renders as `v?`. In a built `.app`, CI has already injected the version from the git tag.

- [ ] **Step 2: Build and run tests**

Run: `swift test 2>&1 | tail -5`

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStats/Views/SettingsView.swift
git commit -m "settings: read version from Bundle instead of hardcoding"
```

---

### Task 6: Auto-update toggle and "Check now" button in SettingsView

**Files:**
- Modify: `Sources/ClaudeStats/Views/SettingsView.swift`

- [ ] **Step 1: Add toggle state and UI**

In `Sources/ClaudeStats/Views/SettingsView.swift`, modify the struct to add an auto-update state and UI. The full replacement file should be:

```swift
import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoUpdate: Bool
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _autoUpdate = State(initialValue: container.updater.automaticallyChecks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 14, weight: .semibold))

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin.toggle()
                    }
                }

            Toggle("Automatically check for updates", isOn: $autoUpdate)
                .onChange(of: autoUpdate) { _, on in
                    container.updater.automaticallyChecks = on
                }

            Button("Check for updates now") {
                container.updater.checkForUpdates()
            }

            Button("Rebuild index (relaunch required)") {
                Task {
                    await container.rebuildIndex()
                    NSApp.terminate(nil)
                }
            }

            Button("Open data folder") {
                let url = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("claude-stats")
                NSWorkspace.shared.open(url)
            }

            Spacer()

            HStack {
                Spacer()
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, height: 280)
    }
}
```

Three changes:
1. New `@State private var autoUpdate` initialized from the container's current value (init replaces the implicit memberwise init).
2. New Toggle and Button for updates.
3. Frame height grew from 220 → 280 to accommodate the new controls.

- [ ] **Step 2: Build and run tests**

Run: `swift test 2>&1 | tail -10`

Expected: all tests pass.

- [ ] **Step 3: Smoke check via swift run (optional manual)**

Run: `swift run claude-stats` and (if you have time) open the Settings window from the menubar popover. Verify the new toggle and button render; click "Check for updates now" — without a real `SUPublicEDKey` and SUFeedURL pointing at a non-existent appcast yet, Sparkle will quickly fail and log to Console.app, but the UI should not crash.

Press `Ctrl-C` to stop the dev run.

This is optional because the appcast doesn't exist yet — failure is expected. The visual layout check is the main value.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStats/Views/SettingsView.swift
git commit -m "settings: add auto-update toggle and 'Check now' button"
```

---

### Task 7: Refactor build.sh to accept VERSION

**Files:**
- Modify: `scripts/build.sh`

- [ ] **Step 1: Replace the build script**

Replace the entire contents of `scripts/build.sh` with:

```bash
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
```

Three substantive changes vs. the old script:
1. `VERSION` resolved from env or `git describe`.
2. PlistBuddy writes `CFBundleShortVersionString` and `CFBundleVersion` after the Info.plist is copied.
3. Codesign step comment clarified that CI re-runs it after injecting the public key.

- [ ] **Step 2: Run the script locally with current tag**

Run: `./scripts/build.sh 2>&1 | tail -5`

Expected output ends with `Built ClaudeStats.app at version 1.0.3` (or whatever the most recent local tag is).

- [ ] **Step 3: Verify the version landed in the bundled Info.plist**

Run: `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ClaudeStats.app/Contents/Info.plist`

Expected: `1.0.3` (matches the tag, not `1.0.0` which was the stale checked-in value).

- [ ] **Step 4: Verify the artifact is ad-hoc signed**

Run: `codesign -dv ClaudeStats.app 2>&1 | grep -E 'Authority|Identifier'`

Expected: `Authority=(adhoc)` and `Identifier=ClaudeStats` (or similar — the key signal is `adhoc`).

- [ ] **Step 5: Clean up the local build artifact**

Run: `rm -rf ClaudeStats.app`

- [ ] **Step 6: Commit**

```bash
git add scripts/build.sh
git commit -m "build: derive version from tag and inject via PlistBuddy"
```

---

### Task 8: make-appcast.sh + golden file test

**Files:**
- Create: `scripts/make-appcast.sh`
- Create: `Tests/ClaudeStatsTests/Fixtures/releases-sample.json`
- Create: `Tests/ClaudeStatsTests/Fixtures/appcast-expected.xml`
- Create: `Tests/ClaudeStatsTests/AppcastGenerationTests.swift`

- [ ] **Step 1: Write the fixture JSON**

Create `Tests/ClaudeStatsTests/Fixtures/releases-sample.json` with a representative shape of the `gh api repos/.../releases` response. The script will pick the newest release that has a `ClaudeStats.zip` asset:

```json
[
  {
    "tag_name": "v1.0.4",
    "name": "v1.0.4 — auto-update",
    "html_url": "https://github.com/jappyjan/claude-stats/releases/tag/v1.0.4",
    "published_at": "2026-05-12T10:00:00Z",
    "assets": [
      {
        "name": "ClaudeStats.zip",
        "browser_download_url": "https://github.com/jappyjan/claude-stats/releases/download/v1.0.4/ClaudeStats.zip",
        "size": 3000000
      },
      {
        "name": "ClaudeStats.dmg",
        "browser_download_url": "https://github.com/jappyjan/claude-stats/releases/download/v1.0.4/ClaudeStats.dmg",
        "size": 3500000
      }
    ]
  },
  {
    "tag_name": "v1.0.3",
    "name": "v1.0.3 — full-bleed app icon",
    "html_url": "https://github.com/jappyjan/claude-stats/releases/tag/v1.0.3",
    "published_at": "2026-05-11T08:44:20Z",
    "assets": [
      {
        "name": "ClaudeStats.dmg",
        "browser_download_url": "https://github.com/jappyjan/claude-stats/releases/download/v1.0.3/ClaudeStats.dmg",
        "size": 2769644
      }
    ]
  }
]
```

- [ ] **Step 2: Write the expected appcast (golden file)**

Create `Tests/ClaudeStatsTests/Fixtures/appcast-expected.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClaudeStats</title>
    <link>https://jappyjan.github.io/claude-stats/appcast.xml</link>
    <description>Most recent ClaudeStats release.</description>
    <language>en</language>
    <item>
      <title>v1.0.4 — auto-update</title>
      <pubDate>2026-05-12T10:00:00Z</pubDate>
      <sparkle:version>1.0.4</sparkle:version>
      <sparkle:shortVersionString>1.0.4</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/jappyjan/claude-stats/releases/tag/v1.0.4</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/jappyjan/claude-stats/releases/download/v1.0.4/ClaudeStats.zip" sparkle:edSignature="TEST_SIGNATURE_BASE64" length="3000000" type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

Only the newest release with a `.zip` asset becomes an `<item>`. The `v1.0.3` release in the fixture has no zip, so it's filtered out.

- [ ] **Step 3: Write the appcast script**

Create `scripts/make-appcast.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Generates a Sparkle appcast.xml from a list of GitHub releases (stdin JSON)
# plus the EdDSA signature of the current release's ZIP (env vars).
#
# Usage:
#   SPARKLE_SIGNATURE='abc...=' SPARKLE_LENGTH=3000000 \
#       ./scripts/make-appcast.sh < releases.json > appcast.xml
#
# stdin: the response body of `gh api repos/<owner>/<repo>/releases`
#        (a JSON array sorted newest-first by GitHub's API).
# env SPARKLE_SIGNATURE: EdDSA signature of ClaudeStats.zip, base64 (no XML
#        attribute syntax — just the bare value).
# env SPARKLE_LENGTH: byte size of ClaudeStats.zip.
#
# Output: appcast.xml on stdout, with exactly one <item> — the newest
#         release that has a ClaudeStats.zip asset. Older releases are
#         filtered because we don't keep their EdDSA signatures around.

: "${SPARKLE_SIGNATURE:?must be set}"
: "${SPARKLE_LENGTH:?must be set}"

JSON="$(cat)"

# Pick the newest release whose asset list contains ClaudeStats.zip.
# `jq -e` exits non-zero if no such release exists.
RELEASE="$(echo "$JSON" | jq -e '
    [.[] | select(.assets[].name == "ClaudeStats.zip")] | .[0]
')"

TAG="$(echo "$RELEASE" | jq -r '.tag_name')"
VERSION="${TAG#v}"
NAME="$(echo "$RELEASE" | jq -r '.name')"
HTML_URL="$(echo "$RELEASE" | jq -r '.html_url')"
PUBLISHED="$(echo "$RELEASE" | jq -r '.published_at')"
ZIP_URL="$(echo "$RELEASE" | jq -r '.assets[] | select(.name == "ClaudeStats.zip") | .browser_download_url')"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClaudeStats</title>
    <link>https://jappyjan.github.io/claude-stats/appcast.xml</link>
    <description>Most recent ClaudeStats release.</description>
    <language>en</language>
    <item>
      <title>${NAME}</title>
      <pubDate>${PUBLISHED}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${HTML_URL}</sparkle:releaseNotesLink>
      <enclosure url="${ZIP_URL}" sparkle:edSignature="${SPARKLE_SIGNATURE}" length="${SPARKLE_LENGTH}" type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
```

- [ ] **Step 4: Make the script executable**

Run: `chmod +x scripts/make-appcast.sh`

- [ ] **Step 5: Smoke-run the script with the fixture**

Run:
```bash
SPARKLE_SIGNATURE='TEST_SIGNATURE_BASE64' SPARKLE_LENGTH=3000000 \
    ./scripts/make-appcast.sh < Tests/ClaudeStatsTests/Fixtures/releases-sample.json
```

Expected: stdout matches `Tests/ClaudeStatsTests/Fixtures/appcast-expected.xml` byte-for-byte (after trimming surrounding whitespace).

If there's a mismatch, update one of the two files until they match — both are checked-in artifacts and the golden file is the spec.

- [ ] **Step 6: Write the failing test**

Create `Tests/ClaudeStatsTests/AppcastGenerationTests.swift`:

```swift
import XCTest

final class AppcastGenerationTests: XCTestCase {
    func test_makeAppcast_matchesGolden() throws {
        let bundle = Bundle.module
        guard
            let fixtureURL = bundle.url(forResource: "releases-sample", withExtension: "json"),
            let goldenURL = bundle.url(forResource: "appcast-expected", withExtension: "xml")
        else {
            XCTFail("fixtures not found in test bundle")
            return
        }

        let fixture = try Data(contentsOf: fixtureURL)
        let expected = try String(contentsOf: goldenURL, encoding: .utf8)
        let scriptURL = try Self.projectRoot()
            .appendingPathComponent("scripts/make-appcast.sh")

        let stdin = Pipe()
        let stdout = Pipe()
        let process = Process()
        process.executableURL = scriptURL
        process.standardInput = stdin
        process.standardOutput = stdout
        var env = ProcessInfo.processInfo.environment
        env["SPARKLE_SIGNATURE"] = "TEST_SIGNATURE_BASE64"
        env["SPARKLE_LENGTH"] = "3000000"
        process.environment = env

        try process.run()
        stdin.fileHandleForWriting.write(fixture)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "script exited non-zero")
        let actual = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(
            actual.trimmingCharacters(in: .whitespacesAndNewlines),
            expected.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Walk up from this source file until we find a directory containing Package.swift.
    private static func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        struct ProjectRootNotFound: Error {}
        throw ProjectRootNotFound()
    }
}
```

- [ ] **Step 7: Run the test, expect pass**

Run: `swift test --filter AppcastGenerationTests 2>&1 | tail -10`

Expected: test passes.

If it fails on `jq: command not found`, install jq first: `brew install jq`. (CI runners on `macos-14` have jq preinstalled.)

- [ ] **Step 8: Run full test suite**

Run: `swift test 2>&1 | tail -10`

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add scripts/make-appcast.sh \
    Tests/ClaudeStatsTests/Fixtures/releases-sample.json \
    Tests/ClaudeStatsTests/Fixtures/appcast-expected.xml \
    Tests/ClaudeStatsTests/AppcastGenerationTests.swift
git commit -m "build: add make-appcast.sh and golden-file test"
```

---

### Task 9: GitHub Actions release.yml workflow

**Files:**
- Create: `.github/workflows/release.yml`

This task is the CI pipeline. It cannot be unit-tested — the test is "push a tag and watch the action succeed". Before this task lands, the maintainer must (per `docs/RELEASING.md`, written in Task 10):
1. Generate an EdDSA keypair using Sparkle's `generate_keys` tool.
2. Add `SPARKLE_PRIVATE_KEY` and `SPARKLE_PUBLIC_KEY` as repo secrets.
3. Create an empty `gh-pages` branch and enable GitHub Pages → "Deploy from branch" → `gh-pages` → `/(root)`.

The workflow assumes all three are done before the first tag is pushed.

- [ ] **Step 1: Create the workflow directory**

Run: `mkdir -p .github/workflows`

- [ ] **Step 2: Create the workflow file**

Create `.github/workflows/release.yml`. Step order matters: upload the release assets BEFORE generating the appcast, because the appcast step calls the GitHub releases API to enumerate published releases, and the just-built release must already be there.

```yaml
name: Release

on:
  push:
    tags: ['v*.*.*']

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-14
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0   # so build.sh's `git describe` fallback works

      - name: Extract version from tag
        id: ver
        run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Install create-dmg
        run: brew install create-dmg

      - name: Build .app (release)
        env:
          VERSION: ${{ steps.ver.outputs.VERSION }}
        run: ./scripts/build.sh

      - name: Inject Sparkle public key into Info.plist
        env:
          SPARKLE_PUBLIC_KEY: ${{ secrets.SPARKLE_PUBLIC_KEY }}
        run: |
          /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY" \
            ClaudeStats.app/Contents/Info.plist
          # Re-codesign because we just modified Info.plist.
          codesign --force --deep --sign - ClaudeStats.app

      - name: Build ClaudeStats.dmg (user-facing download)
        run: ./scripts/build-dmg.sh

      - name: Build ClaudeStats.zip (Sparkle update artifact)
        run: ditto -c -k --sequesterRsrc --keepParent ClaudeStats.app ClaudeStats.zip

      - name: Sign update with Sparkle EdDSA key
        id: sign
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          # Write private key to a temp file with restrictive perms; clean up on exit.
          KEYFILE="$(mktemp)"
          chmod 600 "$KEYFILE"
          trap 'rm -f "$KEYFILE"' EXIT
          printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"

          # Sparkle ships sign_update as an executable inside the SPM checkout
          # cache after `swift build` resolved Sparkle. Find it.
          SIGN_UPDATE="$(find .build -name sign_update -type f -perm +111 | head -1)"
          if [ -z "$SIGN_UPDATE" ]; then
            echo "::error::sign_update binary not found under .build/" >&2
            exit 1
          fi

          # sign_update emits something like:
          #   sparkle:edSignature="abc...=" length="3000000"
          # Parse the values out so we can pass them as env vars to make-appcast.sh.
          ATTRS="$("$SIGN_UPDATE" -f "$KEYFILE" ClaudeStats.zip)"
          SIG="$(echo "$ATTRS" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
          LEN="$(echo "$ATTRS" | sed -E 's/.*length="([^"]+)".*/\1/')"

          echo "SIG=$SIG" >> "$GITHUB_OUTPUT"
          echo "LEN=$LEN" >> "$GITHUB_OUTPUT"

      - name: Upload release assets
        uses: softprops/action-gh-release@v2
        with:
          files: |
            ClaudeStats.dmg
            ClaudeStats.zip
          generate_release_notes: true

      - name: Generate appcast.xml
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SPARKLE_SIGNATURE: ${{ steps.sign.outputs.SIG }}
          SPARKLE_LENGTH: ${{ steps.sign.outputs.LEN }}
        run: |
          mkdir -p public
          # The release we just uploaded is visible to the API now.
          gh api "repos/${GITHUB_REPOSITORY}/releases" --paginate \
            | jq -s 'add' \
            | ./scripts/make-appcast.sh > public/appcast.xml
          # Minimal landing page so the GH Pages root isn't a 404.
          cat > public/index.html <<HTML
          <!doctype html><meta charset="utf-8"><title>ClaudeStats</title>
          <body><a href="https://github.com/${GITHUB_REPOSITORY}">ClaudeStats on GitHub</a></body>
          HTML

      - name: Publish appcast.xml to gh-pages
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./public
          keep_files: false
```

- [ ] **Step 3: Lint the workflow with `actionlint` if available, else with plain YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "YAML OK"`

Expected: `YAML OK`. (`actionlint` is nicer but not always installed.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: tag-triggered release pipeline with Sparkle signing"
```

---

### Task 10: docs/RELEASING.md

**Files:**
- Create: `docs/RELEASING.md`

- [ ] **Step 1: Write the doc**

Create `docs/RELEASING.md`:

```markdown
# Releasing ClaudeStats

Releases are produced entirely by CI from a tag push. The maintainer never
runs `swift build` for distribution.

## One-time setup (do this once for the lifetime of the repo)

1. **Generate the Sparkle EdDSA keypair.** Sparkle ships a `generate_keys`
   tool inside its SPM artifacts. After `swift build` resolves Sparkle, run:

       SIGN_DIR=$(find .build -name sign_update -type f -perm +111 | head -1 | xargs dirname)
       "$SIGN_DIR/generate_keys"

   It stores the private key in the macOS Keychain and prints the public
   key (base64) to stdout. Export the private key:

       "$SIGN_DIR/generate_keys" -p > /tmp/sparkle-pub.txt  # public
       "$SIGN_DIR/generate_keys" -x /tmp/sparkle-priv.txt   # export private

   Keep both files private. The private key never enters the repo.

2. **Add the GitHub repo secrets** (Settings → Secrets and variables →
   Actions → New repository secret):

   - `SPARKLE_PRIVATE_KEY` — contents of `/tmp/sparkle-priv.txt`
   - `SPARKLE_PUBLIC_KEY` — contents of `/tmp/sparkle-pub.txt` (single
     line, base64, no quotes)

3. **Create an empty `gh-pages` branch** for the appcast:

       git switch --orphan gh-pages
       git commit --allow-empty -m "init gh-pages"
       git push -u origin gh-pages
       git switch main

4. **Enable GitHub Pages** in Settings → Pages → "Deploy from a branch"
   → Branch: `gh-pages`, Folder: `/ (root)`. Wait ~1 minute, then verify
   `https://jappyjan.github.io/claude-stats/` loads (404 is fine until the
   first release runs; we just need Pages to be enabled).

5. **Delete the temp key files** from disk:

       shred -u /tmp/sparkle-priv.txt /tmp/sparkle-pub.txt 2>/dev/null \
         || rm /tmp/sparkle-priv.txt /tmp/sparkle-pub.txt

## Per-release procedure

That's the whole procedure:

    git tag v1.0.4
    git push --tags

CI does the rest: builds the `.app`, codesigns ad-hoc, builds the DMG and
ZIP, signs the ZIP with the Sparkle EdDSA key, uploads release assets,
generates the appcast, and pushes the appcast to `gh-pages`. Users on the
prior Sparkle-equipped version receive the standard Sparkle prompt within
24 hours.

## When something goes wrong

- **Workflow failed mid-run, before any asset uploaded.** Safe to delete
  the tag (`git tag -d v1.0.4 && git push --delete origin v1.0.4`), fix
  the issue, and re-tag.

- **Workflow failed AFTER asset upload but before appcast push.** The
  release exists on GitHub but no users see it (appcast still references
  the previous release). Re-run the failed job from the Actions UI — both
  upload and appcast steps are idempotent.

- **Sparkle prompt doesn't appear on user's machine.** Check
  Console.app for messages starting with "Sparkle" — most common causes
  are: SUFeedURL pointing somewhere wrong, EdDSA public key in Info.plist
  doesn't match the signing key, or GitHub Pages not yet serving the new
  appcast (DNS / CDN propagation can take a few minutes).
```

- [ ] **Step 2: Commit**

```bash
git add docs/RELEASING.md
git commit -m "docs: maintainer release procedure for Sparkle pipeline"
```

---

### Task 11: README touch-up

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add an "Updates" section**

In `README.md`, find the existing `## Pricing` section. Insert an `## Updates` section just before it:

Before:
```markdown
## Pricing

Pulled from [LiteLLM's community pricing JSON]...
```

After:
```markdown
## Updates

The app checks for new releases once a day via [Sparkle](https://sparkle-project.org/).
When a new version is available, you'll see a prompt with release notes and
an Install button. You can disable automatic checks from
**Settings → Automatically check for updates** at any time; the "Check for
updates now" button still works regardless.

## Pricing

Pulled from [LiteLLM's community pricing JSON]...
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document auto-update behavior and opt-out"
```

---

## After all tasks

The branch now contains every piece needed for the first auto-update release. The next physical step is bumping a tag — but that triggers CI, which is out of scope for this plan. Per `docs/RELEASING.md`:

1. Push this branch / merge to main.
2. Complete the one-time setup (EdDSA keys, secrets, gh-pages branch, Pages enablement).
3. `git tag v1.0.4 && git push --tags` to ship the first Sparkle-equipped release.
4. After CI succeeds, install the new DMG manually to test (`xattr -dr com.apple.quarantine`, then open).
5. Tag `v1.0.5` (any small change) and verify the in-app prompt appears when you click "Check for updates now" in v1.0.4.

These steps are documented in `docs/RELEASING.md` and don't belong in the implementation plan.
