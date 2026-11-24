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
    finalWarningDuration: .seconds(3)
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
    func clear()
    func playCompletionChime()
}

extension TimerPlatform: TimerPlatformControlling {}

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
    @Published var completionChime = false

    private var state: TimerState
    private var nextTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var started = false
    private let clock: TimerClock
    private let platform: any TimerPlatformControlling

    init(
        platform: any TimerPlatformControlling,
        clock: TimerClock? = nil,
        configuration: TimerConfiguration = .productDefault,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        self.platform = platform
        self.clock = clock ?? .systemClock()
        self.state = TimerState(configuration: configuration, now: now)
        self.phase = state.phase
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

    func send(_ event: TimerEvent) {
        send(event, now: clock.now())
    }

    func send(_ event: TimerEvent, now: ContinuousClock.Instant) {
        let previous = state.phase
        state.handle(event, now: now)
        let current = state.phase
        phase = current
        if current != previous {
            route(from: overlay(for: previous), to: overlay(for: current), event: event)
        }
        scheduleNext()
    }

    func pause() { send(.pause) }
    func resume() { send(.resume) }
    func takeBreakNow() { send(.takeBreakNow) }
    func snoozeScheduledBreak() { send(.snoozeScheduledBreak) }
    func dismissBreak() { send(.dismissBreak) }
    func screenUnavailable() { send(.screenUnavailable) }
    func screenAvailable() { send(.screenAvailable) }

    func deadlineReached(token: UInt64, deadline: ContinuousClock.Instant) {
        guard token == generation, state.nextDeadline == deadline else { return }
        send(.deadlineReached)
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
        present(overlay(for: phase))
    }

    private func present(_ overlay: Overlay) {
        switch overlay {
        case .none:
            break
        case .headsUp:
            platform.showHeadsUp { [weak self] in self?.snoozeScheduledBreak() }
        case .finalCountdown(let deadline):
            platform.showFinalCountdown(deadline: deadline)
        case .onBreak(let deadline, let origin):
            let dismiss: @MainActor () -> Void = { [weak self] in self?.dismissBreak() }
            let snooze: (@MainActor () -> Void)?
            switch origin {
            case .scheduled:
                snooze = { [weak self] in self?.snoozeScheduledBreak() }
            case .onDemand:
                snooze = nil
            }
            platform.showBreak(deadline: deadline, origin: origin, dismiss: dismiss, snooze: snooze)
        }
    }

    private func overlay(for phase: TimerPhase) -> Overlay {
        switch phase {
        case .work(let deadline, let warning):
            switch warning {
            case .none:
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
    }
}
