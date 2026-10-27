import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, system
    public var label: String { self == .microphone ? "내 마이크" : "회의 소리" }
    public var speakerLabel: String { self == .microphone ? "내 발언" : "상대방 발언" }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, finalizing, completed, interrupted, failed
    public var label: String {
        switch self {
        case .recording: return "녹음 중"
        case .finalizing: return "파일 정리 중"
        case .completed: return "저장 완료"
        case .interrupted: return "녹음 중단됨"
        case .failed: return "오류 확인 필요"
        }
    }
}

public struct TranscriptSegment: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [TranscriptWord]?
    public var speakerID: String?

    public init(source: AudioSource, start: Double, end: Double, text: String) {
        id = UUID()
        self.source = source
        self.start = max(0, start.isFinite ? start : 0)
        self.end = max(self.start, end.isFinite ? end : self.start)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct AudioChunk: Codable, Sendable {
    public var fileName: String
    public var source: AudioSource
    public var offset: Double
    public var duration: Double
    public var finalized: Bool

    public init(fileName: String, source: AudioSource, offset: Double, duration: Double = 0, finalized: Bool = false) {
        self.fileName = fileName
        self.source = source
        self.offset = offset
        self.duration = duration
        self.finalized = finalized
    }
}

public struct Meeting: Codable, Identifiable, Sendable {
    public var schemaVersion = 2
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var segments: [TranscriptSegment]
    public var audioChunks: [AudioChunk]
    public var audioFile: String?
    public var warnings: [String]
    public var error: String?
    public var diarization: SpeakerDiarizationSummary?
    public var recordingTarget: RecordingTarget?
    public var transcriptionEngine: String?

    public init(title: String, date: Date = Date()) {
        id = UUID()
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "제목 없는 회의" : title
        startedAt = date
        status = .recording
        segments = []
        audioChunks = []
        warnings = []
    }

    public var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
    }

    public mutating func add(_ segment: TranscriptSegment) {
        var cleaned = segment
        cleaned.text = TranscriptText.clean(segment.text) ?? ""
        // Final results identify an audio range. A repeated final replaces that range.
        if let index = segments.firstIndex(where: { $0.source == segment.source && abs($0.start - segment.start) < 0.001 }) {
            if cleaned.text.isEmpty { segments.remove(at: index) }
            else { segments[index] = cleaned }
        } else if !cleaned.text.isEmpty {
            segments.append(cleaned)
        }
    }

    public mutating func cleanTranscript() {
        segments = segments.compactMap { segment in
            guard let text = TranscriptText.clean(segment.text) else { return nil }
            var cleaned = segment
            cleaned.text = text
            return cleaned
        }
    }
}

public enum TranscriptMarkdown {
    public static func timestamp(_ seconds: Double) -> String {
        let valid = seconds.isFinite && seconds < Double(Int.max / 2) ? max(0, seconds) : 0
        let value = Int(valid)
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }

    public static func render(_ meeting: Meeting) -> String {
        let title = meeting.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let sections = TranscriptDocument.sections(meeting).map { section in
            "## \(section.label)\n\n\(section.text)"
        }
        return (["# \(title)"] + sections).joined(separator: "\n\n") + "\n"
    }

    // Used only to recognize untouched v0.1/v0.2 files during migration. Never
    // overwrite a Markdown document that the user has edited independently.
    static func legacyRender(_ meeting: Meeting) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let header = "# \(meeting.title.replacingOccurrences(of: "\n", with: " "))\n\n- 회의 ID: \(meeting.id.uuidString)\n- 시작: \(formatter.string(from: meeting.startedAt))\n- 상태: \(meeting.status.label)\n\n## 전체 대화록\n\n"
        let body = meeting.sortedSegments.map {
            "[\(timestamp($0.start))] **\($0.source.label)**\n\n\($0.text)\n"
        }.joined(separator: "\n")
        return header + (body.isEmpty ? "확정된 전사 결과가 아직 없습니다.\n" : body)
    }
}
