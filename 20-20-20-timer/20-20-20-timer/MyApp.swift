import AppKit
import SwiftUI
import TimerCore

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = TimerController.shared
    private let commands = TimerCommandService.shared

    var body: some Scene {
        MenuBarExtra {
            TimerMenu(
                phase: controller.phase,
                completionChime: Binding(
                    get: { controller.completionChime },
                    set: { _ = commands.perform(.init(command: .setCompletionChime, enabled: $0)) }
                ),
                isBlinkCheckInEnabled: Binding(
                    get: { controller.isBlinkCheckInEnabled },
                    set: { _ = commands.perform(.init(command: .setBlinkCheckIn, enabled: $0)) }
                ),
                isPostureCheckInEnabled: Binding(
                    get: { controller.isPostureCheckInEnabled },
                    set: { _ = commands.perform(.init(command: .setPostureCheckIn, enabled: $0)) }
                ),
                perform: { command in
                    _ = commands.perform(.init(command: command))
                }
            )
        } label: {
            TimerStatusItemLabel(phase: controller.phase)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        TimerController.shared.start()
        TimerCommandHost.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        TimerController.shared.stop()
    }
}
