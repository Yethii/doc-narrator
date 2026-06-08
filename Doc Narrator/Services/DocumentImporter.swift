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
        let attr = bodyAttributedString(plain: body)
        guard let url = renderPDF(title: title, content: attr) else { throw ImportError.pdfFailed }
        return url
    }

    // MARK: - Markdown → formatted PDF

    /// Render Markdown into a PROPERLY FORMATTED PDF: real headings, bold, and bullets, with all
    /// Markdown syntax (`#`, `**`, `-`, escapes) removed — so the page looks like a document and
    /// the narrator never reads "asterisk asterisk" or stray backslashes.
    static func makePDF(title: String, markdown: String) throws -> URL {
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ImportError.emptyText }
        let attr = markdownAttributedString(body)
        guard let url = renderPDF(title: title, content: attr) else { throw ImportError.pdfFailed }
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
        guard let url = renderPDF(title: title, content: bodyAttributedString(plain: text)) else {
            throw ImportError.pdfFailed
        }
        return (url, title)
    }

    // MARK: - PDF rendering (paginated via Core Text)

    /// Plain body text as an attributed string (no Markdown interpretation).
    private static func bodyAttributedString(plain: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4; para.paragraphSpacing = 10
        return NSAttributedString(string: plain, attributes: [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: UIColor.black,
            .paragraphStyle: para
        ])
    }

    /// Convert Markdown to a styled attributed string using the SHARED MarkdownDocument parser
    /// (same one the on-screen renderer + narrator use): headings become bold/larger, `**bold**`
    /// becomes bold, lists become real bullets/numbers, tables become aligned text, and Markdown
    /// punctuation/escapes/LaTeX are resolved so nothing raw shows or is later read aloud.
    private static func markdownAttributedString(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineSpacing = 4; bodyPara.paragraphSpacing = 10
        let headingPara = NSMutableParagraphStyle()
        headingPara.lineSpacing = 4; headingPara.paragraphSpacing = 6; headingPara.paragraphSpacingBefore = 12

        for block in MarkdownDocument.parse(markdown) {
            switch block {
            case .heading(let level, let text):
                let size: CGFloat = level <= 1 ? 20 : level == 2 ? 18 : 16
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: .bold),
                    .foregroundColor: UIColor.black, .paragraphStyle: headingPara]))
            case .paragraph(let text):
                out.append(styledInline(stripInlineMarkdown(text) + "\n", base: bodyPara))
            case .bullet(let text):
                out.append(styledInline("•  " + stripInlineMarkdown(text) + "\n", base: bodyPara))
            case .numbered(let index, let text):
                out.append(styledInline("\(index).  " + stripInlineMarkdown(text) + "\n", base: bodyPara))
            case .code(let code):
                out.append(NSAttributedString(string: code + "\n", attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: UIColor.darkGray, .paragraphStyle: bodyPara]))
            case .table(let header, let rows):
                out.append(tableAttributedString(header: header, rows: rows, base: bodyPara))
            }
        }
        return out
    }

    /// Render a Markdown table as monospaced, column-aligned text in the PDF.
    private static func tableAttributedString(header: [String], rows: [[String]],
                                              base: NSParagraphStyle) -> NSAttributedString {
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        var widths = [Int](repeating: 0, count: cols)
        func cell(_ r: [String], _ c: Int) -> String { c < r.count ? r[c] : "" }
        for c in 0..<cols {
            widths[c] = max(cell(header, c).count, rows.map { cell($0, c).count }.max() ?? 0)
        }
        func rowLine(_ r: [String]) -> String {
            (0..<cols).map { cell(r, $0).padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: "  |  ")
        }
        var lines = [rowLine(header)]
        lines.append((0..<cols).map { String(repeating: "-", count: widths[$0]) }.joined(separator: "--+--"))
        lines.append(contentsOf: rows.map(rowLine))
        return NSAttributedString(string: lines.joined(separator: "\n") + "\n", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.black, .paragraphStyle: base])
    }

    /// Build an attributed line, rendering **bold** / __bold__ spans as bold; everything else
    /// body weight. Markdown markers themselves are removed.
    private static func styledInline(_ line: String, base: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = UIFont.systemFont(ofSize: 15)
        let bold = UIFont.boldSystemFont(ofSize: 15)
        let scanner = line as NSString
        let boldRegex = try? NSRegularExpression(pattern: #"(\*\*|__)(.+?)\1"#)
        var cursor = 0
        let full = NSRange(location: 0, length: scanner.length)
        let matches = boldRegex?.matches(in: line, range: full) ?? []
        func append(_ s: String, font: UIFont) {
            result.append(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: UIColor.black, .paragraphStyle: base]))
        }
        for m in matches {
            if m.range.location > cursor {
                append(scanner.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), font: body)
            }
            append(scanner.substring(with: m.range(at: 2)), font: bold)
            cursor = m.range.location + m.range.length
        }
        if cursor < scanner.length {
            append(scanner.substring(with: NSRange(location: cursor, length: scanner.length - cursor)), font: body)
        }
        return result
    }

    /// Remove inline Markdown punctuation and escapes that shouldn't be shown or spoken.
    private static func stripInlineMarkdown(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)   // code
        t = t.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression) // image
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)  // link
        t = t.replacingOccurrences(of: #"(\*\*|\*|__|_|~~)"#, with: "", options: .regularExpression)        // emphasis
        t = t.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!>])"#, with: "$1", options: .regularExpression) // escapes \. \- etc.
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func renderPDF(title: String, content: NSAttributedString) -> URL? {
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
                .foregroundColor: UIColor.black,
                .paragraphStyle: para
            ]))
        }
        attr.append(content)

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
