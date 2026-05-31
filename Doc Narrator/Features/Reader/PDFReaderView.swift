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

        // Double-tap to jump to the tapped sentence.
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        pdfView.addGestureRecognizer(doubleTap)

        context.coordinator.pdfView = pdfView
        context.coordinator.jumpTap = doubleTap

        // PDFView installs its own double-tap-to-zoom recognizer lazily after layout.
        // Disable it so double-tap only jumps. Pinch-to-zoom is separate and stays.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            context.coordinator.disableBuiltInZoomTaps(in: pdfView)
        }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        let c = context.coordinator
        c.disableBuiltInZoomTaps(in: pdfView)

        let si = vm.currentSectionIndex
        let sj = vm.currentSentenceIndex
        guard si != c.lastSI || sj != c.lastSJ || locateTrigger != c.lastTrigger else { return }
        c.lastSI = si; c.lastSJ = sj; c.lastTrigger = locateTrigger
        let sections = vm.sections
        c.highlightCurrentSentence(pdfView: pdfView, document: document,
                                   sections: sections, si: si, sj: sj)
    }

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var vm: ReaderViewModel?
        weak var pdfView: PDFView?
        weak var jumpTap: UITapGestureRecognizer?
        var lastSI = -1, lastSJ = -1, lastTrigger = -1
        private let tag = "tts_hl"
        private var highlightGeneration = 0

        init(vm: ReaderViewModel) { self.vm = vm }

        // MARK: Keep PDFView's built-in double-tap zoom disabled

        func disableBuiltInZoomTaps(in view: UIView) {
            view.gestureRecognizers?.forEach { gr in
                if let t = gr as? UITapGestureRecognizer,
                   t.numberOfTapsRequired == 2,
                   t !== jumpTap {
                    t.isEnabled = false
                }
            }
            view.subviews.forEach { disableBuiltInZoomTaps(in: $0) }
        }

        // MARK: Double-tap → jump to the sentence AT the tap location

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let pdfView = g.view as? PDFView, let vm else { return }
            let pt = g.location(in: pdfView)
            guard let page = pdfView.page(for: pt, nearest: true) else { return }
            let pagePt = pdfView.convert(pt, to: page)

            // Character index at the tapped point → text from there forward.
            let idx = page.characterIndex(at: pagePt)
            guard idx >= 0, let pageText = page.string else {
                jumpByWord(at: pagePt, page: page, vm: vm)   // fallback for margin taps
                return
            }
            let ns = pageText as NSString
            let len = min(120, ns.length - idx)
            guard len > 0 else { return }
            let forward = ns.substring(with: NSRange(location: idx, length: len))
            let fc = compactAlnum(forward)               // alnum-only text starting at the tap

            // Match decreasing prefixes so a tap near a sentence boundary still resolves.
            for needleLen in [28, 20, 14, 9, 6] where fc.count >= needleLen {
                let needle = String(fc.prefix(needleLen))
                for (si, section) in vm.sections.enumerated() {
                    for (sj, sentence) in section.sentences.enumerated()
                    where compactAlnum(sentence).contains(needle) {
                        DispatchQueue.main.async { vm.jumpTo(sectionIndex: si, sentenceIndex: sj) }
                        return
                    }
                }
            }
        }

        private func jumpByWord(at pagePt: CGPoint, page: PDFPage, vm: ReaderViewModel) {
            guard let word = page.selectionForWord(at: pagePt)?.string,
                  !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let lower = word.lowercased()
            for (si, section) in vm.sections.enumerated() {
                for (sj, sentence) in section.sentences.enumerated()
                where sentence.lowercased().contains(lower) {
                    DispatchQueue.main.async { vm.jumpTo(sectionIndex: si, sentenceIndex: sj) }
                    return
                }
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        // MARK: Highlight + scroll

        func highlightCurrentSentence(pdfView: PDFView, document: PDFDocument,
                                       sections: [PaperSection], si: Int, sj: Int) {
            guard si < sections.count else { return }
            let section = sections[si]
            guard sj < section.sentences.count else { return }
            let sentence = section.sentences[sj]

            highlightGeneration += 1
            let gen = highlightGeneration

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak pdfView, weak document] in
                guard let self, let pdfView, let document else { return }
                guard self.highlightGeneration == gen else { return }

                let selection = self.sentenceSelection(sentence: sentence, document: document)

                DispatchQueue.main.async {
                    guard self.highlightGeneration == gen else { return }
                    self.applyHighlight(pdfView: pdfView, document: document, selection: selection)
                }
            }
        }

        /// Locate the sentence's page, then span from its start anchor to its end anchor.
        private func sentenceSelection(sentence: String, document: PDFDocument) -> PDFSelection? {
            let words = sentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard words.count >= 1 else { return nil }

            // Find the page using a leading phrase (try 4 → 2 words).
            var anchor: PDFSelection?
            for k in [4, 3, 2] where words.count >= k {
                let q = words.prefix(k).joined(separator: " ")
                if let s = document.findString(q, withOptions: .caseInsensitive).first { anchor = s; break }
            }
            if anchor == nil {
                anchor = document.findString(words[0], withOptions: .caseInsensitive).first
            }
            guard let anchorSel = anchor, let page = anchorSel.pages.first else { return anchor }

            return spanSelection(sentence: sentence, words: words, on: page) ?? anchorSel
        }

        /// Build a selection covering start→end of the sentence on `page`, matching
        /// alphanumeric-only so hyphenation / ligatures / spacing never break it.
        private func spanSelection(sentence: String, words: [String], on page: PDFPage) -> PDFSelection? {
            guard let pageText = page.string, !pageText.isEmpty else { return nil }

            // Compact (alnum-only) page text + map each compact char → UTF-16 offset.
            var compact = ""
            var offsets: [Int] = []
            var utf16Index = 0
            for ch in pageText {
                let l = String(ch).utf16.count
                if ch.isLetter || ch.isNumber {
                    compact.append(ch)
                    offsets.append(utf16Index)
                }
                utf16Index += l
            }
            offsets.append(utf16Index)   // sentinel
            guard !compact.isEmpty else { return nil }

            // Start anchor (leading words).
            var startIdx: Int?
            for k in [6, 5, 4, 3] where words.count >= k {
                let needle = compactAlnum(words.prefix(k).joined(separator: " "))
                guard needle.count >= 4, let r = compact.range(of: needle, options: .caseInsensitive)
                else { continue }
                startIdx = compact.distance(from: compact.startIndex, to: r.lowerBound)
                break
            }
            guard let sIdx = startIdx else { return nil }

            // End anchor (trailing words), searched only after the start.
            let expected = compactAlnum(sentence).count
            let searchFrom = compact.index(compact.startIndex, offsetBy: sIdx)
            let tail = compact[searchFrom...]
            var endIdx: Int?
            for k in [5, 4, 3, 2] where words.count >= k {
                let needle = compactAlnum(words.suffix(k).joined(separator: " "))
                guard needle.count >= 3, let r = tail.range(of: needle, options: .caseInsensitive)
                else { continue }
                endIdx = compact.distance(from: compact.startIndex, to: r.upperBound)
                break
            }

            // Validate span length; reject a runaway end anchor that matched a duplicate.
            let upper: Int
            if let eIdx = endIdx, eIdx > sIdx, (eIdx - sIdx) <= expected * 2 + 20 {
                upper = eIdx
            } else {
                // End not found / implausible: highlight just the leading anchor.
                upper = min(sIdx + max(expected, 4), offsets.count - 1)
            }

            let utf16Start = offsets[sIdx]
            let utf16End = offsets[min(upper, offsets.count - 1)]
            guard utf16End > utf16Start else { return nil }
            return page.selection(for: NSRange(location: utf16Start, length: utf16End - utf16Start))
        }

        private func compactAlnum(_ s: String) -> String {
            String(s.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }.map(Character.init))
        }

        private func applyHighlight(pdfView: PDFView, document: PDFDocument, selection: PDFSelection?) {
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i) else { continue }
                page.annotations.filter { $0.userName == tag }.forEach { page.removeAnnotation($0) }
            }
            guard let sel = selection else { return }
            for line in sel.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let ann = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                ann.color = UIColor.systemYellow.withAlphaComponent(0.6)
                ann.userName = tag
                page.addAnnotation(ann)
            }
            pdfView.go(to: sel)
        }
    }
}
