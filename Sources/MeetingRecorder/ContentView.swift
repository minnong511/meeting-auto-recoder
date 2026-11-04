import AVKit
import RecorderAudio
import RecorderCore
import SwiftUI

struct CopyToastModifier: ViewModifier {
    @ObservedObject var model: RecorderModel

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if model.isCopyNoticeVisible {
                Label(model.clipboardMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(.primary)
                    .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                .padding(.top, 16).transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false).accessibilityElement(children: .combine)
            }
        }.animation(.easeInOut(duration: 0.2), value: model.isCopyNoticeVisible)
    }
}

struct ContentView: View {
    @ObservedObject var model: RecorderModel
    @State private var tab = "transcript"
    @State private var search = ""
    @State private var columns = NavigationSplitViewVisibility.all
    @StateObject private var playback = RecordingPlayer()
    @State private var expandsRecordingControls = false
    @State private var followLive = true
    @State private var pendingDeletion: StoredMeeting?
    @State private var confirmsStop = false

    private var filteredMeetings: [StoredMeeting] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.meetings : model.meetings.filter {
            $0.meeting.title.localizedStandardContains(query)
        }
    }

    private var showsRecordingControls: Bool {
        model.phase != .idle || model.selected == nil || expandsRecordingControls
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            GeometryReader { geometry in
                sidebar.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            GeometryReader { geometry in
            VStack(spacing: 0) {
                if showsRecordingControls, let suggestion = model.meetingSuggestion { meetingAppBanner(suggestion) }
                if !model.isBusy { ReleaseBanner(updates: model.updates) }
                if showsRecordingControls { recordingControls }
                else if model.isPolishing {
                    HStack { ProgressView().controlSize(.small); Text(model.polishProgress).font(.caption); Spacer() }
                }
                if let stored = model.selected { meetingDetail(stored) }
                else { emptyLibrary }
            }
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RecorderTheme.canvas)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
        .tint(RecorderTheme.accent)
        .frame(minWidth: 820, minHeight: 620)
        .modifier(CopyToastModifier(model: model))
        .toolbar {
            if columns == .detailOnly {
                Button(action: newRecording) { Label("새 녹음", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command).disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $model.showsSettings) { RecorderSettingsView(model: model) }
        .confirmationDialog("회의를 삭제할까요?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingDeletion) { stored in
            Button("휴지통으로 이동", role: .destructive) { deleteMeeting(stored) }
            Button("취소", role: .cancel) { pendingDeletion = nil }
        } message: { stored in
            Text("‘\(stored.meeting.title)’의 녹음, 대화록, 요약과 관련 파일을 모두 휴지통으로 이동합니다. Finder의 휴지통에서 복구할 수 있습니다.")
        }
        .confirmationDialog("녹음을 종료할까요?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("녹음 종료") { Task { await model.stop() } }
            Button("계속 녹음", role: .cancel) {}
        } message: { Text("녹음을 마치고 전사와 음성 파일을 저장합니다.") }
        .alert("확인이 필요합니다", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: model.selectedID) { _, _ in
            playback.reset()
            expandsRecordingControls = false
            if let stored = model.selected, stored.meeting.audioFile != nil { playback.prepare(stored) }
            model.refreshSummary()
            model.refreshPolished()
        }
        .onChange(of: model.activeStartedAt) { _, date in
            if date != nil { tab = "transcript"; followLive = true; search = "" }
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .idle { playback.pause() }
            else { expandsRecordingControls = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            playback.finished(notification)
        }
        .onDisappear { playback.reset() }
        .onChange(of: playback.errorMessage) { _, message in
            if let message { model.errorMessage = message }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshNotificationPermission()
            model.refreshMCPConnections()
            Task { await model.updates.check() }
            model.refreshSummary()
        }
        .onAppear { model.refreshPolished(); model.refreshSummary() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshSummary()
            if model.showsSettings && model.settingsPage == .connections { model.refreshMCPConnections() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RecorderTheme.accent).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting Recorder").font(RecorderTheme.heading(15))
                }
            }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 20)
            Button(action: newRecording) {
                Label("새 녹음", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.isBusy)
            .padding(.horizontal, 16).padding(.bottom, 16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("회의 검색", text: $search).textFieldStyle(.plain).accessibilityLabel("회의 제목 검색")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("검색 지우기")
                }
            }
            .font(.system(size: 13)).padding(10)
            .background(RecorderTheme.hover.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            HStack {
                Text("회의 기록").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(model.meetings.count)").monospacedDigit().font(.system(size: 11))
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 6)
            List(selection: $model.selectedID) {
                ForEach(MeetingDateGroup.allCases, id: \.self) { group in
                    let items = filteredMeetings.filter { MeetingDateGroup.group(for: $0.meeting.startedAt) == group }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { stored in
                                meetingRow(stored).tag(stored.id)
                                    .contextMenu {
                                        Button("회의 폴더 열기") { model.openFolder(stored.directory) }
                                        Button("회의 폴더 경로 복사") { model.copyPath(stored.directory) }
                                        Divider()
                                        Button(role: .destructive) { pendingDeletion = stored } label: {
                                            Label("회의 삭제…", systemImage: "trash")
                                        }.disabled(!model.canDeleteMeeting(stored))
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onDeleteCommand {
                if let stored = model.selected, model.canDeleteMeeting(stored) { pendingDeletion = stored }
            }
            .overlay {
                if filteredMeetings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: search.isEmpty ? "tray" : "magnifyingglass").font(.title2)
                        Text(search.isEmpty ? "첫 회의를 기다리고 있어요" : "검색 결과가 없습니다").font(.caption)
                    }.foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            Divider().overlay(RecorderTheme.border).padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        if let root = model.root { model.openFolder(root) }
                        else { model.chooseFolder() }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "folder").foregroundStyle(RecorderTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("저장 폴더").font(.caption2).foregroundStyle(.secondary)
                                Text(model.root?.lastPathComponent ?? "폴더 선택…")
                                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help(model.root?.path ?? "저장 폴더 선택")
                        .accessibilityLabel(model.root == nil ? "저장 폴더 선택" : "저장 폴더 열기")
                    Spacer(minLength: 0)
                    Button { if let root = model.root { model.copyPath(root) } } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.root == nil)
                        .help("저장 폴더 경로 복사").accessibilityLabel("저장 폴더 경로 복사")
                }
                Button { model.openSettings(.general) } label: {
                    HStack {
                        Label("설정 및 연결", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }.font(.system(size: 12)).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(18)
        }
        .background(RecorderTheme.sidebar)
    }

    private func deleteMeeting(_ stored: StoredMeeting) {
        let wasSelected = model.selectedID == stored.id
        if wasSelected { playback.reset() }
        if model.moveMeetingToTrash(stored.id), wasSelected,
           !filteredMeetings.contains(where: { $0.id == model.selectedID }) {
            model.selectedID = filteredMeetings.first?.id
        }
        pendingDeletion = nil
    }

    private func meetingRow(_ stored: StoredMeeting) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: stored.meeting.status == .recording ? "record.circle.fill" : "text.alignleft")
                .font(.system(size: 13))
                .foregroundStyle(stored.meeting.status == .recording ? RecorderTheme.recording : .secondary)
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(stored.meeting.title).font(RecorderTheme.heading(13)).lineLimit(1).foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(stored.meeting.startedAt, format: .dateTime.month().day().hour().minute())
                    if let end = stored.meeting.endedAt {
                        Text("·")
                        Text(shortDuration(end.timeIntervalSince(stored.meeting.startedAt)))
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if stored.meeting.status != .completed {
                    Label(stored.meeting.status.label, systemImage: stored.meeting.status == .recording ? "record.circle" : "info.circle")
                        .font(.system(size: 10)).foregroundStyle(statusColor(stored.meeting.status))
                }
            }
        }.padding(.vertical, 5)
    }

    private func newRecording() {
        expandsRecordingControls = true
        model.title = ""
        search = ""
        tab = "transcript"
        followLive = true
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.phase == .recording ? "회의 녹음 중" : "새 녹음", systemImage: "waveform.and.mic")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let start = model.activeStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TranscriptMarkdown.timestamp(context.date.timeIntervalSince(start)))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                }
                phaseBadge
                if !model.isBusy && model.selected != nil {
                    Button { expandsRecordingControls = false } label: {
                        Label("접기", systemImage: "chevron.up")
                    }.buttonStyle(.borderless).font(.caption).accessibilityLabel("녹음 준비 접기")
                }
            }
            HStack(spacing: 20) {
                TextField("어떤 회의인가요?", text: $model.title).textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .medium)).accessibilityLabel("회의 제목").disabled(model.isBusy)
                recordingAction
            }
            HStack(spacing: 12) {
                Image(systemName: "app").foregroundStyle(.secondary)
                targetPicker
                Button { model.refreshMeetingApps() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("실행 중인 앱 새로 고침")
                    .accessibilityLabel("실행 중인 앱 새로 고침").disabled(model.isBusy)
                Button("자동 선택", action: model.automaticallyChooseMeetingApp)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(RecorderTheme.accent).disabled(model.isBusy)
                Spacer(minLength: 8)
                Toggle(isOn: Binding(get: { model.microphoneEnabled }, set: { enabled in
                    Task { await model.setMicrophoneEnabled(enabled) }
                })) {
                    Label(model.microphoneEnabled ? "내 마이크 켜짐" : "내 마이크 꺼짐", systemImage: model.microphoneEnabled ? "mic" : "mic.slash")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
                .disabled(model.phase == .preparing || model.phase == .stopping || model.isUpdatingMicrophone)
                .help("이 앱의 녹음과 전사에 내 마이크 음성을 포함합니다.")
            }
            if let bundleID = model.recordingTarget?.bundleID,
               ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.naver.Whale"].contains(bundleID) {
                Label("같은 브라우저의 다른 탭 소리도 함께 녹음됩니다.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.isBusy {
                HStack(spacing: 8) {
                    if model.phase != .recording { ProgressView().controlSize(.mini) }
                    Text(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if model.isSeparatingSpeakers {
                        Button("분석 중단", action: model.cancelSpeakerSeparation).font(.caption).buttonStyle(.borderless)
                    }
                }
            }
            if model.phase == .recording { liveTranscriptPanel }
        }
        .padding(.vertical, 18).padding(.horizontal, 4)
    }

    private var targetPicker: some View {
        Picker("녹음할 앱", selection: Binding(get: { model.selectedTargetID }, set: model.selectTarget)) {
            Text("녹음할 앱 선택").tag("")
            ForEach(model.availableApps) { app in Text(app.name + (app.kind != nil ? " · 회의 앱" : "")).tag(app.id) }
            if !model.selectedTargetID.isEmpty && model.recordingTarget == nil {
                Text("선택한 앱 실행 필요").tag(model.selectedTargetID)
            }
            Divider()
            Text(model.excludesNotificationSounds ? "전체 시스템 소리 · 알림 앱 제외" : "전체 시스템 소리").tag(RecordingTarget.systemID)
        }.labelsHidden().frame(maxWidth: 250).disabled(model.isBusy)
    }

    private var phaseBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(model.phase == .recording ? RecorderTheme.recording : (model.phase == .idle ? (model.canBegin ? .green : .secondary) : RecorderTheme.accent))
                .frame(width: 7, height: 7)
            Text(model.phase == .recording ? "녹음 중" : model.phase == .idle ? (model.canBegin ? "준비됨" : "앱 선택 필요") : model.phase == .preparing ? "준비 중" : "저장 중")
                .font(.system(size: 11, weight: .semibold))
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var recordingAction: some View {
        if model.phase == .recording {
            Button(role: .destructive) { confirmsStop = true } label: {
                Label("녹음 종료", systemImage: "stop.fill").frame(minWidth: 100)
            }.buttonStyle(.borderedProminent).tint(RecorderTheme.recording).controlSize(.large)
                .keyboardShortcut("r", modifiers: [.command, .shift])
        } else if model.phase == .preparing {
            Button("준비 취소") { Task { await model.stop() } }.controlSize(.large)
        } else if model.phase == .stopping {
            Button("기록 저장 중…") {}.controlSize(.large).disabled(true)
        } else {
            Button(action: model.begin) { Label("녹음 시작", systemImage: "record.circle").frame(minWidth: 100) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canBegin)
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    private func meetingAppBanner(_ event: MeetingAppEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill").foregroundStyle(RecorderTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.system(size: 12, weight: .semibold))
                Text(event.message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("이 앱으로 녹음") { model.begin(in: event.app) }.buttonStyle(.bordered).disabled(model.isBusy)
            Button(action: model.dismissMeetingSuggestion) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("알림 닫기").accessibilityLabel("회의 앱 알림 닫기")
        }.padding(14).background(RecorderTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveTranscriptPanel: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(AudioSource.allCases, id: \.self) { source in
                let muted = source == .microphone && !model.microphoneEnabled
                let pending = model.pendingTranscript.text(for: source)
                let text = pending.isEmpty ? model.latestConfirmed[source]?.text : pending
                let color: Color = source == .microphone ? RecorderTheme.accent : .teal
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: source == .microphone ? (muted ? "mic.slash" : "mic") : "waveform")
                        Text(source.label).fontWeight(.medium)
                        Spacer()
                        Text(muted ? "꺼짐" : "실시간").foregroundStyle(.secondary)
                    }.font(.system(size: 10)).foregroundStyle(muted ? .secondary : color)
                    ProgressView(value: muted ? 0 : (source == .microphone ? model.metrics.microphoneLevel : model.metrics.systemLevel))
                        .tint(color).accessibilityLabel(source.label + " 입력 크기")
                    Text(muted ? "마이크 녹음이 꺼져 있습니다" : (text ?? "말소리를 기다리고 있어요…"))
                        .font(.system(size: 12)).lineLimit(2).lineSpacing(3)
                        .foregroundStyle(muted || text == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func meetingDetail(_ stored: StoredMeeting) -> some View {
        VStack(spacing: 0) {
            documentHeader(stored)
            documentTabs(stored)
            Divider()
            documentContent(stored)
            if stored.meeting.audioFile != nil { audioBar(stored) }
            else if !stored.meeting.audioChunks.isEmpty && !model.isBusy {
                Divider()
                HStack {
                    Label("저장되지 않은 녹음 조각이 있습니다", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("M4A 복구") { Task { await model.recoverSelectedAudio() } }
                }.padding(16)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func documentHeader(_ stored: StoredMeeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(stored.meeting.title).font(RecorderTheme.heading(23)).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Label { Text(stored.meeting.startedAt, format: .dateTime.year().month().day().hour().minute()) } icon: {
                            Image(systemName: "calendar")
                        }
                        if let end = stored.meeting.endedAt {
                            Label(shortDuration(end.timeIntervalSince(stored.meeting.startedAt)), systemImage: "clock")
                        }
                        if let diarization = stored.meeting.diarization, diarization.state == .completed, diarization.speakerCount > 0 {
                            Label("상대방 \(diarization.speakerCount)명", systemImage: "person.2")
                        }
                        Label(stored.meeting.status.label, systemImage: stored.meeting.status == .recording ? "record.circle.fill" : "circle.fill")
                            .foregroundStyle(statusColor(stored.meeting.status))
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { model.openFolder(stored.directory) } label: {
                    Label("회의 폴더", systemImage: "folder")
                }.buttonStyle(.bordered).controlSize(.small)
                    .help(stored.directory.path).accessibilityLabel("회의 폴더 열기")
                Menu {
                    Button("회의 폴더 경로 복사") { model.copyPath(stored.directory) }
                    Divider()
                    filePathItem("대화록", file: stored.directory.appendingPathComponent("transcript.md"))
                    filePathItem("정리본", file: stored.directory.appendingPathComponent(PolishedTranscriptStore.fileName))
                    filePathItem("요약", file: stored.directory.appendingPathComponent("summary.md"))
                    if let audio = stored.audioURL { filePathItem("녹음 파일", file: audio) }
                } label: { Label("경로 복사", systemImage: "doc.on.doc") }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                Menu {
                    Button("Markdown 열기", action: model.openTranscript)
                    Button("요약 요청 복사", action: model.copySummaryRequest).disabled(stored.meeting.status != .completed)
                    if stored.meeting.audioFile != nil && stored.meeting.diarization?.state != .completed {
                        Divider()
                        Button("화자 구분") { Task { await model.separateSelectedSpeakers() } }
                            .help("기존 대화록에 화자 표시를 붙입니다.")
                            .disabled(model.isBusy || !SpeakerDiarizer.canAnalyze(stored))
                    }
                    Divider()
                    Button(role: .destructive) { pendingDeletion = stored } label: {
                        Label("회의 삭제…", systemImage: "trash")
                    }.disabled(!model.canDeleteMeeting(stored))
                } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 24, height: 22) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("회의 파일 더 보기")
            }
            if stored.meeting.transcriptionEngine?.contains("Whisper fallback") == true {
                Label("짧은 발언 일부는 실시간 전사 결과를 유지했습니다.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !stored.meeting.warnings.isEmpty || stored.meeting.error != nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(stored.meeting.warnings, id: \.self) { Text($0) }
                        if let error = stored.meeting.error { Text(error) }
                    }
                }.font(.caption).foregroundStyle(.orange).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            if let diarization = stored.meeting.diarization {
                if diarization.reviewCount > 0 {
                    Label("화자를 확인할 구간이 \(diarization.reviewCount)개 있습니다", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error = diarization.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 12)
    }

    private func filePathItem(_ label: String, file: URL) -> some View {
        Button(label + " 경로 복사") { model.copyPath(file) }
            .disabled(!FileManager.default.fileExists(atPath: file.path))
    }

    private func documentTabs(_ stored: StoredMeeting) -> some View {
        HStack(spacing: 16) {
            documentTab("대화록", symbol: "text.alignleft", value: "transcript")
            documentTab("다듬은 대화록", symbol: "text.badge.checkmark", value: "polished")
            documentTab("회의 요약", symbol: "sparkles", value: "summary")
            Spacer(minLength: 4)
            if model.selectedIsActive && tab == "transcript" {
                Toggle("자동 따라가기", isOn: $followLive).toggleStyle(.checkbox).font(.system(size: 10))
            }
            if stored.meeting.status == .completed, tab != "summary" || model.summaryText != nil {
                summaryButton(stored)
            }
            let label = tab == "transcript" ? "대화록 복사" : (tab == "polished" ? "정리본 복사" : "요약 복사")
            let empty = tab == "polished" ? model.polishedMeetingID != stored.id || !model.hasPolishedText :
                (tab == "summary" ? model.summaryText == nil : stored.meeting.segments.isEmpty && !FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent("transcript.md").path))
            Button { model.copyDocument(tab, from: stored) } label: {
                ViewThatFits(in: .horizontal) {
                    Label(label, systemImage: "doc.on.doc").fixedSize()
                    Image(systemName: "doc.on.doc")
                }
            }.buttonStyle(.bordered).controlSize(.small).disabled(empty)
                .help(label).accessibilityLabel(label).keyboardShortcut("c", modifiers: [.command, .shift])
        }.padding(.horizontal, 4)
    }

    @ViewBuilder private func summaryButton(_ stored: StoredMeeting) -> some View {
        if model.summarizingID == stored.id {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Button("취소", action: model.cancelSummary).controlSize(.small).accessibilityLabel("요약 취소")
            }
        } else {
            let agent = model.summaryAgent
            let label = model.summaryText == nil ? (agent.map { $0.name + "로 요약" } ?? "회의 요약 생성") : "다시 요약"
            HStack(spacing: 4) {
                if let agent { SummaryModelPicker(agent: agent, compact: true).id(agent) }
                Button {
                    tab = "summary"
                    model.generateSummary(stored)
                } label: { Label(label, systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help(agent.map { "이 회의의 대화록을 " + $0.name + "에 보내 요약합니다." } ?? "요약 연결 설정")
            }.disabled(stored.meeting.status != .completed || model.summarizingID != nil)
        }
    }

    private func documentTab(_ label: String, symbol: String, value: String) -> some View {
        Button { tab = value } label: {
            Label(label, systemImage: symbol)
                .font(.system(size: 13, weight: tab == value ? .semibold : .regular))
                .foregroundStyle(tab == value ? RecorderTheme.accent : .secondary)
                .padding(.vertical, 15).contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    if tab == value { Capsule().fill(RecorderTheme.accent).frame(height: 2) }
                }
        }.buttonStyle(.plain).modifier(QuietHover()).accessibilityValue(tab == value ? "선택됨" : "")
    }

    private func documentContent(_ stored: StoredMeeting) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if tab == "transcript" {
                    let paragraphs = TranscriptDocument.playbackParagraphs(stored.meeting)
                    if paragraphs.isEmpty && !model.selectedIsActive {
                        documentEmptyState(
                            title: "아직 대화록이 없습니다",
                            message: stored.meeting.audioFile != nil ? "아래에서 녹음 파일을 재생할 수 있습니다." : "확정된 발언이 여기에 표시됩니다.",
                            symbol: "text.bubble")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            ForEach(paragraphs) { paragraph in playbackParagraph(paragraph, in: stored) }
                            if model.selectedIsActive {
                                ForEach(AudioSource.allCases, id: \.self) { source in
                                    let pending = model.pendingTranscript.text(for: source)
                                    if !pending.isEmpty {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Label(source.speakerLabel + " · 인식 중", systemImage: "waveform")
                                                .font(.system(size: 12, weight: .medium))
                                            Text(pending).font(.system(size: 14)).lineSpacing(7)
                                        }.foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Color.clear.frame(height: 1).id("transcript-bottom")
                        }.padding(.vertical, 28).padding(.horizontal, 8).frame(maxWidth: RecorderTheme.contentWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center).textSelection(.enabled)
                    }
                } else if tab == "polished" {
                    polishedContent(stored)
                } else {
                    if let failure = model.summaryError, failure.id == stored.id {
                        HStack {
                            Text(failure.message).foregroundStyle(.secondary)
                            Button("연결 설정") { model.openSettings(.connections) }
                        }.font(.callout).padding(.top, 12)
                    }
                    if let summary = model.summaryText {
                        SummaryMarkdownView(markdown: summary)
                            .textSelection(.enabled).padding(.vertical, 28).padding(.horizontal, 8)
                            .frame(maxWidth: RecorderTheme.contentWidth, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(RecorderTheme.accent)
                                    .frame(width: 44, height: 44)
                                    .background(RecorderTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(model.summarizingID == stored.id ? (model.runningSummaryAgent?.name ?? "에이전트") + "가 요약 중입니다" : "아직 회의 요약이 없습니다").font(.system(size: 17, weight: .semibold))
                                }
                            }
                            HStack(spacing: 16) {
                                summaryButton(stored)
                                Button("MCP 연결 설정") { model.openSettings(.connections) }
                                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.padding(28).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: model.transcriptRevision) { _, _ in
                    if followLive && tab == "transcript" && model.selectedIsActive { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
                }
                .onChange(of: followLive) { _, enabled in
                    if enabled && tab == "transcript" { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
                }
        }
    }

    private func polishedContent(_ stored: StoredMeeting) -> some View {
        let paragraphs = TranscriptDocument.playbackParagraphs(stored.meeting)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI 정리 초안").font(.system(size: 14, weight: .semibold))
                    Text("사용 모델 · \(model.selectedLocalModel)").font(.caption).foregroundStyle(.secondary)
                    if !model.polished.entries.isEmpty {
                        let models = Set(model.polished.entries.values.map { $0.model ?? model.polished.model })
                        if models != [model.selectedLocalModel] {
                            Text("저장된 문단 · \(models.sorted().joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !model.polishProgress.isEmpty { Text(model.polishProgress).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.isPolishing {
                    Button("중단", action: model.cancelPolishing).buttonStyle(.bordered)
                } else {
                    Button("문장 다듬기", action: model.startPolishing).buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || stored.meeting.status != .completed || paragraphs.isEmpty)
                }
            }
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(paragraphs) { paragraph in
                    playbackParagraph(paragraph, in: stored, polishedText: model.polishedText(for: paragraph, in: stored), showPolished: true)
                }
            }
        }.padding(.vertical, 28).padding(.horizontal, 8).frame(maxWidth: RecorderTheme.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center).textSelection(.enabled)
    }

    private func playbackParagraph(_ paragraph: TranscriptPlaybackParagraph, in stored: StoredMeeting,
                                   polishedText: String? = nil, showPolished: Bool = false) -> some View {
        let color: Color = paragraph.source == .microphone ? RecorderTheme.accent : .secondary
        let active = playback.meetingID == stored.id && playback.hasStarted &&
            playback.position >= paragraph.start && playback.position < paragraph.end
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: paragraph.source == .microphone ? "person.fill" : "waveform")
                .font(.system(size: 12)).foregroundStyle(color).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(paragraph.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Button {
                        playback.seek(to: paragraph.start, in: stored, autoplay: true)
                    } label: {
                        Label(TranscriptMarkdown.timestamp(paragraph.start), systemImage: active ? "speaker.wave.2.fill" : "play.circle")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }.buttonStyle(.borderless)
                        .disabled(model.isBusy || stored.meeting.audioFile == nil)
                        .help("이 문단의 녹음 재생")
                        .accessibilityLabel(TranscriptMarkdown.timestamp(paragraph.start) + "부터 문단 재생")
                        .accessibilityValue(active ? "현재 재생 구간" : "")
                    Spacer()
                    Button { model.copyText(showPolished ? (polishedText ?? paragraph.text) : paragraph.text, message: "문단 복사됨") } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("문단 복사").accessibilityLabel("문단 복사")
                }
                if showPolished {
                    Text(polishedText ?? "아직 다듬지 않은 문단입니다.")
                        .font(RecorderTheme.body()).lineSpacing(8).foregroundStyle(polishedText == nil ? .secondary : .primary)
                    Text("원문").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(paragraph.text).font(.system(size: 12)).lineSpacing(5).foregroundStyle(.secondary)
                } else {
                    Text(paragraph.text).font(RecorderTheme.body()).lineSpacing(8).foregroundStyle(.primary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
            .background(active ? RecorderTheme.accent.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func documentEmptyState(title: String, message: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light))
                .foregroundStyle(RecorderTheme.accent.opacity(0.8)).frame(width: 60, height: 60)
                .background(RecorderTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 19)).padding(.bottom, 5)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(message).font(.system(size: 12)).lineSpacing(5).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 36)
    }

    private var emptyLibrary: some View {
        documentEmptyState(title: model.meetings.isEmpty ? "저장된 회의가 없습니다" : "회의를 선택하세요",
                           message: model.meetings.isEmpty ? "녹음할 앱을 선택하고 녹음을 시작하세요." : "왼쪽 목록에서 대화록을 열 수 있습니다.",
                           symbol: "waveform.and.mic")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func audioBar(_ stored: StoredMeeting) -> some View {
        VStack(spacing: 0) {
            Divider()
            PlaybackTimeline(player: playback, stored: stored, enabled: !model.isBusy && playback.duration > 0)
                .id(stored.audioURL)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button { playback.toggle(stored) } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12))
                        .foregroundStyle(RecorderTheme.accent).frame(width: 32, height: 32)
                        .background(RecorderTheme.accent.opacity(0.09), in: Circle())
                }.buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityLabel(playback.isPlaying ? "녹음 일시정지" : "녹음 재생")
                Button { playback.skip(-10, in: stored) } label: { Image(systemName: "gobackward.10") }
                    .buttonStyle(.borderless).disabled(model.isBusy).help("10초 뒤로").accessibilityLabel("10초 뒤로")
                Button { playback.skip(10, in: stored) } label: { Image(systemName: "goforward.10") }
                    .buttonStyle(.borderless).disabled(model.isBusy).help("10초 앞으로").accessibilityLabel("10초 앞으로")
                Text(PlaybackTimeline.time(playback.position) + " / " + PlaybackTimeline.time(playback.duration))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 4)
                Picker("재생 속도", selection: Binding(get: { playback.rate }, set: playback.setRate)) {
                    ForEach(RecordingPlayer.rates, id: \.self) { rate in
                        Text(rate.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(rate)
                    }
                }.labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    .help("재생 속도").accessibilityLabel("재생 속도")
                HStack(spacing: 5) {
                    Button(action: playback.toggleMute) {
                        Image(systemName: playback.isMuted ? "speaker.slash.fill" :
                                (playback.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                            .frame(width: 18, height: 24)
                    }.buttonStyle(.borderless)
                        .accessibilityLabel(playback.isMuted ? "음소거 해제" : "녹음 음소거")
                        .help(playback.isMuted ? "음소거 해제" : "음소거")
                    Slider(value: Binding(get: { playback.effectiveVolume }, set: playback.setVolume), in: 0...1)
                        .controlSize(.small).frame(minWidth: 45, idealWidth: 65, maxWidth: 76)
                        .accessibilityLabel("재생 음량").accessibilityValue(playback.effectiveVolume.formatted(.percent.precision(.fractionLength(0))))
                        .help("재생 음량")
                }
                Menu {
                    if let audio = stored.audioURL {
                        filePathItem("녹음 파일", file: audio)
                        Button("Finder에서 녹음 파일 보기") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                            .disabled(!FileManager.default.fileExists(atPath: audio.path))
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("녹음 파일 더 보기")
            }.padding(.horizontal, 4).padding(.vertical, 5)
        }.onAppear { playback.prepare(stored) }
    }

    private func shortDuration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value < 60 ? "\(value)초" : value < 3600 ? "\(value / 60)분" : "\(value / 3600)시간 \(value % 3600 / 60)분"
    }

    private func statusColor(_ status: MeetingStatus) -> Color {
        switch status {
        case .recording: return RecorderTheme.recording
        case .failed, .interrupted: return .orange
        case .completed: return .secondary
        case .finalizing: return RecorderTheme.accent
        }
    }
}
