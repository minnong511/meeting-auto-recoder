import CryptoKit
import FluidAudio
import Foundation

/// A capture consumer owns one 16 kHz stream. Only the microphone transcription lane uses it.
public final class MicrophoneNoiseFilter {
    typealias Block = MicrophoneFilterBuffer.Block

    private static let revision = "4205430781c240397073d6f7bf676fb4c732fc12"
    private static let bundle = "localvqe-v1.3-4.8M-16ms.mlmodelc"
    private static let checksums = [
        ("model.mil", "8dddf32c801cdb90329e43748a46e9321ef2b14c8d41d6515c541c81a43cbbf4"),
        ("coremldata.bin", "795709e1ad528f94a7d76226e0e408d1897ee0a6603d32fdfad9ffb5b668fd22"),
        ("analytics/coremldata.bin", "b38b26719f7fdb1d37d0ea66e2a72c0cb2f111105b606636d733b958ea3d7892"),
        ("weights/weight.bin", "fc5f290cbfb497718d9d9568ee965c352bfe4663bab49b30a10e91f8fcfff826")
    ]

    private let stream: LocalVqeStream
    private var buffer = MicrophoneFilterBuffer()

    // The immutable model can serve multiple recordings. Each recording gets fresh recurrent state.
    private actor ModelCache {
        var model: LocalVqeManager?

        func get() async throws -> LocalVqeManager {
            if let model { return model }
            let prepared = try await MicrophoneNoiseFilter.loadModel()
            try Task.checkCancellation()
            if let model { return model }
            model = prepared
            return prepared
        }
    }

    private static let cache = ModelCache()

    public static func prepare() async throws -> MicrophoneNoiseFilter {
        let model = try await cache.get()
        try Task.checkCancellation()
        return try await MicrophoneNoiseFilter(stream: model.makeStream())
    }

    private static func loadModel() async throws -> LocalVqeManager {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecorder/LocalVQE/" + revision, isDirectory: true)
        for (file, expected) in checksums {
            try Task.checkCancellation()
            let relative = bundle + "/" + file
            let target = directory.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: target, options: .mappedIfSafe), digest(data) == expected { continue }
            let url = URL(string: "https://huggingface.co/FluidInference/localvqe-coreml/resolve/\(revision)/\(relative)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), digest(data) == expected else {
                throw RecorderError.message("팬 소음 억제 모델을 내려받아 확인하지 못했습니다.")
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        try Task.checkCancellation()
        let config = LocalVqeConfig(variant: .v13, chunk: .realtime16ms, computeUnits: .cpuOnly)
        return try LocalVqeManager(config: config, modelDirectory: directory)
    }

    private init(stream: LocalVqeStream) { self.stream = stream }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func hasGap(at start: Double) -> Bool { buffer.hasGap(at: start) }

    func append(_ samples: [Float], at start: Double) async throws -> Block? {
        buffer.append(samples, at: start)
        let output = try await stream.enhance(mic: samples, reference: [Float](repeating: 0, count: samples.count))
        return try buffer.mix(output)
    }

    func finish() async throws -> Block? {
        let tail = try await stream.flush()
        return try buffer.mix(tail, final: true)
    }

    func takePendingOriginal() -> Block? { buffer.takePendingOriginal() }
}

/// The network emits earlier samples. Hold their dry counterparts until it is safe to mix or recover them.
package struct MicrophoneFilterBuffer {
    package struct Block {
        package let samples: [Float]
        package let start: Double
    }

    private var pending: [Float] = []
    private var origin: Double?
    private var inputCount = 0
    private var outputCount = 0

    package init() {}

    package func hasGap(at start: Double) -> Bool {
        guard let origin else { return false }
        return abs(start - origin - Double(inputCount) / 16_000) > 0.1
    }

    package mutating func append(_ samples: [Float], at start: Double) {
        if origin == nil { origin = start }
        pending.append(contentsOf: samples)
        inputCount += samples.count
    }

    package mutating func mix(_ output: [Float], final: Bool = false) throws -> Block? {
        if final && output.count != pending.count {
            throw RecorderError.message("팬 소음 억제 결과의 길이가 원본과 다릅니다.")
        }
        guard !output.isEmpty else {
            if final { self = Self() }
            return nil
        }
        guard let origin, output.count <= pending.count, output.allSatisfy(\.isFinite) else {
            throw RecorderError.message("팬 소음 억제 결과를 원본 시각에 맞추지 못했습니다.")
        }
        let start = origin + Double(outputCount) / 16_000
        let samples = zip(pending, output).map { $0 + 0.5 * ($1 - $0) }
        pending.removeFirst(output.count)
        outputCount += output.count
        if final { self = Self() }
        return Block(samples: samples, start: start)
    }

    /// Return every sample that was accepted but not yet delivered if enhancement fails.
    package mutating func takePendingOriginal() -> Block? {
        defer { self = Self() }
        guard let origin, !pending.isEmpty else { return nil }
        return Block(samples: pending, start: origin + Double(outputCount) / 16_000)
    }
}
