import RecorderCore
import SwiftUI

struct SummaryPromptSettings: View {
    @State private var draft = MeetingSummaryPrompt.saved().editorial
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("요약 프롬프트").font(.headline)
                Spacer()
                Button("기본값 복원") { update(MeetingSummaryPrompt.defaultEditorial) }
                    .disabled(draft == MeetingSummaryPrompt.defaultEditorial)
            }
            TextEditor(text: Binding(get: { draft }, set: update))
                .font(.body).scrollContentBackground(.hidden).focused($editing)
                .padding(6).frame(height: 124)
                .background(RecorderTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(editing ? RecorderTheme.accent : RecorderTheme.border).allowsHitTesting(false) }
                .accessibilityLabel("요약 프롬프트")
                .accessibilityIdentifier("summary-prompt-editor")
            Text(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "비워 두면 기본 프롬프트를 사용합니다." : "자동 저장 · 다음 요약부터 적용")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .onChange(of: editing) { _, focused in
            if !focused, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = MeetingSummaryPrompt.defaultEditorial
            }
        }
    }

    private func update(_ text: String) {
        draft = text
        MeetingSummaryPrompt(text).save()
    }
}
