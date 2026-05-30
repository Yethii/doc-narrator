import Testing
import Foundation
@testable import Doc_Narrator

@Suite("Paper Model")
struct PaperTests {
    @Test("round-trips through JSON")
    func roundTrip() throws {
        let paper = Paper(title: "Test Paper", bookmarkData: Data([0x01, 0x02]))
        let data = try JSONEncoder().encode(paper)
        let decoded = try JSONDecoder().decode(Paper.self, from: data)
        #expect(decoded.id == paper.id)
        #expect(decoded.title == "Test Paper")
        #expect(decoded.lastReadSentenceIndex == 0)
    }

    @Test("announcement is nil for body sections")
    func announcementNilForBody() {
        let section = PaperSection(type: .body, heading: "Intro", sentences: ["Hello."])
        #expect(section.announcement == nil)
    }

    @Test("announcement returns formatted string for sectionHeader")
    func announcementFormatted() {
        let section = PaperSection(type: .sectionHeader, heading: "Methods")
        #expect(section.announcement == "Section: Methods.")
    }
}
