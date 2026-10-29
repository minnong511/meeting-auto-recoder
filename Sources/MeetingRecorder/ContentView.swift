import AVKit
import RecorderAudio
import RecorderCore
import SwiftUI

private enum RecorderTheme {
    static let accent = Color.indigo
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
}

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

    private var filteredMeetings: [StoredMeeting] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.meetings : model.meetings.filter {
            $0.meeting.title.localizedStandardContains(query)
        }
    }

    private var showsRecordingControls: Bool {
        model.isBusy || model.selected == nil || expandsRecordingControls
    }

    var body: some View {
        NavigationSplitView {
            GeometryReader { geometry in
                sidebar.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            GeometryReader { geometry in
            VStack(spacing: 16) {
                if showsRecordingControls, let suggestion = model.meetingSuggestion { meetingAppBanner(suggestion) }
                if showsRecordingControls { recordingControls }
                else { collapsedRecordingControls }
                if let stored = model.selected { meetingDetail(stored) }
                else { emptyLibrary }
                workspaceFooter
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RecorderTheme.canvas)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
        .tint(RecorderTheme.accent)
        .frame(minWidth: 940, minHeight: 680)
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
        .alert("확인이 필요합니다", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: model.selectedID) { _, _ in
            playback.reset()
            expandsRecordingControls = false
            if let stored = model.selected, stored.meeting.audioFile != nil { playback.prepare(stored) }
            model.refreshSummary()
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
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshSummary()
            if showsSettings { model.refreshMCPConnections() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(RecorderTheme.accent).frame(width: 36, height: 36)
                    .background(RecorderTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting Recorder").font(.system(size: 15, weight: .semibold))
                    Text("대화가 기록이 되는 곳").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)
            Button {
                model.selectedID = nil
                model.title = ""
                search = ""
                tab = "transcript"
                followLive = true
            } label: {
                Label("새 회의", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.isBusy)
            .padding(.horizontal, 20).padding(.bottom, 16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("회의 검색", text: $search).textFieldStyle(.plain).accessibilityLabel("회의 제목 검색")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("검색 지우기")
                }
            }
            .font(.system(size: 12)).padding(10)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 16)
            HStack {
                Text("회의 기록").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(model.meetings.count)").monospacedDigit().font(.system(size: 11))
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 6)
            List(selection: $model.selectedID) {
                ForEach(filteredMeetings) { stored in
                    meetingRow(stored).tag(stored.id)
                        .contextMenu {
                            Button(role: .destructive) { pendingDeletion = stored } label: {
                                Label("회의 삭제…", systemImage: "trash")
                            }.disabled(!model.canDeleteMeeting(stored))
                        }
                }
            }
            .listStyle(.sidebar)
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
            Divider().padding(.horizontal, 16)
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
            }.padding(20)
        }
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stored.meeting.status == .recording ? "waveform" : "doc.text")
                .font(.system(size: 14))
                .foregroundStyle(stored.meeting.status == .recording ? .red : RecorderTheme.accent)
                .frame(width: 30, height: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text(stored.meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(stored.meeting.startedAt, format: .dateTime.month().day().hour().minute())
                    if let end = stored.meeting.endedAt {
                        Text("·")
                        Text(shortDuration(end.timeIntervalSince(stored.meeting.startedAt)))
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if stored.meeting.status != .completed {
                    Label(stored.meeting.status.label, systemImage: stored.meeting.status == .recording ? "record.circle" : "info.circle")
                        .font(.system(size: 10)).foregroundStyle(statusColor(stored.meeting.status))
                }
            }
        }.padding(.vertical, 8)
    }

    private var collapsedRecordingControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.and.mic").foregroundStyle(.secondary)
            Text(model.recordingTarget?.name ?? "다음 녹음 준비")
                .font(.system(size: 12, weight: .medium))
            Text(model.microphoneEnabled ? "내 마이크 켜짐" : "내 마이크 꺼짐")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button { expandsRecordingControls = true } label: {
                Label("녹음 준비 펼치기", systemImage: "chevron.down")
            }.buttonStyle(.borderless).font(.system(size: 12))
        }.padding(.horizontal, 4).padding(.vertical, 3)
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.phase == .recording ? "회의 녹음 중" : "새로운 회의", systemImage: "waveform.and.mic")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
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
        .padding(20)
        .background(RecorderTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(RecorderTheme.border) }
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
            Circle().fill(model.phase == .recording ? .red : (model.phase == .idle ? (model.canBegin ? .green : .secondary) : RecorderTheme.accent))
                .frame(width: 5, height: 5)
            Text(model.phase == .recording ? "REC" : model.phase == .idle ? (model.canBegin ? "준비됨" : "앱 선택 필요") : model.phase == .preparing ? "준비 중" : "저장 중")
                .font(.system(size: 10, weight: .semibold))
        }.padding(.horizontal, 9).padding(.vertical, 5)
            .background(.primary.opacity(0.045), in: Capsule()).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var recordingAction: some View {
        if model.phase == .recording {
            Button(role: .destructive) { Task { await model.stop() } } label: {
                Label("녹음 종료", systemImage: "stop.fill").frame(minWidth: 100)
            }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
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
                }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(color.opacity(muted ? 0.025 : 0.055), in: RoundedRectangle(cornerRadius: 10))
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
            .background(RecorderTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(RecorderTheme.border) }
    }

    private func documentHeader(_ stored: StoredMeeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(stored.meeting.title).font(.system(size: 21, weight: .semibold)).lineLimit(2).textSelection(.enabled)
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
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
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
        }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
    }

    private func documentTabs(_ stored: StoredMeeting) -> some View {
        HStack(spacing: 24) {
            documentTab("대화록", symbol: "text.alignleft", value: "transcript")
            documentTab("회의 요약", symbol: "sparkles", value: "summary")
            Spacer(minLength: 4)
            if model.selectedIsActive && tab == "transcript" {
                Toggle("자동 따라가기", isOn: $followLive).toggleStyle(.checkbox).font(.system(size: 10))
            }
            Button(action: model.copySummaryRequest) {
                Label("LLM으로 요약", systemImage: "arrow.up.right").font(.system(size: 11, weight: .medium))
            }.buttonStyle(.bordered).disabled(stored.meeting.status != .completed)
                .help("요약 요청을 복사합니다. MCP를 연결한 LLM 채팅에 붙여 넣으세요.").padding(.bottom, 10)
        }.padding(.horizontal, 24)
    }

    private func documentTab(_ label: String, symbol: String, value: String) -> some View {
        Button { tab = value } label: {
            Label(label, systemImage: symbol)
                .font(.system(size: 12, weight: tab == value ? .semibold : .regular))
                .foregroundStyle(tab == value ? RecorderTheme.accent : .secondary)
                .padding(.vertical, 13).contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    if tab == value { Capsule().fill(RecorderTheme.accent).frame(height: 2) }
                }
        }.buttonStyle(.plain).accessibilityValue(tab == value ? "선택됨" : "")
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
                        }.padding(28).frame(maxWidth: 860, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center).textSelection(.enabled)
                    }
                } else {
                    let summary = try? String(contentsOf: stored.directory.appendingPathComponent("summary.md"), encoding: .utf8)
                    if let summary {
                        Text(LocalizedStringKey(summary)).font(.system(size: 14)).lineSpacing(7)
                            .textSelection(.enabled).padding(28)
                            .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
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

    private func playbackParagraph(_ paragraph: TranscriptPlaybackParagraph, in stored: StoredMeeting) -> some View {
        let color: Color = paragraph.source == .microphone ? RecorderTheme.accent : .teal
        let active = playback.meetingID == stored.id && playback.hasStarted &&
            playback.position >= paragraph.start && playback.position < paragraph.end
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: paragraph.source == .microphone ? "person.fill" : "person.wave.2.fill")
                .font(.system(size: 13)).foregroundStyle(color).frame(width: 32, height: 32)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(paragraph.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
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
                    Button { model.copyText(paragraph.text, message: "문단 복사됨") } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("문단 복사").accessibilityLabel("문단 복사")
                }.padding(.top, 7)
                Text(paragraph.text).font(.system(size: 14)).lineSpacing(7).foregroundStyle(.primary.opacity(0.9))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(10)
            .background(active ? RecorderTheme.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
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
            }.padding(.horizontal, 24).padding(.vertical, 12)
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
        case .recording: return .red
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
                    LabeledContent("음성 인식", value: "Whisper · 실시간")
                    Text("녹음 중 확정된 문장을 그대로 저장합니다. 종료할 때는 마지막 미확정 문장만 마무리합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("전사", systemImage: "text.bubble") }
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
            }
    }
}
