import SwiftUI

/// Paste raw text → generate a PDF → add it to the library.
struct PasteTextView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Title (optional)") {
                    TextField("Untitled", text: $title)
                }
                Section("Text") {
                    TextEditor(text: $text)
                        .frame(minHeight: 240)
                        .font(.body)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
            }
            .navigationTitle("Paste Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { add() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func add() {
        do {
            let url = try DocumentImporter.makePDF(title: title, text: text)
            LibraryStore.shared.addGeneratedPDF(at: url, title: title.isEmpty ? derivedTitle() : title)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // First line / first few words as a fallback title.
    private func derivedTitle() -> String {
        let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? "Untitled"
        return String(firstLine.prefix(60))
    }
}

/// Enter a web link → fetch + extract readable text → generate a PDF → add it to the library.
struct WebLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Web address") {
                    TextField("example.com/article", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(isLoading)
                }
                Section {
                    Text("The page's readable text is extracted and saved as a document you can read and narrate. Formatting and layout may differ from the original site.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
            }
            .navigationTitle("Add Web Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(isLoading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await add() } }
                            .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    @MainActor
    private func add() async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await DocumentImporter.makePDFFromWeb(urlString: urlString)
            LibraryStore.shared.addGeneratedPDF(at: result.url, title: result.title)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
