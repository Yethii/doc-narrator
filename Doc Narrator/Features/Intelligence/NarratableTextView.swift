import SwiftUI

/// A readable, structured rendering of AI Markdown text whose sentences map 1:1 to the
/// narrator's queue: the spoken sentence is highlighted, and tapping a sentence jumps there.
struct NarratableTextView: View {
    let markdown: String
    @ObservedObject var narrator: SentenceNarrator
    var isStreaming: Bool = false

    @State private var segments: [TextSegment] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                        segmentView(seg, index: i)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { narrator.jump(to: i) }
                    }
                }
                .padding(20)
            }
            .onChange(of: narrator.currentIndex) { _, idx in
                guard idx >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
        .onAppear { rebuild() }
        .onChange(of: markdown) { _, _ in rebuild() }
    }

    private func rebuild() {
        segments = TextSegment.parse(markdown)
        // Feed the narrator only when the text is settled (not mid-stream), so playback
        // isn't reset on every token.
        if !isStreaming { narrator.load(sentences: segments.map(\.text)) }
    }

    @ViewBuilder
    private func segmentView(_ seg: TextSegment, index: Int) -> some View {
        let isCurrent = index == narrator.currentIndex
        Group {
            switch seg.kind {
            case .heading:
                Text(seg.text).font(.title3.weight(.semibold))
            case .bullet:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(seg.text)
                }
                .font(.body)
            case .body:
                Text(seg.text).font(.body)
            }
        }
        .lineSpacing(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.yellow.opacity(0.28) : .clear)
        )
    }
}

/// One narratable unit of AI text with a display style.
struct TextSegment {
    enum Kind { case heading, bullet, body }
    let text: String      // plain (Markdown stripped) — read aloud and displayed
    let kind: Kind

    /// Parse Markdown into ordered segments: headings and list items stay whole;
    /// paragraphs are split into sentences so highlighting tracks per sentence.
    static func parse(_ markdown: String) -> [TextSegment] {
        var segs: [TextSegment] = []
        var paragraph = ""

        func flushParagraph() {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = ""
            guard !p.isEmpty else { return }
            for s in Markdown.sentences(p) { segs.append(TextSegment(text: s, kind: .body)) }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); continue }
            if line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil {
                flushParagraph()
                segs.append(TextSegment(text: Markdown.plainText(line), kind: .heading))
            } else if line.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil {
                flushParagraph()
                segs.append(TextSegment(text: Markdown.plainText(line), kind: .bullet))
            } else {
                paragraph += paragraph.isEmpty ? line : " " + line
            }
        }
        flushParagraph()
        return segs
    }
}
