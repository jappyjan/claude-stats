# Resizable Menu Bar Popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user drag the menu bar popover's lower border to change its height, with the chosen value persisted across app restarts via `@AppStorage`.

**Architecture:** Move height ownership from `ClaudeStatsApp.swift` (currently a hard-coded `.frame(maxHeight: 480)`) into `PopoverView.swift` as a `@AppStorage("popoverHeight")` `Double`. Append a 6pt transparent drag strip at the bottom of `PopoverView`'s outer `VStack` that hosts a `DragGesture` updating the stored height (clamped 240–1000pt) and an `.onHover` modifier that flips `NSCursor.resizeUpDown` on hover.

**Tech Stack:** SwiftUI (`MenuBarExtra` window style, `@AppStorage`, `DragGesture`, `.onHover`), AppKit (`NSCursor.resizeUpDown`).

---

## File Structure

**Modified files:**
- `Sources/ClaudeStats/App/ClaudeStatsApp.swift` — drop `.frame(maxHeight: 480)` from the `MenuBarExtra` content; height is now owned by `PopoverView`.
- `Sources/ClaudeStats/App/PopoverView.swift` — add `@AppStorage("popoverHeight")` and `@State` for drag baseline, apply `.frame(height:)` to the outer VStack, change `.padding(.vertical, 4)` to `.padding(.top, 4)` so the drag strip sits flush against the bottom edge, append a `resizeHandle` view as the last child of the VStack.

No new files. No tests — this is a UI gesture feature with no business logic; the spec explicitly designates verification as manual.

---

## Task 1: Move popover height ownership into `PopoverView`

This is a no-visible-functional-change refactor that unblocks Task 2. After this commit, the popover still opens at 480pt (the default), but the height is now controlled by an `@AppStorage` value owned by `PopoverView` instead of a hard-coded frame in `ClaudeStatsApp`.

**Files:**
- Modify: `Sources/ClaudeStats/App/ClaudeStatsApp.swift` (lines 8–11)
- Modify: `Sources/ClaudeStats/App/PopoverView.swift` (lines 4–14, 23–95)

- [ ] **Step 1.1: Drop the height cap from `ClaudeStatsApp.swift`**

In `Sources/ClaudeStats/App/ClaudeStatsApp.swift`, locate the `MenuBarExtra` content block (lines 8–11):

```swift
        MenuBarExtra {
            PopoverView(viewModel: container.viewModel, container: container)
                .frame(width: 380)
                .frame(maxHeight: 480)
        } label: {
```

Remove the `.frame(maxHeight: 480)` line. The block becomes:

```swift
        MenuBarExtra {
            PopoverView(viewModel: container.viewModel, container: container)
                .frame(width: 380)
        } label: {
```

- [ ] **Step 1.2: Add `@AppStorage` and `@State` properties to `PopoverView`**

In `Sources/ClaudeStats/App/PopoverView.swift`, locate the existing property declarations (lines 5–14):

```swift
    @Bindable var viewModel: StatsViewModel
    let container: AppContainer
    @State private var section: Section = .overview
    @State private var drillProjectKey: String? = nil
    @State private var drillDetail: StatsViewModel.ProjectDetail? = nil
    @State private var drillMonth: MonthSelection? = nil
    @State private var drillMonthDetail: StatsViewModel.MonthDetail? = nil
    @State private var showExport: Bool = false
    @AppStorage("monthsBreakdown") private var monthsBreakdown: MonthsBreakdown = .total
    @Environment(\.openWindow) private var openWindow
```

After the `@AppStorage("monthsBreakdown")` line and before `@Environment(\.openWindow)`, add two new properties:

```swift
    @AppStorage("popoverHeight") private var popoverHeight: Double = 480
    @State private var dragStartHeight: Double? = nil
```

The property block becomes:

```swift
    @Bindable var viewModel: StatsViewModel
    let container: AppContainer
    @State private var section: Section = .overview
    @State private var drillProjectKey: String? = nil
    @State private var drillDetail: StatsViewModel.ProjectDetail? = nil
    @State private var drillMonth: MonthSelection? = nil
    @State private var drillMonthDetail: StatsViewModel.MonthDetail? = nil
    @State private var showExport: Bool = false
    @AppStorage("monthsBreakdown") private var monthsBreakdown: MonthsBreakdown = .total
    @AppStorage("popoverHeight") private var popoverHeight: Double = 480
    @State private var dragStartHeight: Double? = nil
    @Environment(\.openWindow) private var openWindow
```

- [ ] **Step 1.3: Apply the stored height to the body's outer VStack, and switch vertical padding to top-only**

In `Sources/ClaudeStats/App/PopoverView.swift`, locate the end of the `var body: some View` block (lines 93–95):

```swift
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .padding(.vertical, 4)
    }
```

(Note: the `.padding(.horizontal, 14).padding(.vertical, 6)` belongs to the footer `HStack` — leave it untouched. We are changing only the outer `.padding(.vertical, 4)` on the body's VStack.)

Change `.padding(.vertical, 4)` to `.padding(.top, 4)` and append `.frame(height: popoverHeight)`. The tail of the body becomes:

```swift
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .padding(.top, 4)
        .frame(height: popoverHeight)
    }
```

The bottom-edge padding is dropped intentionally so the drag strip added in Task 2 sits flush against the popover's true bottom edge. The body's VStack now has a fixed height equal to `popoverHeight`.

- [ ] **Step 1.4: Build to verify the refactor compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

If the build fails with `'Double' is not convertible to ...` on the `.frame(height:)` line: SwiftUI's `.frame(height:)` takes `CGFloat?`. Convert explicitly: `.frame(height: CGFloat(popoverHeight))`. (Usually unnecessary because `Double` bridges to `CGFloat` on 64-bit Apple platforms, but worth noting.)

- [ ] **Step 1.5: Commit**

```bash
git add Sources/ClaudeStats/App/ClaudeStatsApp.swift Sources/ClaudeStats/App/PopoverView.swift
git commit -m "$(cat <<'EOF'
popover: move height ownership into PopoverView

Drop the hard-coded .frame(maxHeight: 480) from ClaudeStatsApp and
replace it with @AppStorage("popoverHeight") on PopoverView so the next
commit can let the user drag the bottom edge to resize. No user-visible
change yet — the popover still opens at 480pt.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the drag-to-resize handle

Adds the user-visible feature: a 6pt transparent drag strip at the bottom of the popover that resizes the window via vertical drag, with the cursor flipping to `resizeUpDown` on hover.

**Files:**
- Modify: `Sources/ClaudeStats/App/PopoverView.swift` (import statements, body VStack tail, new private view)

- [ ] **Step 2.1: Insert the `resizeHandle` view as the last child of the body's VStack**

In `Sources/ClaudeStats/App/PopoverView.swift`, find the closing of the footer `HStack` inside `var body`:

```swift
            HStack {
                Text("\(viewModel.overview.projectCount) project\(viewModel.overview.projectCount == 1 ? "" : "s") · \(viewModel.overview.sessionCount) session\(viewModel.overview.sessionCount == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: { openWindow(id: "settings") }) {
                    Image(systemName: "gearshape").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit ClaudeStats")
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .padding(.top, 4)
        .frame(height: popoverHeight)
    }
```

Immediately after the footer `HStack`'s closing `}` and its trailing `.padding(.horizontal, 14).padding(.vertical, 6)` modifier, but BEFORE the outer VStack's closing `}`, insert a reference to `resizeHandle`:

```swift
            HStack {
                Text("\(viewModel.overview.projectCount) project\(viewModel.overview.projectCount == 1 ? "" : "s") · \(viewModel.overview.sessionCount) session\(viewModel.overview.sessionCount == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: { openWindow(id: "settings") }) {
                    Image(systemName: "gearshape").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit ClaudeStats")
            }
            .padding(.horizontal, 14).padding(.vertical, 6)

            resizeHandle
        }
        .padding(.top, 4)
        .frame(height: popoverHeight)
    }
```

- [ ] **Step 2.2: Add the `resizeHandle` private computed view**

In `Sources/ClaudeStats/App/PopoverView.swift`, locate the `sectionTabs` private computed view (around lines 110–126). Immediately after the closing `}` of `sectionTabs` and before `private func formatTokens(...)`, insert the `resizeHandle` property:

```swift
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(height: 6)
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = popoverHeight }
                        let proposed = (dragStartHeight ?? popoverHeight) + value.translation.height
                        popoverHeight = min(1000, max(240, proposed))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }
```

Notes for the implementer:
- `contentShape(Rectangle())` makes the transparent rectangle hit-testable; without it, `Color.clear` does not catch hovers or drags.
- `DragGesture(minimumDistance: 0)` triggers on a click-down (matching macOS resize behavior — no need to "drag a bit" before the resize begins).
- `dragStartHeight` is captured on the first `onChanged` of each drag and reset on `onEnded`. This is what makes the drag stable — without it, every `onChanged` would re-apply the cumulative translation against an already-updated baseline, causing the popover to "fly away" exponentially.
- `NSCursor.resizeUpDown.push()` / `.pop()` are AppKit calls. `NSCursor` is already in scope because line 2 of this file is `import AppKit`.

- [ ] **Step 2.3: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 2.4: Commit**

```bash
git add Sources/ClaudeStats/App/PopoverView.swift
git commit -m "$(cat <<'EOF'
popover: add drag-to-resize handle at the bottom edge

A 6pt transparent strip at the bottom of the popover catches a
DragGesture and updates the @AppStorage-backed popoverHeight,
clamped to 240-1000pt. The cursor flips to NSCursor.resizeUpDown
on hover.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Manual verification

This is a UI gesture feature with no business logic. Verify by exercising the popover in the running app.

**Files:** none modified.

- [ ] **Step 3.1: Wipe any stale `popoverHeight` from `UserDefaults`**

So that the first launch reflects the default (480pt) rather than a value left by a developer's earlier hand-testing:

Run: `defaults delete de.janjaap.claude-stats popoverHeight 2>/dev/null || true`

(Bundle id taken from `Sources/ClaudeStats/Info.plist`; the command is a no-op if the key isn't set, which is fine.)

- [ ] **Step 3.2: Build and launch the app**

Run: `bash scripts/build.sh && open ClaudeStats.app`

Expected: app launches, a menu bar icon appears showing today's token count.

- [ ] **Step 3.3: Verify initial height**

Click the menu bar icon. Expected: popover opens at ~480pt tall (the default).

- [ ] **Step 3.4: Verify cursor hover**

Move the mouse to the bottom ~6pt of the popover. Expected: cursor changes to the vertical-resize cursor (two arrows pointing up/down).

- [ ] **Step 3.5: Verify drag resize**

Drag the bottom edge downward. Expected: popover grows smoothly. Drag upward. Expected: popover shrinks smoothly.

- [ ] **Step 3.6: Verify bounds clamping**

Drag the bottom edge as far down as possible. Expected: popover stops growing at ~1000pt; further drag has no effect. Drag as far up as possible. Expected: popover stops shrinking at ~240pt.

- [ ] **Step 3.7: Verify persistence across popover close/reopen**

Resize the popover to a noticeably non-default height (e.g., ~700pt). Click elsewhere on screen so the popover closes. Click the menu bar icon again. Expected: popover reopens at the chosen height.

- [ ] **Step 3.8: Verify persistence across app quit/relaunch**

Quit the app (cmd-Q or the power button in the popover footer). Re-launch with `open ClaudeStats.app`. Click the menu bar icon. Expected: popover opens at the height chosen in step 3.7.

- [ ] **Step 3.9: Verify navigation does not reset height**

With the popover open at the chosen height, switch between Overview / Projects / Months tabs. Expected: height does not change. Drill into a project row, then back. Expected: height does not change. Drill into a month, then back. Expected: height does not change.

- [ ] **Step 3.10: Verify content scrolls correctly at small heights**

Resize to ~240pt. Expected: section content scrolls within its `ScrollView`; status row, limits bar, tabs, and footer remain visible (not clipped).

If any step fails, fix it before declaring the feature complete. Common failure modes:
- Popover does not resize at all → check that `.frame(height: popoverHeight)` is applied to the body's VStack and that `dragStartHeight` is being captured on first `onChanged`.
- Popover snaps back to 480 on next open → check that `@AppStorage("popoverHeight")` is being read (typo in the key would silently fall back to the default).
- Cursor does not change → check that `contentShape(Rectangle())` is on the resize handle; `Color.clear` alone is not hit-testable.
- Drag feels jittery / runs away → check the `dragStartHeight` logic; if it's reset on every `onChanged`, translations compound.
