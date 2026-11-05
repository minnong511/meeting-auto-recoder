import Foundation
import RecorderCore
import SwiftUI

/// Ranges come from the original UTF-16 text, never from rendered Markdown or a
/// normalized search string. Invalid ranges are ignored rather than slicing a
/// composed character or displaying a different passage.
struct SearchHighlightedText: View {
    let text: String
    var ranges: [MeetingTextRange] = []

    var body: Text {
        var output = Text("")
        var cursor = text.startIndex
        for match in ranges.sorted(by: { $0.location < $1.location }) {
            guard match.location >= 0, match.length > 0,
                  match.location <= text.utf16.count,
                  match.length <= text.utf16.count - match.location,
                  let range = Range(NSRange(location: match.location, length: match.length), in: text),
                  range.lowerBound >= cursor else { continue }
            let prefix = Text(verbatim: String(text[cursor..<range.lowerBound]))
            let highlighted = Text(verbatim: String(text[range])).foregroundColor(RecorderTheme.accent).bold().underline()
            output = Text("\(output)\(prefix)\(highlighted)")
            cursor = range.upperBound
        }
        let suffix = Text(verbatim: String(text[cursor...]))
        return Text("\(output)\(suffix)")
    }
}

struct MeetingSearchResultsView: View {
    @ObservedObject var search: MeetingSearchModel
    let playbackEnabled: Bool
    let open: (MeetingSearchHit, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if search.isSearching {
                    ProgressView().controlSize(.small)
                    Text("기록 검색 중…")
                    Spacer()
                    Button("취소", action: search.cancel).buttonStyle(.plain).keyboardShortcut(.cancelAction)
                } else {
                    Text(search.wasCancelled ? "검색 취소됨" : "검색 결과")
                    Spacer()
                    Text("\(search.totalMatches)곳").monospacedDigit()
                    Button(action: search.runSearch) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).accessibilityLabel("검색 새로 고침")
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)

            if let error = search.errorMessage {
                VStack(alignment: .leading, spacing: 7) {
                    Label(error, systemImage: "exclamationmark.circle")
                    Button("다시 검색", action: search.runSearch)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
            }
            if !search.warnings.isEmpty {
                DisclosureGroup("읽지 못한 항목 \(search.warnings.count)개") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(search.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, 5)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 8)
            }
            if search.totalMatches > search.hits.count {
                Text("처음 \(search.hits.count)곳을 표시합니다. 검색어를 더 구체적으로 입력해 주세요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 8)
            }
            if search.hits.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: search.isSearching ? "text.magnifyingglass" : "magnifyingglass")
                        .font(.system(size: 22, weight: .light))
                    Text(search.isSearching ? "저장된 문서를 확인하고 있어요" : search.wasCancelled ? "검색을 취소했습니다" : search.errorMessage != nil ? "검색을 완료하지 못했습니다" : search.hasSearched ? "일치하는 내용이 없습니다" : "검색을 시작할 수 있습니다")
                        .font(.system(size: 12, weight: .medium))
                    if !search.isSearching && (search.wasCancelled || !search.hasSearched) {
                        Button("다시 검색", action: search.runSearch).buttonStyle(.bordered)
                    } else if search.hasSearched && !search.isSearching && search.errorMessage == nil {
                        Text("검색 범위를 바꾸거나 짧은 단어로 다시 찾아보세요.")
                            .font(.system(size: 11)).multilineTextAlignment(.center)
                    }
                }.foregroundStyle(.secondary).padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(meetingGroups) { group in
                            MeetingSearchMeetingSection(group: group, selectedHitID: search.selectedHit?.id,
                                                        playbackEnabled: playbackEnabled, open: open)
                        }
                    }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 20)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Group only the presentation. Every occurrence retains its original hit,
    /// document version, range and verified audio destination.
    private var meetingGroups: [MeetingSearchMeetingGroup] {
        var groups: [MeetingSearchMeetingGroup] = []
        var positions: [String: Int] = [:]
        for hit in search.hits {
            let key = hit.meetingID.uuidString + ":" + hit.directory.standardizedFileURL.path
            if let position = positions[key] {
                groups[position].hits.append(hit)
            } else {
                positions[key] = groups.count
                groups.append(MeetingSearchMeetingGroup(id: key, hits: [hit]))
            }
        }
        return groups
    }
}

private struct MeetingSearchMeetingGroup: Identifiable {
    let id: String
    var hits: [MeetingSearchHit]

    var passages: [MeetingSearchPassageGroup] {
        var groups: [MeetingSearchPassageGroup] = []
        var positions: [String: Int] = [:]
        for hit in hits {
            let key = hit.source.rawValue + ":" + hit.documentVersion + ":" + hit.blockID
            if let position = positions[key] {
                groups[position].hits.append(hit)
            } else {
                positions[key] = groups.count
                groups.append(MeetingSearchPassageGroup(id: key, hits: [hit]))
            }
        }
        return groups
    }
}

private struct MeetingSearchPassageGroup: Identifiable {
    let id: String
    var hits: [MeetingSearchHit]
}

private struct MeetingSearchMeetingSection: View {
    let group: MeetingSearchMeetingGroup
    let selectedHitID: String?
    let playbackEnabled: Bool
    let open: (MeetingSearchHit, Bool) -> Void

    var body: some View {
        if let first = group.hits.first {
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(first.title).font(RecorderTheme.heading(14)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(group.hits.count)곳")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary).fixedSize()
                    }
                    Text(first.date.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).year().month().day().hour().minute()))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.horizontal, 5)
                ForEach(group.passages) { passage in
                    MeetingSearchPassageRow(group: passage, selectedHitID: selectedHitID,
                                            playbackEnabled: playbackEnabled, open: open)
                }
            }
        }
    }
}

private struct MeetingSearchPassageRow: View {
    let group: MeetingSearchPassageGroup
    let selectedHitID: String?
    let playbackEnabled: Bool
    let open: (MeetingSearchHit, Bool) -> Void
    @State private var browsedHitID: String?

    private var currentIndex: Int {
        group.hits.firstIndex(where: { $0.id == selectedHitID }) ??
        group.hits.firstIndex(where: { $0.id == browsedHitID }) ?? 0
    }

    private var selected: Bool { group.hits.contains(where: { $0.id == selectedHitID }) }

    var body: some View {
        let hit = group.hits[currentIndex]
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Label(hit.source.label, systemImage: sourceIcon(hit.source))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if group.hits.count > 1 {
                    Text("\(currentIndex + 1) / \(group.hits.count)")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("이 문단에서 \(group.hits.count)곳 중 \(currentIndex + 1)번째 일치")
                    occurrenceButton(offset: -1, icon: "chevron.left", label: "이 문단의 이전 일치 구절")
                    occurrenceButton(offset: 1, icon: "chevron.right", label: "이 문단의 다음 일치 구절")
                }
            }
            Button { open(hit, false) } label: {
                SearchHighlightedText(text: hit.snippet, ranges: hit.snippetRanges)
                    .font(RecorderTheme.body(13)).lineSpacing(5).lineLimit(5)
                    .foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(hit.title), \(hit.source.label), \(hit.snippet)")
                .accessibilityHint("회의를 열고 검색 구절을 표시합니다")
            if let start = hit.playbackStart {
                HStack(spacing: 5) {
                    if let speaker = hit.speaker {
                        Text(speaker).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { open(hit, true) } label: {
                        Label(TranscriptMarkdown.timestamp(start), systemImage: "play.circle")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(minHeight: 28)
                    }.buttonStyle(.plain).foregroundStyle(RecorderTheme.accent).disabled(!playbackEnabled)
                        .accessibilityLabel(TranscriptMarkdown.timestamp(start) + "부터 검색한 발언 재생")
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RecorderTheme.accent.opacity(0.10) : RecorderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .modifier(QuietHover())
    }

    private func occurrenceButton(offset: Int, icon: String, label: String) -> some View {
        Button {
            let targetIndex = currentIndex + offset
            guard group.hits.indices.contains(targetIndex) else { return }
            let hit = group.hits[targetIndex]
            browsedHitID = hit.id
            open(hit, false)
        } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(RecorderTheme.accent)
            .disabled(!(group.hits.indices.contains(currentIndex + offset)))
            .accessibilityLabel(label)
    }

    private func sourceIcon(_ source: MeetingSearchSource) -> String {
        switch source {
        case .title: return "textformat"
        case .transcript: return "text.alignleft"
        case .summary: return "sparkles"
        }
    }
}

struct SearchDocumentBlockView: View {
    let block: MeetingSearchBlock
    let selected: Bool
    let active: Bool
    let ranges: [MeetingTextRange]
    let markdown: Bool
    let playbackEnabled: Bool
    var startOverride: Double? = nil
    let play: (() -> Void)?
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if block.speaker != nil || block.start != nil {
                HStack(spacing: 10) {
                    if let speaker = block.speaker {
                        Text(speaker).font(.system(size: 13, weight: .semibold))
                    }
                    if let start = startOverride ?? block.start, let play {
                        Button(action: play) {
                            Label(TranscriptMarkdown.timestamp(start), systemImage: active ? "speaker.wave.2.fill" : "play.circle")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(minHeight: 28)
                        }.buttonStyle(.plain).foregroundStyle(RecorderTheme.accent)
                            .disabled(!playbackEnabled).help("이 발언의 녹음 재생")
                            .accessibilityLabel(TranscriptMarkdown.timestamp(start) + "부터 문단 재생")
                            .accessibilityValue(active ? "현재 재생 구간" : "")
                    }
                    Spacer()
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc").font(.system(size: 12)).frame(width: 28, height: 28)
                    }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("문단 복사")
                }
            }
            if markdown && !selected {
                SummaryMarkdownView(markdown: block.text)
            } else {
                if markdown && selected {
                    Text("검색 구절 · Markdown 원문").font(.caption).foregroundStyle(.secondary)
                }
                SearchHighlightedText(text: block.text, ranges: ranges)
                    .font(RecorderTheme.body(15)).lineSpacing(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RecorderTheme.accent.opacity(0.08) : active ? RecorderTheme.accent.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(RecorderTheme.accent).frame(width: 3) }
            }
            .textSelection(.enabled)
    }
}
