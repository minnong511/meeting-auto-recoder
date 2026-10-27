import AppKit
import Foundation
import RecorderAudio
import RecorderCore

@MainActor
final class MeetingAppMonitor {
    var onUpdate: (([MeetingAppCandidate], String?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var refreshing = false
    private var refreshAgain = false

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await refresh() }
    }

    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let snapshot = await Self.snapshot()
        onUpdate?(snapshot, NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        refreshing = false
        if refreshAgain { refreshAgain = false; Task { await refresh() } }
    }

    static func snapshot() async -> [MeetingAppCandidate] {
        let activity = await Task.detached(priority: .utility) { AudioActivityReader.snapshot() }.value
        let applications = NSWorkspace.shared.runningApplications
        var seen = Set<String>()
        return applications.compactMap { app -> MeetingAppCandidate? in
            guard !app.isTerminated, let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
                  bundleID != "dev.meetingrecorder.prototype",
                  app.activationPolicy == .regular || MeetingAppKind.identify(bundleID) != nil,
                  seen.insert(bundleID).inserted else { return nil }
            let processes = activity.processes.filter { process in
                let processBundle = process.bundleID.isEmpty ? applications.first { $0.processIdentifier == process.processID }?.bundleIdentifier ?? "" : process.bundleID
                return process.processID == app.processIdentifier || MeetingAppKind.includes(processBundle, for: bundleID)
            }
            func active(_ values: [Bool?]) -> Bool? {
                guard activity.available else { return nil }
                if values.contains(where: { $0 == true }) { return true }
                return values.contains(where: { $0 == nil }) ? nil : false
            }
            return MeetingAppCandidate(bundleID: bundleID, name: MeetingAppKind.identify(bundleID)?.name ?? app.localizedName ?? bundleID,
                processID: app.processIdentifier, inputActive: active(processes.map(\.inputActive)), outputActive: active(processes.map(\.outputActive)))
        }.sorted {
            if ($0.kind != nil) != ($1.kind != nil) { return $0.kind != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
