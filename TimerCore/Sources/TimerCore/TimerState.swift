public struct TimerState: Sendable, Equatable {
    public let configuration: TimerConfiguration
    public private(set) var phase: TimerPhase
    public private(set) var checkInSettings: CheckInSettings
    public private(set) var activeCheckIn: ActiveCheckIn?

    private var nextTransition: ContinuousClock.Instant?
    private var nextCheckIn: ScheduledCheckIn?
    private var workAnchor: ContinuousClock.Instant
    private var suspendedResume: SuspendedResume?
    private var onDemandRestore: OnDemandRestore?

    public init(
        configuration: TimerConfiguration = .productDefault,
        checkInSettings: CheckInSettings = .productDefault,
        now: ContinuousClock.Instant
    ) {
        self.configuration = configuration
        self.checkInSettings = checkInSettings
        self.onDemandRestore = nil
        self.suspendedResume = nil
        self.activeCheckIn = nil
        self.workAnchor = now
        self.phase = .work(deadline: now + configuration.workInterval, warning: .none)
        self.nextTransition = nil
        self.nextCheckIn = nil
        beginWork(deadline: now + configuration.workInterval, at: now)
    }

    public var nextDeadline: ContinuousClock.Instant? {
        [nextTransition, nextCheckIn?.due, activeCheckIn?.expiresAt].compactMap { $0 }.min()
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
        case .dismissCheckIn:
            dismissCheckIn()
        case .updateCheckInSettings(let settings):
            update(settings, at: now)
        }
    }

    private mutating func advance(to now: ContinuousClock.Instant) {
        if let active = activeCheckIn, now >= active.expiresAt {
            activeCheckIn = nil
        }
        switch phase {
        case .work(let deadline, _):
            if now >= deadline {
                startScheduledBreak(at: now)
            } else {
                let dueCheckIn = nextCheckIn
                applyWork(deadline: deadline, at: now)
                activateDueCheckIn(dueCheckIn, at: now)
            }
        case .onBreak(let deadline, let origin):
            clearCheckIn()
            if now >= deadline {
                completeBreak(origin: origin, at: now)
            }
        case .paused, .suspended:
            clearCheckIn()
        }
    }

    private mutating func pause(at now: ContinuousClock.Instant) {
        switch phase {
        case .work(let deadline, _):
            clearCheckIn()
            phase = .paused(remaining: deadline - now)
            nextTransition = nil
        case .paused, .onBreak, .suspended:
            break
        }
    }

    private mutating func resume(at now: ContinuousClock.Instant) {
        switch phase {
        case .paused(let remaining):
            beginWork(deadline: now + remaining, at: now)
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

    private mutating func dismissCheckIn() {
        activeCheckIn = nil
    }

    private mutating func update(_ settings: CheckInSettings, at now: ContinuousClock.Instant) {
        checkInSettings = settings
        if let active = activeCheckIn, !settings.isEnabled(active.origin) {
            activeCheckIn = nil
        }
        refreshCheckInSchedule(at: now)
    }

    private mutating func screenBecameUnavailable(at now: ContinuousClock.Instant) {
        clearCheckIn()
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
                beginWork(deadline: now + remaining, at: now)
            case .finalWarning?:
                beginWork(deadline: now + configuration.finalWarningDuration, at: now)
            case .paused(let remaining)?:
                phase = .paused(remaining: remaining)
                nextTransition = nil
                clearCheckIn()
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
                clearCheckIn()
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
            beginWork(deadline: now + remaining, at: now)
        case .paused(let remaining)?:
            phase = .paused(remaining: remaining)
            nextTransition = nil
            clearCheckIn()
        case nil:
            startWorkInterval(at: now)
        }
    }

    private mutating func suspend() {
        clearCheckIn()
        phase = .suspended
        nextTransition = nil
    }

    private mutating func startWorkInterval(at now: ContinuousClock.Instant) {
        beginWork(deadline: now + configuration.workInterval, at: now)
    }

    private mutating func startSnoozedWork(at now: ContinuousClock.Instant) {
        onDemandRestore = nil
        beginWork(deadline: now + configuration.snoozeInterval, at: now)
    }

    private mutating func startScheduledBreak(at now: ContinuousClock.Instant) {
        clearCheckIn()
        onDemandRestore = nil
        let deadline = now + configuration.breakDuration
        phase = .onBreak(deadline: deadline, origin: .scheduled)
        nextTransition = deadline
    }

    private mutating func startOnDemandBreak(at now: ContinuousClock.Instant) {
        clearCheckIn()
        let deadline = now + configuration.breakDuration
        phase = .onBreak(deadline: deadline, origin: .onDemand)
        nextTransition = deadline
    }

    private mutating func beginWork(deadline: ContinuousClock.Instant, at now: ContinuousClock.Instant) {
        workAnchor = now
        clearCheckIn()
        applyWork(deadline: deadline, at: now)
    }

    private mutating func applyWork(deadline: ContinuousClock.Instant, at now: ContinuousClock.Instant) {
        let timeline = workTimeline(deadline: deadline, now: now)
        phase = .work(deadline: deadline, warning: timeline.warning)
        nextTransition = timeline.next
        refreshCheckInSchedule(at: now)
    }

    private mutating func clearCheckIn() {
        activeCheckIn = nil
        nextCheckIn = nil
    }

    private mutating func refreshCheckInSchedule(at now: ContinuousClock.Instant) {
        guard case .work(let deadline, let warning) = phase else {
            nextCheckIn = nil
            return
        }
        guard warning == .none else {
            clearCheckIn()
            return
        }
        if let active = activeCheckIn, !checkInSettings.isEnabled(active.origin) {
            activeCheckIn = nil
        }
        nextCheckIn = scheduledCheckIn(after: now, deadline: deadline)
    }

    private mutating func activateDueCheckIn(
        _ scheduled: ScheduledCheckIn?,
        at now: ContinuousClock.Instant
    ) {
        guard case .work(_, let warning) = phase, warning == .none else { return }
        guard activeCheckIn == nil else { return }
        guard let scheduled, scheduled.due <= now else { return }
        let isStale = now >= scheduled.due + configuration.checkInDuration
        if !isStale, checkInSettings.isEnabled(scheduled.origin) {
            activeCheckIn = ActiveCheckIn(
                origin: scheduled.origin,
                expiresAt: now + configuration.checkInDuration
            )
        }
    }

    private func scheduledCheckIn(
        after now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant
    ) -> ScheduledCheckIn? {
        let warningStart = deadline - configuration.headsUpLead
        var candidates: [ScheduledCheckIn] = []
        if checkInSettings.blinkEnabled {
            candidates.append(contentsOf: configuration.blinkCheckInOffsets.map {
                ScheduledCheckIn(origin: .blink, due: workAnchor + $0)
            })
        }
        if checkInSettings.postureEnabled {
            candidates.append(contentsOf: configuration.postureCheckInOffsets.map {
                ScheduledCheckIn(origin: .posture, due: workAnchor + $0)
            })
        }
        return candidates
            .filter { $0.due > now && $0.due < warningStart }
            .min { $0.due < $1.due }
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

private struct ScheduledCheckIn: Sendable, Equatable {
    let origin: CheckInOrigin
    let due: ContinuousClock.Instant
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
