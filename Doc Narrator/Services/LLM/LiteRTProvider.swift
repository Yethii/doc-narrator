import Foundation
import Combine

/// Manages the downloadable on-device Gemma model (LiteRT-LM): download/progress/delete and a
/// lazily-loaded inference engine. Singleton so the heavy engine is shared and loaded once.
@MainActor
final class LiteRTManager: ObservableObject {
    static let shared = LiteRTManager()

    private let downloader = ModelDownloader()
    private var engineCache: LiteRTLMEngine?
    private var pollTimer: Timer?

    @Published private(set) var isDownloaded = false
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadError: String?

    /// Approx download size, shown in the UI.
    let approxSizeText = "~2.6 GB"
    let modelName = "Gemma 4 E2B (on-device)"

    private init() { isDownloaded = downloader.isDownloaded }

    func startDownload() {
        guard !isDownloading, !isDownloaded else { return }
        downloadError = nil
        isDownloading = true
        progress = 0
        startPolling()
        Task {
            do {
                try await downloader.download()
            } catch {
                self.downloadError = error.localizedDescription
            }
            self.isDownloading = false
            self.isDownloaded = downloader.isDownloaded
            self.stopPolling()
        }
    }

    func cancelDownload() {
        downloader.cancel()
        isDownloading = false
        stopPolling()
    }

    func deleteModel() {
        downloader.deleteModel()
        engineCache = nil
        isDownloaded = false
        progress = 0
    }

    /// Lazily load (once) and return the inference engine. Loads the multi-GB model on first use.
    func engine() async throws -> LiteRTLMEngine {
        if let e = engineCache, e.isReady { return e }
        let e = LiteRTLMEngine(modelPath: downloader.modelPath, backend: "cpu", maxNumTokens: 4096)
        try await e.load()
        engineCache = e
        return e
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.progress = self?.downloader.progress ?? 0 }
        }
    }
    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }
}

/// LLMProvider backed by the downloadable Gemma model via LiteRT-LM.
final class LiteRTProvider: LLMProvider {
    var displayName: String { "Gemma (on-device)" }

    func availability() async -> LLMAvailability {
        let ready = await LiteRTManager.shared.isDownloaded
        return ready ? .available
                     : .unavailable("Download the Gemma model in Settings to use this.")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let engine = try await LiteRTManager.shared.engine()
                    // Gemma chat format.
                    let prompt = "<start_of_turn>user\n\(request.system)\n\n\(request.user)<end_of_turn>\n<start_of_turn>model\n"
                    for try await chunk in engine.generateStreaming(
                        prompt: prompt,
                        temperature: Float(request.temperature),
                        maxTokens: request.maxTokens) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel() {}
}
