# Native macOS Workarounds

## Roles

`TimerPlatform` is the app-boundary adapter for AppKit windows, focus, audio and
accessibility announcements. It holds no timer state and reads no deadlines from
the system clock. `TimerCore` owns all phase transitions; the controller sends
typed events and supplies deadlines. `ScreenAvailabilityObserver` (task #85) is
owned separately and wired by `start(onAvailability:onDisplayChange:)`.

Every constructed panel sets `hidesOnDeactivate = false`. AppKit defaults a
borderless nonactivating `NSPanel` to hiding on deactivate, which can hide a
visible cue or overlay as soon as another app owns focus; the adapter keeps the
surface visible regardless of which app is frontmost.

## Heads-up

The one-minute heads-up is a borderless, nonactivating `NSPanel` with a
click-capable Snooze button hosted by `HeadsUpView`. The panel is never made key,
so the frontmost app and its text caret stay put. It uses a floating-or-higher
level, `canJoinAllSpaces`, `stationary`, `ignoresCycle` and `fullScreenAuxiliary`
so it is visible over fullscreen Spaces without joining the app's window cycle.
It fades in and out with `NSAnimationContext`.

## Final countdown

The five-second countdown is a mouse-ignoring `NSPanel` hosted by
`FinalCountdownView`. Its position comes only from `NSEvent.mouseLocation` while
the panel is visible; no global event monitor or input monitoring permission is
used. A visibility-scoped task refreshes the position, offsets it from the
pointer hotspot and clamps it inside the pointer's current `visibleFrame`. Near
an edge the offset flips to the opposite side of the pointer before clamping, so
the clamped rect cannot cover the hotspot. When
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is set, the panel
uses a fixed screen-anchored position, no recurring refresh task, and a brief
0.15s opacity fade. The refresh task is cancelled when the surface is cleared,
so no work runs while hidden.

## Breaks

A break creates one borderless `NSPanel` per connected `NSScreen`, each hosting
`BreakOverlayView` over the calm charcoal background. Non-control panels ignore
mouse events and show only the background. The panel on the display containing
the pointer at break start is the control panel: it accepts mouse and keyboard
input, overrides `canBecomeKey` so the borderless panel can actually become key,
and intercepts Escape in `sendEvent` and `performKeyEquivalent` before the
hosting view's responder chain. Its
content receives the optional snooze action, so Snooze 5m is available inside a
scheduled overlay. `NSWorkspace.shared.frontmostApplication` is captured when
the break starts and reactivated when the break ends or is dismissed; when no
former app is known the app deactivates itself.

The control display is identified by a stable `NSScreenNumber`. It stays the
control display while it exists, even if the pointer moves. If it is
disconnected, the controls migrate to a remaining display while the original
deadline and callbacks are unchanged. Repeated `showBreak` calls with the same
deadline update panels without restarting the break, re-announcing it or moving
the controls.

## Check-ins

A blink or posture check-in uses the same borderless nonactivating panel shape as
the heads-up, hosted by `CheckInView` and placed top-right on the pointer's
display. The panel is never made key, so the frontmost app and caret keep focus.
The core owns the prompt deadline; the adapter only fades the panel in, moves it
when display topology changes, and fades it out when the controller clears it.
The `Got it` button routes a typed `.dismissCheckIn` event rather than dismissing
the panel on its own. Reduce Motion switches the icon reveal to an immediate
still presentation.

## Display topology

`NSApplication.didChangeScreenParametersNotification` is observed on the main
queue. On a change the adapter reconciles the panel set against `NSScreen.screens`:
panels for removed displays are closed, panels for new displays are created, and
existing panels are resized to their screen. The display observer remains
installed until deallocation so topology changes keep working after `clear()`.
Fade-out cleanup closes only the exact panel instance it captured, so a panel
recreated during a topology change is never closed by an earlier cleanup.

## Fades, announcements and sound

All surfaces fade through `NSAnimationContext`, with a brief 0.15s opacity
transition when Reduce Motion is enabled. Break start and end are each announced exactly
once through the AppKit `NSAccessibility` announcement request; topology updates
and repeated clear calls do not duplicate them. The completion chime is played
with `NSSound`, stopped before replay so rapid completions do not overlap.

## Command transport

`TimerCommandHost` owns the app-side socket server. It derives the endpoint from
the app's real home directory and `Bundle.main.bundleIdentifier`, so the socket
lives at `~/Library/Containers/<bundle-id>/Data/tmp/tc/s` even though the app is
sandboxed. `TimerCommandTransport` creates a 0700 endpoint directory, a 0600
socket, a 0600 lock file, and verifies the peer UID with `getpeereid`. Frames are
bounded to 64 KiB and the server handles one request at a time off the main actor.

The handler decodes `TimerCommandRequest`, calls the main-actor
`TimerCommandService.execute`, and encodes `TimerCommandExecution.response`. A
quit request carries the service's shared termination completion as the
transport's after-reply hook; the transport writes and shuts down that response
before the hook calls `NSApplication.shared.terminate(nil)`. Quit therefore
acknowledges the CLI before the normal app termination path runs, while the menu
quit button uses the same command and completion immediately. The server start
failure is logged and does not stop the menu bar timer.

## Menu bar status label

`TimerStatusItemLabel` updates its displayed countdown from a view-local
one-second Combine ticker. A `TimelineView` or self-updating `Text` inside a
`MenuBarExtra` label caused an endless `makeMenuBarExtras` update loop during
launch on this macOS/Xcode combination, so the label uses an explicit display
tick that never starts, advances, pauses, or reschedules the timer.
