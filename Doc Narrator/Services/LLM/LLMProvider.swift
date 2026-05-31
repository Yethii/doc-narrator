import Foundation

/// Whether the active provider can currently generate text.
enum LLMAvailability: Equatable {
    case available
    case unavailable(String)   // human-readable reason for the UI
}

enum LLMError: LocalizedError {
    case unavailable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let r): return r
        case .cancelled:          return "Cancelled"
        }
    }
}

/// A single generation request. Mirrors the minimal surface every backend supports.
struct LLMRequest {
    var system: String          // instructions / role
    var user: String            // the content or question
    var maxTokens: Int = 512
    var temperature: Double = 0.3
}

/// On-device language-model backend. Concrete impls: Apple Foundation Models (default),
/// MLX open models (Phase 4). Mirrors the TTSEngine abstraction so the UI is backend-agnostic.
protocol LLMProvider: AnyObject {
    var displayName: String { get }
    func availability() async -> LLMAvailability
    /// Streams the response as incremental text deltas (append in order).
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
    func cancel()
}

extension LLMProvider {
    /// Convenience: collect the full response into one string.
    func complete(_ request: LLMRequest) async throws -> String {
        var out = ""
        for try await delta in stream(request) { out += delta }
        return out
    }
}
