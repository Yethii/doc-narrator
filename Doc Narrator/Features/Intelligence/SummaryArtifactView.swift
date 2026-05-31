import SwiftUI

/// Displays one summary (general or topic-focused): generates + saves on first open,
/// renders it readably, narrates it gap-free, and supports regenerate.
struct SummaryArtifactView: View {
    enum Mode { case existing(SummaryArtifact), generateGeneral, generateCustom(String) }

    let paper: Paper
    let sections: [PaperSection]
    let mode: Mode

    @ObservedObject private var llm = LLMService.shared
    @StateObject private var narrator = SentenceNarrator()

    @State private var artifactID: UUID?
    @State private var text = ""
    @State private var isStreaming = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let errorText {
                    ContentUnavailableView("Couldn't generate",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(errorText))
                } else if text.isEmpty && isStreaming {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Working on device…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NarratableTextView(markdown: text, narrator: narrator, isStreaming: isStreaming)
                }
            }
            .frame(maxHeight: .infinity)

            if !text.isEmpty && !isStreaming {
                Divider()
                NarrationControlsView(narrator: narrator)
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { regenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .disabled(isStreaming || !llm.isReady)
            }
        }
        .onAppear(perform: startIfNeeded)
        .onDisappear { task?.cancel(); llm.cancel(); narrator.stop() }
    }

    private var navTitle: String {
        switch mode {
        case .existing(let a): return a.title
        case .generateGeneral: return "General summary"
        case .generateCustom(let t): return "Summary · \(t)"
        }
    }

    private var kind: SummaryArtifact.Kind {
        switch mode {
        case .generateCustom: return .custom
        case .existing(let a): return a.kind
        case .generateGeneral: return .general
        }
    }

    private var topic: String? {
        switch mode {
        case .generateCustom(let t): return t
        case .existing(let a): return a.topic
        case .generateGeneral: return nil
        }
    }

    private func startIfNeeded() {
        if case .existing(let a) = mode {
            artifactID = a.id
            text = a.markdown
            return
        }
        generate()
    }

    private func regenerate() {
        task?.cancel(); narrator.stop()
        text = ""
        generate()
    }

    private func generate() {
        guard llm.isReady else { errorText = llm.statusText; return }
        errorText = nil
        isStreaming = true
        let stream = (kind == .custom && topic != nil)
            ? llm.focusedSummary(topic: topic!, sections: sections)
            : llm.summarize(sections: sections)
        task = Task {
            do {
                var acc = ""
                for try await delta in stream {
                    acc += delta
                    await MainActor.run { text = acc }
                }
                await MainActor.run { isStreaming = false; persist(acc) }
            } catch is CancellationError {
                await MainActor.run { isStreaming = false }
            } catch {
                await MainActor.run {
                    errorText = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                    isStreaming = false
                }
            }
        }
    }

    private func persist(_ markdown: String) {
        guard !markdown.isEmpty else { return }
        let id = artifactID ?? UUID()
        artifactID = id
        let artifact = SummaryArtifact(id: id, paperID: paper.id, kind: kind, topic: topic,
                                       modelLabel: llm.currentModelLabel, markdown: markdown)
        SessionStore.updateSummary(artifact)
    }
}
