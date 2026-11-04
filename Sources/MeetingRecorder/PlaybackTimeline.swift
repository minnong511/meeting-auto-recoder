import RecorderAudio
import RecorderCore
import SwiftUI

@MainActor
private final class WaveformPreview: ObservableObject {
    @Published private(set) var waveform: PlaybackWaveform?
    @Published private(set) var unavailable = false
    private var request: UUID?

    func load(_ url: URL) async {
        guard waveform?.isComplete != true else { return }
        let id = UUID()
        request = id; unavailable = false
        defer { if request == id { request = nil } }
        do {
            let value = try await PlaybackWaveform.load(at: url) { [weak self] partial in
                Task { @MainActor in
                    guard let self, self.request == id,
                          partial.availableBins > (self.waveform?.availableBins ?? 0) else { return }
                    self.waveform = partial
                }
            }
            try Task.checkCancellation()
            if request == id { waveform = value }
        } catch is CancellationError { }
        catch { if !Task.isCancelled, request == id { unavailable = true } }
    }
}

struct PlaybackTimeline: View {
    @ObservedObject var player: RecordingPlayer
    let stored: StoredMeeting
    let enabled: Bool
    @StateObject private var preview = WaveformPreview()
    @State private var hover: Double?
    @State private var drag: Double?
    @State private var requested = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate static let inset: CGFloat = 5
    private static let orange = Color(red: 1, green: 0.47, blue: 0.14)
    private var cursor: Double? { drag ?? hover }
    private var expanded: Bool { enabled && cursor != nil }
    private var audioToLoad: URL? { requested && enabled ? stored.audioURL : nil }
    private var played: Double { player.duration > 0 ? min(max(0, player.position / player.duration), 1) : 0 }

    static func time(_ seconds: Double) -> String {
        let value = Duration.seconds(seconds.isFinite ? max(0, seconds.rounded(.down)) : 0)
        return value.formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - 2 * Self.inset)
            ZStack(alignment: .bottomLeading) {
                if expanded, let cursor {
                    RoundedRectangle(cornerRadius: 6).fill(
                        LinearGradient(colors: [Color(red: 0.38, green: 0.32, blue: 0.27),
                                                Color(red: 0.28, green: 0.27, blue: 0.25)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                    Canvas { context, size in
                        if let waveform = preview.waveform {
                            let path = bars(waveform, width: width, height: size.height)
                            context.fill(path, with: .color(.white.opacity(0.94)))
                            var highlighted = context
                            highlighted.clip(to: Path(CGRect(x: 0, y: 0, width: Self.inset + width * cursor, height: size.height)))
                            highlighted.fill(path, with: .color(Self.orange))
                        }
                        let marker = CGRect(x: Self.inset + width * cursor - 0.5, y: 4, width: 1, height: max(0, size.height - 7))
                        context.fill(Path(marker), with: .color(Self.orange))
                        if player.hasStarted && abs(played - cursor) * width > 4 {
                            let x = Self.inset + width * played
                            var playhead = Path()
                            playhead.move(to: CGPoint(x: x - 3, y: 1))
                            playhead.addLine(to: CGPoint(x: x + 3, y: 1))
                            playhead.addLine(to: CGPoint(x: x, y: 6))
                            playhead.closeSubpath()
                            context.fill(playhead, with: .color(.white))
                        }
                    }.accessibilityHidden(true)
                    if preview.unavailable {
                        Text("파형을 읽을 수 없습니다").font(.caption).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if preview.waveform == nil {
                        ProgressView().controlSize(.small).tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    let tagWidth: CGFloat = player.duration >= 3_600 ? 62 : 46
                    Text(Self.time(cursor * player.duration))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white).frame(width: tagWidth, height: 17)
                        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: min(max(2, Self.inset + width * cursor - tagWidth / 2), max(2, geo.size.width - tagWidth - 2)), y: -2)
                        .accessibilityHidden(true)
                } else {
                    Canvas { context, size in
                        let y = size.height / 2
                        let track = CGRect(x: Self.inset, y: y - 2, width: width, height: 4)
                        context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.secondary.opacity(0.28)))
                        let progress = CGRect(x: Self.inset, y: y - 2, width: width * played, height: 4)
                        context.fill(Path(roundedRect: progress, cornerRadius: 2), with: .color(RecorderTheme.accent))
                        context.fill(Path(ellipseIn: CGRect(x: Self.inset + width * played - 4, y: y - 4, width: 8, height: 8)), with: .color(RecorderTheme.accent))
                    }.accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
            .overlay {
                TimelineInput(duration: player.duration, position: player.position, enabled: enabled,
                    hovered: { hover = $0 },
                    began: { player.scrub(true, in: stored) },
                    scrubbed: { fraction in
                        drag = fraction
                        player.scrubPosition(fraction * player.duration, in: stored)
                    },
                    ended: {
                        player.scrub(false, in: stored)
                        drag = nil
                    },
                    seek: { player.scrubPosition($0, in: stored) })
            }
        }
        .frame(height: expanded ? 62 : 18)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: expanded)
        .task(id: expanded) {
            guard expanded, !requested else { return }
            do { try await Task.sleep(for: .milliseconds(100)); requested = true } catch { }
        }
        .task(id: audioToLoad) { if let url = audioToLoad { await preview.load(url) } }
        .onChange(of: enabled) { _, active in
            if !active {
                if drag != nil { player.pause() }
                drag = nil; hover = nil
            }
        }
    }

    private func bars(_ waveform: PlaybackWaveform, width: CGFloat, height: CGFloat) -> Path {
        var result = Path()
        let peaks = waveform.peaks
        let count = max(1, min(peaks.count, Int(width / 3)))
        let stride = width / CGFloat(count)
        for i in 0..<count {
            let start = i * peaks.count / count
            let end = min((i + 1) * peaks.count / count, waveform.availableBins)
            guard start < end else { break }
            let peak = peaks[start..<end].max() ?? 0
            let level = min(1, max(0, (20 * log10(max(peak, 0.0001)) + 54) / 54))
            let h = max(1, CGFloat(level) * max(1, height - 9))
            result.addRect(CGRect(x: Self.inset + CGFloat(i) * stride, y: height - h - 3, width: max(1, stride - 1), height: h))
        }
        return result
    }
}

/// The same native control owns tracking, drag capture and accessibility in
/// both sizes. Expanding the drawing under the cursor never replaces the input.
private struct TimelineInput: NSViewRepresentable {
    var duration: Double
    var position: Double
    var enabled: Bool
    var hovered: (Double?) -> Void
    var began: () -> Void
    var scrubbed: (Double) -> Void
    var ended: () -> Void
    var seek: (Double) -> Void

    func makeNSView(context: Context) -> TimelineSlider {
        let view = TimelineSlider()
        view.setAccessibilityLabel("녹음 재생 위치")
        view.focusRingType = .exterior
        return view
    }

    func updateNSView(_ view: TimelineSlider, context: Context) {
        view.input = self
        view.isEnabled = enabled
        view.maxValue = max(0, duration)
        view.doubleValue = position
        view.setAccessibilityValueDescription(TranscriptMarkdown.timestamp(position))
    }
}

private final class TimelineSlider: NSSlider {
    var input: TimelineInput?
    private var pointerArea: NSTrackingArea?
    private var isDragging = false
    private var departureMonitor: Any?
    private var resignation: NSObjectProtocol?

    override func draw(_ dirtyRect: NSRect) { } // The waveform and rail share the SwiftUI drawing.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea, trackingAreas.contains(where: { $0 === pointerArea }) { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }

    private func fraction(_ event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        let pad = PlaybackTimeline.inset
        return min(1, max(0, (x - pad) / max(1, bounds.width - 2 * pad)))
    }

    private func setHover(_ fraction: Double?) {
        if fraction != nil, departureMonitor == nil, let window {
            // Menus, scroll gestures and a changing tracking rectangle can take
            // the normal mouse-exited event. Observe this window only while open.
            departureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, !self.isDragging else { return event }
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.setHover(nil)
                }
                return event
            }
            resignation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setHover(nil) }
            }
        } else if fraction == nil { removeDepartureMonitor() }
        input?.hovered(fraction)
    }

    private func removeDepartureMonitor() {
        if let departureMonitor { NSEvent.removeMonitor(departureMonitor); self.departureMonitor = nil }
        if let resignation { NotificationCenter.default.removeObserver(resignation); self.resignation = nil }
    }

    override func viewWillMove(toWindow window: NSWindow?) {
        if self.window !== window { removeDepartureMonitor() }
        super.viewWillMove(toWindow: window)
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { setHover(fraction(event)) } }
    override func mouseMoved(with event: NSEvent) { if isEnabled { setHover(fraction(event)) } }
    override func mouseExited(with event: NSEvent) { setHover(nil) }
    override func scrollWheel(with event: NSEvent) {
        if isEnabled { setHover(fraction(event)) }
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isDragging = true
        input?.began()
        let x = fraction(event)
        setHover(x); input?.scrubbed(x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isDragging else { return }
        input?.scrubbed(fraction(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        guard isEnabled else { return }
        let x = fraction(event)
        input?.scrubbed(x)
        input?.ended()
        setHover(bounds.contains(convert(event.locationInWindow, from: nil)) ? x : nil)
    }

    private func seek(to seconds: Double) {
        guard isEnabled, seconds.isFinite else { return }
        input?.seek(min(max(0, seconds), maxValue))
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow, .downArrow: seek(to: doubleValue - 5)
        case .rightArrow, .upArrow: seek(to: doubleValue + 5)
        case .home: seek(to: 0)
        case .end: seek(to: maxValue)
        default: super.keyDown(with: event)
        }
    }

    override func setAccessibilityValue(_ value: Any?) {
        if let number = value as? NSNumber { seek(to: number.doubleValue) }
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        seek(to: doubleValue + 5); return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        seek(to: doubleValue - 5); return true
    }
}
