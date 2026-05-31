import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @EnvironmentObject private var store: LibraryStore
    @State private var selectedPaper: Paper?
    @State private var showSettings = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.papers.isEmpty {
                    ContentUnavailableView(
                        "No Papers",
                        systemImage: "doc.text",
                        description: Text("Tap + to import a PDF")
                    )
                } else {
                    List {
                        ForEach(store.papers) { paper in
                            Button { selectedPaper = paper } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(paper.title)
                                        .font(.headline).lineLimit(2)
                                    Text(paper.dateAdded.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if paper.lastReadSentenceIndex > 0 {
                                        Text("Reading in progress")
                                            .font(.caption2).foregroundStyle(.blue)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: vm.deletePapers)
                    }
                }
            }
            .navigationTitle("Doc Narrator")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gear") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import PDF", systemImage: "plus") { vm.isImporting = true }
                }
            }
            .fileImporter(isPresented: $vm.isImporting,
                          allowedContentTypes: [.pdf],
                          allowsMultipleSelection: false) { result in
                vm.handleImport(result: result)
            }
            .alert("Import Error", isPresented: Binding(
                get: { vm.importError != nil },
                set: { if !$0 { vm.importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.importError ?? "")
            }
            .navigationDestination(item: $selectedPaper) { paper in
                ReaderView(paper: paper)
            }
            .onChange(of: store.incomingPaper) { _, paper in
                guard let paper else { return }
                selectedPaper = paper
                store.incomingPaper = nil
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}
