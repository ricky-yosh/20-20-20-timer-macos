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

public enum CheckInOrigin: Sendable, Equatable {
    case blink
    case posture
}

public struct CheckInSettings: Sendable, Equatable {
    public var blinkEnabled: Bool
    public var postureEnabled: Bool

    public init(blinkEnabled: Bool = true, postureEnabled: Bool = true) {
        self.blinkEnabled = blinkEnabled
        self.postureEnabled = postureEnabled
    }

    public static let productDefault = CheckInSettings()

    public func isEnabled(_ origin: CheckInOrigin) -> Bool {
        switch origin {
        case .blink:
            return blinkEnabled
        case .posture:
            return postureEnabled
        }
    }
}

public struct ActiveCheckIn: Sendable, Equatable {
    public let origin: CheckInOrigin
    public let expiresAt: ContinuousClock.Instant

    public init(origin: CheckInOrigin, expiresAt: ContinuousClock.Instant) {
        self.origin = origin
        self.expiresAt = expiresAt
    }
}

public enum TimerEvent: Sendable, Equatable {
    case deadlineReached
    case pause
    case resume
    case takeBreakNow
    case snoozeScheduledBreak
    case dismissBreak
    case dismissCheckIn
    case screenUnavailable
    case screenAvailable
    case updateCheckInSettings(CheckInSettings)
}
