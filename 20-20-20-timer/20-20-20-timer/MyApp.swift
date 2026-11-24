import AppKit
import SwiftUI

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = TimerController.shared

    var body: some Scene {
        MenuBarExtra {
            TimerMenu(
                phase: controller.phase,
                completionChime: Binding(
                    get: { controller.completionChime },
                    set: { controller.completionChime = $0 }
                ),
                send: { event in controller.send(event) }
            )
        } label: {
            Label("20-20-20", systemImage: "eye.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        TimerController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        TimerController.shared.stop()
    }
}
