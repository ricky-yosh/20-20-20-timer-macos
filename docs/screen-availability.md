# Screen availability

`ScreenAvailabilityObserver` is the macOS adapter that tells the controller when the Mac is usable for the timer. It reports only boolean edges: `false` when any reason makes the screen unavailable, and `true` only after every reason has cleared.

## Sources

| Reason | Notification | Center |
| --- | --- | --- |
| Display asleep | `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification` | `NSWorkspace.shared.notificationCenter` |
| Machine asleep | `NSWorkspace.willSleepNotification` / `didWakeNotification` | `NSWorkspace.shared.notificationCenter` |
| Screen locked | `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` | `DistributedNotificationCenter.default()` |
| Session inactive | `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification` | `NSWorkspace.shared.notificationCenter` |

The observer registers block-based observers and keeps their tokens so it can remove them in `deinit`. Notification blocks may run on a posting thread other than the main thread, so each block forwards only a small `Sendable` edge value onto `DispatchQueue.main`; all state lives on the main actor.

## Why native notifications, and why four reasons

- Display sleep and machine sleep are independent events. A Mac can sleep the displays while the machine stays awake, and machine wake can happen before display wake. A single boolean per source would report the screen usable at the first wake, so the observer keeps a set of active reasons and reports usable only when the set is empty.
- AppKit has no screen-lock notification. The loginwindow distributed notifications `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` are the built-in signal for ordinary lock and unlock, and they work without a screen-recording or input-monitoring permission. They remain a distributed notification rather than an AppKit API, which is the native workaround this adapter owns.
- Session active/resign-active notifications cover fast user switching and login/logout transitions that do not produce a lock notification. They are separate from lock so a session change during a lock does not clear the lock reason.
- Each reason is inserted or removed by name. Repeated notifications for the same transition collapse to the same set, and a change is reported only when the derived usable state actually flips. This suppresses duplicate edges from overlapping sleep, lock, and session events.

## Caveats

- `start(onChange:)` is one-shot; later calls are ignored. The observer assumes a usable state at launch and does not probe current lock, display, or session state, so a change that happened before the app launched is not reported. Callers should start from a running timer and let the first edge suspend it.
- A screen saver that does not lock the screen is not a separate reason. Display sleep and lock, the cases in the product checklist, are covered.
- Distributed notifications are posted by the system and can also be posted by any local process; the observer treats them as hints, never as a source of time or as a trigger for timer work.
- No clock, timer, task, permission request, or input-monitoring API is used. All notification registration is performed by this adapter; the core never observes the OS directly.
