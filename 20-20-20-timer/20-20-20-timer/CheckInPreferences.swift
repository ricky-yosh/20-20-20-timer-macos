import Foundation

@MainActor
protocol CheckInPreferencesStoring: AnyObject {
    var isBlinkCheckInEnabled: Bool { get set }
    var isPostureCheckInEnabled: Bool { get set }
}

@MainActor
final class UserDefaultsCheckInPreferences: CheckInPreferencesStoring {
    private enum Key {
        static let blink = "isBlinkCheckInEnabled"
        static let posture = "isPostureCheckInEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.blink: true,
            Key.posture: true,
        ])
    }

    var isBlinkCheckInEnabled: Bool {
        get { defaults.bool(forKey: Key.blink) }
        set { defaults.set(newValue, forKey: Key.blink) }
    }

    var isPostureCheckInEnabled: Bool {
        get { defaults.bool(forKey: Key.posture) }
        set { defaults.set(newValue, forKey: Key.posture) }
    }
}
