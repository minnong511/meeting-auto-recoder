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

    public static let releasesPage = URL(string: "https://github.com/minnong511/meeting-auto-recoder/tree/main/releases")!
    static let feed = URL(string: "https://raw.githubusercontent.com/minnong511/meeting-auto-recoder/main/releases/SHA256SUMS")!

    // The packaging tool adds a line only when it has produced an installable archive.
    package static func latest(in text: String) -> Self? {
        let prefix = "Meeting-Recorder-", suffix = "-macOS-arm64.zip"
        return text.split(whereSeparator: \.isNewline).compactMap { line -> Self? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0].utf8.count == 64, fields[0].allSatisfy(\.isHexDigit),
                  fields[1].hasPrefix(prefix), fields[1].hasSuffix(suffix) else { return nil }
            return Self(String(fields[1].dropFirst(prefix.count).dropLast(suffix.count)))
        }.max()
    }

    public static func fetchLatest() async throws -> Self {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 65_536,
              let text = String(data: data, encoding: .utf8), let release = latest(in: text) else {
            throw URLError(.cannotParseResponse)
        }
        return release
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
