import Foundation

/// Opt-in CLI measurement of the same worker used by the app. It writes no meeting files.
enum PolishingBenchmark {
    struct Input: Decodable {
        let id: String
        let text: String
        let preserve: [String]
    }
    struct Result: Encodable {
        let id: String
        let text: String
        let metrics: LocalTranscriptPolisher.Metrics?
        let missingMarkers: [String]
    }
    struct Report: Encodable {
        let model: String
        let requestedMode: LocalTranscriptPolisher.ComputeMode
        let startupMode: LocalTranscriptPolisher.ComputeMode
        let startupSeconds: Double
        let results: [Result]
    }

    static func run(input: URL, modelID: String, mode: LocalTranscriptPolisher.ComputeMode) async throws -> Data {
        let cases = try JSONDecoder().decode([Input].self, from: Data(contentsOf: input))
        guard let model = LocalTranscriptPolisher.installedModels().first(where: { $0.id == modelID }) else {
            throw PolishError.missingModel
        }
        let worker = LocalTranscriptPolisher(model: model)
        defer { worker.stop() }
        let start = ProcessInfo.processInfo.systemUptime
        try await worker.start(mode: mode)
        let startup = ProcessInfo.processInfo.systemUptime - start
        var results: [Result] = []
        for item in cases {
            try Task.checkCancellation()
            let text = try await worker.polish(item.text)
            let compact = text.filter { !$0.isWhitespace }
            let missing = item.preserve.filter { !compact.contains($0.filter { !$0.isWhitespace }) }
            results.append(Result(id: item.id, text: text, metrics: worker.lastMetrics, missingMarkers: missing))
        }
        let report = Report(model: modelID, requestedMode: mode, startupMode: worker.computeMode,
                            startupSeconds: startup, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}
