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
    func showCheckIn(origin: CheckInOrigin, dismiss: @escaping @MainActor () -> Void) {}
    func clear() {}
    func playCompletionChime() {}
}

@MainActor
final class InMemoryCheckInPreferences: CheckInPreferencesStoring {
    var isBlinkCheckInEnabled: Bool
    var isPostureCheckInEnabled: Bool

    init(blink: Bool = true, posture: Bool = true) {
        isBlinkCheckInEnabled = blink
        isPostureCheckInEnabled = posture
    }
}

@MainActor
final class TerminationRecorder {
    var count = 0
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
    var checkInOrigin: CheckInOrigin?
    var checkInDismiss: (@MainActor () -> Void)?

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

    func showCheckIn(origin: CheckInOrigin, dismiss: @escaping @MainActor () -> Void) {
        actions.append("checkIn:\(origin == .blink ? "blink" : "posture")")
        checkInOrigin = origin
        checkInDismiss = dismiss
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
            preferences: InMemoryCheckInPreferences(),
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
            preferences: InMemoryCheckInPreferences(),
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
            preferences: InMemoryCheckInPreferences(),
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
            preferences: InMemoryCheckInPreferences(),
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
            preferences: InMemoryCheckInPreferences(),
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

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let preferences = InMemoryCheckInPreferences()
        let reminderConfiguration = TimerConfiguration(
            workInterval: .seconds(100),
            breakDuration: .seconds(20),
            snoozeInterval: .seconds(30),
            headsUpLead: .seconds(20),
            headsUpDuration: .seconds(5),
            finalWarningDuration: .seconds(10),
            checkInDuration: .seconds(5),
            blinkCheckInOffsets: [.seconds(40), .seconds(80)],
            postureCheckInOffsets: [.seconds(60)]
        )
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            preferences: preferences,
            configuration: reminderConfiguration,
            now: t0
        )
        controller.start()
        await settle(clock, 1)
        check(clock.lastDeadline == t0 + .seconds(40), "first wakeup is the blink reminder")

        await clock.advance(to: t0 + .seconds(40))
        await settle(clock, clock.scheduled.count + 1)
        check(controller.activeCheckIn?.origin == .blink, "blink reminder becomes active")
        check(platform.actions.contains("checkIn:blink"), "blink prompt presented")
        check(clock.lastDeadline == t0 + .seconds(45), "reminder expiry is the next wakeup")

        await clock.advance(to: t0 + .seconds(45))
        await settle(clock, clock.scheduled.count + 1)
        check(controller.activeCheckIn == nil, "blink reminder expires")
        check(clock.lastDeadline == t0 + .seconds(60), "posture reminder remains scheduled")

        controller.setBlinkCheckInEnabled(false)
        check(!preferences.isBlinkCheckInEnabled, "blink preference persists independently")
        await settle(clock, clock.scheduled.count + 1)

        await clock.advance(to: t0 + .seconds(60))
        await settle(clock, clock.scheduled.count + 1)
        check(controller.activeCheckIn?.origin == .posture, "posture reminder follows its own toggle")
        check(platform.actions.contains("checkIn:posture"), "posture prompt presented")
        check(clock.lastDeadline == t0 + .seconds(65), "posture expiry is the next wakeup")

        platform.checkInDismiss?()
        check(controller.activeCheckIn == nil, "check-in Got it uses the shared command path")
        await settle(clock, clock.scheduled.count + 1)
        check(clock.lastDeadline == t0 + .seconds(80), "warning boundary is next while blink is disabled")

        controller.setBlinkCheckInEnabled(true)
        await settle(clock, clock.scheduled.count + 1)
        check(clock.lastDeadline == t0 + .seconds(80), "enabled blink reminder targets its cadence")

        await clock.advance(to: t0 + .seconds(80))
        await settle(clock, clock.scheduled.count + 1)
        check(
            controller.phase == .work(deadline: t0 + .seconds(100), warning: .headsUp),
            "heads-up keeps priority over a due reminder"
        )
        check(controller.activeCheckIn == nil, "overlapping reminder stays suppressed")
        check(
            platform.actions.filter { $0 == "checkIn:blink" }.count == 1,
            "suppressed reminder is not presented a second time"
        )
        controller.stop()
    }

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let preferences = InMemoryCheckInPreferences()
        let suppressionConfiguration = TimerConfiguration(
            workInterval: .seconds(100),
            breakDuration: .seconds(20),
            snoozeInterval: .seconds(30),
            headsUpLead: .seconds(20),
            headsUpDuration: .seconds(5),
            finalWarningDuration: .seconds(10),
            checkInDuration: .seconds(5),
            blinkCheckInOffsets: [.seconds(20)],
            postureCheckInOffsets: [.seconds(30)]
        )
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            preferences: preferences,
            configuration: suppressionConfiguration,
            now: t0
        )
        controller.start()
        await settle(clock, 1)
        controller.pause()
        check(controller.phase == .paused(remaining: .seconds(100)), "pause preserves work")
        check(controller.activeCheckIn == nil, "pause has no reminder")
        await clock.advance(to: t0 + .seconds(45))
        check(controller.phase == .paused(remaining: .seconds(100)), "stale reminder wakeup is rejected")

        controller.resume()
        await settle(clock, clock.scheduled.count + 1)
        check(clock.lastDeadline == t0 + .seconds(65), "cadence restarts after resume")
        await clock.advance(to: t0 + .seconds(65))
        await settle(clock, clock.scheduled.count + 1)
        check(controller.activeCheckIn?.origin == .blink, "reminder appears after resume")

        controller.screenUnavailable()
        check(controller.phase == .suspended, "lock suspends the timer")
        check(controller.activeCheckIn == nil, "lock clears the active reminder")
        check(platform.actions.contains("clear"), "lock removes the prompt surface")

        clock.current = t0 + .seconds(100)
        controller.screenAvailable()
        await settle(clock, clock.scheduled.count + 1)
        check(controller.activeCheckIn == nil, "unlock does not replay a stale reminder")
        check(clock.lastDeadline == t0 + .seconds(120), "cadence restarts from unlock")
        controller.stop()
    }

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            preferences: InMemoryCheckInPreferences(),
            configuration: configuration,
            now: t0
        )
        controller.start()
        await clock.advance(to: t0 + .seconds(100))
        check(platform.breakOrigin == .scheduled, "scheduled break overlay presented")
        platform.breakSnooze?()
        check(
            controller.phase == .work(deadline: t0 + .seconds(130), warning: .none),
            "break overlay snooze uses the shared command path"
        )
        await clock.advance(to: t0 + .seconds(130))
        check(platform.breakOrigin == .scheduled, "snoozed break opens again through the timer")
        platform.breakDismiss?()
        check(
            controller.phase == .work(deadline: t0 + .seconds(230), warning: .none),
            "break overlay dismiss uses the shared command path"
        )
        check(
            controller.performTimerCommand(.dismissBreak) == .unavailable,
            "unavailable overlay command is rejected before dispatch"
        )
        check(
            controller.performTimerCommand(.dismissCheckIn) == .unavailable,
            "check-in dismissal is unavailable without a prompt"
        )
        check(
            controller.performTimerCommand(.status) == .notHandled,
            "status is not a timer dispatch command"
        )
        controller.stop()
    }

    do {
        let clock = ManualTimerClock(t0)
        let platform = RecordingPlatform()
        let preferences = InMemoryCheckInPreferences()
        let controller = TimerController(
            platform: platform,
            clock: clock.clock,
            preferences: preferences,
            configuration: configuration,
            now: t0
        )
        let termination = TerminationRecorder()
        let service = TimerCommandService(
            controller: controller,
            termination: { termination.count += 1 }
        )
        controller.start()

        let initial = service.perform(.init(command: .status))
        check(initial.ok, "command status succeeds")
        check(initial.status?.phase == .work, "command status reports work")
        check(initial.status?.remainingSeconds == 100, "command status reports remaining seconds")
        check(initial.status?.availableCommands.contains(.pause) == true, "command status offers pause")

        let pause = service.perform(.init(command: .pause))
        check(pause.ok && controller.phase == .paused(remaining: .seconds(100)), "command pause matches GUI transition")
        check(pause.status?.availableCommands.contains(.resume) == true, "paused status offers resume")
        check(pause.status?.availableCommands.contains(.pause) == false, "paused status hides pause")

        let resume = service.perform(.init(command: .resume))
        check(resume.ok && controller.phase == .work(deadline: t0 + .seconds(100), warning: .none), "command resume matches GUI transition")

        let snooze = service.perform(.init(command: .snoozeBreak))
        check(!snooze.ok && snooze.error?.code == .unavailable, "command snooze rejects an unavailable phase")

        let chime = service.perform(.init(command: .setCompletionChime, enabled: true))
        check(chime.ok && controller.completionChime, "command sets the completion chime")
        let blink = service.perform(.init(command: .setBlinkCheckIn, enabled: false))
        check(blink.ok && !preferences.isBlinkCheckInEnabled, "command sets the blink preference")
        let posture = service.perform(.init(command: .setPostureCheckIn, enabled: false))
        check(posture.ok && !preferences.isPostureCheckInEnabled, "command sets the posture preference")

        let missingValue = service.perform(.init(command: .setBlinkCheckIn))
        check(!missingValue.ok && missingValue.error?.code == .invalidArgument, "command reports a missing toggle value")

        let breakNow = service.perform(.init(command: .takeBreakNow))
        check(breakNow.ok && controller.phase == .onBreak(deadline: t0 + .seconds(20), origin: .onDemand), "command take break now matches GUI transition")
        check(breakNow.status?.availableCommands.contains(.dismissBreak) == true, "on-demand break status offers end break")
        check(breakNow.status?.availableCommands.contains(.snoozeBreak) == false, "on-demand break status hides snooze")

        let endBreak = service.perform(.init(command: .dismissBreak))
        check(endBreak.ok && controller.phase == .work(deadline: t0 + .seconds(100), warning: .none), "command end break matches GUI transition")

        let quitExecution = service.execute(.init(command: .quit))
        check(quitExecution.response.ok, "command quit acknowledges before termination")
        check(termination.count == 0, "quit completion waits for the host acknowledgement")
        quitExecution.afterResponse?()
        check(termination.count == 1, "quit completion terminates once after acknowledgement")

        let quit = service.perform(.init(command: .quit))
        check(quit.ok && termination.count == 2, "GUI quit uses the shared completion handler")

        for command in TimerCommand.allCases {
            let request = TimerCommandRequest(command: command, enabled: command.requiresEnabledValue ? true : nil)
            guard let data = try? TimerCommandCodec.encode(request),
                  let decoded = try? TimerCommandCodec.decode(TimerCommandRequest.self, from: data) else {
                check(false, "command \(command.rawValue) JSON round trip")
                continue
            }
            check(decoded == request, "command \(command.rawValue) JSON round trip")
        }

        let guiEvents: [(TimerCommand, TimerEvent)] = [
            (.pause, .pause),
            (.resume, .resume),
            (.takeBreakNow, .takeBreakNow),
            (.snoozeBreak, .snoozeScheduledBreak),
            (.dismissBreak, .dismissBreak),
        ]
        for (command, event) in guiEvents {
            check(command.timerEvent == event, "GUI action \(command.rawValue) uses the shared timer event")
        }
        check(TimerCommand.dismissCheckIn.timerEvent == .dismissCheckIn, "check-in dismissal uses the shared timer event")
        controller.stop()
    }

    if failures.isEmpty {
        print("PASS: all app lifecycle checks passed")
    } else {
        print("FAIL: \(failures.count) app lifecycle check(s) failed")
        exit(1)
    }
}
