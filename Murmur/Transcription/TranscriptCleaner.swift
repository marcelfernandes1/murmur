import Foundation

/// Lightweight, deterministic post-processing of raw transcripts.
enum TranscriptCleaner {
    // Standalone hesitation/filler tokens, with an optional trailing comma.
    private static let fillerRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(um+|umm+|uh+|uhm+|hmm+|mhm+|erm+|er|ah+)\b[,]?"#
    )

    /// Remove filler words (um, uh, erm, ah…) and tidy the surrounding spacing.
    static func removeFillers(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = fillerRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")

        // Tidy up: collapse spaces, drop spaces before punctuation, fix stray leading commas.
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s,]+"#, with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Re-capitalize the first letter if we stripped a leading filler.
        if let first = result.first {
            result.replaceSubrange(result.startIndex...result.startIndex, with: first.uppercased())
        }
        return result
    }
}
