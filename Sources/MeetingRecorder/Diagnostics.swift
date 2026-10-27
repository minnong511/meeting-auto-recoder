import AppKit
import AVFoundation
import Foundation
import RecorderAudio
import RecorderCore
@preconcurrency import UserNotifications

@MainActor
enum RecorderDiagnostics {
    static func notificationStatus() async throws -> Data {
        guard Bundle.main.bundleIdentifier != nil else { throw RecorderError.message("앱 번들에서 실행해야 합니다.") }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let delivered = await center.deliveredNotifications()
        return try JSONSerialization.data(withJSONObject: ["authorizationStatus": settings.authorizationStatus.rawValue,
            "deliveredIDs": delivered.map { $0.request.identifier }], options: [.sortedKeys])
    }

    static func captureContent() async throws -> Data {
        let content = try await CaptureService.recordingContent()
        return try JSONSerialization.data(withJSONObject: ["applicationCount": content.applications.count,
            "meetingApps": content.applications.filter { MeetingAppKind.identify($0.bundleIdentifier) != nil }.map(\.bundleIdentifier)], options: [.sortedKeys])
    }

    /// Deliberately records only one selected process, with the microphone off.
    /// Used to verify app isolation with two synthetic tone playback apps.
    static func captureApp(_ bundleID: String, root: URL) async throws -> Data {
        guard let app = await MeetingAppMonitor.snapshot().first(where: { $0.bundleID == bundleID }) else {
            throw RecordingTargetError.appUnavailable(bundleID)
        }
        let content = try await CaptureService.recordingContent()
        let filter = try CaptureService.contentFilter(content: content, target: app.target)
        let store = MeetingStore(root: root)
        var stored = try store.create(title: "앱별 오디오 수집 검증")
        stored.meeting.recordingTarget = app.target
        let capture = CaptureService(directory: stored.directory, lanes: [:], microphoneEnabled: false,
            onChunk: { _ in }, onMetrics: { _ in }, onError: { _ in })
        do {
            try await capture.start(content: content, target: app.target)
            try await Task.sleep(for: .seconds(15))
            let result = await capture.stop()
            stored.meeting.audioChunks = result.chunks
            if let error = result.error { throw RecorderError.message(error) }
            guard result.metrics.microphoneFrames == 0, result.metrics.systemFrames > 0 else {
                throw RecorderError.message("앱 오디오가 수신되지 않았거나 마이크가 포함되었습니다.")
            }
            let warnings = try await AudioExporter.export(chunks: result.chunks, directory: stored.directory)
            guard warnings.isEmpty else { throw RecorderError.message(warnings.joined(separator: "; ")) }
            stored.meeting.audioFile = "audio.m4a"
            stored.meeting.status = .completed
            stored.meeting.endedAt = Date()
            try store.save(stored)
            return try JSONSerialization.data(withJSONObject: ["directory": stored.directory.path,
                "includedBundleIDs": filter.includedApplications.map(\.bundleIdentifier),
                "systemFrames": result.metrics.systemFrames, "microphoneFrames": result.metrics.microphoneFrames], options: [.sortedKeys])
        } catch {
            let result = await capture.stop()
            stored.meeting.audioChunks = result.chunks
            stored.meeting.status = .failed
            stored.meeting.error = error.localizedDescription
            try? store.save(stored)
            throw error
        }
    }
}
