import Foundation
import OSLog
import SwiftData

/// Owns the SwiftData container and provides the simple writes the dictation
/// flow needs. The History view reads via `@Query` from the same container.
@MainActor
final class HistoryStore {
    let container: ModelContainer

    // `nonisolated` so the background write task (below) can use them off the main actor.
    nonisolated private static let log = Logger(subsystem: "com.murmur.app", category: "history")

    /// Cap on retained dictations. History is a convenience log, not a system of
    /// record; the oldest entries beyond this are pruned so it can't grow without
    /// bound (and so the view's `@Query` never loads an unbounded set into memory).
    nonisolated private static let maxEntries = 10_000

    init() {
        let url = Self.storeURL()
        let config = ModelConfiguration(url: url)
        do {
            container = try ModelContainer(for: Transcript.self, configurations: config)
        } catch {
            // The on-disk store is unreadable/incompatible (e.g. a future non-
            // lightweight schema change, or corruption). Rather than `fatalError` —
            // which would crash-loop on every launch with no escape — move the bad
            // store aside and start fresh so the app stays usable.
            Self.log.error("History store unreadable, recreating: \(String(describing: error), privacy: .public)")
            Self.moveAside(url)
            if let recovered = try? ModelContainer(for: Transcript.self, configurations: config) {
                container = recovered
            } else {
                // Last resort: in-memory keeps the app running this session.
                Self.log.error("History store recreate failed; falling back to in-memory")
                container = try! ModelContainer(
                    for: Transcript.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            }
        }
    }

    /// A Murmur-specific store location. SwiftData's default store for a
    /// non-sandboxed app is `~/Library/Application Support/default.store`, which is
    /// SHARED by every non-sandboxed SwiftData app on the machine. When another app
    /// opens that file with a different schema, SwiftData migrates it to that app's
    /// model and drops our `Transcript` table — silently wiping history. Scoping the
    /// store to our own subdirectory keeps it isolated and stable.
    private static func storeURL() -> URL {
        let fm = FileManager.default
        let dir = URL.applicationSupportDirectory.appending(path: "Murmur", directoryHint: .isDirectory)
        // Owner-only directory (defense-in-depth: transcripts are private speech).
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appending(path: "Murmur.store")
    }

    /// Rename the incompatible store (and its WAL/SHM siblings) out of the way so a
    /// fresh one can be created.
    private static func moveAside(_ url: URL) {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = URL(fileURLWithPath: url.path + suffix + ".corrupt-\(stamp)")
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
        }
    }

    /// - Parameter original: the pre-cleanup text (raw words, fillers removed) when
    ///   smart cleanup ran, so the comparison screen can show input vs. output.
    func add(_ text: String, original: String? = nil) {
        // Write on a background context so a slow SQLite commit (large WAL checkpoint,
        // contended disk) never blocks the main run loop / UI. The view's `@Query`
        // on the main context is updated automatically when this save lands.
        let container = self.container
        Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.insert(Transcript(text: text, createdAt: .now, original: original))
            do {
                try context.save()
                try Self.pruneIfNeeded(context)
            } catch {
                Self.log.error("History save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Delete the oldest entries once the store exceeds `maxEntries`.
    nonisolated private static func pruneIfNeeded(_ context: ModelContext) throws {
        let count = try context.fetchCount(FetchDescriptor<Transcript>())
        guard count > maxEntries else { return }
        var descriptor = FetchDescriptor<Transcript>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        descriptor.fetchLimit = count - maxEntries
        for old in try context.fetch(descriptor) { context.delete(old) }
        try context.save()
    }
}
