import Darwin
import Foundation

package enum SummaryAgent: String, CaseIterable, Identifiable, Sendable {
    case codex, claude
    package var id: Self { self }
    package var name: String { self == .codex ? "Codex" : "Claude Code" }

    package static func connected(_ clients: [MCPClientConnection]) -> Set<Self> {
        Set(clients.compactMap { client in
            switch client.name.lowercased() {
            case "codex", "codex-mcp-client": return .codex
            case "claude-code", "claude code", "claude-cli", "claude-code-cli", "claude-ai/claude-code": return .claude
            default: return nil
            }
        })
    }

    package func executable(custom: String? = nil) -> URL? {
        let fm = FileManager.default
        if let custom { return fm.isExecutableFile(atPath: custom) ? URL(fileURLWithPath: custom) : nil }
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.volta/bin",
                 home + "/.bun/bin", home + "/.npm-global/bin", home + "/.local/share/mise/shims", home + "/.asdf/shims"]
        var paths = dirs.filter { $0.hasPrefix("/") }.map { $0 + "/" + rawValue }
        if self == .codex {
            for folder in ["/Applications", home + "/Applications"] {
                paths += [folder + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          folder + "/Codex.app/Contents/Resources/codex"]
            }
        } else { paths.append(home + "/.claude/local/claude") }
        return paths.first(where: fm.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    package func arguments(server: URL, directory: URL, model: SummaryModel? = nil) throws -> [String] {
        func json(_ object: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        let args = ["--summary-job", directory.path]
        let modelArguments = model.map { ["--model", $0.id] } ?? []
        switch self {
        case .codex:
            let key = "mcp_servers.meeting_summary."
            return ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "--sandbox", "read-only",
                    "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                    "--disable", "shell_tool", "--disable", "apps", "--disable", "plugins",
                    "--disable", "hooks", "--disable", "memories", "--disable", "multi_agent",
                    "-c", key + "command=" + (try json(server.path)), "-c", key + "args=" + (try json(args)),
                    "-c", key + "required=true", "-c", key + "default_tools_approval_mode=\"approve\""]
                + modelArguments + ["-"]
        case .claude:
            let config = try json(["mcpServers": ["meeting_summary": ["command": server.path, "args": args]]])
            return ["--print", "--no-session-persistence", "--strict-mcp-config", "--mcp-config", config,
                    "--setting-sources", "", "--tools", "", "--permission-mode", "dontAsk", "--disable-slash-commands",
                    "--allowedTools", "mcp__meeting_summary__get_transcript,mcp__meeting_summary__save_summary"]
                + modelArguments + ["--"]
        }
    }
}

package enum SummaryAgentRunner {
    package static func generate(agent: SummaryAgent, executable: URL, server: URL, root: URL, meeting: StoredMeeting,
                                 prompt: MeetingSummaryPrompt = .saved(), model: SummaryModel? = nil,
                                 timeout: Duration = .seconds(600)) async throws {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: server.path) else { throw MCPError.message("앱에 포함된 MCP 서버를 찾을 수 없습니다.") }
        let job = try MeetingSummaryJob(root: root, meeting: meeting, prompt: prompt)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("meeting-summary-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        // Work in an empty folder, so the host never loads a recording's project configuration.
        let cwd = dir.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: false)
        try job.publishTicket(in: dir)
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw MCPError.message("요약 작업을 준비하지 못했습니다.") }
        var recent = Data()
        // Host diagnostics can echo the transcript. Keep only a bounded tail in memory.
        func drain() {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                recent.append(contentsOf: buffer.prefix(count))
                if recent.count > 8_192 { recent.removeFirst(recent.count - 8_192) }
            }
        }
        let p = Process()
        p.executableURL = executable
        p.currentDirectoryURL = cwd
        p.arguments = try agent.arguments(server: server, directory: dir, model: model)
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = [executable.deletingLastPathComponent().path, path, "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        p.environment = env
        // Supply the user's complete text on stdin for both agents, including
        // multiline text or text beginning with "-" without interpreting it as CLI flags.
        let inputURL = dir.appendingPathComponent("instructions.txt")
        try Data(job.prompt.automatic.utf8).write(to: inputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        p.standardInput = input
        p.standardOutput = pipe
        p.standardError = pipe
        try Task.checkCancellation()
        do { try p.run() } catch { throw MCPError.message("\(agent.name)를 실행하지 못했습니다. 연결 설정에서 실행 파일을 확인해 주세요.") }
        try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while p.isRunning {
                drain()
                try Task.checkCancellation()
                if ContinuousClock.now >= deadline { throw MCPError.message("\(agent.name)의 응답 시간이 초과됐습니다. 다시 시도해 주세요.") }
                try await Task.sleep(for: .milliseconds(200))
            }
            try Task.checkCancellation()
            drain()
            guard p.terminationStatus == 0 else { throw failure(agent, model: model, recent: recent) }
            // Cancellation or a failed run can only discard a staged proposal.
            // commit rechecks both hashes under the same lock as manual MCP writes.
            try job.commit(from: dir)
        } catch {
            if p.isRunning {
                p.terminate()
                await Task.detached(priority: .utility) {
                    // waitUntilExit can hang on a worker run loop after the child has already exited.
                    for attempt in 0..<40 {
                        guard p.isRunning else { return }
                        if attempt == 20 { kill(p.processIdentifier, SIGKILL) }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }.value
            }
            throw error
        }
    }

    private static func failure(_ agent: SummaryAgent, model: SummaryModel?, recent: Data) -> MCPError {
        let text = String(decoding: recent, as: UTF8.self).lowercased()
        if ["not logged in", "login", "sign in", "unauthorized", "authentication", "401"].contains(where: text.contains) {
            return .message("\(agent.name)에 로그인한 뒤 다시 시도해 주세요.")
        }
        if ["rate limit", "usage limit", "quota", "429"].contains(where: text.contains) {
            return .message("\(agent.name)의 사용 한도에 도달했습니다. 한도가 갱신된 뒤 다시 시도해 주세요.")
        }
        if let model, ["model_not_found", "unknown model", "unsupported model", "invalid model", "model is not available",
                       "issue with the selected model", "does not exist or you do not have access",
                       "not supported when using codex", "do not have access to the model", "model is not allowed",
                       "not allowed to use this model"].contains(where: text.contains) {
            return .message("\(agent.name)에서 \(model.id) 모델을 사용할 수 없습니다. 요약 모델을 다시 선택해 주세요.")
        }
        if ["unknown option", "unexpected argument", "unrecognized", "unknown feature"].contains(where: text.contains) {
            return .message("\(agent.name) 실행기를 업데이트한 뒤 다시 시도해 주세요.")
        }
        return .message("\(agent.name)가 요약을 완료하지 못했습니다. 로그인과 네트워크 연결을 확인한 뒤 다시 시도해 주세요.")
    }
}
