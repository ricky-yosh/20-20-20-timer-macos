import AppKit
import Dispatch
import Foundation

@MainActor
final class ScreenAvailabilityObserver {
    private enum UnavailabilityReason: Hashable, Sendable {
        case displayAsleep
        case machineAsleep
        case screenLocked
        case sessionInactive
    }

    private struct AvailabilityEdge: Sendable {
        let reason: UnavailabilityReason
        let becameUnavailable: Bool
    }

    private var registrations: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var activeReasons: Set<UnavailabilityReason> = []
    private var isUsable = true
    private var onChange: (@MainActor (Bool) -> Void)?
    private var started = false

    init() {}

    isolated deinit {
        for registration in registrations {
            registration.center.removeObserver(registration.token)
        }
    }

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        guard !started else { return }
        started = true
        self.onChange = onChange
        observeWorkspaceNotifications()
        observeDistributedNotifications()
    }

    private func observeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        register(NSWorkspace.screensDidSleepNotification, on: center, becameUnavailable: true, reason: .displayAsleep)
        register(NSWorkspace.screensDidWakeNotification, on: center, becameUnavailable: false, reason: .displayAsleep)
        register(NSWorkspace.willSleepNotification, on: center, becameUnavailable: true, reason: .machineAsleep)
        register(NSWorkspace.didWakeNotification, on: center, becameUnavailable: false, reason: .machineAsleep)
        register(NSWorkspace.sessionDidResignActiveNotification, on: center, becameUnavailable: true, reason: .sessionInactive)
        register(NSWorkspace.sessionDidBecomeActiveNotification, on: center, becameUnavailable: false, reason: .sessionInactive)
    }

    private func observeDistributedNotifications() {
        let center = DistributedNotificationCenter.default()
        register(Self.screenIsLocked, on: center, becameUnavailable: true, reason: .screenLocked)
        register(Self.screenIsUnlocked, on: center, becameUnavailable: false, reason: .screenLocked)
    }

    private func register(
        _ name: NSNotification.Name,
        on center: NotificationCenter,
        becameUnavailable: Bool,
        reason: UnavailabilityReason
    ) {
        let edge = AvailabilityEdge(reason: reason, becameUnavailable: becameUnavailable)
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.record(edge)
            }
        }
        registrations.append((center, token))
    }

    private func record(_ edge: AvailabilityEdge) {
        let previousReasons = activeReasons
        if edge.becameUnavailable {
            activeReasons.insert(edge.reason)
        } else {
            activeReasons.remove(edge.reason)
        }
        guard activeReasons != previousReasons else { return }
        let currentlyUsable = activeReasons.isEmpty
        guard currentlyUsable != isUsable else { return }
        isUsable = currentlyUsable
        onChange?(currentlyUsable)
    }

    private static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")
}
