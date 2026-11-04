import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Darwin
import RecorderCore

/// Only owned on CaptureService's serial control queue. A tap-only private
/// aggregate has no output device and never changes the default sound route.
final class ProcessAudioTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private var running = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var selectedAppExit: DispatchSourceProcess?
    private var initialBundles = Set<String>()
    private var selection: Set<AudioObjectID> = []
    private var registeredBundles: Set<String> = []
    private var notifiedFailure = false
    private let queue: DispatchQueue
    private let target: RecordingTarget
    private let policy: RecordingSoundPolicy
    private let onError: (String) -> Void
    private let tapUUID = UUID()
    private let realtimeQueue = DispatchQueue(label: "MeetingRecorder.audio-tap", qos: .userInteractive)

    init(queue: DispatchQueue, target: RecordingTarget, policy: RecordingSoundPolicy, onError: @escaping (String) -> Void) {
        self.queue = queue; self.target = target; self.policy = policy; self.onError = onError
    }

    static func validate(_ target: RecordingTarget) throws {
        guard let id = target.bundleID else { return }
        guard let pid = target.processID, let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, app.bundleIdentifier == id else { throw RecordingTargetError.appUnavailable(target.name) }
    }

    func start(delivery: DispatchQueue, receive: @escaping (AVAudioPCMBuffer, CMTime) -> Void) throws {
        do {
            if let pid = target.processID {
                let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                exit.setEventHandler { [weak self] in
                    guard let self, self.running else { return }
                    self.fail(RecordingTargetError.appUnavailable(self.target.name).localizedDescription)
                }
                selectedAppExit = exit
                exit.resume()
            }
            let roots = target.bundleID.map { Set([$0]) } ?? policy.excludedBundles
            initialBundles = roots
            for root in roots {
                initialBundles.formUnion(MeetingAppKind.helperBundleIDs(for: root))
                // Pre-register embedded audio helpers even if their first sound is
                // the chime that launches the process. Restrict this to the chosen app.
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: root) else { continue }
                for folder in ["Frameworks", "Helpers", "XPCServices", "Library/LoginItems"] {
                    let location = url.appendingPathComponent("Contents/" + folder)
                    let entries = (try? FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)) ?? []
                    for entry in entries where ["app", "xpc"].contains(entry.pathExtension) {
                        if let id = Bundle(url: entry)?.bundleIdentifier, MeetingAppKind.includes(id, for: root) {
                            initialBundles.insert(id)
                        }
                    }
                }
            }
            let (ids, bundles) = try routes()
            let description = description(for: ids, bundles: bundles)
            try check(AudioHardwareCreateProcessTap(description, &tap), "오디오 전용 녹음을 준비하지 못했습니다")
            selection = ids; registeredBundles = bundles
            let specification: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Meeting Recorder Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &device), "녹음 장치를 만들지 못했습니다")
            // Subscribe before re-reading the list: do not miss a helper that
            // appeared between resolving the original selection and starting IO.
            let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            var address = property(kAudioHardwarePropertyProcessObjectList)
            try check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, changed), "앱 소리 변경을 감지하지 못했습니다")
            listener = changed
            let deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.checkDevice() }
            address = property(kAudioDevicePropertyDeviceIsAlive)
            try check(AudioObjectAddPropertyListenerBlock(device, &address, queue, deviceChanged), "녹음 장치 상태를 확인하지 못했습니다")
            deviceListener = deviceChanged
            var inputFormat = try tapFormat()
            let formatChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.running, !self.notifiedFailure else { return }
                do {
                    let updated = try self.tapFormat()
                    guard !updated.isEqual(inputFormat) else { return }
                    try self.check(AudioDeviceStop(self.device, self.io), "이전 오디오 형식을 해제하지 못했습니다")
                    self.running = false
                    if let io = self.io {
                        try self.check(AudioDeviceDestroyIOProcID(self.device, io), "이전 오디오 입력을 해제하지 못했습니다")
                        self.io = nil
                    }
                    try self.connectIO(format: updated, delivery: delivery, receive: receive)
                    try self.check(AudioDeviceStart(self.device, self.io), "변경한 오디오 장치에 연결하지 못했습니다")
                    inputFormat = updated
                    self.running = true
                } catch { self.fail(error.localizedDescription) }
            }
            address = property(kAudioTapPropertyFormat)
            try check(AudioObjectAddPropertyListenerBlock(tap, &address, queue, formatChanged), "오디오 형식 변경을 감지하지 못했습니다")
            formatListener = formatChanged
            inputFormat = try tapFormat()
            try connectIO(format: inputFormat, delivery: delivery, receive: receive)
            try updateSelection()
            try check(AudioDeviceStart(device, io), "시스템 오디오 녹음을 시작하지 못했습니다")
            running = true
        } catch { stop(); throw error }
    }

    private func tapFormat() throws -> AVAudioFormat {
        var format = AudioStreamBasicDescription()
        var address = property(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout.size(ofValue: format))
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "녹음 형식을 확인하지 못했습니다")
        guard let audio = AVAudioFormat(streamDescription: &format), format.mFormatID == kAudioFormatLinearPCM,
              format.mBytesPerFrame > 0 else { throw RecorderError.message("지원하지 않는 시스템 오디오 형식입니다.") }
        return audio
    }

    private func connectIO(format: AVAudioFormat, delivery: DispatchQueue, receive: @escaping (AVAudioPCMBuffer, CMTime) -> Void) throws {
        var frameCount = UInt32(0)
        var address = property(kAudioDevicePropertyBufferFrameSize)
        var size = UInt32(MemoryLayout.size(ofValue: frameCount))
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frameCount)
        let handoff = try TapBufferHandoff(format: format, capacity: max(4_096, frameCount),
            delivery: delivery, receive: receive, onError: onError)
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, realtimeQueue) { _, input, time, _, _ in
            handoff.copy(input, at: time.pointee)
        }, "오디오 입력을 연결하지 못했습니다")
    }

    private func routes() throws -> (Set<AudioObjectID>, Set<String>) {
        try Self.validate(target)
        let snapshot = AudioActivityReader.snapshot()
        guard snapshot.available else { throw RecorderError.message("오디오를 재생하는 프로세스를 확인하지 못했습니다.") }
        var ids = Set<AudioObjectID>()
        var bundles = initialBundles
        for p in snapshot.processes {
            guard let objectID = p.objectID else { continue }
            let id = p.bundleID.isEmpty ? NSRunningApplication(processIdentifier: p.processID)?.bundleIdentifier ?? "" : p.bundleID
            let selected: Bool
            if let root = target.bundleID {
                selected = p.processID == target.processID || MeetingAppKind.includes(id, for: root)
            } else {
                selected = p.processID == getpid() || policy.excludes(bundleID: id) ||
                    (policy.excludesAlerts && policy.excludesSystemService(at: executablePath(p.processID)))
            }
            if selected {
                ids.insert(objectID)
                if !id.isEmpty { bundles.insert(id) }
            }
        }
        return (ids, bundles)
    }

    private func executablePath(_ pid: Int32) -> String {
        var bytes = [CChar](repeating: 0, count: 4_096)
        let result = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        return result > 0 ? String(cString: bytes) : ""
    }

    private func description(for ids: Set<AudioObjectID>, bundles: Set<String>) -> CATapDescription {
        let description = target.isSystemAudio ? CATapDescription(monoGlobalTapButExcludeProcesses: ids.sorted()) :
            CATapDescription(monoMixdownOfProcesses: ids.sorted())
        description.uuid = tapUUID
        description.name = "Meeting Recorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        // Stable bundle IDs also cover clients starting to play after recording
        // begins. An app-specific tap is never converted into a global tap.
        description.bundleIDs = bundles.sorted()
        description.isProcessRestoreEnabled = target.isSystemAudio
        return description
    }

    private func updateSelection() throws {
        let (ids, bundles) = try routes()
        guard ids != selection || bundles != registeredBundles else { return }
        let updated = description(for: ids, bundles: bundles)
        var address = property(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(updated).toOpaque()
        let status = withExtendedLifetime(updated) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: reference)), &reference)
        }
        try check(status, "녹음 대상 앱의 변경을 반영하지 못했습니다")
        selection = ids; registeredBundles = bundles
    }

    private func refresh() {
        guard running, !notifiedFailure else { return }
        do { try updateSelection() } catch { fail(error.localizedDescription) }
    }

    private func checkDevice() {
        guard running, !notifiedFailure else { return }
        var alive: UInt32 = 0, size: UInt32 = 4
        var address = property(kAudioDevicePropertyDeviceIsAlive)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) != noErr || alive == 0 {
            fail("녹음 장치 연결이 끊겼습니다.")
        }
    }

    private func fail(_ message: String) {
        guard !notifiedFailure else { return }
        notifiedFailure = true
        // Stop admission immediately if the selection can no longer be enforced.
        if running { AudioDeviceStop(device, io); running = false }
        onError(message)
    }

    func stop() {
        selectedAppExit?.cancel(); selectedAppExit = nil
        if running { AudioDeviceStop(device, io); running = false }
        if let listener {
            var address = property(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            self.listener = nil
        }
        if let formatListener {
            var address = property(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tap, &address, queue, formatListener)
            self.formatListener = nil
        }
        if let deviceListener {
            var address = property(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, deviceListener)
            self.deviceListener = nil
        }
        if let io { AudioDeviceDestroyIOProcID(device, io); self.io = nil }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ message: String) throws {
        guard status != noErr else { return }
        throw RecorderError.message("\(message) (\(status)). 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 오디오 녹음 권한을 확인해 주세요.")
    }
}

/// One producer, one FIFO consumer. Copy HAL-owned memory before returning;
/// no audio conversion, file writing, transcription or blocking on the IO queue.
private final class TapBufferHandoff: @unchecked Sendable {
    private let buffers: [AVAudioPCMBuffer]
    private let available: DispatchSemaphore
    private var next = 0
    private var failed = false
    private let bytesPerFrame: UInt32
    private let delivery: DispatchQueue
    private let receive: (AVAudioPCMBuffer, CMTime) -> Void
    private let onError: (String) -> Void

    init(format: AVAudioFormat, capacity: UInt32, delivery: DispatchQueue,
         receive: @escaping (AVAudioPCMBuffer, CMTime) -> Void, onError: @escaping (String) -> Void) throws {
        buffers = (0..<32).compactMap { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) }
        guard buffers.count == 32 else { throw RecorderError.message("오디오 입력 버퍼를 준비하지 못했습니다.") }
        available = DispatchSemaphore(value: buffers.count)
        bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        self.delivery = delivery; self.receive = receive; self.onError = onError
    }

    func copy(_ list: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) {
        guard !failed else { return }
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = source.first, first.mDataByteSize > 0 else { return }
        let frames = first.mDataByteSize / bytesPerFrame
        let buffer = buffers[next]
        guard frames > 0, frames <= buffer.frameCapacity, first.mDataByteSize % bytesPerFrame == 0,
              available.wait(timeout: .now()) == .success else { reportFailure(); return }
        buffer.frameLength = frames
        let dest = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard dest.count == source.count else { available.signal(); reportFailure(); return }
        for index in source.indices {
            let src = source[index], dst = dest[index]
            guard src.mDataByteSize == dst.mDataByteSize, let out = dst.mData else { available.signal(); reportFailure(); return }
            if let input = src.mData { memcpy(out, input, Int(src.mDataByteSize)) }
            else { memset(out, 0, Int(src.mDataByteSize)) }
        }
        next = (next + 1) % buffers.count
        let timestamp = time.mFlags.contains(.hostTimeValid) ? CMClockMakeHostTimeFromSystemUnits(time.mHostTime) : CMClockGetTime(CMClockGetHostTimeClock())
        delivery.async { [self] in
            defer { available.signal() }
            receive(buffer, timestamp)
        }
    }

    private func reportFailure() {
        guard !failed else { return }; failed = true
        delivery.async { [onError] in onError("오디오 입력 형식이 바뀌었거나 저장 속도가 입력을 따라가지 못했습니다.") }
    }
}
