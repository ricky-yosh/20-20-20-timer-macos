import SwiftUI
import TimerCore

@MainActor
struct CheckInView: View {
    private let origin: CheckInOrigin
    private let dismiss: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    init(origin: CheckInOrigin, dismiss: @escaping @MainActor () -> Void) {
        self.origin = origin
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .scaleEffect(isPresented || reduceMotion ? 1 : 0.82)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button("Got it", action: dismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Dismiss \(title.lowercased())")
        }
        .padding(18)
        .frame(width: 300, height: 96)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .opacity(isPresented || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) {
                isPresented = true
            }
        }
    }

    private var title: String {
        switch origin {
        case .blink:
            return "Time to blink"
        case .posture:
            return "Check your posture"
        }
    }

    private var detail: String {
        switch origin {
        case .blink:
            return "Look away and blink a few times."
        case .posture:
            return "Sit tall and relax your shoulders."
        }
    }

    private var symbolName: String {
        switch origin {
        case .blink:
            return "eye"
        case .posture:
            return "figure.stand"
        }
    }
}
