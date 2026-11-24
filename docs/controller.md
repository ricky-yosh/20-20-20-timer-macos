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
- Overlay and chime routing compares the previous and new presentation.
  `clear()` runs when an overlay disappears, and the completion chime plays only
  when a break ends through `.deadlineReached` with the preference enabled.
- Display-topology changes call `redisplayOverlays()`, which re-presents the
  current overlay with the same deadline without changing timer state.
- `TimerPlatformControlling` is injected so lifecycle tests use a recording
  fake; the real `TimerPlatform` conforms with `@MainActor` callback signatures.

## Verification commands

Standalone lifecycle harness (no view mounting, no Xcode test target):

```
./run-app-lifecycle-tests.sh
```

It builds `TimerCore` and the harness into a fresh directory created with
`mktemp -d "${TMPDIR:-/tmp}/timer-lifecycle.XXXXXX"` and removes it on exit, so
concurrent runs cannot collide and no fixed parent folder must exist in advance.
Run it with `TMPDIR` pointed at any existing temporary folder to relocate the
build. It runs 32 typed checks covering warning boundaries, snooze, early
dismissal, sleep/unlock replay, stale callbacks, and display migration.

Full app typecheck with the scheme's Swift 6 settings can be reproduced from the
repo root with the equivalent `xcodebuild` invocation:

```
xcodebuild -project 20-20-20-timer/20-20-20-timer.xcodeproj -scheme 20-20-20-timer -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/timer-swarm/app-xcode-build CODE_SIGNING_ALLOWED=NO build
```

## Development timings

In Debug builds, pass `--demo-timings` to the executable to shorten the cycle to
a 12-second work interval, 6-second break, 8-second snooze, 6-second heads-up
lead with a 2-second heads-up, and a 3-second final warning:

```
/tmp/timer-swarm/app-xcode-build/Build/Products/Debug/20-20-20-timer.app/Contents/MacOS/20-20-20-timer --demo-timings
```

The flag has no effect in Release builds.
