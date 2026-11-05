import CryptoKit
import Darwin
import Foundation

public enum MeetingSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all, title, transcript, summary
    public var id: String { rawValue }
    public var label: String {
        switch self { case .all: return "전체"; case .title: return "제목"; case .transcript: return "대화록"; case .summary: return "요약" }
    }
}

public enum MeetingSearchSource: String, Sendable {
    case title, transcript, summary
    public var label: String {
        switch self { case .title: return "제목"; case .transcript: return "대화록"; case .summary: return "요약" }
    }
}

/// Offsets refer to the original string's UTF-16, never the normalized search text.
public struct MeetingTextRange: Hashable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

public struct MeetingSearchBlock: Identifiable, Sendable {
    public let id: String
    public let text: String
    public let paragraphID: UUID?
    public let speaker: String?
    public let start: Double?
    public let end: Double?
    public init(id: String, text: String, paragraphID: UUID? = nil, speaker: String? = nil,
                start: Double? = nil, end: Double? = nil) {
        self.id = id; self.text = text; self.paragraphID = paragraphID
        self.speaker = speaker; self.start = start; self.end = end
    }
}

public struct MeetingSearchDocument: Sendable {
    public let source: MeetingSearchSource
    public let version: String
    public let blocks: [MeetingSearchBlock]
    public let externallyEdited: Bool
    public let readError: String?
    public init(source: MeetingSearchSource, version: String, blocks: [MeetingSearchBlock],
                externallyEdited: Bool = false, readError: String? = nil) {
        self.source = source; self.version = version; self.blocks = blocks
        self.externallyEdited = externallyEdited; self.readError = readError
    }
}

public struct MeetingSearchSnapshot: Sendable {
    public let stored: StoredMeeting
    public let transcript: MeetingSearchDocument
    public let summary: MeetingSearchDocument?
    public let warnings: [String]
    public init(stored: StoredMeeting, transcript: MeetingSearchDocument,
                summary: MeetingSearchDocument?, warnings: [String] = []) {
        self.stored = stored; self.transcript = transcript; self.summary = summary; self.warnings = warnings
    }
}

public struct MeetingSearchHit: Identifiable, Sendable {
    public let id: String
    public let meetingID: UUID
    public let directory: URL
    public let title: String
    public let date: Date
    public let source: MeetingSearchSource
    public let documentVersion: String
    public let blockID: String
    public let text: String
    public let matchRanges: [MeetingTextRange]
    public let snippet: String
    public let snippetRanges: [MeetingTextRange]
    public let paragraphID: UUID?
    public let speaker: String?
    public let playbackStart: Double?

    public init(id: String, meetingID: UUID, directory: URL, title: String, date: Date,
                source: MeetingSearchSource, documentVersion: String, blockID: String, text: String,
                matchRanges: [MeetingTextRange], snippet: String, snippetRanges: [MeetingTextRange],
                paragraphID: UUID?, speaker: String?, playbackStart: Double?) {
        self.id = id; self.meetingID = meetingID; self.directory = directory; self.title = title; self.date = date
        self.source = source; self.documentVersion = documentVersion; self.blockID = blockID; self.text = text
        self.matchRanges = matchRanges; self.snippet = snippet; self.snippetRanges = snippetRanges
        self.paragraphID = paragraphID; self.speaker = speaker; self.playbackStart = playbackStart
    }
}

public struct MeetingSearchResponse: Sendable {
    public let hits: [MeetingSearchHit]
    public let meetings: [StoredMeeting]
    public let warnings: [String]
    public let totalMatches: Int
    public init(hits: [MeetingSearchHit], meetings: [StoredMeeting], warnings: [String], totalMatches: Int) {
        self.hits = hits; self.meetings = meetings; self.warnings = warnings; self.totalMatches = totalMatches
    }
}

public enum MeetingSearchError: LocalizedError {
    case rootUnavailable, documentUnavailable, changed, duplicateIdentity
    public var errorDescription: String? {
        switch self {
        case .rootUnavailable: return "저장 폴더를 읽을 수 없습니다. 위치와 접근 권한을 확인해 주세요."
        case .documentUnavailable: return "회의 문서를 읽을 수 없습니다. 파일 위치와 접근 권한을 확인해 주세요."
        case .changed: return "회의 문서가 변경되었습니다. 검색을 새로 고친 뒤 다시 선택해 주세요."
        case .duplicateIdentity: return "같은 회의 ID를 가진 폴더가 여러 개 있습니다. 중복 기록을 확인해 주세요."
        }
    }
}

public enum MeetingSearchText {
    /// Case/diacritics/width and whitespace are ignored; punctuation is retained.
    /// Each returned range still addresses complete graphemes in the source.
    public static func ranges(in text: String, query: String) -> [MeetingTextRange] {
        ranges(in: text, query: query, limit: Int.max)
    }

    fileprivate static func ranges(in text: String, query: String, limit: Int) -> [MeetingTextRange] {
        let needle = normalized(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let mapped = MappedText(text)
        return mapped.ranges(for: needle, limit: limit)
    }

    fileprivate static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }))
    }

    private struct MappedText {
        let original: String
        init(_ original: String) { self.original = original }

        func ranges(for needle: String, limit: Int) -> [MeetingTextRange] {
            let string = MeetingSearchText.normalized(original) as NSString
            var cursor = 0, matches: [NSRange] = []
            while cursor < string.length, matches.count < limit {
                let match = string.range(of: needle, options: .literal, range: NSRange(location: cursor, length: string.length - cursor))
                guard match.location != NSNotFound else { break }
                matches.append(match)
                cursor = NSMaxRange(match)
            }
            guard !matches.isEmpty else { return [] }
            // Map only requested hits while walking the source. A long unbroken
            // paragraph must not allocate two Int arrays for every UTF-16 unit.
            var output: [MeetingTextRange] = [], matchIndex = 0
            var sourceOffset = 0, foldedOffset = 0, sourceStart: Int?, count = 0
            for character in original {
                count += 1
                if count.isMultiple(of: 512), Task.isCancelled { return [] }
                let source = String(character), length = source.utf16.count
                let foldedLength = MeetingSearchText.normalized(source).utf16.count
                let foldedEnd = foldedOffset + foldedLength
                while matchIndex < matches.count {
                    let match = matches[matchIndex]
                    guard match.location < foldedEnd else { break }
                    if NSMaxRange(match) > foldedOffset {
                        if sourceStart == nil { sourceStart = sourceOffset }
                        guard NSMaxRange(match) <= foldedEnd else { break }
                        let range = MeetingTextRange(location: sourceStart!, length: sourceOffset + length - sourceStart!)
                        if output.last != range { output.append(range) }
                        sourceStart = nil
                    }
                    matchIndex += 1
                }
                sourceOffset += length; foldedOffset = foldedEnd
                if matchIndex == matches.count { break }
            }
            return output
        }
    }
}

/// Read-only, reproducible cache. No migrations, writes, model downloads, or network operations.
/// Actual bytes are re-read on refresh, including files whose size and mtime were preserved.
public actor LocalMeetingSearchIndex {
    private struct AudioSpan { let range: MeetingTextRange; let segmentID: UUID; let start: Double }
    private struct Cached {
        let metadataHash: String
        let fingerprint: String
        let snapshot: MeetingSearchSnapshot
        let title: MeetingSearchDocument
        let spans: [String: [AudioSpan]]
    }
    private var cache: [String: Cached] = [:]
    private var cacheOrder: [String] = []
    private var cacheSizes: [String: Int] = [:]
    private var normalizedCache: [String: String] = [:]
    private var normalizedOrder: [String] = []
    private var normalizedHead = 0
    private var normalizedBytes = 0
    private var identityCache: [String: UUID] = [:]
    private var cachedRoot: URL?
    public init() {}

    public func clear() {
        cache.removeAll(); cacheOrder.removeAll(); cacheSizes.removeAll()
        normalizedCache.removeAll(); normalizedOrder.removeAll(); normalizedHead = 0
        normalizedBytes = 0; identityCache.removeAll(); cachedRoot = nil
    }

    public func search(root: URL, query: String, scope: MeetingSearchScope) throws -> MeetingSearchResponse {
        let root = try checkedRoot(root)
        if cachedRoot != root { clear(); cachedRoot = root }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var loaded: [Cached] = [], warnings: [String] = [], seenPaths = Set<String>()
        for directory in directories {
            try Task.checkCancellation()
            guard hasMetadata(directory) else { continue }
            do {
                let entry = try load(root: root, directory: directory)
                loaded.append(entry); seenPaths.insert(directory.standardizedFileURL.path)
                warnings.append(contentsOf: entry.snapshot.warnings)
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("‘\(directory.lastPathComponent)’ 기록을 읽을 수 없습니다.") }
        }
        cache = cache.filter { seenPaths.contains($0.key) }
        cacheOrder.removeAll { !seenPaths.contains($0) }
        cacheSizes = cacheSizes.filter { seenPaths.contains($0.key) }
        let counts = Dictionary(grouping: loaded, by: { $0.snapshot.stored.id }).mapValues(\.count)
        if counts.values.contains(where: { $0 > 1 }) { warnings.append(MeetingSearchError.duplicateIdentity.localizedDescription) }
        loaded.removeAll { counts[$0.snapshot.stored.id, default: 0] > 1 }
        loaded.sort { $0.snapshot.stored.meeting.startedAt > $1.snapshot.stored.meeting.startedAt }

        let needle = MeetingSearchText.normalized(query)
        var hits: [MeetingSearchHit] = [], total = 0, liveKeys = Set<String>()
        for entry in loaded {
            try Task.checkCancellation()
            let documents = [entry.title, entry.snapshot.transcript] + [entry.snapshot.summary].compactMap { $0 }
            for document in documents {
                guard scope == .all || scope.rawValue == document.source.rawValue else { continue }
                for block in document.blocks {
                    try Task.checkCancellation()
                    // Normalization depends on text alone, not its meeting or
                    // document version. Identical passages share one entry.
                    let key = block.text
                    liveKeys.insert(key)
                    guard !needle.isEmpty else { continue }
                    let normalized = normalizedCache[key] ?? MeetingSearchText.normalized(block.text)
                    try Task.checkCancellation()
                    rememberNormalized(normalized, key: key)
                    guard normalized.range(of: needle, options: .literal) != nil else { continue }
                    let string = normalized as NSString
                    var cursor = 0
                    while cursor < string.length {
                        let match = string.range(of: needle, options: .literal, range: NSRange(location: cursor, length: string.length - cursor))
                        guard match.location != NSNotFound else { break }
                        total += 1; cursor = NSMaxRange(match)
                        if total.isMultiple(of: 256) { try Task.checkCancellation() }
                    }
                    guard hits.count < 200 else { continue }
                    let ranges = MeetingSearchText.ranges(in: block.text, query: query, limit: 200 - hits.count)
                    try Task.checkCancellation()
                    for range in ranges.prefix(200 - hits.count) {
                        hits.append(makeHit(entry: entry, document: document, block: block, range: range))
                    }
                }
            }
        }
        normalizedCache = normalizedCache.filter { liveKeys.contains($0.key) }
        normalizedOrder = Array(normalizedOrder[normalizedHead...]).filter { normalizedCache[$0] != nil }
        normalizedHead = 0
        normalizedBytes = normalizedCache.reduce(0) { $0 + normalizedCost(key: $1.key, text: $1.value) }
        try Task.checkCancellation()
        return MeetingSearchResponse(hits: hits, meetings: loaded.map { $0.snapshot.stored },
                                     warnings: Array(warnings.prefix(20)), totalMatches: total)
    }

    public func snapshot(root: URL, meetingID: UUID, directory: URL) throws -> MeetingSearchSnapshot {
        let root = try checkedRoot(root)
        try verifyUniqueIdentity(root: root, id: meetingID)
        let entry = try load(root: root, directory: directory)
        guard entry.snapshot.stored.id == meetingID else { throw MeetingSearchError.changed }
        return entry.snapshot
    }

    public func validate(root: URL, hit: MeetingSearchHit) throws -> (MeetingSearchSnapshot, MeetingSearchHit) {
        let root = try checkedRoot(root)
        try verifyUniqueIdentity(root: root, id: hit.meetingID)
        let entry = try load(root: root, directory: hit.directory)
        guard entry.snapshot.stored.id == hit.meetingID else { throw MeetingSearchError.changed }
        let document: MeetingSearchDocument?
        switch hit.source { case .title: document = entry.title; case .transcript: document = entry.snapshot.transcript; case .summary: document = entry.snapshot.summary }
        guard let document, document.version == hit.documentVersion, document.readError == nil,
              let block = document.blocks.first(where: { $0.id == hit.blockID }), block.text == hit.text,
              let range = hit.matchRanges.first, range.location >= 0, range.length > 0,
              range.length <= (block.text as NSString).length,
              range.location <= (block.text as NSString).length - range.length else { throw MeetingSearchError.changed }
        let verified = makeHit(entry: entry, document: document, block: block, range: range)
        guard verified.id == hit.id else { throw MeetingSearchError.changed }
        return (entry.snapshot, verified)
    }

    private func checkedRoot(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else { throw MeetingSearchError.rootUnavailable }
        return root
    }

    private func hasMetadata(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".meeting.json").path) ||
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path)
    }

    private func checkedDirectory(_ url: URL, root: URL) throws -> URL {
        let directory = url.standardizedFileURL
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true,
              directory.resolvingSymlinksInPath().deletingLastPathComponent() == root,
              FileManager.default.isReadableFile(atPath: directory.path) else { throw MeetingSearchError.documentUnavailable }
        return directory
    }

    private func verifyUniqueIdentity(root: URL, id: UUID) throws {
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var count = 0
        for candidate in directories {
            try Task.checkCancellation()
            guard let directory = try? checkedDirectory(candidate, root: root), hasMetadata(directory),
                  let bytes = try? metadata(directory) else { continue }
            let hash = digest(bytes)
            let candidateID: UUID
            if let cached = identityCache[hash] { candidateID = cached }
            else {
                guard let meeting = try? decode(bytes) else { continue }
                candidateID = meeting.id
                if identityCache.count > 10_000 { identityCache.removeAll() }
                identityCache[hash] = candidateID
            }
            if candidateID == id { count += 1 }
            if count > 1 { throw MeetingSearchError.duplicateIdentity }
        }
    }

    private func metadata(_ directory: URL) throws -> Data {
        if let bytes = try read(directory.appendingPathComponent(".meeting.json"), limit: 32 * 1_024 * 1_024, optional: true) { return bytes }
        guard let legacy = try read(directory.appendingPathComponent("metadata.json"), limit: 32 * 1_024 * 1_024, optional: false) else { throw MeetingSearchError.documentUnavailable }
        return legacy
    }

    private func decode(_ data: Data) throws -> Meeting {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var meeting = try decoder.decode(Meeting.self, from: data)
        guard meeting.startedAt.timeIntervalSince1970.isFinite,
              meeting.title.utf16.count <= 16_384,
              Set(meeting.segments.map(\.id)).count == meeting.segments.count else { throw MeetingSearchError.documentUnavailable }
        meeting.cleanTranscript()
        return meeting
    }

    private func load(root: URL, directory original: URL) throws -> Cached {
        try Task.checkCancellation()
        let directory = try checkedDirectory(original, root: root)
        let meta = try metadata(directory)
        let metaHash = digest(meta)
        let meeting: Meeting
        if let previous = cache[directory.path], previous.metadataHash == metaHash { meeting = previous.snapshot.stored.meeting }
        else { meeting = try decode(meta) }
        if identityCache.count > 10_000 { identityCache.removeAll() }
        identityCache[metaHash] = meeting.id
        let stored = StoredMeeting(meeting: meeting, directory: directory)
        var warnings: [String] = []
        let transcript: Data?, summary: Data?
        var transcriptError: String?, summaryError: String?
        do { transcript = try read(directory.appendingPathComponent("transcript.md"), limit: 16 * 1_024 * 1_024, optional: true) }
        catch is CancellationError { throw CancellationError() }
        catch { transcript = nil; transcriptError = "대화록 파일을 읽을 수 없습니다. 위치와 접근 권한을 확인해 주세요."; warnings.append("‘\(meeting.title)’ \(transcriptError!)") }
        do { summary = try read(directory.appendingPathComponent("summary.md"), limit: 16 * 1_024 * 1_024, optional: true) }
        catch is CancellationError { throw CancellationError() }
        catch { summary = nil; summaryError = "요약 파일을 읽을 수 없습니다. 위치와 접근 권한을 확인해 주세요."; warnings.append("‘\(meeting.title)’ \(summaryError!)") }
        let transcriptVersion = digest(Data((metaHash + ":transcript:" + (transcript.map(digest) ?? "missing") + (transcriptError ?? "")).utf8))
        let summaryVersion = digest(Data((metaHash + ":summary:" + (summary.map(digest) ?? "missing") + (summaryError ?? "")).utf8))
        let fingerprint = transcriptVersion + summaryVersion
        _ = try checkedDirectory(original, root: root)
        if let cached = cache[directory.path], cached.fingerprint == fingerprint { return cached }
        var spans: [String: [AudioSpan]] = [:]
        let canonical = TranscriptMarkdown.render(meeting)
        let transcriptDocument: MeetingSearchDocument
        if let transcriptError {
            transcriptDocument = MeetingSearchDocument(source: .transcript, version: transcriptVersion, blocks: [], readError: transcriptError)
        } else if let transcript, let text = String(data: transcript, encoding: .utf8), text != canonical {
            transcriptDocument = MeetingSearchDocument(source: .transcript, version: transcriptVersion,
                blocks: try textBlocks(text, version: transcriptVersion), externallyEdited: true)
        } else if transcript != nil && String(data: transcript!, encoding: .utf8) == nil {
            let error = "대화록 파일이 UTF-8 텍스트가 아닙니다."
            warnings.append("‘\(meeting.title)’ \(error)")
            transcriptDocument = MeetingSearchDocument(source: .transcript, version: transcriptVersion, blocks: [], readError: error)
        } else {
            let paragraphs = TranscriptDocument.playbackParagraphs(meeting)
            let segments = meeting.sortedSegments
            let positions = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
            let blocks = paragraphs.enumerated().map { index, paragraph -> MeetingSearchBlock in
                let first = positions[paragraph.id] ?? 0
                let next = index + 1 < paragraphs.count ? positions[paragraphs[index + 1].id] ?? segments.count : segments.count
                var offset = 0, audio: [AudioSpan] = []
                for segment in segments[first..<max(first, next)] {
                    guard let text = TranscriptText.clean(segment.text) else { continue }
                    if offset > 0 { offset += 1 }
                    let length = text.utf16.count
                    audio.append(AudioSpan(range: MeetingTextRange(location: offset, length: length), segmentID: segment.id,
                                           start: max(0, segment.start.isFinite ? segment.start : 0)))
                    offset += length
                }
                spans[paragraph.id.uuidString] = audio
                return MeetingSearchBlock(id: paragraph.id.uuidString, text: paragraph.text, paragraphID: paragraph.id,
                                          speaker: paragraph.label, start: paragraph.start, end: paragraph.end)
            }
            transcriptDocument = MeetingSearchDocument(source: .transcript, version: transcriptVersion, blocks: blocks)
        }
        let summaryDocument: MeetingSearchDocument?
        if let summaryError {
            summaryDocument = MeetingSearchDocument(source: .summary, version: summaryVersion, blocks: [], readError: summaryError)
        } else if let summary {
            if let text = String(data: summary, encoding: .utf8) {
                summaryDocument = MeetingSearchDocument(source: .summary, version: summaryVersion, blocks: try textBlocks(text, version: summaryVersion))
            } else {
                let error = "요약 파일이 UTF-8 텍스트가 아닙니다."
                warnings.append("‘\(meeting.title)’ \(error)")
                summaryDocument = MeetingSearchDocument(source: .summary, version: summaryVersion, blocks: [], readError: error)
            }
        } else { summaryDocument = nil }
        let snapshot = MeetingSearchSnapshot(stored: stored, transcript: transcriptDocument, summary: summaryDocument, warnings: warnings)
        let title = MeetingSearchDocument(source: .title, version: metaHash,
            blocks: [MeetingSearchBlock(id: "title", text: meeting.title)])
        _ = try checkedDirectory(original, root: root)
        try Task.checkCancellation()
        let cached = Cached(metadataHash: metaHash, fingerprint: fingerprint, snapshot: snapshot, title: title, spans: spans)
        remember(cached, key: directory.path)
        return cached
    }

    /// Refuse symlinks and non-regular files, bound allocations, and detect a
    /// changed inode rather than reading a different destination mid-refresh.
    private func read(_ url: URL, limit: Int, optional: Bool) throws -> Data? {
        try Task.checkCancellation()
        var before = stat()
        if lstat(url.path, &before) != 0 {
            if optional && errno == ENOENT { return nil }
            throw MeetingSearchError.documentUnavailable
        }
        guard (before.st_mode & S_IFMT) == S_IFREG, before.st_size >= 0, before.st_size <= limit,
              FileManager.default.isReadableFile(atPath: url.path) else { throw MeetingSearchError.documentUnavailable }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw MeetingSearchError.documentUnavailable }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
              (opened.st_mode & S_IFMT) == S_IFREG else { throw MeetingSearchError.documentUnavailable }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw MeetingSearchError.documentUnavailable }
            guard output.count <= limit - count else { throw MeetingSearchError.documentUnavailable }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard lstat(url.path, &after) == 0, after.st_ino == opened.st_ino, after.st_dev == opened.st_dev,
              after.st_size == output.count, after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else { throw MeetingSearchError.changed }
        return output
    }

    private func textBlocks(_ text: String, version: String) throws -> [MeetingSearchBlock] {
        // Split on natural paragraph boundaries only. Splitting at an arbitrary
        // length can hide a word spanning the boundary. The read limit bounds
        // the file, and identifiers bind source ranges to a content version.
        var blocks: [MeetingSearchBlock] = [], buffer = "", offset = 0, start = 0, length = 0
        var previousWasNewline = false
        func flush() {
            guard !buffer.isEmpty else { return }
            let id = digest(Data((version + ":" + String(start) + ":" + String(length)).utf8))
            blocks.append(MeetingSearchBlock(id: id, text: buffer)); buffer = ""; start = offset; length = 0
        }
        for character in text {
            if offset.isMultiple(of: 512) { try Task.checkCancellation() }
            let part = String(character), count = part.utf16.count
            buffer += part; offset += count; length += count
            let newline = character == "\n" || character == "\r\n"
            if newline && previousWasNewline { flush() }
            previousWasNewline = newline
        }
        flush()
        return blocks
    }

    private func remember(_ entry: Cached, key: String) {
        cacheOrder.removeAll { $0 == key }
        cache[key] = entry; cacheOrder.append(key)
        let snapshot = entry.snapshot
        let textBytes = snapshot.transcript.blocks.reduce(0) { $0 + $1.text.utf8.count } +
            (snapshot.summary?.blocks.reduce(0) { $0 + $1.text.utf8.count } ?? 0)
        let segmentBytes = snapshot.stored.meeting.segments.reduce(0) { $0 + $1.text.utf8.count + 256 }
        cacheSizes[key] = textBytes + segmentBytes + snapshot.transcript.blocks.count * 160 + 2_048
        var bytes = cacheSizes.values.reduce(0, +)
        while bytes > 128 * 1_024 * 1_024, let oldest = cacheOrder.first {
            cacheOrder.removeFirst(); cache.removeValue(forKey: oldest)
            bytes -= cacheSizes.removeValue(forKey: oldest) ?? 0
        }
    }

    private func rememberNormalized(_ text: String, key: String) {
        guard normalizedCache[key] == nil else { return }
        let count = normalizedCost(key: key, text: text)
        guard count <= 96 * 1_024 * 1_024 else { return }
        normalizedCache[key] = text; normalizedOrder.append(key); normalizedBytes += count
        while normalizedBytes > 96 * 1_024 * 1_024, normalizedHead < normalizedOrder.count {
            let oldest = normalizedOrder[normalizedHead]
            normalizedHead += 1
            if let value = normalizedCache.removeValue(forKey: oldest) {
                normalizedBytes -= normalizedCost(key: oldest, text: value)
            }
        }
        if normalizedHead > 4_096, normalizedHead > normalizedOrder.count / 2 {
            normalizedOrder.removeFirst(normalizedHead)
            normalizedHead = 0
        }
    }

    private func normalizedCost(key: String, text: String) -> Int {
        // Include both retained strings and conservative hash-entry/queue costs.
        key.utf8.count + text.utf8.count + 160
    }

    private func makeHit(entry: Cached, document: MeetingSearchDocument, block: MeetingSearchBlock,
                         range: MeetingTextRange) -> MeetingSearchHit {
        let stored = entry.snapshot.stored
        let audio = entry.spans[block.id]?.first { NSIntersectionRange($0.range.nsRange, range.nsRange).length > 0 }
        let start = document.source == .transcript && !document.externallyEdited && hasPlayableAudio(stored) ? audio?.start : nil
        let id = digest(Data((stored.id.uuidString + ":" + document.source.rawValue + ":" + document.version + ":" + block.id + ":\(range.location):\(range.length)").utf8))
        let string = block.text as NSString
        let left = max(0, range.location - 55), right = min(string.length, NSMaxRange(range.nsRange) + 90)
        let context = string.rangeOfComposedCharacterSequences(for: NSRange(location: left, length: right - left))
        let prefix = context.location > 0 ? "…" : ""
        let suffix = NSMaxRange(context) < string.length ? "…" : ""
        let snippet = prefix + string.substring(with: context) + suffix
        let snippetRange = MeetingTextRange(location: range.location - context.location + prefix.utf16.count, length: range.length)
        return MeetingSearchHit(id: id, meetingID: stored.id, directory: stored.directory, title: stored.meeting.title,
            date: stored.meeting.startedAt, source: document.source, documentVersion: document.version,
            blockID: block.id, text: block.text, matchRanges: [range], snippet: snippet, snippetRanges: [snippetRange],
            paragraphID: block.paragraphID, speaker: block.speaker, playbackStart: start)
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func hasPlayableAudio(_ stored: StoredMeeting) -> Bool {
        guard let audio = stored.audioURL,
              audio.standardizedFileURL.deletingLastPathComponent() == stored.directory.standardizedFileURL,
              audio.resolvingSymlinksInPath().deletingLastPathComponent() == stored.directory.resolvingSymlinksInPath(),
              FileManager.default.isReadableFile(atPath: audio.path) else { return false }
        var info = stat()
        return lstat(audio.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}
