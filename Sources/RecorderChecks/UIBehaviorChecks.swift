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

extension RecorderChecks {
    func meetingCopyActions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-copy-check-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var meeting = Meeting(title: "복사 검사")
        meeting.segments = [
            TranscriptSegment(source: .microphone, start: 0, end: 2, text: "내 원문"),
            TranscriptSegment(source: .system, start: 5, end: 8, text: "상대 원문")
        ]
        var stored = StoredMeeting(meeting: meeting, directory: dir)
        let generated = try MeetingCopy.transcript(stored)
        try expect(generated == TranscriptMarkdown.render(meeting), "누락된 파일의 확정 대화록 복구 실패")
        let edited = "# 직접 편집한 문서\n\n사용자가 정정한 금액 6,000원.\n"
        try edited.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let copied = try MeetingCopy.transcript(stored)
        try expect(copied == edited, "대화록 복사에서 직접 편집한 Markdown이 유실됨")
        let paragraphs = TranscriptDocument.playbackParagraphs(meeting)
        var polished = PolishedTranscript()
        try expect(MeetingCopy.polished(stored, document: polished) == nil, "정리 결과가 없는데 정리본이 생성됨")
        let first = paragraphs[0], second = paragraphs[1]
        polished.entries[first.id.uuidString] = PolishedEntry(sourceHash: PolishedTranscript.sourceHash(first), text: "정리한 첫 문단")
        polished.entries[second.id.uuidString] = PolishedEntry(sourceHash: "stale", text: "폐기된 수정본")
        let mixed = MeetingCopy.polished(stored, document: polished) ?? ""
        try expect(mixed.contains("정리한 첫 문단") && mixed.contains("00:00:05") && mixed.contains("· 원문\n상대 원문") && !mixed.contains("폐기된 수정본"), "부분 정리본을 복사할 때 원문·타임스탬프·최신 해시 구분 오류")
        stored.meeting.audioFile = "복원 녹음.m4a"
        try expect(stored.audioURL == dir.appendingPathComponent("복원 녹음.m4a"), "메타데이터의 실제 파일 이름을 무시함")
        stored.meeting.audioFile = "../outside.m4a"
        try expect(stored.audioURL == nil, "회의 폴더 밖의 녹음 경로를 허용함")
    }

    @MainActor func releaseAlerts() async throws {
        let hash = String(repeating: "a", count: 64)
        let feed = """
        \(hash)  Meeting-Recorder-0.9.9-macOS-arm64.zip
        \(hash)  Meeting-Recorder-0.10.0-macOS-arm64.zip
        \(hash)  Meeting-Recorder-4.0.0-beta-macOS-arm64.zip
        \(hash)  Meeting-Recorder-8.0.0-macOS-x86_64.zip
        invalid  Meeting-Recorder-9.0.0-macOS-arm64.zip
        """
        let release = RecorderRelease("0.10.0")!, newer = RecorderRelease("1.0.0")!
        try expect(RecorderRelease.published(at: release.releasePage) == release && release > RecorderRelease("0.9.9")! &&
                   RecorderRelease.published(at: URL(string: "https://github.com/minnong511/meeting-auto-recoder/releases/tag/v0.11.0-beta")!) == nil &&
                   RecorderRelease.published(at: URL(string: "https://github.com/other/repo/releases/tag/v0.11.0")!) == nil,
                   "GitHub 정식 태그 또는 버전 비교가 올바르지 않음")
        let domain = "RecorderUpdatesTest.\(UUID())"
        let prefs = UserDefaults(suiteName: domain)!
        defer { prefs.removePersistentDomain(forName: domain) }
        var time = Date(timeIntervalSince1970: 100_000), next = release
        try expect(release.checksum(in: feed) == hash.lowercased() && release.checksum(in: feed + "\n" + feed) == nil,
                   "버전 해시 불일치 또는 중복 배포 항목 허용")
        try expect(release.downloadURL.absoluteString == "https://github.com/minnong511/meeting-auto-recoder/releases/download/v0.10.0/Meeting-Recorder-0.10.0-macOS-arm64.zip",
                   "다운로드가 선택한 정식 버전에 고정되지 않음")
        var requests = 0, alerts: [RecorderRelease] = []
        var offline = false
        let monitor = RecorderUpdates(installedVersion: "0.9.9", defaults: prefs, now: { time }, fetch: {
            requests += 1
            if offline { throw URLError(.notConnectedToInternet) }
            return next
        })
        monitor.onNewRelease = { alerts.append($0) }
        await monitor.check()
        await monitor.check()
        try expect(monitor.banner == release && alerts == [release] && requests == 1, "중복 네트워크 확인 또는 새 버전 알림 오류")
        await monitor.check(manual: true)
        try expect(requests == 2 && alerts.count == 1, "수동 확인이 같은 버전을 재알림")
        monitor.dismiss(release)
        let reopened = RecorderUpdates(installedVersion: "0.9.9", defaults: prefs)
        try expect(reopened.available == release && reopened.banner == nil, "다시 실행하면 닫은 배너가 되살아남")
        time = time.addingTimeInterval(24 * 3600)
        next = newer
        await monitor.check()
        try expect(monitor.banner == newer && alerts == [release, newer], "다음 배포 버전을 알리지 않음")
        monitor.setEnabled(false)
        time = time.addingTimeInterval(24 * 3600)
        await monitor.check()
        try expect(requests == 3 && monitor.banner == nil, "자동 확인을 껐는데 네트워크 요청 또는 배너 표시")
        offline = true
        await monitor.check(manual: true)
        try expect(requests == 4 && monitor.failed && !monitor.isChecking && monitor.available == newer, "오프라인을 최신으로 잘못 표시함")
        offline = false
        next = RecorderRelease("0.8.0")!
        await monitor.check(manual: true)
        try expect(monitor.available == nil && !monitor.failed && alerts.count == 2, "낮은 버전을 업데이트로 표시함")
        next = RecorderRelease("0.9.9")!
        monitor.setEnabled(true)
        await monitor.check(manual: true)
        try expect(monitor.available == nil && alerts.count == 2, "동일 버전이나 빌드만 바뀌었을 때 잘못 알림")
    }
}
