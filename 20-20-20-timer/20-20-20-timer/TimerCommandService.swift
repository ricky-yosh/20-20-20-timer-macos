import AppKit
import Foundation
import TimerCore

nonisolated struct TimerCommandExecution: Sendable {
    let response: TimerCommandResponse
    let afterResponse: (@MainActor @Sendable () -> Void)?

    init(
        response: TimerCommandResponse,
        afterResponse: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.response = response
        self.afterResponse = afterResponse
    }
}

@MainActor
final class TimerCommandService {
    static let shared = TimerCommandService(
        controller: .shared,
        termination: { NSApplication.shared.terminate(nil) }
    )

    private let controller: TimerController
    private let termination: (@MainActor @Sendable () -> Void)?

    init(
        controller: TimerController,
        termination: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.controller = controller
        self.termination = termination
    }

    func perform(_ request: TimerCommandRequest) -> TimerCommandResponse {
        let execution = execute(request)
        execution.afterResponse?()
        return execution.response
    }

    func execute(_ request: TimerCommandRequest) -> TimerCommandExecution {
        switch request.command {
        case .status:
            return TimerCommandExecution(response: .success(status()))
        case .quit:
            return TimerCommandExecution(
                response: .success(status()),
                afterResponse: termination
            )
        case .setCompletionChime, .setBlinkCheckIn, .setPostureCheckIn:
            guard let enabled = request.enabled else {
                return TimerCommandExecution(
                    response: .failure(
                        .invalidArgument,
                        "\(request.command.rawValue) requires an on or off value."
                    )
                )
            }
            apply(enabled, for: request.command)
            return TimerCommandExecution(response: .success(status()))
        case .start, .pause, .resume, .takeBreakNow, .dismissBreak, .snoozeBreak, .dismissCheckIn:
            switch controller.performTimerCommand(request.command) {
            case .performed:
                return TimerCommandExecution(response: .success(status()))
            case .unavailable:
                return TimerCommandExecution(response: unavailable(request.command))
            case .notHandled:
                return TimerCommandExecution(
                    response: .failure(
                        .invalidCommand,
                        "\(request.command.rawValue) is not a timer command."
                    )
                )
            }
        }
    }

    private func apply(_ enabled: Bool, for command: TimerCommand) {
        switch command {
        case .setCompletionChime:
            controller.setCompletionChimeEnabled(enabled)
        case .setBlinkCheckIn:
            controller.setBlinkCheckInEnabled(enabled)
        case .setPostureCheckIn:
            controller.setPostureCheckInEnabled(enabled)
        case .status, .start, .pause, .resume, .takeBreakNow, .dismissBreak, .snoozeBreak, .dismissCheckIn, .quit:
            break
        }
    }

    private func unavailable(_ command: TimerCommand) -> TimerCommandResponse {
        .failure(
            .unavailable,
            "\(command.rawValue) is unavailable while \(phaseDescription)."
        )
    }

    private var phaseDescription: String {
        switch controller.phase {
        case .work(_, let warning):
            switch warning {
            case .none:
                return "the timer is working"
            case .headsUp:
                return "the break heads-up is showing"
            case .finalCountdown:
                return "the final countdown is showing"
            }
        case .paused:
            return "the timer is paused"
        case .onBreak(_, let origin):
            switch origin {
            case .scheduled:
                return "a scheduled break is running"
            case .onDemand:
                return "an on-demand break is running"
            }
        case .suspended:
            return "the screen is unavailable"
        }
    }

    private func status() -> TimerCommandStatus {
        let now = controller.currentInstant
        let phase = controller.phase
        let warning: TimerCommandWarning?
        let origin: TimerCommandBreakOrigin?
        let remaining: Int?

        switch phase {
        case .work(let deadline, let workWarning):
            warning = commandWarning(workWarning)
            origin = nil
            remaining = seconds(deadline - now)
        case .paused(let pausedRemaining):
            warning = nil
            origin = nil
            remaining = seconds(pausedRemaining)
        case .onBreak(let deadline, let breakOrigin):
            warning = nil
            origin = commandOrigin(breakOrigin)
            remaining = seconds(deadline - now)
        case .suspended:
            warning = nil
            origin = nil
            remaining = nil
        }

        return TimerCommandStatus(
            phase: commandPhase(phase),
            warning: warning,
            breakOrigin: origin,
            remainingSeconds: remaining,
            isCompletionChimeEnabled: controller.completionChime,
            isBlinkCheckInEnabled: controller.isBlinkCheckInEnabled,
            isPostureCheckInEnabled: controller.isPostureCheckInEnabled,
            activeCheckIn: controller.activeCheckIn.map(commandCheckIn),
            availableCommands: TimerCommand.available(
                in: phase,
                activeCheckIn: controller.activeCheckIn
            )
        )
    }

    private func commandPhase(_ phase: TimerPhase) -> TimerCommandPhase {
        switch phase {
        case .work:
            return .work
        case .paused:
            return .paused
        case .onBreak:
            return .onBreak
        case .suspended:
            return .suspended
        }
    }

    private func commandWarning(_ warning: WarningPhase) -> TimerCommandWarning {
        switch warning {
        case .none:
            return .none
        case .headsUp:
            return .headsUp
        case .finalCountdown:
            return .finalCountdown
        }
    }

    private func commandOrigin(_ origin: BreakOrigin) -> TimerCommandBreakOrigin {
        switch origin {
        case .scheduled:
            return .scheduled
        case .onDemand:
            return .onDemand
        }
    }

    private func commandCheckIn(_ checkIn: ActiveCheckIn) -> TimerCommandCheckIn {
        switch checkIn.origin {
        case .blink:
            return .blink
        case .posture:
            return .posture
        }
    }

    private func seconds(_ duration: Duration) -> Int {
        let components = duration.components
        let total = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0, Int(total.rounded(.up)))
    }
}
