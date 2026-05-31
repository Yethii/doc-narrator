import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's built-in on-device language model (iOS 26+ Foundation Models).
/// No model download, runs fully on device. Requires an Apple-Intelligence-capable device
/// with Apple Intelligence enabled.
final class AppleFoundationProvider: LLMProvider {
    var displayName: String { "Apple Intelligence (on-device)" }

    private var task: Task<Void, Never>?

    func availability() async -> LLMAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(Self.describe(reason))
            @unknown default:
                return .unavailable("Unavailable")
            }
        } else {
            return .unavailable("Requires iOS 26 or later")
        }
        #else
        return .unavailable("Foundation Models not available in this build")
        #endif
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                let t = Task {
                    do {
                        let session = LanguageModelSession(instructions: request.system)
                        let options = GenerationOptions(temperature: request.temperature)
                        // Phase 0: single-shot response. True token streaming is added in
                        // Phase 1 where summary latency matters.
                        let response = try await session.respond(to: request.user, options: options)
                        try Task.checkCancellation()
                        continuation.yield(response.content)
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: LLMError.cancelled)
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                self.task = t
                continuation.onTermination = { _ in t.cancel() }
            } else {
                continuation.finish(throwing: LLMError.unavailable("Requires iOS 26 or later"))
            }
            #else
            continuation.finish(throwing: LLMError.unavailable("Foundation Models not available"))
            #endif
        }
    }

    func cancel() { task?.cancel(); task = nil }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use this."
        case .modelNotReady:
            return "The on-device model is still downloading or preparing."
        @unknown default:
            return "Unavailable on this device."
        }
    }
    #endif
}
