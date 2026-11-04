import CryptoKit
import Darwin
import Foundation
import Metal
import WhisperKit
import whisper

enum MetalWhisperAssets {
    static let file = "ggml-large-v3.bin"
    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let digest = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
    static let byteCount: Int64 = 3_095_033_483
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingRecorder/WhisperMetal", isDirectory: true)

    private struct Receipt: Codable, Equatable {
        let sha256: String
        let modified: Date
        let bytes: Int64
    }
    private static func receipt(for url: URL) throws -> Receipt {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.int64Value == byteCount,
              let date = attrs[.modificationDate] as? Date else {
            throw RecorderError.message("음성 모델 크기를 확인하지 못했습니다.")
        }
        return Receipt(sha256: digest, modified: date, bytes: size.int64Value)
    }
    static func installed(in root: URL = directory) -> Bool {
        guard let current = try? receipt(for: root.appendingPathComponent(file)),
              let data = try? Data(contentsOf: root.appendingPathComponent("verified.json")),
              let saved = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return current == saved
    }
    private static func verify(_ url: URL) throws {
        _ = try receipt(for: url)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
            throw RecorderError.message("음성 모델의 다운로드 무결성 확인에 실패했습니다.")
        }
    }
    static func prepare(progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(file)
        if installed() { return target }
        // A complete cached file can recover from an interrupted receipt write without a download.
        var verified = false
        if fm.fileExists(atPath: target.path) {
            progress("로컬 음성 모델 파일 확인 중…")
            do { try verify(target); verified = true } catch { try Task.checkCancellation() }
        }
        if !verified {
            progress("Whisper large-v3 GPU 모델 다운로드 중… 약 3.10 GB, 처음 한 번만 필요합니다")
            let remote = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/\(file)")!
            let (temporary, response) = try await URLSession.shared.download(from: remote)
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw RecorderError.message("음성 모델을 내려받지 못했습니다.")
            }
            try verify(temporary)
            let staging = directory.appendingPathComponent(".download-" + UUID().uuidString)
            defer { try? fm.removeItem(at: staging) }
            try fm.moveItem(at: temporary, to: staging)
            try Task.checkCancellation()
            guard rename(staging.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let data = try JSONEncoder().encode(receipt(for: target))
        try data.write(to: directory.appendingPathComponent("verified.json"), options: .atomic)
        return target
    }
}

private final class DecodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.withLock { stopped = true } }
    var isCancelled: Bool { lock.withLock { stopped } }
}

/// Model state is owned by the speech engine's existing two-lane decode permit.
final class MetalWhisperDecoder {
    private let context: OpaquePointer
    init(model: URL) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw RecorderError.message("Metal 음성 인식에 사용할 GPU가 없습니다.") }
        var options = whisper_context_default_params()
        options.use_gpu = true
        options.flash_attn = true
        guard let loaded = whisper_init_from_file_with_params(model.path, options) else {
            throw RecorderError.message("Whisper GPU 모델을 열지 못했습니다.")
        }
        context = loaded
    }
    deinit { whisper_free(context) }

    func transcribe(_ samples: [Float], aligned: Bool, temperature: Float = 0) async throws -> [TranscriptionSegment] {
        guard !samples.isEmpty else { return [] }
        let cancellation = DecodeCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var options = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            options.n_threads = 4
            options.greedy.best_of = 1
            options.no_context = true
            options.n_max_text_ctx = 0
            options.detect_language = false
            options.translate = false
            options.no_timestamps = false
            options.token_timestamps = aligned
            options.temperature = temperature
            options.print_progress = false
            options.print_realtime = false
            options.print_timestamps = false
            options.print_special = false
            options.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            options.abort_callback = { pointer in
                guard let pointer else { return false }
                return Unmanaged<DecodeCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
            }
            let status = "ko".withCString { language in
                options.language = language
                return samples.withUnsafeBufferPointer { audio in
                    whisper_full(context, options, audio.baseAddress!, Int32(audio.count))
                }
            }
            try Task.checkCancellation()
            guard status == 0 else { throw RecorderError.message("로컬 GPU 전사에 실패했습니다 (\(status)).") }
            return (0..<whisper_full_n_segments(context)).compactMap { index in
                guard let raw = whisper_full_get_segment_text(context, index) else { return nil }
                let text = String(cString: raw)
                let tokenCount = whisper_full_n_tokens(context, index)
                let endToken = whisper_token_eot(context)
                var tokens: [MetalTimedToken] = []
                var logProbability: Float = 0
                var count = 0
                for i in 0..<tokenCount {
                    let token = whisper_full_get_token_data(context, index, i)
                    guard token.id < endToken else { continue }
                    logProbability += log(max(token.p, 1e-10)); count += 1
                    if aligned, let pointer = whisper_token_to_str(context, token.id) {
                        let bytes = Data(bytes: pointer, count: strlen(pointer))
                        tokens.append(MetalTimedToken(bytes: bytes, start: Float(token.t0) / 100,
                            end: Float(token.t1) / 100, id: Int(token.id), probability: token.p))
                    }
                }
                return TranscriptionSegment(start: Float(whisper_full_get_segment_t0(context, index)) / 100,
                    end: Float(whisper_full_get_segment_t1(context, index)) / 100, text: text,
                    avgLogprob: count > 0 ? logProbability / Float(count) : 0,
                    noSpeechProb: whisper_full_get_segment_no_speech_prob(context, index),
                    words: aligned ? MetalTimedToken.words(tokens, matching: text) : nil)
            }
        } onCancel: { cancellation.cancel() }
    }
}

package struct MetalTimedToken {
    package var bytes: Data
    package var start: Float
    package var end: Float
    package var id: Int
    package var probability: Float
    package init(bytes: Data, start: Float, end: Float, id: Int, probability: Float) {
        self.bytes = bytes; self.start = start; self.end = end; self.id = id; self.probability = probability
    }
    /// Korean BPE tokens can split a UTF-8 scalar. Decode whole whitespace-delimited words.
    package static func words(_ tokens: [Self], matching text: String) -> [WordTiming]? {
        var words: [WordTiming] = [], part = Data(), ids: [Int] = []
        var start: Float = 0, end: Float = 0, probability: Float = 1
        func flush() -> Bool {
            if part.isEmpty { return true }
            guard let word = String(data: part, encoding: .utf8) else { return false }
            words.append(WordTiming(word: word, tokens: ids, start: start, end: end, probability: probability))
            part.removeAll(keepingCapacity: true); ids.removeAll(keepingCapacity: true); probability = 1
            return true
        }
        for token in tokens {
            guard token.start >= 0, token.end >= token.start else { return nil }
            if let byte = token.bytes.first, [9,10,13,32].contains(byte), !flush() { return nil }
            if part.isEmpty { start = token.start }
            part.append(token.bytes); ids.append(token.id); end = token.end
            probability = min(probability, token.probability)
        }
        guard flush(), !words.isEmpty, words.map(\.word).joined() == text else { return nil }
        return words
    }
}
