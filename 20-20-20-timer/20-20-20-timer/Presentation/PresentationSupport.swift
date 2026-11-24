import SwiftUI

struct RemainingTime: Equatable, Sendable {
    let seconds: Int

    init(duration: Duration) {
        let components = duration.components
        let fractional = Double(components.attoseconds) / 1_000_000_000_000_000_000
        let total = Double(components.seconds) + fractional
        seconds = total > 0 ? Int(total.rounded(.up)) : 0
    }

    init(deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) {
        self.init(duration: deadline - now)
    }

    var clockText: String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return "\(hours):\(Self.padded(minutes)):\(Self.padded(remainder))"
        }
        return "\(minutes):\(Self.padded(remainder))"
    }

    var spokenText: String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append(Self.spokenCount(hours, unit: "hour"))
        }
        if minutes > 0 {
            parts.append(Self.spokenCount(minutes, unit: "minute"))
        }
        if remainder > 0 || parts.isEmpty {
            parts.append(Self.spokenCount(remainder, unit: "second"))
        }
        return parts.joined(separator: " ")
    }

    private static func padded(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func spokenCount(_ count: Int, unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}

struct CharcoalBackground: View {
    private let color: Color = Color(red: 0.1, green: 0.1, blue: 0.13)

    var body: some View {
        color
            .ignoresSafeArea()
    }
}

struct BreakControlButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isProminent ? Color.black.opacity(0.82) : Color.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background {
                Capsule(style: .continuous)
                    .fill(isProminent ? Color.white.opacity(0.92) : Color.white.opacity(0.14))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule(style: .continuous))
    }
}
