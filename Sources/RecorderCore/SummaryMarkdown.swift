import Foundation

public enum SummaryMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(marker: String, text: String)
    case table([[String]])
    case code(String)
    case divider
}

public enum SummaryMarkdown {
    public static func parse(_ markdown: String) -> [SummaryMarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [SummaryMarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll() }
        }
        func cells(_ line: String) -> [String] {
            var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        func isTableSeparator(_ line: String) -> Bool {
            let parts = cells(line)
            return line.contains("|") && !parts.isEmpty && parts.allSatisfy { cell in
                let stripped = cell.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
                return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
            }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }
            if trimmed.hasPrefix("```") {
                flush(); i += 1
                var code: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 }
                blocks.append(.code(code.joined(separator: "\n"))); continue
            }
            if i + 1 < lines.count && line.contains("|") && !line.contains("\\|") && isTableSeparator(lines[i + 1]) {
                flush(); var rows = [cells(line)]; i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].contains("\\|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                blocks.append(.table(rows)); continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush(); blocks.append(.heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1)))); i += 1; continue
            }
            if ["---", "***", "___"].contains(trimmed) { flush(); blocks.append(.divider); i += 1; continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush(); blocks.append(.list(marker: "•", text: String(trimmed.dropFirst(2)))); i += 1; continue
            }
            if let range = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush(); blocks.append(.list(marker: String(trimmed[range]).trimmingCharacters(in: .whitespaces), text: String(trimmed[range.upperBound...]))); i += 1; continue
            }
            paragraph.append(line); i += 1
        }
        flush()
        return blocks
    }
}
