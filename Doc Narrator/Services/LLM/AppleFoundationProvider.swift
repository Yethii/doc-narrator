import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

private let llmLog = Logger(subsystem: "in.lyr.Doc-Narrator", category: "AppleLLM")

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
                        // Log exactly what Apple FM receives so we can see if the paper text is
                        // actually reaching the model (vs. being dropped/truncated).
                        llmLog.debug("Apple FM request — instructions: \(request.system.count, privacy: .public) chars, prompt: \(request.user.count, privacy: .public) chars, maxOut: \(request.maxTokens, privacy: .public)")
                        llmLog.debug("Prompt head: \(request.user.prefix(300), privacy: .public)")
                        let session = LanguageModelSession(instructions: request.system)
                        let options = GenerationOptions(temperature: request.temperature,
                                                        maximumResponseTokens: request.maxTokens)
                        // Stream cumulative snapshots; emit only the new delta each time.
                        var previous = ""
                        for try await partial in session.streamResponse(to: request.user, options: options) {
                            try Task.checkCancellation()
                            let snapshot = partial.content
                            if snapshot.hasPrefix(previous) {
                                let delta = String(snapshot.dropFirst(previous.count))
                                if !delta.isEmpty { continuation.yield(delta) }
                            } else {
                                // Snapshot diverged (rare) — replay the whole thing.
                                continuation.yield(snapshot)
                            }
                            previous = snapshot
                        }
                        llmLog.debug("Apple FM done — \(previous.count, privacy: .public) chars out. Head: \(previous.prefix(200), privacy: .public)")
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: LLMError.cancelled)
                    } catch let genErr as LanguageModelSession.GenerationError {
                        llmLog.error("Apple FM GenerationError: \(String(describing: genErr), privacy: .public)")
                        continuation.finish(throwing: Self.mapGenerationError(genErr))
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
    /// Turn Apple's opaque generation errors into clear, honest messages. The big one is
    /// context overflow: Apple's on-device model has only a ~4k-token total budget (input +
    /// output), so a long grounded prompt overflows — and instead of a clean failure the model
    /// would otherwise confabulate "I can't read the paper". Surface the real reason.
    @available(iOS 26.0, *)
    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> LLMError {
        switch error {
        case .exceededContextWindowSize:
            return .unavailable("This is too much text for Apple Intelligence's small context window. Ask a shorter or more specific question, or switch to Gemma (on-device) in Settings.")
        case .guardrailViolation:
            return .unavailable("Apple Intelligence declined to answer this (content safety). Try rephrasing, or switch to Gemma in Settings.")
        default:
            return .unavailable("Apple Intelligence couldn't complete this. Try again, a shorter question, or Gemma in Settings.")
        }
    }

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
