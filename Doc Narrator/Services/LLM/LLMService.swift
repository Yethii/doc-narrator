import Foundation
import Combine

/// Owns the active LLM provider and exposes high-level intelligence operations to the UI.
/// Singleton + ObservableObject, mirroring LibraryStore. Re-selects the provider when
/// settings change (mirrors ReaderViewModel.reconfigureEngine()).
@MainActor
final class LLMService: ObservableObject {
    static let shared = LLMService()

    @Published private(set) var provider: (any LLMProvider)?
    @Published private(set) var status: LLMAvailability = .unavailable("Off")
    @Published var settings: LLMSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            reconfigure()
        }
    }

    /// True when an intelligence feature can run right now.
    var isReady: Bool { if case .available = status { return true }; return false }

    var statusText: String {
        switch status {
        case .available:            return "Ready"
        case .unavailable(let r):   return r
        }
    }

    private init() {
        self.settings = LLMSettings.load()
        reconfigure()
    }

    private func reconfigure() {
        switch settings.providerType {
        case .appleFoundation:
            provider = AppleFoundationProvider()
        case .mlxLocal:
            provider = nil   // Phase 4
        case .off:
            provider = nil
        }
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        guard let provider else { status = .unavailable("Off"); return }
        status = await provider.availability()
    }

    // MARK: - Generation

    /// Streams a response for arbitrary instructions + input. Higher-level ops
    /// (summarize / ask / explain) build on this in later phases.
    func stream(system: String, user: String,
                maxTokens: Int = 512, temperature: Double = 0.3) -> AsyncThrowingStream<String, Error> {
        guard let provider else {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.unavailable("No model selected")) }
        }
        return provider.stream(LLMRequest(system: system, user: user,
                                          maxTokens: maxTokens, temperature: temperature))
    }

    func cancel() { provider?.cancel() }
}
