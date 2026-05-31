import Foundation
import NaturalLanguage

/// Markdown helpers for narration: strip formatting so the TTS engine never speaks
/// "**", "##", "-", etc., and split prose into sentences.
enum Markdown {
    /// Remove Markdown syntax, leaving clean prose suitable for speech.
    static func plainText(_ md: String) -> String {
        var s = md
        func sub(_ pattern: String, _ replacement: String) {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        sub(#"```[\s\S]*?```"#, " ")                       // fenced code blocks
        sub(#"`([^`]*)`"#, "$1")                            // inline code
        sub(#"!\[([^\]]*)\]\([^)]*\)"#, "$1")               // images -> alt text
        sub(#"\[([^\]]*)\]\([^)]*\)"#, "$1")                // links -> link text
        sub(#"(?m)^\s{0,3}#{1,6}\s*"#, "")                  // ATX headings
        sub(#"(?m)^\s{0,3}>\s?"#, "")                       // blockquotes
        sub(#"(?m)^\s*([-*+]|\d+[.)])\s+"#, "")             // list markers
        sub(#"(?m)^\s*([-*_]\s*){3,}$"#, " ")               // horizontal rules
        sub(#"(\*\*|\*|__|_|~~)"#, "")                      // bold / italic / strike
        sub(#"[ \t]+"#, " ")                                // collapse spaces
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split text into sentences (Markdown stripped first).
    static func sentences(_ text: String) -> [String] {
        let plain = plainText(text)
        guard !plain.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = plain
        var out: [String] = []
        tokenizer.enumerateTokens(in: plain.startIndex..<plain.endIndex) { range, _ in
            let piece = plain[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            return true
        }
        return out
    }
}
