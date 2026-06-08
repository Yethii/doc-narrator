import SwiftUI

/// Controls what the narrator includes when reading AI text (summaries, chat answers) aloud.
/// Kept in its own sub-screen so the main Settings page stays uncluttered.
struct NarrationSettingsView: View {
    @State private var settings = NarrationSettings.load()

    var body: some View {
        Form {
            Section {
                Toggle("Skip tables", isOn: $settings.skipTables)
                Toggle("Skip equations", isOn: $settings.skipEquations)
                Toggle("Skip code blocks", isOn: $settings.skipCodeBlocks)
            } header: {
                Text("Read aloud")
            } footer: {
                Text("When a table is not skipped, it's read row by row (for example: \"Column: value, Column: value\"). Equations are always shown on screen as readable text; this only controls whether they're spoken.")
            }
        }
        .navigationTitle("Narration")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { _, new in new.save() }
    }
}
