import Foundation
import SwiftData

/// One saved dictation.
@Model
final class Transcript {
    var text: String
    var createdAt: Date
    /// The transcript handed to smart cleanup — i.e. the raw ASR words with basic
    /// fillers stripped, but before the LLM pass. `nil` when cleanup didn't run.
    /// Powers the cleanup comparison screen (input vs. output). Optional so adding
    /// it is a lightweight SwiftData migration for existing stores.
    var original: String?

    init(text: String, createdAt: Date = .now, original: String? = nil) {
        self.text = text
        self.createdAt = createdAt
        self.original = original
    }
}
