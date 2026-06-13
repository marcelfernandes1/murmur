import Foundation
import Observation

/// User-managed list of names/terms/acronyms that Whisper often mis-hears. These
/// are fed to the model as a prompt to bias recognition toward them.
@MainActor
@Observable
final class VocabularyStore {
    private(set) var terms: [String]

    private let defaults = UserDefaults.standard
    private let key = "customVocabulary"

    init() {
        terms = defaults.stringArray(forKey: key) ?? []
    }

    func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        terms.append(trimmed)
        persist()
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        persist()
    }

    private func persist() {
        defaults.set(terms, forKey: key)
    }
}
