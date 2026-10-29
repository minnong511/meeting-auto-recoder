import Foundation
import CoreML
import FluidAudio
import WhisperKit

struct Sample: Decodable { let id: String; let path: String; let duration: Double }
struct Manifest: Decodable { let samples: [Sample] }
struct Result: Encodable {
    let id: String
    let text: String
    let seconds: Double
    let duration: Double
    let error: String?
}

@main enum Benchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { fatalError("ASRBenchmark whisper|cohere manifest.json model-dir output.jsonl") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let output = URL(fileURLWithPath: args[4])
        var done = Set<String>()
        if let data = try? String(contentsOf: output, encoding: .utf8) {
            for line in data.split(separator: "\n") {
                if let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = value["id"] as? String { done.insert(id) }
            }
        }
        if !FileManager.default.fileExists(atPath: output.path) { FileManager.default.createFile(atPath: output.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: output)
        try handle.seekToEnd()
        defer { try? handle.close() }
        let loadStart = Date()
        var whisper: WhisperKit?
        var cohere: CoherePipeline.LoadedModels?
        let pipeline = CoherePipeline()
        if args[1] == "whisper" {
            whisper = try await WhisperKit(WhisperKitConfig(modelFolder: args[3],
                tokenizerFolder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingRecorder/Whisper"),
                computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
                verbose: false, prewarm: true, load: true, download: false))
        } else {
            let root = URL(fileURLWithPath: args[3])
            cohere = try await CoherePipeline.loadModels(encoderDir: root.appendingPathComponent("q8"), decoderDir: root.appendingPathComponent("q8"), vocabDir: root, computeUnits: .cpuAndNeuralEngine)
        }
        fputs("LOAD_SECONDS \(Date().timeIntervalSince(loadStart))\n", stderr)
        for (i, sample) in manifest.samples.enumerated() where !done.contains(sample.id) {
            let start = Date()
            let result: Result
            do {
                let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: sample.path)
                let text: String
                if let whisper {
                    let options = DecodingOptions(verbose: false, task: .transcribe, language: "ko", temperatureFallbackCount: 2,
                        usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: false,
                        wordTimestamps: true, windowClipTime: 0, suppressBlank: true, firstTokenLogProbThreshold: nil, concurrentWorkerCount: 1)
                    text = try await whisper.transcribe(audioArray: audio, decodeOptions: options).map(\.text).joined(separator: " ")
                } else {
                    text = try await pipeline.transcribeLong(audio: audio, models: cohere!, language: .korean).text
                }
                result = Result(id: sample.id, text: text, seconds: Date().timeIntervalSince(start), duration: sample.duration, error: nil)
            } catch {
                result = Result(id: sample.id, text: "", seconds: Date().timeIntervalSince(start), duration: sample.duration, error: error.localizedDescription)
            }
            let data = try JSONEncoder().encode(result)
            try handle.write(contentsOf: data + Data([10]))
            try handle.synchronize()
            fputs("\(args[1]) \(i + 1)/\(manifest.samples.count) \(String(format: "%.2f", result.seconds))s \(result.error ?? "OK")\n", stderr)
        }
        await whisper?.unloadModels()
    }
}
