import PDFKit
import Foundation

enum PDFProcessorError: LocalizedError {
    case cannotOpen, noSelectableText, emptyDocument

    var errorDescription: String? {
        switch self {
        case .cannotOpen:       return "Cannot open PDF file."
        case .noSelectableText: return "This PDF appears to be scanned. Doc Narrator requires text-selectable PDFs."
        case .emptyDocument:    return "PDF has no pages."
        }
    }
}

struct PDFProcessor {

    /// Returns (document, per-page strings). Throws if scanned or unreadable.
    static func extractPages(from url: URL) throws -> (doc: PDFDocument, pages: [String]) {
        guard let doc = PDFDocument(url: url) else { throw PDFProcessorError.cannotOpen }
        guard doc.pageCount > 0 else { throw PDFProcessorError.emptyDocument }
        var pages: [String] = []
        var nonEmptyCount = 0
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            pages.append(text)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { nonEmptyCount += 1 }
        }
        // >80% empty pages = scanned document
        if Double(nonEmptyCount) / Double(doc.pageCount) < 0.2 {
            throw PDFProcessorError.noSelectableText
        }
        return (doc, pages)
    }

    /// Lines in the first/last 3 lines of each page that appear on 3+ pages = running headers/footers.
    static func detectRunningHeaders(pages: [String]) -> Set<String> {
        guard pages.count >= 3 else { return [] }
        var freq: [String: Int] = [:]
        for pageText in pages {
            let lines = pageText.components(separatedBy: "\n")
            let candidates = Set(
                (lines.prefix(3) + lines.suffix(3))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.count < 120 }
            )
            for line in candidates { freq[line, default: 0] += 1 }
        }
        let threshold = max(3, Int(Double(pages.count) * 0.25))
        return Set(freq.filter { $0.value >= min(3, threshold) }.keys)
    }

    /// Title from PDF metadata, or first substantial non-empty line of page 1.
    static func parseTitle(from doc: PDFDocument, firstPageText: String) -> String {
        if let info = doc.documentAttributes,
           let title = info[PDFDocumentAttribute.titleAttribute] as? String,
           !title.isEmpty { return title }
        return firstPageText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.count > 5 }
            .map { String($0.prefix(120)) } ?? "Untitled"
    }
}
