import Foundation
import FluidAudio

public enum SpeechSegmentation: String, Sendable {
    case energy
    case voiceActivity = "vad"
}

/// One small model, with a separate recurrent state for each capture lane.
actor SpeechActivityDetector {
    static let shared = SpeechActivityDetector()
    private var loading: Task<VadManager, Error>?

    private func model() async throws -> VadManager {
        if let loading { return try await loading.value }
        let task = Task { try await VadManager(config: VadConfig(defaultThreshold: 0.5)) }
        loading = task
        do { return try await task.value }
        catch { loading = nil; throw error }
    }

    func prepare() async throws { _ = try await model() }

    func classify(_ samples: [Float], state: VadStreamState) async throws -> VadStreamResult {
        let manager = try await model()
        try Task.checkCancellation()
        return try await manager.processStreamingChunk(samples, state: state)
    }

    func unload() { loading?.cancel(); loading = nil }
}

struct SpeechActivityBuffer {
    struct Block {
        let samples: [Float]
        let start: Double
        let isSpeech: Bool
    }
    private var samples: [Float] = []
    private var start: Double = 0
    private var expectedTime: Double?
    private var state = VadStreamState.initial()
    let threshold: Float

    init(threshold: Float = 0.5) { self.threshold = threshold }

    mutating func append(_ input: [Float], at time: Double) async throws -> [Block] {
        var blocks: [Block] = []
        if let expectedTime, abs(time - expectedTime) > 0.1 {
            if let tail = try await finish() { blocks.append(tail) }
        }
        if samples.isEmpty { start = time }
        samples.append(contentsOf: input)
        expectedTime = time + Double(input.count) / 16_000
        while samples.count >= VadManager.chunkSize {
            let audio = Array(samples.prefix(VadManager.chunkSize))
            let result = try await SpeechActivityDetector.shared.classify(audio, state: state)
            state = result.state
            blocks.append(Block(samples: audio, start: start, isSpeech: result.probability >= threshold))
            samples.removeFirst(VadManager.chunkSize)
            start += Double(VadManager.chunkSize) / 16_000
        }
        return blocks
    }

    mutating func finish() async throws -> Block? {
        defer { samples.removeAll(keepingCapacity: true); state = .initial(); expectedTime = nil }
        guard !samples.isEmpty else { return nil }
        let result = try await SpeechActivityDetector.shared.classify(samples, state: state)
        return Block(samples: samples, start: start, isSpeech: result.probability >= threshold)
    }
}
