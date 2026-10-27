import Darwin
import Foundation

public struct StoredMeeting: Identifiable, Sendable {
    public var meeting: Meeting
    public var directory: URL
    public var id: UUID { meeting.id }
    public init(meeting: Meeting, directory: URL) { self.meeting = meeting; self.directory = directory }
}

public enum StoreError: LocalizedError {
    case invalidFileName
    case invalidMeetingDirectory
    case meetingChanged
    case meetingInProgress
    case meetingLocked

    public var errorDescription: String? {
        switch self {
        case .invalidFileName: return "잘못된 파일 경로입니다."
        case .invalidMeetingDirectory: return "현재 저장 폴더 안의 회의 기록만 삭제할 수 있습니다."
        case .meetingChanged: return "회의 기록이 변경되어 삭제하지 않았습니다. 앱을 다시 열어 확인해 주세요."
        case .meetingInProgress: return "녹음이나 파일 정리가 끝난 뒤 삭제해 주세요."
        case .meetingLocked: return "요약을 저장 중이거나 회의 파일에 접근할 수 없습니다. 잠시 후 다시 삭제해 주세요."
        }
    }
}

public struct MeetingStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func create(title: String, date: Date = Date()) throws -> StoredMeeting {
        let meeting = Meeting(title: title, date: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "\(formatter.string(from: date))_\(Self.safeTitle(meeting.title))_\(meeting.id.uuidString.prefix(8))"
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = StoredMeeting(meeting: meeting, directory: directory)
        try save(stored)
        return stored
    }

    public func save(_ stored: StoredMeeting) throws {
        var cleaned = stored
        cleaned.meeting.cleanTranscript()
        cleaned.meeting.schemaVersion = max(2, cleaned.meeting.schemaVersion)
        try write(cleaned, updateTranscript: true)
    }

    /// Move the complete recording together so audio, transcripts, summaries,
    /// and recovery files can be restored from the system Trash.
    public func moveToTrash(_ stored: StoredMeeting,
                            trashItem: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let directory = try deletionDirectory(stored)
        // Share the MCP summary writer's lock; never move a folder mid-write.
        let fd = Darwin.open(directory.appendingPathComponent(".summary.lock").path,
                             O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.meetingLocked }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.meetingLocked }
        // Re-read identity and status after taking the lock instead of trusting
        // the snapshot that was shown when the confirmation dialog opened.
        _ = try deletionDirectory(stored)
        try trashItem(directory)
    }

    private func deletionDirectory(_ stored: StoredMeeting) throws -> URL {
        let directory = stored.directory.standardizedFileURL
        let resolved = directory.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              resolved.deletingLastPathComponent().path == resolvedRoot.path else {
            throw StoreError.invalidMeetingDirectory
        }
        let metadata = directory.appendingPathComponent(".meeting.json")
        guard try metadata.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw StoreError.invalidMeetingDirectory
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(contentsOf: metadata))
        guard meeting.id == stored.id else { throw StoreError.meetingChanged }
        guard meeting.status != .recording, meeting.status != .finalizing else {
            throw StoreError.meetingInProgress
        }
        return directory
    }

    private func write(_ stored: StoredMeeting, updateTranscript: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Metadata is the recovery source; Markdown is a readable projection of final segments.
        try encoder.encode(stored.meeting).write(to: stored.directory.appendingPathComponent(".meeting.json"), options: .atomic)
        if updateTranscript {
            try TranscriptMarkdown.render(stored.meeting).write(to: stored.directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        }
        // Delete recovery chunks only after both the final audio and metadata are durable.
        if stored.meeting.status == .completed, stored.meeting.audioFile == "audio.m4a",
           stored.meeting.diarization == nil || stored.meeting.diarization?.state == .completed,
           stored.meeting.warnings.isEmpty,
           FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent("audio.m4a").path) {
            try? FileManager.default.removeItem(at: stored.directory.appendingPathComponent(".audio-parts"))
        }
    }

    public func loadAll(recoverInterrupted: Bool = false) throws -> [StoredMeeting] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try directories.compactMap { directory -> StoredMeeting? in
            let metadata = directory.appendingPathComponent(".meeting.json")
            let legacy = directory.appendingPathComponent("metadata.json")
            let isLegacy = !FileManager.default.fileExists(atPath: metadata.path)
            guard let data = try? Data(contentsOf: isLegacy ? legacy : metadata) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var meeting = try? decoder.decode(Meeting.self, from: data) else { return nil }
            let original = meeting
            meeting.cleanTranscript()
            var changed = isLegacy || meeting.schemaVersion < 2 || meeting.segments != original.segments
            meeting.schemaVersion = max(2, meeting.schemaVersion)
            if recoverInterrupted && [.recording, .finalizing].contains(meeting.status) {
                meeting.status = .interrupted
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.m4a").path) {
                    meeting.audioFile = "audio.m4a"
                }
                meeting.warnings.append("이전 실행이 종료되어 녹음이 중단되었습니다. 확정된 대화록과 오디오 조각은 보존되었습니다.")
                changed = true
            }
            if changed {
                let existing = try? String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
                let untouched = existing == nil || existing == TranscriptMarkdown.legacyRender(original) || existing == TranscriptMarkdown.render(original)
                // Commit the generated projection first during migration. If a
                // write fails, the legacy snapshot remains available for retry.
                if untouched {
                    try TranscriptMarkdown.render(meeting).write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
                }
                try write(StoredMeeting(meeting: meeting, directory: directory), updateTranscript: false)
            }
            // Remove the visible legacy metadata only after the current snapshot
            // and, when applicable, generated Markdown have been committed.
            if let legacyData = try? Data(contentsOf: legacy),
               let old = try? decoder.decode(Meeting.self, from: legacyData), old.id == meeting.id {
                try FileManager.default.removeItem(at: legacy)
            }
            return StoredMeeting(meeting: meeting, directory: directory)
        }.sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    public static func safeTitle(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let sanitized = title.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        let result = String(sanitized.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "회의" : result
    }

    public static func chunkURL(_ name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw StoreError.invalidFileName }
        return directory.appendingPathComponent(".audio-parts", isDirectory: true).appendingPathComponent(name)
    }
}
