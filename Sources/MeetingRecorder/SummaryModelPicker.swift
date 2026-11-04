import RecorderCore
import SwiftUI

struct SummaryModelPicker: View {
    let agent: SummaryAgent
    let compact: Bool
    @AppStorage private var selection: String
    @State private var models: [SummaryModel] = []
    @State private var customID = ""
    @State private var editing = false

    init(agent: SummaryAgent, compact: Bool = false) {
        self.agent = agent
        self.compact = compact
        _selection = AppStorage(wrappedValue: "", agent.modelPreferenceKey)
    }

    private var selectedTitle: String {
        models.first { $0.id == selection }?.title ?? (selection.isEmpty ? "에이전트 기본값" : selection)
    }

    var body: some View {
        Group {
            if compact {
                menu.controlSize(.small).fixedSize()
            } else {
                LabeledContent("요약 모델") { menu }
            }
        }
        .task(id: agent) {
            let options = await Task.detached(priority: .utility) { [agent] in agent.modelOptions() }.value
            if !Task.isCancelled { models = options }
        }
        .alert("모델 ID 직접 입력", isPresented: $editing) {
            TextField("모델 ID", text: $customID)
            Button("취소", role: .cancel) { }
            Button("적용") {
                if let model = SummaryModel(customID) { selection = model.id }
            }.disabled(SummaryModel(customID) == nil)
        }
    }

    private var menu: some View {
        Menu {
            Picker("요약 모델", selection: $selection) {
                Text("에이전트 기본값").tag("")
                ForEach(models) { Text($0.title).tag($0.id) }
                if !selection.isEmpty, !models.contains(where: { $0.id == selection }) {
                    Text(selection).tag(selection)
                }
            }.pickerStyle(.inline)
            Divider()
            Button("모델 ID 직접 입력…") {
                customID = selection
                editing = true
            }
        } label: {
            Text(compact && selection.isEmpty ? "모델" : selectedTitle)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: compact && !selection.isEmpty ? 104 : nil)
        }
        .accessibilityLabel("요약 모델").accessibilityValue(selectedTitle)
        .accessibilityIdentifier(compact ? "meeting-summary-model" : "settings-summary-model")
        .help("\(agent.name) 요약 모델 · \(selectedTitle)")
    }
}
