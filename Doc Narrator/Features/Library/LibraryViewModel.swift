import SwiftUI
import Combine
import PDFKit
import UniformTypeIdentifiers

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
            if isPDF(url) {
                importPDF(from: url)
            } else {
                importTextFile(from: url)   // .txt / .md / .rtf → converted to PDF
            }
        }
    }

    private func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    /// Read a plain-text / Markdown / RTF file and render it into a PDF so it flows through the
    /// same reader + narration + intelligence pipeline as any PDF. (Word/EPUB aren't supported
    /// yet — they need a real document parser, not just a text read.)
    private func importTextFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let text: String
        let ext = url.pathExtension.lowercased()
        if ext == "rtf",
           let attr = try? NSAttributedString(url: url,
                                              options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil) {
            text = attr.string
        } else if let raw = try? String(contentsOf: url, encoding: .utf8) {
            text = raw
        } else if let data = try? Data(contentsOf: url) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            importError = "Couldn't read that file."; return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            importError = "That file has no readable text."; return
        }
        let title = url.deletingPathExtension().lastPathComponent
        do {
            let pdfURL = try DocumentImporter.makePDF(title: title, text: text)
            store.addGeneratedPDF(at: pdfURL, title: title)
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? "Couldn't import that file."
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
