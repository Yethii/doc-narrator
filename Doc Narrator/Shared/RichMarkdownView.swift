import SwiftUI

/// Shared, selectable Markdown renderer used by chat. Renders headings, bold/italic, bullet &
/// numbered lists, fenced code, and real tables. Inline LaTeX is converted to readable text
/// upstream by Markdown.plainText.
///
/// Selection: consecutive non-table blocks are merged into ONE AttributedString rendered by a
/// single `Text` — a single Text selects per-word reliably, whereas a stack of separate Texts
/// does not. Tables break the run and render as grids (not selectable as a unit, by nature).
struct RichMarkdownView: View {
    let markdown: String

    private var runs: [Run] { Run.build(from: MarkdownDocument.parse(markdown)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case .prose(let attr):
                    Text(attr)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let header, let rows):
                    TableView(header: header, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A contiguous run of prose (one selectable Text) or a table.
    private enum Run {
        case prose(AttributedString)
        case table(header: [String], rows: [[String]])

        static func build(from blocks: [MarkdownBlock]) -> [Run] {
            var runs: [Run] = []
            var current = AttributedString()
            var hasProse = false

            func flush() {
                if hasProse { runs.append(.prose(current)) }
                current = AttributedString(); hasProse = false
            }
            func newline() { if hasProse { current += AttributedString("\n") } }

            for block in blocks {
                switch block {
                case .heading(let level, let text):
                    newline()
                    var a = inline(text)
                    a.font = headingUIFont(level)
                    current += a; current += AttributedString("\n"); hasProse = true
                case .paragraph(let text):
                    newline(); current += body(inline(text)); hasProse = true
                case .bullet(let text):
                    newline(); current += body(inline("•  " + text)); hasProse = true
                case .numbered(let index, let text):
                    newline(); current += body(inline("\(index).  " + text)); hasProse = true
                case .code(let code):
                    newline()
                    var a = AttributedString(code)
                    a.font = .system(.callout, design: .monospaced)
                    current += a; hasProse = true
                case .table(let header, let rows):
                    flush()
                    runs.append(.table(header: header, rows: rows))
                }
            }
            flush()
            return runs
        }

        private static func body(_ a: AttributedString) -> AttributedString {
            var x = a
            if x.font == nil { x.font = .system(.body, design: .rounded) }
            return x
        }

        private static func inline(_ text: String) -> AttributedString {
            let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            if var a = try? AttributedString(markdown: text, options: opts) {
                a.font = .system(.body, design: .rounded)
                return a
            }
            return AttributedString(text)
        }

        private static func headingUIFont(_ level: Int) -> Font {
            switch level {
            case 1:  return .title2.weight(.bold)
            case 2:  return .title3.weight(.semibold)
            default: return .headline
            }
        }
    }
}

/// A simple bordered grid for a Markdown table. Horizontally scrollable so wide tables don't clip.
private struct TableView: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                gridRow(header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    gridRow(row, isHeader: false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gridRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { col in
                Text(col < cells.count ? cells[col] : "")
                    .font(isHeader ? .footnote.weight(.semibold) : .footnote)
                    .frame(minWidth: 90, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                if col < columnCount - 1 { Divider() }
            }
        }
        .background(isHeader ? Color(.secondarySystemBackground) : Color.clear)
    }
}
