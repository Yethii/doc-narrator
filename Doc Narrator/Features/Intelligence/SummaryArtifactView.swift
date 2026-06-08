import SwiftUI
import UIKit

/// Shows one summary. Generation runs in a background SummaryGenerator.Job (survives leaving
/// this page); this view just observes it. Saved summaries display statically.
struct SummaryArtifactView: View {
    let paper: Paper
    let sections: [PaperSection]
    let savedArtifact: SummaryArtifact?

    @State private var job: SummaryGenerator.Job?
    @StateObject private var narrator = SentenceNarrator()

    init(paper: Paper, sections: [PaperSection], artifact: SummaryArtifact) {
        self.paper = paper; self.sections = sections; self.savedArtifact = artifact
        _job = State(initialValue: nil)
    }

    init(paper: Paper, sections: [PaperSection], job: SummaryGenerator.Job) {
        self.paper = paper; self.sections = sections; self.savedArtifact = nil
        _job = State(initialValue: job)
    }

    var body: some View {
        Group {
            if let job {
                LiveSummaryContent(job: job, narrator: narrator, onRegenerate: regenerate)
            } else if let a = savedArtifact {
                SavedSummaryContent(markdown: a.markdown, narrator: narrator, onRegenerate: regenerate)
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { narrator.stop() }   // never cancels the generation job
    }

    private var navTitle: String { job?.title ?? savedArtifact?.title ?? "Summary" }

    private func regenerate() {
        let kind = job?.kind ?? savedArtifact?.kind ?? .general
        let topic = job?.topic ?? savedArtifact?.topic
        let id = job?.id ?? savedArtifact?.id
        narrator.stop()
        if kind == .custom, let topic {
            job = SummaryGenerator.shared.startCustom(topic: topic, paper: paper, sections: sections, reusing: id)
        } else {
            job = SummaryGenerator.shared.startGeneral(paper: paper, sections: sections, reusing: id)
        }
    }
}

/// Live view of an in-progress (or just-finished) generation job.
private struct LiveSummaryContent: View {
    @ObservedObject var job: SummaryGenerator.Job
    @ObservedObject var narrator: SentenceNarrator
    let onRegenerate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = job.error {
                ContentUnavailableView("Couldn't generate", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                    .frame(maxHeight: .infinity)
            } else {
                if job.isGenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Generating on device — you can leave this page; you'll be notified when it's ready.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.thinMaterial)
                }
                if job.text.isEmpty {
                    Spacer()
                } else {
                    NarratableTextView(markdown: job.text, narrator: narrator, isStreaming: job.isGenerating)
                }
            }

            if !job.text.isEmpty && !job.isGenerating {
                Divider()
                NarrationControlsView(narrator: narrator)
            }
        }
        .toolbar {
            if !job.text.isEmpty && !job.isGenerating {
                ToolbarItem(placement: .topBarTrailing) { SummaryShareMenu(markdown: job.text) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRegenerate) { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .disabled(job.isGenerating)
            }
        }
    }
}

/// Static view of a saved summary.
private struct SavedSummaryContent: View {
    let markdown: String
    @ObservedObject var narrator: SentenceNarrator
    let onRegenerate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NarratableTextView(markdown: markdown, narrator: narrator)
            Divider()
            NarrationControlsView(narrator: narrator)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SummaryShareMenu(markdown: markdown) }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRegenerate) { Label("Regenerate", systemImage: "arrow.clockwise") }
            }
        }
    }
}

/// Copy / Share menu for a summary. Copies clean plain text; shares the readable text too.
private struct SummaryShareMenu: View {
    let markdown: String
    private var plain: String { Markdown.plainText(markdown) }

    var body: some View {
        Menu {
            Button { UIPasteboard.general.string = plain } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            ShareLink(item: plain) { Label("Share…", systemImage: "square.and.arrow.up") }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }
}
