import CryptoKit
import Darwin
import Foundation
import RecorderCore

private struct SearchFixture {
    let root: URL
    init(prefix: String = "meeting-search-checks") throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func meeting(title: String, segments: [TranscriptSegment], summary: String? = nil,
                 schemaVersion: Int = 2, date: Date = Date(timeIntervalSince1970: 1_790_000_000)) throws -> StoredMeeting {
        var meeting = Meeting(title: title, date: date)
        meeting.schemaVersion = schemaVersion
        meeting.status = .completed
        meeting.endedAt = date.addingTimeInterval(segments.last?.end ?? 30)
        meeting.segments = segments
        meeting.audioFile = "audio.m4a"
        let directory = root.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meeting).write(to: directory.appendingPathComponent(".meeting.json"))
        try TranscriptMarkdown.render(meeting).write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        if let summary { try summary.write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8) }
        // The search checks never decode this fixture audio or request recording access.
        try Data("fixture-audio-preserve".utf8).write(to: directory.appendingPathComponent("audio.m4a"))
        return StoredMeeting(meeting: meeting, directory: directory)
    }

    func contents() throws -> [String: String] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: String] = [:]
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            result[relative] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

private func searchSegment(_ text: String, start: Double = 12, end: Double = 20,
                           speaker: String = "speaker-1") -> TranscriptSegment {
    var segment = TranscriptSegment(source: .system, start: start, end: end, text: text)
    segment.speakerID = speaker
    return segment
}

private func searchRejects(_ message: String, action: () async throws -> Void) async throws {
    do { try await action() }
    catch { return }
    throw CheckError.failed(message)
}

extension RecorderChecks {
    func meetingSearchText() throws {
        let decomposed = "🙂 출시 일정은 11월 25일, API v2.0 입니다.".decomposedStringWithCanonicalMapping
        for query in ["출시일정", "출 시 일 정", "API", "api", "11월25일", "v2.0"] {
            try expect(!MeetingSearchText.ranges(in: decomposed, query: query).isEmpty,
                       "한국어 공백·NFC·영문 대소문자·숫자 검색 누락: " + query)
        }
        guard let unicodeRange = MeetingSearchText.ranges(in: decomposed, query: "출시일정").first else {
            throw CheckError.failed("분해된 한국어의 원문 범위 누락")
        }
        let originalSlice = (decomposed as NSString).substring(with: unicodeRange.nsRange)
        try expect(originalSlice.precomposedStringWithCanonicalMapping == "출시 일정" && unicodeRange.location == 3,
                   "검색 강조 범위가 이모지·분해된 한국어의 원래 UTF-16 위치를 잃음")
        let latePrefix = String(repeating: "🙂가", count: 2_000).decomposedStringWithCanonicalMapping
        let lateSource = latePrefix + "출시 일정".decomposedStringWithCanonicalMapping
        guard let lateRange = MeetingSearchText.ranges(in: lateSource, query: "출시일정").first else {
            throw CheckError.failed("긴 Unicode 문단 후반의 일치 범위 누락")
        }
        try expect(lateRange.location == latePrefix.utf16.count &&
                   (lateSource as NSString).substring(with: lateRange.nsRange).precomposedStringWithCanonicalMapping == "출시 일정",
                   "긴 Unicode 문단 후반의 원문 UTF-16 위치가 어긋남")
        try expect(MeetingSearchText.ranges(in: decomposed, query: "v20").isEmpty,
                   "구두점을 지워 서로 다른 버전 번호를 같은 값으로 검색함")
        try expect(MeetingSearchText.ranges(in: decomposed, query: "   \n\t").isEmpty, "빈 검색어를 모든 위치와 일치시킴")
        try expect(MeetingSearchText.ranges(in: "ＡＰＩ café", query: "api").count == 1,
                   "전각 영문 검색 정규화 실패")
        try expect(MeetingSearchText.ranges(in: "café", query: "cafe").count == 1,
                   "악센트 접기 검색 실패")
    }

    func meetingSearchEvidence() async throws {
        let fixture = try SearchFixture()
        defer { fixture.cleanup() }
        let first = searchSegment("배포 준비를 검토했습니다.", start: 1, end: 10)
        let later = searchSegment("출시 일정은 11월 25일입니다.", start: 12, end: 20)
        let one = try fixture.meeting(title: "주간 검토", segments: [first, later], schemaVersion: 1)
        try FileManager.default.moveItem(at: one.directory.appendingPathComponent(".meeting.json"),
                                         to: one.directory.appendingPathComponent("metadata.json"))
        let two = try fixture.meeting(title: "고객 확인", segments: [searchSegment("출시 일정은 다음 회의에서 정합니다.", start: 75, end: 82)],
                                      date: Date(timeIntervalSince1970: 1_790_000_100))
        let before = try fixture.contents()
        let index = LocalMeetingSearchIndex()
        let response = try await index.search(root: fixture.root, query: "출시일정", scope: .all)
        try expect(Set(response.hits.map(\.meetingID)) == Set([one.id, two.id]), "동일 구절이 있는 두 회의를 구분하지 못함")
        let match = response.hits.first { $0.meetingID == one.id && $0.playbackStart != nil }
        try expect(match?.playbackStart == later.start, "합친 문단의 시작으로 이동하여 실제 매치 발언 시각을 잃음")
        try expect(match?.paragraphID == first.id, "실제 발언과 화면의 합친 문단 연결이 어긋남")
        guard let hit = match else { throw CheckError.failed("재생 근거 결과 누락") }
        _ = try await index.validate(root: fixture.root, hit: hit)
        let secondMatch = response.hits.first { $0.meetingID == two.id }
        try expect(secondMatch?.playbackStart == 75, "다른 회의의 시각을 잘못 재사용함")
        let titleOnly = try await index.search(root: fixture.root, query: "출시일정", scope: .title)
        try expect(titleOnly.hits.isEmpty, "제목 검색 범위에서 대화록을 반환함")
        let transcriptOnly = try await index.search(root: fixture.root, query: "출시일정", scope: .transcript)
        try expect(!transcriptOnly.hits.isEmpty && transcriptOnly.hits.allSatisfy { $0.source == .transcript },
                   "대화록 검색 범위가 다른 문서를 포함함")
        let after = try fixture.contents()
        try expect(after == before, "색인·검증이 메타데이터, Markdown 또는 오디오를 변경함")
    }

    func meetingSearchExternalDocuments() async throws {
        let fixture = try SearchFixture()
        defer { fixture.cleanup() }
        let stored = try fixture.meeting(title: "검토 회의", segments: [searchSegment("원래 약속을 확인합니다.")],
                                         summary: "# 요약\n\n초기 결정은 검토 중입니다.\n")
        let index = LocalMeetingSearchIndex()
        let initial = try await index.search(root: fixture.root, query: "원래약속", scope: .all)
        guard let old = initial.hits.first else { throw CheckError.failed("초기 전사 결과 누락") }
        let transcript = stored.directory.appendingPathComponent("transcript.md")
        let edited = "# 편집된 회의\n\n## 담당자\n\n외부에서 수정한 고유명사 알파프로젝트를 확인합니다.\n"
        try edited.write(to: transcript, atomically: true, encoding: .utf8)
        try await searchRejects("변경된 대화록의 오래된 결과를 허용함") {
            _ = try await index.validate(root: fixture.root, hit: old)
        }
        let current = try await index.search(root: fixture.root, query: "알파프로젝트", scope: .all)
        try expect(!current.hits.isEmpty && current.hits.allSatisfy { $0.playbackStart == nil },
                   "외부 편집 텍스트 누락 또는 근거 없는 재생 시각 생성")
        let displayed = try await index.snapshot(root: fixture.root, meetingID: stored.id, directory: stored.directory)
        let displayedText = displayed.transcript.blocks.map(\.text).joined(separator: "\n\n")
        try expect(displayed.transcript.externallyEdited && displayedText.contains("알파프로젝트") && !displayedText.contains("원래 약속"),
                   "검색한 외부 편집 내용과 선택한 문서 snapshot이 다름")
        let removed = try await index.search(root: fixture.root, query: "원래약속", scope: .all)
        try expect(removed.hits.isEmpty, "외부 편집 후 화면에 없는 JSON 원문이 여전히 검색됨")
        let summary = stored.directory.appendingPathComponent("summary.md")
        let oldSummary = try await index.search(root: fixture.root, query: "초기결정", scope: .all)
        guard let summaryHit = oldSummary.hits.first else { throw CheckError.failed("초기 요약 검색 누락") }
        try expect(summaryHit.playbackStart == nil, "요약 결과에 원음 시각을 생성함")
        let originalSummary = try String(contentsOf: summary, encoding: .utf8)
        let sameLengthSummary = originalSummary.replacingOccurrences(of: "초기", with: "최종")
        var originalStat = stat()
        guard lstat(summary.path, &originalStat) == 0 else { throw CheckError.failed("요약 파일 stat 실패") }
        let handle = try FileHandle(forWritingTo: summary)
        try handle.write(contentsOf: Data(sameLengthSummary.utf8))
        var timestamps = [originalStat.st_atimespec, originalStat.st_mtimespec]
        guard futimens(handle.fileDescriptor, &timestamps) == 0 else { throw CheckError.failed("동일 mtime fixture 생성 실패") }
        try handle.close()
        var changedStat = stat()
        guard lstat(summary.path, &changedStat) == 0 else { throw CheckError.failed("변경 요약 stat 실패") }
        try expect(originalStat.st_ino == changedStat.st_ino && originalStat.st_size == changedStat.st_size &&
                   originalStat.st_mtimespec.tv_sec == changedStat.st_mtimespec.tv_sec &&
                   originalStat.st_mtimespec.tv_nsec == changedStat.st_mtimespec.tv_nsec,
                   "내용만 변경하는 동일 inode·size·mtime fixture가 유지되지 않음")
        try await searchRejects("mtime·크기가 같아도 바뀐 요약 내용의 오래된 결과를 허용함") {
            _ = try await index.validate(root: fixture.root, hit: summaryHit)
        }
        let sameStamp = try await index.search(root: fixture.root, query: "최종결정", scope: .all)
        try expect(!sameStamp.hits.isEmpty, "mtime·크기가 유지된 외부 변경을 색인에서 누락함")
        let staleWord = try await index.search(root: fixture.root, query: "초기결정", scope: .all)
        try expect(staleWord.hits.isEmpty, "mtime·크기가 유지된 외부 변경 후 이전 본문을 계속 검색함")
        try "# 요약\n\n[00:12:00] 변경된 결정은 예산 승인입니다.\n".write(to: summary, atomically: true, encoding: .utf8)
        try await searchRejects("변경된 요약의 오래된 결과를 허용함") {
            _ = try await index.validate(root: fixture.root, hit: summaryHit)
        }
        let freshSummary = try await index.search(root: fixture.root, query: "예산승인", scope: .all)
        try expect(!freshSummary.hits.isEmpty && freshSummary.hits.allSatisfy { $0.playbackStart == nil },
                   "요약의 시간 문자열을 재생 근거로 잘못 해석함")
        let preserved = try String(contentsOf: transcript, encoding: .utf8)
        try expect(preserved == edited, "외부 편집 대화록을 다시 생성함")
        let boundaryParagraph = String(repeating: "가", count: 3_998) + "알파프로젝트 경계검색검증을 확인합니다."
        let longTranscript = "# 긴 외부 대화록\n\n" + boundaryParagraph + "\n\n다음 문단의 줄바꿈도 보존합니다.\n"
        let longSummary = "# 긴 요약\n\n" + boundaryParagraph + "\n\n| 항목 | 내용 |\n| --- | --- |\n| 결정 | 검토 |\n"
        try longTranscript.write(to: transcript, atomically: true, encoding: .utf8)
        try longSummary.write(to: summary, atomically: true, encoding: .utf8)
        for scope in [MeetingSearchScope.transcript, .summary] {
            let boundary = try await index.search(root: fixture.root, query: "알파프로젝트", scope: scope)
            try expect(boundary.hits.count == 1 && boundary.hits.allSatisfy { $0.playbackStart == nil },
                       "긴 문단의 4000자 경계에 걸린 검색어를 놓치거나 재생 시각을 추측함: " + scope.rawValue)
        }
        let longSnapshot = try await index.snapshot(root: fixture.root, meetingID: stored.id, directory: stored.directory)
        try expect(longSnapshot.transcript.blocks.map(\.text).joined() == longTranscript &&
                   longSnapshot.summary?.blocks.map(\.text).joined() == longSummary,
                   "긴 문서 snapshot에서 원문의 문자·표·줄바꿈이 손실되거나 중복됨")
    }

    func meetingSearchFileChanges() async throws {
        let fixture = try SearchFixture()
        defer { fixture.cleanup() }
        let stored = try fixture.meeting(title: "경로 검증", segments: [searchSegment("이동 검증 토큰입니다.")])
        let index = LocalMeetingSearchIndex()
        let initial = try await index.search(root: fixture.root, query: "이동검증", scope: .all)
        guard let old = initial.hits.first else { throw CheckError.failed("이동 검증 초기 결과 누락") }
        let audio = stored.directory.appendingPathComponent("audio.m4a")
        try FileManager.default.removeItem(at: audio)
        let (_, missingAudio) = try await index.validate(root: fixture.root, hit: old)
        try expect(missingAudio.playbackStart == nil, "삭제된 오디오에 재생 시각을 연결함")
        let otherAudio = fixture.root.appendingPathComponent("other-audio.m4a")
        try Data("other fixture".utf8).write(to: otherAudio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: otherAudio)
        let (_, linkedAudio) = try await index.validate(root: fixture.root, hit: old)
        try expect(linkedAudio.playbackStart == nil, "심볼릭 링크 오디오를 재생 근거로 연결함")
        try FileManager.default.removeItem(at: audio)
        try Data("fixture-audio-preserve".utf8).write(to: audio)
        guard chmod(audio.path, 0) == 0 else { throw CheckError.failed("오디오 권한 fixture 생성 실패") }
        let (_, lockedAudio) = try await index.validate(root: fixture.root, hit: old)
        try expect(lockedAudio.playbackStart == nil, "읽을 수 없는 오디오를 재생 근거로 연결함")
        _ = chmod(audio.path, S_IRUSR | S_IWUSR)
        let (_, readableAudio) = try await index.validate(root: fixture.root, hit: old)
        try expect(readableAudio.playbackStart == 12, "오디오 접근 복원 후 재생 근거를 복구하지 못함")
        let renamed = fixture.root.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.moveItem(at: stored.directory, to: renamed)
        let moved = try await index.search(root: fixture.root, query: "이동검증", scope: .all)
        try expect(moved.hits.contains { $0.meetingID == stored.id }, "폴더 이름 변경 후 같은 회의를 찾지 못함")
        try await searchRejects("이동 전 경로의 오래된 결과를 허용함") { _ = try await index.validate(root: fixture.root, hit: old) }
        guard let movedHit = moved.hits.first else { throw CheckError.failed("이동 후 결과 누락") }
        _ = try await index.validate(root: fixture.root, hit: movedHit)
        try FileManager.default.removeItem(at: renamed)
        try await searchRejects("삭제한 회의의 오래된 결과를 허용함") { _ = try await index.validate(root: fixture.root, hit: movedHit) }
        let removed = try await index.search(root: fixture.root, query: "이동검증", scope: .all)
        try expect(removed.hits.isEmpty, "삭제된 회의가 색인에 남음")
    }

    func meetingSearchInvalidSources() async throws {
        let fixture = try SearchFixture()
        let outside = try SearchFixture(prefix: "meeting-search-outside")
        defer { fixture.cleanup(); outside.cleanup() }
        let valid = try fixture.meeting(title: "유효한 회의", segments: [searchSegment("유효한검색토큰")])
        let external = try outside.meeting(title: "외부 회의", segments: [searchSegment("외부비밀토큰")])
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked"), withDestinationURL: external.directory)
        let index = LocalMeetingSearchIndex()
        try await searchRejects("존재하지 않는 저장 폴더의 검색 실패를 숨김") {
            _ = try await index.search(root: fixture.root.appendingPathComponent("missing"), query: "토큰", scope: .all)
        }
        let outsideResult = try await index.search(root: fixture.root, query: "외부비밀토큰", scope: .all)
        try expect(outsideResult.hits.isEmpty, "root 밖으로 나가는 회의 symlink를 색인함")
        let corrupt = fixture.root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: false)
        try Data("invalid json".utf8).write(to: corrupt.appendingPathComponent(".meeting.json"))
        let damaged = try await index.search(root: fixture.root, query: "유효한검색토큰", scope: .all)
        try expect(damaged.hits.contains { $0.meetingID == valid.id }, "손상된 기록 때문에 정상 검색까지 실패함")
        try expect(!damaged.warnings.isEmpty, "손상된 기록을 사용자에게 알리지 않음")
        let file = valid.directory.appendingPathComponent("transcript.md")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external.directory.appendingPathComponent("transcript.md"))
        let symlinked = try await index.search(root: fixture.root, query: "외부비밀토큰", scope: .all)
        try expect(symlinked.hits.isEmpty, "root 밖 대화록 symlink를 읽음")
        try FileManager.default.removeItem(at: file)
        try "권한검증토큰".write(to: file, atomically: true, encoding: .utf8)
        guard chmod(file.path, 0) == 0 else { throw CheckError.failed("권한 검사 fixture chmod 실패") }
        defer { _ = chmod(file.path, S_IRUSR | S_IWUSR) }
        let locked = try await index.search(root: fixture.root, query: "권한검증토큰", scope: .all)
        try expect(locked.hits.isEmpty && !locked.warnings.isEmpty, "읽기 권한 상실 후 오래된 본문을 반환하거나 실패를 숨김")
        _ = chmod(file.path, S_IRUSR | S_IWUSR)
        let duplicate = fixture.root.appendingPathComponent("duplicate-identity", isDirectory: true)
        try FileManager.default.copyItem(at: valid.directory, to: duplicate)
        let duplicates = try await index.search(root: fixture.root, query: "유효한회의", scope: .title)
        try expect(duplicates.hits.isEmpty && !duplicates.warnings.isEmpty, "중복 회의 ID를 잘못된 경로로 연결함")
        do {
            _ = try await index.snapshot(root: fixture.root, meetingID: valid.id, directory: valid.directory)
            throw CheckError.failed("중복 회의 ID의 문서 이동을 허용함")
        } catch MeetingSearchError.duplicateIdentity {}
    }

    func meetingSearchCancellation() async throws {
        let fixture = try SearchFixture()
        defer { fixture.cleanup() }
        let stored = try fixture.meeting(title: "취소 검증", segments: [searchSegment("재시작검증토큰")])
        let before = try fixture.contents()
        let index = LocalMeetingSearchIndex()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await index.search(root: fixture.root, query: "재시작검증토큰", scope: .all)
        }
        do {
            _ = try await cancelled.value
            throw CheckError.failed("취소된 작업이 정상 검색 응답을 게시함")
        } catch is CancellationError {}
        await index.clear()
        let restarted = try await index.search(root: fixture.root, query: "재시작검증토큰", scope: .all)
        try expect(restarted.hits.contains { $0.meetingID == stored.id }, "색인 취소·초기화 후 재검색 실패")
        let after = try fixture.contents()
        try expect(after == before, "취소·재시작이 원본 데이터를 변경함")
    }

    func meetingSearchBenchmark() async throws {
        let fixture = try SearchFixture(prefix: "meeting-search-benchmark")
        defer { fixture.cleanup() }
        let count = 1_000, paragraphs = 100
        let started = ProcessInfo.processInfo.systemUptime
        for meeting in 0..<count {
            let segments = (0..<paragraphs).map { paragraph in
                searchSegment("분기별 제품 검토 회의 \(meeting) 문단 \(paragraph). 한국어 띄어쓰기와 API v2.0, 예산 25,000원을 점검했습니다. 다음 담당자는 근거 자료를 검토하고 출시 일정핵심에 맞춰 결과를 공유합니다.",
                              start: Double(paragraph * 35), end: Double(paragraph * 35 + 25), speaker: "speaker-\(paragraph % 3)")
            }
            _ = try fixture.meeting(title: "분기별 검토 \(meeting)", segments: segments,
                                     summary: "# 회의 요약\n\n예산 25,000원과 API v2.0의 변경 사항을 검토했습니다.\n",
                                     date: Date(timeIntervalSince1970: 1_790_000_000 + Double(meeting * 3_600)))
        }
        let preparation = ProcessInfo.processInfo.systemUptime - started
        let corpusBytes = try searchCorpusBytes(in: fixture.root)
        let index = LocalMeetingSearchIndex()
        let coldStart = ProcessInfo.processInfo.systemUptime
        let cold = try await index.search(root: fixture.root, query: "출시일정핵심", scope: .all)
        let coldSeconds = ProcessInfo.processInfo.systemUptime - coldStart
        guard let evidence = cold.hits.first else { throw CheckError.failed("벤치마크 cold 검색 결과 누락") }
        let validateStart = ProcessInfo.processInfo.systemUptime
        _ = try await index.validate(root: fixture.root, hit: evidence)
        let validateSeconds = ProcessInfo.processInfo.systemUptime - validateStart
        let snapshotStart = ProcessInfo.processInfo.systemUptime
        _ = try await index.snapshot(root: fixture.root, meetingID: evidence.meetingID, directory: evidence.directory)
        let snapshotSeconds = ProcessInfo.processInfo.systemUptime - snapshotStart
        var timings: [Double] = []
        var workloads: [[String: Any]] = []
        for query in ["APIv2.0", "예산25,000원", "한국어띄어쓰기", "결과를공유", "분기별", "검토회의", "출시일정핵심", "담당자는", "자료를검토", "없는구절XYZ"] {
            let start = ProcessInfo.processInfo.systemUptime
            let response = try await index.search(root: fixture.root, query: query, scope: .all)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            timings.append(seconds)
            workloads.append(["query": query, "seconds": seconds, "total_matches": response.totalMatches])
        }
        let sorted = timings.sorted()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = [
            "fixture": "synthetic-only; removed after measurement",
            "machine": searchHardwareString("hw.model"),
            "cpu": searchHardwareString("machdep.cpu.brand_string"),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "meeting_count": count, "paragraph_count": count * paragraphs,
            "metadata_and_markdown_bytes": corpusBytes,
            "fixture_creation_seconds": preparation,
            "cold_query": "출시일정핵심",
            "cold_index_and_query_seconds": coldSeconds,
            "cold_total_matches": cold.totalMatches,
            "selected_evidence_validation_seconds": validateSeconds,
            "selected_document_snapshot_seconds": snapshotSeconds,
            "warm_query_count": timings.count,
            "warm_query_median_seconds": sorted[sorted.count / 2],
            "warm_query_max_seconds": sorted.last!,
            "warm_queries": workloads,
            "peak_rss_bytes": usage.ru_maxrss
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}

private func searchHardwareString(_ key: String) -> String {
    var length = 0
    guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: length)
    guard sysctlbyname(key, &bytes, &length, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
}

private func searchCorpusBytes(in root: URL) throws -> Int {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
    var bytes = 0
    for case let file as URL in enumerator where ["json", "md"].contains(file.pathExtension) {
        bytes += (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return bytes
}
