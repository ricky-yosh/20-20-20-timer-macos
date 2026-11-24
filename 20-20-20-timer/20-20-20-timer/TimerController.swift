import Combine
import Foundation
import SwiftUI
import TimerCore

#if DEBUG
private let demoTimerConfiguration = TimerConfiguration(
    workInterval: .seconds(12),
    breakDuration: .seconds(6),
    snoozeInterval: .seconds(8),
    headsUpLead: .seconds(6),
    headsUpDuration: .seconds(2),
    finalWarningDuration: .seconds(3),
    checkInDuration: .seconds(2),
    blinkCheckInOffsets: [.seconds(2)],
    postureCheckInOffsets: [.seconds(4)]
)
#endif

@MainActor
final class TimerClock {
    let now: @MainActor () -> ContinuousClock.Instant
    let sleep: @MainActor (UInt64, ContinuousClock.Instant) async -> Void

    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant,
        sleep: @escaping @MainActor (UInt64, ContinuousClock.Instant) async -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    static func systemClock() -> TimerClock {
        TimerClock(
            now: { ContinuousClock.now },
            sleep: { _, deadline in
                try? await ContinuousClock().sleep(until: deadline)
            }
        )
    }
}

@MainActor
protocol TimerPlatformControlling: AnyObject {
    func start(
        onAvailability: @escaping @MainActor (Bool) -> Void,
        onDisplayChange: @escaping @MainActor () -> Void
    )
    func showHeadsUp(snooze: @escaping @MainActor () -> Void)
    func showFinalCountdown(deadline: ContinuousClock.Instant)
    func showBreak(
        deadline: ContinuousClock.Instant,
        origin: BreakOrigin,
        dismiss: @escaping @MainActor () -> Void,
        snooze: (@MainActor () -> Void)?
    )
    func showCheckIn(origin: CheckInOrigin, dismiss: @escaping @MainActor () -> Void)
    func clear()
    func playCompletionChime()
}

extension TimerPlatform: TimerPlatformControlling {}

enum TimerCommandDispatchResult: Equatable {
    case performed
    case unavailable
    case notHandled
}

@MainActor
final class TimerController: ObservableObject {
    static let shared: TimerController = {
        #if DEBUG
        let configuration = CommandLine.arguments.contains("--demo-timings")
            ? demoTimerConfiguration
            : TimerConfiguration.productDefault
        #else
        let configuration = TimerConfiguration.productDefault
        #endif
        return TimerController(platform: TimerPlatform(), configuration: configuration)
    }()

    @Published private(set) var phase: TimerPhase
    @Published private(set) var activeCheckIn: ActiveCheckIn?
    @Published private(set) var isBlinkCheckInEnabled: Bool
    @Published private(set) var isPostureCheckInEnabled: Bool
    @Published var completionChime = false

    private var state: TimerState
    private var nextTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var started = false
    private let clock: TimerClock
    private let platform: any TimerPlatformControlling
    private let preferences: any CheckInPreferencesStoring

    init(
        platform: any TimerPlatformControlling,
        clock: TimerClock? = nil,
        preferences: any CheckInPreferencesStoring = UserDefaultsCheckInPreferences(),
        configuration: TimerConfiguration = .productDefault,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        let settings = CheckInSettings(
            blinkEnabled: preferences.isBlinkCheckInEnabled,
            postureEnabled: preferences.isPostureCheckInEnabled
        )
        self.platform = platform
        self.clock = clock ?? .systemClock()
        self.preferences = preferences
        self.isBlinkCheckInEnabled = settings.blinkEnabled
        self.isPostureCheckInEnabled = settings.postureEnabled
        self.state = TimerState(configuration: configuration, checkInSettings: settings, now: now)
        self.phase = state.phase
        self.activeCheckIn = state.activeCheckIn
    }

    deinit {
        nextTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        platform.start(
            onAvailability: { [weak self] available in
                self?.send(available ? .screenAvailable : .screenUnavailable)
            },
            onDisplayChange: { [weak self] in
                self?.redisplayOverlays()
            }
        )
        scheduleNext()
    }

    func stop() {
        nextTask?.cancel()
        nextTask = nil
        generation &+= 1
        platform.clear()
    }

    var currentInstant: ContinuousClock.Instant {
        clock.now()
    }

    func setCompletionChimeEnabled(_ enabled: Bool) {
        completionChime = enabled
    }

    func setBlinkCheckInEnabled(_ enabled: Bool) {
        guard enabled != isBlinkCheckInEnabled else { return }
        isBlinkCheckInEnabled = enabled
        preferences.isBlinkCheckInEnabled = enabled
        send(.updateCheckInSettings(checkInSettings))
    }

    func setPostureCheckInEnabled(_ enabled: Bool) {
        guard enabled != isPostureCheckInEnabled else { return }
        isPostureCheckInEnabled = enabled
        preferences.isPostureCheckInEnabled = enabled
        send(.updateCheckInSettings(checkInSettings))
    }

    @discardableResult
    func performTimerCommand(_ command: TimerCommand) -> TimerCommandDispatchResult {
        switch command {
        case .start:
            start()
            return .performed
        case .pause, .resume, .takeBreakNow, .dismissBreak, .snoozeBreak, .dismissCheckIn:
            guard command.isAvailable(in: phase, activeCheckIn: activeCheckIn),
                  let event = command.timerEvent else {
                return .unavailable
            }
            send(event)
            return .performed
        case .status, .quit, .setCompletionChime, .setBlinkCheckIn, .setPostureCheckIn:
            return .notHandled
        }
    }

    func send(_ event: TimerEvent) {
        send(event, now: clock.now())
    }

    func send(_ event: TimerEvent, now: ContinuousClock.Instant) {
        let previousPhase = state.phase
        let previousCheckIn = state.activeCheckIn
        state.handle(event, now: now)
        let currentPhase = state.phase
        let currentCheckIn = state.activeCheckIn
        if phase != currentPhase {
            phase = currentPhase
        }
        if activeCheckIn != currentCheckIn {
            activeCheckIn = currentCheckIn
        }
        if currentPhase != previousPhase || currentCheckIn != previousCheckIn {
            route(
                from: overlay(for: previousPhase, checkIn: previousCheckIn),
                to: overlay(for: currentPhase, checkIn: currentCheckIn),
                event: event
            )
        }
        scheduleNext()
    }

    func pause() { performTimerCommand(.pause) }
    func resume() { performTimerCommand(.resume) }
    func takeBreakNow() { performTimerCommand(.takeBreakNow) }
    func snoozeScheduledBreak() { performTimerCommand(.snoozeBreak) }
    func dismissBreak() { performTimerCommand(.dismissBreak) }
    func screenUnavailable() { send(.screenUnavailable) }
    func screenAvailable() { send(.screenAvailable) }

    func deadlineReached(token: UInt64, deadline: ContinuousClock.Instant) {
        guard token == generation, state.nextDeadline == deadline else { return }
        send(.deadlineReached)
    }

    private var checkInSettings: CheckInSettings {
        CheckInSettings(
            blinkEnabled: isBlinkCheckInEnabled,
            postureEnabled: isPostureCheckInEnabled
        )
    }

    private func scheduleNext() {
        nextTask?.cancel()
        nextTask = nil
        generation &+= 1
        guard let deadline = state.nextDeadline else { return }
        let token = generation
        let clock = self.clock
        nextTask = Task { @MainActor [weak self] in
            await clock.sleep(token, deadline)
            self?.deadlineReached(token: token, deadline: deadline)
        }
    }

    private func route(from old: Overlay, to new: Overlay, event: TimerEvent) {
        if old != new {
            if old != .none {
                platform.clear()
            }
            if case .onBreak = old, event == .deadlineReached, completionChime {
                platform.playCompletionChime()
            }
            present(new)
        }
    }

    private func redisplayOverlays() {
        present(overlay(for: phase, checkIn: activeCheckIn))
    }

    private func present(_ overlay: Overlay) {
        switch overlay {
        case .none:
            break
        case .headsUp:
            platform.showHeadsUp { [weak self] in
                self?.performTimerCommand(.snoozeBreak)
            }
        case .finalCountdown(let deadline):
            platform.showFinalCountdown(deadline: deadline)
        case .onBreak(let deadline, let origin):
            let dismiss: @MainActor () -> Void = { [weak self] in
                self?.performTimerCommand(.dismissBreak)
            }
            let snooze: (@MainActor () -> Void)?
            switch origin {
            case .scheduled:
                snooze = { [weak self] in self?.performTimerCommand(.snoozeBreak) }
            case .onDemand:
                snooze = nil
            }
            platform.showBreak(deadline: deadline, origin: origin, dismiss: dismiss, snooze: snooze)
        case .checkIn(let origin):
            platform.showCheckIn(origin: origin) { [weak self] in
                self?.performTimerCommand(.dismissCheckIn)
            }
        }
    }

    private func overlay(for phase: TimerPhase, checkIn: ActiveCheckIn?) -> Overlay {
        switch phase {
        case .work(let deadline, let warning):
            switch warning {
            case .none:
                if let checkIn {
                    return .checkIn(origin: checkIn.origin)
                }
                return .none
            case .headsUp:
                return .headsUp
            case .finalCountdown:
                return .finalCountdown(deadline: deadline)
            }
        case .paused, .suspended:
            return .none
        case .onBreak(let deadline, let origin):
            return .onBreak(deadline: deadline, origin: origin)
        }
    }

    private enum Overlay: Equatable {
        case none
        case headsUp
        case finalCountdown(deadline: ContinuousClock.Instant)
        case onBreak(deadline: ContinuousClock.Instant, origin: BreakOrigin)
        case checkIn(origin: CheckInOrigin)
    }
}
