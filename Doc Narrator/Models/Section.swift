import Foundation

enum SectionType: String, Codable, CaseIterable {
    case title
    case abstract
    case sectionHeader   // emits an announcement, no sentences to read
    case body
    case acknowledgments
}

struct PaperSection: Identifiable {
    let id: UUID
    let type: SectionType
    let heading: String?
    /// Cleaned, tokenized sentences ready for TTS
    let sentences: [String]

    init(type: SectionType, heading: String? = nil, sentences: [String] = []) {
        self.id = UUID(); self.type = type
        self.heading = heading; self.sentences = sentences
    }

    /// Spoken announcement when this section header is reached ("Section: Methods.")
    var announcement: String? {
        guard let heading, type == .sectionHeader else { return nil }
        return "Section: \(heading)."
    }
}
