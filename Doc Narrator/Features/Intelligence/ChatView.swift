import SwiftUI
import Combine
import UIKit

/// A persistent, retrieval-grounded conversation about one paper. ChatGPT/Claude-style:
/// streamed answers, Markdown-rendered for readability, per-answer read-aloud, history saved
/// to SessionStore (one chat among many per paper).
struct ChatView: View {
    let paper: Paper
    let sections: [PaperSection]

    @ObservedObject private var llm = LLMService.shared
    @StateObject private var model: ChatModel
    @FocusState private var composerFocused: Bool

    init(paper: Paper, sections: [PaperSection], session: ChatSession) {
        self.paper = paper
        self.sections = sections
        _model = StateObject(wrappedValue: ChatModel(session: session, sections: sections,
                                                     paperTitle: paper.title))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !llm.isReady {
                Label(llm.statusText, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.thinMaterial)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.messages.isEmpty && !model.isStreaming {
                            emptyState
                        }
                        ForEach(model.messages) { msg in
                            MessageBubble(message: msg,
                                          isStreaming: model.isStreaming && msg.id == model.streamingID)
                                .id(msg.id)
                        }
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(16)
                }
                .onChange(of: model.messages.last?.text) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: model.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }

            Divider()
            composer
        }
        .navigationTitle(model.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.onLeave() }
    }

    private let bottomID = "chat-bottom"

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Ask anything about this document.")
                .font(.headline)
            Text("Answers are grounded in the paper's text. Nothing leaves your device.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about this paper…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))

            if model.isStreaming {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button { composerFocused = false; model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                        .foregroundStyle(canSend ? .blue : .secondary)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        llm.isReady && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One message: user (trailing, tinted) or assistant (leading, readable Markdown).
/// All text is selectable/copyable. Chat does NOT use tap-to-speak — text selection is primary;
/// a single "Read aloud" button plays the whole answer for those who want it.
private struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .readingStyle()
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.15)))
            }
        } else {
            AssistantBubble(message: message, isStreaming: isStreaming)
        }
    }
}

/// Assistant answer rendered as a SINGLE selectable Text (native Markdown). One Text selects
/// per-word reliably; stacked Texts don't. Icon-only Copy + Read aloud sit under the answer.
private struct AssistantBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    @StateObject private var narrator = SentenceNarrator()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rendered)
                .readingStyle()
                .textSelection(.enabled)   // long-press → select & copy any word/phrase
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isStreaming && !message.text.isEmpty {
                HStack(spacing: 16) {
                    Button { UIPasteboard.general.string = Markdown.plainText(message.text) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy")

                    Button { narrator.toggle() } label: {
                        Image(systemName: narrator.isPlaying ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityLabel(narrator.isPlaying ? "Stop" : "Read aloud")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loadNarrator() }
        .onChange(of: isStreaming) { _, _ in loadNarrator() }
        .onDisappear { narrator.stop() }
    }

    /// Render Markdown inline (bold, lists collapse to plain prose) into one AttributedString.
    private var rendered: AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: message.text, options: opts) { return a }
        return AttributedString(message.text)
    }

    private func loadNarrator() {
        guard !isStreaming else { return }
        narrator.load(sentences: Markdown.sentences(message.text))
    }
}

/// Owns one chat's state: messages, draft, streaming, persistence.
@MainActor
final class ChatModel: ObservableObject {
    @Published var session: ChatSession
    @Published var draft = ""
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var isStreaming = false
    @Published private(set) var streamingID: UUID?
    @Published private(set) var error: String?

    private let sections: [PaperSection]
    private let paperTitle: String
    private var task: Task<Void, Never>?

    init(session: ChatSession, sections: [PaperSection], paperTitle: String) {
        self.session = session
        self.messages = session.messages
        self.sections = sections
        self.paperTitle = paperTitle
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""; error = nil

        let userMsg = ChatMessage(role: .user, text: text)
        messages.append(userMsg)

        // Title the chat from its first question.
        if session.title == "New chat" {
            session.title = String(text.prefix(48))
        }

        let history = Array(messages.dropLast())   // exclude the just-added question
        let assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        streamingID = assistant.id
        isStreaming = true
        persist()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in LLMService.shared.chat(question: text, history: history,
                                                              sections: self.sections,
                                                              paperTitle: self.paperTitle) {
                    if Task.isCancelled { break }
                    self.appendDelta(delta, to: assistant.id)
                }
            } catch is CancellationError {
                // user stopped — keep partial text
            } catch {
                self.error = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
            self.finishStreaming()
        }
    }

    func stop() { task?.cancel() }

    /// Called when the view leaves: cancel an in-flight stream and save.
    func onLeave() {
        task?.cancel()
        // Drop a trailing empty assistant placeholder if generation never produced text.
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            messages.removeLast()
        }
        persist()
    }

    private func appendDelta(_ delta: String, to id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].text += delta
    }

    private func finishStreaming() {
        isStreaming = false
        streamingID = nil
        // Remove an empty answer (e.g. immediate error) so it doesn't persist as a blank bubble.
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            messages.removeLast()
        }
        persist()
    }

    private func persist() {
        session.messages = messages
        SessionStore.upsertChat(session)
    }
}
