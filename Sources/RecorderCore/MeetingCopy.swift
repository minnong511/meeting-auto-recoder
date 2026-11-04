import Foundation

public enum MeetingCopy {
    /// Copy the saved Markdown, including external edits. A missing projection can be
    /// reconstructed from confirmed segments without writing to the meeting folder.
    public static func transcript(_ stored: StoredMeeting) throws -> String {
        let file = stored.directory.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: file.path) {
            return try String(contentsOf: file, encoding: .utf8)
        }
        return TranscriptMarkdown.render(stored.meeting)
    }

    public static func polished(_ stored: StoredMeeting, document: PolishedTranscript) -> String? {
        let paragraphs = TranscriptDocument.playbackParagraphs(stored.meeting)
        var hasPolishedText = false
        let lines = paragraphs.map { paragraph in
            let revised = document.text(for: paragraph)
            hasPolishedText = hasPolishedText || revised != nil
            let fallback = revised == nil ? " · 원문" : ""
            return "[\(TranscriptMarkdown.timestamp(paragraph.start))] \(paragraph.label)\(fallback)\n\(revised ?? paragraph.text)"
        }
        return hasPolishedText ? lines.joined(separator: "\n\n") : nil
    }
}
