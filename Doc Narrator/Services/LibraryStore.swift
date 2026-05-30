import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published private(set) var papers: [Paper] = []
    private let key = "paperLibrary"

    private init() { load() }

    func add(paper: Paper) { papers.append(paper); save() }

    func update(paper: Paper) {
        guard let idx = papers.firstIndex(where: { $0.id == paper.id }) else { return }
        papers[idx] = paper; save()
    }

    func remove(paper: Paper) { papers.removeAll { $0.id == paper.id }; save() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Paper].self, from: data) else { return }
        papers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(papers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
