import AppKit
import SwiftUI

/// The control process receives display-only state, never recording contents.
struct RecordingIslandMessage: Codable {
    var phase: String
    var elapsed: String
    var targetName: String
    var bundleID: String?
    var processID: Int32?
    var canStart: Bool = false
}

@MainActor
enum RecordingIslandHelper {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = RecordingIslandHelperController()
        controller.start()
        withExtendedLifetime(controller) { app.run() }
    }
}

/// Reads complete newline-delimited messages off the main thread. The serial
/// queue also preserves the order of the last message and the parent's EOF.
private final class RecordingIslandInput {
    private let handle = FileHandle.standardInput
    private let queue = DispatchQueue(label: "meeting-recorder.island-input")
    private var buffer = Data()
    private var finished = false
    private let maximumLineLength = 65_536
    private let receive: (RecordingIslandMessage) -> Void
    private let end: () -> Void

    init(receive: @escaping (RecordingIslandMessage) -> Void, end: @escaping () -> Void) {
        self.receive = receive
        self.end = end
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in self?.consume(data) }
        }
    }

    private func consume(_ data: Data) {
        guard !finished else { return }
        guard !data.isEmpty else { finish(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let length = buffer.distance(from: buffer.startIndex, to: newline)
            guard length <= maximumLineLength else { finish(); return }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(RecordingIslandMessage.self, from: line) else { continue }
            DispatchQueue.main.async { [receive] in receive(message) }
        }
        if buffer.count > maximumLineLength { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        handle.readabilityHandler = nil
        buffer.removeAll()
        DispatchQueue.main.async { [end] in end() }
    }
}

@MainActor
private final class RecordingIslandHelperController {
    private let state = RecordingIslandState()
    private var panel: IslandHelperPanel?
    private var input: RecordingIslandInput?
    private var screenObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var collapseWork: DispatchWorkItem?
    private var anchorDisplayID: NSNumber?
    private var sessionActive = true
    private var hasState = false
    private var stopSent = false
    private var lastBundleID: String?
    private var lastProcessID: Int32?
    private var animatedFrame: NSRect?
    private var frameTimer: Timer?
    private let expansionDuration = 0.24

    func start() {
        state.stop = { [weak self] in
            guard let self, !self.stopSent else { return }
            self.stopSent = true
            try? FileHandle.standardOutput.write(contentsOf: Data("stop\n".utf8))
        }
        state.start = {
            try? FileHandle.standardOutput.write(contentsOf: Data("start\n".utf8))
        }
        state.hoverChanged = { [weak self] hovering in self?.hoverChanged(hovering) }
        state.toggleExpanded = { [weak self] in
            guard let self else { return }
            self.setExpanded(!self.state.expanded)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.positionPanel() } }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        sessionObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.setSessionActive(false) } })
        sessionObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.setSessionActive(true) } })
        let reader = RecordingIslandInput(receive: { [weak self] message in
            MainActor.assumeIsolated { self?.receive(message) }
        }, end: { [weak self] in
            MainActor.assumeIsolated { self?.shutdown() }
        })
        input = reader
        reader.start()
    }

    private func receive(_ message: RecordingIslandMessage) {
        switch message.phase {
        case "idle": state.phase = .idle
        case "preparing": state.phase = .preparing
        case "recording": state.phase = .recording
        case "stopping": state.phase = .stopping
        case "ended": state.phase = .ended
        default: return
        }
        if message.phase == "idle" { stopSent = false }
        state.elapsed = message.elapsed
        state.canStart = message.canStart
        state.targetName = message.targetName
        if !hasState || message.bundleID != lastBundleID || message.processID != lastProcessID {
            lastBundleID = message.bundleID
            lastProcessID = message.processID
            state.targetIcon = targetIcon(bundleID: message.bundleID, processID: message.processID)
        }
        if !hasState { anchorDisplayID = displayID(preferredScreen()) }
        hasState = true
        showPanel()
    }

    private func targetIcon(bundleID: String?, processID: Int32?) -> NSImage? {
        if let processID, let bundleID,
           let application = NSRunningApplication(processIdentifier: processID),
           application.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame,
           let icon = application.icon { return icon }
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func showPanel() {
        guard sessionActive else { return }
        if panel == nil {
            let window = IslandHelperPanel(contentRect: NSRect(x: 0, y: 0, width: 432, height: 48),
                                           styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isFloatingPanel = true
            window.animationBehavior = .none
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = IslandPanelContentView(state: state)
            panel = window
        }
        positionPanel()
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
    }

    private func positionPanel(animated: Bool = false) {
        guard let panel else { return }
        let anchored = anchorDisplayID.flatMap { id in NSScreen.screens.first { displayID($0) == id } }
        guard let screen = anchored ?? preferredScreen() else { panel.orderOut(nil); return }
        anchorDisplayID = displayID(screen)
        let frame = screen.frame
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let hasNotch = screen.safeAreaInsets.top > 0 && left != nil && right != nil
        let center = hasNotch ? (left!.maxX + right!.minX) / 2 : frame.midX
        let notchWidth = hasNotch ? max(0, right!.minX - left!.maxX) : 0
        let width = min(frame.width, max(432, notchWidth + 120))
        if state.hasNotch != hasNotch { state.hasNotch = hasNotch }
        if state.notchWidth != notchWidth { state.notchWidth = notchWidth }
        if state.panelWidth != width { state.panelWidth = width }
        let height: CGFloat = state.expanded ? 148 : 48
        let top = hasNotch ? frame.maxY : screen.visibleFrame.maxY
        let x = max(frame.minX, min(center - width / 2, frame.maxX - width))
        let newFrame = NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height)
        // State messages arrive every second; they must not snap an in-flight
        // expansion to its final frame. Screen changes still apply immediately.
        if animatedFrame == newFrame { return }
        frameTimer?.invalidate()
        frameTimer = nil
        animatedFrame = nil
        guard panel.frame != newFrame else { return }
        guard animated else {
            panel.setFrame(newFrame, display: true, animate: false)
            return
        }

        // Derive both origin and height from the same value on every frame.
        // NSWindow's animator and SwiftUI's layout otherwise interpolate their
        // sizes independently, leaving a visible gap at the notch.
        let startHeight = panel.frame.height
        let startTime = ProcessInfo.processInfo.systemUptime
        let animationTop = newFrame.maxY
        animatedFrame = newFrame
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak panel] timer in
            MainActor.assumeIsolated {
                guard let self, let panel, self.animatedFrame == newFrame else { timer.invalidate(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let progress = min(1, max(0, elapsed / self.expansionDuration))
                let eased = progress * progress * (3 - 2 * progress)
                let height = startHeight + (newFrame.height - startHeight) * eased
                panel.setFrame(NSRect(x: newFrame.minX, y: animationTop - height, width: newFrame.width, height: height),
                               display: true, animate: false)
                if progress >= 1 {
                    timer.invalidate()
                    self.frameTimer = nil
                    self.animatedFrame = nil
                }
            }
        }
        timer.tolerance = 0.003
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func displayID(_ screen: NSScreen?) -> NSNumber? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func setExpanded(_ expanded: Bool) {
        collapseWork?.cancel()
        collapseWork = nil
        guard state.expanded != expanded else { return }
        let animate = panel?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            withAnimation(.easeInOut(duration: expansionDuration)) { state.expanded = expanded }
        } else {
            state.expanded = expanded
        }
        positionPanel(animated: animate)
    }

    private func hoverChanged(_ hovering: Bool) {
        collapseWork?.cancel()
        collapseWork = nil
        if hovering { setExpanded(true); return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) { self.setExpanded(false) }
        }
        collapseWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func setSessionActive(_ active: Bool) {
        sessionActive = active
        if active && hasState { showPanel() }
        else if !active { panel?.orderOut(nil) }
    }

    private func shutdown() {
        collapseWork?.cancel()
        frameTimer?.invalidate()
        panel?.orderOut(nil)
        panel?.close()
        NSApp.terminate(nil)
    }
}

private final class IslandHelperPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // The controller calculates a frame on an attached screen, including the
    // notch area. AppKit's usual visible-frame constraint can pull that frame
    // away from the top edge while it is resized.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class IslandHelperHostingView: NSHostingView<RecordingNotchView> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A fixed-height SwiftUI host is pinned to the top while this container is
/// resized and clipped to the panel. The actual window still shrinks, so the
/// transparent area below a collapsed island cannot intercept clicks.
@MainActor
private final class IslandPanelContentView: NSView {
    private let hostingView: IslandHelperHostingView
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(state: RecordingIslandState) {
        hostingView = IslandHelperHostingView(rootView: RecordingNotchView(state: state))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        hostingView.sizingOptions = []
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        hostingView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 148)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width = bounds.width, height = bounds.height
        let radius = min(20, height / 2, width / 2)
        let curve = radius * 0.55228475
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: width, y: 0))
        path.line(to: NSPoint(x: width, y: height - radius))
        path.curve(to: NSPoint(x: width - radius, y: height),
                   controlPoint1: NSPoint(x: width, y: height - radius + curve),
                   controlPoint2: NSPoint(x: width - radius + curve, y: height))
        path.line(to: NSPoint(x: radius, y: height))
        path.curve(to: NSPoint(x: 0, y: height - radius),
                   controlPoint1: NSPoint(x: radius - curve, y: height),
                   controlPoint2: NSPoint(x: 0, y: height - radius + curve))
        path.close()
        NSColor.black.setFill()
        path.fill()
    }
}
