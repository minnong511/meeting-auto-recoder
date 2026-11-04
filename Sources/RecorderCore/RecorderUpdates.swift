import Combine
import Foundation

public struct RecorderRelease: Comparable, Sendable, CustomStringConvertible {
    private let parts: [Int]
    public let description: String

    public init?(_ text: String) {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ field in
            (1...9).contains(field.utf8.count) && (field.count == 1 || field.first != "0") &&
                field.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        parts = fields.compactMap { Int($0) }
        description = text
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }

    public static let releasesPage = URL(string: "https://github.com/minnong511/meeting-auto-recoder/releases/latest")!
    private static let raw = URL(string: "https://raw.githubusercontent.com/minnong511/meeting-auto-recoder")!
    public var archiveName: String { "Meeting-Recorder-\(description)-macOS-arm64.zip" }
    public var releasePage: URL { Self.releasesPage.deletingLastPathComponent().appendingPathComponent("tag/v" + description) }
    public var downloadURL: URL {
        Self.releasesPage.deletingLastPathComponent().appendingPathComponent("download/v" + description + "/" + archiveName)
    }

    package static func published(at url: URL) -> Self? {
        let tag = url.lastPathComponent
        guard url.scheme == "https", url.host == "github.com", tag.hasPrefix("v"),
              url.deletingLastPathComponent().path == "/minnong511/meeting-auto-recoder/releases/tag" else { return nil }
        return Self(String(tag.dropFirst()))
    }

    package func checksum(in text: String) -> String? {
        let rows = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { $0.count == 2 && $0[1] == archiveName }
        guard rows.count == 1, let digest = rows.first?.first, digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return digest.lowercased()
    }

    private static func index(ref: String) async throws -> String {
        let url = raw.appendingPathComponent(ref + "/releases/SHA256SUMS")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 65_536,
              let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        return text
    }

    public static func fetchLatest() async throws -> Self {
        // The public Latest redirect excludes drafts and prereleases without an API key.
        var request = URLRequest(url: releasesPage, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, let release = published(at: url) else { throw URLError(.cannotParseResponse) }
        return release
    }

    package func fetchChecksum() async throws -> String {
        guard let digest = checksum(in: try await Self.index(ref: "v" + description)) else { throw URLError(.cannotParseResponse) }
        return digest
    }
}

@MainActor
public final class RecorderUpdates: ObservableObject {
    public let installed: RecorderRelease?
    @Published public private(set) var enabled: Bool
    @Published public private(set) var latest: RecorderRelease?
    @Published public private(set) var isChecking = false
    @Published public private(set) var failed = false
    @Published private var dismissed: String?
    public var onNewRelease: ((RecorderRelease) async -> Void)?

    private let defaults: UserDefaults
    private let fetch: () async throws -> RecorderRelease
    private let now: () -> Date
    private let interval: TimeInterval = 24 * 60 * 60
    private var timer: Task<Void, Never>?
    private var started = false

    public init(installedVersion: String, defaults: UserDefaults = .standard,
                now: @escaping () -> Date = Date.init,
                fetch: @escaping () async throws -> RecorderRelease = RecorderRelease.fetchLatest) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        installed = RecorderRelease(installedVersion)
        enabled = defaults.object(forKey: "releaseAlertsEnabled") as? Bool ?? true
        latest = defaults.string(forKey: "latestPublicRelease").flatMap(RecorderRelease.init)
        dismissed = defaults.string(forKey: "dismissedRelease")
    }

    public var available: RecorderRelease? {
        guard let latest, let installed, latest > installed else { return nil }
        return latest
    }

    public var banner: RecorderRelease? {
        guard enabled, let available, available.description != dismissed else { return nil }
        return available
    }

    public func dismiss(_ release: RecorderRelease) {
        dismissed = release.description
        defaults.set(release.description, forKey: "dismissedRelease")
    }

    public func start() {
        guard !started else { return }
        started = true
        schedule()
    }

    public func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: "releaseAlertsEnabled")
        if started { schedule() }
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        guard enabled else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let delay: TimeInterval
                do {
                    guard let self else { return }
                    await self.check()
                    let elapsed = self.now().timeIntervalSince(self.lastAttempt ?? self.now())
                    delay = max(1, self.interval - max(0, elapsed))
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private var lastAttempt: Date? { defaults.object(forKey: "publicReleaseLastAttempt") as? Date }

    public func check(manual: Bool = false) async {
        guard installed != nil, !isChecking, manual || enabled else { return }
        let date = now()
        if !manual, let lastAttempt, (0..<interval).contains(date.timeIntervalSince(lastAttempt)) { return }
        defaults.set(date, forKey: "publicReleaseLastAttempt")
        isChecking = true
        failed = false
        defer { isChecking = false }
        do {
            let release = try await fetch()
            try Task.checkCancellation()
            latest = release
            defaults.set(release.description, forKey: "latestPublicRelease")
            guard enabled, banner == release, let onNewRelease,
                  defaults.string(forKey: "announcedPublicRelease") != release.description else { return }
            defaults.set(release.description, forKey: "announcedPublicRelease")
            await onNewRelease(release)
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    deinit { timer?.cancel() }
}
