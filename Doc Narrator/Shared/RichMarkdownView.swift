import SwiftUI

/// Shared, selectable Markdown renderer for all AI text (chat + summaries). Renders headings,
/// bold/italic, bullet & numbered lists, fenced code, and real tables. Inline LaTeX is converted
/// to readable text upstream by Markdown.plainText. Text is selectable for copy.
struct RichMarkdownView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] { MarkdownDocument.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let text):
            Text(inline(text)).readingStyle()
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).readingStyle()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .numbered(let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).").foregroundStyle(.secondary).monospacedDigit()
                Text(inline(text)).readingStyle()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))

        case .table(let header, let rows):
            TableView(header: header, rows: rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title2.weight(.bold)
        case 2:  return .title3.weight(.semibold)
        default: return .headline
        }
    }

    /// Inline bold/italic via AttributedString (this part of the API is reliable; block syntax
    /// is handled by MarkdownDocument so nothing leaks as raw "###" / "|").
    private func inline(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: text, options: opts) { return a }
        return AttributedString(text)
    }
}

/// A simple bordered grid for a Markdown table. Horizontally scrollable so wide tables don't
/// get clipped. Cells are selectable via the parent's textSelection.
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
                if col < columnCount - 1 {
                    Divider()
                }
            }
        }
        .background(isHeader ? Color(.secondarySystemBackground) : Color.clear)
    }
}
