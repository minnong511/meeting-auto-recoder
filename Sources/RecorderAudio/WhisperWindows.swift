import Foundation

/// Bounded 16 kHz speech windows. Only decoders with word timestamps reuse an overlapping tail.
public struct WhisperAudioWindow: Sendable {
    public struct Request: Sendable {
        public var samples: [Float]
        public var start: Double
        public var end: Double { start + Double(samples.count) / 16_000 }
        public var commitThrough: Double?
        public var isFinal: Bool { commitThrough != nil }
        public init(samples: [Float], start: Double, commitThrough: Double?) {
            self.samples = samples; self.start = start; self.commitThrough = commitThrough
        }
    }
    private var samples: [Float] = []
    private var start: Double = 0
    private var lastVoice: Double?
    private var lastDecode: Double = 0
    public var bufferedSampleCount: Int { samples.count }
    private let silenceDuration: Double
    private let maximumSamples: Int
    private let retainedSamples: Int
    public init(silenceDuration: Double = 0.8, maximumDuration: Double = 24, retainedTailSeconds: Double = 8) {
        self.silenceDuration = silenceDuration.isFinite && silenceDuration > 0 ? silenceDuration : 0.8
        let maximum = maximumDuration.isFinite ? min(30, max(2, maximumDuration)) : 24
        maximumSamples = Int(maximum * 16_000)
        retainedSamples = Int(min(maximum - 1, max(0, retainedTailSeconds.isFinite ? retainedTailSeconds : 8)) * 16_000)
    }

    public mutating func append(_ input: [Float], at time: Double, isSpeech: Bool? = nil) -> [Request] {
        var requests: [Request] = []
        if !samples.isEmpty && time - (start + Double(samples.count) / 16_000) > 0.1 {
            if let request = finish() { requests.append(request) }
        }
        for offset in stride(from: 0, to: input.count, by: 320) {
            let block = input[offset..<min(offset + 320, input.count)]
            let blockStart = time + Double(offset) / 16_000
            if samples.isEmpty { start = blockStart; lastDecode = start }
            samples.append(contentsOf: block)
            let end = start + Double(samples.count) / 16_000
            if isSpeech ?? (block.reduce(0.0) { $0 + Double($1 * $1) } / Double(block.count) > 0.000001) { lastVoice = end }
            guard let lastVoice else {
                if samples.count > 4_800 {
                    let removed = samples.count - 4_800
                    samples.removeFirst(removed)
                    start += Double(removed) / 16_000
                    lastDecode = start
                }
                continue
            }
            if end - lastVoice >= silenceDuration {
                if let request = finish() { requests.append(request) }
            } else if samples.count >= maximumSamples {
                requests.append(Request(samples: samples, start: start, commitThrough: retainedSamples == 0 ? end : end - 1))
                // A very short final tail can be classified as silence when it
                // begins inside a word. Retain enough preceding speech for the
                // decoder to recognize the whole sentence, then trim by time.
                let removed = samples.count - retainedSamples
                samples.removeFirst(removed)
                start += Double(removed) / 16_000
                lastDecode = end
                if samples.isEmpty { self.lastVoice = nil }
            } else if end - lastDecode >= 4 && end - start >= 3.8 {
                requests.append(Request(samples: samples, start: start, commitThrough: nil))
                lastDecode = end
            }
        }
        return requests
    }

    public mutating func finish() -> Request? {
        defer { samples = []; lastVoice = nil; lastDecode = 0 }
        guard lastVoice != nil, !samples.isEmpty else { return nil }
        return Request(samples: samples, start: start, commitThrough: start + Double(samples.count) / 16_000)
    }
}
