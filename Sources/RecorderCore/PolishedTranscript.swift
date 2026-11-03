import CryptoKit
import Foundation

public struct PolishedEntry: Codable, Sendable, Equatable {
    public var sourceHash: String
    public var text: String
    public var model: String?
    public init(sourceHash: String, text: String, model: String? = nil) { self.sourceHash = sourceHash; self.text = text; self.model = model }
}

public struct PolishedTranscript: Codable, Sendable {
    public var version = 1
    public var model = "Qwen3.5 4B"
    public var entries: [String: PolishedEntry] = [:]
    public init() {}

    public static func sourceHash(_ paragraph: TranscriptPlaybackParagraph) -> String {
        SHA256.hash(data: Data(paragraph.text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func text(for paragraph: TranscriptPlaybackParagraph) -> String? {
        guard let entry = entries[paragraph.id.uuidString], entry.sourceHash == Self.sourceHash(paragraph) else { return nil }
        return entry.text
    }
}

public enum PolishedTranscriptStore {
    public static let fileName = "polished-transcript.json"
    public static func read(_ directory: URL) throws -> (PolishedTranscript, Data?) {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return (PolishedTranscript(), nil) }
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(PolishedTranscript.self, from: data)
        guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return (document, data)
    }
    public static func save(_ document: PolishedTranscript, directory: URL, expected: Data?) throws -> Data {
        let url = directory.appendingPathComponent(fileName)
        let existing = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        guard existing == expected else { throw CocoaError(.fileWriteFileExists) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
        return data
    }
}
