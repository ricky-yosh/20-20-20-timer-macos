import SwiftUI

@MainActor
struct FinalCountdownView: View {
    private let deadline: ContinuousClock.Instant

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: refreshInterval)) { _ in
            let remaining = RemainingTime(deadline: deadline, now: ContinuousClock.now)
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.74))
                Circle()
                    .strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
                Text("\(remaining.seconds)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(reduceMotion ? ContentTransition.identity : .numericText(countsDown: true))
            }
            .frame(width: 52, height: 52)
            .shadow(color: Color.black.opacity(0.35), radius: 8, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Break in \(remaining.spokenText)")
            .accessibilityAddTraits(.isStaticText)
        }
        .frame(width: 52, height: 52)
    }

    private var refreshInterval: TimeInterval {
        reduceMotion ? 1.0 : 0.25
    }
}
