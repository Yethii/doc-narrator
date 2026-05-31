import SwiftUI
import Combine
import PDFKit

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var isImporting = false
    @Published var importError: String?
    private let store = LibraryStore.shared

    var papers: [Paper] { store.papers }

    func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .failure(let e): importError = e.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            importPDF(from: url)
        }
    }

    private func importPDF(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else { importError = "Cannot read PDF."; return }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            let firstText = doc.page(at: 0)?.string ?? ""
            let title = PDFProcessor.parseTitle(from: doc, firstPageText: firstText)
            store.add(paper: Paper(title: title, bookmarkData: bookmark, isLocalCopy: false))
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    func deletePapers(at offsets: IndexSet) {
        offsets.forEach { store.remove(paper: store.papers[$0]) }
    }
}
