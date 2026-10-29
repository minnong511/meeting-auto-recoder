import Foundation

/// Conservative cleanup: remove recognizer noise without guessing what a speaker
/// meant. Short answers, numbers, technical terms and deliberate repeats survive.
public enum TranscriptText {
    /// Flag only extreme consecutive loops, never ordinary stutters, repeated
    /// answers at different times, or recurring technical terms.
    public static func isRepetitionLoop(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 12 else { return false }
        for width in 1...min(6, tokens.count / 12) {
            for start in 0...(tokens.count - width * 12) {
                let pattern = tokens[start..<(start + width)]
                var count = 1
                var cursor = start + width
                while cursor + width <= tokens.count,
                      tokens[cursor..<(cursor + width)].elementsEqual(pattern) {
                    count += 1
                    if count >= 12 { return true }
                    cursor += width
                }
            }
        }
        return false
    }

    public static func clean(_ text: String) -> String? {
        let printable = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(printable))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        let noiseTags: Set<String> = [
            "[음악]", "(음악)", "[박수]", "(박수)", "[잡음]", "(잡음)",
            "[무음]", "(무음)", "[침묵]", "(침묵)",
            "[music]", "(music)", "[applause]", "(applause)",
            "[noise]", "(noise)", "[silence]", "(silence)", "[inaudible]"
        ]
        guard !noiseTags.contains(normalized.lowercased()) else { return nil }
        return normalized
    }
}

public struct TranscriptSpeakerSection: Identifiable, Sendable {
    public let id: String
    public let source: AudioSource
    public let label: String
    public let paragraphs: [String]
    public var text: String { paragraphs.joined(separator: "\n\n") }
}

/// A presentation of original segments with their actual audio range. These
/// paragraphs never replace stored segments or the Markdown projection.
public struct TranscriptPlaybackParagraph: Identifiable, Sendable {
    public let id: UUID
    public let source: AudioSource
    public let speakerID: String?
    public let label: String
    public let start: Double
    public var end: Double
    public var text: String
}

public enum TranscriptDocument {
    public static func playbackParagraphs(_ meeting: Meeting) -> [TranscriptPlaybackParagraph] {
        var output: [TranscriptPlaybackParagraph] = []
        for segment in meeting.sortedSegments {
            guard let text = TranscriptText.clean(segment.text) else { continue }
            let start = segment.start.isFinite ? max(0, segment.start) : 0
            let end = max(start, segment.end.isFinite ? segment.end : start)
            if let last = output.last, last.source == segment.source,
               last.speakerID == segment.speakerID, start - last.end <= 3,
               end - last.start <= 30, last.text.count + text.count + 1 < 500 {
                output[output.count - 1].text += " " + text
                output[output.count - 1].end = max(last.end, end)
            } else {
                output.append(TranscriptPlaybackParagraph(id: segment.id, source: segment.source,
                    speakerID: segment.speakerID,
                    label: SpeakerAttribution.label(for: segment.speakerID, source: segment.source),
                    start: start, end: end, text: text))
            }
        }
        return output
    }

    public static func sections(_ meeting: Meeting) -> [TranscriptSpeakerSection] {
        let segments = meeting.sortedSegments
        // Merge only adjacent turns. Grouping all words by speaker moved later
        // fragments ahead of earlier speech and broke conversation chronology.
        var sections: [TranscriptSpeakerSection] = []
        var key: String?
        var sectionID = ""
        var source: AudioSource = .system
        var label = ""
        var paragraphs: [String] = []
        func finishSection() {
            guard !paragraphs.isEmpty else { return }
            sections.append(TranscriptSpeakerSection(id: sectionID, source: source, label: label, paragraphs: paragraphs))
        }
        for segment in segments {
            guard let text = TranscriptText.clean(segment.text) else { continue }
            let nextKey = "\(segment.source.rawValue):\(segment.speakerID ?? "unsplit")"
            if key != nextKey {
                finishSection()
                key = nextKey
                sectionID = segment.id.uuidString
                source = segment.source
                label = SpeakerAttribution.label(for: segment.speakerID, source: segment.source)
                paragraphs = []
            }
            if let last = paragraphs.last, last.count + text.count < 500 {
                paragraphs[paragraphs.count - 1] = last + " " + text
            } else { paragraphs.append(text) }
        }
        finishSection()
        return sections
    }
}
