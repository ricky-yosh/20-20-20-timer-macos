# 20-20-20 Timer

[docs/decisions.md](docs/decisions.md) defines the accepted product behavior and the Mac verification checklist. Use the existing Xcode project. Resolve routine implementation details yourself. Ask when a choice changes agreed behavior, scope, or permissions.

## Organic architecture

- **Use source paths to show who owns a behavior.** Put timer rules and their tests in a separate `TimerCore` module. In the existing app target, put the menu bar and overlay views in `Presentation/`, and macOS adapters for windows, sleep and lock, and audio in `Platform/`. Keep the controller beside the app entry point. Keep supporting code beside the feature that owns it.
- **Enforce that structure in the build graph.** The app imports `TimerCore`. The core builds and tests independently and may import standard Swift libraries and Foundation. An automated check must reject app or macOS service imports in the core and reject any dependency from the core back to the app. Use Swift 6 strict concurrency to enforce the `@MainActor` boundary for the controller and UI. Pass only `Sendable` values across actor boundaries. Ban `Task.detached`, `@unchecked Sendable`, and `nonisolated(unsafe)` in product code.
- **Make intent readable from types and names.** Give concepts that change behavior distinct types or enum cases, such as scheduled and on-demand break origins. Name values for what they represent, such as `breakDeadline` or `remainingWorkTime`. Name commands for their effect, such as `snoozeScheduledBreak`. Keep state mutations private to the controller and give views a read-only snapshot and a typed event entry point.
- **Remove obsolete patterns in the code you change.** When replacing a timer path, remove the old path and migrate its callers in the same change. Keep required macOS workarounds inside the adapter that owns them and record the reason in `docs/`.
- **Ban implementation comments in handwritten product code.** Express behavior through structure, names, types, and tests. Record design rationale in `docs/`. Required license headers and tool directives are allowed.

## Deterministic foundations

- **Use typed states and events.** Model the active phase and break origin explicitly. Let the core compute the next state from the current state, an event, and a supplied monotonic instant. Keep sleep, window management, audio, and scheduling at the app boundary. The core must not read the clock, start tasks, or perform I/O by itself.
- **Keep one source of time.** One app-level controller owns the timer state and schedules its next transition. Derive displayed time from deadlines rather than decrementing a counter on each tick. Cancel obsolete scheduled work and reject stale callbacks. Each display reads the same break deadline.
- **Ban hidden timer effects.** SwiftUI `onAppear`, `onDisappear`, `onChange`, and `.task` are limited to view-local behavior. They must not start, advance, pause, or reschedule the timer, or register app-wide observers. Route user actions, timer deadlines, and macOS notifications to the controller as typed events through explicit entry points.
- **Make invalid states hard to express.** Represent timer phases with a single enum. Use exhaustive switches over timer states and events, without `default` branches.

## Verification

- Test timer rules with a controllable clock or explicit instants. Advance time directly in tests. Cover the transitions a change touches, especially the warning boundaries, snooze, early dismissal, sleep and unlock, and obsolete callbacks arriving after a new action.
- Add an automated architecture and lint check when introducing the timer module. It must fail on forbidden core imports, banned concurrency escape hatches, and disallowed product source comments. Run it alongside the build and timer tests. Cover the timer lifecycle with tests that exercise the typed entry points without mounting a view.
- Build the existing macOS scheme for app changes. For visible changes, run the relevant checks from the decision log in the app. Use shortened development timings where useful.
- Match evidence to the behavior. Use a screenshot for layout, a short recording for motion, and a test result or event trace for timing. In the handoff, report what passed and which runtime checks remain. Keep temporary verification artifacts out of the repo unless requested.

## Navigation

If `.codegraph/` exists at the repo root, use CodeGraph before searching or reading source to understand or locate code. Prefer `codegraph_explore`, with `codegraph explore` as the shell fallback. If the directory is absent, skip CodeGraph and use `rg`.
