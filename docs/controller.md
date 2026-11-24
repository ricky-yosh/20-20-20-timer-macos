# App controller

`TimerController` is the single owner of timer time in the app. `TimerState` from
`TimerCore` computes every transition from an event and an explicit instant; the
controller never reads the clock to decide state, only to supply `now` and to
compute a sleep deadline.

- `start()` attaches the platform's availability and display callbacks and
  schedules the first transition. `stop()` cancels pending work and clears
  overlays. Both are called from `AppDelegate`.
- One `Task<Void, Never>` waits on `ContinuousClock.sleep(until:)`. Every
  reschedule increments a generation token; the task captures the token and a
  local clock, not `self`, and `deadlineReached(token:deadline:)` rejects a
  callback whose token or deadline is stale. The task therefore cannot retain
  the controller while it sleeps.
- `@Published private(set) var phase` is the read-only snapshot for the menu.
  Views send typed `TimerEvent` values through `send(_:)`; SwiftUI views contain
  no timer effects.
- `@Published private(set) var activeCheckIn` exposes the core-owned blink or
  posture prompt. `TimerCore` chooses the next reminder, its expiration, and the
  suppression rules from the same event and instant input; `nextDeadline` covers
  both warning boundaries and reminder transitions, so the controller still owns
  exactly one pending sleep.
- Overlay and chime routing compares the previous and new presentation.
  `clear()` runs when an overlay disappears, and the completion chime plays only
  when a break ends through `.deadlineReached` with the preference enabled.
  Break warnings take priority over a check-in in the same routing decision.
- The two reminder toggles are persisted through an injected
  `CheckInPreferencesStoring` adapter. Product code uses `UserDefaults`; lifecycle
  tests use an in-memory store, so tests never touch real preferences.
- Display-topology changes call `redisplayOverlays()`, which re-presents the
  current overlay with the same deadline without changing timer state.
- `TimerPlatformControlling` is injected so lifecycle tests use a recording
  fake; the real `TimerPlatform` conforms with `@MainActor` callback signatures.
- `TimerController.performTimerCommand(_:)` is the single validation and
  dispatch path for menu actions, overlay controls (heads-up snooze, break
  dismiss/snooze/Escape, check-in Got it), and the CLI socket host. It rejects
  unavailable commands before mapping `TimerCommand` values to the same
  `TimerEvent` cases. `TimerCommandService` supplies the `Codable` status
  snapshot, preference changes, and the shared quit completion, so the CLI
  cannot fork the timer rules or quit ordering.

## Verification commands

Standalone lifecycle harness (no view mounting, no Xcode test target):

```
./run-app-lifecycle-tests.sh
```

It builds `TimerCore` and the harness into a fresh directory created under
`/tmp/timer-swarm` and removes it on exit, so concurrent runs cannot collide and
no fixed parent folder must exist in advance. It runs 104 typed checks covering
warning boundaries, snooze, early dismissal, sleep/unlock replay, stale callbacks,
display migration, reminder cadence and expiry, independent toggles, reminder
suppression during pause, break, and lock, plus the shared CLI command path and
JSON round trips.

Full app typecheck with the scheme's Swift 6 settings can be reproduced from the
repo root with the equivalent `xcodebuild` invocation:

```
xcodebuild -project 20-20-20-timer/20-20-20-timer.xcodeproj -scheme 20-20-20-timer -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/timer-swarm/app-xcode-build CODE_SIGNING_ALLOWED=NO build
```

## Development timings

In Debug builds, pass `--demo-timings` to the executable to shorten the cycle to
a 12-second work interval, 6-second break, 8-second snooze, 6-second heads-up
lead with a 2-second heads-up, a 3-second final warning, a 2-second blink prompt
at 2 seconds, and a 2-second posture prompt at 4 seconds:

```
/tmp/timer-swarm/app-xcode-build/Build/Products/Debug/20-20-20-timer.app/Contents/MacOS/20-20-20-timer --demo-timings
```

The flag has no effect in Release builds.
