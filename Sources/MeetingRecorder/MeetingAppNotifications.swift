import AppKit
import RecorderCore
@preconcurrency import UserNotifications

@MainActor
final class MeetingAppNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var enabled = true
    private var allowed = false
    private var requesting = false
    private var configured = false
    private var pending: MeetingAppEvent?
    private var currentApps: [String: MeetingAppCandidate] = [:]

    func updateApps(_ apps: [MeetingAppCandidate]) {
        currentApps = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })
        if let event = pending {
            if let app = currentApps[event.app.bundleID], app.sessionID == event.app.sessionID {
                pending = event.refreshed(with: app)
            } else { pending = nil }
        }
    }

    func configure(enabled: Bool, request: Bool = true) async {
        self.enabled = enabled
        center.delegate = self
        if !enabled {
            configured = true
            pending = nil
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            onStatus?("macOS 알림 꺼짐")
            return
        }
        guard !requesting else { return }
        requesting = true
        defer { requesting = false; configured = true }
        var settings = await center.notificationSettings()
        if request && settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert]) }
            catch { onStatus?("macOS 알림 권한을 확인하지 못했습니다") }
            settings = await center.notificationSettings()
        }
        allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if self.enabled {
            onStatus?(allowed ? "macOS 알림 허용됨" : "macOS 알림은 시스템 설정에서 허용해 주세요")
            await flush()
        }
    }

    func post(_ event: MeetingAppEvent) async {
        guard enabled else { return }
        pending = event
        await refreshAuthorization()
        await flush()
    }

    func refreshAuthorization() async {
        // Do not let an initial passive activation check suppress the first
        // explicit permission request, and never show a permission prompt here.
        guard configured, enabled, !requesting else { return }
        await configure(enabled: enabled, request: false)
    }

    private func flush() async {
        guard enabled, allowed, let pendingEvent = pending else { return }
        pending = nil
        let previous = await center.deliveredNotifications()
        guard enabled, let app = currentApps[pendingEvent.app.bundleID], app.sessionID == pendingEvent.app.sessionID else { return }
        let event = pendingEvent.refreshed(with: app)
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.message + " 알림을 누르면 녹음 대상을 선택합니다."
        content.userInfo = ["bundleID": event.app.bundleID]
        content.threadIdentifier = "meeting-app-detection"
        // A local notification only: no push server, meeting title or transcript.
        let oldIDs = previous.filter { $0.request.content.userInfo["bundleID"] as? String == event.app.bundleID }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: oldIDs)
        // A new request ID allows a later call to show a fresh banner. Keep only
        // the latest delivered suggestion for each app in Notification Center.
        let request = UNNotificationRequest(identifier: "meeting-app-\(event.app.bundleID)-\(UUID().uuidString)", content: content, trigger: nil)
        do { try await center.add(request) }
        catch { onStatus?("macOS 알림을 보내지 못했습니다 · 앱 상단 알림을 확인해 주세요") }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor [weak self] in completionHandler(self?.enabled == true ? [.banner, .list] : []) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let bundleID = response.notification.request.content.userInfo["bundleID"] as? String
        Task { @MainActor [weak self] in
            if let bundleID { self?.onOpen?(bundleID) }
            completionHandler()
        }
    }
}
