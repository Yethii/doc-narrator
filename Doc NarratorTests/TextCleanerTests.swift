import Testing
import Foundation
@testable import Doc_Narrator

@Suite("TextCleaner")
struct TextCleanerTests {

    @Test("strips running headers")
    func stripsHeaders() {
        let pages = ["Journal Name\nThis is body text.\nFooter"]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: ["Journal Name", "Footer"])
        let text = sections.flatMap(\.sentences).joined()
        #expect(!text.contains("Journal Name"))
        #expect(text.contains("body text"))
    }

    @Test("removes citation brackets")
    func citationRemoval() {
        let pages = ["Achieves SOTA [1,2] on benchmarks [Smith et al., 2023]."]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: [])
        let text = sections.flatMap(\.sentences).joined()
        #expect(!text.contains("[1,2]"))
        #expect(!text.contains("[Smith"))
    }

    @Test("replaces inline math with spoken placeholder")
    func mathReplacement() {
        let pages = ["The loss $L = -y \\log p$ minimizes cross-entropy."]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: [])
        let text = sections.flatMap(\.sentences).joined()
        #expect(text.contains("mathematical expression"))
        #expect(!text.contains("$L"))
    }

    @Test("truncates at References section")
    func referenceTruncation() {
        let pages = ["Introduction\nThis is body.\nReferences\n[1] Smith, J. Some Paper."]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: [])
        let text = sections.flatMap(\.sentences).joined()
        #expect(text.contains("body"))
        #expect(!text.contains("Smith, J."))
    }

    @Test("detects numbered section header and strips number")
    func numberedHeader() {
        let pages = ["1. Introduction\nThis paper presents a novel approach."]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: [])
        let headerSection: PaperSection? = sections.first { $0.type == .sectionHeader }
        #expect(headerSection?.heading == "Introduction")
    }

    @Test("discards figure captions")
    func figureCaptionFiltered() {
        let pages = ["We see in Figure 2 that results improve.\nFigure 2. Results on benchmark A."]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: [])
        let text = sections.flatMap(\.sentences).joined()
        #expect(!text.contains("Figure 2. Results"))
        #expect(text.contains("We see in Figure 2"))
    }

    @Test("discards standalone page numbers")
    func pageNumberFiltered() {
        let pages = ["Body text here.\n4\nMore body text."]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: [])
        let text = sections.flatMap(\.sentences).joined()
        #expect(text.contains("Body text"))
        #expect(text.contains("More body"))
    }

    @Test("truncates at Bibliography too")
    func bibliographyTruncation() {
        let pages = ["Body text.\nBibliography\nSome citation entry."]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: [])
        let text = sections.flatMap(\.sentences).joined()
        #expect(!text.contains("citation entry"))
    }

    @Test("sectionHeader announcement is formatted correctly")
    func sectionAnnouncement() {
        let pages = ["Methods\nWe trained the model for 100 epochs."]
        let sections = TextCleaner.clean(pages: pages, runningHeaders: [])
        let header: PaperSection? = sections.first { $0.type == .sectionHeader }
        #expect(header?.announcement == "Section: Methods.")
    }
}
