import Foundation

/// What the narrator includes when reading AI text aloud. Lives in its own Settings sub-window
/// so it doesn't clog the main page. Tables, when not skipped, are read row by row.
struct NarrationSettings: Codable, Equatable {
    var skipTables = false
    var skipEquations = false
    var skipCodeBlocks = true     // code read aloud is noise by default

    static let defaultsKey = "narrationSettings"

    static func load() -> NarrationSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(NarrationSettings.self, from: data)
        else { return NarrationSettings() }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: NarrationSettings.defaultsKey)
    }
}
