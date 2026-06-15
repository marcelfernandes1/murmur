import Foundation
import SwiftData

/// Owns the SwiftData container and provides the simple writes the dictation
/// flow needs. The History view reads via `@Query` from the same container.
@MainActor
final class HistoryStore {
    let container: ModelContainer

    init() {
        do {
            let config = ModelConfiguration(url: Self.storeURL())
            container = try ModelContainer(for: Transcript.self, configurations: config)
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
    }

    /// A Murmur-specific store location. SwiftData's default store for a
    /// non-sandboxed app is `~/Library/Application Support/default.store`, which is
    /// SHARED by every non-sandboxed SwiftData app on the machine. When another app
    /// opens that file with a different schema, SwiftData migrates it to that app's
    /// model and drops our `Transcript` table — silently wiping history. Scoping the
    /// store to our own subdirectory keeps it isolated and stable.
    private static func storeURL() -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Murmur", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Murmur.store")
    }

    /// - Parameter original: the pre-cleanup text (raw words, fillers removed) when
    ///   smart cleanup ran, so the comparison screen can show input vs. output.
    func add(_ text: String, original: String? = nil) {
        let context = container.mainContext
        context.insert(Transcript(text: text, original: original))
        try? context.save()
    }
}
