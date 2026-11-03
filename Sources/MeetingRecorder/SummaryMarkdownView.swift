import RecorderCore
import SwiftUI

struct SummaryMarkdownView: View {
    let markdown: String

    private func inline(_ text: String) -> Text {
        if let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(value)
        }
        return Text(verbatim: text)
    }

    var body: some View {
        let blocks = SummaryMarkdown.parse(markdown)
        return LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    inline(text).font(RecorderTheme.heading(level == 1 ? 22 : level == 2 ? 18 : 15))
                        .padding(.top, level == 1 ? 0 : 12).frame(maxWidth: .infinity, alignment: .leading)
                case let .paragraph(text):
                    inline(text).font(RecorderTheme.body()).lineSpacing(8).frame(maxWidth: .infinity, alignment: .leading)
                case let .list(marker, text):
                    HStack(alignment: .top, spacing: 10) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .leading)
                        inline(text).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(RecorderTheme.body()).lineSpacing(7)
                case let .table(rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                                GridRow(alignment: .top) {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        inline(cell).font(.system(size: 13, weight: rowIndex == 0 ? .semibold : .regular))
                                            .lineSpacing(5).frame(width: rows.first?.count == 2 ? 240 : 175, alignment: .leading)
                                            .padding(10)
                                    }
                                }.background(rowIndex == 0 ? RecorderTheme.hover.opacity(0.5) : .clear)
                                Divider().gridCellUnsizedAxes(.horizontal)
                            }
                        }
                    }.padding(.vertical, 4)
                case let .code(text):
                    Text(verbatim: text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RecorderTheme.hover, in: RoundedRectangle(cornerRadius: 10))
                case .divider:
                    Divider().overlay(RecorderTheme.border).padding(.vertical, 4)
                }
            }
        }
    }
}
