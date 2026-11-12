import SwiftUI

// Typography measured from the CPA iOS app: 17pt body with airy line height,
// wide gaps between paragraphs and compact list items with hanging indents.
private enum MarkdownStyle {
    static let bodySize: CGFloat = 17
    static let lineSpacing: CGFloat = 5.5
    static let blockSpacing: CGFloat = 28
    static let leadInSpacing: CGFloat = 12
    static let headingSpacing: CGFloat = 10
    static let itemSpacing: CGFloat = 8
    static let bulletWidth: CGFloat = 25
    static let markerGap: CGFloat = 4
    static let wideColumnLength = 24
    static let wideColumnWidth: CGFloat = 240
}

// Markdown subset rendered natively: headings, paragraphs, nested lists, quotes, tables, rules and fenced code.
struct MarkdownText: View {
    let text: String
    let wrapCode: Bool

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownBlock.parse(text), wrapCode: wrapCode, listDepth: 0, isCompact: false)
    }

    static func inline(_ value: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
        var result = AttributedString()
        for (link, range) in parsed.runs[\.link] {
            var part = AttributedString(parsed[range])
            for run in part.runs where run.inlinePresentationIntent?.contains(.code) == true {
                // Inline code stays monospaced but muted, so it does not outweigh the prose.
                part[run.range].swiftUI.foregroundColor = .secondary
            }
            result += part
            guard let link else {
                continue
            }
            // Links read as body text marked by a trailing arrow. Text selection bypasses custom text
            // renderers and the system underline overlaps CJK glyphs, so no underline is drawn.
            var arrow = AttributedString("\u{2009}\u{2197}")
            arrow.link = link
            arrow.swiftUI.font = .system(size: 14)
            result += arrow
        }
        return result
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let wrapCode: Bool
    let listDepth: Int
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, index == 0 ? 0 : spacing(after: blocks[index - 1], before: block))
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let value):
            Text(MarkdownText.inline(value))
                .font(.system(size: MarkdownStyle.bodySize))
                .lineSpacing(MarkdownStyle.lineSpacing)
                .tint(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let value, let level):
            Text(MarkdownText.inline(value))
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .lineSpacing(MarkdownStyle.lineSpacing)
                .tint(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let value):
            CodeBlock(text: value, wrapLines: wrapCode)
        case .list(let list):
            MarkdownListView(list: list, wrapCode: wrapCode, depth: listDepth)
        case .quote(let blocks):
            MarkdownBlocksView(blocks: blocks, wrapCode: wrapCode, listDepth: listDepth, isCompact: true)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color(.separator))
                        .frame(width: 3)
                }
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
                .padding(.vertical, 4)
        }
    }

    private func spacing(after previous: MarkdownBlock, before block: MarkdownBlock) -> CGFloat {
        if isCompact {
            return MarkdownStyle.itemSpacing
        }
        switch (previous, block) {
        case (.heading, _):
            return MarkdownStyle.headingSpacing
        case (.paragraph, .list), (.paragraph, .code), (.paragraph, .table):
            // A lead-in sentence stays close to the content it introduces.
            return MarkdownStyle.leadInSpacing
        default:
            return MarkdownStyle.blockSpacing
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1:
            22
        case 2:
            20
        case 3:
            18
        default:
            MarkdownStyle.bodySize
        }
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    let wrapCode: Bool
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownStyle.itemSpacing) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: MarkdownStyle.markerGap) {
                    marker(offset)
                    MarkdownBlocksView(blocks: item, wrapCode: wrapCode, listDepth: depth + 1, isCompact: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ offset: Int) -> some View {
        if let start = list.start {
            let last = start + max(list.items.count - 1, 0)
            Text(verbatim: "\(start + offset).")
                .font(.system(size: MarkdownStyle.bodySize))
                .monospacedDigit()
                .frame(width: max(MarkdownStyle.bulletWidth, CGFloat(String(last).count + 1) * 10), alignment: .trailing)
        } else {
            // A drawn dot is larger than the bullet glyph, matching CPA; it is centered on the CJK glyph middle.
            Group {
                if depth == 0 {
                    Circle()
                } else {
                    Circle().strokeBorder(lineWidth: 1.2)
                }
            }
            .frame(width: 6, height: 6)
            .frame(width: MarkdownStyle.bulletWidth)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5.5 }
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    // Long columns wrap at a fixed width; short ones keep their natural single-line width.
    private var wideColumns: Set<Int> {
        var columns = Set<Int>()
        for row in [table.header] + table.rows {
            for (column, cell) in row.enumerated() where cell.count > MarkdownStyle.wideColumnLength {
                columns.insert(column)
            }
        }
        return columns
    }

    var body: some View {
        let wide = wideColumns
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                row(table.header, wide: wide, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(height: 0.5)
                    row(cells, wide: wide, isHeader: false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            }
            .padding(0.5)
        }
    }

    private func row(_ cells: [String], wide: Set<Int>, isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                Text(MarkdownText.inline(cell))
                    .font(.system(size: 15, weight: isHeader ? .semibold : .regular))
                    .lineSpacing(3)
                    .tint(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: !wide.contains(column), vertical: true)
                    .frame(width: wide.contains(column) ? MarkdownStyle.wideColumnWidth : nil, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
        }
    }
}

struct CodeBlock: View {
    let text: String
    let wrapLines: Bool

    var body: some View {
        Group {
            if wrapLines {
                code
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    code
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var code: some View {
        Text(verbatim: text)
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(3)
            .textSelection(.enabled)
    }
}

struct MarkdownList: Hashable {
    // Number of the first item for ordered lists, nil for bullet lists.
    var start: Int?
    var items: [[MarkdownBlock]]
}

struct MarkdownTable: Hashable {
    var header: [String]
    var rows: [[String]]
}

enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(String, Int)
    case code(String)
    case list(MarkdownList)
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        parseLines(text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
    }

    private static func parseLines(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let fence = fence(trimmed) {
                flushParagraph()
                let indent = indentWidth(line)
                var code: [String] = []
                index += 1
                // An unterminated fence is still streaming and runs to the end.
                while index < lines.count {
                    let current = lines[index]
                    index += 1
                    if closes(current, fence: fence) {
                        break
                    }
                    code.append(dropIndent(current, upTo: indent))
                }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading.text, heading.level))
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var content = current.dropFirst()
                    if content.first == " " {
                        content = content.dropFirst()
                    }
                    quoted.append(String(content))
                    index += 1
                }
                blocks.append(.quote(parseLines(quoted)))
                continue
            }
            if let header = tableRow(trimmed), index + 1 < lines.count, isDelimiterRow(lines[index + 1], columns: header.count) {
                flushParagraph()
                var rows: [[String]] = []
                index += 2
                // Rows end at a blank line or at the start of another block.
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !startsBlock(row), listItem(lines[index]) == nil, let cells = tableRow(row) else {
                        break
                    }
                    rows.append((0..<header.count).map { $0 < cells.count ? cells[$0] : "" })
                    index += 1
                }
                blocks.append(.table(MarkdownTable(header: header, rows: rows)))
                continue
            }
            if listItem(line) != nil {
                flushParagraph()
                let (list, next) = parseList(lines, from: index)
                blocks.append(.list(list))
                index = next
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // Collects sibling items of the same kind; deeper-indented lines belong to the current item.
    private static func parseList(_ lines: [String], from start: Int) -> (MarkdownList, Int) {
        guard let first = listItem(lines[start]) else {
            return (MarkdownList(start: nil, items: []), start + 1)
        }
        var items: [[MarkdownBlock]] = []
        var index = start
        while index < lines.count,
              !isRule(lines[index].trimmingCharacters(in: .whitespaces)),
              let item = listItem(lines[index]),
              item.indent < first.indent + 2,
              (item.number == nil) == (first.number == nil) {
            var body = [item.text]
            // The item text itself may open a fence.
            var fenceMarker = fence(item.text.trimmingCharacters(in: .whitespaces))
            var sawBlank = false
            index += 1
            while index < lines.count {
                let current = lines[index]
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if let marker = fenceMarker {
                    body.append(dropIndent(current, upTo: item.contentIndent))
                    if closes(current, fence: marker) {
                        fenceMarker = nil
                    }
                } else if trimmed.isEmpty {
                    body.append("")
                    sawBlank = true
                } else if indentWidth(current) >= item.indent + 2 {
                    body.append(dropIndent(current, upTo: item.contentIndent))
                    // A nested item may open a fence right after its marker.
                    fenceMarker = fence(listItem(current)?.text.trimmingCharacters(in: .whitespaces) ?? trimmed)
                    sawBlank = false
                } else if !sawBlank && listItem(current) == nil && !startsBlock(trimmed) {
                    // Lazy continuation of the item text.
                    body.append(trimmed)
                } else {
                    break
                }
                index += 1
            }
            while body.last?.isEmpty == true {
                body.removeLast()
            }
            items.append(parseLines(body))
        }
        return (MarkdownList(start: first.number, items: items), index)
    }

    private static func listItem(_ line: String) -> (indent: Int, number: Int?, contentIndent: Int, text: String)? {
        let indent = indentWidth(line)
        let rest = line.drop { $0 == " " || $0 == "\t" }
        var number: Int?
        var afterMarker: Substring
        if let first = rest.first, "-*+\u{2022}".contains(first) {
            afterMarker = rest.dropFirst()
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count),
                  let delimiter = rest.dropFirst(digits.count).first,
                  delimiter == "." || delimiter == ")" else {
                return nil
            }
            number = Int(digits)
            afterMarker = rest.dropFirst(digits.count + 1)
        }
        guard afterMarker.first == " " || afterMarker.first == "\t" else {
            return nil
        }
        let markerWidth = rest.count - afterMarker.count
        let spaces = min(afterMarker.prefix { $0 == " " }.count, 4)
        let text = afterMarker.drop { $0 == " " || $0 == "\t" }
        return (indent, number, indent + markerWidth + max(spaces, 1), String(text))
    }

    private static func heading(_ trimmed: String) -> (text: String, level: Int)? {
        let level = trimmed.prefix { $0 == "#" }.count
        let rest = trimmed.dropFirst(level)
        guard (1...6).contains(level), rest.hasPrefix(" ") else {
            return nil
        }
        return (rest.trimmingCharacters(in: .whitespaces), level)
    }

    private static func fence(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return String(trimmed.prefix { $0 == marker.first })
        }
        return nil
    }

    private static func closes(_ line: String, fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(fence) && trimmed.allSatisfy { $0 == fence.first }
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func startsBlock(_ trimmed: String) -> Bool {
        fence(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">")
    }

    // Splits on unescaped pipes; `\|` becomes a literal pipe inside the cell.
    private static func tableRow(_ trimmed: String) -> [String]? {
        guard trimmed.contains("|") else {
            return nil
        }
        var cells: [String] = []
        var cell = ""
        var isEscaped = false
        for char in trimmed {
            if isEscaped {
                if char != "|" {
                    cell.append("\\")
                }
                cell.append(char)
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(char)
            }
        }
        if isEscaped {
            cell.append("\\")
        }
        cells.append(cell)
        // Outer pipes produce empty edge cells.
        if trimmed.hasPrefix("|") {
            cells.removeFirst()
        }
        if cells.count > 1, cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isDelimiterRow(_ line: String, columns: Int) -> Bool {
        guard let cells = tableRow(line.trimmingCharacters(in: .whitespaces)), cells.count == columns else {
            return false
        }
        return cells.allSatisfy { cell in
            var core = Substring(cell)
            if core.hasPrefix(":") {
                core = core.dropFirst()
            }
            if core.hasSuffix(":") {
                core = core.dropLast()
            }
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for char in line {
            if char == " " {
                width += 1
            } else if char == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    private static func dropIndent(_ line: String, upTo limit: Int) -> String {
        var width = 0
        var rest = Substring(line)
        while width < limit, let char = rest.first, char == " " || char == "\t" {
            width += char == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }
}
