import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers
import RecorderAudio
import RecorderCore

@MainActor
final class RecorderModel: ObservableObject {
    enum Phase { case idle, preparing, recording, stopping }
    @Published var phase: Phase = .idle
    @Published var meetings: [StoredMeeting] = []
    @Published var selectedID: UUID?
    @Published var title = ""
    @Published var statusText = "녹음할 준비가 되었습니다"
    @Published var supportText = SpeechSupport.supportLabel
    @Published private(set) var speechModel: SpeechModel = .recommended
    @Published var errorMessage: String?
    @Published var metrics = CaptureMetrics()
    @Published var pendingTranscript = PendingTranscript()
    @Published var latestConfirmed: [AudioSource: TranscriptSegment] = [:]
    @Published var transcriptRevision = 0
    @Published private(set) var summaryText: String?
    @Published var showsSettings = false
    @Published var settingsPage = RecorderSettingsPage.general
    let updates = RecorderUpdates(installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    @Published private(set) var polished = PolishedTranscript()
    @Published private(set) var polishedMeetingID: UUID?
    private(set) var hasPolishedText = false
    @Published private(set) var isPolishing = false
    @Published private(set) var polishProgress = ""
    @Published private(set) var localModels: [LocalTranscriptPolisher.Model] = []
    @Published private(set) var selectedLocalModel = "qwen3.5:4b"
    private var polishTask: Task<Void, Never>?
    @Published private(set) var clipboardMessage = ""
    @Published private(set) var isCopyNoticeVisible = false
    @Published private(set) var mcpClients: [MCPClientConnection] = []
    @Published private(set) var mcpPresenceAvailable = true
    @Published private(set) var isCheckingMCP = false
    @Published private(set) var mcpDiagnostic: MCPDiagnosticResult?
    private let pasteboard: NSPasteboard
    private var copyNoticeTask: Task<Void, Never>?
    private var summaryStamp: Date?
    private var summaryFile: URL?
    @Published private(set) var excludesNotificationSounds = true
    @Published private(set) var additionalQuietApps: [String] = []
    @Published private(set) var microphoneFanSuppression = false
    @Published private(set) var microphoneEnabled = true
    @Published private(set) var isUpdatingMicrophone = false
    @Published private(set) var isSeparatingSpeakers = false
    @Published var root: URL?
    @Published var activeStartedAt: Date?
    @Published private(set) var availableApps: [MeetingAppCandidate] = []
    @Published private(set) var selectedTargetID = ""
    @Published private(set) var meetingSuggestion: MeetingAppEvent?
    @Published private(set) var meetingNotificationsEnabled = true
    @Published private(set) var recordingIslandEnabled = true
    @Published private(set) var notificationStatus = "macOS 알림 확인 전"
    @Published private(set) var activeTarget: RecordingTarget?
    private var current: StoredMeeting?
    private var capture: CaptureService?
    private var lanes: [AudioSource: SpeechLane] = [:]
    private var startTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var recordingLimit: Double?
    private var warnedSources = Set<AudioSource>()
    private var speakerTask: Task<Meeting, Error>?
    private var isQuitting = false
    private let appMonitor = MeetingAppMonitor()
    private lazy var appNotifications = MeetingAppNotifications()
    private var detectionState = MeetingDetectionState()
    private var alertThrottle = MeetingAlertThrottle()
    private var monitoringStarted = false
    private var automaticallySelectTarget = true
    private var handledTargetExit = false

    var isBusy: Bool { phase != .idle || isPolishing }
    var selected: StoredMeeting? { meetings.first { $0.id == selectedID } }
    var selectedIsActive: Bool { current?.id == selectedID && isBusy }
    var recordingTarget: RecordingTarget? {
        guard !selectedTargetID.isEmpty else { return nil }
        return selectedTargetID == RecordingTarget.systemID ? .system : availableApps.first { $0.id == selectedTargetID }?.target
    }
    var canBegin: Bool { !isQuitting && !isBusy && recordingTarget != nil }
    var detectedMeetingApps: [MeetingAppCandidate] { availableApps.filter { $0.kind != nil } }

    func canDeleteMeeting(_ stored: StoredMeeting) -> Bool {
        !isBusy && stored.meeting.status != .recording && stored.meeting.status != .finalizing
    }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        excludesNotificationSounds = UserDefaults.standard.object(forKey: "excludesNotificationSounds") as? Bool ?? true
        additionalQuietApps = UserDefaults.standard.stringArray(forKey: "additionalQuietApps") ?? []
        if UserDefaults.standard.object(forKey: "recordingIslandEnabled") != nil {
            recordingIslandEnabled = UserDefaults.standard.bool(forKey: "recordingIslandEnabled")
        }
        speechModel = UserDefaults.standard.string(forKey: "speechModel").flatMap(SpeechModel.init(rawValue:)) ?? .recommended
        selectedLocalModel = UserDefaults.standard.string(forKey: "localPolishModel") ?? "qwen3.5:4b"
        refreshLocalModels()
        if let saved = UserDefaults.standard.string(forKey: "recordingTargetID") {
            selectedTargetID = saved
            automaticallySelectTarget = false
        }
        if UserDefaults.standard.object(forKey: "meetingAppNotifications") != nil {
            meetingNotificationsEnabled = UserDefaults.standard.bool(forKey: "meetingAppNotifications")
        }
        if UserDefaults.standard.object(forKey: "microphoneFanSuppression") != nil {
            microphoneFanSuppression = UserDefaults.standard.bool(forKey: "microphoneFanSuppression")
        }
        if UserDefaults.standard.object(forKey: "includeMicrophone") != nil {
            microphoneEnabled = UserDefaults.standard.bool(forKey: "includeMicrophone")
        }
        if let path = UserDefaults.standard.string(forKey: "recordingFolder") {
            root = URL(fileURLWithPath: path, isDirectory: true)
            reload(recover: true)
        }
    }

    func startMeetingMonitoring() {
        guard !monitoringStarted else { return }
        monitoringStarted = true
        appMonitor.onUpdate = { [weak self] apps, frontmost in self?.receiveApps(apps, frontmost: frontmost) }
        appNotifications.onStatus = { [weak self] in self?.notificationStatus = $0 }
        appNotifications.onOpen = { [weak self] bundleID in
            guard let self else { return }
            if !self.isBusy && self.availableApps.contains(where: { $0.id == bundleID }) { self.selectTarget(bundleID) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        appNotifications.onOpenRelease = { [weak self] version in
            guard let self, self.updates.enabled, self.updates.available?.description == version else { return }
            NSWorkspace.shared.open(RecorderRelease.releasesPage)
        }
        updates.onNewRelease = { [weak self] release in
            guard let self, !self.isBusy, !NSApp.isActive else { return }
            await self.appNotifications.postUpdate(release)
        }
        appMonitor.start()
        Task {
            await appNotifications.configure(enabled: meetingNotificationsEnabled, updatesEnabled: updates.enabled)
            updates.start()
        }
    }

    func refreshMeetingApps() { Task { await appMonitor.refresh() } }
    func refreshLocalModels() { localModels = LocalTranscriptPolisher.installedModels() }
    func selectLocalModel(_ id: String) {
        guard !isPolishing, localModels.contains(where: { $0.id == id }) else { return }
        selectedLocalModel = id
        UserDefaults.standard.set(id, forKey: "localPolishModel")
    }
    func refreshNotificationPermission() { Task { await appNotifications.refreshAuthorization() } }

    func automaticallyChooseMeetingApp() {
        guard !isBusy else { return }
        automaticallySelectTarget = true
        UserDefaults.standard.removeObject(forKey: "recordingTargetID")
        refreshMeetingApps()
    }

    func selectTarget(_ id: String) {
        guard !isBusy else { return }
        selectedTargetID = id
        automaticallySelectTarget = false
        UserDefaults.standard.set(id, forKey: "recordingTargetID")
    }

    func setMeetingNotifications(_ enabled: Bool) {
        meetingNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "meetingAppNotifications")
        Task { await appNotifications.configure(enabled: meetingNotificationsEnabled, updatesEnabled: updates.enabled) }
    }

    func setUpdateNotifications(_ enabled: Bool) {
        updates.setEnabled(enabled)
        Task { await appNotifications.configure(enabled: meetingNotificationsEnabled, updatesEnabled: updates.enabled) }
    }

    func openSettings(_ page: RecorderSettingsPage) {
        settingsPage = page
        showsSettings = true
    }

    func showUpdateSettings() {
        openSettings(.general)
        Task { await updates.check(manual: true) }
    }

    func setRecordingIslandEnabled(_ enabled: Bool) {
        recordingIslandEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "recordingIslandEnabled")
    }

    func dismissMeetingSuggestion() { meetingSuggestion = nil }

    func begin(in app: MeetingAppCandidate) {
        selectTarget(app.id)
        begin()
    }

    private func receiveApps(_ apps: [MeetingAppCandidate], frontmost: String?) {
        availableApps = apps
        appNotifications.updateApps(apps)
        if !isBusy && automaticallySelectTarget {
            selectedTargetID = MeetingAppCandidate.recommended(in: apps, frontmostBundleID: frontmost)?.id ?? ""
        }
        if let activeTarget, let bundleID = activeTarget.bundleID, !handledTargetExit,
           !apps.contains(where: { $0.bundleID == bundleID && $0.processID == activeTarget.processID }) {
            if phase == .preparing { handledTargetExit = true; startTask?.cancel() }
            else if phase == .recording {
                handledTargetExit = true
                current?.meeting.warnings.append("녹음 대상 \(activeTarget.name) 앱이 종료되어 녹음을 마무리했습니다.")
                Task { await stop() }
            }
        }
        if let suggestion = meetingSuggestion {
            if let app = apps.first(where: { $0.sessionID == suggestion.app.sessionID }) {
                meetingSuggestion = suggestion.refreshed(with: app)
            } else { meetingSuggestion = nil }
        }
        let events = detectionState.update(apps)
        guard !isBusy, !events.isEmpty else { return }
        let recommended = MeetingAppCandidate.recommended(in: events.map(\.app), frontmostBundleID: frontmost)
        if let event = events.last(where: { $0.app.sessionID == recommended?.sessionID }) {
            meetingSuggestion = event
            if meetingNotificationsEnabled && alertThrottle.shouldNotify(event, at: ProcessInfo.processInfo.systemUptime) {
                Task { await appNotifications.post(event) }
            }
        }
    }

    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "회의 파일을 저장할 폴더를 선택하세요"
        panel.prompt = "저장 폴더 선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            root = url
            mcpDiagnostic = nil
            UserDefaults.standard.set(url.path, forKey: "recordingFolder")
            reload(recover: true)
        }
    }

    func checkSupport() async {
        supportText = "음성 인식 모델 확인 중…"
        let selected = speechModel
        let result = await SpeechSupport.inspect(model: selected)
        guard selected == speechModel else { return }
        supportText = result.koreanInstalled ? selected.supportLabel : "\(selected.displayName) · 첫 녹음 시 다운로드 (\(selected.downloadDescription))"
    }

    func setExcludesNotificationSounds(_ value: Bool) {
        guard !isBusy else { return }
        excludesNotificationSounds = value
        UserDefaults.standard.set(value, forKey: "excludesNotificationSounds")
    }

    func addQuietApp() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "추가"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        guard !isBusy, !RecordingSoundPolicy(additionalApps: additionalQuietApps).excludes(bundleID: id) else { return }
        additionalQuietApps.append(id)
        UserDefaults.standard.set(additionalQuietApps, forKey: "additionalQuietApps")
    }

    func removeQuietApp(_ id: String) {
        guard !isBusy else { return }
        additionalQuietApps.removeAll { $0 == id }
        UserDefaults.standard.set(additionalQuietApps, forKey: "additionalQuietApps")
    }

    func setMicrophoneFanSuppression(_ enabled: Bool) {
        guard !isBusy else { return }
        microphoneFanSuppression = enabled
        UserDefaults.standard.set(enabled, forKey: "microphoneFanSuppression")
    }

    func selectSpeechModel(_ model: SpeechModel) {
        guard !isBusy else { return }
        speechModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "speechModel")
        Task { await checkSupport() }
    }

    func begin() {
        begin(limit: nil)
    }

    func beginTest() {
        begin(limit: 15)
    }

    private func begin(limit: Double?) {
        guard !isQuitting, !isBusy else { return }
        guard let target = recordingTarget else { errorMessage = "녹음할 앱을 먼저 선택해 주세요."; return }
        if root == nil { chooseFolder() }
        guard root != nil else { return }
        phase = .preparing
        errorMessage = nil
        metrics = CaptureMetrics()
        pendingTranscript = PendingTranscript()
        latestConfirmed = [:]
        warnedSources = []
        recordingLimit = limit
        activeTarget = target
        handledTargetExit = false
        meetingSuggestion = nil
        startTask = Task { await startRecording() }
    }

    private func startRecording() async {
        var recordingModel = speechModel
        do {
            statusText = "마이크 권한 확인 중…"
            if microphoneEnabled {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else { throw RecorderError.message("마이크 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 이 앱을 허용하거나 마이크 녹음을 꺼 주세요.") }
            }
            try Task.checkCancellation()
            statusText = "녹음 대상 확인 중…"
            guard let target = activeTarget else { throw RecorderError.message("녹음할 앱을 선택해 주세요.") }
            try CaptureService.validateTarget(target)
            try Task.checkCancellation()
            statusText = "음성 인식 모델 준비 중…"
            let progress: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard self?.phase == .preparing else { return }
                    self?.statusText = message
                }
            }
            let segmentation: SpeechSegmentation
            var modelWarning: String?
            do {
                segmentation = try await SpeechLane.prepareAssets(model: recordingModel, allowEnergyFallback: true, progress: progress)
            } catch {
                try Task.checkCancellation()
                // An offline upgrade can still use the previously cached model. Respect an explicit choice.
                guard recordingModel == .recommended, UserDefaults.standard.string(forKey: "speechModel") == nil else { throw error }
                var cached: SpeechModel?
                for candidate in [SpeechModel.largeV3, .largeV3Turbo] where candidate != recordingModel {
                    if await SpeechSupport.inspect(model: candidate).koreanInstalled { cached = candidate; break }
                }
                guard let cached else { throw error }
                recordingModel = cached
                modelWarning = "권장 모델을 준비하지 못해 이 Mac에 설치된 \(cached.displayName)로 전사했습니다."
                segmentation = try await SpeechLane.prepareAssets(model: recordingModel, allowEnergyFallback: true, progress: progress)
            }
            // Prepare the microphone lane once; the microphone can be re-enabled during a meeting.
            var microphoneFilter: MicrophoneNoiseFilter?
            var filterWarning: String?
            if microphoneFanSuppression && recordingModel == .largeV3Metal && segmentation == .voiceActivity {
                statusText = "마이크 팬 소음 억제 모델 준비 중…"
                do { microphoneFilter = try await MicrophoneNoiseFilter.prepare() }
                catch {
                    try Task.checkCancellation()
                    filterWarning = "팬 소음 억제 모델을 준비하지 못해 마이크 원음으로 전사했습니다. " + error.localizedDescription
                }
            }
            try Task.checkCancellation()
            guard let root else { throw RecorderError.message("저장 폴더를 선택해 주세요.") }
            let stored = try MeetingStore(root: root).create(title: title)
            current = stored
            current?.meeting.recordingTarget = target
            current?.meeting.transcriptionEngine = recordingModel.engineDescription + " · " + segmentation.rawValue
                + (microphoneFilter == nil ? "" : " · mic LocalVQE 1.3 50%")
            if let filterWarning { current?.meeting.warnings.append(filterWarning) }
            if let modelWarning { current?.meeting.warnings.append(modelWarning) }
            if segmentation == .energy {
                current?.meeting.warnings.append("말소리 감지 모델을 준비하지 못해 이번 녹음에는 음량 기준 감지를 사용했습니다.")
            }
            selectedID = stored.id
            updateList(stored)
            for source in AudioSource.allCases {
                let lane = try await SpeechLane.create(source: source, segmentation: segmentation,
                    microphoneNoiseFilter: source == .microphone ? microphoneFilter : nil, onResult: { [weak self] segment, final in
                    self?.receive(segment, final: final, meetingID: stored.id)
                }, onError: { [weak self] error in
                    Task { @MainActor in self?.transcriptionFailed(source: source, error: error, meetingID: stored.id) }
                }, onWarning: { [weak self] warning in
                    guard self?.current?.id == stored.id else { return }
                    self?.current?.meeting.warnings.append(warning)
                    self?.persist()
                })
                lanes[source] = lane
            }
            try Task.checkCancellation()
            let capture = CaptureService(directory: stored.directory, lanes: lanes, microphoneEnabled: microphoneEnabled,
                soundPolicy: RecordingSoundPolicy(excludesAlerts: excludesNotificationSounds, additionalApps: additionalQuietApps),
                onChunk: { [weak self] chunk in Task { @MainActor in self?.receive(chunk, meetingID: stored.id) } },
                onMetrics: { [weak self] metrics in Task { @MainActor in self?.metrics = metrics } },
                onError: { [weak self] error in Task { @MainActor in await self?.captureFailed(error, meetingID: stored.id) } })
            self.capture = capture
            statusText = "\(target.name) 소리 연결 중…"
            // The audio tap rechecks the selected process immediately before attaching.
            try await capture.start(target: target)
            try Task.checkCancellation()
            activeStartedAt = Date()
            phase = .recording
            statusText = "\(target.name) 녹음·실시간 전사 중"
            supportText = recordingModel.supportLabel
            if let limit = recordingLimit {
                autoStopTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(limit)) } catch { return }
                    self?.autoStopTask = nil
                    await self?.stop()
                }
            }
        } catch {
            if let capture { _ = await capture.stop() }
            capture = nil
            for lane in lanes.values { await lane.cancel() }
            lanes = [:]
            if var stored = current {
                stored.meeting.status = .failed
                stored.meeting.endedAt = Date()
                stored.meeting.error = error.localizedDescription
                current = stored
                persist()
            }
            await releaseTranscriber()
            phase = .idle
            statusText = error is CancellationError ? "준비를 취소했습니다" : "녹음을 시작하지 못했습니다"
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            current = nil
            activeTarget = nil
        }
    }

    private func receive(_ segment: TranscriptSegment, final: Bool, meetingID: UUID) {
        guard var stored = current, stored.id == meetingID else { return }
        pendingTranscript.receive(segment, final: final)
        if !final && segment.source == .microphone && !microphoneEnabled {
            pendingTranscript.clear(source: .microphone)
            return
        }
        transcriptRevision += 1
        if final {
            stored.meeting.add(segment)
            current = stored
            if let text = TranscriptText.clean(segment.text) {
                var cleaned = segment
                cleaned.text = text
                latestConfirmed[segment.source] = cleaned
            }
            persist()
        }
    }

    private func receive(_ chunk: AudioChunk, meetingID: UUID) {
        guard phase == .recording || phase == .preparing, var stored = current, stored.id == meetingID else { return }
        if let index = stored.meeting.audioChunks.firstIndex(where: { $0.fileName == chunk.fileName }) {
            stored.meeting.audioChunks[index] = chunk
        } else { stored.meeting.audioChunks.append(chunk) }
        current = stored
        persist()
    }

    private func transcriptionFailed(source: AudioSource, error: String, meetingID: UUID) {
        guard current?.id == meetingID, !warnedSources.contains(source) else { return }
        warnedSources.insert(source)
        current?.meeting.warnings.append("\(source.label) 전사 중단: \(error). 음성 녹음은 계속됩니다.")
        pendingTranscript.clear(source: source)
        persist()
        statusText = "녹음 중 · 일부 전사 오류가 있어 종료 후 확인이 필요합니다"
    }

    private func captureFailed(_ error: String, meetingID: UUID) async {
        guard current?.id == meetingID, phase == .recording else { return }
        await stop()
        errorMessage = error
    }

    func setMicrophoneEnabled(_ enabled: Bool) async {
        guard !isUpdatingMicrophone, phase == .idle || phase == .recording else { return }
        if enabled == microphoneEnabled { return }
        if phase == .idle {
            microphoneEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "includeMicrophone")
            return
        }
        guard let capture, let meetingID = current?.id else { return }
        isUpdatingMicrophone = true
        defer { isUpdatingMicrophone = false }
        do {
            if enabled {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw RecorderError.message("마이크를 켜려면 시스템 설정에서 이 앱의 마이크 권한을 허용해 주세요.")
                }
            }
            guard phase == .recording, current?.id == meetingID else { return }
            try await capture.setMicrophoneEnabled(enabled)
            guard phase == .recording, current?.id == meetingID else { return }
            microphoneEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "includeMicrophone")
            if !enabled {
                try await lanes[.microphone]?.finalizePending()
                pendingTranscript.clear(source: .microphone)
                transcriptRevision += 1
            }
        } catch {
            guard current?.id == meetingID, phase == .recording else { return }
            if !enabled {
                // The sample gate is already closed. End capture if the OS could
                // not release the microphone instead of claiming it is disabled.
                microphoneEnabled = false
                await stop()
            }
            errorMessage = "마이크 설정 변경 실패: \(error.localizedDescription)"
        }
    }

    func stop() async {
        if phase == .preparing {
            startTask?.cancel()
            await startTask?.value
            return
        }
        guard phase == .recording else { return }
        autoStopTask?.cancel()
        autoStopTask = nil
        phase = .stopping
        statusText = "마지막 문장 확정 및 M4A 저장 중…"
        current?.meeting.status = .finalizing
        persist()
        if let result = await capture?.stop() {
            current?.meeting.audioChunks = result.chunks
            if let error = result.error { current?.meeting.warnings.append("녹음 종료: \(error)") }
            if result.metrics.microphoneWasEnabled && result.metrics.microphoneFrames == 0 { current?.meeting.warnings.append("마이크 입력이 수신되지 않았습니다.") }
            if result.metrics.systemFrames == 0 { current?.meeting.warnings.append("시스템 소리 입력이 수신되지 않았습니다. 회의 앱에서 소리가 재생되었는지 확인해 주세요.") }
        }
        capture = nil
        for (source, lane) in lanes {
            do { try await lane.finish() }
            catch { current?.meeting.warnings.append("\(source.label) 마지막 전사 확정 실패: \(error.localizedDescription)") }
        }
        lanes = [:]
        await releaseTranscriber()
        pendingTranscript = PendingTranscript()
        current?.meeting.endedAt = Date()
        persist()
        if let stored = current {
            do {
                let warnings = try await AudioExporter.export(chunks: stored.meeting.audioChunks, directory: stored.directory)
                current?.meeting.audioFile = "audio.m4a"
                current?.meeting.warnings.append(contentsOf: warnings)
                // The live lane already finalized its last buffer above. Saving
                // never runs a second recognizer or changes confirmed words.
                current?.meeting.status = .completed
                statusText = "실시간 대화록과 M4A를 저장했습니다"
            } catch {
                current?.meeting.status = .failed
                current?.meeting.error = error.localizedDescription
                statusText = "대화록을 보관했습니다 · 오디오 복구가 필요합니다"
                errorMessage = error.localizedDescription
            }
        }
        persist()
        await releaseTranscriber()
        current = nil
        activeTarget = nil
        activeStartedAt = nil
        phase = .idle
    }

    func finishBeforeQuitting() async {
        isQuitting = true
        speakerTask?.cancel()
        polishTask?.cancel()
        await polishTask?.value
        await stop()
        // A stop initiated from the window may already be exporting.
        while isBusy { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func cancelSpeakerSeparation() { speakerTask?.cancel() }

    func refreshPolished() {
        hasPolishedText = false
        guard let stored = selected else { polished = PolishedTranscript(); polishedMeetingID = nil; return }
        do {
            polished = try PolishedTranscriptStore.read(stored.directory).0
            polishedMeetingID = stored.id
            if !polished.entries.isEmpty {
                hasPolishedText = TranscriptDocument.playbackParagraphs(stored.meeting).contains { polished.text(for: $0) != nil }
            }
        } catch {
            polished = PolishedTranscript()
            polishedMeetingID = nil
        }
    }

    func polishedText(for paragraph: TranscriptPlaybackParagraph, in meeting: StoredMeeting) -> String? {
        guard polishedMeetingID == meeting.id else { return nil }
        return polished.text(for: paragraph)
    }

    func cancelPolishing() { polishTask?.cancel() }

    func startPolishing() {
        guard !isBusy, let stored = selected, stored.meeting.status == .completed else { return }
        let paragraphs = TranscriptDocument.playbackParagraphs(stored.meeting)
        guard !paragraphs.isEmpty else { return }
        refreshLocalModels()
        guard let selectedModel = localModels.first(where: { $0.id == selectedLocalModel }) else {
            errorMessage = "선택한 로컬 모델을 찾을 수 없습니다. Ollama에서 내려받고 설정에서 모델을 선택해 주세요."
            return
        }
        isPolishing = true
        polishProgress = "로컬 모델 준비 중…"
        polishTask = Task { [weak self] in
            guard let self else { return }
            let worker = LocalTranscriptPolisher(model: selectedModel)
            defer { worker.stop(); self.isPolishing = false; self.polishTask = nil }
            do {
                var (document, expected) = try PolishedTranscriptStore.read(stored.directory)
                let pending = paragraphs.filter { document.text(for: $0) == nil }
                guard !pending.isEmpty else { self.polishProgress = "이미 문장 정리가 완료되었습니다."; return }
                try await worker.start()
                for paragraph in pending {
                    try Task.checkCancellation()
                    let completed = paragraphs.count - pending.count + pending.firstIndex(where: { $0.id == paragraph.id })!
                    self.polishProgress = "문장 다듬는 중 \(completed + 1)/\(paragraphs.count)"
                    let text = try await worker.polish(paragraph.text)
                    try Task.checkCancellation()
                    document.entries[paragraph.id.uuidString] = PolishedEntry(sourceHash: PolishedTranscript.sourceHash(paragraph), text: text, model: selectedModel.id)
                    expected = try PolishedTranscriptStore.save(document, directory: stored.directory, expected: expected)
                    if self.selectedID == stored.id {
                        self.polished = document
                        self.polishedMeetingID = stored.id
                        self.hasPolishedText = true
                    }
                }
                self.polishProgress = "문장 정리가 완료되었습니다. 원문과 비교해 확인해 주세요."
            } catch {
                if Task.isCancelled || error is CancellationError {
                    self.polishProgress = "중단했습니다. 완료된 문단은 저장되어 있습니다."
                } else {
                    self.polishProgress = "문장 정리를 완료하지 못했습니다. 완료된 문단과 원문은 보존됩니다."
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func separateSpeakers(_ stored: StoredMeeting) async throws -> Meeting {
        if isQuitting { throw CancellationError() }
        isSeparatingSpeakers = true
        defer { isSeparatingSpeakers = false; speakerTask = nil }
        let progress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard self?.isSeparatingSpeakers == true else { return }
                self?.statusText = message
            }
        }
        let task = Task.detached(priority: .utility) {
            try await SpeakerDiarizer.analyze(stored, progress: progress)
        }
        speakerTask = task
        return try await task.value
    }

    func separateSelectedSpeakers() async {
        guard !isBusy, let stored = selected, let root else { return }
        phase = .stopping
        defer { phase = .idle }
        do {
            let updated = StoredMeeting(meeting: try await separateSpeakers(stored), directory: stored.directory)
            try MeetingStore(root: root).save(updated)
            updateList(updated)
            transcriptRevision += 1
            statusText = "참석자별 대화록을 저장했습니다"
        } catch {
            // The previous Markdown, audio and metadata are untouched on failure.
            statusText = "화자 분리를 완료하지 못했습니다 · 기존 기록은 보존했습니다"
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func recoverSelectedAudio() async {
        guard !isBusy, let stored = selected else { return }
        phase = .stopping
        statusText = "남아 있는 오디오 조각으로 M4A 복구 중…"
        var updated = stored
        do {
            let warnings = try await AudioExporter.export(chunks: stored.meeting.audioChunks, directory: stored.directory)
            updated.meeting.warnings.append(contentsOf: warnings)
            updated.meeting.audioFile = "audio.m4a"
            updated.meeting.status = .completed
            updated.meeting.error = nil
            try MeetingStore(root: root!).save(updated)
            updateList(updated)
            statusText = "M4A 복구 완료"
        } catch { errorMessage = error.localizedDescription; statusText = "오디오 조각을 보존했습니다" }
        phase = .idle
    }

    @discardableResult
    func moveMeetingToTrash(_ id: UUID) -> Bool {
        guard !isBusy else {
            errorMessage = "녹음이나 파일 정리가 끝난 뒤 삭제해 주세요."
            return false
        }
        guard let root, let index = meetings.firstIndex(where: { $0.id == id }) else {
            errorMessage = "삭제할 회의 기록을 찾을 수 없습니다."
            return false
        }
        do {
            try MeetingStore(root: root).moveToTrash(meetings[index])
            meetings.remove(at: index)
            if selectedID == id {
                selectedID = meetings.isEmpty ? nil : meetings[min(index, meetings.count - 1)].id
                refreshSummary()
            }
            transcriptRevision += 1
            statusText = "회의를 휴지통으로 이동했습니다"
            return true
        } catch {
            errorMessage = "회의를 삭제하지 못했습니다. \(error.localizedDescription)"
            return false
        }
    }

    func openFolder(_ url: URL) {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              NSWorkspace.shared.open(url) else {
            errorMessage = "폴더를 열 수 없습니다. 저장 위치를 확인해 주세요."
            return
        }
    }

    func copyDocument(_ tab: String, from stored: StoredMeeting) {
        do {
            let text: String?
            let notice: String
            switch tab {
            case "transcript":
                text = try MeetingCopy.transcript(stored)
                notice = "대화록 복사됨"
            case "polished":
                text = polishedMeetingID == stored.id ? MeetingCopy.polished(stored, document: polished) : nil
                notice = "정리본 복사됨"
            case "summary":
                text = try String(contentsOf: stored.directory.appendingPathComponent("summary.md"), encoding: .utf8)
                notice = "요약 복사됨"
            default: return
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "복사할 내용이 없습니다."
                return
            }
            copyText(text, message: notice)
        } catch { errorMessage = "문서를 읽을 수 없습니다. 회의 폴더에서 파일을 확인해 주세요." }
    }

    func openTranscript() {
        if let directory = selected?.directory { NSWorkspace.shared.open(directory.appendingPathComponent("transcript.md")) }
    }

    func copyPath(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "파일이나 폴더를 찾을 수 없습니다."
            return
        }
        copyText(url.path, message: "경로 복사됨")
    }

    func copyText(_ text: String, message: String) {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            errorMessage = "클립보드에 복사하지 못했습니다. 다시 시도해 주세요."
            return
        }
        clipboardMessage = message
        isCopyNoticeVisible = true
        copyNoticeTask?.cancel()
        copyNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            self?.isCopyNoticeVisible = false
        }
    }

    func refreshMCPConnections() {
        do {
            let clients = try MCPConnectionRegistry.activeClients()
            if clients != mcpClients { mcpClients = clients }
            mcpPresenceAvailable = true
        } catch {
            mcpClients = []
            mcpPresenceAvailable = false
        }
    }

    func checkMCP() async {
        guard !isCheckingMCP else { return }
        isCheckingMCP = true
        refreshMCPConnections()
        let checkedRoot = root
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MeetingRecorderMCP")
        let result = await MCPDiagnostics.check(executable: executable, root: checkedRoot)
        mcpDiagnostic = root == checkedRoot ? result : nil
        refreshMCPConnections()
        isCheckingMCP = false
    }

    func copyMCPConfiguration() {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MeetingRecorderMCP").path
        // No fixed root: each MCP request follows the app's current saved folder.
        let value: [String: Any] = ["mcpServers": ["meeting-recorder": ["command": executable, "args": []]]]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            copyText(String(decoding: data, as: UTF8.self), message: "MCP 설정 복사됨")
        }
    }

    func copySummaryRequest() {
        guard let selected else { return }
        copyText("meeting-recorder MCP로 회의 \(selected.id.uuidString)의 대화록을 get_transcript로 읽어줘. 주제별 요약, 결정 사항, 액션 아이템(담당자·할 일·기한)을 Markdown으로 정리하고 save_summary로 앱에 저장해줘. 언급되지 않은 담당자와 기한은 미정으로 표시하고 전사가 불명확하면 확인 필요로 남겨줘. 읽을 때 받은 transcript_sha256과 summary_sha256을 저장 도구에 전달해줘.",
                 message: "요약 요청 복사됨")
    }

    func refreshSummary() {
        let file = selected?.directory.appendingPathComponent("summary.md")
        let stamp = file.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard file != summaryFile || stamp != summaryStamp else { return }
        summaryFile = file
        summaryStamp = stamp
        let text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        summaryText = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    private func releaseTranscriber() async {
        await SpeechLane.releaseAssets()
    }

    private func persist() {
        guard let current, let root else { return }
        do { try MeetingStore(root: root).save(current); updateList(current) }
        catch { errorMessage = "파일 저장 실패: \(error.localizedDescription)" }
    }

    private func updateList(_ stored: StoredMeeting) {
        if let index = meetings.firstIndex(where: { $0.id == stored.id }) { meetings[index] = stored }
        else { meetings.insert(stored, at: 0) }
    }

    private func reload(recover: Bool) {
        guard let root else { return }
        do { meetings = try MeetingStore(root: root).loadAll(recoverInterrupted: recover); selectedID = meetings.first?.id }
        catch { errorMessage = error.localizedDescription }
    }
}
