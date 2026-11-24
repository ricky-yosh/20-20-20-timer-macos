import Combine
import SwiftUI
import TimerCore

@MainActor
struct TimerStatusItemLabel: View {
    private let phase: TimerPhase
    @State private var now = ContinuousClock.now
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(phase: TimerPhase) {
        self.phase = phase
    }

    var body: some View {
        Text(labelText)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)
            .accessibilityLabel(accessibilityText)
            .onReceive(ticker) { _ in
                now = ContinuousClock.now
            }
    }

    private var labelText: String {
        switch phase {
        case .work(let deadline, _), .onBreak(let deadline, _):
            return compact(RemainingTime(deadline: deadline, now: now).seconds)
        case .paused(let remaining):
            return compact(RemainingTime(duration: remaining).seconds)
        case .suspended:
            return "—"
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .work(let deadline, _), .onBreak(let deadline, _):
            let remaining = RemainingTime(deadline: deadline, now: now)
            return "\(remaining.spokenText) remaining"
        case .paused(let remaining):
            let remaining = RemainingTime(duration: remaining)
            return "Paused, \(remaining.spokenText) remaining"
        case .suspended:
            return "Suspended while the screen is unavailable"
        }
    }

    private func compact(_ seconds: Int) -> String {
        if seconds >= 60 {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }
}
