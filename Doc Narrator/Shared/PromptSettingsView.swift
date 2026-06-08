import SwiftUI

/// View and edit the system prompts that drive the intelligence features. Edits take effect
/// immediately (next generation). "Restore default" reverts to the prompts the app shipped with.
struct PromptSettingsView: View {
    @ObservedObject private var llm = LLMService.shared
    @State private var showAdvanced = false
    @State private var confirmRestoreAll = false

    private let defaults = PromptSettings.makeDefault()

    var body: some View {
        Form {
            Section {
                Text("These are the instructions sent to the on-device model. Edit them to tune accuracy and style. Changes apply to the next summary or chat message.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            promptSection(
                title: "General summary",
                text: $llm.prompts.generalSummary,
                defaultValue: defaults.generalSummary,
                footer: "Used for ‘New general summary’. The whole paper is summarized in pieces, then combined using this prompt."
            )

            promptSection(
                title: "Custom summary (topic)",
                text: $llm.prompts.customSummary,
                defaultValue: defaults.customSummary,
                footer: "Used for ‘Summarize a topic…’. Must contain \(PromptSettings.topicPlaceholder), which is replaced with the topic you enter. If you remove it, the topic is appended automatically."
            )

            promptSection(
                title: "Chat with PDF",
                text: $llm.prompts.chat,
                defaultValue: defaults.chat,
                footer: chatFooter
            )

            Section {
                DisclosureGroup("Advanced: long-document steps", isExpanded: $showAdvanced) {
                    Text("A long paper is too big to summarize in one pass, so the app does it in stages. These two prompts control the early stages; the final result still uses the ‘General summary’ or ‘Custom summary’ prompt above. You usually don’t need to touch these.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 4)

                    promptBody(title: "Step 1 — Summarize each part",
                               text: $llm.prompts.map, defaultValue: defaults.map)
                    Text("Run on each section of a long paper to shorten it first.")
                        .font(.caption2).foregroundStyle(.secondary)

                    promptBody(title: "Step 2 — Merge the part-summaries",
                               text: $llm.prompts.fold, defaultValue: defaults.fold)
                    Text("Combines the Step 1 results when there are still too many to fit. The merged text then goes to the final summary prompt above.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } footer: {
                Text("These only run on long documents. Short ones are summarized directly with the prompts above.")
            }

            Section {
                Button(role: .destructive) { confirmRestoreAll = true } label: {
                    Label("Restore all defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("AI Prompts")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Restore all prompts to their defaults?",
                            isPresented: $confirmRestoreAll, titleVisibility: .visible) {
            Button("Restore all", role: .destructive) { llm.prompts = PromptSettings.makeDefault() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Footer for the Chat prompt: documents the rolling-window grounding so it's transparent.
    private var chatFooter: String {
        let budget = llm.contextCharBudget
        let model = llm.settings.providerType == .appleFoundation ? "Apple Intelligence" : "Gemma"
        return """
        How chat context works: for each question, the app finds the most relevant sections of \
        the paper (semantic search) and includes up to ~\(budget) characters of them, plus the \
        last 6 messages of the conversation — a rolling window. Older turns scroll out of the \
        model’s view (the full history is still saved on device). The window is sized to the \
        active model: \(model) is selected now. Apple’s model has a small ~4k-token limit, so it \
        gets a tighter window than Gemma to avoid overflow.
        """
    }

    @ViewBuilder
    private func promptSection(title: String, text: Binding<String>,
                              defaultValue: String, footer: String) -> some View {
        Section {
            promptBody(title: title, text: text, defaultValue: defaultValue)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private func promptBody(title: String, text: Binding<String>, defaultValue: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if text.wrappedValue != defaultValue {
                    Button("Restore default") { text.wrappedValue = defaultValue }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            TextEditor(text: text)
                .frame(minHeight: 120)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                .autocorrectionDisabled()
        }
        .padding(.vertical, 4)
    }
}
