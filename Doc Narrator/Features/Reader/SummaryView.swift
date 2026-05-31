import SwiftUI

struct SummaryView: View {
    @ObservedObject var vm: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var llm = LLMService.shared
    @StateObject private var narrator = SentenceNarrator()

    @State private var text = ""
    @State private var isStreaming = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if let errorText {
                        ContentUnavailableView("Couldn't summarize",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text(errorText))
                    } else if text.isEmpty && isStreaming {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Summarizing on device…")
                                .font(.subheadline).foregroundStyle(.secondary)
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
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { stop(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { regenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                        .disabled(isStreaming || !llm.isReady)
                }
            }
            .onAppear(perform: start)
            .onDisappear { stop() }
        }
    }

    private func start() {
        if let cached = vm.paper.cachedSummary, !cached.isEmpty {
            text = cached; return
        }
        guard llm.isReady else { errorText = llm.statusText; return }
        errorText = nil
        isStreaming = true
        task = Task {
            do {
                var acc = ""
                for try await delta in llm.summarize(sections: vm.sections) {
                    acc += delta
                    await MainActor.run { text = acc }
                }
                await MainActor.run { isStreaming = false; vm.cacheSummary(acc) }
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

    private func regenerate() {
        stop()
        text = ""
        vm.paper.cachedSummary = nil
        start()
    }

    private func stop() {
        task?.cancel(); task = nil
        llm.cancel()
        narrator.stop()
    }
}
