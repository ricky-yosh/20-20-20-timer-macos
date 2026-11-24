import SwiftUI
import TimerCore

@MainActor
struct TimerMenu: View {
    private let phase: TimerPhase
    @Binding private var completionChime: Bool
    @Binding private var isBlinkCheckInEnabled: Bool
    @Binding private var isPostureCheckInEnabled: Bool
    private let perform: @MainActor (TimerCommand) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        phase: TimerPhase,
        completionChime: Binding<Bool>,
        isBlinkCheckInEnabled: Binding<Bool>,
        isPostureCheckInEnabled: Binding<Bool>,
        perform: @escaping @MainActor (TimerCommand) -> Void
    ) {
        self.phase = phase
        _completionChime = completionChime
        _isBlinkCheckInEnabled = isBlinkCheckInEnabled
        _isPostureCheckInEnabled = isPostureCheckInEnabled
        self.perform = perform
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            status
            actions
            Divider()
            Toggle("Completion chime", isOn: $completionChime)
                .toggleStyle(.switch)
                .accessibilityHint("Plays a sound when a break finishes naturally")
            Toggle("Blink reminders", isOn: $isBlinkCheckInEnabled)
                .toggleStyle(.switch)
                .accessibilityHint("Shows brief blink prompts during work intervals")
            Toggle("Posture reminders", isOn: $isPostureCheckInEnabled)
                .toggleStyle(.switch)
                .accessibilityHint("Shows brief posture prompts during work intervals")
            Divider()
            Button("Quit 20-20-20 Timer") {
                perform(.quit)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 292)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("20-20-20")
                .font(.headline)
            Spacer()
            phaseBadge
        }
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch phase {
        case .work(deadline: _, warning: .none), .suspended:
            EmptyView()
        case .work(deadline: _, warning: .headsUp):
            badge("Heads-up", tint: .orange)
        case .work(deadline: _, warning: .finalCountdown):
            badge("Imminent", tint: .red)
        case .paused(remaining: _):
            badge("Paused", tint: .secondary)
        case .onBreak(deadline: _, origin: _):
            badge("On break", tint: .green)
        }
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .work(deadline: let deadline, warning: _):
            remainingStatus(title: "Work session", deadline: deadline)
        case .paused(remaining: let remaining):
            staticStatus(title: "Paused", remaining: RemainingTime(duration: remaining))
        case .onBreak(deadline: let deadline, origin: let origin):
            remainingStatus(title: breakTitle(origin), deadline: deadline)
        case .suspended:
            staticStatus(title: "Suspended", remaining: nil)
        }
    }

    private func breakTitle(_ origin: BreakOrigin) -> String {
        switch origin {
        case .scheduled:
            return "Scheduled break"
        case .onDemand:
            return "On-demand break"
        }
    }

    private func remainingStatus(title: String, deadline: ContinuousClock.Instant) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let remaining = RemainingTime(deadline: deadline, now: ContinuousClock.now)
                Text(remaining.clockText)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("\(title), \(remaining.spokenText) remaining")
            }
        }
    }

    private func staticStatus(title: String, remaining: RemainingTime?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(remaining?.clockText ?? "Screen unavailable")
                .font(.system(size: remaining == nil ? 16 : 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(remaining == nil ? .secondary : .primary)
                .accessibilityLabel(remaining.map { "\(title), \($0.spokenText) remaining" } ?? "Suspended while the screen is unavailable")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .work(deadline: _, warning: _):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Pause") { perform(.pause) }
                        .buttonStyle(.bordered)
                    Button("Take Break Now") { perform(.takeBreakNow) }
                        .buttonStyle(.borderedProminent)
                }
                if let snoozeTitle {
                    Button(snoozeTitle) { perform(.snoozeBreak) }
                        .buttonStyle(.bordered)
                }
            }
        case .paused(remaining: _):
            HStack(spacing: 8) {
                Button("Resume") { perform(.resume) }
                    .buttonStyle(.bordered)
                Button("Take Break Now") { perform(.takeBreakNow) }
                    .buttonStyle(.borderedProminent)
            }
        case .onBreak(deadline: _, origin: _):
            Button("End Break") { perform(.dismissBreak) }
                .buttonStyle(.bordered)
        case .suspended:
            EmptyView()
        }
    }

    private var snoozeTitle: String? {
        switch phase {
        case .work(deadline: _, warning: let warning):
            switch warning {
            case .none:
                return nil
            case .headsUp, .finalCountdown:
                return "Snooze 5m"
            }
        case .paused, .onBreak, .suspended:
            return nil
        }
    }
}
