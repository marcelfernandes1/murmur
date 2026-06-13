import Foundation
import SwiftData

/// Owns the SwiftData container and provides the simple writes the dictation
/// flow needs. The History view reads via `@Query` from the same container.
@MainActor
final class HistoryStore {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Transcript.self)
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
    }

    func add(_ text: String) {
        let context = container.mainContext
        context.insert(Transcript(text: text))
        try? context.save()
    }
}
