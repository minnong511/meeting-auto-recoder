import Foundation

@main
enum PolisherLifecycleChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let server = root.appendingPathComponent("fake-server.py").path
        let model = LocalTranscriptPolisher.installedModels().first!
        func configure(_ scenario: String) throws {
            try scenario.write(to: root.appendingPathComponent("scenario.txt"), atomically: true, encoding: .utf8)
            try Data().write(to: root.appendingPathComponent("attempts.jsonl"))
        }
        func attempts() throws -> [[String: Any]] {
            let text = try String(contentsOf: root.appendingPathComponent("attempts.jsonl"), encoding: .utf8)
            return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        func require(_ ok: Bool, _ message: String) throws {
            if !ok { throw NSError(domain: message, code: 1) }
        }

        try configure("fallback")
        let fallback = LocalTranscriptPolisher(model: model, serverExecutable: server)
        try await fallback.start()
        try require(fallback.computeMode == .cpu, "failed acceleration must retry CPU")
        let text = try await fallback.polish("숫자 240, 담당자 미정")
        try require(text == "숫자 240, 담당자 미정", "worker must return response unchanged")
        try require(fallback.lastMetrics?.completionTokens == 7, "worker must report usage")
        let launches = try attempts()
        try require(launches.map { $0["mode"] as! String } == ["auto", "0"], "exactly one CPU retry")
        try require(launches.last?["priorAlive"] as? Bool == false, "first process must exit before retry")
        fallback.stop()
        do { _ = try await fallback.polish("stopped"); throw NSError(domain: "stopped worker accepted input", code: 1) }
        catch PolishError.startup { }
        print("PASS accelerated startup failure, CPU retry, prior-process cleanup, response, metrics, stop")

        try configure("both-fail")
        let failed = LocalTranscriptPolisher(model: model, serverExecutable: server)
        do { try await failed.start(); throw NSError(domain: "startup should fail", code: 1) }
        catch PolishError.startup { }
        try require(try attempts().count == 2, "do not retry indefinitely")
        failed.stop()
        print("PASS both backends fail with bounded retries")

        try configure("cancel")
        let cancelled = LocalTranscriptPolisher(model: model, serverExecutable: server)
        let task = Task { try await cancelled.start() }
        // Wait until the process exists so the test exercises cancellation during startup.
        for _ in 0..<100 {
            if !(try attempts()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { try await task.value; throw NSError(domain: "cancellation ignored", code: 1) }
        catch is CancellationError { }
        try require(try attempts().count == 1, "cancellation must not launch CPU fallback")
        cancelled.stop()
        print("PASS startup cancellation without CPU retry")

        try configure("truncated")
        let truncated = LocalTranscriptPolisher(model: model, serverExecutable: server)
        try await truncated.start(mode: .cpu)
        do { _ = try await truncated.polish("원문"); throw NSError(domain: "truncated output accepted", code: 1) }
        catch PolishError.outputTruncated { }
        try require(truncated.lastMetrics == nil, "failed response must not report a successful measurement")
        truncated.stop()
        print("PASS truncated output rejected")
    }
}
