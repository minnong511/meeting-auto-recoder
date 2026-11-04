import Foundation
import RecorderCore

extension RecorderChecks {
    func summaryPages() throws {
        let text = "\n처음 항목\n" + String(repeating: "가🙂abc ", count: 480) + "\n\n끝 13곳\n"
        let pages = MeetingSummaryPages(text, byteLimit: 150)
        try expect(pages.parts.count > 2 && pages.parts.joined() == text, "대화록 일부 또는 줄바꿈 누락")
        try expect(pages.parts.allSatisfy { $0.utf8.count <= 150 }, "페이지 크기 제한 실패")
        let first = try pages.response(part: 1), last = try pages.response(part: pages.parts.count)
        try expect(first["next_part"] as? Int == 2 && last["next_part"] is NSNull, "다음 부분 표시 오류")
        do { _ = try pages.response(part: 0); throw CheckError.failed("범위 밖 페이지 허용") } catch is MCPError {}
        let ids = [MCPClientConnection(id: "1", name: "codex-mcp-client"), .init(id: "2", name: "Claude Code")]
        try expect(SummaryAgent.connected(ids) == [.codex, .claude], "연결된 에이전트 식별 실패")
    }

    func summaryScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("summary-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = MeetingStore(root: root)
        var stored = try lib.create(title: "예시")
        stored.meeting.status = .completed
        try lib.save(stored)
        let transcript = stored.directory.appendingPathComponent("transcript.md")
        let summary = stored.directory.appendingPathComponent("summary.md")
        try String(repeating: "첫 안건입니다.\n", count: 500).write(to: transcript, atomically: true, encoding: .utf8)
        try "기존 요약".write(to: summary, atomically: true, encoding: .utf8)
        let workspace = root.appendingPathComponent("job", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let job = try MeetingSummaryJob(root: root, meeting: stored)
        try job.publishTicket(in: workspace)
        let session = try ScopedSummarySession(directory: workspace)
        let first = try session.call("get_transcript", arguments: ["part": 1])
        guard let total = first["total_parts"] as? Int, total > 1 else { throw CheckError.failed("여러 부분으로 나뉘지 않음") }
        try expect(first["paths"] == nil, "회의 경로 노출")
        do { _ = try session.call("list_meetings", arguments: [:]); throw CheckError.failed("다른 회의 조회 허용") } catch is MCPError {}
        do { _ = try session.call("get_transcript", arguments: ["part": 1, "meeting_id": UUID().uuidString]); throw CheckError.failed("다른 회의 지정 허용") } catch is MCPError {}
        do { _ = try session.call("save_summary", arguments: ["markdown": "너무 이름"]); throw CheckError.failed("마지막 부분 누락을 수용함") } catch is MCPError {}
        for i in 2...total { _ = try session.call("get_transcript", arguments: ["part": i]) }
        _ = try session.call("save_summary", arguments: ["markdown": "새 요약"])
        let original = try String(contentsOf: summary, encoding: .utf8)
        try expect(original == "기존 요약", "에이전트가 원본에 직접 저장함")
        try job.commit(from: workspace)
        let committed = try String(contentsOf: summary, encoding: .utf8)
        try expect(committed == "새 요약\n", "앱이 요약을 저장하지 못함")
        let history = try FileManager.default.contentsOfDirectory(at: stored.directory.appendingPathComponent(".summary-history"), includingPropertiesForKeys: nil)
        try expect(history.count == 1, "이전 요약 누락")
        try "직접 수정".write(to: summary, atomically: true, encoding: .utf8)
        do { try job.commit(from: workspace); throw CheckError.failed("직접 수정한 요약 덮어씀") } catch is MCPError {}
        let fresh = try MeetingSummaryJob(root: root, meeting: stored)
        try "바뀐 원문".write(to: transcript, atomically: true, encoding: .utf8)
        do { try fresh.commit(from: workspace); throw CheckError.failed("바뀐 원문에 예전 요약 저장") } catch is MCPError {}
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: summary)
        do { _ = try MeetingSummaryJob(root: root, meeting: stored); throw CheckError.failed("대체 링크를 원본으로 취급함") } catch is MCPError {}
    }

    func summaryCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("summary-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = MeetingStore(root: root)
        var meeting = try lib.create(title: "취소 테스트")
        meeting.meeting.status = .completed; try lib.save(meeting)
        try "회의 발언".write(to: meeting.directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let fake = root.appendingPathComponent("paused-host")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let target = meeting
        let task = Task { try await SummaryAgentRunner.generate(agent: .codex, executable: fake, server: fake, root: root, meeting: target) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { try await task.value; throw CheckError.failed("취소한 작업이 성공함") } catch is CancellationError {}
        do {
            try await SummaryAgentRunner.generate(agent: .claude, executable: fake, server: fake, root: root, meeting: target, timeout: .milliseconds(200))
            throw CheckError.failed("시간 초과 작업이 성공함")
        } catch let error as MCPError { try expect(error.localizedDescription.contains("시간"), "시간 초과 안내 누락") }
        try expect(!FileManager.default.fileExists(atPath: target.directory.appendingPathComponent("summary.md").path), "취소된 요약이 저장됨")
    }
}
