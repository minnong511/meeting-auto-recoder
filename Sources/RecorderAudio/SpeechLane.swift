import AVFoundation
import CoreML
import Foundation
import RecorderCore
import WhisperKit

public struct SpeechSupport: Codable, Sendable {
    public static let supportLabel = "Whisper large-v3-turbo · 실시간 결과 저장 · 로컬"
    public static let engineDescription = "WhisperKit · large-v3-v20240930_626MB · ko · live-only"
    public var engineAvailable: Bool
    public var koreanSupported: Bool
    public var koreanInstalled: Bool
    public var supportedLocales: [String]
    public var engine = "WhisperKit"
    public var model = WhisperEngine.variant
    public var cachePath = WhisperEngine.cacheRoot.path
    public var transcriptionMode = "live-only"
    public var postProcessingEnabled = false

    public static func inspect() async -> SpeechSupport {
        let path = try? String(contentsOf: WhisperEngine.readyMarker, encoding: .utf8)
        return SpeechSupport(engineAvailable: true, koreanSupported: true,
            koreanInstalled: path.map { WhisperEngine.validModelFolder(URL(fileURLWithPath: $0)) } ?? false,
            supportedLocales: ["ko-KR"])
    }
}

/// Both inputs share one model. The explicit permit also serializes calls that
/// suspend inside Core ML; actor isolation alone would allow reentrant decoding.
private actor WhisperEngine {
    static let shared = WhisperEngine()
    static let variant = "large-v3-v20240930_626MB"
    static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingRecorder/Whisper", isDirectory: true)
    static let readyMarker = cacheRoot.appendingPathComponent("ready-model-path.txt")
    private var kit: WhisperKit?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    func prepare(progress: @escaping @Sendable (String) -> Void) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard kit == nil else { return }
        try FileManager.default.createDirectory(at: Self.cacheRoot, withIntermediateDirectories: true)
        let folder: URL
        if let path = try? String(contentsOf: Self.readyMarker, encoding: .utf8),
           Self.validModelFolder(URL(fileURLWithPath: path)) {
            folder = URL(fileURLWithPath: path)
        } else {
            progress("Whisper 모델 다운로드 중… 약 627 MB, 처음 한 번만 필요합니다")
            folder = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.cacheRoot) { value in
                progress("Whisper 모델 다운로드 중… \(Int(value.fractionCompleted * 100))%")
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
        kit = loaded
        try folder.path.write(to: Self.readyMarker, atomically: true, encoding: .utf8)
        progress("Whisper large-v3-turbo 준비됨 · 한국어 로컬 전사")
    }
    static func validModelFolder(_ folder: URL) -> Bool {
        ["AudioEncoder", "TextDecoder", "MelSpectrogram"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0 + ".mlmodelc").path)
        }
    }
    func transcribe(_ request: WhisperAudioWindow.Request, wordTimestamps: Bool) async throws -> [TranscriptionSegment] {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
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

public final class SpeechLane {
    private enum Input {
        case audio([Float], Double)
        case barrier(CheckedContinuation<Void, Error>, finalize: Bool)
    }
    public let source: AudioSource
    private let converter = PCMConverter(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
    private let continuation: AsyncStream<Input>.Continuation
    private var resultTask: Task<Void, Error>?
    private var nextInputTime: Double?
    private init(source: AudioSource, continuation: AsyncStream<Input>.Continuation) {
        self.source = source
        self.continuation = continuation
    }
    public static func prepareAssets(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await WhisperEngine.shared.prepare(progress: progress)
    }
    public static func releaseAssets() async { await WhisperEngine.shared.unload() }

    public static func create(source: AudioSource, emitPartials: Bool = true,
                              onResult: @escaping @MainActor (TranscriptSegment, Bool) -> Void,
                              onError: @escaping (String) -> Void,
                              onWarning: @escaping @MainActor (String) -> Void = { _ in }) async throws -> SpeechLane {
        let (stream, continuation) = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        let lane = SpeechLane(source: source, continuation: continuation)
        lane.resultTask = Task {
            var window = WhisperAudioWindow()
            var mapper = WhisperTranscriptMapper()
            var failure: Error?
            func decode(_ request: WhisperAudioWindow.Request) async throws {
                let result = try await WhisperEngine.shared.transcribe(request,
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
            for await input in stream {
                if Task.isCancelled || failure != nil {
                    if case let .barrier(reply, _) = input { reply.resume(throwing: failure ?? CancellationError()) }
                    continue
                }
                do {
                    switch input {
                    case let .audio(samples, start):
                        for request in window.append(samples, at: start) where request.isFinal || emitPartials {
                            try await decode(request)
                        }
                    case let .barrier(reply, finalize):
                        do {
                            if finalize, let request = window.finish() { try await decode(request) }
                            reply.resume()
                        } catch { reply.resume(throwing: error); throw error }
                    }
                } catch {
                    failure = error
                    continuation.finish()
                    if !(error is CancellationError) { onError(error.localizedDescription) }
                }
            }
            if !Task.isCancelled && failure == nil, let request = window.finish() {
                do { try await decode(request) }
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
        nextInputTime = start + Double(converted.frameLength) / 16_000
        for offset in stride(from: 0, to: Int(converted.frameLength), by: 320) {
            let count = min(320, Int(converted.frameLength) - offset)
            let samples = Array(UnsafeBufferPointer(start: data + offset, count: count))
            if case .dropped = continuation.yield(.audio(samples, start + Double(offset) / 16_000)) {
                throw RecorderError.message("Whisper 전사가 입력을 따라가지 못했습니다. 원본 오디오는 복구용으로 보존합니다.")
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
