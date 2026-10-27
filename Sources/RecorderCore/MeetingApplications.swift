import Foundation

public enum MeetingAppKind: String, Codable, CaseIterable, Sendable {
    case zoom, teams, webex

    public var name: String {
        switch self { case .zoom: return "Zoom"; case .teams: return "Microsoft Teams"; case .webex: return "Webex" }
    }

    public static func identify(_ bundleID: String) -> MeetingAppKind? {
        let id = bundleID.lowercased()
        switch id {
        case "us.zoom.xos": return .zoom
        case "com.microsoft.teams", "com.microsoft.teams2": return .teams
        case "cisco-systems.spark", "com.cisco.webexmeetingsapp", "com.cisco.webex.meetings", "com.webex.meetingmanager": return .webex
        default: return nil
        }
    }

    /// Include the selected app's own helpers, never another app in the same
    /// vendor family (for example, selecting Teams Classic must not include Teams 2).
    public static func includes(_ candidate: String, for selected: String) -> Bool {
        let id = candidate.lowercased(), root = selected.lowercased()
        if id == root || id.hasPrefix(root + ".") { return true }
        let helpers: [String]
        switch root {
        case "us.zoom.xos": helpers = ["us.zoom.cpthost", "us.zoom.aomhost", "us.zoom.zoomcefhelper"]
        case "cisco-systems.spark": helpers = ["com.cisco.wme.audiowmebridge"]
        default: helpers = []
        }
        return helpers.contains { id == $0 || id.hasPrefix($0 + ".") }
    }
}

public struct RecordingTarget: Codable, Identifiable, Sendable, Equatable {
    public var id: String { bundleID ?? Self.systemID }
    public let bundleID: String?
    public let name: String
    public let processID: Int32?
    public var isSystemAudio: Bool { bundleID == nil }
    public static let systemID = "all-system-audio"
    public static let system = RecordingTarget(bundleID: nil, name: "전체 시스템 소리", processID: nil)
    public init(bundleID: String?, name: String, processID: Int32?) {
        self.bundleID = bundleID; self.name = name; self.processID = processID
    }
}

public struct ApplicationIdentity: Sendable, Equatable {
    public let bundleID: String
    public let processID: Int32
    public init(bundleID: String, processID: Int32) { self.bundleID = bundleID; self.processID = processID }
}

public enum RecordingTargetError: LocalizedError {
    case appUnavailable(String)
    public var errorDescription: String? {
        switch self {
        case .appUnavailable(let name): return "\(name) 앱을 찾지 못했습니다. 앱을 실행한 뒤 녹음 대상을 다시 선택해 주세요."
        }
    }
}

public enum RecordingTargetPolicy {
    public static func included(for target: RecordingTarget, in applications: [ApplicationIdentity]) throws -> [ApplicationIdentity] {
        guard let bundleID = target.bundleID else { return [] }
        guard let pid = target.processID, applications.contains(where: { $0.bundleID == bundleID && $0.processID == pid }) else {
            throw RecordingTargetError.appUnavailable(target.name)
        }
        return applications.filter { MeetingAppKind.includes($0.bundleID, for: bundleID) }
    }
}

public struct MeetingAppCandidate: Codable, Identifiable, Sendable, Equatable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let processID: Int32
    public let inputActive: Bool?
    public let outputActive: Bool?
    public var kind: MeetingAppKind? { MeetingAppKind.identify(bundleID) }
    public var sessionID: String { "\(bundleID):\(processID)" }
    public var target: RecordingTarget { RecordingTarget(bundleID: bundleID, name: name, processID: processID) }
    public var activityLabel: String {
        inputActive == true ? "마이크 사용 중" : (inputActive == nil ? "실행 중 · 오디오 상태 확인 불가" : "실행 중")
    }
    public init(bundleID: String, name: String, processID: Int32, inputActive: Bool? = nil, outputActive: Bool? = nil) {
        self.bundleID = bundleID; self.name = name; self.processID = processID
        self.inputActive = inputActive; self.outputActive = outputActive
    }

    public static func recommended(in apps: [MeetingAppCandidate], frontmostBundleID: String?) -> MeetingAppCandidate? {
        apps.filter { $0.kind != nil }.sorted {
            if ($0.inputActive == true) != ($1.inputActive == true) { return $0.inputActive == true }
            if ($0.bundleID == frontmostBundleID) != ($1.bundleID == frontmostBundleID) { return $0.bundleID == frontmostBundleID }
            if ($0.outputActive == true) != ($1.outputActive == true) { return $0.outputActive == true }
            return $0.bundleID < $1.bundleID
        }.first
    }
}

public struct MeetingAppEvent: Sendable {
    public enum Kind: Sendable { case launched, microphoneActive }
    public let app: MeetingAppCandidate
    public let kind: Kind
    public var title: String { kind == .microphoneActive ? "\(app.name) 마이크 사용 감지" : "\(app.name) 감지" }
    public var message: String { "\(app.activityLabel). 이 앱의 소리와 내 마이크를 녹음할 수 있습니다." }
    public func refreshed(with app: MeetingAppCandidate) -> MeetingAppEvent {
        MeetingAppEvent(app: app, kind: kind == .microphoneActive && app.inputActive == true ? .microphoneActive : .launched)
    }
}

/// Polling updates only emit a launch or a sustained input transition. An app
/// being open or holding an input stream is evidence, not proof of an active call.
public struct MeetingDetectionState: Sendable {
    private var sessions = Set<String>()
    private var inputStreak: [String: Int] = [:]
    private var announcedInput = Set<String>()
    public init() {}
    public mutating func update(_ apps: [MeetingAppCandidate]) -> [MeetingAppEvent] {
        let supported = apps.filter { $0.kind != nil }
        let current = Set(supported.map(\.sessionID))
        inputStreak = inputStreak.filter { current.contains($0.key) }
        announcedInput.formIntersection(current)
        var events: [MeetingAppEvent] = []
        for app in supported {
            let key = app.sessionID
            if !sessions.contains(key) { events.append(MeetingAppEvent(app: app, kind: .launched)) }
            if app.inputActive == true {
                inputStreak[key, default: 0] += 1
                if inputStreak[key, default: 0] >= 2 && !announcedInput.contains(key) {
                    announcedInput.insert(key)
                    events.append(MeetingAppEvent(app: app, kind: .microphoneActive))
                }
            } else if app.inputActive == false {
                inputStreak[key] = 0
                announcedInput.remove(key)
            } else {
                // An unavailable read is neither continued input evidence nor
                // proof that a call ended. Require consecutive valid samples.
                inputStreak[key] = 0
            }
        }
        sessions = current
        return events
    }
}

public struct MeetingAlertThrottle: Sendable {
    private var lastAlert: [String: TimeInterval] = [:]
    public init() {}
    public mutating func shouldNotify(_ event: MeetingAppEvent, at time: TimeInterval) -> Bool {
        if let previous = lastAlert[event.app.bundleID], time - previous < 45 { return false }
        lastAlert[event.app.bundleID] = time
        return true
    }
}
