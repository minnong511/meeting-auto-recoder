import AVFoundation
import Foundation
import RecorderCore

public enum FinalASR {
    struct Configuration: Decodable {
        var engine: String
        var python: String?
        var model: String?
        let worker: String?
        let models: [String: String]?
        let runtimes: [String: String]?
    }
    static var configuration: Configuration? {
        let url = ProcessInfo.processInfo.environment["MEETING_RECORDER_ASR_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("LocalASR.json")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard var config = try? JSONDecoder().decode(Configuration.self, from: data) else { return nil }
        if ProcessInfo.processInfo.environment["MEETING_RECORDER_ASR_CONFIG"] == nil,
           let chosen = UserDefaults.standard.string(forKey: "finalTranscriptionEngine"),
           ["cohere", "qwen17", "whisper"].contains(chosen) {
            if chosen == "whisper" { config.engine = chosen }
            else if let model = config.models?[chosen] {
                config.engine = chosen; config.model = model
                config.python = config.runtimes?[chosen] ?? config.python
            }
        }
        return config
    }
    public static var engineChoice: String { configuration?.engine ?? "whisper" }
    public static func selectEngine(_ engine: String) {
        guard ["cohere", "qwen17", "whisper"].contains(engine) else { return }
        UserDefaults.standard.set(engine, forKey: "finalTranscriptionEngine")
    }
    public static var enabled: Bool { ["qwen17", "cohere"].contains(configuration?.engine ?? "") }
    public static var modelName: String { configuration?.engine == "cohere" ? "Cohere Transcribe 2B" : "Qwen3-ASR 1.7B" }
    public static var isInstalled: Bool {
        guard let config = configuration, let python = config.python, let model = config.model, let worker = config.worker else { return false }
        return FileManager.default.isExecutableFile(atPath: python)
            && FileManager.default.fileExists(atPath: model + "/model.safetensors")
            && FileManager.default.fileExists(atPath: worker)
    }
    public static var supportLabel: String {
        enabled ? "실시간 Whisper · 저장 \(modelName) · 로컬" : "Whisper large-v3-turbo · 한국어 로컬 전사"
    }

    public static func refine(systemAudio: URL, microphoneAudio: URL? = nil, turns: [SpeakerTurn],
                              meeting: Meeting, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Meeting {
        guard enabled, let config = configuration else { return SpeakerAttribution.apply(turns, to: meeting) }
        let fm = FileManager.default
        guard let python = config.python, fm.isExecutableFile(atPath: python),
              let model = config.model, fm.fileExists(atPath: model + "/model.safetensors"),
              let worker = config.worker, fm.fileExists(atPath: worker) else {
            throw RecorderError.message("최종 전사 환경이 없습니다. scripts/setup-local-asr.sh를 실행한 후 다시 시도하세요. 기존 실시간 대화록은 보존했습니다.")
        }
        let temporary = fm.temporaryDirectory.appendingPathComponent("MeetingRecorder-ASR-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        progress("최종 전사 오디오 준비 중…")
        let system = temporary.appendingPathComponent("system.wav")
        let systemInfo = try convert(systemAudio, to: system, detectVoice: false)
        var audio: [String: String] = ["system": system.path]
        var micInfo: (Double, [(Double, Double)]) = (0, [])
        if let microphoneAudio {
            let mic = temporary.appendingPathComponent("microphone.wav")
            micInfo = try convert(microphoneAudio, to: mic, detectVoice: true)
            audio["microphone"] = mic.path
        }
        let jobs = FinalTranscriptPlan.jobs(turns: turns, microphone: micInfo.1,
            systemDuration: systemInfo.0, microphoneDuration: micInfo.0, prior: meeting.segments)
        guard !jobs.isEmpty else { return SpeakerAttribution.apply(turns, to: meeting) }
        struct Request: Encodable { let audio: [String: String]; let jobs: [FinalTranscriptJob] }
        struct Output: Decodable { let id: Int; let text: String }
        let request = temporary.appendingPathComponent("request.json")
        let result = temporary.appendingPathComponent("result.json")
        try JSONEncoder().encode(Request(audio: audio, jobs: jobs)).write(to: request, options: .atomic)
        let log = temporary.appendingPathComponent("worker.log")
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [worker, model, request.path, result.path, config.engine == "cohere" ? "ko" : "Korean"]
        process.standardOutput = handle; process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment
        progress("\(modelName)로 화자별 최종 전사 중… \(jobs.count)개 발화")
        try Task.checkCancellation()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                process.terminationHandler = { process in reply.resume(returning: process.terminationStatus) }
                do { try process.run() }
                catch { process.terminationHandler = nil; reply.resume(throwing: error) }
                if Task.isCancelled && process.isRunning { process.terminate() }
            }
        } onCancel: { if process.isRunning { process.terminate() } }
        try Task.checkCancellation()
        guard status == 0, let data = try? Data(contentsOf: result) else {
            throw RecorderError.message("최종 전사를 마치지 못했습니다(종료 코드 \(status)). 기존 대화록과 복구 오디오는 보존했습니다.")
        }
        let outputs = try JSONDecoder().decode([Output].self, from: data)
        guard outputs.count == jobs.count, Set(outputs.map(\.id)) == Set(jobs.map(\.id)) else {
            throw RecorderError.message("최종 전사 결과가 일부 누락되어 기존 대화록을 보존했습니다.")
        }
        let byID = Dictionary(uniqueKeysWithValues: outputs.map { ($0.id, $0.text) })
        var updated = meeting
        var segments: [TranscriptSegment] = []
        var fallbackCount = 0
        for job in jobs {
            if let text = TranscriptText.clean(byID[job.id] ?? "") {
                segments.append(TranscriptSegment(source: job.source, start: job.start, end: job.end, text: text))
            } else {
                // Empty short acknowledgements keep their already-confirmed words.
                let sourceSegments = meeting.segments.filter { $0.source == job.source }
                let sourceWords: [TranscriptWord] = sourceSegments.flatMap { $0.words ?? [] }
                let words = sourceWords.filter { word in
                    let middle = (word.start + word.end) / 2
                    return middle >= job.start && middle <= job.end
                }
                if let text = TranscriptText.clean(words.map { $0.text }.joined()) {
                    segments.append(TranscriptSegment(source: job.source, start: job.start, end: job.end, text: text))
                    fallbackCount += 1
                } else if meeting.segments.contains(where: { $0.source == job.source && $0.start < job.end && $0.end > job.start && !$0.text.isEmpty }) {
                    throw RecorderError.message("발화의 최종 전사가 비어 있어 기존 대화록을 보존했습니다.")
                }
            }
        }
        let retained = FinalTranscriptPlan.uncovered(meeting.segments, jobs: jobs)
        segments.append(contentsOf: retained)
        updated.segments = segments
        updated.transcriptionEngine = "\(modelName) · MLX \(config.engine == "cohere" ? "8bit" : "4bit") · Korean · Whisper live" + (fallbackCount > 0 || !retained.isEmpty ? " · Whisper fallback" : "")
        return SpeakerAttribution.apply(turns, to: updated)
    }

    /// Stream resampling to scratch WAV; long meetings do not become a single RAM array.
    private static func convert(_ input: URL, to output: URL, detectVoice: Bool) throws -> (Double, [(Double, Double)]) {
        let file = try AVAudioFile(forReading: input)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let converter = PCMConverter(outputFormat: format)
        let writer = try AVAudioFile(forWriting: output, settings: format.settings)
        var frames: Int64 = 0
        var start: Double?
        var lastVoice: Double = 0
        var regions: [(Double, Double)] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: buffer)
            guard let converted = try converter.convert(buffer) else { continue }
            let time = Double(frames) / 16000
            let end = time + Double(converted.frameLength) / 16000
            if detectVoice, let samples = converted.floatChannelData?[0] {
                var energy: Double = 0
                for i in 0..<Int(converted.frameLength) { energy += Double(samples[i] * samples[i]) }
                if energy / Double(max(1, converted.frameLength)) > 0.000001 {
                    if start == nil { start = max(0, time - 0.2) }
                    lastVoice = end
                } else if let lo = start, end - lastVoice > 0.8 {
                    regions.append((lo, min(end, lastVoice + 0.2))); start = nil
                }
            }
            try writer.write(from: converted)
            frames += Int64(converted.frameLength)
        }
        let duration = Double(frames) / 16000
        if let start { regions.append((start, min(duration, lastVoice + 0.2))) }
        return (duration, regions)
    }
}
