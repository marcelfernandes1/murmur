import Foundation
import SwiftData

/// One saved dictation.
@Model
final class Transcript {
    var text: String
    var createdAt: Date

    init(text: String, createdAt: Date = .now) {
        self.text = text
        self.createdAt = createdAt
    }
}
