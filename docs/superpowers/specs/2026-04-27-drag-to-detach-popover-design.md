# Drag to detach the menu-bar popover

Status: approved
Date: 2026-04-27
Author: brainstorming session (Paolo + Claude)

## Goal

The user can tear the menu-bar popover off into a free-floating window
by **dragging it away from the menu bar**, in addition to the existing
right-click → "Detach Window" affordance. The end state is identical to
today's menu-driven detach: `WindowStateStore.isDetached() == true`,
`detachedWindow` set, popover dismissed, frame persisted.

Reattach-by-drag is **out of scope** for this spec. Reattach continues
to be the right-click "Reattach to Menu Bar" menu item.

## Non-goals

- Reattach by dragging the window back to the status item. Tracked
  separately; the user is still thinking about the interaction.
- Removing the right-click "Detach Window" / "Reattach to Menu Bar"
  menu items. They stay for discoverability and accessibility.
- A custom drag handle inside the popover content. AppKit's built-in
  detach gesture (drag from the popover background) is sufficient.
- Animating the transition ourselves. AppKit handles the popover →
  window crossfade.
- Changing the visual style of the detached window. It must keep the
  current chromeless look (titled but transparent, only the close
  traffic light visible, full-size content view, draggable by
  background).

## Background — current detach flow

Today, detach is triggered exclusively from the status-item context
menu:

```
right-click status item
   └─ "Detach Window" → MenuBarController.toggleDetached()
         └─ detach()
               ├─ snapshot popover frame → WindowStateStore.saveFrame
               ├─ WindowStateStore.setDetached(true)
               ├─ popover.performClose(nil)
               ├─ configurePopover()                    // refresh hosting
               └─ DispatchQueue.main.async showDetachedWindow()
                     └─ creates NSWindow via createDetachedWindow()
                            (titled + transparent + close-only chrome,
                             isMovableByWindowBackground, delegate = self)
```

The detached window is created lazily on first show. Its delegate is
`MenuBarController`, which persists frame on move/resize/close.

## Design

AppKit already supports tear-off popovers. We adopt
`NSPopoverDelegate.popoverShouldDetach(_:)` and supply a custom window
via `detachableWindow(for:)`, then react in
`popoverDidDetach(_:)` to converge on the same internal state today's
menu-driven path produces.

### Delegate methods

`MenuBarController` (already `@MainActor` and an `NSObject`) conforms to
`NSPopoverDelegate` and is set as `popover.delegate` in
`configurePopover()`.

```swift
extension MenuBarController: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        makeDetachableWindow()
    }

    func popoverDidDetach(_ popover: NSPopover) {
        adoptDetachedWindow()
    }
}
```

`makeDetachableWindow()` and `adoptDetachedWindow()` are new private
helpers introduced below.

### Popover behavior change

`popover.behavior` flips from `.transient` to `.semitransient`.

| Behavior | Closes when… | Drag-detach reliable? |
|---|---|---|
| `.transient` (today) | user clicks anywhere outside the popover, including the desktop | unreliable — the click-tracking that powers transient dismissal can preempt the detach drag in practice |
| `.semitransient` (proposed) | user activates a different window | yes — Apple's recommended pairing for tear-off popovers |

User-visible change: clicking on the empty desktop no longer dismisses
the popover. Clicking another window (Finder, browser, the Knot status
item again) still does. For a menu-bar utility this is acceptable — the
popover's primary dismissal gesture is "click the menu-bar icon again",
which still works.

### Window construction split

`createDetachedWindow()` is split into two helpers so both detach paths
share styling:

```swift
/// Builds an empty, fully-styled window suitable for AppKit's
/// drag-detach. AppKit moves the popover's content view into it.
private func makeDetachableWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0,
                            width: Theme.popoverWidth,
                            height: Theme.popoverHeight),
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: true
    )
    applyDetachedChrome(to: window)
    return window
}

/// Builds a window with its own hosting controller, used by the
/// menu-driven detach path that doesn't transfer the popover's view.
private func createDetachedWindow() -> NSWindow {
    let host = NSHostingController(rootView: makeRootView())
    host.view.frame = NSRect(x: 0, y: 0,
                             width: Theme.popoverWidth,
                             height: Theme.popoverHeight)
    let window = NSWindow(contentViewController: host)
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.setContentSize(NSSize(width: Theme.popoverWidth,
                                 height: Theme.popoverHeight))
    applyDetachedChrome(to: window)
    return window
}

/// Shared chrome: transparent titlebar, hidden min/zoom buttons,
/// drag-by-background, screen-spanning behavior, delegate hookup.
private func applyDetachedChrome(to window: NSWindow) {
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.title = "Knot"
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.delegate = self
}
```

### Adoption after drag-detach

`popoverDidDetach(_:)` runs after AppKit has moved the popover's
content into the new window and animated the transition:

```swift
private func adoptDetachedWindow() {
    guard let window = popover.contentViewController?.view.window else {
        // Defensive: AppKit should always have re-parented by now.
        return
    }
    detachedWindow = window
    WindowStateStore.setDetached(true)
    WindowStateStore.saveFrame(window.frame)
    // Rebuild the popover's hosting controller so the next showPopover()
    // call has fresh content (AppKit emptied this one).
    configurePopover()
}
```

Note: `configurePopover()` already builds a new `NSHostingController`
and assigns it to `popover.contentViewController`. After drag-detach,
the previous hosting controller's view is now living inside
`detachedWindow`. Rebuilding the popover guarantees the next
`showPopover()` produces a fresh editor surface.

### Status-item click while detached

No change. `MenuBarController.toggle()` already branches on
`WindowStateStore.isDetached()` and routes the click to
`toggleDetachedWindow()`. After drag-detach, that flag is true, so
clicking the status icon hides/shows the floating window as expected.

### Right-click menu

No change. `toggleDetachedFromMenu` calls `toggleDetached()` which
chooses between `detach()` and `reattach()`. Both paths still work; the
menu remains the only reattach affordance.

## State invariants — must hold after each transition

| Transition | `isDetached()` | `detachedWindow` | popover shown |
|---|---|---|---|
| Initial / fresh launch | `false` | `nil` | no |
| User opens popover | `false` | `nil` | yes |
| User drags popover off (new) | `true` | the AppKit-supplied window | no |
| User picks "Detach Window" from menu | `true` | a window made by `createDetachedWindow()` | no |
| User picks "Reattach to Menu Bar" | `false` | `nil` | yes |
| User closes detached window via close button | `true` (unchanged today; out of scope) | window kept, ordered out | no |
| `handleSettingsReset()` | `false` — `AppDelegate.handleSettingsReset()` clears `WindowStateStore` before dismissing/rebuilding menu-bar UI. | `nil` | no |

Drag-detach must converge on the same row as menu-driven detach.

## Edge cases

| Case | Behavior |
|---|---|
| User starts dragging then releases over the menu bar | AppKit cancels the detach; popover stays attached. No state change. |
| Drag-detach during onboarding (no vault) | Works the same. The `OnboardingView` is what gets carried into the new window. Vault picker still functions; once vault is picked, `EditorView` replaces it via `@Bindable model`. |
| Saved frame absent at drag-detach time | AppKit places the new window where the user dragged it. We persist that frame in `popoverDidDetach` (and again on first move). |
| Drag-detach on a secondary display | Window appears on that display. `windowDidMove` saves the frame; `constrainedFrame()` already protects later sessions if the display is gone. |
| User drags to detach and immediately quits | App termination flushes `UserDefaults`. Frame and detached flag persist normally. |
| Right-click → "Detach Window" while popover already showing | Unchanged: `detach()` runs, popover closes, separate `createDetachedWindow()` path kicks in. |
| Right-click → "Detach Window" pressed mid-drag | Practically impossible — context menu requires the popover to lose focus first, which closes it before the menu opens. No special handling needed. |
| `popoverShouldDetach` returns true but user releases inside menu-bar threshold | Same as case 1. AppKit's threshold logic decides. |
| `popoverDidDetach` fires but `popover.contentViewController?.view.window` is nil | Guard logs nothing user-visible and skips state mutation. The window AppKit created still exists; user can use the close button. (Defensive — should not happen in practice.) |
| Popover opened from a click that becomes a drag | AppKit treats the gesture as a normal popover-to-window drag once the user's pointer leaves the menu-bar drop zone. Standard AppKit behavior. |

## Testing

Drag-detach is an AppKit interaction tied to live mouse events; it is
not unit-testable from KnotKit. There is no extractable pure-logic
component — the helper functions here just call AppKit APIs.

### Manual QA checklist (added inline to PR)

1. Launch Knot. Click the menu-bar icon → popover appears.
2. Drag from a non-interactive part of the popover background (outside the textarea) down into the screen.
   Expect: it tears off into a free-floating window mid-drag.
3. Confirm the floating window has the correct chrome: hidden title,
   transparent titlebar, only close traffic-light visible.
4. Confirm `WindowStateStore` was updated: quit and relaunch — clicking
   the menu-bar icon now toggles the floating window, not a popover.
5. Right-click the menu-bar icon → "Reattach to Menu Bar" → popover
   returns; relaunch confirms `isDetached() == false`.
6. Repeat the drag-detach across two displays. Verify the window lands
   on the correct screen and the saved frame is honored on next launch.
7. With popover open, click an empty area of the desktop. Expect: the
   popover **stays open** (this is the `.semitransient` change). Click
   another app or the status item to dismiss.
8. Right-click → "Detach Window" still works; reattach still works.
9. Onboarding case: with no vault configured, drag-detach the popover.
   Confirm the vault picker still functions inside the floating window
   and the editor takes over once a vault is chosen.

### Automated tests

None. `MenuBarController` is app-target code; the project's testing
discipline ("Logic belongs in KnotKit") explicitly carves out AppKit
shells. We do not introduce a UI-test target for this single
interaction.

## File touch list

- **Edit**: `Knot/macOS/MenuBarController.swift`
  - Conform to `NSPopoverDelegate`.
  - Set `popover.delegate = self` in `configurePopover()`.
  - Change `popover.behavior` from `.transient` to `.semitransient`.
  - Split `createDetachedWindow()` into `makeDetachableWindow()`,
    `createDetachedWindow()`, and `applyDetachedChrome(to:)`.
  - Add `adoptDetachedWindow()` and the three delegate methods.

No other files change. No `project.yml` edits. No changes to KnotKit.
No changes to entitlements.

## Rollback

Revert is a single-file change. The state shape stored in
`UserDefaults` is unchanged, so a downgrade leaves persisted frames and
the detached flag intact and usable by older builds.

## Open questions

None. Reattach-by-drag is being thought through separately and will be
specced on its own.
