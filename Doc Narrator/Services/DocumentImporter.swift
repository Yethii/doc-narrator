import UIKit
import CoreText
import PDFKit

/// Turns pasted text or a web page into a real PDF saved in the app's Documents folder, so it
/// flows through the same reader / narration / intelligence pipeline as any imported PDF.
enum DocumentImporter {

    enum ImportError: LocalizedError {
        case emptyText, badURL, fetchFailed, noReadableContent, pdfFailed
        var errorDescription: String? {
            switch self {
            case .emptyText:          return "There's no text to add."
            case .badURL:             return "That doesn't look like a valid web address."
            case .fetchFailed:        return "Couldn't load that page."
            case .noReadableContent:  return "Couldn't find readable text on that page."
            case .pdfFailed:          return "Couldn't create the document."
            }
        }
    }

    // MARK: - Paste text → PDF

    static func makePDF(title: String, text: String) throws -> URL {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ImportError.emptyText }
        guard let url = renderPDF(title: title, body: body) else { throw ImportError.pdfFailed }
        return url
    }

    // MARK: - Web link → PDF

    /// Fetch a page and extract readable text. Must touch NSAttributedString HTML parsing on main.
    @MainActor
    static func makePDFFromWeb(urlString: String) async throws -> (url: URL, title: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let pageURL = URL(string: normalized), pageURL.host != nil else { throw ImportError.badURL }

        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: pageURL) }
        catch { throw ImportError.fetchFailed }

        let html = String(decoding: data, as: UTF8.self)
        let title = htmlTitle(html) ?? pageURL.host ?? "Web Page"

        // NSAttributedString handles tags + entities; fall back to a crude strip if it fails.
        var text = ""
        if let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil) {
            text = attr.string
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = stripTags(html)
        }
        text = collapseBlankLines(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.noReadableContent
        }
        guard let url = renderPDF(title: title, body: text) else { throw ImportError.pdfFailed }
        return (url, title)
    }

    // MARK: - PDF rendering (paginated via Core Text)

    private static func renderPDF(title: String, body: String) -> URL? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter
        let margin: CGFloat = 54
        let textRect = pageRect.insetBy(dx: margin, dy: margin)

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4; para.paragraphSpacing = 10

        let attr = NSMutableAttributedString()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty {
            attr.append(NSAttributedString(string: cleanTitle + "\n\n", attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .paragraphStyle: para
            ]))
        }
        attr.append(NSAttributedString(string: body, attributes: [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: UIColor.black,
            .paragraphStyle: para
        ]))

        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { context in
            var pos = 0
            let total = attr.length
            while pos < total {
                context.beginPage()
                let ctx = context.cgContext
                ctx.textMatrix = .identity
                ctx.translateBy(x: 0, y: pageRect.height)
                ctx.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: textRect, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(pos, 0), path, nil)
                CTFrameDraw(frame, ctx)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length <= 0 { break }
                pos += visible.length
            }
        }

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(UUID().uuidString).pdf")
        do { try pdfData.write(to: url); return url } catch { return nil }
    }

    // MARK: - HTML helpers

    private static func htmlTitle(_ html: String) -> String? {
        guard let r = html.range(of: #"<title[^>]*>(.*?)</title>"#,
                                 options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = String(html[r])
        let inner = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let decoded = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    private static func stripTags(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"(?is)<script.*?</script>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<style.*?</style>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<(br|/p|/div|/h[1-6]|/li)[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(s)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&rsquo;", with: "'")
            .replacingOccurrences(of: "&lsquo;", with: "'")
            .replacingOccurrences(of: "&ldquo;", with: "\"")
            .replacingOccurrences(of: "&rdquo;", with: "\"")
    }

    private static func collapseBlankLines(_ s: String) -> String {
        s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
