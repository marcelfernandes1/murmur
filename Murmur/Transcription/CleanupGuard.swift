import Foundation

/// Last line of defense against a cleanup backend returning something that isn't
/// a cleanup — e.g. a guardrailed model "answering" or refusing the transcript
/// ("As an LLM created by Apple, I cannot…") instead of reformatting it. A real
/// cleanup only trims/reformats, so anything that introduces refusal language or
/// balloons the text is rejected in favour of the original.
enum CleanupGuard {
    /// Phrases a cleanup must never emit. Matched case-insensitively, and only
    /// rejected when they weren't in what the speaker actually said.
    private static let refusalMarkers = [
        "as an ai", "as a language model", "as an llm", "i cannot assist",
        "i can't assist", "i cannot help", "i can't help", "i'm sorry, but",
        "i am sorry, but", "i cannot fulfill", "i'm unable to", "i am unable to",
        "i cannot provide", "created by apple", "language model", "violates",
        "without proper authorization", "i cannot comply",
    ]

    /// Returns `cleaned` only if it's a plausible cleanup of `original`; otherwise
    /// returns `original` (which is already the raw words with fillers removed).
    static func sanitize(_ cleaned: String, original: String) -> String {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return original }

        let lower = trimmed.lowercased()
        let originalLower = original.lowercased()
        for marker in refusalMarkers where lower.contains(marker) && !originalLower.contains(marker) {
            return original
        }

        // Cleanup removes/reformats; it must never substantially grow the text.
        let originalWords = wordCount(original)
        let cleanedWords = wordCount(trimmed)
        if cleanedWords > Int(Double(originalWords) * 1.5) + 8 { return original }

        // Over-editing: a faithful cleanup only deletes (fillers/false starts),
        // adjusts case/punctuation, and turns spoken numbers into digits. It must
        // NOT introduce ANY new word the speaker didn't say — that's the model
        // rewording (e.g. "thing" -> "site"). Pure-digit tokens are exempt, since
        // "twenty twenty six" -> "2026" legitimately produces digits. If even one
        // new word appears, keep the speaker's verbatim text instead.
        var available = Dictionary(grouping: tokenize(original), by: { $0 }).mapValues(\.count)
        for token in tokenize(trimmed) where !token.allSatisfy(\.isNumber) {
            if let count = available[token], count > 0 {
                available[token] = count - 1
            } else {
                return original // introduced a word that wasn't said → reject
            }
        }

        return trimmed
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// Lowercased, punctuation-stripped word tokens for content comparison.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
