import Foundation

public struct TranscriptWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

public struct SpeakerTurn: Codable, Sendable {
    public let speakerID: String
    public let start: Double
    public let end: Double
    public init(speakerID: String, start: Double, end: Double) {
        self.speakerID = speakerID; self.start = start; self.end = end
    }
}

public struct SpeakerDiarizationSummary: Codable, Sendable {
    public enum State: String, Codable, Sendable { case pending, completed, failed }
    public var state: State
    public var speakerCount: Int
    public var reviewCount: Int
    public var error: String?
    public init(state: State, speakerCount: Int = 0, reviewCount: Int = 0, error: String? = nil) {
        self.state = state; self.speakerCount = speakerCount; self.reviewCount = reviewCount; self.error = error
    }
}

public enum SpeakerAttribution {
    public static let unknown = "unassigned"

    public static func label(for speakerID: String?, source: AudioSource) -> String {
        if source == .microphone { return "내 발언" }
        guard let speakerID else { return source.speakerLabel }
        guard speakerID != unknown, speakerID.hasPrefix("participant-"),
              let index = Int(speakerID.dropFirst("participant-".count)), index >= 0, index < 10_000 else {
            return "화자 확인 필요"
        }
        var number = index + 1
        var suffix = ""
        while number > 0 {
            number -= 1
            suffix = String(UnicodeScalar(65 + number % 26)!) + suffix
            number /= 26
        }
        return "화자 \(suffix)"
    }

    public static func apply(_ turns: [SpeakerTurn], to meeting: Meeting) -> Meeting {
        let valid = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.speakerID < $1.speakerID : $0.start < $1.start }
        var names: [String: String] = [:]
        for turn in valid where names[turn.speakerID] == nil { names[turn.speakerID] = "participant-\(names.count)" }

        func identify(start: Double, end: Double) -> String {
            guard start.isFinite && end.isFinite && end > start else { return unknown }
            var coverage: [String: Double] = [:]
            for turn in valid where turn.start < end && turn.end > start {
                coverage[turn.speakerID, default: 0] += min(end, turn.end) - max(start, turn.start)
            }
            let ranked = coverage.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard let best = ranked.first, best.value / (end - start) >= 0.5 else { return unknown }
            // Keep ambiguous or overlapping speech unassigned rather than
            // confidently attributing one person's words to another.
            if ranked.count > 1 && ranked[1].value > min(0.15, best.value * 0.2) { return unknown }
            return names[best.key] ?? unknown
        }

        var result = meeting
        result.segments = []
        for segment in meeting.sortedSegments {
            if segment.source == .microphone {
                var mine = segment
                mine.words = nil
                result.segments.append(mine)
                continue
            }
            if let words = segment.words, !words.isEmpty,
               TranscriptText.clean(words.map(\.text).joined()) == TranscriptText.clean(segment.text) {
                var groups: [TranscriptSegment] = []
                for word in words {
                    let speaker = identify(start: word.start, end: word.end)
                    if let last = groups.last, last.speakerID == speaker {
                        groups[groups.count - 1].text += word.text
                        groups[groups.count - 1].end = max(last.end, word.end)
                    } else {
                        var part = TranscriptSegment(source: .system, start: word.start, end: word.end, text: word.text)
                        part.text = word.text
                        part.speakerID = speaker
                        groups.append(part)
                    }
                }
                result.segments.append(contentsOf: groups)
            } else {
                // Old recordings have phrase timing only. Preserve the text;
                // do not invent word boundaries when multiple people speak.
                var part = segment
                part.words = nil
                part.speakerID = identify(start: part.start, end: part.end)
                result.segments.append(part)
            }
        }
        result.cleanTranscript()
        let system = result.segments.filter { $0.source == .system }
        let assigned = Set(system.compactMap(\.speakerID).filter { $0 != unknown })
        result.diarization = SpeakerDiarizationSummary(state: .completed, speakerCount: assigned.count,
                                                       reviewCount: system.filter { $0.speakerID == unknown }.count)
        return result
    }
}
