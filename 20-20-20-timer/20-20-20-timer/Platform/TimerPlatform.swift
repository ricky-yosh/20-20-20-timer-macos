import AppKit
import CoreGraphics
import SwiftUI
import TimerCore

@MainActor
private final class BreakControlPanel: NSPanel {
    var handlesEscape = false
    var onEscape: (@MainActor () -> Void)?

    override var acceptsFirstResponder: Bool { handlesEscape }
    override var canBecomeKey: Bool { handlesEscape }

    override func sendEvent(_ event: NSEvent) {
        if handlesEscape, event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlesEscape, event.keyCode == 53 {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handlesEscape && event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct BreakPresentation {
    let deadline: ContinuousClock.Instant
    let origin: BreakOrigin
    let dismiss: @MainActor () -> Void
    let snooze: (@MainActor () -> Void)?
}

@MainActor
final class TimerPlatform {
    private let availability = ScreenAvailabilityObserver()
    private let completionSound = NSSound(named: "Glass")

    private var onDisplayChange: (@MainActor () -> Void)?
    private var displayObserver: NSObjectProtocol?
    private var hasStarted = false

    private var headsUpPanel: NSPanel?
    private var countdownPanel: NSPanel?
    private var countdownRefreshTask: Task<Void, Never>?
    private var countdownGeneration = 0

    private var activeBreak: BreakPresentation?
    private var breakPanels: [CGDirectDisplayID: NSPanel] = [:]
    private var breakPanelControlState: [CGDirectDisplayID: Bool] = [:]
    private var controlDisplayID: CGDirectDisplayID?
    private var keyedControlID: CGDirectDisplayID?
    private var formerFrontmostApplication: NSRunningApplication?
    private var announcedBreakStart = false
    private var announcedBreakEnd = false

    init() {}

    isolated deinit {
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
        }
        countdownRefreshTask?.cancel()
    }

    func start(
        onAvailability: @escaping @MainActor (Bool) -> Void,
        onDisplayChange: @escaping @MainActor () -> Void
    ) {
        availability.start(onChange: onAvailability)
        self.onDisplayChange = onDisplayChange
        guard !hasStarted else { return }
        hasStarted = true
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleDisplayParametersChange()
            }
        }
    }

    func showHeadsUp(snooze: @escaping @MainActor () -> Void) {
        clearWarnings()
        let panel = makePassivePanel(level: .statusBar, ignoresMouseEvents: false)
        let dismissAction: @MainActor () -> Void = { [weak self] in
            snooze()
            self?.dismissHeadsUp()
        }
        panel.contentView = NSHostingView(rootView: HeadsUpView(snooze: dismissAction))
        panel.setContentSize(NSSize(width: 280, height: 84))
        placeHeadsUp(panel)
        headsUpPanel = panel
        fadeIn(panel)
    }

    func showFinalCountdown(deadline: ContinuousClock.Instant) {
        clearWarnings()
        let panel = makePassivePanel(level: warningLevel, ignoresMouseEvents: true)
        panel.contentView = NSHostingView(rootView: FinalCountdownView(deadline: deadline))
        panel.setContentSize(NSSize(width: 52, height: 52))
        countdownPanel = panel
        refreshCountdownPosition(force: true)
        fadeIn(panel)
        startCountdownTracking()
    }

    func showBreak(
        deadline: ContinuousClock.Instant,
        origin: BreakOrigin,
        dismiss: @escaping @MainActor () -> Void,
        snooze: (@MainActor () -> Void)? = nil
    ) {
        clearWarnings()
        let isNewBreak = activeBreak?.deadline != deadline
        let presentation = BreakPresentation(deadline: deadline, origin: origin, dismiss: dismiss, snooze: snooze)
        activeBreak = presentation
        if isNewBreak {
            controlDisplayID = displayID(containing: NSEvent.mouseLocation)
            formerFrontmostApplication = NSWorkspace.shared.frontmostApplication
            announcedBreakStart = false
            announcedBreakEnd = false
            keyedControlID = nil
        }
        if !announcedBreakStart {
            announce("Break started. Look about 20 feet away.")
            announcedBreakStart = true
        }
        reconcileBreakPanels()
    }

    func clear() {
        clearWarnings()
        finishBreak()
    }

    func playCompletionChime() {
        completionSound?.stop()
        completionSound?.play()
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var warningLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
    }

    private func makePassivePanel(level: NSWindow.Level, ignoresMouseEvents: Bool) -> NSPanel {
        let panel = NSPanel()
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = ignoresMouseEvents
        return panel
    }

    private func makeBreakPanel(isControl: Bool) -> NSPanel {
        let control = BreakControlPanel()
        control.onEscape = { [weak self] in self?.handleBreakEscape() }
        control.handlesEscape = isControl
        let panel = control
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = !isControl
        return panel
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func displayID(containing point: NSPoint) -> CGDirectDisplayID? {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen.flatMap(displayID(for:))
    }

    private func handleDisplayParametersChange() {
        reconcileBreakPanels()
        if countdownPanel != nil {
            refreshCountdownPosition(force: true)
        }
        if let headsUpPanel {
            placeHeadsUp(headsUpPanel)
        }
        onDisplayChange?()
    }

    private func placeHeadsUp(_ panel: NSPanel) {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.maxX - size.width - 20,
            y: frame.maxY - size.height - 20
        )
        panel.setFrameOrigin(clamped(origin: origin, size: size, in: frame))
    }

    private func refreshCountdownPosition(force: Bool = false) {
        guard let panel = countdownPanel else { return }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let preferred: NSPoint
        if reduceMotion {
            preferred = NSPoint(x: frame.maxX - size.width - 24, y: frame.maxY - size.height - 24)
        } else {
            let margin: CGFloat = 8
            let flipsRight = point.x + 18 + size.width + margin > frame.maxX
            let flipsDown = point.y - size.height - 12 < frame.minY + margin
            let x = flipsRight ? point.x - size.width - 18 : point.x + 18
            let y = flipsDown ? point.y + 12 : point.y - size.height - 12
            preferred = NSPoint(x: x, y: y)
        }
        let origin = clamped(origin: preferred, size: size, in: frame)
        if force || panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func clamped(origin: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        let margin: CGFloat = 8
        return NSPoint(
            x: min(max(origin.x, frame.minX + margin), max(frame.maxX - size.width - margin, frame.minX + margin)),
            y: min(max(origin.y, frame.minY + margin), max(frame.maxY - size.height - margin, frame.minY + margin))
        )
    }

    private func startCountdownTracking() {
        countdownRefreshTask?.cancel()
        countdownGeneration += 1
        guard !reduceMotion else { return }
        let generation = countdownGeneration
        countdownRefreshTask = Task { @MainActor [weak self] in
            while let self, generation == self.countdownGeneration {
                try? await Task.sleep(for: .milliseconds(50))
                guard generation == self.countdownGeneration else { return }
                self.refreshCountdownPosition()
            }
        }
    }

    private func reconcileBreakPanels() {
        guard let presentation = activeBreak else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let liveIDs = Set(screens.compactMap(displayID(for:)))
        let controlIsLive = controlDisplayID.map { liveIDs.contains($0) } ?? false
        if !controlIsLive {
            controlDisplayID = liveIDs.first
            keyedControlID = nil
        }
        for (id, panel) in breakPanels where !liveIDs.contains(id) {
            breakPanels[id] = nil
            breakPanelControlState[id] = nil
            panel.close()
        }

        for screen in screens {
            guard let id = displayID(for: screen) else { continue }
            let isControl = id == controlDisplayID
            let panel: NSPanel
            if let existing = breakPanels[id] {
                panel = existing
            } else {
                panel = makeBreakPanel(isControl: isControl)
                breakPanels[id] = panel
                panel.setFrame(screen.frame, display: true)
                panel.contentView = breakContent(presentation: presentation, isControl: isControl)
                breakPanelControlState[id] = isControl
                fadeIn(panel)
            }
            if breakPanelControlState[id] != isControl {
                panel.contentView = breakContent(presentation: presentation, isControl: isControl)
                breakPanelControlState[id] = isControl
            }
            (panel as? BreakControlPanel)?.handlesEscape = isControl
            panel.ignoresMouseEvents = !isControl
            if panel.frame != screen.frame {
                panel.setFrame(screen.frame, display: true)
            }
        }

        if let controlID = controlDisplayID,
           keyedControlID != controlID,
           let controlPanel = breakPanels[controlID],
           controlPanel.isVisible {
            NSApplication.shared.activate(ignoringOtherApps: true)
            controlPanel.makeKey()
            keyedControlID = controlID
        }
    }

    private func breakContent(presentation: BreakPresentation, isControl: Bool) -> NSHostingView<BreakOverlayView> {
        let dismissAction: @MainActor () -> Void = { [weak self] in self?.handleBreakDismiss() }
        let snoozeAction: (@MainActor () -> Void)?
        if let snooze = presentation.snooze {
            snoozeAction = { [weak self] in self?.handleBreakSnooze(snooze) }
        } else {
            snoozeAction = nil
        }
        return NSHostingView(rootView: BreakOverlayView(
            deadline: presentation.deadline,
            origin: presentation.origin,
            showsControls: isControl,
            dismiss: dismissAction,
            snooze: snoozeAction
        ))
    }

    private func handleBreakEscape() {
        handleBreakDismiss()
    }

    private func handleBreakDismiss() {
        guard let presentation = activeBreak else { return }
        presentation.dismiss()
        finishBreak()
    }

    private func handleBreakSnooze(_ snooze: @MainActor () -> Void) {
        snooze()
        finishBreak()
    }

    private func dismissHeadsUp() {
        guard let panel = headsUpPanel else { return }
        headsUpPanel = nil
        fadeOut(panel)
    }

    private func clearWarnings() {
        countdownGeneration += 1
        countdownRefreshTask?.cancel()
        countdownRefreshTask = nil
        let panels = [headsUpPanel, countdownPanel].compactMap { $0 }
        headsUpPanel = nil
        countdownPanel = nil
        for panel in panels {
            fadeOut(panel)
        }
    }

    private func finishBreak() {
        guard activeBreak != nil else { return }
        activeBreak = nil
        let panels = Array(breakPanels.values)
        breakPanels.removeAll()
        breakPanelControlState.removeAll()
        controlDisplayID = nil
        keyedControlID = nil
        if !announcedBreakEnd {
            announce("Break ended.")
            announcedBreakEnd = true
        }
        if let former = formerFrontmostApplication {
            former.activate()
        } else {
            NSApplication.shared.deactivate()
        }
        formerFrontmostApplication = nil
        for panel in panels {
            fadeOut(panel)
        }
    }

    private func fadeIn(_ panel: NSPanel) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.35
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut(_ panel: NSPanel) {
        guard panel.isVisible else {
            panel.close()
            return
        }
        let duration: TimeInterval = reduceMotion ? 0.15 : 0.3
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            panel.close()
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
