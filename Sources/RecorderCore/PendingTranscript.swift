import Foundation

/// Volatile results are replacements for time ranges, not text to append.
public struct PendingTranscript: Sendable {
    public private(set) var segments: [TranscriptSegment] = []
    public init() {}

    public mutating func receive(_ segment: TranscriptSegment, final: Bool) {
        var replacement = segment
        if let previous = segments.first(where: { $0.source == segment.source && abs($0.start - segment.start) < 0.001 }) {
            replacement.id = previous.id
        }
        segments.removeAll { existing in
            guard existing.source == segment.source else { return false }
            let sameStart = abs(existing.start - segment.start) < 0.001
            let overlaps = max(existing.start, segment.start) < min(existing.end, segment.end) - 0.001
            return sameStart || overlaps
        }
        if !final, let text = TranscriptText.clean(replacement.text) {
            replacement.text = text
            segments.append(replacement)
        }
        segments.sort { $0.start < $1.start }
    }

    public func text(for source: AudioSource) -> String {
        segments.filter { $0.source == source }.map(\.text).joined(separator: " ")
    }

    public mutating func clear(source: AudioSource) { segments.removeAll { $0.source == source } }
}
