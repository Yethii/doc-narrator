import Foundation

struct Paper: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var authors: [String]
    /// Security-scoped bookmark — persists file access across launches
    var bookmarkData: Data
    var lastReadSentenceIndex: Int
    var dateAdded: Date
    /// true = we own a copy in Documents (delete on remove); false = in-place bookmark
    var isLocalCopy: Bool

    init(id: UUID = UUID(), title: String, authors: [String] = [],
         bookmarkData: Data, lastReadSentenceIndex: Int = 0,
         dateAdded: Date = .now, isLocalCopy: Bool = true) {
        self.id = id; self.title = title; self.authors = authors
        self.bookmarkData = bookmarkData
        self.lastReadSentenceIndex = lastReadSentenceIndex
        self.dateAdded = dateAdded; self.isLocalCopy = isLocalCopy
    }

    /// Resolves bookmark to URL and starts security scope.
    /// Caller MUST call url.stopAccessingSecurityScopedResource() when done.
    func resolveURL() throws -> URL {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData,
                          options: .withoutUI, relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}
