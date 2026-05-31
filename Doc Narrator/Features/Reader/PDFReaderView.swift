import SwiftUI
import PDFKit

struct PDFReaderView: UIViewRepresentable {
    let document: PDFDocument
    @ObservedObject var vm: ReaderViewModel
    let locateTrigger: Int

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemBackground

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        pdfView.addGestureRecognizer(tap)

        context.coordinator.pdfView = pdfView
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        let si = vm.currentSectionIndex
        let sj = vm.currentSentenceIndex
        let c  = context.coordinator
        // Only re-highlight when sentence changes or locate is triggered.
        guard si != c.lastSI || sj != c.lastSJ || locateTrigger != c.lastTrigger else { return }
        c.lastSI = si; c.lastSJ = sj; c.lastTrigger = locateTrigger
        // Pass sections by value so background thread never touches @MainActor state.
        let sections = vm.sections
        c.highlightCurrentSentence(pdfView: pdfView, document: document,
                                   sections: sections, si: si, sj: sj)
    }

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var vm: ReaderViewModel?
        weak var pdfView: PDFView?
        var lastSI = -1, lastSJ = -1, lastTrigger = -1
        private let tag = "tts_hl"

        init(vm: ReaderViewModel) { self.vm = vm }

        // MARK: Tap → jump to sentence

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let pdfView = g.view as? PDFView else { return }
            let pt = g.location(in: pdfView)
            guard let page = pdfView.page(for: pt, nearest: false) else { return }
            let pagePt = pdfView.convert(pt, to: page)
            guard let word = page.selectionForWord(at: pagePt)?.string,
                  !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            guard let vm else { return }
            let lower = word.lowercased()
            for (si, section) in vm.sections.enumerated() {
                for (sj, sentence) in section.sentences.enumerated() {
                    if sentence.lowercased().contains(lower) {
                        DispatchQueue.main.async { vm.jumpTo(sectionIndex: si, sentenceIndex: sj) }
                        return
                    }
                }
            }
        }

        // Coexist with PDFView's built-in pan/pinch gestures
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        // MARK: Highlight + scroll

        func highlightCurrentSentence(pdfView: PDFView, document: PDFDocument,
                                       sections: [PaperSection], si: Int, sj: Int) {
            guard si < sections.count else { return }
            let section = sections[si]
            guard sj < section.sentences.count else { return }
            let sentence = section.sentences[sj]
            // First 6 non-empty words — enough to be unique, short enough to be fast
            let query = sentence.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }.prefix(6).joined(separator: " ")

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak pdfView, weak document] in
                guard let self, let pdfView, let document else { return }
                let hits = document.findString(query, withOptions: .caseInsensitive)
                DispatchQueue.main.async { self.applyHighlight(pdfView: pdfView, document: document, hits: hits) }
            }
        }

        private func applyHighlight(pdfView: PDFView, document: PDFDocument, hits: [PDFSelection]) {
            // Remove previous highlight
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i) else { continue }
                page.annotations.filter { $0.userName == tag }.forEach { page.removeAnnotation($0) }
            }
            guard let sel = hits.first else { return }
            for line in sel.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let ann = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                ann.color = UIColor.systemYellow.withAlphaComponent(0.55)
                ann.userName = tag
                page.addAnnotation(ann)
            }
            pdfView.go(to: sel)   // scroll PDF to show the highlighted sentence
        }
    }
}
