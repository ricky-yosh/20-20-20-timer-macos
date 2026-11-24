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

struct ShiftingBreakBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let palette: [Color] = [
        Color(red: 0.043, green: 0.102, blue: 0.196),
        Color(red: 0.129, green: 0.180, blue: 0.388),
        Color(red: 0.106, green: 0.322, blue: 0.357),
        Color(red: 0.247, green: 0.129, blue: 0.302),
        Color(red: 0.043, green: 0.102, blue: 0.196),
    ]

    var body: some View {
        if reduceMotion {
            composition(phase: 0.18)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                composition(phase: Self.phase(at: context.date))
            }
        }
    }

    private func composition(phase: Double) -> some View {
        GeometryReader { proxy in
            let radius = max(proxy.size.width, proxy.size.height) * 0.85
            ZStack {
                LinearGradient(
                    colors: Self.palette,
                    startPoint: Self.unitPoint(phase: phase),
                    endPoint: Self.unitPoint(phase: phase + 0.5)
                )
                RadialGradient(
                    colors: [Color.white.opacity(0.14), Color.white.opacity(0.02), Color.clear],
                    center: Self.unitPoint(phase: phase + 0.25),
                    startRadius: 0,
                    endRadius: radius
                )
                LinearGradient(
                    colors: [Color.black.opacity(0.28), Color.clear, Color.black.opacity(0.22)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    private static func phase(at date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return (seconds / 72).truncatingRemainder(dividingBy: 1)
    }

    private static func unitPoint(phase: Double) -> UnitPoint {
        let angle = phase * 2 * Double.pi
        return UnitPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))
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
