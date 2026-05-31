import SwiftUI

/// The persistent AI workspace for a paper: summaries (general + custom), and (Phase D) chats.
/// Pushed from the reader's ✨ button; back arrow returns to the document.
struct IntelligenceHomeView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject private var llm = LLMService.shared
    @ObservedObject private var generator = SummaryGenerator.shared

    @State private var sessions = PaperSessions()
    @State private var askTopic = false
    @State private var topicText = ""
    @State private var activeJob: SummaryGenerator.Job?   // drives navigation to a live job

    private var liveJobs: [SummaryGenerator.Job] { generator.jobs(for: vm.paper.id) }

    var body: some View {
        List {
            if !llm.isReady {
                Section {
                    Label(llm.statusText, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Summaries") {
                // In-flight generations (keep running even if you leave this page).
                ForEach(liveJobs) { job in
                    NavigationLink {
                        SummaryArtifactView(paper: vm.paper, sections: vm.sections, job: job)
                    } label: {
                        jobRow(job)
                    }
                }

                ForEach(sessions.summaries) { artifact in
                    NavigationLink {
                        SummaryArtifactView(paper: vm.paper, sections: vm.sections, artifact: artifact)
                    } label: {
                        summaryRow(artifact)
                    }
                }
                .onDelete(perform: deleteSummaries)

                Button {
                    activeJob = generator.startGeneral(paper: vm.paper, sections: vm.sections)
                } label: {
                    Label("New general summary", systemImage: "sparkles")
                }
                .disabled(!llm.isReady)

                Button { topicText = ""; askTopic = true } label: {
                    Label("Summarize a topic…", systemImage: "text.magnifyingglass")
                }
                .disabled(!llm.isReady)
            }

            Section("Chat") {
                Label("Chat with PDF — coming soon", systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
            }

            Section {
                Label("Podcast — coming soon", systemImage: "waveform")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .alert("Summarize a topic", isPresented: $askTopic) {
            TextField("e.g. the evaluation method", text: $topicText)
            Button("Cancel", role: .cancel) {}
            Button("Summarize") {
                let t = topicText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    activeJob = generator.startCustom(topic: t, paper: vm.paper, sections: vm.sections)
                }
            }
        } message: {
            Text("What should the summary focus on? You'll be notified when it's ready.")
        }
        .navigationDestination(item: $activeJob) { job in
            SummaryArtifactView(paper: vm.paper, sections: vm.sections, job: job)
        }
    }

    private func jobRow(_ job: SummaryGenerator.Job) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.headline).lineLimit(1)
                Text("Generating…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func summaryRow(_ a: SummaryArtifact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(a.title).font(.headline).lineLimit(1)
            Text("\(a.modelLabel) · \(a.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        sessions = SessionStore.sessions(for: vm.paper.id)
        // One-time migration: fold a previously cached summary into a saved artifact.
        if sessions.summaries.isEmpty, let cached = vm.paper.cachedSummary, !cached.isEmpty {
            let a = SummaryArtifact(paperID: vm.paper.id, kind: .general,
                                    modelLabel: "Apple (built-in)", markdown: cached)
            SessionStore.addSummary(a)
            sessions = SessionStore.sessions(for: vm.paper.id)
        }
    }

    private func deleteSummaries(_ offsets: IndexSet) {
        for i in offsets { SessionStore.deleteSummary(id: sessions.summaries[i].id, paperID: vm.paper.id) }
        reload()
    }
}

// Allow a plain String to drive `.navigationDestination(item:)`.
extension String: @retroactive Identifiable {
    public var id: String { self }
}
