import SwiftUI

struct ReaderView: View {
    let paper: Paper
    @StateObject private var vm: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var locateTrigger = 0

    init(paper: Paper) {
        self.paper = paper
        _vm = StateObject(wrappedValue: ReaderViewModel(
            paper: paper,
            settings: TTSSettings.load()
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(vm.sections.enumerated()), id: \.element.id) { idx, section in
                            sectionRow(section: section, index: idx)
                                .id(section.id)
                        }
                    }
                    .padding()
                }
                // Auto-scroll: follow the narration as the current sentence changes.
                .onChange(of: vm.currentSentenceIndex) { _, _ in
                    scrollToCurrentSentence(proxy)
                }
                .onChange(of: vm.currentSectionIndex) { _, _ in
                    scrollToCurrentSentence(proxy)
                }
                // Manual locate: trigger counter increments on button tap. The proxy
                // captured here is always the live one (re-evaluated each body render).
                .onChange(of: locateTrigger) { _, _ in
                    scrollToCurrentSentence(proxy)
                }
            }

            Divider()
            PlayerControlsView(vm: vm)
        }
        .navigationTitle(paper.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    locateTrigger += 1
                } label: {
                    Image(systemName: "location.fill")
                }
                .disabled(vm.sections.isEmpty)
            }
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

    /// Scrolls to the exact sentence being narrated. Body/abstract sentences carry
    /// "s-{section}-{sentence}" IDs; section-header rows only have the section UUID,
    /// so fall back to that when the current section is a header.
    private func scrollToCurrentSentence(_ proxy: ScrollViewProxy) {
        guard vm.currentSectionIndex < vm.sections.count else { return }
        let section = vm.sections[vm.currentSectionIndex]
        withAnimation(.easeInOut(duration: 0.3)) {
            if section.type == .sectionHeader {
                proxy.scrollTo(section.id, anchor: .center)
            } else {
                proxy.scrollTo("s-\(vm.currentSectionIndex)-\(vm.currentSentenceIndex)", anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func sectionRow(section: PaperSection, index: Int) -> some View {
        let isCurrent = index == vm.currentSectionIndex

        switch section.type {
        case .sectionHeader:
            Text(section.heading ?? "")
                .font(.title3.bold())
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .padding(.top, 8)
                .contentShape(Rectangle())
                .onTapGesture { vm.jumpTo(sectionIndex: index) }

        case .title:
            Text(section.sentences.first ?? "")
                .font(.title2.bold())

        case .abstract, .body, .acknowledgments:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(section.sentences.enumerated()), id: \.offset) { si, sentence in
                    let isActive = isCurrent && si == vm.currentSentenceIndex
                    Text(sentence)
                        .id("s-\(index)-\(si)")
                        .font(.body)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .padding(.horizontal, isActive ? 4 : 0)
                        .padding(.vertical, isActive ? 2 : 0)
                        .background(
                            isActive ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .animation(.easeInOut(duration: 0.15), value: isActive)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.jumpTo(sectionIndex: index, sentenceIndex: si) }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                isCurrent ? Color.accentColor.opacity(0.05) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                isCurrent
                    ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                    : nil
            )
        }
    }
}
