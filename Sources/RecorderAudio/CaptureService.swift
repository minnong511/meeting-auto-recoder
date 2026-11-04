import AVFoundation
import CoreMedia
import Foundation
import RecorderCore

public struct CaptureMetrics: Sendable {
    public var microphoneLevel: Double = 0
    public var systemLevel: Double = 0
    public var microphoneFrames: Int64 = 0
    public var systemFrames: Int64 = 0
    public var microphoneWasEnabled = true
    public init() {}
}

public final class CaptureService: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let control = DispatchQueue(label: "MeetingRecorder.capture-control", qos: .userInitiated)
    private let queue = DispatchQueue(label: "MeetingRecorder.capture", qos: .userInitiated)
    // Device lifecycle belongs to control. Sample acceptance, clocks, writers and metrics belong to queue.
    private var tap: ProcessAudioTap?
    private var micSession: AVCaptureSession?
    private var micErrorObserver: NSObjectProtocol?
    private var micOutput: AVCaptureAudioDataOutput?
    private var micClock: CMClock?
    private let initialMicrophone: Bool
    private let soundPolicy: RecordingSoundPolicy
    private var stopped = false
    private var writers: [AudioSource: AudioChunkWriter] = [:]
    private var converters: [AudioSource: PCMConverter] = [:]
    private let lanes: [AudioSource: SpeechLane]
    private var baseTime: CMTime?
    private var metrics = CaptureMetrics()
    private var lastMeterUpdate: TimeInterval = 0
    private var accepting = false
    private var finishing = false
    private var failure: String?
    private let onMetrics: (CaptureMetrics) -> Void
    private let onError: (String) -> Void

    public init(directory: URL, lanes: [AudioSource: SpeechLane], microphoneEnabled: Bool = true,
                soundPolicy: RecordingSoundPolicy = RecordingSoundPolicy(),
                onChunk: @escaping (AudioChunk) -> Void,
                onMetrics: @escaping (CaptureMetrics) -> Void,
                onError: @escaping (String) -> Void) {
        self.lanes = lanes; initialMicrophone = microphoneEnabled; self.soundPolicy = soundPolicy
        self.metrics.microphoneWasEnabled = microphoneEnabled
        self.onMetrics = onMetrics; self.onError = onError
        super.init()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for source in AudioSource.allCases {
            converters[source] = PCMConverter(outputFormat: format)
            writers[source] = AudioChunkWriter(source: source, directory: directory, format: format, onChange: onChunk)
        }
    }

    public static func validateTarget(_ target: RecordingTarget) throws { try ProcessAudioTap.validate(target) }

    public func start(target: RecordingTarget) async throws {
        try await onControl {
            guard self.tap == nil, !self.stopped else { throw RecorderError.message("녹음 장치를 다시 시작할 수 없습니다.") }
            let tap = ProcessAudioTap(queue: self.control, target: target, policy: self.soundPolicy) { [weak self] message in
                self?.queue.async { [weak self] in self?.fail(message) }
            }
            do {
                try tap.start(delivery: self.queue) { [weak self] pcm, time in self?.consume(pcm, at: time, source: .system) }
                self.tap = tap
                if self.initialMicrophone { try self.startMicrophone() }
                try self.queue.sync {
                    if let failure = self.failure { throw RecorderError.message(failure) }
                    self.accepting = true
                }
            } catch {
                self.stopMicrophone()
                tap.stop()
                self.tap = nil
                throw error
            }
        }
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        try await onControl {
            guard self.tap != nil, !self.stopped else { throw RecorderError.message("녹음이 진행 중이 아닙니다.") }
            if enabled { try self.startMicrophone() } else { self.stopMicrophone() }
        }
    }

    private func onControl(_ action: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { reply in
            control.async {
                do { try action(); reply.resume() }
                catch { reply.resume(throwing: error) }
            }
        }
    }

    private func startMicrophone() throws {
        guard micSession == nil else { return }
        guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderError.message("마이크를 찾지 못했습니다.") }
        let session = AVCaptureSession(), input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input) else { session.commitConfiguration(); throw RecorderError.message("마이크를 연결할 수 없습니다.") }
        session.addInput(input)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw RecorderError.message("마이크 입력을 받을 수 없습니다.") }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        // Both the mic and the HAL tap are mapped to the same monotonic host clock.
        queue.sync { self.micClock = session.synchronizationClock; self.micOutput = output }
        micSession = session
        micErrorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { [weak self, weak session] note in
                let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "마이크 연결이 끊겼습니다."
                self?.control.async { [weak self, weak session] in
                    guard let self, let session, self.micSession === session else { return }
                    self.queue.async { self.fail(message) }
                }
            }
        session.startRunning()
        guard session.isRunning else { stopMicrophone(); throw RecorderError.message("마이크 녹음을 시작하지 못했습니다. 마이크 권한과 입력 장치를 확인해 주세요.") }
        queue.sync { self.micClock = session.synchronizationClock; self.metrics.microphoneWasEnabled = true }
    }

    private func stopMicrophone() {
        guard let session = micSession else { return }
        micSession = nil
        if let micErrorObserver { NotificationCenter.default.removeObserver(micErrorObserver); self.micErrorObserver = nil }
        queue.sync {
            self.micOutput = nil; self.micClock = nil
            self.metrics.microphoneLevel = 0
            self.writers[.microphone]?.close()
            self.onMetrics(self.metrics)
        }
        for case let output as AVCaptureAudioDataOutput in session.outputs { output.setSampleBufferDelegate(nil, queue: nil) }
        session.stopRunning()
    }

    public func stop() async -> (chunks: [AudioChunk], metrics: CaptureMetrics, error: String?) {
        await withCheckedContinuation { reply in
            control.async {
                self.stopped = true
                self.queue.sync { self.accepting = false; self.finishing = true }
                self.stopMicrophone()
                self.tap?.stop(); self.tap = nil
                self.queue.async {
                    self.writers.values.forEach { $0.close() }
                    reply.resume(returning: (self.writers.values.flatMap(\.chunks), self.metrics, self.failure))
                }
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting, output === micOutput, sampleBuffer.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }
        let host = CMClockGetHostTimeClock()
        let time = micClock.map { CMSyncConvertTime(pts, from: $0, to: host) } ?? pts
        do { consume(try AudioBuffers.copy(sampleBuffer), at: time, source: .microphone) }
        catch { fail(error.localizedDescription) }
    }

    private func consume(_ input: AVAudioPCMBuffer, at timestamp: CMTime, source: AudioSource) {
        guard accepting, failure == nil, timestamp.isNumeric else { return }
        do {
            if baseTime == nil { baseTime = timestamp }
            let seconds = max(0, (timestamp - baseTime!).seconds)
            guard let pcm = try converters[source]?.convert(input) else { return }
            try writers[source]?.write(pcm, at: seconds)
            try lanes[source]?.consume(pcm, at: seconds)
            let level = AudioBuffers.level(pcm)
            if source == .microphone { metrics.microphoneLevel = level; metrics.microphoneFrames += Int64(pcm.frameLength) }
            else { metrics.systemLevel = level; metrics.systemFrames += Int64(pcm.frameLength) }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMeterUpdate > 0.1 { lastMeterUpdate = now; onMetrics(metrics) }
        } catch { fail(error.localizedDescription) }
    }

    private func fail(_ message: String) {
        guard !finishing, failure == nil else { return }
        failure = message
        if accepting { onError(message) }
    }
}
