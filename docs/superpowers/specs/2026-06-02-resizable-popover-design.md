# Resizable Menu Bar Popover

## Goal

Let the user change the height of the menu bar dropdown by dragging its lower
border. The chosen height persists across popover re-opens and app restarts.

## Current behavior

`ClaudeStatsApp.swift` declares the popover as:

```swift
PopoverView(viewModel: container.viewModel, container: container)
    .frame(width: 380)
    .frame(maxHeight: 480)
```

Width is fixed at 380pt. Height is capped at 480pt but can be smaller if the
content is shorter. Every section view (`OverviewView`, `ProjectsView`,
`MonthsView`, `ProjectDetailView`, `MonthDetailView`) already wraps its content
in a `ScrollView`, so a taller frame won't expose layout gaps and a shorter
frame won't clip content.

## Design

### Ownership of the height

Height becomes a `@AppStorage("popoverHeight")` `Double` defined inside
`PopoverView`. `ClaudeStatsApp.swift` drops `.frame(maxHeight: 480)` and keeps
only `.frame(width: 380)`. The outer `VStack` in `PopoverView` gets
`.frame(height: popoverHeight)`, applied **after** the existing padding so the
stored value represents the popover's total outer height.

The existing `.padding(.vertical, 4)` on the outer VStack becomes
`.padding(.top, 4)`. Without dropping the bottom 4pt, the drag strip would sit
4pt above the popover's true bottom edge, which is unergonomic.

Default value: **480pt** (matches today's cap, so existing users see no change
on first launch after the update).

Range: **240–1000pt**. Below 240pt the status row, limits bar, tabs, and a few
content rows can no longer all fit. Above 1000pt the popover exceeds a typical
laptop screen.

### The drag handle

A 6pt-tall transparent strip is appended as the last child of `PopoverView`'s
`VStack`, sitting below the existing footer (`HStack` with project/session
counts, gear icon, and quit button).

```swift
private var resizeHandle: some View {
    Rectangle()
        .fill(Color.clear)
        .contentShape(Rectangle())
        .frame(height: 6)
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
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

`@State private var dragStartHeight: Double? = nil` captures the height at drag
start so accumulated `translation.height` produces stable resizing (resetting
the baseline on every change would compound drift).

### Cursor

`NSCursor.resizeUpDown.push()` / `.pop()` on hover enter/exit. Push/pop can
occasionally get out of balance if SwiftUI drops a hover-end event during a
drag; AppKit clears the cursor stack on subsequent mouse moves, so for a 6pt
strip this is acceptable.

### Persistence

`@AppStorage("popoverHeight")` writes to `UserDefaults`. Survives popover
close, app quit, and app updates. No migration needed — missing key falls back
to the 480 default.

### Bounds clamping

Clamp inside `onChanged` (not just `onEnded`) so the popover visibly stops at
the limit during the drag instead of snapping back at release.

## Out of scope

- Horizontal resize. Width stays fixed at 380pt.
- A visible gripper/divider on the drag strip. The minimal aesthetic of the
  popover is preserved; the cursor change on hover is the discoverability cue.
- Per-section custom default heights.
- Animating to a remembered height on first open after launch (the `@AppStorage`
  value is read synchronously and applied to the initial frame).

## Testing

This is a UI gesture feature with no business logic. Verification is manual:

1. Launch the app, open the popover. It opens at the persisted height (480pt
   on a clean install).
2. Hover the bottom 6pt of the popover. Cursor switches to vertical resize.
3. Drag down — popover grows; drag up — popover shrinks.
4. Drag beyond 1000pt down or above 240pt up — popover stops at the limit.
5. Release, close the popover, reopen — same height.
6. Quit and relaunch the app — same height.
7. Switch sections (Overview / Projects / Months) and drill into a project or
   month — the chosen height is preserved across navigation.
