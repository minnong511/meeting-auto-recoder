import Foundation

/// A positive app selection always wins, including a Slack huddle. Exclusions
/// apply to the system mix and never change what the user hears on the Mac.
public struct RecordingSoundPolicy: Sendable {
    public static let defaultMessengers = ["com.tinyspeck.slackmacgap", "com.kakao.KakaoTalkMac"]
    public static let recorderID = "dev.meetingrecorder.prototype"
    private static let systemAlertIDs = ["com.apple.notificationcenterui", "com.apple.UserNotificationCenter",
        "com.apple.UserNotificationCenterAgent", "com.apple.usernotificationsd", "com.apple.usernoted",
        "com.apple.audio.systemsoundserverd", "com.apple.systemsoundserverd", "com.apple.SafariNotificationAgent"]
    public let excludesAlerts: Bool
    public let excludedBundles: Set<String>

    public init(excludesAlerts: Bool = true, additionalApps: [String] = []) {
        self.excludesAlerts = excludesAlerts
        var ids = Set([Self.recorderID])
        if excludesAlerts { ids.formUnion(Self.systemAlertIDs + Self.defaultMessengers + additionalApps.filter { !$0.isEmpty }) }
        excludedBundles = ids
    }

    public func excludes(bundleID: String) -> Bool {
        excludedBundles.contains { MeetingAppKind.includes(bundleID, for: $0) }
    }

    public func excludesSystemService(at path: String) -> Bool {
        guard excludesAlerts else { return false }
        if path == "/usr/sbin/systemsoundserverd" { return true }
        guard path.hasPrefix("/System/Library/") else { return false }
        return ["usernotificationsd", "usernoted", "NotificationCenter", "UserNotificationCenter",
                "UserNotificationCenterAgent"].contains((path as NSString).lastPathComponent)
    }
}
