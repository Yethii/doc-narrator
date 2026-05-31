import Foundation

/// A saved AI summary of a paper (general, or focused on a topic). Many can exist per paper,
/// each tagged with the model that produced it.
struct SummaryArtifact: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case general, custom }

    let id: UUID
    let paperID: UUID
    var kind: Kind
    var topic: String?        // set for custom summaries
    var modelLabel: String    // e.g. "Apple (built-in)"
    var markdown: String
    let createdAt: Date

    init(id: UUID = UUID(), paperID: UUID, kind: Kind, topic: String? = nil,
         modelLabel: String, markdown: String, createdAt: Date = .now) {
        self.id = id; self.paperID = paperID; self.kind = kind; self.topic = topic
        self.modelLabel = modelLabel; self.markdown = markdown; self.createdAt = createdAt
    }

    var title: String {
        switch kind {
        case .general: return "General summary"
        case .custom:  return topic.map { "Summary · \($0)" } ?? "Custom summary"
        }
    }
}

/// One turn in a chat-with-PDF conversation.
struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    var role: Role
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt
    }
}

/// A persistent chat-with-PDF conversation (populated in Phase D).
struct ChatSession: Identifiable, Codable, Hashable {
    let id: UUID
    let paperID: UUID
    var modelLabel: String
    var title: String
    let createdAt: Date
    var messages: [ChatMessage]

    init(id: UUID = UUID(), paperID: UUID, modelLabel: String,
         title: String = "New chat", createdAt: Date = .now, messages: [ChatMessage] = []) {
        self.id = id; self.paperID = paperID; self.modelLabel = modelLabel
        self.title = title; self.createdAt = createdAt; self.messages = messages
    }
}

/// All AI artifacts for one paper (one JSON file per paper).
struct PaperSessions: Codable {
    var summaries: [SummaryArtifact] = []
    var chats: [ChatSession] = []
}
