import Foundation
import Combine
import UIKit
import UserNotifications

/// Runs summary generation as background jobs that survive view navigation: starting a summary
/// creates a Job that keeps streaming even if the user leaves the page or the reader. A local
/// notification fires when a job completes. Jobs are owned here (a singleton), not by any view.
@MainActor
final class SummaryGenerator: ObservableObject {
    static let shared = SummaryGenerator()

    /// A single in-flight (or just-finished) generation. Observed by the detail view for
    /// live progress; runs independently of whether that view is on screen.
    @MainActor
    final class Job: ObservableObject, Identifiable, Hashable {
        nonisolated static func == (lhs: Job, rhs: Job) -> Bool { lhs.id == rhs.id }
        nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

        let id: UUID
        let paperID: UUID
        let paperTitle: String
        let kind: SummaryArtifact.Kind
        let topic: String?
        let modelLabel: String
        @Published var text = ""
        @Published var isGenerating = true
        @Published var error: String?
        fileprivate var task: Task<Void, Never>?

        init(id: UUID, paperID: UUID, paperTitle: String,
             kind: SummaryArtifact.Kind, topic: String?, modelLabel: String) {
            self.id = id; self.paperID = paperID; self.paperTitle = paperTitle
            self.kind = kind; self.topic = topic; self.modelLabel = modelLabel
        }

        var title: String {
            switch kind {
            case .general: return "General summary"
            case .custom:  return topic.map { "Summary · \($0)" } ?? "Custom summary"
            }
        }
    }

    @Published private(set) var jobs: [Job] = []

    /// True while any summary is being generated (it competes with TTS for the chip).
    var isGenerating: Bool { jobs.contains { $0.isGenerating } }

    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func jobs(for paperID: UUID) -> [Job] { jobs.filter { $0.paperID == paperID } }
    func job(id: UUID) -> Job? { jobs.first { $0.id == id } }

    @discardableResult
    func startGeneral(paper: Paper, sections: [PaperSection], reusing id: UUID? = nil) -> Job {
        start(paper: paper, sections: sections, kind: .general, topic: nil, reusing: id)
    }

    @discardableResult
    func startCustom(topic: String, paper: Paper, sections: [PaperSection], reusing id: UUID? = nil) -> Job {
        start(paper: paper, sections: sections, kind: .custom, topic: topic, reusing: id)
    }

    private func start(paper: Paper, sections: [PaperSection],
                       kind: SummaryArtifact.Kind, topic: String?, reusing id: UUID?) -> Job {
        let llm = LLMService.shared
        let job = Job(id: id ?? UUID(), paperID: paper.id, paperTitle: paper.title,
                      kind: kind, topic: topic, modelLabel: llm.currentModelLabel)
        jobs.removeAll { $0.id == job.id }
        jobs.append(job)

        let stream = (kind == .custom && topic != nil)
            ? llm.focusedSummary(topic: topic!, sections: sections)
            : llm.summarize(sections: sections)

        // Lower priority so foreground TTS/UI win the CPU; throttle UI updates so the main
        // thread isn't hammered per token (keeps the reader's highlight responsive).
        // Lower priority so foreground TTS/UI win the CPU; throttle UI updates so the main
        // thread isn't touched per token (keeps the reader's highlight responsive).
        job.task = Task(priority: .utility) { [weak self, weak job] in
            guard let job else { return }
            // Grab extra background time so a brief lock/backgrounding doesn't suspend us mid-run.
            let bg = await UIApplication.shared.beginBackgroundTask(withName: "summary-\(job.id)")
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
            do {
                var acc = ""
                var lastFlush = Date.distantPast
                for try await delta in stream {
                    acc += delta
                    if Date().timeIntervalSince(lastFlush) > 0.2 {
                        lastFlush = Date(); job.text = acc
                    }
                }
                job.text = acc
                job.isGenerating = false
                self?.finish(job, success: true)
            } catch is CancellationError {
                job.isGenerating = false
                self?.jobs.removeAll { $0.id == job.id }
            } catch {
                job.error = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                job.isGenerating = false
                self?.finish(job, success: false)
            }
        }
        return job
    }

    func cancel(id: UUID) {
        guard let job = job(id: id) else { return }
        job.task?.cancel()
        jobs.removeAll { $0.id == id }
    }

    private func finish(_ job: Job, success: Bool) {
        if success, !job.text.isEmpty {
            let artifact = SummaryArtifact(id: job.id, paperID: job.paperID, kind: job.kind,
                                           topic: job.topic, modelLabel: job.modelLabel, markdown: job.text)
            SessionStore.updateSummary(artifact)
            notify(job)
            jobs.removeAll { $0.id == job.id }   // the saved artifact now represents it
        }
        // On failure: KEEP the job (error set, isGenerating == false) so the user can see the
        // reason and retry, instead of it silently disappearing.
    }

    private func notify(_ job: Job) {
        let content = UNMutableNotificationContent()
        content.title = "Summary ready"
        content.body = "“\(job.title)” for \(job.paperTitle) is ready to read."
        // No sound: a notification sound interrupts the AVAudioSession and pauses narration.
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
