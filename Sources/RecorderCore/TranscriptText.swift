import Foundation

/// Conservative cleanup: remove recognizer noise without guessing what a speaker
/// meant. Short answers, numbers, technical terms and deliberate repeats survive.
public enum TranscriptText {
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

public enum TranscriptDocument {
    public static func sections(_ meeting: Meeting) -> [TranscriptSpeakerSection] {
        let segments = meeting.sortedSegments
        // First appearance determines section order. Within each source, preserve
        // the original order; a repeated answer at a later time is still speech.
        var order: [String] = []
        var paragraphs: [String: [String]] = [:]
        var speakers: [String: (AudioSource, String)] = [:]
        for segment in segments {
            guard let text = TranscriptText.clean(segment.text) else { continue }
            let key = "\(segment.source.rawValue):\(segment.speakerID ?? "unsplit")"
            if paragraphs[key] == nil { order.append(key) }
            speakers[key] = (segment.source, SpeakerAttribution.label(for: segment.speakerID, source: segment.source))
            var sourceParagraphs = paragraphs[key] ?? []
            if let last = sourceParagraphs.last, last.count + text.count < 500 {
                sourceParagraphs[sourceParagraphs.count - 1] = last + " " + text
            } else { sourceParagraphs.append(text) }
            paragraphs[key] = sourceParagraphs
        }
        return order.map { key in
            TranscriptSpeakerSection(id: key, source: speakers[key]!.0, label: speakers[key]!.1, paragraphs: paragraphs[key] ?? [])
        }
    }
}
