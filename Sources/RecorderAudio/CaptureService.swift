import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import ScreenCaptureKit

public struct CaptureMetrics: Sendable {
    public var microphoneLevel: Double = 0
    public var systemLevel: Double = 0
    public var microphoneFrames: Int64 = 0
    public var systemFrames: Int64 = 0
    public var microphoneWasEnabled = true
    public init() {}
}

public final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingRecorder.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var microphoneEnabled: Bool
    private var writers: [AudioSource: AudioChunkWriter] = [:]
    private var converters: [AudioSource: PCMConverter] = [:]
    private var lanes: [AudioSource: SpeechLane]
    private var baseTime: CMTime?
    private var metrics = CaptureMetrics()
    private var lastMeterUpdate: TimeInterval = 0
    private var accepting = true
    private var reportedFailure = false
    private let onMetrics: (CaptureMetrics) -> Void
    private let onError: (String) -> Void

    public init(directory: URL, lanes: [AudioSource: SpeechLane], microphoneEnabled: Bool = true,
                onChunk: @escaping (AudioChunk) -> Void,
                onMetrics: @escaping (CaptureMetrics) -> Void,
                onError: @escaping (String) -> Void) {
        self.lanes = lanes
        self.microphoneEnabled = microphoneEnabled
        self.metrics.microphoneWasEnabled = microphoneEnabled
        self.onMetrics = onMetrics
        self.onError = onError
        super.init()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for source in AudioSource.allCases {
            converters[source] = PCMConverter(outputFormat: format)
            writers[source] = AudioChunkWriter(source: source, directory: directory, format: format, onChange: onChunk)
        }
    }

    public static func recordingContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let details = error as NSError
            if details.code == -3801 {
                throw RecorderError.message("ScreenCaptureKit이 오디오 접근을 거부했습니다 (\(details.domain), \(details.code)). 시스템 설정의 화면 및 시스템 오디오 녹음에서 Meeting Recorder를 허용하고 앱을 다시 실행해 주세요.")
            }
            throw RecorderError.message("시스템 오디오 접근 확인 실패 (\(details.domain), \(details.code)): \(error.localizedDescription)")
        }
    }

    public static func contentFilter(content: SCShareableContent, target: RecordingTarget) throws -> SCContentFilter {
        guard let display = content.displays.first else { throw RecorderError.message("녹음할 디스플레이를 찾을 수 없습니다.") }
        if target.isSystemAudio { return SCContentFilter(display: display, excludingWindows: []) }
        let identities = content.applications.map { ApplicationIdentity(bundleID: $0.bundleIdentifier, processID: $0.processID) }
        let included = try RecordingTargetPolicy.included(for: target, in: identities)
        let pids = Set(included.map(\.processID))
        let applications = content.applications.filter { pids.contains($0.processID) }
        // Empty/missing selections throw above; never broaden to system audio.
        return SCContentFilter(display: display, including: applications, exceptingWindows: [])
    }

    public func start(content: SCShareableContent, target: RecordingTarget) async throws {
        let filter = try Self.contentFilter(content: content, target: target)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = microphoneEnabled
        configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        self.stream = stream
        self.configuration = configuration
        try await stream.startCapture()
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard let stream, let configuration else { throw RecorderError.message("녹음이 진행 중이 아닙니다.") }
        if !enabled {
            // Stop admitting microphone samples before waiting for the OS update.
            await setMicrophoneGate(false)
        }
        configuration.captureMicrophone = enabled
        try await stream.updateConfiguration(configuration)
        if enabled { await setMicrophoneGate(true) }
    }

    private func setMicrophoneGate(_ enabled: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.microphoneEnabled = enabled
                if enabled { self.metrics.microphoneWasEnabled = true }
                else {
                    self.metrics.microphoneLevel = 0
                    self.writers[.microphone]?.close()
                }
                self.onMetrics(self.metrics)
                continuation.resume()
            }
        }
    }

    public func stop() async -> (chunks: [AudioChunk], metrics: CaptureMetrics, error: String?) {
        var stopError: String?
        do { try await stream?.stopCapture() } catch { stopError = error.localizedDescription }
        let result: ([AudioChunk], CaptureMetrics) = await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                self.writers.values.forEach { $0.close() }
                continuation.resume(returning: (self.writers.values.flatMap(\.chunks), self.metrics))
            }
        }
        stream = nil
        configuration = nil
        return (result.0, result.1, stopError)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid else { return }
        let source: AudioSource
        switch type { case .audio: source = .system; case .microphone: source = .microphone; default: return }
        guard source != .microphone || microphoneEnabled else { return }
        do {
            let original = try AudioBuffers.copy(sampleBuffer)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isNumeric else { return }
            if baseTime == nil { baseTime = timestamp }
            let seconds = max(0, (timestamp - baseTime!).seconds)
            guard let pcm = try converters[source]?.convert(original) else { return }
            try writers[source]?.write(pcm, at: seconds)
            try lanes[source]?.consume(pcm, at: seconds)
            let level = AudioBuffers.level(pcm)
            if source == .microphone { metrics.microphoneLevel = level; metrics.microphoneFrames += Int64(pcm.frameLength) }
            else { metrics.systemLevel = level; metrics.systemFrames += Int64(pcm.frameLength) }
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastMeterUpdate > 0.1 { lastMeterUpdate = now; onMetrics(metrics) }
        } catch {
            if !reportedFailure { reportedFailure = true; onError(error.localizedDescription) }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error.localizedDescription) }
}
