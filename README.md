# 20-20-20-timer-macos

20-20-20 timer reminder to look away from the screen and take a break!

## Project structure

- `TimerCore/` — Swift 6 SwiftPM package with the timer rules and typed state/events. Builds and tests independently with no package dependencies (Swift standard library and Foundation only).
- `20-20-20-timer/` — macOS app target. Imports `TimerCore`; menu bar and overlay views live in `Presentation/`, macOS adapters in `Platform/`, and the controller beside the app entry point.
- `scripts/check-architecture` — self-contained architecture/lint guard.

## Build (macOS)

Run from the repository root:

```bash
xcodebuild -project 20-20-20-timer/20-20-20-timer.xcodeproj -scheme 20-20-20-timer -configuration Debug -destination 'platform=macOS' build
```

The `20-20-20-timer` scheme resolves `TimerCore` as a local SwiftPM package; no network access is required.

## Verification

Run these from the repository root.

### Architecture guard

```bash
./scripts/check-architecture
```

The guard is a single executable Python 3 script with no helper dependencies. It recursively scans production Swift in both modules and fails on:

- **Core imports** — anything other than Swift standard modules and Foundation in `TimerCore`.
- **Concurrency escape hatches** — `Task.detached`, `@unchecked Sendable`, or `nonisolated(unsafe)` in either module.
- **Implementation comments** — handwritten comments in either module; only license headers and tool directives are allowed, and comment tokens inside strings are ignored.
- **Package graph** — any `TimerCore` package dependency or reverse dependency on the app, reported from `swift package dump-package`.
- **Xcode graph** — a missing local `../TimerCore` package declaration, an app target without a `TimerCore` package-product member, or a reverse Xcode edge.

### Core tests

```bash
swift test --package-path TimerCore
```

### App controller lifecycle tests

The standalone controller lifecycle harness exercises the typed entry points without mounting a view. Run it from the repository root:

```bash
./run-app-lifecycle-tests.sh
```

## License

MIT
