import Foundation

/// Only the ticket and a proposed summary live in the private temporary directory.
package struct MeetingSummaryJob: Codable, Sendable {
    let root: URL
    let folder: URL
    let id: UUID
    let transcriptHash: String
    let summaryHash: String

    package init(root: URL, meeting: StoredMeeting) throws {
        let store = MCPStore(root: root)
        let pinned = try store.pinnedMeeting(directory: meeting.directory, id: meeting.id)
        let record = try store.transcript(pinned)
        guard let hash = record["transcript_sha256"] as? String, let previous = record["summary_sha256"] as? String,
              let text = record["transcript"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MCPError.message("읽을 대화록이 없습니다.") }
        self.root = root; folder = pinned.directory; id = pinned.id; transcriptHash = hash; summaryHash = previous
    }

    package func publishTicket(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("request.json"), options: .atomic)
    }

    package func commit(from directory: URL) throws {
        let proposal = directory.appendingPathComponent("proposal.md")
        guard let text = try? String(contentsOf: proposal, encoding: .utf8), !text.isEmpty else {
            throw MCPError.message("에이전트가 전체 대화록을 읽고 요약을 제출하지 못했습니다. 다시 시도해 주세요.")
        }
        let store = MCPStore(root: root)
        let meeting = try store.pinnedMeeting(directory: folder, id: id)
        _ = try store.saveSummary(["meeting_id": id.uuidString, "markdown": text,
            "transcript_sha256": transcriptHash, "expected_summary_sha256": summaryHash], pinned: meeting, beforeWrite: { try Task.checkCancellation() })
    }
}

/// The automated agent sees two tools for a single immutable transcript. It
/// cannot select another meeting or alter the real summary while it is running.
package final class ScopedSummarySession {
    private let directory: URL
    private let title: String
    private let pages: MeetingSummaryPages
    private var readParts = Set<Int>()

    package init(directory: URL) throws {
        let job = try JSONDecoder().decode(MeetingSummaryJob.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
        let store = MCPStore(root: job.root)
        let record = try store.transcript(store.pinnedMeeting(directory: job.folder, id: job.id))
        guard record["transcript_sha256"] as? String == job.transcriptHash, record["summary_sha256"] as? String == job.summaryHash,
              let transcript = record["transcript"] as? String, let title = record["title"] as? String else {
            throw MCPError.message("요약을 시작한 뒤 회의 내용이 변경됐습니다. 다시 시도해 주세요.")
        }
        self.directory = directory; self.title = title; pages = MeetingSummaryPages(transcript)
    }

    package static let tools: [[String: Any]] = [
        ["name": "get_transcript", "description": "선택된 회의의 대화록 한 부분을 읽습니다. part는 1부터 시작합니다.",
         "inputSchema": ["type": "object", "properties": ["part": ["type": "integer", "minimum": 1]], "required": ["part"], "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]],
        ["name": "save_summary", "description": "전체 대화록을 읽고 완성한 한국어 회의록을 앱에 제출합니다.",
         "inputSchema": ["type": "object", "properties": ["markdown": ["type": "string"]], "required": ["markdown"], "additionalProperties": false],
         "annotations": ["destructiveHint": false, "openWorldHint": false]]
    ]

    package func call(_ name: String?, arguments: [String: Any]) throws -> [String: Any] {
        switch name {
        case "get_transcript":
            guard arguments.count == 1, let part = arguments["part"] as? Int else { throw MCPError.message("part 번호가 필요합니다.") }
            var result = try pages.response(part: part)
            result["title"] = title
            readParts.insert(part)
            return result
        case "save_summary":
            guard readParts.count == pages.parts.count else { throw MCPError.message("모든 부분을 먼저 읽어 주세요.") }
            guard arguments.count == 1, let text = arguments["markdown"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2_000_000 else {
                throw MCPError.message("완성된 Markdown 본문이 필요합니다.")
            }
            try Data(text.utf8).write(to: directory.appendingPathComponent("proposal.md"), options: .atomic)
            return ["submitted": true]
        default: throw MCPError.message("이 회의의 대화록 읽기와 요약 제출만 지원합니다.")
        }
    }
}
