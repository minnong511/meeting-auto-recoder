import RecorderAudio
import RecorderCore
import SwiftUI

enum RecorderSettingsPage: String, CaseIterable {
    case general = "일반", speech = "전사", connections = "연결"
}

struct RecorderSettingsView: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsConnectionDetails = false
    @State private var showsQuietApps = false
    @FocusState private var focusedSettingsPage: RecorderSettingsPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("설정 및 연결").font(RecorderTheme.heading(21))
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.top, 18)
            settingsNavigation
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            Divider()
            Form {
                switch model.settingsPage {
                case .general: general
                case .speech: speech
                case .connections: connections
                }
            }.formStyle(.grouped).frame(maxWidth: .infinity)
        }
        .frame(width: 580, height: 540).tint(RecorderTheme.accent)
        .modifier(CopyToastModifier(model: model))
        .task(id: model.settingsPage) {
            switch model.settingsPage {
            case .connections:
                model.refreshMCPConnections()
                await model.checkMCP()
            case .speech:
                model.refreshLocalModels()
                await model.checkSupport()
            case .general: break
            }
        }
    }

    private var settingsNavigation: some View {
        HStack(spacing: 4) {
            ForEach(RecorderSettingsPage.allCases, id: \.self) { page in
                Button {
                    model.settingsPage = page
                    focusedSettingsPage = page
                } label: {
                    Text(page.rawValue)
                        .font(RecorderTheme.heading(14))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.settingsPage == page ? RecorderTheme.canvas : Color.primary)
                .background(model.settingsPage == page ? RecorderTheme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .focusable()
                .focused($focusedSettingsPage, equals: page)
                .accessibilityLabel(page.rawValue)
                .accessibilityAddTraits(model.settingsPage == page ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RecorderTheme.hover, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("설정 항목")
        .onMoveCommand { direction in
            let pages = RecorderSettingsPage.allCases
            let index = pages.firstIndex(of: focusedSettingsPage ?? model.settingsPage) ?? 0
            let next: Int
            switch direction {
            case .left: next = (index + pages.count - 1) % pages.count
            case .right: next = (index + 1) % pages.count
            default: return
            }
            model.settingsPage = pages[next]
            focusedSettingsPage = pages[next]
        }
    }

    @ViewBuilder private var general: some View {
        Section("저장 폴더") {
            if let root = model.root {
                Text(root.path).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Finder에서 열기") { model.openFolder(root) }
                    Button("경로 복사") { model.copyPath(root) }
                    Spacer()
                    Button("변경…", action: model.chooseFolder).disabled(model.isBusy)
                }
            } else {
                Button("저장 폴더 선택…", action: model.chooseFolder).disabled(model.isBusy)
            }
        }
        ReleaseSettings(updates: model.updates, toggle: model.setUpdateNotifications)
        Section("녹음") {
            Toggle("녹음에서 알림음 제외", isOn: Binding(get: { model.excludesNotificationSounds }, set: model.setExcludesNotificationSounds))
                .disabled(model.isBusy)
            if model.excludesNotificationSounds {
                DisclosureGroup("전체 시스템 소리에서 제외할 앱", isExpanded: $showsQuietApps) {
                    Text("macOS 알림 · Slack · 카카오톡").font(.callout)
                    ForEach(model.additionalQuietApps, id: \.self) { id in
                        HStack {
                            Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id)
                            Spacer()
                            Button("제거") { model.removeQuietApp(id) }.disabled(model.isBusy)
                        }
                    }
                    Button("다른 앱 추가…", action: model.addQuietApp).disabled(model.isBusy)
                    Text("전체 시스템 녹음에서는 목록에 있는 앱의 통화도 제외됩니다. 해당 앱을 직접 선택하면 통화와 앱 자체 알림음이 함께 녹음될 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("노치에 녹음 상태 표시", isOn: Binding(get: { model.recordingIslandEnabled }, set: model.setRecordingIslandEnabled))
            Toggle("회의 앱 감지 알림", isOn: Binding(get: { model.meetingNotificationsEnabled }, set: model.setMeetingNotifications))
            Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var speech: some View {
        Section("음성 인식") {
            Picker("전사 모델", selection: Binding(get: { model.speechModel }, set: model.selectSpeechModel)) {
                ForEach(SpeechModel.allCases) { item in
                    Text(item.displayName + (item == .recommended ? " · 권장" : "")).tag(item)
                }
            }.disabled(model.isBusy)
            Text(model.speechModel.downloadDescription).font(.caption).foregroundStyle(.secondary)
            Toggle("마이크 팬 소음 억제", isOn: Binding(
                get: { model.speechModel == .largeV3Metal && model.microphoneFanSuppression },
                set: model.setMicrophoneFanSuppression))
                .disabled(model.isBusy || model.speechModel != .largeV3Metal)
                .help("Whisper large-v3 (Metal) 전용 · 첫 다운로드 약 20MB")
            if model.speechModel != .largeV3Metal {
                Text("팬 소음 억제는 Whisper large-v3 (Metal)에서 사용할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("문장 다듬기") {
            if model.localModels.isEmpty {
                Text("Ollama에 설치된 모델이 없습니다.").foregroundStyle(.secondary)
            } else {
                Picker("로컬 모델", selection: Binding(get: { model.selectedLocalModel }, set: model.selectLocalModel)) {
                    if !model.localModels.contains(where: { $0.id == model.selectedLocalModel }) {
                        Text(model.selectedLocalModel + " · 찾을 수 없음").tag(model.selectedLocalModel)
                    }
                    ForEach(model.localModels) { Text($0.id).tag($0.id) }
                }.disabled(model.isBusy)
            }
            Button("모델 목록 새로고침", action: model.refreshLocalModels)
        }
        Section("권한 및 진단") {
            Text(model.supportText).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("모델 확인") { Task { await model.checkSupport() } }.disabled(model.isBusy)
                Button("녹음 권한 설정") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Spacer()
                Button("15초 테스트") { dismiss(); model.beginTest() }.disabled(!model.canBegin)
            }
        }
    }

    @ViewBuilder private var connections: some View {
        Section("자동 요약") {
            Picker("요약 에이전트", selection: Binding(get: { model.summaryPreference }, set: model.setSummaryPreference)) {
                Text("자동").tag("auto")
                ForEach(SummaryAgent.allCases) { Text($0.name).tag($0.rawValue) }
            }.disabled(model.summarizingID != nil)
            if let host = model.summaryAgent {
                HStack {
                    Text(model.summaryExecutables[host] == nil ? host.name + " 실행 파일을 찾을 수 없습니다" : host.name + " 사용")
                    Spacer()
                    Button("실행 파일 선택…") { model.chooseSummaryExecutable(host) }.disabled(model.summarizingID != nil)
                }.font(.callout)
            }
            SummaryPromptSettings()
        }
        Section("LLM 연결") {
            if !model.mcpPresenceAvailable {
                Label("연결 상태를 확인할 수 없습니다", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            } else if model.mcpClients.isEmpty {
                Text("연결된 앱이 없습니다.").foregroundStyle(.secondary)
                Text("MCP 설정을 복사해 사용할 LLM 앱에 붙여넣으세요.").font(.caption).foregroundStyle(.secondary)
            } else {
                let groups = MCPClientPresentation.groups(model.mcpClients)
                ForEach(groups) { group in
                    HStack {
                        Label(group.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Text("\(group.sessions.count)개 세션").font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("연결 세부정보", isExpanded: $showsConnectionDetails) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading) {
                            Text(group.name).fontWeight(.medium)
                            Text(Array(Set(group.sessions.map(\.name))).sorted().joined(separator: ", "))
                            if !group.versions.isEmpty { Text(group.versions.joined(separator: ", ")) }
                        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
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
        }
    }
}

private struct ReleaseSettings: View {
    @ObservedObject var updates: RecorderUpdates
    var toggle: (Bool) -> Void

    private var status: String {
        if updates.isChecking { return "확인 중…" }
        if updates.failed { return "공개 버전을 확인하지 못했습니다." }
        if let next = updates.available { return "새 버전 \(next.description)" }
        if let latest = updates.latest { return "공개 버전 \(latest.description) · 업데이트 없음" }
        return "아직 확인하지 않음"
    }

    var body: some View {
        Section("업데이트") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("설치 버전 \(updates.installed?.description ?? "알 수 없음")")
                    Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("update-check-status")
                }
                Spacer()
                if updates.available != nil { Link("배포본 보기", destination: RecorderRelease.releasesPage) }
                Button("지금 확인") { Task { await updates.check(manual: true) } }.disabled(updates.isChecking)
            }
            Toggle("새 버전 알림", isOn: Binding(get: { updates.enabled }, set: toggle))
                .help("공개된 새 앱 버전을 하루 한 번 확인합니다.")
        }
    }
}

struct ReleaseBanner: View {
    @ObservedObject var updates: RecorderUpdates
    var body: some View {
        if let release = updates.banner {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").foregroundStyle(RecorderTheme.accent)
                Text("새 버전 \(release.description)").font(.callout.weight(.semibold))
                Spacer()
                Link("배포본 보기", destination: RecorderRelease.releasesPage)
                Button { updates.dismiss(release) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("이번 버전 알림 닫기")
                    .help("이번 버전 알림 닫기")
            }.padding(11).background(RecorderTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            .padding(.bottom, 8)
        }
    }
}
