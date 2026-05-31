import Foundation
import NaturalLanguage
import OSLog

private let tcLog = Logger(subsystem: "in.lyr.Doc-Narrator", category: "TextCleaner")

struct TextCleaner {

    // Swift Regex literals (iOS 17+)
    private static let citationRegex = #/\[\s*(?:[0-9]+(?:[,–\-][0-9]+)*|[A-Za-z][^\[\]]{0,60})\s*\]/#
    private static let inlineMathRegex = #/\$[^\$\n]{1,200}\$/#
    private static let displayMathRegex = #/\$\$[\s\S]{1,500}?\$\$/#
    private static let pageNumberRegex = #/^\s*\d{1,4}\s*$/#
    private static let urlRegex = #/https?:\/\/\S+/#
    private static let doiRegex = #/\b10\.\d{4,}\/\S+/#
    private static let emailRegex = #/\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b/#
    private static let captionPrefixRegex = #/^(?:Fig(?:ure)?\.?\s*\d|Table\s*\d|Algorithm\s*\d)/#
    private static let sectionNumberRegex = #/^\d+(?:\.\d+)*\.?\s+/#
    // Roman numeral section prefixes: I. through ~XXVIII. (covers typical paper section counts)
    private static let romanSectionPrefixRegex = #/^(?:X{0,2}(?:I{1,3}|IV|V(?:I{0,3})?|IX)|XX?)\.?\s+/#
    // Equation reference like "(1)" or "(1a)" at end of line — common in papers
    private static let equationLabelRegex = #/\(\d+[a-z]?\)\s*$/#

    // Symbols that strongly indicate math/equation content
    private static let mathSymbols: Set<Character> = [
        "=", "+", "−", "×", "÷", "<", ">", "∫", "∑", "∏", "√", "±",
        "≤", "≥", "∈", "∉", "⊂", "⊃", "∂", "∇", "∞", "~", "^", "|"
    ]

    private static let knownHeaders: Set<String> = [
        "abstract", "introduction", "background", "related work", "related works",
        "methodology", "method", "methods", "approach", "model", "models", "architecture",
        "experiments", "experiment", "experimental setup", "evaluation", "results",
        "discussion", "conclusion", "conclusions", "future work",
        "acknowledgments", "acknowledgements", "appendix", "supplementary material"
    ]

    // MARK: - Public

    static func clean(pages: [String], runningHeaders: Set<String>) -> [PaperSection] {
        let strippedPages = pages.map { stripHeaders($0, headers: runningHeaders) }
        let allLines = strippedPages.flatMap { $0.components(separatedBy: "\n") }
        let truncated = truncateAtReferences(allLines)
        return buildSections(from: truncated)
    }

    // MARK: - Phase 1: Strip running headers

    private static func stripHeaders(_ text: String, headers: Set<String>) -> String {
        text.components(separatedBy: "\n")
            .filter { !headers.contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n")
    }

    // MARK: - Phase 2: Truncate at references

    private static func truncateAtReferences(_ lines: [String]) -> [String] {
        let stopWords: Set<String> = ["references", "bibliography", "works cited"]
        for (i, line) in lines.enumerated() {
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            if stopWords.contains(lower) && lower.count < 30 {
                return Array(lines.prefix(i))
            }
        }
        return lines
    }

    // MARK: - Phase 3 & 4: Classify lines, build sections

    private static func buildSections(from lines: [String]) -> [PaperSection] {
        var sections: [PaperSection] = []
        var currentHeading: String? = nil
        var currentType: SectionType = .body
        var bodyLines: [String] = []

        func flush() {
            guard !bodyLines.isEmpty else { return }
            let text = bodyLines.joined(separator: " ")
            let sentences = tokenizeSentences(applySubstitutions(text))
            if !sentences.isEmpty {
                sections.append(PaperSection(type: currentType, heading: currentHeading, sentences: sentences))
            }
            bodyLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.wholeMatch(of: pageNumberRegex) != nil { continue }
            if trimmed.firstMatch(of: captionPrefixRegex) != nil { continue }

            let withoutURLs = trimmed
                .replacing(urlRegex, with: "").replacing(doiRegex, with: "")
                .replacing(emailRegex, with: "").trimmingCharacters(in: .whitespaces)
            if withoutURLs.isEmpty { continue }

            // Drop lines that are predominantly math/symbols (equations, variable defs)
            if isMathJunk(trimmed) {
                tcLog.debug("isMathJunk: '\(trimmed.prefix(80))'")
                continue
            }

            if let heading = detectSectionHeader(trimmed) {
                flush()
                tcLog.info("Section: '\(heading)' ← '\(trimmed.prefix(80))'")
                sections.append(PaperSection(type: .sectionHeader, heading: heading, sentences: []))
                currentHeading = heading
                currentType = heading.lowercased() == "abstract" ? .abstract : .body
                continue
            }

            bodyLines.append(trimmed)
        }
        flush()
        return sections
    }

    // MARK: - Junk line filter

    private static func isMathJunk(_ line: String) -> Bool {
        guard line.count > 2 else { return false }
        let letterCount = line.filter { $0.isLetter }.count
        let total = line.count
        // Less than 35% letters → likely equation or symbol garbage
        if Double(letterCount) / Double(total) < 0.35 { return true }
        // Contains math operator symbols → likely an equation
        let mathCount = line.filter { mathSymbols.contains($0) }.count
        if mathCount >= 2 { return true }
        // Pure equation label like "(3)" or "(12b)"
        if line.firstMatch(of: equationLabelRegex) != nil && total < 10 { return true }
        return false
    }

    // MARK: - Section header detection

    private static func detectSectionHeader(_ line: String) -> String? {
        var stripped = line
        var hadNumberPrefix = false
        if let match = stripped.firstMatch(of: sectionNumberRegex) {
            stripped = String(stripped[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            hadNumberPrefix = true
        } else if let match = stripped.firstMatch(of: romanSectionPrefixRegex) {
            stripped = String(stripped[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            hadNumberPrefix = true
        }
        let lower = stripped.lowercased()

        // Known keyword: short line, no sentence-ending period
        if knownHeaders.contains(lower) && !line.contains(".") && line.count < 60 {
            return stripped.capitalized
        }

        // ALL CAPS heuristic: letters must make up >55% of chars (excludes "F = MA" style equations)
        let letters = stripped.filter { $0.isLetter }
        let letterRatio = Double(letters.count) / Double(max(1, stripped.count))
        if letters.count >= 4
            && letters.allSatisfy({ $0.isUppercase })
            && letterRatio > 0.55
            && stripped.count <= 60
            && !stripped.contains(".")
            && !stripped.contains(where: { mathSymbols.contains($0) }) {
            return stripped.capitalized
        }

        // Had a section-number prefix → only treat as header if it reads like real words
        if hadNumberPrefix {
            let strippedLetterRatio = Double(stripped.filter({ $0.isLetter }).count) / Double(max(1, stripped.count))
            let hasMath = stripped.contains(where: { mathSymbols.contains($0) })
            let wordCount = stripped.split(separator: " ").count
            if !hasMath
                && strippedLetterRatio > 0.65
                && wordCount >= 1
                && stripped.count >= 3
                && stripped.count <= 80
                && !stripped.hasSuffix(".") {
                return stripped
            }
        }

        return nil
    }

    // MARK: - Substitutions

    private static func applySubstitutions(_ text: String) -> String {
        var result = text
        // LaTeX math (rare in PDFs but handle it)
        result = result.replacing(displayMathRegex, with: " ")
        result = result.replacing(inlineMathRegex, with: " ")
        // Strip citations [1], [2,3], etc.
        result = result.replacing(citationRegex, with: "")
        // Strip parenthesized equation labels at end of sentences: "... (1)"
        result = result.replacing(equationLabelRegex, with: "")
        // Collapse runs of spaces
        while result.contains("  ") { result = result.replacing("  ", with: " ") }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sentence tokenization

    private static func tokenizeSentences(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop sentences that are too short or still mostly symbols
            guard s.count >= 8 else { return true }
            let letterRatio = Double(s.filter({ $0.isLetter }).count) / Double(s.count)
            if letterRatio >= 0.4 { sentences.append(s) }
            return true
        }
        return sentences
    }
}
