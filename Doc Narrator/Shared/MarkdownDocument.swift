import Foundation

/// A parsed Markdown document as ordered, typed blocks. One parser shared by the on-screen
/// renderer (RichMarkdownView), the narrator (narration sentences), and the .md → PDF importer,
/// so display and speech never diverge again. Handles headings, paragraphs, bullet/numbered
/// lists, fenced code blocks, and tables. Inline emphasis is resolved by the renderer; LaTeX is
/// converted to readable text via Markdown.plainText so no raw "$"/backslashes show or speak.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)      // text is plain (markdown/LaTeX stripped)
    case paragraph(String)                       // may still contain inline ** __ etc. for display
    case bullet(String)
    case numbered(index: Int, text: String)
    case code(String)
    case table(header: [String], rows: [[String]])
}

enum MarkdownDocument {

    /// Parse Markdown into ordered blocks.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var paragraph = ""

        func flushParagraph() {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = ""
            if !p.isEmpty { blocks.append(.paragraph(p)) }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Blank line ends a paragraph.
            if line.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code block.
            if line.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1   // skip closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // Table: a header row of pipes followed by a separator row of dashes/pipes.
            if isTableRow(line), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(line)
                i += 2   // header + separator
                var rows: [[String]] = []
                while i < lines.count, isTableRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                    rows.append(tableCells(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Heading.
            if line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil {
                flushParagraph()
                let level = line.prefix(while: { $0 == "#" }).count
                let text = Markdown.plainText(line)
                blocks.append(.heading(level: min(level, 6), text: text))
                i += 1; continue
            }

            // Numbered list item.
            if let m = line.range(of: #"^(\d+)[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let numStr = line[line.startIndex..<m.upperBound].prefix(while: { $0.isNumber })
                let idx = Int(numStr) ?? (countNumbered(blocks) + 1)
                blocks.append(.numbered(index: idx, text: String(line[m.upperBound...])))
                i += 1; continue
            }

            // Bullet list item.
            if line.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil {
                flushParagraph()
                let text = line.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
                blocks.append(.bullet(text))
                i += 1; continue
            }

            // Otherwise accumulate into the current paragraph.
            paragraph += paragraph.isEmpty ? line : " " + line
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Narration

    /// Ordered plain-text sentences to read aloud, honoring NarrationSettings. The on-screen
    /// renderer builds the SAME order so highlight/jump line up where applicable.
    static func narrationSentences(_ markdown: String, settings: NarrationSettings) -> [String] {
        var out: [String] = []
        for block in parse(markdown) {
            switch block {
            case .heading(_, let text):
                let s = Markdown.plainText(text)
                if !s.isEmpty { out.append(s) }
            case .paragraph(let text):
                out.append(contentsOf: Markdown.sentences(text))
            case .bullet(let text):
                out.append(contentsOf: Markdown.sentences(text))
            case .numbered(_, let text):
                out.append(contentsOf: Markdown.sentences(text))
            case .code(let text):
                if !settings.skipCodeBlocks {
                    out.append(contentsOf: Markdown.sentences(text))
                }
            case .table(let header, let rows):
                if settings.skipTables { break }
                // Read row by row: "header1, header2: value1, value2."
                for row in rows {
                    let pairs = zip(header, row).map { "\($0): \($1)" }
                    let line = pairs.isEmpty ? row.joined(separator: ", ") : pairs.joined(separator: ", ")
                    let clean = Markdown.plainText(line)
                    if !clean.isEmpty { out.append(clean) }
                }
            }
        }
        // Equation handling: Markdown.plainText already converts LaTeX to readable words. If the
        // user opted to skip equations, drop sentences that are still equation-dense.
        if settings.skipEquations {
            out = out.filter { !isEquationHeavy($0) }
        }
        return out
    }

    // MARK: - Table helpers

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && line.filter { $0 == "|" }.count >= 1 && !line.hasPrefix("```")
    }

    private static func isTableSeparator(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("|") || line.contains("-") else { return false }
        // e.g. | --- | :---: | ---: |
        return line.range(of: #"^\|?[\s:|-]*-[\s:|-]*\|?$"#, options: .regularExpression) != nil
            && line.contains("-")
    }

    private static func tableCells(_ raw: String) -> [String] {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|") { line.removeLast() }
        return line.components(separatedBy: "|").map {
            Markdown.plainText($0.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func countNumbered(_ blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { if case .numbered = $1 { return $0 + 1 }; return $0 }
    }

    /// Rough check: a sentence that's mostly math symbols / had LaTeX markers.
    private static func isEquationHeavy(_ s: String) -> Bool {
        let mathChars = s.filter { "=+−-×÷<>≤≥∑∫√±∞^|".contains($0) }.count
        let letters = s.filter { $0.isLetter }.count
        return mathChars >= 3 && Double(mathChars) >= Double(max(letters, 1)) * 0.5
    }
}
