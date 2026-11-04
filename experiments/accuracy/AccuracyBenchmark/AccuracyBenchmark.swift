import AVFoundation
import Foundation
import RecorderCore
import RecorderAudio

struct AccuracySample: Decodable { let id: String; let path: String; let duration: Double }
struct AccuracyManifest: Decodable { let samples: [AccuracySample] }
struct AccuracyEvent: Encodable {
    let elapsed: Double
    let start: Double
    let end: Double
    let final: Bool
    let text: String
    let afterInput: Bool
}
struct AccuracyResult: Encodable {
    let id: String
    let text: String
    let seconds: Double
    let duration: Double
    let realtime: Bool
    let error: String?
    let events: [AccuracyEvent]
}

@main enum AccuracyBenchmark {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "--duplex-check", let model = SpeechModel(rawValue: args[2]) {
            try await checkDuplex(model: model, path: args[3]); return
        }
        guard args.count >= 5,
              let segmentation = SpeechSegmentation(rawValue: args[2]) else {
            fatalError("AccuracyBenchmark model energy|vad manifest.json output.jsonl [--realtime] [--silence seconds] [--threshold probability]")
        }
        func argument(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let modelName = args[1]
        guard SpeechModel(rawValue: modelName) != nil || modelName == "qwen3-asr-1.7b" else {
            throw RecorderError.message("Unknown benchmark model: " + modelName)
        }
        let realtime = args.contains("--realtime")
        let silence = argument("--silence").flatMap(Double.init)
        let threshold = argument("--threshold").flatMap(Float.init) ?? 0.5
        let manifest = try JSONDecoder().decode(AccuracyManifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let url = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RecorderError.message("평가 결과에는 새 파일 경로를 지정해 주세요.")
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let worker: QwenSpeechDecoder?
        let decoder: LiveSpeechDecoder
        if let model = SpeechModel(rawValue: modelName) {
            try await SpeechLane.prepareAssets(model: model, segmentation: segmentation) { fputs("\($0)\n", stderr) }
            worker = nil; decoder = .whisper
        } else {
            if segmentation == .voiceActivity { try await SpeechLane.prepareVoiceDetector() }
            let child = QwenSpeechDecoder()
            try await child.start()
            worker = child; decoder = LiveSpeechDecoder { try await child.transcribe($0) }
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        for (i, sample) in manifest.samples.enumerated() {
            var events: [AccuracyEvent] = []
            var meeting = Meeting(title: "Evaluation")
            var errors: [String] = []
            var inputFinished = false
            let begin = ProcessInfo.processInfo.systemUptime
            let lane = try await SpeechLane.create(source: .system, emitPartials: true,
                segmentation: segmentation, silenceDuration: silence, speechThreshold: threshold, decoder: decoder,
                skipObsoletePreviews: !args.contains("--eager-previews"),
                onResult: { segment, final in
                    if final { meeting.add(segment) }
                    events.append(AccuracyEvent(elapsed: ProcessInfo.processInfo.systemUptime - begin,
                        start: segment.start, end: segment.end, final: final, text: segment.text, afterInput: inputFinished))
                }, onError: { message in Task { @MainActor in errors.append(message) } })
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: sample.path))
                let converter = PCMConverter(outputFormat: format)
                var offset = 0.0
                while file.framePosition < file.length {
                    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: realtime ? 320 : 4096)!
                    try file.read(into: input)
                    if let buffer = try converter.convert(input) {
                        let end = offset + Double(buffer.frameLength) / 16_000
                        if realtime {
                            let remaining = begin + end - ProcessInfo.processInfo.systemUptime
                            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                        }
                        try lane.consume(buffer, at: offset)
                        offset = end
                        if !realtime { try await lane.synchronize() }
                    }
                }
                // Same trailing silence for every model; allows normal endpointing before EOF.
                var padding = 32_768
                while padding > 0 {
                    let count = min(padding, realtime ? 320 : 4096)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                    buffer.frameLength = AVAudioFrameCount(count)
                    memset(buffer.floatChannelData![0], 0, count * MemoryLayout<Float>.size)
                    let end = offset + Double(count) / 16_000
                    if realtime {
                        let remaining = begin + end - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                    }
                    try lane.consume(buffer, at: offset); offset = end; padding -= count
                    if !realtime { try await lane.synchronize() }
                }
                inputFinished = true
                try await lane.finish()
            } catch { await lane.cancel(); errors.append(error.localizedDescription) }
            let result = AccuracyResult(id: sample.id, text: meeting.sortedSegments.map(\.text).joined(separator: " "),
                seconds: ProcessInfo.processInfo.systemUptime - begin, duration: sample.duration, realtime: realtime,
                error: errors.isEmpty ? nil : errors.joined(separator: "; "), events: events)
            try output.write(contentsOf: JSONEncoder().encode(result) + Data([10]))
            try output.synchronize()
            fputs("\(modelName)/\(segmentation.rawValue) \(i + 1)/\(manifest.samples.count) \(String(format: "%.2f", result.seconds))s \(result.error ?? "OK")\n", stderr)
        }
        await worker?.stop()
        await SpeechLane.releaseAssets()
    }
}
