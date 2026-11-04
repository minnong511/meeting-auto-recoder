import AVFoundation
import CoreML
import Foundation
import RecorderCore
import WhisperKit

/// Local speech models that can transcribe Korean.
public enum SpeechModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case largeV3Metal = "large-v3-metal"
    case largeV3Turbo = "large-v3-turbo"
    case largeV3TurboFP16 = "large-v3-turbo-fp16"
    case largeV3 = "large-v3"
    case small, base, tiny
    // The FP16 GPU path was validated with 16 GiB unified memory. Keep the compact model on smaller Macs.
    public static let recommended: Self = ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024 ? .largeV3Metal : .largeV3
    public var id: String { rawValue }
    public var variant: String {
        switch self {
        case .largeV3Metal: return MetalWhisperAssets.file
        case .largeV3Turbo: return "openai_whisper-large-v3-v20240930_626MB"
        case .largeV3TurboFP16: return "openai_whisper-large-v3-v20240930_turbo"
        case .largeV3: return "openai_whisper-large-v3_947MB"
        case .small: return "openai_whisper-small"
        case .base: return "openai_whisper-base"
        case .tiny: return "openai_whisper-tiny"
        }
    }
    public var displayName: String {
        switch self {
        case .largeV3Metal: return "Whisper large-v3 (Metal)"
        case .largeV3Turbo: return "Whisper large-v3-turbo"
        case .largeV3TurboFP16: return "Whisper large-v3-turbo FP16"
        case .largeV3: return "Whisper large-v3 (Core ML)"
        case .small: return "Whisper small"
        case .base: return "Whisper base"
        case .tiny: return "Whisper tiny"
        }
    }
    public var downloadDescription: String {
        let size: String
        switch self {
        case .largeV3Metal: return "약 3.10 GB · 맥 로컬 GPU"
        case .largeV3Turbo: size = "약 627 MB"
        case .largeV3TurboFP16: size = "약 1.64 GB"
        case .largeV3: size = "약 948 MB"
        case .small: size = "약 487 MB"
        case .base: size = "약 147 MB"
        case .tiny: size = "약 77 MB"
        }
        return "\(size) + 토크나이저·추가 캐시"
    }
    public var supportLabel: String { "\(displayName) · 실시간 결과 저장 · 로컬" }
    public var engineName: String { self == .largeV3Metal ? "whisper.cpp Metal" : "WhisperKit" }
    public var engineDescription: String { "\(engineName) · \(variant) · ko · live-only" }
}

public struct SpeechSupport: Codable, Sendable {
    public static let supportLabel = SpeechModel.recommended.supportLabel
    public static let engineDescription = SpeechModel.recommended.engineDescription
    public var engineAvailable: Bool
    public var koreanSupported: Bool
    public var koreanInstalled: Bool
    public var supportedLocales: [String]
    public var engine = "WhisperKit"
    public var model = SpeechModel.recommended.variant
    public var cachePath = LocalSpeechEngine.cacheRoot.path
    public var transcriptionMode = "live-only"
    public var postProcessingEnabled = false

    public static func inspect(model: SpeechModel = .recommended) async -> SpeechSupport {
        await inspect(model: model, cacheRoot: model == .largeV3Metal ? MetalWhisperAssets.directory : LocalSpeechEngine.cacheRoot)
    }
    public static func inspect(model: SpeechModel, cacheRoot: URL) async -> SpeechSupport {
        if model == .largeV3Metal {
            return SpeechSupport(engineAvailable: true, koreanSupported: true,
                koreanInstalled: MetalWhisperAssets.installed(in: cacheRoot), supportedLocales: ["ko-KR"],
                engine: model.engineName, model: model.variant, cachePath: cacheRoot.path)
        }
        let path = try? String(contentsOf: LocalSpeechEngine.readyMarker(for: model, cacheRoot: cacheRoot), encoding: .utf8)
        return SpeechSupport(engineAvailable: true, koreanSupported: true,
            koreanInstalled: path.map { LocalSpeechEngine.validModelFolder(URL(fileURLWithPath: $0), model: model) } ?? false,
            supportedLocales: ["ko-KR"], model: model.variant, cachePath: cacheRoot.path)
    }
}

/// Both inputs share one model. The explicit permit also serializes calls that
/// suspend inside Core ML; actor isolation alone would allow reentrant decoding.
private actor LocalSpeechEngine {
    static let shared = LocalSpeechEngine()
    static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingRecorder/Whisper", isDirectory: true)
    static func readyMarker(for model: SpeechModel, cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(model == .largeV3Turbo ? "ready-model-path.txt" : "ready-model-path-\(model.rawValue).txt")
    }
    private var kit: WhisperKit?
    private var metal: MetalWhisperDecoder?
    private var loadedModel: SpeechModel?
    private var busy = false
    private var required: [CheckedContinuation<Void, Never>] = []
    private var previews: [CheckedContinuation<Void, Never>] = []
    private func acquire(required isRequired: Bool = true) async {
        if busy {
            await withCheckedContinuation { continuation in
                if isRequired { required.append(continuation) } else { previews.append(continuation) }
            }
        }
        else { busy = true }
    }
    private func release() {
        if !required.isEmpty { required.removeFirst().resume() }
        else if !previews.isEmpty { previews.removeFirst().resume() }
        else { busy = false }
    }

    func prepare(model: SpeechModel, progress: @escaping @Sendable (String) -> Void) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if (kit != nil || metal != nil) && loadedModel == model { return }
        metal = nil
        loadedModel = nil
        if kit != nil {
            await kit?.unloadModels()
            kit = nil
        }
        if model == .largeV3Metal {
            let file = try await MetalWhisperAssets.prepare(progress: progress)
            try Task.checkCancellation()
            progress("로컬 GPU에서 Whisper large-v3 준비 중…")
            let decoder = try MetalWhisperDecoder(model: file)
            try Task.checkCancellation()
            metal = decoder; loadedModel = model
            progress("Whisper large-v3 준비됨 · 로컬 GPU 전사")
            return
        }
        try FileManager.default.createDirectory(at: Self.cacheRoot, withIntermediateDirectories: true)
        let marker = Self.readyMarker(for: model, cacheRoot: Self.cacheRoot)
        let folder: URL
        if let path = try? String(contentsOf: marker, encoding: .utf8),
           Self.validModelFolder(URL(fileURLWithPath: path), model: model) {
            folder = URL(fileURLWithPath: path)
        } else {
            progress("\(model.displayName) 다운로드 중… \(model.downloadDescription), 처음 한 번만 필요합니다")
            folder = try await WhisperKit.download(variant: model.variant, downloadBase: Self.cacheRoot) { value in
                progress("\(model.displayName) 다운로드 중… \(Int(value.fractionCompleted * 100))%")
            }
        }
        try Task.checkCancellation()
        progress("Whisper 모델을 맥북에 맞게 준비 중… 첫 실행에는 시간이 걸릴 수 있습니다")
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.cacheRoot,
            computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndNeuralEngine,
                                                 textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false, prewarm: true, load: true, download: false)
        let loaded = try await WhisperKit(config)
        try Task.checkCancellation()
        guard Self.validModelFolder(folder, model: model) else { throw RecorderError.message("선택한 Whisper 모델 파일을 확인하지 못했습니다.") }
        try folder.path.write(to: marker, atomically: true, encoding: .utf8)
        kit = loaded
        loadedModel = model
        progress("\(model.displayName) 준비됨 · 한국어 로컬 전사")
    }
    static func validModelFolder(_ folder: URL, model: SpeechModel) -> Bool {
        folder.lastPathComponent == model.variant && ["AudioEncoder", "TextDecoder", "MelSpectrogram"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0 + ".mlmodelc").path)
        }
    }
    func transcribe(_ request: WhisperAudioWindow.Request, wordTimestamps: Bool) async throws -> [TranscriptionSegment] {
        await acquire(required: request.isFinal)
        defer { release() }
        try Task.checkCancellation()
        if let metal {
            var result = try await metal.transcribe(request.samples, aligned: wordTimestamps)
            if request.isFinal && result.contains(where: { TranscriptText.isRepetitionLoop($0.text) }) {
                result = try await metal.transcribe(request.samples, aligned: wordTimestamps, temperature: 0.2)
            }
            return result
        }
        guard let kit else { throw RecorderError.message("Whisper 모델이 준비되지 않았습니다.") }
        var options = DecodingOptions(verbose: false, task: .transcribe, language: "ko",
            temperatureFallbackCount: 2, usePrefillPrompt: true, detectLanguage: false,
            skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: wordTimestamps,
            windowClipTime: 0, suppressBlank: true,
            // Judge the completed decode: early first-token rejection produced
            // empty output for audible Korean passages in the local lecture.
            firstTokenLogProbThreshold: nil, concurrentWorkerCount: 1)
        var result = try await kit.transcribe(audioArray: request.samples, decodeOptions: options)
        // Retry only the current uncommitted window, never a saved transcript.
        // Partial previews wait for finalization instead of doubling live work.
        if request.isFinal, result.flatMap(\.segments).contains(where: { TranscriptText.isRepetitionLoop($0.text) }) {
            try Task.checkCancellation()
            options.temperature = 0.2
            result = try await kit.transcribe(audioArray: request.samples, decodeOptions: options)
        }
        try Task.checkCancellation()
        return result.flatMap(\.segments)
    }
    func unload() async {
        await acquire()
        defer { release() }
        await kit?.unloadModels()
        kit = nil
        metal = nil
        loadedModel = nil
    }
}

/// Restore source times and commit overlapping word ranges only once.
public struct WhisperTranscriptMapper {
    public private(set) var committedThrough: Double = -.infinity
    public private(set) var requiresReview = false
    public init() {}
    public mutating func map(_ results: [TranscriptionSegment], request: WhisperAudioWindow.Request,
                             source: AudioSource) -> TranscriptSegment {
        let accepted = results.filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -1) }
        requiresReview = false
        let lower = committedThrough
        let upper = request.commitThrough ?? request.end
        var words: [TranscriptWord] = []
        var parts: [String] = []
        var hasCoarseText = false
        var mappedEnd = upper
        for result in accepted {
            if TranscriptText.isRepetitionLoop(result.text) {
                if request.isFinal {
                    parts.append(" [음성 인식 확인 필요] ")
                    hasCoarseText = true
                    requiresReview = true
                }
                continue
            }
            if let timing = result.words, !timing.isEmpty,
               timing.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }) {
                for item in timing {
                    let start = request.start + Double(item.start)
                    let end = request.start + Double(item.end)
                    guard end > lower + 0.0001,
                          end <= upper + 0.025 else { continue }
                    let word = TranscriptWord(text: item.word, start: max(request.start, start), end: min(request.end, end))
                    words.append(word)
                    parts.append(item.word)
                }
            } else if request.start + Double(result.end) > lower + 0.005 {
                // Coarse text remains available when word alignment is missing.
                // The diarizer can mark an ambiguous passage for review.
                hasCoarseText = true
                parts.append(result.text)
                mappedEnd = max(mappedEnd, min(request.end, request.start + Double(result.end)))
            }
        }
        let mappedStart = !hasCoarseText ? words.first?.start ?? request.start : max(request.start, lower)
        var segment = TranscriptSegment(source: source, start: mappedStart, end: mappedEnd, text: parts.joined())
        if request.isFinal && !hasCoarseText && !words.isEmpty { segment.words = words }
        if request.isFinal { committedThrough = max(committedThrough, mappedEnd) }
        return segment
    }
}

/// Alternate local decoders can be compared by package experiments using the same
/// capture, endpointing and commit path as the app. Only Whisper ships in the app.
public struct LiveSpeechDecoder: Sendable {
    public static let whisper = LiveSpeechDecoder(utterance: nil)
    fileprivate let utterance: (@Sendable ([Float]) async throws -> String)?
    package init(utterance: (@Sendable ([Float]) async throws -> String)?) { self.utterance = utterance }

    fileprivate func transcribe(_ request: WhisperAudioWindow.Request, wordTimestamps: Bool) async throws -> [TranscriptionSegment] {
        if let utterance {
            let text = try await utterance(request.samples)
            return [TranscriptionSegment(start: 0, end: Float(request.samples.count) / 16_000, text: text)]
        }
        return try await LocalSpeechEngine.shared.transcribe(request, wordTimestamps: wordTimestamps)
    }
}

/// The capture queue keeps moving while decoding suspends. Obsolete previews must
/// never delay a final; use the audio clock so file replay and live input agree.
package final class LivePreviewPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedThrough = -Double.infinity
    package init() {}
    package func received(through time: Double) {
        lock.withLock { receivedThrough = max(receivedThrough, time) }
    }
    package func shouldDecode(final: Bool, isSpeech: Bool?, end: Double) -> Bool {
        if final { return true }
        if isSpeech == false { return false }
        return lock.withLock { receivedThrough - end <= 0.5 }
    }
}

public final class SpeechLane {
    private enum Input {
        case audio([Float], Double)
        case barrier(CheckedContinuation<Void, Error>, finalize: Bool)
    }
    public let source: AudioSource
    private let converter = PCMConverter(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
    private let continuation: AsyncStream<Input>.Continuation
    private var resultTask: Task<Void, Error>?
    private let previewPolicy = LivePreviewPolicy()
    private var nextInputTime: Double?
    private init(source: AudioSource, continuation: AsyncStream<Input>.Continuation) {
        self.source = source
        self.continuation = continuation
    }
    package static func prepareVoiceDetector() async throws {
        try await SpeechActivityDetector.shared.prepare()
    }

    @discardableResult public static func prepareAssets(model: SpeechModel = .recommended, segmentation: SpeechSegmentation = .voiceActivity,
                              allowEnergyFallback: Bool = false, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SpeechSegmentation {
        var effective = segmentation
        if segmentation == .voiceActivity {
            progress("말소리 감지 모델 준비 중…")
            do { try await prepareVoiceDetector() }
            catch {
                try Task.checkCancellation()
                guard allowEnergyFallback else { throw error }
                effective = .energy
                progress("말소리 감지 모델을 준비하지 못해 기본 감지로 계속합니다.")
            }
        }
        try await LocalSpeechEngine.shared.prepare(model: model, progress: progress)
        return effective
    }
    public static func releaseAssets() async {
        await LocalSpeechEngine.shared.unload()
        await SpeechActivityDetector.shared.unload()
    }

    public static func create(source: AudioSource, emitPartials: Bool = true,
                              segmentation: SpeechSegmentation = .voiceActivity, silenceDuration: Double? = nil, speechThreshold: Float = 0.5,
                              decoder: LiveSpeechDecoder = .whisper, skipObsoletePreviews: Bool = true,
                              onResult: @escaping @MainActor (TranscriptSegment, Bool) -> Void,
                              onError: @escaping (String) -> Void,
                              onWarning: @escaping @MainActor (String) -> Void = { _ in }) async throws -> SpeechLane {
        let alignedWords = decoder.utterance == nil
        let (stream, continuation) = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        let lane = SpeechLane(source: source, continuation: continuation)
        let previews = lane.previewPolicy
        lane.resultTask = Task {
            var window = WhisperAudioWindow(silenceDuration: silenceDuration ?? (segmentation == .energy ? 0.8 : 0.6),
                maximumDuration: alignedWords ? 24 : 30, retainedTailSeconds: alignedWords ? 8 : 0)
            var activity = SpeechActivityBuffer(threshold: speechThreshold)
            var mapper = WhisperTranscriptMapper()
            var failure: Error?
            func decode(_ request: WhisperAudioWindow.Request) async throws {
                let result = try await decoder.transcribe(request,
                    wordTimestamps: request.isFinal || mapper.committedThrough > request.start)
                let before = mapper.committedThrough
                let segment = mapper.map(result, request: request, source: source)
                if mapper.requiresReview {
                    await onWarning("\(source.label) \(TranscriptMarkdown.timestamp(segment.start)) 부근의 반복 인식 오류로 확인 표시를 남겼습니다. 원본 음성은 보존됩니다.")
                }
                if CommandLine.arguments.contains("--window-diagnostics") {
                    let stats: [String: Any] = ["start": request.start, "end": request.end,
                        "commitBefore": before.isFinite ? before : -1, "outputCharacters": segment.text.count,
                        "raw": result.map { item -> [String: Any] in
                            ["start": item.start, "end": item.end, "characters": item.text.count,
                             "words": item.words?.count ?? 0, "noSpeech": item.noSpeechProb,
                             "logProbability": item.avgLogprob,
                             "lastWordEnd": item.words?.last?.end ?? -1]
                        }]
                    if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys]) {
                        fputs(String(decoding: data, as: UTF8.self) + "\n", stderr)
                    }
                }
                await onResult(segment, request.isFinal)
            }
            func appendWindow(_ samples: [Float], at start: Double, isSpeech: Bool? = nil) async throws {
                for request in window.append(samples, at: start, isSpeech: isSpeech) where request.isFinal || emitPartials {
                    if skipObsoletePreviews && segmentation == .voiceActivity && !previews.shouldDecode(final: request.isFinal, isSpeech: isSpeech, end: request.end) { continue }
                    try await decode(request)
                }
            }
            func flushActivity() async throws {
                if segmentation == .voiceActivity, let tail = try await activity.finish() {
                    try await appendWindow(tail.samples, at: tail.start, isSpeech: tail.isSpeech)
                }
            }
            for await input in stream {
                if Task.isCancelled || failure != nil {
                    if case let .barrier(reply, _) = input { reply.resume(throwing: failure ?? CancellationError()) }
                    continue
                }
                do {
                    switch input {
                    case let .audio(samples, start):
                        if segmentation == .voiceActivity {
                            for block in try await activity.append(samples, at: start) {
                                try await appendWindow(block.samples, at: block.start, isSpeech: block.isSpeech)
                            }
                        } else { try await appendWindow(samples, at: start) }
                    case let .barrier(reply, finalize):
                        do {
                            if finalize {
                                try await flushActivity()
                                if let request = window.finish() { try await decode(request) }
                            }
                            reply.resume()
                        } catch { reply.resume(throwing: error); throw error }
                    }
                } catch {
                    failure = error
                    continuation.finish()
                    if !(error is CancellationError) { onError(error.localizedDescription) }
                }
            }
            if !Task.isCancelled && failure == nil {
                do {
                    try await flushActivity()
                    if let request = window.finish() { try await decode(request) }
                }
                catch { failure = error; if !(error is CancellationError) { onError(error.localizedDescription) } }
            }
            if let failure { throw failure }
            try Task.checkCancellation()
        }
        return lane
    }

    // Called on the capture queue. At most ~20 seconds of copied PCM can queue.
    public func consume(_ buffer: AVAudioPCMBuffer, at seconds: Double) throws {
        guard let converted = try converter.convert(buffer), let data = converted.floatChannelData?[0] else { return }
        let start = nextInputTime.map { seconds - $0 < 0.1 ? $0 : seconds } ?? seconds
        let end = start + Double(converted.frameLength) / 16_000
        nextInputTime = end
        previewPolicy.received(through: end)
        for offset in stride(from: 0, to: Int(converted.frameLength), by: 320) {
            let count = min(320, Int(converted.frameLength) - offset)
            let samples = Array(UnsafeBufferPointer(start: data + offset, count: count))
            if case .dropped = continuation.yield(.audio(samples, start + Double(offset) / 16_000)) {
                throw RecorderError.message("실시간 전사가 입력을 따라가지 못했습니다. 원본 오디오는 복구용으로 보존합니다.")
            }
        }
    }
    public func synchronize() async throws { try await barrier(finalize: false) }
    public func finalizePending() async throws { try await barrier(finalize: true) }
    private func barrier(finalize: Bool) async throws {
        try await withCheckedThrowingContinuation { reply in
            switch continuation.yield(.barrier(reply, finalize: finalize)) {
            case .enqueued: break
            case .dropped, .terminated: reply.resume(throwing: RecorderError.message("전사 입력이 종료됐거나 처리 대기열이 가득 찼습니다."))
            @unknown default: reply.resume(throwing: CancellationError())
            }
        }
    }
    public func finish() async throws {
        continuation.finish()
        try await resultTask?.value
    }
    public func cancel() async {
        continuation.finish()
        resultTask?.cancel()
        _ = await resultTask?.result
    }
}
