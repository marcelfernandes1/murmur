import Foundation

/// Last line of defense against a cleanup backend returning something that isn't
/// a cleanup — e.g. a guardrailed model "answering" or refusing the transcript
/// ("As an LLM created by Apple, I cannot…") instead of reformatting it. A real
/// cleanup only trims/reformats, so anything that introduces refusal language or
/// balloons the text is rejected in favour of the original.
enum CleanupGuard {
    /// Phrases a cleanup must never emit. Matched case-insensitively, and only
    /// rejected when they weren't in what the speaker actually said. Kept to
    /// unambiguous refusal lead-ins — broad terms like "violates" / "language
    /// model" were removed because they appear in ordinary dictation.
    private static let refusalMarkers = [
        "as an ai", "as a language model", "as an llm", "i cannot assist",
        "i can't assist", "i cannot help", "i can't help", "i'm sorry, but",
        "i am sorry, but", "i cannot fulfill", "i'm unable to", "i am unable to",
        "i cannot provide", "created by apple", "i cannot comply",
    ]

    /// Spoken-number words that a faithful cleanup may legitimately turn into digits
    /// (e.g. "twenty twenty six" → "2026"). Used to bound how many digit tokens the
    /// output may introduce, so the model can't fabricate phone numbers / amounts.
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
        "million", "billion", "first", "second", "third", "oh", "double", "triple",
        "dozen", "quarter", "half",
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

        // A faithful cleanup only deletes (fillers/false starts), adjusts
        // case/punctuation, and turns spoken numbers into digits — it must not
        // reword, reorder, fabricate numbers, or gut the content. Compare on
        // lowercased, punctuation-stripped tokens.
        let originalTokens = tokenize(original)
        let cleanedTokens = tokenize(trimmed)
        let originalWordTokens = originalTokens.filter { !$0.allSatisfy(\.isNumber) }
        let cleanedWordTokens = cleanedTokens.filter { !$0.allSatisfy(\.isNumber) }
        let cleanedDigitCount = cleanedTokens.count - cleanedWordTokens.count

        // 1) No invented words AND no reordering: the cleaned word tokens must be an
        //    in-order subsequence of the spoken word tokens. (Subsequence implies the
        //    old "every word was actually said" rule and additionally rejects the
        //    model swapping word/clause order — e.g. switching a recipient.)
        guard isSubsequence(cleanedWordTokens, of: originalWordTokens) else { return original }

        // 2) No fabricated numbers: a digit token is only legitimate if the speaker
        //    actually gave a number to convert. Allow at most as many digit tokens as
        //    the original has spoken-number words + existing digits; more means the
        //    model invented figures (phone numbers, amounts, dosages) → reject.
        let numberSources = originalTokens.filter { numberWords.contains($0) || $0.allSatisfy(\.isNumber) }.count
        if cleanedDigitCount > numberSources { return original }

        // 3) No wholesale deletion: cleanup trims fillers/false-starts, but dropping
        //    most of the content means the model truncated or degenerated. For
        //    non-trivial input require at least a third of the spoken words to survive
        //    (generous for false-start-heavy speech, but rejects a one-word "cleanup").
        if originalWordTokens.count >= 6, cleanedWordTokens.count < originalWordTokens.count / 3 {
            return original
        }

        return trimmed
    }

    /// Whether `sub` appears within `seq` in the same order (gaps allowed).
    private static func isSubsequence(_ sub: [String], of seq: [String]) -> Bool {
        var i = 0
        for token in seq {
            if i < sub.count, sub[i] == token { i += 1 }
        }
        return i == sub.count
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
