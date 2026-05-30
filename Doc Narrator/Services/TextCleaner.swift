import Foundation
import NaturalLanguage

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

            if let heading = detectSectionHeader(trimmed) {
                flush()
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

    // MARK: - Section header detection

    private static func detectSectionHeader(_ line: String) -> String? {
        var stripped = line
        if let match = stripped.firstMatch(of: sectionNumberRegex) {
            stripped = String(stripped[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let lower = stripped.lowercased()

        // Known keyword: short line, no sentence-ending period
        if knownHeaders.contains(lower) && !line.contains(".") && line.count < 60 {
            return stripped.capitalized
        }

        // ALL CAPS heuristic: ≥3 letters, ≤60 chars, no period
        let letters = stripped.filter { $0.isLetter }
        if letters.count >= 3 && stripped == stripped.uppercased()
            && stripped.count <= 60 && !stripped.contains(".") {
            return stripped.capitalized
        }

        // Had a section-number prefix stripped → numbered header
        if stripped != line && stripped.count >= 3 && stripped.count <= 80 && !stripped.hasSuffix(".") {
            return stripped
        }

        return nil
    }

    // MARK: - Substitutions

    private static func applySubstitutions(_ text: String) -> String {
        var result = text
        result = result.replacing(displayMathRegex, with: " a mathematical expression ")
        result = result.replacing(inlineMathRegex, with: " a mathematical expression ")
        result = result.replacing(citationRegex, with: "")
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
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        return sentences
    }
}
