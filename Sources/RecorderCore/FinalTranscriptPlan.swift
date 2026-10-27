import Foundation

public struct FinalTranscriptJob: Codable, Sendable {
    public let id: Int
    public let source: AudioSource
    public let start: Double
    public let end: Double
    public init(id: Int, source: AudioSource, start: Double, end: Double) {
        self.id = id; self.source = source; self.start = start; self.end = end
    }
}

public enum FinalTranscriptPlan {
    /// Split at an existing word end when possible, without spanning a change of
    /// speaker or inventing word timestamps for a model that does not provide them.
    public static func jobs(turns: [SpeakerTurn], microphone: [(Double, Double)],
                            systemDuration: Double, microphoneDuration: Double,
                            prior: [TranscriptSegment]) -> [FinalTranscriptJob] {
        let valid = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var regions: [(AudioSource, Double, Double, String)] = []
        for t in valid {
            let start = max(0, min(systemDuration, t.start)), end = max(0, min(systemDuration, t.end))
            guard end > start else { continue }
            if let last = regions.last, last.0 == .system, last.3 == t.speakerID,
               start >= last.2, start - last.2 < 0.35 {
                regions[regions.count-1].2 = end
            } else { regions.append((.system, start, end, t.speakerID)) }
        }
        for (start, end) in microphone where start.isFinite && end.isFinite {
            let lo = max(0, min(microphoneDuration, start)), hi = max(0, min(microphoneDuration, end))
            if hi > lo { regions.append((.microphone, lo, hi, "microphone")) }
        }
        var output: [FinalTranscriptJob] = []
        for (source, lo, hi, _) in regions {
            let wordEnds = prior.filter { $0.source == source }.flatMap { $0.words ?? [] }
                .map(\.end).filter { $0.isFinite }
            var cursor = lo
            while hi - cursor > 0.001 {
                var end = min(hi, cursor + 24)
                if end < hi, let boundary = wordEnds.filter({ $0 >= cursor+20 && $0 <= end }).max() { end = boundary }
                output.append(FinalTranscriptJob(id: output.count, source: source, start: cursor, end: end))
                cursor = end
            }
        }
        return output
    }

    /// Keep earlier confirmed words in speech regions the diarizer missed. This
    /// preserves short replies instead of silently deleting them in finalization.
    public static func uncovered(_ prior: [TranscriptSegment], jobs: [FinalTranscriptJob]) -> [TranscriptSegment] {
        var retained: [TranscriptSegment] = []
        for segment in prior {
            let ranges = jobs.filter { $0.source == segment.source }
            if let words = segment.words, !words.isEmpty {
                var group: TranscriptSegment?
                for word in words {
                    let middle = (word.start + word.end) / 2
                    if ranges.contains(where: { $0.start <= middle && $0.end >= middle }) {
                        if let value = group { retained.append(value); group = nil }
                    } else if group == nil {
                        group = TranscriptSegment(source: segment.source, start: word.start, end: word.end, text: word.text)
                    } else { group!.text += word.text; group!.end = word.end }
                }
                if let group { retained.append(group) }
            } else if !ranges.contains(where: { $0.start < segment.end && $0.end > segment.start }) {
                retained.append(segment)
            }
        }
        return retained
    }
}
