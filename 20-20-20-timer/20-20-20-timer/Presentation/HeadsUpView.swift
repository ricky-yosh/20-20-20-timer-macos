import SwiftUI

@MainActor
struct HeadsUpView: View {
    private let snooze: @MainActor () -> Void

    init(snooze: @escaping @MainActor () -> Void) {
        self.snooze = snooze
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "eye")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Break in 1 minute")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Text("Look away from the screen soon.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 2)

            Button("Snooze 5m", action: snooze)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Snooze break for 5 minutes")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 280, height: 84)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
