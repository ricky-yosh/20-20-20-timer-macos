public enum WarningPhase: Sendable, Equatable {
    case none
    case headsUp
    case finalCountdown
}

public enum BreakOrigin: Sendable, Equatable {
    case scheduled
    case onDemand
}

public enum TimerPhase: Sendable, Equatable {
    case work(deadline: ContinuousClock.Instant, warning: WarningPhase)
    case paused(remaining: Duration)
    case onBreak(deadline: ContinuousClock.Instant, origin: BreakOrigin)
    case suspended
}

public enum TimerEvent: Sendable, Equatable {
    case deadlineReached
    case pause
    case resume
    case takeBreakNow
    case snoozeScheduledBreak
    case dismissBreak
    case screenUnavailable
    case screenAvailable
}
