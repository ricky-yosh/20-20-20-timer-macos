public struct TimerState: Sendable, Equatable {
    public let configuration: TimerConfiguration
    public private(set) var phase: TimerPhase

    private var nextTransition: ContinuousClock.Instant?
    private var suspendedResume: SuspendedResume?
    private var onDemandRestore: OnDemandRestore?

    public init(configuration: TimerConfiguration = .productDefault, now: ContinuousClock.Instant) {
        self.configuration = configuration
        self.onDemandRestore = nil
        self.suspendedResume = nil
        self.phase = .work(deadline: now + configuration.workInterval, warning: .none)
        self.nextTransition = nil
        applyWork(deadline: now + configuration.workInterval, at: now)
    }

    public var nextDeadline: ContinuousClock.Instant? {
        nextTransition
    }

    public mutating func handle(_ event: TimerEvent, now: ContinuousClock.Instant) {
        switch event {
        case .screenUnavailable:
            screenBecameUnavailable(at: now)
        case .screenAvailable:
            screenBecameAvailable(at: now)
        case .deadlineReached:
            advance(to: now)
        case .pause:
            advance(to: now)
            pause(at: now)
        case .resume:
            advance(to: now)
            resume(at: now)
        case .takeBreakNow:
            advance(to: now)
            takeBreakNow(at: now)
        case .snoozeScheduledBreak:
            advance(to: now)
            snoozeScheduledBreak(at: now)
        case .dismissBreak:
            advance(to: now)
            dismissBreak(at: now)
        }
    }

    private mutating func advance(to now: ContinuousClock.Instant) {
        switch phase {
        case .work(let deadline, _):
            if now >= deadline {
                startScheduledBreak(at: now)
            } else {
                applyWork(deadline: deadline, at: now)
            }
        case .onBreak(let deadline, let origin):
            if now >= deadline {
                completeBreak(origin: origin, at: now)
            }
        case .paused, .suspended:
            break
        }
    }

    private mutating func pause(at now: ContinuousClock.Instant) {
        switch phase {
        case .work(let deadline, _):
            phase = .paused(remaining: deadline - now)
            nextTransition = nil
        case .paused, .onBreak, .suspended:
            break
        }
    }

    private mutating func resume(at now: ContinuousClock.Instant) {
        switch phase {
        case .paused(let remaining):
            applyWork(deadline: now + remaining, at: now)
        case .work, .onBreak, .suspended:
            break
        }
    }

    private mutating func takeBreakNow(at now: ContinuousClock.Instant) {
        switch phase {
        case .work(let deadline, _):
            onDemandRestore = .work(remaining: deadline - now)
            startOnDemandBreak(at: now)
        case .paused(let remaining):
            onDemandRestore = .paused(remaining: remaining)
            startOnDemandBreak(at: now)
        case .onBreak, .suspended:
            break
        }
    }

    private mutating func snoozeScheduledBreak(at now: ContinuousClock.Instant) {
        switch phase {
        case .work(_, let warning):
            switch warning {
            case .headsUp, .finalCountdown:
                startSnoozedWork(at: now)
            case .none:
                break
            }
        case .onBreak(_, let origin):
            switch origin {
            case .scheduled:
                startSnoozedWork(at: now)
            case .onDemand:
                break
            }
        case .paused, .suspended:
            break
        }
    }

    private mutating func dismissBreak(at now: ContinuousClock.Instant) {
        switch phase {
        case .onBreak(_, let origin):
            switch origin {
            case .scheduled:
                onDemandRestore = nil
                startWorkInterval(at: now)
            case .onDemand:
                restoreAfterOnDemandBreak(at: now)
            }
        case .work, .paused, .suspended:
            break
        }
    }

    private mutating func screenBecameUnavailable(at now: ContinuousClock.Instant) {
        switch phase {
        case .work(let deadline, _):
            if deadline - now <= configuration.finalWarningDuration {
                suspendedResume = .finalWarning
            } else {
                suspendedResume = .work(remaining: deadline - now)
            }
            onDemandRestore = nil
            suspend()
        case .paused(let remaining):
            suspendedResume = .paused(remaining: remaining)
            onDemandRestore = nil
            suspend()
        case .onBreak:
            switch onDemandRestore {
            case .paused(_)?:
                suspendedResume = .paused(remaining: configuration.workInterval)
            case .work(_)?, nil:
                suspendedResume = .freshWorkInterval
            }
            onDemandRestore = nil
            suspend()
        case .suspended:
            break
        }
    }

    private mutating func screenBecameAvailable(at now: ContinuousClock.Instant) {
        switch phase {
        case .suspended:
            let resume = suspendedResume
            suspendedResume = nil
            switch resume {
            case .work(let remaining)?:
                applyWork(deadline: now + remaining, at: now)
            case .finalWarning?:
                applyWork(deadline: now + configuration.finalWarningDuration, at: now)
            case .paused(let remaining)?:
                phase = .paused(remaining: remaining)
                nextTransition = nil
            case .freshWorkInterval?, nil:
                startWorkInterval(at: now)
            }
        case .work, .paused, .onBreak:
            break
        }
    }

    private mutating func completeBreak(origin: BreakOrigin, at now: ContinuousClock.Instant) {
        switch origin {
        case .scheduled:
            onDemandRestore = nil
            startWorkInterval(at: now)
        case .onDemand:
            let restore = onDemandRestore
            onDemandRestore = nil
            switch restore {
            case .paused(_)?:
                phase = .paused(remaining: configuration.workInterval)
                nextTransition = nil
            case .work(_)?, nil:
                startWorkInterval(at: now)
            }
        }
    }

    private mutating func restoreAfterOnDemandBreak(at now: ContinuousClock.Instant) {
        let restore = onDemandRestore
        onDemandRestore = nil
        switch restore {
        case .work(let remaining)?:
            applyWork(deadline: now + remaining, at: now)
        case .paused(let remaining)?:
            phase = .paused(remaining: remaining)
            nextTransition = nil
        case nil:
            startWorkInterval(at: now)
        }
    }

    private mutating func suspend() {
        phase = .suspended
        nextTransition = nil
    }

    private mutating func startWorkInterval(at now: ContinuousClock.Instant) {
        applyWork(deadline: now + configuration.workInterval, at: now)
    }

    private mutating func startSnoozedWork(at now: ContinuousClock.Instant) {
        onDemandRestore = nil
        applyWork(deadline: now + configuration.snoozeInterval, at: now)
    }

    private mutating func startScheduledBreak(at now: ContinuousClock.Instant) {
        onDemandRestore = nil
        let deadline = now + configuration.breakDuration
        phase = .onBreak(deadline: deadline, origin: .scheduled)
        nextTransition = deadline
    }

    private mutating func startOnDemandBreak(at now: ContinuousClock.Instant) {
        let deadline = now + configuration.breakDuration
        phase = .onBreak(deadline: deadline, origin: .onDemand)
        nextTransition = deadline
    }

    private mutating func applyWork(deadline: ContinuousClock.Instant, at now: ContinuousClock.Instant) {
        let timeline = workTimeline(deadline: deadline, now: now)
        phase = .work(deadline: deadline, warning: timeline.warning)
        nextTransition = timeline.next
    }

    private func workTimeline(
        deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> (warning: WarningPhase, next: ContinuousClock.Instant) {
        let headsUpStart = deadline - configuration.headsUpLead
        let headsUpEnd = headsUpStart + configuration.headsUpDuration
        let finalStart = deadline - configuration.finalWarningDuration

        let warning: WarningPhase
        if now >= finalStart {
            warning = .finalCountdown
        } else if now >= headsUpStart && now < headsUpEnd {
            warning = .headsUp
        } else {
            warning = .none
        }

        let boundaries = [headsUpStart, headsUpEnd, finalStart, deadline]
        let next = boundaries.filter { $0 > now }.min() ?? deadline
        return (warning, next)
    }
}

private enum SuspendedResume: Sendable, Equatable {
    case work(remaining: Duration)
    case finalWarning
    case paused(remaining: Duration)
    case freshWorkInterval
}

private enum OnDemandRestore: Sendable, Equatable {
    case work(remaining: Duration)
    case paused(remaining: Duration)
}
