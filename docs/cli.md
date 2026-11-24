# Timer CLI

`20-20-20-cli` drives the running menu bar app through the same typed commands and
controller path as the GUI. It does not own a timer, a clock, or a second set of
transition rules. The app's `TimerController` remains the only timer owner.

## Files

- `20-20-20-timer/TimerCommandProtocol/TimerCommandProtocol.swift` — shared
  `Codable` command, status, error, and response types; the `TimerCommand` to
  `TimerEvent` mapping; and availability rules.
- `20-20-20-timer/20-20-20-timer/TimerCommandService.swift` — `@MainActor`
  command handler used by both `TimerMenu` bindings/buttons and the socket host;
  timer commands dispatch through `TimerController.performTimerCommand`.
- `20-20-20-timer/20-20-20-timer/Platform/TimerCommandHost.swift` — app-boundary
  host that decodes requests, calls the service, and encodes responses.
- `20-20-20-timer/20-20-20-timer/Platform/TimerCommandTransport.swift` — bounded
  same-user Unix-domain-socket request/reply transport.
- `20-20-20-timer/20-20-20-cli/TimerCLI.swift` — CLI argument parsing, app launch,
  container endpoint lookup, JSON output, and exit codes.

## Build

Build the app and the CLI from the repository root. The CLI target does not
embed itself in the app bundle and does not make the app depend on the CLI.

```bash
xcodebuild -project 20-20-20-timer/20-20-20-timer.xcodeproj \
  -scheme 20-20-20-timer -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/timer-swarm/cli-app build

xcodebuild -project 20-20-20-timer/20-20-20-timer.xcodeproj \
  -scheme 20-20-20-cli -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/timer-swarm/cli-app build
```

The products are:

```text
/tmp/timer-swarm/cli-app/Build/Products/Debug/20-20-20-timer.app
/tmp/timer-swarm/cli-app/Build/Products/Debug/20-20-20-cli
```

The app keeps App Sandbox enabled and its existing entitlements. The CLI is an
unsigned local tool with no additional OS permissions.

## Run

Start the app normally, or let `start` launch it. `start --demo-timings` passes
the Debug demo configuration when it has to launch the app:

```bash
APP=/tmp/timer-swarm/cli-app/Build/Products/Debug/20-20-20-timer.app
CLI=/tmp/timer-swarm/cli-app/Build/Products/Debug/20-20-20-cli

open -g "$APP" --args --demo-timings
"$CLI" status --app "$APP"
```

If the app is not running, `start` launches the sibling `20-20-20-timer.app`
(or `--app`, or `TIMER_APP_PATH`) with `open`, waits for a successful exchange,
and then sends an idempotent start. Use `--no-launch` to require the app to
already be running.

## Commands

| Command | Effect |
| --- | --- |
| `status` | Report phase, warning, break origin, remaining seconds, active check-in, preferences, and available commands. |
| `start` | Start the app if needed, then start the timer. Safe when already running. |
| `pause` | Pause the work interval. |
| `resume` | Resume a paused work interval. |
| `take-break-now` | Open an on-demand break. |
| `end-break` | End or dismiss the current break; `dismiss-break` is the canonical name. |
| `snooze-break` | Snooze a scheduled warning or scheduled break. Rejected otherwise. |
| `dismiss-check-in` | Dismiss the visible blink or posture prompt. |
| `set-chime on\|off` | Set the completion chime preference. |
| `set-blink on\|off` | Set the blink reminder preference. |
| `set-posture on\|off` | Set the posture reminder preference. |
| `quit` | Acknowledge and then quit the app through the normal GUI quit path. |

Aliases include `end-break`, `snooze`, `take-break`, `set-chime`, `set-blink`,
and `set-posture`. Every `TimerCommand` raw value is also accepted directly.

## JSON

The CLI always prints one JSON object. Keys are sorted for stable output.
`--pretty` is the default and `--compact` removes whitespace.

Successful status:

```json
{
  "ok": true,
  "status": {
    "availableCommands": [
      "status",
      "start",
      "pause",
      "take-break-now",
      "quit",
      "set-completion-chime",
      "set-blink-check-in",
      "set-posture-check-in"
    ],
    "isBlinkCheckInEnabled": true,
    "isCompletionChimeEnabled": false,
    "isPostureCheckInEnabled": true,
    "phase": "work",
    "remainingSeconds": 1184,
    "warning": "none"
  }
}
```

Stable status values:

- `phase`: `work`, `paused`, `on-break`, `suspended`
- `warning`: `none`, `heads-up`, or `final-countdown` while working; omitted for
  `paused`, `on-break`, and `suspended`
- `breakOrigin`: `scheduled` or `on-demand` during a break; omitted otherwise
- `activeCheckIn`: `blink` or `posture` while a prompt is visible; omitted otherwise
- `remainingSeconds`: whole seconds rounded up; omitted while suspended

Optional keys are omitted when they have no value, so a missing key is not an
error and never appears as `null`.

Failure:

```json
{
  "error": {
    "code": "unavailable",
    "message": "snooze-break is unavailable while an on-demand break is running."
  },
  "ok": false
}
```

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Command accepted and state returned. |
| `2` | Invalid command, option, or missing `on`/`off` value. |
| `3` | App not running or command endpoint unavailable. |
| `4` | Command unavailable in the current timer phase. |
| `5` | Transport or protocol failure. |

## Endpoint

The server binds the Unix-domain socket at
`~/Library/Containers/<CFBundleIdentifier>/Data/tmp/tc/s`. The `tc` socket
directory is 0700, the `s` socket is 0600, the peer UID is checked with
`getpeereid`, and frames are bounded to 64 KiB. The CLI derives the bundle
identifier from the app bundle's `Info.plist`. Pass `--bundle-id` when the app
bundle is not available.

## Verification

```bash
./scripts/check-cli-parity
./run-app-lifecycle-tests.sh
./scripts/check-architecture
```

The parity guard fails if the GUI bypasses the shared command path, if a GUI
action lacks a `TimerEvent` mapping, if an overlay control dispatches directly,
if quit is handled outside the shared completion, or if a preference command is
missing from the shared command path. The lifecycle harness adds checks for
status, pause/resume, break lifecycle, snooze unavailability, check-in dismissal,
preferences, deferred quit acknowledgement before termination, and JSON round
trips.
