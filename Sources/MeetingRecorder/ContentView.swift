import AVKit
import RecorderAudio
import RecorderCore
import SwiftUI

private struct CopyToastModifier: ViewModifier {
    @ObservedObject var model: RecorderModel

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if model.isCopyNoticeVisible {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("복사했습니다!").font(.system(size: 13, weight: .semibold))
                        Text(model.clipboardMessage).font(.system(size: 10)).opacity(0.85)
                    }
                }
                .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10)
                .background(RecorderTheme.accent, in: RoundedRectangle(cornerRadius: 12))
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
    @State private var showsSettings = false
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
        NavigationSplitView {
            GeometryReader { geometry in
                sidebar.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            GeometryReader { geometry in
            VStack(spacing: 0) {
                if showsRecordingControls, let suggestion = model.meetingSuggestion { meetingAppBanner(suggestion) }
                if showsRecordingControls { recordingControls }
                else { collapsedRecordingControls }
                if let stored = model.selected { meetingDetail(stored) }
                else { emptyLibrary }
                workspaceFooter
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
        .sheet(isPresented: $showsSettings) { RecorderSettingsView(model: model) }
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
            model.refreshSummary()
        }
        .onAppear { model.refreshPolished() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshSummary()
            if showsSettings { model.refreshMCPConnections() }
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
            Button {
                model.selectedID = nil
                model.title = ""
                search = ""
                tab = "transcript"
                followLive = true
            } label: {
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
                    Image(systemName: "folder").foregroundStyle(RecorderTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("저장 위치").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(model.root?.lastPathComponent ?? "폴더를 선택하세요")
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button { if let root = model.root { model.copyPath(root) } } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.root == nil)
                        .help("저장 폴더 경로 복사").accessibilityLabel("저장 폴더 경로 복사")
                }
                Button { showsSettings = true } label: {
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

    private var collapsedRecordingControls: some View {
        HStack(spacing: 8) {
            if model.isPolishing {
                ProgressView().controlSize(.small)
                Text(model.polishProgress).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("회의 작업 공간").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { expandsRecordingControls = true } label: {
                Label("새 녹음", systemImage: "plus")
            }.buttonStyle(.bordered).font(.system(size: 12)).disabled(model.isBusy)
                .help("녹음 설정 열기")
        }.padding(.horizontal, 4).padding(.vertical, 10)
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
            Text("전체 시스템 소리").tag(RecordingTarget.systemID)
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
                Menu {
                    Button("이 회의 폴더") { model.copyPath(stored.directory) }
                    Button("녹음 파일 · audio.m4a") { model.copyPath(stored.directory.appendingPathComponent("audio.m4a")) }
                        .disabled(stored.meeting.audioFile == nil)
                    Button("대화록 · transcript.md") { model.copyPath(stored.directory.appendingPathComponent("transcript.md")) }
                    Button("요약 · summary.md") { model.copyPath(stored.directory.appendingPathComponent("summary.md")) }
                        .disabled(!FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent("summary.md").path))
                } label: { Label("경로 복사", systemImage: "doc.on.doc") }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                Menu {
                    Button("Markdown 열기", action: model.openTranscript)
                    Button("Finder에서 보기", action: model.revealSelected)
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
        }.padding(.horizontal, 4).padding(.top, 20).padding(.bottom, 16)
    }

    private func documentTabs(_ stored: StoredMeeting) -> some View {
        HStack(spacing: 24) {
            documentTab("대화록", symbol: "text.alignleft", value: "transcript")
            documentTab("다듬은 대화록", symbol: "text.badge.checkmark", value: "polished")
            documentTab("회의 요약", symbol: "sparkles", value: "summary")
            Spacer(minLength: 4)
            if model.selectedIsActive && tab == "transcript" {
                Toggle("자동 따라가기", isOn: $followLive).toggleStyle(.checkbox).font(.system(size: 10))
            }
            Button(action: model.copySummaryRequest) {
                Label("요약 요청 복사", systemImage: "arrow.up.right").font(.system(size: 11, weight: .medium))
            }.buttonStyle(.bordered).disabled(stored.meeting.status != .completed)
                .help("요약 요청을 복사합니다. MCP를 연결한 LLM 채팅에 붙여 넣으세요.").padding(.bottom, 10)
        }.padding(.horizontal, 4)
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
                            message: stored.meeting.audioFile != nil ? "이 녹음에서 인식된 말소리가 없습니다.\n아래에서 녹음 파일을 확인할 수 있습니다." : "녹음 중 인식된 대화가 여기에 표시됩니다.",
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
                    let summary = try? String(contentsOf: stored.directory.appendingPathComponent("summary.md"), encoding: .utf8)
                    if let summary {
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
                                    Text("회의의 핵심을 한눈에").font(.system(size: 17, weight: .semibold))
                                    Text("MCP를 연결한 LLM에 요약을 요청해 보세요.\n주요 내용, 결정 사항, 할 일이 저장되면 여기에 표시됩니다.")
                                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("요약 요청을 연결된 LLM에 전달하면, 저장된 결과가 이곳에 나타납니다.")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 16) {
                                Button(action: model.copySummaryRequest) { Label("요약 요청 복사", systemImage: "doc.on.doc") }
                                    .buttonStyle(.borderedProminent).disabled(stored.meeting.status != .completed)
                                Button("MCP 연결 설정") { showsSettings = true }
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
                    Text("원문을 보존하며 이 Mac에서 문장을 다듬습니다.").font(.system(size: 13, weight: .semibold))
                    Text("AI가 의미를 바꿀 수 있습니다. 원문과 녹음을 확인해 주세요.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("선택 모델: \(model.selectedLocalModel) · 완료된 문단은 다시 처리하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.polished.entries.isEmpty {
                        let models = Set(model.polished.entries.values.map { $0.model ?? model.polished.model })
                        Text("저장된 결과 모델: \(models.sorted().joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
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
        VStack(spacing: 24) {
            Spacer()
            documentEmptyState(title: "대화에 집중하세요. 기록은 여기에.", message: "녹음할 앱을 선택하고 녹음을 시작하세요.\n회의가 끝나면 화자별 대화록과 녹음 파일이 함께 저장됩니다.", symbol: "waveform.and.mic")
            HStack(spacing: 24) {
                Label("앱 소리 녹음", systemImage: "waveform")
                Label("화자별 대화록", systemImage: "person.2")
                Label("LLM 요약 연결", systemImage: "sparkles")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func audioBar(_ stored: StoredMeeting) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button { playback.toggle(stored) } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12))
                        .foregroundStyle(RecorderTheme.accent).frame(width: 34, height: 34)
                        .background(RecorderTheme.accent.opacity(0.09), in: Circle())
                }.buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityLabel(playback.isPlaying ? "녹음 일시정지" : "녹음 재생")
                Button { playback.skip(-10, in: stored) } label: { Image(systemName: "gobackward.10") }
                    .buttonStyle(.borderless).disabled(model.isBusy).help("10초 뒤로").accessibilityLabel("10초 뒤로")
                VStack(spacing: 3) {
                    Slider(value: Binding(get: { playback.position }, set: { playback.scrubPosition($0, in: stored) }),
                           in: 0...max(1, playback.duration), onEditingChanged: { playback.scrub($0, in: stored) })
                        .disabled(model.isBusy || playback.duration <= 0).accessibilityLabel("녹음 재생 위치")
                        .accessibilityValue(TranscriptMarkdown.timestamp(playback.position))
                    HStack {
                        Text(TranscriptMarkdown.timestamp(playback.position))
                        Spacer()
                        Text(TranscriptMarkdown.timestamp(playback.duration))
                    }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button { playback.skip(10, in: stored) } label: { Image(systemName: "goforward.10") }
                    .buttonStyle(.borderless).disabled(model.isBusy).help("10초 앞으로").accessibilityLabel("10초 앞으로")
                Menu {
                    Button("음성 경로 복사") { model.copyPath(stored.directory.appendingPathComponent("audio.m4a")) }
                    Button("Finder에서 보기", action: model.revealSelected)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("녹음 파일 더 보기")
            }.padding(.horizontal, 4).padding(.vertical, 12)
        }.onAppear { playback.prepare(stored) }
    }

    private var workspaceFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text("녹음과 전사는 이 Mac에서 처리됩니다").font(.system(size: 10))
            Spacer()
        }.foregroundStyle(.secondary).padding(.horizontal, 3)
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

private struct RecorderSettingsView: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsConnectionDetails = false

    private var connectionGroups: [MCPClientGroup] { MCPClientPresentation.groups(model.mcpClients) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("설정 및 연결").font(.system(size: 20, weight: .semibold))
                    Text("녹음 방식과 회의 기록의 저장 위치를 관리하세요.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Divider()
            Form {
                Section {
                    Picker("음성 인식 모델", selection: Binding(get: { model.speechModel }, set: model.selectSpeechModel)) {
                        ForEach(SpeechModel.allCases) { speechModel in
                            Text(speechModel.displayName + (speechModel == .recommended ? " · 권장" : "")).tag(speechModel)
                        }
                    }.disabled(model.isBusy)
                    Text(model.speechModel.downloadDescription + " · 선택한 모델은 첫 녹음 시 준비합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("권장 모델은 한국어 정확도와 자막 확정 시간을 기준으로 선택했습니다. Core ML 모델은 저장 공간을 적게 사용합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("녹음 중 확정된 문장을 그대로 저장합니다. 종료할 때는 마지막 미확정 문장만 마무리합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("전사", systemImage: "text.bubble") }
                Section {
                    if model.localModels.isEmpty {
                        Text("사용 가능한 로컬 모델이 없습니다. Ollama에서 모델을 내려받으세요.")
                    } else {
                        Picker("문장 다듬기 모델", selection: Binding(get: { model.selectedLocalModel }, set: model.selectLocalModel)) {
                            if !model.localModels.contains(where: { $0.id == model.selectedLocalModel }) {
                                Text("\(model.selectedLocalModel) · 찾을 수 없음").tag(model.selectedLocalModel)
                            }
                            ForEach(model.localModels) { item in Text(item.id).tag(item.id) }
                        }.disabled(model.isPolishing)
                    }
                    Button("모델 목록 새로고침", action: model.refreshLocalModels)
                    Text("다운로드된 Ollama 기본 라이브러리 모델을 이 Mac의 CPU에서 처리합니다. 모델에 따라 품질과 호환성이 다를 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("로컬 문장 다듬기", systemImage: "text.badge.checkmark") }
                Section {
                    Toggle("화면 상단에 녹음 상태 표시", isOn: Binding(get: { model.recordingIslandEnabled }, set: model.setRecordingIslandEnabled))
                    Text("녹음 중에는 화면 상단에서 상태를 확인하고 종료할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("녹음 상태", systemImage: "record.circle") }
                Section {
                    Toggle("회의 앱을 감지하면 macOS 알림", isOn: Binding(get: { model.meetingNotificationsEnabled }, set: model.setMeetingNotifications))
                    Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
                } header: { Label("알림", systemImage: "bell") }
                Section {
                    Text(model.root?.path ?? "아직 저장 폴더를 선택하지 않았습니다")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("폴더 변경", action: model.chooseFolder).disabled(model.isBusy)
                        Button("경로 복사") { if let root = model.root { model.copyPath(root) } }.disabled(model.root == nil)
                    }
                } header: { Label("저장 위치", systemImage: "folder") }
                Section {
                    Text("사용 중인 LLM에 MCP를 연결하면 대화록을 읽고, 요약을 이 앱에 저장할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.mcpPresenceAvailable {
                        Label("연결 상태를 확인할 수 없습니다", systemImage: "exclamationmark.circle")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        Text("이 Mac의 임시 연결 상태에 접근할 수 없습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !model.mcpClients.isEmpty {
                        ForEach(connectionGroups) { group in
                            HStack {
                                Label(group.name + " 연결됨", systemImage: "checkmark.circle.fill")
                                    .font(.callout.weight(.medium)).foregroundStyle(.green)
                                Spacer()
                                Text("\(group.sessions.count)개 세션").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        DisclosureGroup("연결 세부정보", isExpanded: $showsConnectionDetails) {
                            ForEach(connectionGroups) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name).font(.caption.weight(.medium))
                                    Text(Array(Set(group.sessions.map(\.name))).sorted().joined(separator: ", "))
                                    Text("세션 \(group.sessions.count)개" + (group.versions.isEmpty ? "" : " · 버전 " + group.versions.joined(separator: ", ")))
                                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.font(.caption)
                    } else {
                        Label("확인된 MCP 연결이 없습니다", systemImage: "circle.dashed")
                            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Text("LLM 앱에 MCP를 연결하면 여기에 표시됩니다. 업데이트 전에 연결했다면 해당 앱을 다시 시작해 주세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("MCP 연결 설정 복사", action: model.copyMCPConfiguration)
                        Button("연결 확인") { Task { await model.checkMCP() } }.disabled(model.isCheckingMCP)
                        if model.isCheckingMCP { ProgressView().controlSize(.small) }
                    }
                    if let diagnostic = model.mcpDiagnostic, !model.isCheckingMCP {
                        Label(diagnostic.message, systemImage: diagnostic.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption).foregroundStyle(diagnostic.succeeded ? .green : .orange)
                    }
                } header: { Label("LLM 연결", systemImage: "point.3.connected.trianglepath.dotted") }
                Section {
                    Text(model.supportText).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("모델 확인") { Task { await model.checkSupport() } }.disabled(model.isBusy)
                        Button("녹음 권한 설정") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        Spacer()
                        Button("15초 테스트") { dismiss(); model.beginTest() }.disabled(!model.canBegin)
                    }
                } header: { Label("권한 및 진단", systemImage: "checkmark.shield") }
            }.formStyle(.grouped)
        }.frame(width: 600, height: 650).tint(RecorderTheme.accent)
            .modifier(CopyToastModifier(model: model))
            .onAppear {
                model.refreshMCPConnections()
                Task { await model.checkMCP() }
                Task { await model.checkSupport() }
            }
    }
}
