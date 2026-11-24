import SwiftUI
import TimerCore

@MainActor
struct BreakOverlayView: View {
    private let deadline: ContinuousClock.Instant
    private let origin: BreakOrigin
    private let showsControls: Bool
    private let dismiss: @MainActor () -> Void
    private let snooze: (@MainActor () -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsInstruction = false
    @State private var showsCountdown = false
    @State private var showsActions = false

    init(
        deadline: ContinuousClock.Instant,
        origin: BreakOrigin,
        showsControls: Bool,
        dismiss: @escaping @MainActor () -> Void,
        snooze: (@MainActor () -> Void)? = nil
    ) {
        self.deadline = deadline
        self.origin = origin
        self.showsControls = showsControls
        self.dismiss = dismiss
        self.snooze = snooze
    }

    var body: some View {
        ZStack {
            ShiftingBreakBackground()

            if showsControls {
                TimelineView(.periodic(from: .now, by: refreshInterval)) { _ in
                    let remaining = RemainingTime(deadline: deadline, now: ContinuousClock.now)
                    content(remaining: remaining)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await stageReveal()
        }
        .accessibilityElement(children: .contain)
    }

    private var refreshInterval: TimeInterval {
        reduceMotion ? 1.0 : 0.25
    }

    private var originTitle: String {
        switch origin {
        case .scheduled:
            return "Scheduled break"
        case .onDemand:
            return "On-demand break"
        }
    }

    private var dismissTitle: String {
        switch origin {
        case .scheduled:
            return "Skip Break"
        case .onDemand:
            return "End Break"
        }
    }

    private var escapeHint: String {
        switch origin {
        case .scheduled:
            return "Escape skips this break and starts a fresh work interval."
        case .onDemand:
            return "Escape ends this break early."
        }
    }

    private var offersSnooze: Bool {
        guard showsControls, snooze != nil else { return false }
        switch origin {
        case .scheduled:
            return true
        case .onDemand:
            return false
        }
    }

    private func content(remaining: RemainingTime) -> some View {
        VStack(spacing: 18) {
            Text(originTitle)
                .font(.callout.weight(.semibold))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.72))
                .opacity(showsInstruction ? 1 : 0)
                .offset(y: showsInstruction ? 0 : 8)

            Text("Look about 20 feet away")
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: Color.black.opacity(0.35), radius: 18, y: 6)
                .opacity(showsInstruction ? 1 : 0)
                .offset(y: showsInstruction ? 0 : 12)

            Text(remaining.clockText)
                .font(.system(size: 128, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .shadow(color: Color.black.opacity(0.35), radius: 22, y: 8)
                .contentTransition(reduceMotion ? ContentTransition.identity : .numericText(countsDown: true))
                .accessibilityLabel("Break ends in \(remaining.spokenText)")
                .scaleEffect(showsCountdown ? 1 : 0.9)
                .opacity(showsCountdown ? 1 : 0)

            if showsControls {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        if offersSnooze, let snooze {
                            Button("Snooze 5m", action: snooze)
                                .buttonStyle(BreakControlButtonStyle(isProminent: true))
                                .accessibilityLabel("Snooze break for 5 minutes")
                        }

                        Button(dismissTitle, action: dismiss)
                            .buttonStyle(BreakControlButtonStyle(isProminent: !offersSnooze))
                            .accessibilityLabel(dismissAccessibilityLabel)
                    }

                    Text(escapeHint)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .opacity(showsActions ? 1 : 0)
                .offset(y: showsActions ? 0 : 10)
            }
        }
        .foregroundStyle(.white)
        .padding(48)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dismissAccessibilityLabel: String {
        switch origin {
        case .scheduled:
            return "Skip this scheduled break and start a fresh work interval"
        case .onDemand:
            return "End this on-demand break"
        }
    }

    private func stageReveal() async {
        if reduceMotion {
            showsInstruction = true
            showsCountdown = true
            showsActions = true
            return
        }

        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.6)) {
            showsInstruction = true
        }

        try? await Task.sleep(for: .milliseconds(360))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.7)) {
            showsCountdown = true
        }

        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.5)) {
            showsActions = true
        }
    }
}
