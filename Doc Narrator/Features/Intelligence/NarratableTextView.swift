import SwiftUI

/// Readable, selectable rendering of AI Markdown text (summaries). Uses the shared
/// RichMarkdownView so headings, bold, lists, code, and tables all render properly (never raw
/// "###" / "|"), and the narrator is fed from the SAME parser via load(markdown:) honoring the
/// user's narration settings (skip tables/equations/code; tables read row-wise).
struct NarratableTextView: View {
    let markdown: String
    @ObservedObject var narrator: SentenceNarrator
    var isStreaming: Bool = false

    var body: some View {
        ScrollView {
            RichMarkdownView(markdown: markdown)
                .padding(20)
        }
        .onAppear { feedNarrator() }
        .onChange(of: markdown) { _, _ in feedNarrator() }
        .onChange(of: isStreaming) { _, _ in feedNarrator() }
    }

    private func feedNarrator() {
        // Feed the narrator only when the text is settled (not mid-stream), so playback isn't
        // reset on every streamed token.
        if !isStreaming { narrator.load(markdown: markdown) }
    }
}

/// One narratable unit of AI text with a display style. Retained for any callers that still
/// build segments directly; primary rendering now goes through RichMarkdownView.
struct TextSegment {
    enum Kind { case heading, bullet, body }
    let text: String
    let kind: Kind

    static func parse(_ markdown: String) -> [TextSegment] {
        var segs: [TextSegment] = []
        for block in MarkdownDocument.parse(markdown) {
            switch block {
            case .heading(_, let text):
                segs.append(TextSegment(text: Markdown.plainText(text), kind: .heading))
            case .bullet(let text), .numbered(_, let text):
                segs.append(TextSegment(text: Markdown.plainText(text), kind: .bullet))
            case .paragraph(let text):
                for s in Markdown.sentences(text) { segs.append(TextSegment(text: s, kind: .body)) }
            case .code(let text):
                segs.append(TextSegment(text: text, kind: .body))
            case .table(let header, let rows):
                for row in rows {
                    segs.append(TextSegment(text: zip(header, row).map { "\($0): \($1)" }
                        .joined(separator: ", "), kind: .body))
                }
            }
        }
        return segs
    }
}
