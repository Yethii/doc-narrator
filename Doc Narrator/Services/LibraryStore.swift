import Foundation
import Combine
import PDFKit

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published private(set) var papers: [Paper] = []
    /// Set when the app is opened with an external PDF — LibraryView navigates to it.
    @Published var incomingPaper: Paper?
    private let key = "paperLibrary"
    private let docsURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    private init() { load() }

    func add(paper: Paper) {
        papers.append(paper)
        papers.sort { $0.dateAdded > $1.dateAdded }   // most recent first
        save()
    }

    /// Add a PDF we generated locally (from pasted text or a web page). We own the file, so it's
    /// a local copy that gets deleted when the paper is removed.
    func addGeneratedPDF(at url: URL, title: String) {
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            let paper = Paper(title: title.isEmpty ? "Untitled" : title, authors: [],
                              bookmarkData: bookmark, isLocalCopy: true)
            add(paper: paper)
            incomingPaper = paper
        } catch {}
    }

    func update(paper: Paper) {
        guard let idx = papers.firstIndex(where: { $0.id == paper.id }) else { return }
        papers[idx] = paper; save()
    }

    func remove(paper: Paper) {
        // Delete local copy if we own it
        if paper.isLocalCopy, let url = try? paper.resolveURL() {
            try? FileManager.default.removeItem(at: url)
            url.stopAccessingSecurityScopedResource()
        }
        SessionStore.deleteAll(for: paper.id)   // drop saved summaries/chats too
        papers.removeAll { $0.id == paper.id }; save()
    }

    // MARK: - Import from share sheet / Files / Safari

    /// Imports a PDF URL received via onOpenURL or the file importer.
    /// - In-place (Files app, iCloud): saves a security-scoped bookmark, no copy.
    /// - Inbox / temp (share sheet, browser): copies to app Documents, deduplicates by size+name.
    func importFromURL(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let pdfDoc = PDFDocument(url: url) else { return }

        let isInbox = url.path.contains("/Inbox/")
        let isInAppDocs = url.path.hasPrefix(docsURL.path)

        if isInbox || (!isInAppDocs && !canBookmarkInPlace(url)) {
            // Need to copy — check for duplicate first
            importCopying(url: url, pdfDoc: pdfDoc)
        } else {
            // In-place bookmark — check if already in library
            importInPlace(url: url, pdfDoc: pdfDoc)
        }
    }

    // MARK: - Private helpers

    private func importInPlace(url: URL, pdfDoc: PDFDocument) {
        // Check if already in library by resolving existing bookmarks
        for paper in papers {
            if let existing = try? paper.resolveURL() {
                let isSame = existing.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
                existing.stopAccessingSecurityScopedResource()
                if isSame { incomingPaper = paper; return }
            }
        }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            let firstText = pdfDoc.page(at: 0)?.string ?? ""
            let title = PDFProcessor.parseTitle(from: pdfDoc, firstPageText: firstText)
            let paper = Paper(title: title,
                              authors: [],
                              bookmarkData: bookmark,
                              isLocalCopy: false)
            add(paper: paper)
            incomingPaper = paper
        } catch {}
    }

    private func importCopying(url: URL, pdfDoc: PDFDocument) {
        let fileName = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // Deduplicate: same filename + same file size = same paper
        for paper in papers {
            if let existing = try? paper.resolveURL() {
                let existingSize = (try? existing.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let sameName = existing.lastPathComponent == fileName
                existing.stopAccessingSecurityScopedResource()
                if sameName && existingSize == size { incomingPaper = paper; return }
            }
        }

        // Copy to Documents
        var dest = docsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = docsURL.appendingPathComponent(UUID().uuidString + "-" + fileName)
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            let bookmark = try dest.bookmarkData(options: .minimalBookmark,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
            let firstText = pdfDoc.page(at: 0)?.string ?? ""
            let title = PDFProcessor.parseTitle(from: pdfDoc, firstPageText: firstText)
            let paper = Paper(title: title,
                              authors: [],
                              bookmarkData: bookmark,
                              isLocalCopy: true)
            add(paper: paper)
            incomingPaper = paper
            // Clean up inbox copy
            if url.path.contains("/Inbox/") {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {}
    }

    private func canBookmarkInPlace(_ url: URL) -> Bool {
        (try? url.bookmarkData(options: .minimalBookmark,
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil)) != nil
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Paper].self, from: data) else { return }
        papers = decoded.sorted { $0.dateAdded > $1.dateAdded }   // most recent first
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(papers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
