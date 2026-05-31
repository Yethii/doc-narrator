import SwiftUI

struct ReaderView: View {
    let paper: Paper
    @StateObject private var vm: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var locateTrigger = 0
    @State private var showSummary = false

    init(paper: Paper) {
        self.paper = paper
        _vm = StateObject(wrappedValue: ReaderViewModel(
            paper: paper,
            settings: TTSSettings.load()
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let doc = vm.pdfDocument {
                PDFReaderView(document: doc, vm: vm, locateTrigger: locateTrigger)
            } else {
                // PDF not loaded yet — blank placeholder while .task runs
                Color(.systemBackground).ignoresSafeArea()
            }

            Divider()
            PlayerControlsView(vm: vm)
        }
        .navigationTitle(paper.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSummary = true } label: {
                    Image(systemName: "sparkles")
                }
                .disabled(vm.sections.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { locateTrigger += 1 } label: {
                    Image(systemName: "location.fill")
                }
                .disabled(vm.pdfDocument == nil)
            }
        }
        .sheet(isPresented: $showSummary) {
            SummaryView(vm: vm)
        }
        .task { await vm.load() }
        .overlay {
            if vm.state == .processing {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Analyzing paper…").font(.subheadline)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { if case .error = vm.state { return true }; return false },
            set: { _ in }
        )) {
            Button("OK") { dismiss() }
        } message: {
            if case .error(let msg) = vm.state { Text(msg) }
        }
    }
}
