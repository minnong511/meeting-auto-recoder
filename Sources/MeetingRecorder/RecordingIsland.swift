import AppKit
import Combine
import Darwin
import SwiftUI

/// Keeps the recording controls in an accessory process, independent of Spaces transitions.
@MainActor
final class RecordingIslandController {
    private weak var model: RecorderModel?
    private var phaseSubscription: AnyCancellable?
    private var targetSubscription: AnyCancellable?
    private var readinessSubscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var writeWork: DispatchWorkItem?
    private var child: Child?
    private var retiringChild: Child?
    private var enabled: Bool
    private var isTerminating = false
    private var sessionStarted = false
    private var didRecord = false
    private var stopRequested = false
    private var startRequested = false
    private var showingEnded = false
    private var lastPhase: RecorderModel.Phase = .idle
    private var message = RecordingIslandMessage(phase: "idle", elapsed: "00:00", targetName: "", bundleID: nil, processID: nil)
    private var failures = 0
    private var retryExhausted = false

    private final class Child {
        let id = UUID()
        let process: Process
        let input: FileHandle
        let output: FileHandle
        var readSource: DispatchSourceRead?
        var inputBuffer = Data()
        var ignoringLine = false
        // Preserve a partially written line; coalesce all later updates into one.
        var writing = Data()
        var next: Data?
        init(process: Process, input: FileHandle, output: FileHandle) {
            self.process = process
            self.input = input
            self.output = output
        }
    }

    init(model: RecorderModel, enabled: Bool = true) {
        self.model = model
        self.enabled = enabled
        phaseSubscription = model.$phase.sink { [weak self] phase in self?.receive(phase) }
        targetSubscription = model.$activeTarget.sink { [weak self] target in
            guard let self, self.sessionStarted, let target else { return }
            self.message.targetName = String(target.name.prefix(200))
            self.message.bundleID = target.bundleID.map { String($0.prefix(256)) }
            self.message.processID = target.processID
            self.sendState()
        }
        // Published values are delivered in willSet. Read the combined state on
        // the next main-actor turn, after all related model updates have settled.
        model.$selectedTargetID.dropFirst().sink { [weak self] _ in self?.scheduleReadinessRefresh() }.store(in: &readinessSubscriptions)
        model.$availableApps.dropFirst().sink { [weak self] _ in self?.scheduleReadinessRefresh() }.store(in: &readinessSubscriptions)
        model.$root.dropFirst().sink { [weak self] _ in self?.scheduleReadinessRefresh() }.store(in: &readinessSubscriptions)
        model.$isPolishing.dropFirst().sink { [weak self] _ in self?.scheduleReadinessRefresh() }.store(in: &readinessSubscriptions)
    }

    func setEnabled(_ value: Bool) {
        guard !isTerminating else { return }
        guard enabled != value else { return }
        enabled = value
        retryWork?.cancel()
        retryWork = nil
        if !value {
            hideWork?.cancel()
            hideWork = nil
            if showingEnded {
                showingEnded = false
                message = RecordingIslandMessage(phase: "idle", elapsed: "00:00", targetName: "", bundleID: nil, processID: nil)
            }
            closeChild()
        } else {
            failures = 0
            retryExhausted = false
            if lastPhase == .idle && !showingEnded { refreshReadiness() }
            sendState()
        }
    }

    // Called synchronously before the app begins its asynchronous shutdown.
    func prepareForTermination() {
        isTerminating = true
        hideWork?.cancel()
        hideWork = nil
        retryWork?.cancel()
        retryWork = nil
        stopTimer()
        closeChild()
    }

    private func receive(_ phase: RecorderModel.Phase) {
        guard !isTerminating else { return }
        // @Published delivers the new value before the model property changes.
        lastPhase = phase
        hideWork?.cancel()
        hideWork = nil
        showingEnded = false
        stopRequested = false
        startRequested = false
        switch phase {
        case .preparing:
            sessionStarted = true
            didRecord = false
            failures = 0
            retryExhausted = false
            retryWork?.cancel()
            retryWork = nil
            message = RecordingIslandMessage(phase: "preparing", elapsed: "00:00", targetName: "", bundleID: nil, processID: nil)
            stopTimer()
            sendState()
        case .recording:
            sessionStarted = true
            didRecord = true
            message.phase = "recording"
            updateElapsed()
            startTimer()
        case .stopping:
            stopTimer()
            guard sessionStarted && didRecord else {
                sessionStarted = false
                message = RecordingIslandMessage(phase: "idle", elapsed: "00:00", targetName: "", bundleID: nil, processID: nil)
                sendState()
                scheduleReadinessRefresh()
                return
            }
            message.phase = "stopping"
            message.canStart = false
            sendState()
        case .idle:
            stopTimer()
            let showEnded = sessionStarted && didRecord && enabled
            sessionStarted = false
            didRecord = false
            if showEnded, child != nil {
                showingEnded = true
                message.phase = "ended"
                message.canStart = false
                sendState()
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.lastPhase == .idle else { return }
                    self.showingEnded = false
                    self.message = RecordingIslandMessage(phase: "idle", elapsed: "00:00", targetName: "", bundleID: nil, processID: nil)
                    self.refreshReadiness()
                    self.sendState()
                }
                hideWork = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
            } else {
                message = RecordingIslandMessage(phase: "idle", elapsed: "00:00", targetName: "", bundleID: nil, processID: nil)
                sendState()
                scheduleReadinessRefresh()
            }
        }
    }

    private func scheduleReadinessRefresh() {
        Task { @MainActor [weak self] in self?.refreshReadiness() }
    }

    private func refreshReadiness() {
        guard !isTerminating, !showingEnded, !sessionStarted, let model else { return }
        let canStart = model.canBegin && model.root != nil
        guard message.canStart != canStart else { return }
        message.canStart = canStart
        sendState()
    }

    private func startChild() {
        guard enabled, !isTerminating, child == nil, retiringChild == nil, retryWork == nil, !retryExhausted, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let writeFD = input.fileHandleForWriting.fileDescriptor
        let readFD = output.fileHandleForReading.fileDescriptor
        // A stopped helper must never block or deliver SIGPIPE to the recording app.
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1,
              fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK) != -1 else {
            NSLog("Recording island: could not configure helper pipes")
            scheduleRetry()
            return
        }
        process.executableURL = executable
        process.arguments = ["--notch-helper"]
        process.standardInput = input
        process.standardOutput = output
        let instance = Child(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
        let id = instance.id
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.childExited(id: id) }
        }
        do {
            try process.run()
        } catch {
            NSLog("Recording island: could not start helper")
            scheduleRetry()
            return
        }
        // The child owns these ends after launch; retaining them prevents EOF.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        child = instance
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .main)
        instance.readSource = source
        source.setEventHandler { [weak self] in self?.readCommands(id: id) }
        source.resume()
    }

    private func sendState() {
        guard enabled, !isTerminating else { return }
        if child == nil { startChild() }
        guard let child, let encoded = try? JSONEncoder().encode(message) else { return }
        var line = encoded
        line.append(10)
        if child.writing.isEmpty { child.writing = line } else { child.next = line }
        flushWrites(id: child.id)
    }

    private func flushWrites(id: UUID) {
        guard let child, child.id == id else { return }
        writeWork?.cancel()
        writeWork = nil
        while !child.writing.isEmpty {
            let result = child.writing.withUnsafeBytes { bytes in
                Darwin.write(child.input.fileDescriptor, bytes.baseAddress!, bytes.count)
            }
            if result > 0 {
                child.writing.removeFirst(result)
                if child.writing.isEmpty, let next = child.next {
                    child.writing = next
                    child.next = nil
                }
            } else if result == -1 && errno == EINTR {
                continue
            } else if result == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                let item = DispatchWorkItem { [weak self] in self?.flushWrites(id: id) }
                writeWork = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
                return
            } else {
                // Process termination is handled separately; do not affect recording.
                child.writing.removeAll()
                child.next = nil
                return
            }
        }
    }

    private func readCommands(id: UUID) {
        guard let child, child.id == id else { return }
        var bytes = [UInt8](repeating: 0, count: 512)
        // Bound the work per event even if the helper misbehaves.
        for _ in 0..<8 {
            let count = Darwin.read(child.output.fileDescriptor, &bytes, bytes.count)
            if count == 0 { child.readSource?.cancel(); child.readSource = nil; return }
            if count < 0 { if errno == EINTR { continue }; return }
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    if !child.ignoringLine, child.inputBuffer == Data("stop".utf8) { requestStop() }
                    if !child.ignoringLine, child.inputBuffer == Data("start".utf8) { requestStart() }
                    child.inputBuffer.removeAll(keepingCapacity: true)
                    child.ignoringLine = false
                } else if !child.ignoringLine {
                    if child.inputBuffer.count < 64 { child.inputBuffer.append(byte) }
                    else { child.inputBuffer.removeAll(); child.ignoringLine = true }
                }
            }
        }
    }

    private func requestStop() {
        guard !stopRequested, lastPhase == .preparing || lastPhase == .recording else { return }
        stopRequested = true
        Task { [weak model] in await model?.stop() }
    }

    private func requestStart() {
        guard !isTerminating, !startRequested, let model else { return }
        startRequested = true
        guard lastPhase == .idle, !showingEnded, model.canBegin, model.root != nil else {
            // Never start as a side effect of opening configuration.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if !model.isBusy {
                model.errorMessage = "녹음할 앱과 저장 폴더를 먼저 선택해 주세요."
            }
            refreshReadiness()
            sendState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startRequested = false }
            return
        }
        model.begin()
    }

    private func childExited(id: UUID) {
        if retiringChild?.id == id {
            retiringChild = nil
            if enabled { sendState() }
            return
        }
        guard let child, child.id == id else { return }
        self.child = nil
        writeWork?.cancel()
        writeWork = nil
        child.readSource?.cancel()
        child.readSource = nil
        try? child.input.close()
        try? child.output.close()
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard enabled, !isTerminating else { return }
        guard failures < 3 else {
            retryExhausted = true
            NSLog("Recording island: helper unavailable; recording controls remain in the app")
            return
        }
        failures += 1
        retryWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            guard self.enabled, self.child == nil else { return }
            self.sendState()
        }
        retryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func closeChild() {
        writeWork?.cancel()
        writeWork = nil
        guard let child else { return }
        self.child = nil
        child.readSource?.cancel()
        child.readSource = nil
        // Closing stdin lets the helper exit; it does not change recording state.
        try? child.input.close()
        try? child.output.close()
        if child.process.isRunning {
            retiringChild = child
            // A stuck helper must not prevent a later session from showing controls.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak child] in
                guard let self, let child, self.retiringChild?.id == child.id, child.process.isRunning else { return }
                child.process.terminate()
            }
        }
    }

    private func startTimer() {
        stopTimer()
        let next = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
        next.tolerance = 0.2
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func updateElapsed() {
        if let start = model?.activeStartedAt {
            let seconds = max(0, Int(Date().timeIntervalSince(start)))
            message.elapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        sendState()
    }

    deinit {
        timer?.invalidate()
        hideWork?.cancel()
        retryWork?.cancel()
        writeWork?.cancel()
        child?.readSource?.cancel()
        try? child?.input.close()
        try? child?.output.close()
    }
}

@MainActor
final class RecordingIslandState: ObservableObject {
    enum Phase { case idle, preparing, recording, stopping, ended }
    @Published var phase: Phase = .preparing
    @Published var elapsed = "00:00"
    @Published var expanded = false
    @Published var hasNotch = false
    @Published var notchWidth: CGFloat = 0
    @Published var panelWidth: CGFloat = 432
    @Published var targetIcon: NSImage?
    @Published var targetName = ""
    @Published var canStart = false
    var hoverChanged: ((Bool) -> Void)?
    var toggleExpanded: (() -> Void)?
    var stop: (() -> Void)?
    var start: (() -> Void)?
}
