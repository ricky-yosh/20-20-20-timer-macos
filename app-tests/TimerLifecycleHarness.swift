import Foundation
import TimerCore

@MainActor
final class TimerPlatform {
    init() {}
    func start(
        onAvailability: @escaping @MainActor (Bool) -> Void,
        onDisplayChange: @escaping @MainActor () -> Void
    ) {}
    func showHeadsUp(snooze: @escaping @MainActor () -> Void) {}
    func showFinalCountdown(deadline: ContinuousClock.Instant) {}
    func showBreak(
        deadline: ContinuousClock.Instant,
        origin: BreakOrigin,
        dismiss: @escaping @MainActor () -> Void,
        snooze: (@MainActor () -> Void)? = nil
    ) {}
    func clear() {}
    func playCompletionChime() {}
}

@MainActor
final class ManualTimerClock {
    let origin: ContinuousClock.Instant
    var current: ContinuousClock.Instant
    var scheduled: [(token: UInt64, deadline: ContinuousClock.Instant)] = []
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    init(_ now: ContinuousClock.Instant) {
        origin = now
        current = now
    }

    lazy var clock: TimerClock = TimerClock(
        now: { [weak self] in self?.current ?? ContinuousClock.now },
        sleep: { [weak self] token, deadline in
            guard let self else { return }
            self.scheduled.append((token, deadline))
            await withCheckedContinuation { continuation in
                self.waiters[token] = continuation
            }
        }
    )

    var lastToken: UInt64? { scheduled.last?.token }
    var lastDeadline: ContinuousClock.Instant? { scheduled.last?.deadline }

    func advance(to now: ContinuousClock.Instant) async {
        for _ in 0..<8 {
            await Task.yield()
        }
        current = now
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume()
        }
        await Task.yield()
        await Task.yield()
    }
}

@MainActor
final class RecordingPlatform: TimerPlatformControlling {
    var actions: [String] = []
    var onAvailability: (@MainActor (Bool) -> Void)?
    var onDisplayChange: (@MainActor () -> Void)?
    var headsUpSnooze: (@MainActor () -> Void)?
    var finalDeadline: ContinuousClock.Instant?
    var breakDeadline: ContinuousClock.Instant?
    var breakOrigin: BreakOrigin?
    var breakDismiss: (@MainActor () -> Void)?
    var breakSnooze: (@MainActor () -> Void)?

    func start(
        onAvailability: @escaping @MainActor (Bool) -> Void,
        onDisplayChange: @escaping @MainActor () -> Void
    ) {
        self.onAvailability = onAvailability
        self.onDisplayChange = onDisplayChange
        actions.append("start")
    }

    func showHeadsUp(snooze: @escaping @MainActor () -> Void) {
        actions.append("headsUp")
        headsUpSnooze = snooze
    }

    func showFinalCountdown(deadline: ContinuousClock.Instant) {
        actions.append("final")
        finalDeadline = deadline
    }

    func showBreak(
        deadline: ContinuousClock.Instant,
        origin: BreakOrigin,
        dismiss: @escaping @MainActor () -> Void,
        snooze: (@MainActor () -> Void)?
    ) {
        actions.append("break:\(origin == .scheduled ? "scheduled" : "onDemand")")
        breakDeadline = deadline
        breakOrigin = origin
        breakDismiss = dismiss
        breakSnooze = snooze
    }

    func clear() {
        actions.append("clear")
    }

    func playCompletionChime() {
        actions.append("chime")
    }
}

@MainActor
func settle(_ clock: ManualTimerClock, _ expected: Int) async {
    for _ in 0..<30 where clock.scheduled.count < expected {
        await Task.yield()
    }
}

@main
struct LifecycleHarness {
    static func main() async {
        await run()
    }
}

@MainActor
func run() async {
    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok: \(message)")
        } else {
            failures.append(message)
            print("FAIL: \(message)")
        }
    }

    let configuration = TimerConfiguration(
        workInterval: .seconds(100),
        breakDuration: .seconds(20),
        snoozeInterval: .seconds(30),
        headsUpLead: .seconds(20),
        headsUpDuration: .seconds(5),
        finalWarningDuration: .seconds(10)
    )
    let t0 = ContinuousClock.now

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            configuration: configuration,
            now: t0
        )
        check(controller.phase == .work(deadline: t0 + .seconds(100), warning: .none), "initial phase is work")
        check(platform.actions.isEmpty, "init has no platform side effects")
        controller.start()
        await settle(clock, 1)
        check(platform.actions == ["start"], "start attaches platform once")
        check(clock.scheduled.count == 1 && clock.lastDeadline == t0 + .seconds(80), "first deadline is heads-up boundary")
        await clock.advance(to: t0 + .seconds(81))
        check(controller.phase == .work(deadline: t0 + .seconds(100), warning: .headsUp), "heads-up boundary warning")
        check(platform.actions == ["start", "headsUp"], "heads-up overlay presented")
        platform.headsUpSnooze?()
        check(
            controller.phase == .work(deadline: t0 + .seconds(111), warning: .none),
            "heads-up snooze routes to snoozeScheduledBreak"
        )
        controller.stop()
    }

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            configuration: configuration,
            now: t0
        )
        controller.start()
        await clock.advance(to: t0 + .seconds(91))
        check(controller.phase == .work(deadline: t0 + .seconds(100), warning: .finalCountdown), "final warning boundary")
        check(platform.actions.contains("final"), "final countdown overlay presented")
        controller.completionChime = true
        await clock.advance(to: t0 + .seconds(100))
        check(
            controller.phase == .onBreak(deadline: t0 + .seconds(120), origin: .scheduled),
            "work deadline opens scheduled break"
        )
        check(platform.actions.contains("break:scheduled"), "scheduled break overlay presented")
        check(platform.breakSnooze != nil, "scheduled break offers snooze")
        await clock.advance(to: t0 + .seconds(120))
        check(controller.phase == .work(deadline: t0 + .seconds(220), warning: .none), "natural completion resets work")
        check(platform.actions.contains("chime"), "natural completion plays enabled chime")
        controller.stop()
    }

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            configuration: configuration,
            now: t0
        )
        controller.start()
        controller.pause()
        check(controller.phase == .paused(remaining: .seconds(100)), "pause preserves remaining work")
        controller.takeBreakNow()
        check(
            controller.phase == .onBreak(deadline: t0 + .seconds(20), origin: .onDemand),
            "take break now opens on-demand break"
        )
        check(platform.breakSnooze == nil, "on-demand break has no snooze action")
        clock.current = t0 + .seconds(5)
        controller.dismissBreak()
        check(controller.phase == .paused(remaining: .seconds(100)), "early dismiss restores paused state")
        check(!platform.actions.contains("chime"), "early dismiss never chimes")
        controller.stop()
    }

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            configuration: configuration,
            now: t0
        )
        controller.start()
        await settle(clock, 1)
        let staleToken = clock.lastToken!
        let staleDeadline = clock.lastDeadline!
        controller.pause()
        controller.deadlineReached(token: staleToken, deadline: staleDeadline)
        check(controller.phase == .paused(remaining: .seconds(100)), "stale callback after pause is rejected")
        clock.current = t0 + .seconds(10)
        controller.resume()
        await settle(clock, 2)
        let currentToken = clock.lastToken!
        let currentDeadline = clock.lastDeadline!
        controller.deadlineReached(token: currentToken, deadline: staleDeadline)
        check(
            controller.phase == .work(deadline: t0 + .seconds(110), warning: .none),
            "current token with stale deadline is rejected"
        )
        clock.current = currentDeadline
        controller.deadlineReached(token: currentToken, deadline: currentDeadline)
        check(
            controller.phase == .work(deadline: t0 + .seconds(110), warning: .headsUp),
            "current token and deadline are accepted"
        )
        controller.stop()
    }

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            configuration: configuration,
            now: t0
        )
        controller.start()
        await clock.advance(to: t0 + .seconds(95))
        controller.screenUnavailable()
        check(controller.phase == .suspended, "screen unavailable suspends")
        check(platform.actions.contains("clear"), "suspend clears overlays")
        clock.current = t0 + .seconds(200)
        controller.screenAvailable()
        check(
            controller.phase == .work(deadline: t0 + .seconds(210), warning: .finalCountdown),
            "unlock replays a fresh final warning"
        )
        let deadlineBefore = clock.lastDeadline
        platform.onDisplayChange?()
        check(controller.phase == .work(deadline: t0 + .seconds(210), warning: .finalCountdown), "display change keeps phase")
        check(clock.lastDeadline == deadlineBefore, "display change keeps deadline")
        check(platform.finalDeadline == t0 + .seconds(210), "display change re-presents overlay")
        await clock.advance(to: t0 + .seconds(210))
        check(
            controller.phase == .onBreak(deadline: t0 + .seconds(230), origin: .scheduled),
            "replayed final warning opens scheduled break"
        )
        let breakDeadlineBefore = clock.lastDeadline
        platform.onDisplayChange?()
        check(
            controller.phase == .onBreak(deadline: t0 + .seconds(230), origin: .scheduled),
            "display change during break keeps phase"
        )
        check(clock.lastDeadline == breakDeadlineBefore, "display change during break keeps deadline")
        check(platform.breakDeadline == t0 + .seconds(230), "display change during break re-presents overlay")
        controller.stop()
    }

    if failures.isEmpty {
        print("PASS: all app lifecycle checks passed")
    } else {
        print("FAIL: \(failures.count) app lifecycle check(s) failed")
        exit(1)
    }
}
