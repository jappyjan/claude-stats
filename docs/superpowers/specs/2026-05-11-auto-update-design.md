# Auto-update via Sparkle + GitHub Actions

Date: 2026-05-11
Status: Approved

## Goal

ClaudeStats users automatically receive new releases. They can opt out from
the app's Settings window. Releases are produced entirely by CI from a git
tag push — no local build, no manual asset upload.

## Success criteria

- Pushing `git tag v1.0.4 && git push --tags` results, with no further human
  action, in:
  - a GitHub Release at `v1.0.4` containing `ClaudeStats.dmg` and
    `ClaudeStats.zip`
  - an updated `appcast.xml` on `gh-pages` referencing the new ZIP and its
    EdDSA signature
  - users on the previous Sparkle-equipped version seeing Sparkle's standard
    "ClaudeStats 1.0.4 is available" prompt within 24 hours
- A user who toggles "Automatically check for updates" off in Settings
  receives no update prompts and no background update checks until they
  re-enable it.
- A user who clicks "Check for updates now" gets a result regardless of the
  toggle state (manual checks always work).
- Version displayed in the popover, version in `Info.plist`, and the git tag
  the binary was built from are always identical (no manual sync).

## Non-goals

- Apple Developer ID signing / notarization. Ad-hoc signing continues; users
  still see "damaged" on first launch and run the documented `xattr` once.
  Notarization can be added later without redesigning the update flow.
- Delta updates (Sparkle supports them; ~3x CI complexity for marginal
  benefit at this app size).
- Beta / pre-release channel. Only `v*.*.*` tags trigger releases.
- Rollback. If a release is bad, ship a higher version. Sparkle has no
  built-in rollback.
- Auto-bumping the version from commit messages (release-please etc.).
  Version source of truth is the git tag the maintainer pushes.

## Architecture

```
┌─ Developer ────────────────┐    ┌─ GitHub macos-14 runner ────────────────┐
│ git tag v1.0.4             │ →  │ release.yml triggered by tag push       │
│ git push --tags            │    │  1. swift build -c release              │
└────────────────────────────┘    │  2. Inject version + Sparkle pubkey     │
                                  │     into Info.plist via PlistBuddy      │
                                  │  3. Ad-hoc codesign .app                │
                                  │  4. create-dmg → ClaudeStats.dmg        │
                                  │  5. ditto → ClaudeStats.zip             │
                                  │  6. sign_update (Sparkle) → EdDSA sig   │
                                  │  7. make-appcast.sh → appcast.xml       │
                                  │  8. softprops/action-gh-release         │
                                  │  9. peaceiris/actions-gh-pages          │
                                  └─────────────────┬───────────────────────┘
                                                    │
                          ┌─────────────────────────┴─────────────────────┐
                          ▼                                               ▼
            jappyjan.github.io/claude-stats/                github.com/.../releases/v1.0.4
                       appcast.xml                          ClaudeStats.dmg, ClaudeStats.zip
                          │
                          │  HTTPS, daily check
                          ▼
            ┌─ ClaudeStats.app on user's Mac ─┐
            │ SPUStandardUpdaterController     │
            │  reads SUFeedURL from Info.plist │
            │  verifies EdDSA signature        │
            │  prompts user to install         │
            │ Settings: opt-out toggle         │
            └──────────────────────────────────┘
```

## Components

### New: `Sources/ClaudeStats/Updates/UpdaterController.swift`

Owns a `SPUStandardUpdaterController` and exposes a minimal Swift surface
for the rest of the app (a Bool toggle and a `checkForUpdates()` call).
Sparkle persists the toggle to `UserDefaults` under its own key — no
additional storage code.

```swift
@MainActor
final class UpdaterController: ObservableObject {
    let updater: SPUStandardUpdaterController

    init() {
        self.updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecks: Bool {
        get { updater.updater.automaticallyChecksForUpdates }
        set { updater.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { updater.checkForUpdates(nil) }
}
```

### Modified: `Sources/ClaudeStats/App/AppContainer.swift`

One new property: `let updater = UpdaterController()`. Created during init
so Sparkle's scheduler starts immediately.

### Modified: `Sources/ClaudeStats/Views/SettingsView.swift`

- Replace hardcoded `Text("v1.0.3")` with
  `Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))`.
- Add a "Updates" section above the existing "Launch at login" toggle:
  - `Toggle("Automatically check for updates", isOn: $autoUpdate)`
  - `Button("Check for updates now")` — always enabled regardless of toggle
    (matches common Mac convention; toggle controls automatic checks only).

### Modified: `Sources/ClaudeStats/Info.plist`

Add Sparkle keys:

```xml
<key>SUFeedURL</key>
<string>https://jappyjan.github.io/claude-stats/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>PLACEHOLDER_REPLACED_BY_CI</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

`SUPublicEDKey` is a placeholder string committed to the repo. CI replaces
it with the actual public key (also a repo secret) via PlistBuddy before
codesigning. The private counterpart never enters the repo.

`CFBundleShortVersionString` and `CFBundleVersion` are also rewritten by CI
to the tag's version.

### Modified: `Package.swift`

Add Sparkle 2 as a SwiftPM dependency:

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
],
targets: [
    .executableTarget(
        name: "ClaudeStats",
        dependencies: [.product(name: "Sparkle", package: "Sparkle")],
        exclude: ["Info.plist", "Resources"]
    ),
    ...
]
```

### Modified: `scripts/build.sh`

Accept `VERSION` from the environment (defaults to `git describe --tags
--abbrev=0 | sed 's/^v//'` for local builds). After copying `Info.plist`
into the `.app`, use PlistBuddy to write `CFBundleShortVersionString` and
`CFBundleVersion` from `$VERSION`. Codesign step stays as-is.

This keeps local and CI builds using the same script — the only difference
is whether `VERSION` is exported by the caller or derived from `git`.

### New: `scripts/make-appcast.sh`

Reads a JSON list of releases from **stdin** (so tests can pipe a fixture;
CI pipes `gh api repos/jappyjan/claude-stats/releases`). Emits
`appcast.xml` to stdout with one `<item>` per release. Each item carries:

- `<title>` from release name
- `<sparkle:version>` and `<sparkle:shortVersionString>` from tag (stripped
  `v` prefix)
- `<sparkle:releaseNotesLink>` to the GitHub release HTML page (so
  Sparkle's prompt shows GitHub-rendered notes inline)
- `<enclosure>` pointing to that release's `ClaudeStats.zip` with
  `sparkle:edSignature` and `length` from `sign_update`'s output

Writes a tiny `public/index.html` alongside that just redirects to the
repo, so anyone hitting the GitHub Pages root doesn't get a 404.

### New: `.github/workflows/release.yml`

Trigger: `on: push: tags: ['v*.*.*']`. Single job on `macos-14`. Steps
ordered as in the architecture diagram above. Permissions:
`contents: write` for both the release upload and the gh-pages push.

Secrets consumed:
- `SPARKLE_PRIVATE_KEY` — base64 EdDSA private key, used only by
  `sign_update`. Written to a file from `mktemp` and deleted with `trap`
  on step exit so it doesn't survive a workflow failure.
- `SPARKLE_PUBLIC_KEY` — base64 EdDSA public key, used by PlistBuddy to
  populate `SUPublicEDKey`. Not technically secret (it ships in every
  binary) but storing it as a secret keeps it out of CI logs.

The Sparkle SPM dependency ships `sign_update` as a build artifact. CI
locates it under `.build/` after `swift build` has resolved dependencies
(`find .build -name sign_update -type f | head -1`).

### New: `docs/RELEASING.md`

Short maintainer doc covering the one-time setup (generate EdDSA keypair,
add the two GitHub secrets, enable GitHub Pages from `gh-pages` branch)
and the per-release procedure (`git tag vX.Y.Z && git push --tags` —
that's it).

## Data flow

**On every app launch (auto-update enabled):**

1. `AppContainer.init()` creates `UpdaterController`, which constructs
   `SPUStandardUpdaterController(startingUpdater: true, ...)`.
2. Sparkle reads `SUFeedURL` and `SUScheduledCheckInterval` from the
   bundle's `Info.plist`.
3. After a small randomized delay, Sparkle fetches the appcast over HTTPS.
4. If the newest `<item>`'s `sparkle:version` is greater than
   `CFBundleShortVersionString`, Sparkle downloads the enclosed ZIP.
5. Sparkle verifies the EdDSA signature against `SUPublicEDKey` baked
   into Info.plist.
6. Sparkle shows its standard update prompt with release notes loaded from
   `sparkle:releaseNotesLink`.
7. On accept, Sparkle quits the app, unzips the new `.app` over the
   running bundle, relaunches. (This works for ad-hoc signed apps; Sparkle
   does not require Developer ID.)

**On settings toggle off:**

Setting `automaticallyChecksForUpdates = false` causes Sparkle to skip
both scheduled and launch-time checks. Manual "Check now" still works
because it calls `checkForUpdates(nil)` directly, bypassing the toggle.

## Error handling

| Failure | Behavior |
|---|---|
| Appcast HTTP fetch fails | Sparkle silently retries at next interval. No UI. |
| Appcast XML malformed | Sparkle logs to Console.app, no UI. |
| Downloaded ZIP fails EdDSA verification | Sparkle aborts install, logs to Console.app, no install prompt shown. App stays on current version. |
| User cancels Sparkle's prompt | Sparkle marks that version as "skipped" for the user. Next version supersedes. |
| Disk full mid-download | Sparkle aborts cleanly, retries next interval. |
| CI's `sign_update` exits non-zero | Workflow fails before any release asset is uploaded. No partial release. |
| Tag pushed twice (re-run CI) | Both `softprops/action-gh-release@v2` and `peaceiris/actions-gh-pages@v4` are idempotent — assets replaced, appcast force-pushed. |

## Testing

- **Unit:** `Tests/ClaudeStatsTests/UpdaterControllerTests.swift` —
  toggling `automaticallyChecks` round-trips through `UserDefaults`. Don't
  test Sparkle internals (it has its own test suite).
- **Integration:** `Tests/ClaudeStatsTests/AppcastGenerationTests.swift` —
  feed `make-appcast.sh` a fixture JSON (a captured `gh api ... releases`
  response) plus a known signature; assert the emitted XML matches a
  checked-in golden file. Run via `Process` from XCTest.
- **CI smoke:** the `release.yml` workflow itself is the integration test
  for the build/sign/upload chain. First run after the spec is implemented
  is a release of v1.0.4 with one substantive change so we can observe
  in-app prompt behavior end-to-end.
- **Manual:** install v1.0.3 from the existing DMG, then install v1.0.4
  (the first Sparkle release) on top via DMG. Push a tag for v1.0.5 and
  verify the in-app prompt appears within an hour (after manually
  triggering "Check now" — daily-check timing isn't worth waiting for).

## Edge cases

| Case | Behavior |
|---|---|
| Auto-update off, new version available | Nothing happens. App stays put. |
| "Check now" with no update | Sparkle's "You're up to date" alert. |
| Network down during check | Silent retry next interval. |
| EdDSA signature mismatch | Abort install, log, no prompt. |
| Update prompt while popover open | Sparkle prompt is its own window — fine. |
| User on v1.0.3 (no Sparkle) | No auto-update. They grab next DMG manually from README link. Communicated in v1.0.4 release notes. |
| Tag pushed without code changes | CI builds anyway, version from tag, safe. |
| Tag without `v` prefix | Workflow doesn't trigger. By design. |
| Local `swift run` | Version reads `?`. Sparkle inert without bundle's Info.plist. |

## Prep work (Step 0 of the plan)

1. Switch from `t3code/8f3d7d49` to `main`, fast-forward to `origin/main`.
   Confirm clean tree.
2. Verify v1.0.3 release intact on GitHub.
3. `swift test` baseline green.

These steps gate all subsequent implementation tasks.

## Open questions

None at design approval. Any maintainer-side ambiguities (EdDSA key
storage location on the maintainer's machine, GitHub Pages enablement
mechanics) are covered in `docs/RELEASING.md`.
