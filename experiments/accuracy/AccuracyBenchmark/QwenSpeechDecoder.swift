import Darwin
import Foundation
import RecorderAudio

private struct QwenRuntime {
    let python: String
    let model: String
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static var installed: Self? {
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        let python = root.appendingPathComponent(".runtime/asr/bin/python").path
        let model = root.appendingPathComponent(".runtime/models/qwen17").path
        let revision = "78a389c776a5483b2d0d4ea5494e11012e0d6159"
        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.isReadableFile(atPath: model + "/model.safetensors"),
              (try? String(contentsOfFile: model + "/.ready-revision", encoding: .utf8)) == revision else { return nil }
        return Self(python: python, model: model)
    }
}

private struct QwenReply: Decodable, Sendable {
    let ready: Bool?
    let `protocol`: Int?
    let id: String?
    let text: String?
    let error: String?
}

/// The benchmark sends one request at a time; only the pipe reader runs concurrently.
final class QwenSpeechDecoder: @unchecked Sendable {
    private var process: Process?
    private var input: FileHandle?
    private var replies: QwenReplyReader?

    func start() async throws {
        guard let runtime = QwenRuntime.installed else {
            throw RecorderError.message("Qwen 음성인식 준비가 필요합니다. experiments/asr/setup-local-asr.sh qwen17을 실행해 주세요.")
        }
        let worker = QwenRuntime.folder.appendingPathComponent("qwen-asr-worker.py")
        guard FileManager.default.isReadableFile(atPath: worker.path) else {
            throw RecorderError.message("평가용 음성인식 실행 파일을 찾지 못했습니다.")
        }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: runtime.python)
        server.arguments = ["-I", "-u", worker.path, runtime.model]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        server.environment = environment
        let incoming = Pipe(), outgoing = Pipe()
        server.standardInput = incoming
        server.standardOutput = outgoing
        server.standardError = FileHandle.nullDevice
        let reader = QwenReplyReader(handle: outgoing.fileHandleForReading)
        let writer = incoming.fileHandleForWriting
        let descriptor = writer.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            reader.finish()
            throw RecorderError.message("로컬 전사 입력을 열지 못했습니다.")
        }
        do { try server.run() } catch { reader.finish(); throw error }
        process = server; input = writer; replies = reader
        do {
            let ready = try await reader.next(timeout: 90)
            guard ready.ready == true, ready.protocol == 1 else {
                throw RecorderError.message("Qwen 음성 모델을 준비하지 못했습니다: \(ready.error ?? "응답 확인 실패")")
            }
            try Task.checkCancellation()
        } catch { await stop(); throw error }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard let process, process.isRunning, let input, let replies else {
            throw RecorderError.message("로컬 음성인식 프로세스가 종료되었습니다. 원본 음성은 보존됩니다.")
        }
        let identifier = UUID().uuidString
        let audio = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let data = try JSONSerialization.data(withJSONObject: ["id": identifier, "audio": audio.base64EncodedString()])
        do {
            // A crashed or stalled child must not block capture cancellation or raise SIGPIPE.
            try await Self.write(data + Data([10]), to: input.fileDescriptor)
            let reply = try await replies.next(timeout: 60)
            try Task.checkCancellation()
            guard reply.id == identifier, reply.error == nil, let text = reply.text else {
                throw RecorderError.message("Qwen 음성인식 응답을 확인하지 못했습니다: \(reply.error ?? "요청 불일치")")
            }
            return text
        } catch { await stop(); throw error }
    }

    private static func write(_ data: Data, to fd: Int32) async throws {
        var offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while offset < data.count {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw RecorderError.message("음성인식 프로세스가 입력을 받지 않습니다.")
            }
            let count = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), ptr.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count == -1 && errno == EINTR { continue }
            if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            throw RecorderError.message("음성인식 프로세스의 입력 연결이 종료되었습니다.")
        }
    }

    func stop() async {
        let server = process
        process = nil
        try? input?.close(); input = nil
        replies?.finish(); replies = nil
        guard let server else { return }
        if server.isRunning { server.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while server.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            // A detached wait remains cancellable independently of a cancelled capture task.
            await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
        }
        if server.isRunning {
            kill(server.processIdentifier, SIGKILL)
            await Task.detached { server.waitUntilExit() }.value
        }
    }
}

private final class QwenReplyReader: @unchecked Sendable {
    let stream: AsyncThrowingStream<QwenReply, Error>
    private let continuation: AsyncThrowingStream<QwenReply, Error>.Continuation
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()

    init(handle: FileHandle) {
        let pair = AsyncThrowingStream<QwenReply, Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        stream = pair.stream; continuation = pair.continuation; self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { self.finish(); return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.buffer.append(data)
            guard self.buffer.count <= 262_144 else {
                self.continuation.finish(throwing: RecorderError.message("음성인식 응답 크기가 비정상적입니다.")); return
            }
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.subdata(in: 0..<newline)
                self.buffer.removeSubrange(0...newline)
                do {
                    let reply = try JSONDecoder().decode(QwenReply.self, from: line)
                    if case .dropped = self.continuation.yield(reply) {
                        self.continuation.finish(throwing: RecorderError.message("음성인식 응답 순서를 확인하지 못했습니다."))
                    }
                } catch { self.continuation.finish(throwing: error) }
            }
        }
    }

    func next(timeout: Double) async throws -> QwenReply {
        let stream = self.stream
        return try await withThrowingTaskGroup(of: QwenReply.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let value = try await iterator.next() else {
                    try Task.checkCancellation()
                    throw RecorderError.message("음성인식 프로세스의 연결이 종료되었습니다.")
                }
                return value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw RecorderError.message("음성인식 응답 대기 시간이 초과되었습니다.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func finish() {
        handle.readabilityHandler = nil
        continuation.finish()
    }
}
