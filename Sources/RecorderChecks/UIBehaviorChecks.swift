import Foundation
import RecorderCore

extension RecorderChecks {
    func playbackParagraphs() throws {
        var meeting = Meeting(title: "문단 재생")
        let a = TranscriptSegment(source: .system, start: 2, end: 5, text: "첫 번째 발언입니다.")
        let b = TranscriptSegment(source: .system, start: 6, end: 10, text: "이어서 설명합니다.")
        let c = TranscriptSegment(source: .microphone, start: 11, end: 12, text: "네")
        let d = TranscriptSegment(source: .system, start: 13, end: 17, text: "다시 설명합니다.")
        let e = TranscriptSegment(source: .system, start: 45, end: 50, text: "시간이 지난 뒤 발언입니다.")
        meeting.segments = [e, c, d, b, a]
        let original = meeting.segments
        let markdown = TranscriptMarkdown.render(meeting)
        let paragraphs = TranscriptDocument.playbackParagraphs(meeting)
        try expect(paragraphs.count == 4, "화자 교대 또는 긴 공백을 한 재생 구간에 합침")
        try expect(paragraphs[0].id == a.id && paragraphs[0].start == 2 && paragraphs[0].end == 10, "문단이 원본의 실제 재생 시각을 보존하지 않음")
        try expect(paragraphs[0].text == a.text + " " + b.text, "문단의 원문이 변경됨")
        try expect(paragraphs[1].source == .microphone && paragraphs[1].text == "네", "짧은 교대 발언이 누락됨")
        try expect(paragraphs.map(\.start) == [2, 11, 13, 45], "문단이 시간순으로 정렬되지 않음")
        try expect(meeting.segments == original && TranscriptMarkdown.render(meeting) == markdown, "UI용 문단 생성이 저장된 원문을 변경함")
        var another = d; another.speakerID = "participant-1"
        meeting.segments = [b, another]
        try expect(TranscriptDocument.playbackParagraphs(meeting).count == 2, "다른 화자의 문단을 합침")
    }

    func connectionPresentation() throws {
        let clients = [
            MCPClientConnection(id: "c", name: "codex-mcp-client", version: "2"),
            MCPClientConnection(id: "a", name: "Codex", version: "1"),
            MCPClientConnection(id: "b", name: " CODEX-MCP-CLIENT ", version: "1"),
            MCPClientConnection(id: "d", name: "Other App")
        ]
        let groups = MCPClientPresentation.groups(clients)
        try expect(groups.count == 2 && groups[0].name == "Codex", "동일 앱의 이름 변형이 여러 줄로 표시됨")
        try expect(groups[0].sessions.count == 3 && groups[0].versions == ["1", "2"], "묶음에서 연결 세션 또는 버전이 누락됨")
        try expect(groups.flatMap(\.sessions).count == clients.count, "연결 목록에서 원본 세션이 손실됨")
        try expect(groups[1].name == "Other App", "다른 앱을 Codex로 잘못 표시함")
        try expect(MCPClientPresentation.groups([]).isEmpty, "연결이 없는데 앱을 표시함")
    }
}
