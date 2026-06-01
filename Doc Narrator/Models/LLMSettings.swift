import Foundation

/// Which on-device LLM backend powers the intelligence features.
enum LLMProviderType: String, Codable, CaseIterable {
    case appleFoundation = "Apple (built-in)"
    case mlxLocal        = "Gemma (on-device)"
    case off             = "Off"
}

/// How the narrator turns extracted PDF text into what it reads aloud.
/// (Wired into the reading pipeline in Phase 5; default keeps today's behavior.)
enum NarrationMode: String, Codable, CaseIterable {
    case verbatim  = "Verbatim"   // read the cleaned text as-is (PDF highlight works)
    case cleaned   = "Cleaned"    // LLM removes junk, preserves wording (highlight works)
    case condensed = "Condensed"  // LLM rewrites/shortens (highlight disabled)
}

struct LLMSettings: Codable, Equatable {
    var providerType: LLMProviderType = .appleFoundation
    /// Identifier of the downloaded open model (Phase 4); empty until one is chosen.
    var selectedModelID: String = ""
    var narrationMode: NarrationMode = .verbatim

    static let defaultsKey = "llmSettings"

    static func load() -> LLMSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(LLMSettings.self, from: data)
        else { return LLMSettings() }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: LLMSettings.defaultsKey)
    }
}
