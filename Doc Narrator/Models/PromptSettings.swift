import Foundation

/// User-editable system prompts for the intelligence features. Defaults live in code so
/// "Restore default" always works, even after edits. Persisted to UserDefaults.
///
/// The Custom summary prompt uses a `{topic}` placeholder, replaced at generation time with
/// what the user asked to focus on.
struct PromptSettings: Codable, Equatable {
    var generalSummary: String
    var customSummary: String      // must contain {topic}
    var chat: String
    var map: String                // advanced: per-chunk condense step (map-reduce)
    var fold: String               // advanced: combine step (map-reduce)

    static let topicPlaceholder = "{topic}"
    static let defaultsKey = "promptSettings"

    // MARK: - Defaults (the exact prompts shipped before this feature)

    static let defaultGeneralSummary =
        "You are writing a clear, reader-friendly summary of a document. Begin with a 2–4 " +
        "sentence plain-language overview (no heading or label). Then a blank line and a line " +
        "**Key points** followed by 4–7 concise bullets of the most important takeaways. " +
        "Be accurate and faithful to the source; do not invent details and do not add a " +
        "'TL;DR' label."

    static let defaultCustomSummary =
        "Summarize what the document says about a specific topic: \"\(topicPlaceholder)\". " +
        "Begin with a 2–4 sentence plain-language overview focused on that topic (no heading " +
        "or label), then a blank line and a line **Key points** with 3–6 concise bullets. " +
        "If the document barely covers the topic, say so plainly. Be faithful to the source; " +
        "do not invent details and do not add a 'TL;DR' label."

    static let defaultChat =
        "You are a helpful assistant answering questions about a specific document. " +
        "Answer ONLY from the provided excerpts and the conversation; if the excerpts don't " +
        "contain the answer, say so plainly rather than guessing. Be concise and accurate, " +
        "use Markdown when it helps (short bullets, bold for key terms), and never invent " +
        "citations, numbers, or facts not present in the excerpts."

    static let defaultMap =
        "You are summarizing one part of a longer academic or technical document. " +
        "Write a concise, factual summary (3–5 sentences) of the key points in this part. " +
        "Only use information present in the text; do not speculate or add outside facts."

    // Fold reuses the map prompt today; exposed separately so it can be tuned independently.
    static let defaultFold = defaultMap

    static func makeDefault() -> PromptSettings {
        PromptSettings(generalSummary: defaultGeneralSummary,
                       customSummary: defaultCustomSummary,
                       chat: defaultChat,
                       map: defaultMap,
                       fold: defaultFold)
    }

    // MARK: - Persistence

    static func load() -> PromptSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(PromptSettings.self, from: data)
        else { return makeDefault() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: PromptSettings.defaultsKey)
    }

    // MARK: - Resolved prompts

    /// Custom-summary prompt with the topic substituted. Falls back to appending the topic if
    /// the user removed the {topic} placeholder.
    func resolvedCustomSummary(topic: String) -> String {
        if customSummary.contains(PromptSettings.topicPlaceholder) {
            return customSummary.replacingOccurrences(of: PromptSettings.topicPlaceholder, with: topic)
        }
        return customSummary + " (Topic: \"\(topic)\".)"
    }
}
