import AVFoundation
import Darwin
import Foundation
import RecorderAudio
import RecorderCore
import struct WhisperKit.TranscriptionSegment
import struct WhisperKit.WordTiming

// Command Line Tools do not ship XCTest; these checks need no model downloads.
enum CheckError: Error { case failed(String) }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError.failed(message) }
}

@main
enum Checks {
    static func main() async {
        let suite = RecorderChecks()
        if let index = CommandLine.arguments.firstIndex(of: "--speaker-fixture"), CommandLine.arguments.count > index + 3 {
            do {
                try await suite.speakerRecording(audio: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                                 result: URL(fileURLWithPath: CommandLine.arguments[index + 2]),
                                                 root: URL(fileURLWithPath: CommandLine.arguments[index + 3]))
            } catch { print("FAIL speaker recording: \(error)"); exit(1) }
            return
        }
        let deletionChecks: [(String, () async throws -> Void)] = [
            ("회의 휴지통 이동·관련 파일 보존·다른 기록 유지", { try suite.meetingTrashContents() }),
            ("진행 중인 회의 삭제 거부·현재 상태 재검증", { try suite.activeMeetingDeletionRefused() }),
            ("삭제 경로 범위·심볼릭 링크·회의 ID 검증", { try suite.meetingDeletionScope() }),
            ("휴지통 이동 실패·요약 저장 중 기록 보존", { try suite.meetingDeletionFailure() })
        ]
        let checks: [(String, () async throws -> Void)] = CommandLine.arguments.contains("--deletion-only") ? deletionChecks : deletionChecks + [
            ("고유 폴더와 안전한 제목", { try suite.uniqueFolders() }),
            ("오디오 경로 이탈 거부", { try suite.safeChunkPaths() }),
            ("전사 정렬·확정 결과 중복 제거", { try suite.finalSegments() }),
            ("중간 결과의 교정은 중복 없이 교체", { try suite.partialReplacement() }),
            ("이전 문장 확정 시 뒤쪽 스트리밍 문장 보존", { try suite.partialFinalization() }),
            ("두 입력의 중간 결과 독립 처리", { try suite.independentPartials() }),
            ("Whisper 무음 메모리 제한·발화 확정·입력 공백 보존", { try suite.whisperWindows() }),
            ("Whisper 긴 발언의 경계 문맥과 단어 중복 방지", { try suite.whisperOverlap() }),
            ("Whisper 단어 시간·불확실 전사 보존·무음 출력 제외", { try suite.whisperMapping() }),
            ("Whisper 마이크 확정·빈 입력 종료·취소", { try await suite.whisperLifecycle() }),
            ("최종 전사 창·화자 경계·짧은 대답 보존", { try suite.finalTranscriptBoundaries() }),
            ("최종 전사 워커 왕복·마이크 무음·실패 보존·취소", { try await suite.finalTranscriptWorker() }),
            ("UTF-8 Markdown·메타데이터 왕복", { try suite.roundTrip() }),
            ("무음·기호 필터와 실제 짧은 발언 보존", { try suite.transcriptCleanup() }),
            ("시간·상태 로그 없는 화자별 대화록", { try suite.speakerDocument() }),
            ("기존 기록 이전과 음성·요약 보존", { try suite.legacyMigration() }),
            ("사용자가 편집한 Markdown 보존", { try suite.editedMarkdownPreserved() }),
            ("한 문장 안의 세 화자와 내 발언 분리", { try suite.threeSpeakers() }),
            ("겹친 목소리·시간 정보 없는 문장 보존", { try suite.uncertainSpeakers() }),
            ("화자 구분 실패 시 원본 조각과 시간 정보 보존", { try suite.speakerRetryRecovery() }),
            ("회의 앱 번들 인식과 보조 프로세스 범위", { try suite.meetingAppCatalog() }),
            ("선택 앱만 포함하고 다른 소리는 제외", { try suite.selectedAppScope() }),
            ("대상 앱 종료·재실행 시 전체 소리로 확대 금지", { try suite.missingAppNoFallback() }),
            ("실행·마이크 감지 전환과 중복 알림 억제", { try suite.meetingDetection() }),
            ("회의 앱 알림 빈도 제한", { try suite.meetingAlertRate() }),
            ("마이크 사용 회의 앱 우선 추천", { try suite.meetingRecommendation() }),
            ("중단된 회의 복구", { try suite.interruptedRecovery() }),
            ("완료된 회의 상태 유지", { try suite.completedPreserved() }),
            ("시간 표시와 비정상 값", { try suite.timestamps() }),
            ("스테레오 입력 리샘플링", { try suite.resampling() }),
            ("양쪽 음성·시간 오프셋·M4A 내보내기", { try await suite.audioExport() }),
            ("마이크를 끈 구간의 무음·회의 소리 유지·마이크 재개", { try await suite.microphoneGap() }),
            ("내보내기 실패 시 복구 파일 보존", { try await suite.failedExport() })
        ]
        var failures = 0
        for (name, body) in checks {
            do { try await body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(1) }
    }
}

final class RecorderChecks {
    func whisperWindows() throws {
        var window = WhisperAudioWindow()
        let quiet = window.append(Array(repeating: 0, count: 16_000 * 60), at: 0)
        try expect(quiet.isEmpty && window.bufferedSampleCount <= 4_800, "무음에서 추론하거나 버퍼가 계속 증가함")
        let speech = window.append(Array(repeating: 0.02, count: 16_000 * 5), at: 60)
        try expect(speech.contains { !$0.isFinal }, "말하는 동안 임시 결과 요청이 없음")
        let ended = window.append(Array(repeating: 0, count: 16_000), at: 65)
        try expect(ended.filter(\.isFinal).count == 1, "무음에서 발화를 한 번 확정하지 못함")
        _ = window.append(Array(repeating: 0.02, count: 8_000), at: 80)
        let afterGap = window.append(Array(repeating: 0.02, count: 8_000), at: 90)
        try expect(afterGap.count == 1 && afterGap[0].start == 80 && abs(afterGap[0].end - 80.5) < 0.001, "마이크 공백을 앞 발화에 붙이거나 시간을 이동함")
        try expect(window.finish()?.start == 90, "재개된 입력의 원래 시간 손실")
    }

    func whisperOverlap() throws {
        var window = WhisperAudioWindow()
        var finals: [WhisperAudioWindow.Request] = []
        for second in 0..<55 {
            let requests = window.append(Array(repeating: 0.02, count: 16_000), at: Double(second))
            try expect(requests.allSatisfy { $0.samples.count <= 24 * 16_000 }, "Whisper 입력 창이 24초를 넘음")
            finals += requests.filter(\.isFinal)
            try expect(window.bufferedSampleCount <= 24 * 16_000, "긴 발언 버퍼 제한 실패")
        }
        try expect(finals.count >= 2 && finals[1].start < finals[0].commitThrough!, "경계 단어 재인식용 문맥이 사라짐")
        var mapper = WhisperTranscriptMapper()
        let first = WhisperAudioWindow.Request(samples: Array(repeating: 0, count: 4 * 16_000), start: 10, commitThrough: 13)
        let a = mapper.map([TranscriptionSegment(words: [WordTiming(word: "환경변수", tokens: [], start: 0, end: 1, probability: 1), WordTiming(word: " 설정", tokens: [], start: 2, end: 2.8, probability: 1), WordTiming(word: " 확인", tokens: [], start: 2.9, end: 3.5, probability: 1)])], request: first, source: .system)
        let next = WhisperAudioWindow.Request(samples: Array(repeating: 0, count: 3 * 16_000), start: 12.5, commitThrough: 15.5)
        let b = mapper.map([TranscriptionSegment(words: [WordTiming(word: " 설정", tokens: [], start: 0, end: 0.3, probability: 1), WordTiming(word: " 확인", tokens: [], start: 0.4, end: 1, probability: 1)])], request: next, source: .system)
        try expect(a.text == "환경변수 설정" && b.text == "확인", "경계 단어가 중복되거나 빠짐")
        try expect(abs(b.words![0].start - 12.9) < 0.001, "원본 단어 시간 오프셋 손실")
    }

    func whisperMapping() throws {
        var mapper = WhisperTranscriptMapper()
        let request = WhisperAudioWindow.Request(samples: Array(repeating: 0, count: 16_000), start: 50, commitThrough: 51)
        let result = mapper.map([TranscriptionSegment(start: 0, end: 0.4, text: "기술명"), TranscriptionSegment(words: [WordTiming(word: " 유지", tokens: [], start: 0.5, end: 0.8, probability: 1)])], request: request, source: .system)
        try expect(result.text == "기술명 유지" && result.words == nil, "단어 시간 없는 부분이나 인접 단어가 삭제됨")
        var quietMapper = WhisperTranscriptMapper()
        let quiet = quietMapper.map([TranscriptionSegment(end: 1, text: "가짜 문장", avgLogprob: -2, noSpeechProb: 0.99)], request: request, source: .system)
        try expect(quiet.text.isEmpty, "모델이 무음으로 판정한 낮은 신뢰도 출력을 저장함")
        var zeroMapper = WhisperTranscriptMapper()
        let zero = zeroMapper.map([TranscriptionSegment(words: [WordTiming(word: "네", tokens: [], start: 0, end: 0, probability: 1)])], request: request, source: .microphone)
        try expect(zero.text == "네", "시작 시각에 길이 0으로 정렬된 실제 짧은 발언이 삭제됨")
        var uncertainMapper = WhisperTranscriptMapper()
        let uncertain = uncertainMapper.map([TranscriptionSegment(end: 1, text: "시간 불명", words: [WordTiming(word: "시간 불명", tokens: [], start: .nan, end: 1, probability: 1)])], request: request, source: .system)
        try expect(uncertain.text == "시간 불명" && uncertain.words == nil, "잘못된 단어 시간이 있는 전사를 삭제함")
    }

    @MainActor func whisperLifecycle() async throws {
        let lane = try await SpeechLane.create(source: .microphone, onResult: { _, _ in }, onError: { _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        buffer.floatChannelData![0].initialize(repeating: 0, count: 4_800)
        try lane.consume(buffer, at: 0)
        try await lane.synchronize()
        try await lane.finalizePending()
        try await lane.finish()
        do { try await lane.synchronize(); throw CheckError.failed("종료된 입력의 확인이 성공함") }
        catch is CheckError { throw CheckError.failed("종료된 입력의 확인이 성공함") }
        catch { }
        let cancelled = try await SpeechLane.create(source: .microphone, onResult: { _, _ in }, onError: { _ in })
        await cancelled.cancel()
    }

    private var temporaryDirectories: [URL] = []
    deinit { temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) } }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func deletableMeeting(in store: MeetingStore, title: String = "삭제 확인") throws -> StoredMeeting {
        var stored = try store.create(title: title)
        stored.meeting.status = .completed
        stored.meeting.endedAt = stored.meeting.startedAt.addingTimeInterval(1)
        try store.save(stored)
        return stored
    }

    func meetingTrashContents() throws {
        let root = try temporaryDirectory()
        let trash = try temporaryDirectory().appendingPathComponent("trashed-meeting")
        let store = MeetingStore(root: root)
        let stored = try deletableMeeting(in: store)
        let other = try deletableMeeting(in: store, title: "보존할 회의")
        let names = ["audio.m4a", "transcript.md", "summary.md", ".summary-history/previous.md", ".audio-parts/recovery.caf"]
        for name in names {
            let file = stored.directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("원본 \(name)".utf8).write(to: file)
        }
        try store.moveToTrash(stored) { directory in
            try expect(directory == stored.directory, "확인한 회의와 다른 폴더를 휴지통으로 이동함")
            try FileManager.default.moveItem(at: directory, to: trash)
        }
        try expect(!FileManager.default.fileExists(atPath: stored.directory.path), "삭제한 회의 폴더가 원래 위치에 남음")
        let remaining = try store.loadAll()
        try expect(remaining.map(\.id) == [other.id], "목록에서 삭제가 반영되지 않거나 다른 회의가 사라짐")
        for name in names {
            let data = try Data(contentsOf: trash.appendingPathComponent(name))
            try expect(data == Data("원본 \(name)".utf8), "휴지통에서 복구할 원본 파일이 변경되거나 누락됨: \(name)")
        }
        try expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent(".meeting.json").path), "복구용 메타데이터가 누락됨")
    }

    func activeMeetingDeletionRefused() throws {
        let store = MeetingStore(root: try temporaryDirectory())
        for status in [MeetingStatus.recording, .finalizing] {
            var stored = try deletableMeeting(in: store)
            let stale = stored
            stored.meeting.status = status
            try store.save(stored)
            var moved = false
            do {
                try store.moveToTrash(stale) { _ in moved = true }
                throw CheckError.failed("진행 중인 회의 삭제를 허용함")
            } catch StoreError.meetingInProgress { }
            try expect(!moved && FileManager.default.fileExists(atPath: stored.directory.path), "진행 중인 원본이 이동됨")
        }
    }

    func meetingDeletionScope() throws {
        let root = try temporaryDirectory()
        let store = MeetingStore(root: root)
        let stored = try deletableMeeting(in: store)
        let outside = try deletableMeeting(in: MeetingStore(root: try temporaryDirectory()))
        let link = root.appendingPathComponent("linked-meeting")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stored.directory)
        let candidates = [outside, StoredMeeting(meeting: stored.meeting, directory: root),
                          StoredMeeting(meeting: stored.meeting, directory: link),
                          StoredMeeting(meeting: outside.meeting, directory: stored.directory)]
        for candidate in candidates {
            var moved = false
            do {
                try store.moveToTrash(candidate) { _ in moved = true }
                throw CheckError.failed("저장 범위를 벗어나거나 ID가 다른 회의 삭제를 허용함")
            } catch is StoreError { }
            try expect(!moved, "잘못된 경로에서 휴지통 이동을 실행함")
        }
        let metadata = stored.directory.appendingPathComponent(".meeting.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside.directory.appendingPathComponent(".meeting.json"))
        do {
            try store.moveToTrash(stored) { _ in throw CheckError.failed("메타데이터 링크가 있는 회의를 이동함") }
            throw CheckError.failed("메타데이터 심볼릭 링크를 허용함")
        } catch StoreError.invalidMeetingDirectory { }
        try expect(FileManager.default.fileExists(atPath: outside.directory.path), "저장 폴더 밖의 원본이 사라짐")
    }

    func meetingDeletionFailure() throws {
        let store = MeetingStore(root: try temporaryDirectory())
        let stored = try deletableMeeting(in: store)
        do {
            try store.moveToTrash(stored) { _ in throw CocoaError(.fileWriteNoPermission) }
            throw CheckError.failed("휴지통 이동 실패를 성공으로 처리함")
        } catch let error as CocoaError { try expect(error.code == .fileWriteNoPermission, "원래 삭제 오류를 잃음") }
        let remaining = try store.loadAll()
        try expect(remaining.map(\.id) == [stored.id], "삭제 실패 후 회의 기록이 사라짐")
        let fd = Darwin.open(stored.directory.appendingPathComponent(".summary.lock").path, O_RDWR)
        guard fd >= 0 else { throw CheckError.failed("테스트 잠금을 열지 못함") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CheckError.failed("테스트 잠금 실패") }
        do {
            try store.moveToTrash(stored) { _ in throw CheckError.failed("요약 저장 중 폴더를 이동함") }
            throw CheckError.failed("사용 중인 요약 잠금을 무시함")
        } catch StoreError.meetingLocked { }
        try expect(FileManager.default.fileExists(atPath: stored.directory.path), "잠금 중 원본을 변경함")
    }

    func uniqueFolders() throws {
        let root = try temporaryDirectory()
        let store = MeetingStore(root: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try store.create(title: "../../회의/제목\n", date: date)
        let second = try store.create(title: "../../회의/제목\n", date: date)
        try expect(first.directory != second.directory, "동일 시각 회의의 폴더가 충돌함")
        try expect(first.directory.deletingLastPathComponent().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path, "상위 폴더로 이탈함")
        try expect(first.directory.lastPathComponent.contains("회의"), "한국어 제목이 보존되지 않음")
    }

    func meetingAppCatalog() throws {
        try expect(MeetingAppKind.identify("us.zoom.xos") == .zoom, "Zoom 인식 실패")
        try expect(MeetingAppKind.identify("com.microsoft.teams2") == .teams && MeetingAppKind.identify("com.microsoft.teams") == .teams, "Teams 신·구 버전 인식 실패")
        try expect(MeetingAppKind.identify("Cisco-Systems.Spark") == .webex, "Webex 인식 실패")
        try expect(MeetingAppKind.identify("com.someone.Zoom") == nil && MeetingAppKind.identify("com.microsoft.teams2.agent") == nil, "이름이 비슷한 앱·보조 프로세스를 회의 앱 본체로 오인")
        try expect(MeetingAppKind.includes("us.zoom.CptHost", for: "us.zoom.xos"), "Zoom 회의 보조 프로세스 누락")
        try expect(!MeetingAppKind.includes("com.microsoft.teams2", for: "com.microsoft.teams"), "서로 다른 Teams 앱까지 수집")
        try expect(!MeetingAppKind.includes("us.zoom.xos-other", for: "us.zoom.xos"), "번들 접두사 경계 누락")
    }

    func selectedAppScope() throws {
        let target = RecordingTarget(bundleID: "us.zoom.xos", name: "Zoom", processID: 10)
        let available = [ApplicationIdentity(bundleID: "us.zoom.xos", processID: 10),
                         ApplicationIdentity(bundleID: "us.zoom.CptHost", processID: 11),
                         ApplicationIdentity(bundleID: "com.apple.Music", processID: 12),
                         ApplicationIdentity(bundleID: "com.microsoft.teams2", processID: 13)]
        let selected = try RecordingTargetPolicy.included(for: target, in: available)
        try expect(selected.map(\.processID) == [10, 11], "선택한 Zoom 외의 앱이 녹음 범위에 포함됨")
        var meeting = Meeting(title: "대상 앱 저장")
        meeting.recordingTarget = target
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        try expect(decoded.recordingTarget == target, "녹음 출처 저장 손실")
        try expect(!TranscriptMarkdown.render(meeting).contains("us.zoom.xos"), "내부 앱 정보가 Markdown에 노출")
    }

    func missingAppNoFallback() throws {
        let target = RecordingTarget(bundleID: "us.zoom.xos", name: "Zoom", processID: 10)
        for available in [[ApplicationIdentity(bundleID: "us.zoom.xos", processID: 99)],
                          [ApplicationIdentity(bundleID: "us.zoom.CptHost", processID: 11)], []] {
            do { _ = try RecordingTargetPolicy.included(for: target, in: available); throw CheckError.failed("종료되거나 다시 실행된 대상을 허용함") }
            catch is RecordingTargetError { }
        }
        let all = try RecordingTargetPolicy.included(for: .system, in: [])
        try expect(all.isEmpty && RecordingTarget.system.isSystemAudio, "전체 오디오는 명시적 선택에서만 허용되어야 함")
    }

    func meetingDetection() throws {
        func zoom(_ active: Bool?, pid: Int32 = 10) -> MeetingAppCandidate {
            MeetingAppCandidate(bundleID: "us.zoom.xos", name: "Zoom", processID: pid, inputActive: active)
        }
        var state = MeetingDetectionState()
        try expect(state.update([zoom(false)]).count == 1, "실행 감지 누락")
        try expect(state.update([zoom(false)]).isEmpty, "반복 조회가 중복 알림을 만듦")
        try expect(state.update([zoom(true)]).isEmpty, "순간적인 마이크 사용을 즉시 회의로 오인")
        let started = state.update([zoom(true)])
        try expect(started.count == 1 && started[0].kind == .microphoneActive, "지속된 마이크 사용 감지 누락")
        let refreshed = started[0].refreshed(with: zoom(false))
        try expect(refreshed.kind == .launched && !refreshed.message.contains("마이크 사용 중"), "마이크 사용 종료 후에도 상단 알림이 사용 중으로 남음")
        try expect(state.update([zoom(true)]).isEmpty, "마이크 사용 알림 반복")
        try expect(state.update([zoom(nil)]).isEmpty, "조회 실패를 새로운 회의로 오인")
        _ = state.update([])
        try expect(state.update([zoom(false, pid: 99)]).count == 1, "앱 재실행 감지 누락")
        _ = state.update([zoom(true, pid: 99)])
        _ = state.update([zoom(nil, pid: 99)])
        try expect(state.update([zoom(true, pid: 99)]).isEmpty, "조회 실패를 가로질러 지속 사용으로 판정함")
        try expect(state.update([zoom(true, pid: 99)]).count == 1, "정상 관측 재개 후 마이크 감지 누락")
    }

    func meetingAlertRate() throws {
        var state = MeetingDetectionState(), throttle = MeetingAlertThrottle()
        let zoom = MeetingAppCandidate(bundleID: "us.zoom.xos", name: "Zoom", processID: 10, inputActive: false)
        let event = state.update([zoom])[0]
        try expect(throttle.shouldNotify(event, at: 100), "첫 알림 차단")
        try expect(!throttle.shouldNotify(event, at: 110), "짧은 간격의 알림 반복")
        try expect(throttle.shouldNotify(event, at: 146), "다음 회의의 알림까지 차단")
    }

    func meetingRecommendation() throws {
        let zoom = MeetingAppCandidate(bundleID: "us.zoom.xos", name: "Zoom", processID: 10, inputActive: true)
        let webex = MeetingAppCandidate(bundleID: "Cisco-Systems.Spark", name: "Webex", processID: 20, inputActive: false)
        let browser = MeetingAppCandidate(bundleID: "com.apple.Safari", name: "Safari", processID: 30, inputActive: true)
        try expect(MeetingAppCandidate.recommended(in: [webex, browser, zoom], frontmostBundleID: webex.id)?.id == zoom.id, "마이크 사용 앱보다 단순 실행 앱을 우선함")
        try expect(MeetingAppCandidate.recommended(in: [browser], frontmostBundleID: browser.id) == nil, "브라우저 실행만으로 회의를 확정함")
    }

    func safeChunkPaths() throws {
        let root = try temporaryDirectory()
        for name in ["../outside.m4a", "/tmp/file.m4a", "..", "", "folder\\file.m4a"] {
            do { _ = try MeetingStore.chunkURL(name, in: root); throw CheckError.failed("잘못된 경로를 허용함: \(name)") }
            catch is StoreError { /* Expected */ }
        }
        let url = try MeetingStore.chunkURL("microphone-000001.m4a", in: root)
        try expect(url.deletingLastPathComponent().lastPathComponent == ".audio-parts", "잘못된 오디오 조각 위치")
    }

    func finalSegments() throws {
        var meeting = Meeting(title: "테스트")
        meeting.add(TranscriptSegment(source: .system, start: 5, end: 6, text: "먼저 도착한 결과"))
        meeting.add(TranscriptSegment(source: .microphone, start: 1, end: 2, text: "초기 결과"))
        meeting.add(TranscriptSegment(source: .microphone, start: 1, end: 2, text: "교정된 결과"))
        meeting.add(TranscriptSegment(source: .system, start: 1, end: 3, text: "동시에 말한 상대방"))
        meeting.add(TranscriptSegment(source: .system, start: 8, end: 9, text: "  \n"))
        try expect(meeting.segments.count == 3, "중복 또는 빈 전사 결과가 추가됨")
        try expect(meeting.sortedSegments.first?.text == "교정된 결과", "정렬 또는 교정 결과 오류")
        try expect(meeting.sortedSegments.last?.start == 5, "도착 순서로 저장됨")
    }

    func roundTrip() throws {
        let store = MeetingStore(root: try temporaryDirectory())
        var stored = try store.create(title: "기술 회의")
        stored.meeting.add(TranscriptSegment(source: .microphone, start: 12, end: 15, text: "출시일은 11월 3일입니다."))
        stored.meeting.status = .completed
        try store.save(stored)
        let read = try store.loadAll().first
        try expect(read?.id == stored.id, "회의 ID가 바뀜")
        try expect(read?.meeting.segments.first?.text == "출시일은 11월 3일입니다.", "한국어 대화록 손실")
        let text = try String(contentsOf: stored.directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        try expect(text.contains("## 내 발언") && text.contains("출시일은 11월 3일입니다.") && !text.contains("00:00:12"), "Markdown 내용 오류")
        try expect(FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent(".meeting.json").path), "숨김 관리 정보가 저장되지 않음")
        try expect(!FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent("metadata.json").path), "사용자 파일과 관리 정보가 섞임")
        try expect(!FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent("summary.md").path), "요약하지 않은 회의의 요약 파일이 생성됨")
    }

    func partialReplacement() throws {
        var pending = PendingTranscript()
        pending.receive(TranscriptSegment(source: .system, start: 0, end: 1, text: "오늘 회의"), final: false)
        let id = pending.segments.first?.id
        pending.receive(TranscriptSegment(source: .system, start: 0, end: 3, text: "오늘 회의에서는 일정을 정합니다"), final: false)
        try expect(pending.segments.count == 1, "수정된 중간 문장이 중복으로 쌓임")
        try expect(pending.segments.first?.id == id, "같은 문장의 화면 ID가 계속 바뀜")
        try expect(pending.text(for: .system) == "오늘 회의에서는 일정을 정합니다", "최신 교정이 반영되지 않음")
    }

    func threeSpeakers() throws {
        var meeting = Meeting(title: "세 명의 회의")
        var segment = TranscriptSegment(source: .system, start: 0, end: 6, text: "기획입니다. 개발입니다. 검증입니다.")
        segment.words = [TranscriptWord(text: "기획입니다. ", start: 0, end: 1),
                         TranscriptWord(text: "개발입니다. ", start: 2, end: 3),
                         TranscriptWord(text: "검증입니다.", start: 4, end: 5)]
        meeting.add(segment)
        meeting.add(TranscriptSegment(source: .microphone, start: 1, end: 2, text: "확인했습니다."))
        let result = SpeakerAttribution.apply([
            SpeakerTurn(speakerID: "raw-9", start: 0, end: 1),
            SpeakerTurn(speakerID: "raw-2", start: 2, end: 3),
            SpeakerTurn(speakerID: "raw-7", start: 4, end: 5)], to: meeting)
        let sections = TranscriptDocument.sections(result)
        try expect(result.diarization?.speakerCount == 3, "화자가 A/B/C로 구분되지 않음")
        try expect(sections.map(\.label) == ["화자 A", "내 발언", "화자 B", "화자 C"], "화자 라벨이나 내 발언 구분 오류")
        let markdown = TranscriptMarkdown.render(result)
        try expect(markdown.contains("## 화자 B\n\n개발입니다."), "문장 중간의 화자 변경을 놓침")
        try expect(result.segments.allSatisfy { $0.words == nil }, "분리 완료 후 중복 단어 정보가 남음")
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(result))
        try expect(TranscriptMarkdown.render(decoded) == markdown, "재실행 후 화자 정보 손실")
    }

    func uncertainSpeakers() throws {
        var meeting = Meeting(title: "불확실한 구간")
        meeting.add(TranscriptSegment(source: .system, start: 0, end: 4, text: "단어 시간이 없는 이전 문장"))
        meeting.add(TranscriptSegment(source: .system, start: 5, end: 6, text: "두 사람이 겹쳐 말합니다"))
        let result = SpeakerAttribution.apply([
            SpeakerTurn(speakerID: "one", start: 0, end: 2), SpeakerTurn(speakerID: "two", start: 2, end: 4),
            SpeakerTurn(speakerID: "one", start: 5, end: 6), SpeakerTurn(speakerID: "two", start: 5, end: 6)], to: meeting)
        try expect(result.diarization?.reviewCount == 2, "애매한 문장에 확실한 화자를 추측함")
        try expect(result.segments.map(\.text) == meeting.segments.map(\.text), "불확실한 발언이 삭제됨")
        try expect(TranscriptMarkdown.render(result).contains("화자 확인 필요"), "불확실한 화자 표시 없음")
    }

    func speakerRetryRecovery() throws {
        let root = try temporaryDirectory()
        let store = MeetingStore(root: root)
        var stored = try store.create(title: "분석 재시도")
        stored.meeting.status = .completed
        stored.meeting.audioFile = "audio.m4a"
        stored.meeting.diarization = SpeakerDiarizationSummary(state: .failed, error: "모델을 불러오지 못함")
        var segment = TranscriptSegment(source: .system, start: 0, end: 1, text: "유지할 문장")
        segment.words = [TranscriptWord(text: "유지할 문장", start: 0, end: 1)]
        stored.meeting.add(segment)
        let chunk = AudioChunk(fileName: "system-000000.m4a", source: .system, offset: 0)
        stored.meeting.audioChunks = [chunk]
        let part = try MeetingStore.chunkURL(chunk.fileName, in: stored.directory)
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: part)
        try Data([3, 4]).write(to: stored.directory.appendingPathComponent("audio.m4a"))
        try store.save(stored)
        let reread = try store.loadAll().first!
        try expect(FileManager.default.fileExists(atPath: part.path), "분석 실패 시 재시도할 원본이 삭제됨")
        try expect(reread.meeting.segments.first?.words?.count == 1, "분석 재시도에 필요한 단어 시간 손실")
        try expect(SpeakerDiarizer.canAnalyze(reread), "분리된 상대방 오디오로 재시도할 수 없음")
    }

    func speakerRecording(audio: URL, result: URL, root: URL) async throws {
        let input = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: result))
        let store = MeetingStore(root: root)
        var stored = try store.create(title: "화자 구분 검증 · 한국어 합성 음성")
        stored.meeting.segments = input.segments.map {
            var segment = $0; segment.speakerID = nil; return segment
        }
        stored.meeting.diarization = SpeakerDiarizationSummary(state: .pending)
        stored.meeting.status = .completed
        let file = try AVAudioFile(forReading: audio)
        let chunk = AudioChunk(fileName: "system-000000.wav", source: .system, offset: 0,
                               duration: Double(file.length) / file.processingFormat.sampleRate, finalized: true)
        let part = try MeetingStore.chunkURL(chunk.fileName, in: stored.directory)
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audio, to: part)
        stored.meeting.audioChunks = [chunk]
        _ = try await AudioExporter.export(chunks: [chunk], directory: stored.directory)
        stored.meeting.audioFile = "audio.m4a"
        try store.save(stored)
        try expect(FileManager.default.fileExists(atPath: part.path), "화자 분석 전 원본 삭제")
        stored.meeting = try await SpeakerDiarizer.analyze(stored)
        try expect(stored.meeting.diarization?.speakerCount == 3, "실제 모델과 원본 조각에서 세 화자를 찾지 못함")
        try store.save(stored)
        let markdown = try String(contentsOf: stored.directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        for label in ["화자 A", "화자 B", "화자 C"] { try expect(markdown.contains("## \(label)"), "Markdown 화자 누락: \(label)") }
        try expect(!FileManager.default.fileExists(atPath: part.path), "화자 분석·저장 완료 후 원본 조각 미정리")
        try expect(!FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent(".speaker-input.m4a").path), "분석 임시 파일 미정리")
        let reread = try store.loadAll().first { $0.id == stored.id }
        try expect(reread?.meeting.diarization?.speakerCount == 3, "재실행 후 화자 정보 누락")
        print("PASS production recording flow: isolated system audio, 3 speakers, Markdown, cleanup, reload")
        print(stored.directory.path)
    }

    func transcriptCleanup() throws {
        for noise in ["", " \n ", ".", "…", "?!", "[음악]", "(박수)", "[Music]", "[silence]"] {
            try expect(TranscriptText.clean(noise) == nil, "무음·기호 결과가 남음: \(noise)")
        }
        for speech in ["네", "아니요", "1", "3.5%", "C++", "음악", "감사합니다", "안녕하세요."] {
            try expect(TranscriptText.clean(speech) == speech, "정상 발언이 삭제됨: \(speech)")
        }
        try expect(TranscriptText.clean(" 첫 문장\n\t두 번째  문장 ") == "첫 문장 두 번째 문장", "공백 정규화 실패")
        var meeting = Meeting(title: "정리 검사")
        meeting.add(TranscriptSegment(source: .microphone, start: 0, end: 1, text: "임시 인식"))
        meeting.add(TranscriptSegment(source: .microphone, start: 0, end: 1, text: "."))
        try expect(meeting.segments.isEmpty, "기호로 교정된 이전 결과가 남음")
        meeting.add(TranscriptSegment(source: .microphone, start: 1, end: 2, text: "네"))
        meeting.add(TranscriptSegment(source: .microphone, start: 3, end: 4, text: "네"))
        try expect(meeting.segments.count == 2, "서로 다른 시점에 실제 반복한 대답이 삭제됨")
    }

    func speakerDocument() throws {
        var meeting = Meeting(title: "회의\n제목")
        meeting.segments = [
            TranscriptSegment(source: .microphone, start: 4, end: 5, text: "일정을 확인하겠습니다."),
            TranscriptSegment(source: .system, start: 0, end: 1, text: "월요일에 진행합니다."),
            TranscriptSegment(source: .system, start: 8, end: 9, text: "장소는 회의실입니다."),
            TranscriptSegment(source: .microphone, start: 10, end: 11, text: ".")
        ]
        meeting.warnings = ["테스트 경고"]
        let rendered = TranscriptMarkdown.render(meeting)
        let expected = "# 회의 제목\n\n## 상대방 발언\n\n월요일에 진행합니다. 장소는 회의실입니다.\n\n## 내 발언\n\n일정을 확인하겠습니다.\n"
        try expect(rendered == expected, "화자별 발언 순서·묶음 또는 로그 제거 오류")
        try expect(TranscriptMarkdown.render(Meeting(title: "빈 회의")) == "# 빈 회의\n", "빈 발언·상태 안내가 대화록에 저장됨")
        var pending = PendingTranscript()
        pending.receive(TranscriptSegment(source: .system, start: 0, end: 1, text: "..."), final: false)
        try expect(pending.segments.isEmpty, "기호가 실시간 대화록에 표시됨")
    }

    private func legacyFixture(in root: URL, edited: String? = nil) throws -> Meeting {
        var meeting = Meeting(title: "이전 회의", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.schemaVersion = 1
        meeting.status = .completed
        meeting.segments = [
            TranscriptSegment(source: .system, start: 0, end: 1, text: "보존할 발언입니다."),
            TranscriptSegment(source: .microphone, start: 2, end: 3, text: ".")
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meeting).write(to: root.appendingPathComponent("metadata.json"))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let oldMarkdown = "# 이전 회의\n\n- 회의 ID: \(meeting.id.uuidString)\n- 시작: \(formatter.string(from: meeting.startedAt))\n- 상태: 저장 완료\n\n## 전체 대화록\n\n[00:00:00] **회의 소리**\n\n보존할 발언입니다.\n\n[00:00:02] **내 마이크**\n\n.\n"
        try (edited ?? oldMarkdown).write(to: root.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        return meeting
    }

    func legacyMigration() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try legacyFixture(in: directory)
        let audio = Data([1, 2, 3, 4]), summary = Data("사용자 요약".utf8)
        try audio.write(to: directory.appendingPathComponent("audio.m4a"))
        try summary.write(to: directory.appendingPathComponent("summary.md"))
        let store = MeetingStore(root: root)
        let migrated = try store.loadAll().first!
        try expect(migrated.id == original.id && migrated.meeting.schemaVersion == 2, "기존 회의 ID·버전 이전 실패")
        try expect(migrated.meeting.segments.count == 1, "기존 무음 전사가 정리되지 않음")
        let markdown = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        try expect(markdown == "# 이전 회의\n\n## 상대방 발언\n\n보존할 발언입니다.\n", "기존 대화록이 새 형식으로 이전되지 않음")
        let savedAudio = try Data(contentsOf: directory.appendingPathComponent("audio.m4a"))
        let savedSummary = try Data(contentsOf: directory.appendingPathComponent("summary.md"))
        try expect(savedAudio == audio, "기존 음성 변경")
        try expect(savedSummary == summary, "기존 요약 변경")
        let hidden = try Data(contentsOf: directory.appendingPathComponent(".meeting.json"))
        _ = try store.loadAll()
        let rereadHidden = try Data(contentsOf: directory.appendingPathComponent(".meeting.json"))
        try expect(rereadHidden == hidden, "반복 실행 시 관리 정보 재작성")
        try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path), "이전 관리 파일 중복 보관")
    }

    func editedMarkdownPreserved() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("edited", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manual = "# 직접 고친 대화록\n\n의미 있는 추가 메모\n"
        _ = try legacyFixture(in: directory, edited: manual)
        _ = try MeetingStore(root: root).loadAll()
        let actual = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        try expect(actual == manual, "수동 편집한 Markdown을 덮어씀")
    }

    func partialFinalization() throws {
        var pending = PendingTranscript()
        pending.receive(TranscriptSegment(source: .system, start: 0, end: 2, text: "첫 번째 문장"), final: false)
        pending.receive(TranscriptSegment(source: .system, start: 2, end: 4, text: "두 번째 문장"), final: false)
        pending.receive(TranscriptSegment(source: .system, start: 0, end: 2, text: "첫 번째 문장입니다."), final: true)
        try expect(pending.segments.count == 1, "이전 문장 확정 시 뒤쪽 문장까지 지워짐")
        try expect(pending.text(for: .system) == "두 번째 문장", "진행 중인 다음 문장을 잃음")
    }

    func independentPartials() throws {
        var pending = PendingTranscript()
        pending.receive(TranscriptSegment(source: .microphone, start: 0, end: 2, text: "내 발언"), final: false)
        pending.receive(TranscriptSegment(source: .system, start: 0, end: 2, text: "상대방 발언"), final: false)
        pending.receive(TranscriptSegment(source: .system, start: 0, end: 2, text: "상대방 발언 확정"), final: true)
        try expect(pending.text(for: .microphone) == "내 발언", "다른 입력의 확정 결과가 마이크 문장을 지움")
        pending.clear(source: .system)
        try expect(pending.segments.count == 1, "오류가 없는 입력까지 초기화됨")
    }

    func interruptedRecovery() throws {
        let store = MeetingStore(root: try temporaryDirectory())
        var stored = try store.create(title: "복구 테스트")
        stored.meeting.add(TranscriptSegment(source: .system, start: 0, end: 2, text: "보존할 발언"))
        stored.meeting.status = .finalizing
        let chunk = AudioChunk(fileName: "system-000000.m4a", source: .system, offset: 0)
        stored.meeting.audioChunks = [chunk]
        try store.save(stored)
        let url = try MeetingStore.chunkURL(chunk.fileName, in: stored.directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        let recovered = try store.loadAll(recoverInterrupted: true).first
        try expect(recovered?.meeting.status == .interrupted, "중단 상태가 복구되지 않음")
        try expect(recovered?.meeting.segments.first?.text == "보존할 발언", "복구 중 전사 손실")
        try expect(FileManager.default.fileExists(atPath: url.path), "복구 중 원본 조각 삭제")
        let reread = try store.loadAll(recoverInterrupted: true).first
        try expect(reread?.meeting.warnings.count == 1, "복구 경고가 반복됨")
    }

    func completedPreserved() throws {
        let store = MeetingStore(root: try temporaryDirectory())
        var stored = try store.create(title: "완료된 회의")
        stored.meeting.status = .completed
        try store.save(stored)
        let read = try store.loadAll(recoverInterrupted: true).first
        try expect(read?.meeting.status == .completed, "완료된 회의가 중단됨으로 바뀜")
    }

    func timestamps() throws {
        try expect(TranscriptMarkdown.timestamp(3_661.9) == "01:01:01", "1시간 이상 표시 오류")
        try expect(TranscriptMarkdown.timestamp(-4) == "00:00:00", "음수 시간 표시 오류")
        try expect(TranscriptMarkdown.timestamp(.nan) == "00:00:00", "NaN 처리 오류")
        try expect(TranscriptMarkdown.timestamp(1e30) == "00:00:00", "비정상적으로 큰 시간 처리 오류")
    }

    private func tone(seconds: Double, rate: Double = 48_000, channels: AVAudioChannelCount = 1, frequency: Double = 440) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let count = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(count) { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * frequency / rate)) * 0.2 }
        }
        return buffer
    }

    func resampling() throws {
        let converter = PCMConverter(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        guard let result = try converter.convert(tone(seconds: 0.1, rate: 44_100, channels: 2)) else { throw CheckError.failed("변환 결과 없음") }
        try expect(result.format.sampleRate == 48_000 && result.format.channelCount == 1, "목표 오디오 형식 불일치")
        try expect(result.frameLength > 4_000 && AudioBuffers.level(result) > 0.1, "샘플 또는 오디오 크기 손실")
    }

    func audioExport() async throws {
        let root = try temporaryDirectory()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        var snapshots: [AudioChunk] = []
        let mic = AudioChunkWriter(source: .microphone, directory: root, format: format, chunkDuration: 0.2) { snapshots.append($0) }
        let system = AudioChunkWriter(source: .system, directory: root, format: format) { snapshots.append($0) }
        try mic.write(tone(seconds: 0.3), at: 0)
        try mic.write(tone(seconds: 0.3), at: 0.3)
        try system.write(tone(seconds: 0.6, frequency: 660), at: 0.2)
        mic.close(); system.close()
        try expect(mic.chunks.count == 2 && snapshots.contains { $0.finalized }, "조각 분할 또는 확정 실패")
        let warnings = try await AudioExporter.export(chunks: mic.chunks + system.chunks, directory: root)
        try expect(warnings.isEmpty, "오디오 조각 내보내기 경고: \(warnings)")
        let asset = AVURLAsset(url: root.appendingPathComponent("audio.m4a"))
        let duration = try await asset.load(.duration).seconds
        try expect(abs(duration - 0.8) < 0.08, "시스템 소리의 0.2초 시작 오프셋이 보존되지 않음: \(duration)")
        let audio = try AVAudioFile(forReading: root.appendingPathComponent("audio.m4a"))
        let decoded = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
        try audio.read(into: decoded)
        try expect(AudioBuffers.level(decoded) > 0.1, "내보낸 M4A가 무음임")
        func energy(from start: Double, to end: Double) -> Double {
            let lower = Int(start * decoded.format.sampleRate)
            let upper = min(Int(end * decoded.format.sampleRate), Int(decoded.frameLength))
            guard let data = decoded.floatChannelData?[0], upper > lower else { return 0 }
            return (lower..<upper).reduce(0.0) { $0 + Double(data[$1] * data[$1]) } / Double(upper - lower)
        }
        try expect(energy(from: 0.05, to: 0.15) > 0.001, "마이크만 녹음된 구간이 손실됨")
        try expect(energy(from: 0.65, to: 0.75) > 0.001, "시스템 소리만 녹음된 구간이 손실됨")
        _ = try await AudioExporter.export(chunks: system.chunks, directory: root, fileName: ".speaker-input.m4a")
        let isolated = try AVAudioFile(forReading: root.appendingPathComponent(".speaker-input.m4a"))
        let isolatedPCM = AVAudioPCMBuffer(pcmFormat: isolated.processingFormat, frameCapacity: AVAudioFrameCount(isolated.length))!
        try isolated.read(into: isolatedPCM)
        let count = Int(isolatedPCM.format.sampleRate * 0.1)
        let leadingEnergy = (0..<count).reduce(0.0) { $0 + Double(pow(isolatedPCM.floatChannelData![0][$1], 2)) } / Double(count)
        try expect(leadingEnergy < 0.000001, "화자 분석용 오디오에 내 마이크가 섞이거나 시작 공백이 사라짐")
        try expect(abs(Double(isolated.length) / isolated.processingFormat.sampleRate - 0.8) < 0.08, "화자 분석용 오디오의 원래 시간축 손실")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".audio-parts").path), "메타데이터 확정 전에 복구 조각이 삭제됨")
        var completed = Meeting(title: "오디오 검사")
        completed.status = .completed
        completed.audioFile = "audio.m4a"
        try MeetingStore(root: root).save(StoredMeeting(meeting: completed, directory: root))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".audio-parts").path), "저장 확정 후 임시 조각이 남음")
    }

    func microphoneGap() async throws {
        let root = try temporaryDirectory()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let mic = AudioChunkWriter(source: .microphone, directory: root, format: format) { _ in }
        let system = AudioChunkWriter(source: .system, directory: root, format: format) { _ in }
        try mic.write(tone(seconds: 0.3, frequency: 440), at: 0)
        mic.close()
        try mic.write(tone(seconds: 0.3, frequency: 440), at: 0.7)
        try system.write(tone(seconds: 1, frequency: 660), at: 0)
        mic.close(); system.close()
        let warnings = try await AudioExporter.export(chunks: mic.chunks + system.chunks, directory: root)
        try expect(warnings.isEmpty, "마이크 재개 시 내보내기 경고: \(warnings)")
        let file = try AVAudioFile(forReading: root.appendingPathComponent("audio.m4a"))
        let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: decoded)
        let rate = decoded.format.sampleRate
        func amplitude(_ frequency: Double, from start: Double, to end: Double) -> Double {
            let lower = Int(start * rate)
            let upper = min(Int(end * rate), Int(decoded.frameLength))
            guard let data = decoded.floatChannelData?[0], upper > lower else { return 0 }
            var sine = 0.0, cosine = 0.0
            for index in lower..<upper {
                let phase = 2 * Double.pi * frequency * Double(index) / rate
                sine += Double(data[index]) * sin(phase)
                cosine += Double(data[index]) * cos(phase)
            }
            return 2 * hypot(sine, cosine) / Double(upper - lower)
        }
        try expect(abs(Double(file.length) / rate - 1) < 0.08, "마이크를 끈 구간이 시간축에서 삭제됨")
        try expect(amplitude(440, from: 0.05, to: 0.2) > 0.06, "마이크 초기 음성 손실")
        try expect(amplitude(440, from: 0.45, to: 0.6) < 0.01, "마이크를 끈 구간에 마이크 음성이 포함됨")
        try expect(amplitude(440, from: 0.8, to: 0.95) > 0.06, "다시 켠 마이크 음성 손실")
        try expect(amplitude(660, from: 0.45, to: 0.6) > 0.06, "마이크를 끌 때 회의 소리도 함께 손실됨")
    }

    func failedExport() async throws {
        let root = try temporaryDirectory()
        let chunk = AudioChunk(fileName: "system-000000.m4a", source: .system, offset: 0)
        let url = try MeetingStore.chunkURL(chunk.fileName, in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid audio".utf8).write(to: url)
        do {
            _ = try await AudioExporter.export(chunks: [chunk], directory: root)
            throw CheckError.failed("손상된 오디오의 내보내기가 성공했다고 보고함")
        } catch is RecorderError {
            try expect(FileManager.default.fileExists(atPath: url.path), "내보내기 실패 후 원본이 삭제됨")
        }
    }
}
