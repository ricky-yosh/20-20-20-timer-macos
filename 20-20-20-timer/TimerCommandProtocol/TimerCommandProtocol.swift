import Foundation
import TimerCore

nonisolated public enum TimerCommand: String, Codable, Sendable, CaseIterable {
    case status
    case start
    case pause
    case resume
    case takeBreakNow = "take-break-now"
    case dismissBreak = "dismiss-break"
    case snoozeBreak = "snooze-break"
    case dismissCheckIn = "dismiss-check-in"
    case quit
    case setCompletionChime = "set-completion-chime"
    case setBlinkCheckIn = "set-blink-check-in"
    case setPostureCheckIn = "set-posture-check-in"

    public var timerEvent: TimerEvent? {
        switch self {
        case .pause:
            return .pause
        case .resume:
            return .resume
        case .takeBreakNow:
            return .takeBreakNow
        case .snoozeBreak:
            return .snoozeScheduledBreak
        case .dismissBreak:
            return .dismissBreak
        case .dismissCheckIn:
            return .dismissCheckIn
        case .status, .start, .quit, .setCompletionChime, .setBlinkCheckIn, .setPostureCheckIn:
            return nil
        }
    }

    public var requiresEnabledValue: Bool {
        switch self {
        case .setCompletionChime, .setBlinkCheckIn, .setPostureCheckIn:
            return true
        case .status, .start, .pause, .resume, .takeBreakNow, .dismissBreak, .snoozeBreak, .dismissCheckIn, .quit:
            return false
        }
    }
}

nonisolated public struct TimerCommandRequest: Codable, Sendable, Equatable {
    public let command: TimerCommand
    public let enabled: Bool?

    public init(command: TimerCommand, enabled: Bool? = nil) {
        self.command = command
        self.enabled = enabled
    }
}

nonisolated public enum TimerCommandPhase: String, Codable, Sendable {
    case work
    case paused
    case onBreak = "on-break"
    case suspended
}

nonisolated public enum TimerCommandWarning: String, Codable, Sendable {
    case none
    case headsUp = "heads-up"
    case finalCountdown = "final-countdown"
}

nonisolated public enum TimerCommandBreakOrigin: String, Codable, Sendable {
    case scheduled
    case onDemand = "on-demand"
}

nonisolated public enum TimerCommandCheckIn: String, Codable, Sendable {
    case blink
    case posture
}

nonisolated public struct TimerCommandStatus: Codable, Sendable, Equatable {
    public let phase: TimerCommandPhase
    public let warning: TimerCommandWarning?
    public let breakOrigin: TimerCommandBreakOrigin?
    public let remainingSeconds: Int?
    public let isCompletionChimeEnabled: Bool
    public let isBlinkCheckInEnabled: Bool
    public let isPostureCheckInEnabled: Bool
    public let activeCheckIn: TimerCommandCheckIn?
    public let availableCommands: [TimerCommand]

    public init(
        phase: TimerCommandPhase,
        warning: TimerCommandWarning?,
        breakOrigin: TimerCommandBreakOrigin?,
        remainingSeconds: Int?,
        isCompletionChimeEnabled: Bool,
        isBlinkCheckInEnabled: Bool,
        isPostureCheckInEnabled: Bool,
        activeCheckIn: TimerCommandCheckIn?,
        availableCommands: [TimerCommand]
    ) {
        self.phase = phase
        self.warning = warning
        self.breakOrigin = breakOrigin
        self.remainingSeconds = remainingSeconds
        self.isCompletionChimeEnabled = isCompletionChimeEnabled
        self.isBlinkCheckInEnabled = isBlinkCheckInEnabled
        self.isPostureCheckInEnabled = isPostureCheckInEnabled
        self.activeCheckIn = activeCheckIn
        self.availableCommands = availableCommands
    }
}

nonisolated public enum TimerCommandErrorCode: String, Codable, Sendable {
    case invalidCommand = "invalid-command"
    case invalidArgument = "invalid-argument"
    case unavailable
    case appNotRunning = "app-not-running"
    case transportFailure = "transport-failure"
    case protocolFailure = "protocol-failure"

    public var exitCode: Int32 {
        switch self {
        case .invalidCommand, .invalidArgument:
            return 2
        case .appNotRunning:
            return 3
        case .unavailable:
            return 4
        case .transportFailure, .protocolFailure:
            return 5
        }
    }
}

nonisolated public struct TimerCommandError: Codable, Sendable, Equatable {
    public let code: TimerCommandErrorCode
    public let message: String

    public init(code: TimerCommandErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

nonisolated public struct TimerCommandResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let status: TimerCommandStatus?
    public let error: TimerCommandError?

    public init(ok: Bool, status: TimerCommandStatus?, error: TimerCommandError?) {
        self.ok = ok
        self.status = status
        self.error = error
    }

    public static func success(_ status: TimerCommandStatus) -> TimerCommandResponse {
        TimerCommandResponse(ok: true, status: status, error: nil)
    }

    public static func failure(_ code: TimerCommandErrorCode, _ message: String) -> TimerCommandResponse {
        TimerCommandResponse(
            ok: false,
            status: nil,
            error: TimerCommandError(code: code, message: message)
        )
    }
}

nonisolated public enum TimerCommandCodec {
    public static func encode<Value: Encodable>(_ value: Value, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

public extension TimerCommand {
    func isAvailable(in phase: TimerPhase, activeCheckIn: ActiveCheckIn?) -> Bool {
        switch self {
        case .status, .start, .quit, .setCompletionChime, .setBlinkCheckIn, .setPostureCheckIn:
            return true
        case .pause:
            if case .work = phase {
                return true
            }
            return false
        case .resume:
            if case .paused = phase {
                return true
            }
            return false
        case .takeBreakNow:
            switch phase {
            case .work, .paused:
                return true
            case .onBreak, .suspended:
                return false
            }
        case .snoozeBreak:
            switch phase {
            case .work(_, let warning):
                return warning != .none
            case .onBreak(_, let origin):
                return origin == .scheduled
            case .paused, .suspended:
                return false
            }
        case .dismissBreak:
            if case .onBreak = phase {
                return true
            }
            return false
        case .dismissCheckIn:
            return activeCheckIn != nil
        }
    }

    static func available(
        in phase: TimerPhase,
        activeCheckIn: ActiveCheckIn?
    ) -> [TimerCommand] {
        allCases.filter { $0.isAvailable(in: phase, activeCheckIn: activeCheckIn) }
    }
}
