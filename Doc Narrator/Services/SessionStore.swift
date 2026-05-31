import Foundation

/// Persists AI artifacts (summaries, chats) as one JSON file per paper in the app sandbox.
/// Mirrors the lightweight Codable approach of LibraryStore; no global publishing — callers
/// load on demand and reload after mutating.
enum SessionStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func fileURL(_ paperID: UUID) -> URL {
        dir.appendingPathComponent("\(paperID.uuidString).json")
    }

    static func sessions(for paperID: UUID) -> PaperSessions {
        guard let data = try? Data(contentsOf: fileURL(paperID)),
              let decoded = try? JSONDecoder().decode(PaperSessions.self, from: data)
        else { return PaperSessions() }
        return decoded
    }

    static func save(_ sessions: PaperSessions, for paperID: UUID) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL(paperID), options: .atomic)
    }

    // MARK: - Summaries

    static func addSummary(_ a: SummaryArtifact) {
        var s = sessions(for: a.paperID)
        s.summaries.insert(a, at: 0)
        save(s, for: a.paperID)
    }

    static func updateSummary(_ a: SummaryArtifact) {
        var s = sessions(for: a.paperID)
        if let i = s.summaries.firstIndex(where: { $0.id == a.id }) { s.summaries[i] = a }
        else { s.summaries.insert(a, at: 0) }
        save(s, for: a.paperID)
    }

    static func deleteSummary(id: UUID, paperID: UUID) {
        var s = sessions(for: paperID)
        s.summaries.removeAll { $0.id == id }
        save(s, for: paperID)
    }

    // MARK: - Chats (Phase D)

    static func upsertChat(_ c: ChatSession) {
        var s = sessions(for: c.paperID)
        if let i = s.chats.firstIndex(where: { $0.id == c.id }) { s.chats[i] = c }
        else { s.chats.insert(c, at: 0) }
        save(s, for: c.paperID)
    }

    static func deleteChat(id: UUID, paperID: UUID) {
        var s = sessions(for: paperID)
        s.chats.removeAll { $0.id == id }
        save(s, for: paperID)
    }

    /// Remove all artifacts for a paper (call when the paper is deleted from the library).
    static func deleteAll(for paperID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(paperID))
    }
}
