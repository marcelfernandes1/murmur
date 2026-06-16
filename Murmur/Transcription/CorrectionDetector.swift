import Foundation

/// Pure logic that decides whether an edit the user made to text we inserted is
/// a *learnable transcription correction* — a misheard name, acronym, or jargon
/// term — as opposed to a typo fix, a reword, or normal editing.
///
/// Deliberately conservative (the user's chosen setting): it only fires for a
/// single one-word substitution where the new word both *looks* like a proper
/// noun / acronym / jargon term and *sounds* like the word it replaced. Anything
/// fuzzier is ignored so we never poison future transcripts with a bad rule.
enum CorrectionDetector {

    struct Candidate: Equatable {
        let heard: String       // what the recognizer produced, e.g. "cubernetes"
        let corrected: String   // what the user changed it to, e.g. "Kubernetes"
    }

    /// A word plus its character range within its source string.
    private struct Token {
        let text: String
        let range: Range<String.Index>
        let source: String
    }

    /// Inspect an edit. `before` is the field's text right after we inserted;
    /// `after` is its text once the user changed something. `insertedRange`
    /// (UTF-16 offsets into `before`) bounds the span we actually inserted, so a
    /// fix the user makes to *pre-existing* text elsewhere in the field is
    /// ignored. Returns a candidate only for a single, plausible word swap.
    static func candidate(before: String, after: String, insertedRange: NSRange?) -> Candidate? {
        guard before != after else { return nil }
        let beforeTokens = tokenize(before)
        let afterTokens = tokenize(after)

        // Strict shape: the two token streams differ in exactly one position.
        // A different count means a word was added/removed (a reword or appended
        // typing) — not a term correction — so we bail. This is intentionally
        // narrow; it keeps false positives near zero.
        guard beforeTokens.count == afterTokens.count, !beforeTokens.isEmpty else { return nil }

        var changed: Int? = nil
        for i in beforeTokens.indices where beforeTokens[i].text != afterTokens[i].text {
            if changed != nil { return nil }   // more than one word changed → not a single term fix
            changed = i
        }
        guard let i = changed else { return nil }

        // The changed word must lie within the text we inserted (when we know
        // where that was), not in surrounding content the user happened to edit.
        if let inserted = insertedRange {
            let wordRange = NSRange(beforeTokens[i].range, in: before)
            guard NSIntersectionRange(wordRange, inserted).length > 0 else { return nil }
        }

        let heard = beforeTokens[i].text
        let corrected = afterTokens[i].text
        guard corrected.count <= 40 else { return nil }
        guard isPlausibleMishearing(heard: heard, corrected: corrected) else { return nil }
        guard isLearnableTerm(corrected, sentenceInitial: isSentenceInitial(afterTokens[i])) else { return nil }
        return Candidate(heard: heard, corrected: corrected)
    }

    // MARK: - Term shape

    /// Whether `word` looks like the kind of thing worth learning: an acronym
    /// (API), a letter+digit token (GPT-4, H100), CamelCase (OpenAI, iPhone), or
    /// a capitalized proper noun (Kubernetes). At the start of a sentence a plain
    /// Capitalized word is ambiguous (any word is capitalized there), so the
    /// proper-noun rule is suppressed to avoid learning "their → There".
    static func isLearnableTerm(_ word: String, sentenceInitial: Bool) -> Bool {
        guard word.count >= 2 else { return false }
        let letters = word.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }          // pure number/punctuation: skip

        // ALL-CAPS acronym (API, NDA, SQL).
        if word == word.uppercased() && word != word.lowercased() && letters.count >= 2 { return true }
        // Mixed letters + digits jargon (GPT4, H100, v3).
        if word.contains(where: \.isNumber) && word.contains(where: \.isLetter) { return true }
        // CamelCase / internal capital (OpenAI, McKinsey, iPhone).
        if hasInternalUppercase(word) { return true }
        // Plain proper noun: capitalized with a lowercase tail (Kubernetes, John).
        if !sentenceInitial, let first = word.first, first.isUppercase,
           word.dropFirst().contains(where: \.isLowercase) { return true }
        return false
    }

    private static func hasInternalUppercase(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count > 1 else { return false }
        for i in 1..<chars.count where chars[i].isUppercase { return true }
        return false
    }

    // MARK: - Phonetic plausibility

    /// Whether `corrected` plausibly fixes a *mishearing* of `heard` rather than
    /// being a wholesale different word. Deliberately permissive — it only needs
    /// to block clearly-unrelated swaps (John → Michael) that would corrupt future
    /// transcripts via the replacement rule; everything with a real relationship
    /// to the heard word, or any obvious term shape, is accepted.
    ///
    /// `allowStrongTermShortcut` accepts any acronym/CamelCase/alphanumeric target
    /// outright, sounds-alike or not. That's right when the user *deliberately*
    /// typed the term (the learn path), but dangerous when *generalizing* a learned
    /// term onto brand-new transcript tokens: it would map any ALL-CAPS token ("PR",
    /// "AI", "OK") onto a CamelCase term like "SupaBase". The generalization pass
    /// passes `false` so it still requires a genuine phonetic/spelling match.
    static func isPlausibleMishearing(heard: String, corrected: String, allowStrongTermShortcut: Bool = true) -> Bool {
        let a = heard.lowercased()
        let b = corrected.lowercased()
        if a == b { return true }                              // pure capitalization / casing fix (openai → OpenAI)
        // Acronyms / CamelCase / alphanumeric jargon are unambiguous deliberate
        // terms — accept regardless of how close they sound (gpt-four → GPT-4).
        if allowStrongTermShortcut, isStrongTerm(corrected) { return true }
        let distance = levenshtein(a, b)
        let ratio = 1.0 - Double(distance) / Double(max(a.count, b.count))
        if ratio >= 0.34 { return true }                       // roughly-related spelling (clod ≈ Claude)
        if soundex(a) == soundex(b) { return true }            // or it just sounds alike (jon ≈ john)
        if let fa = a.first, let fb = b.first, fa == fb, abs(a.count - b.count) <= 3 {
            return true                                         // same onset + similar length
        }
        return false
    }

    /// Acronyms (NDA), CamelCase (OpenAI), or alphanumeric jargon (GPT-4) — these
    /// read as intentional terms on their own, no phonetic check needed. Also the
    /// shape the recognizer emits when guessing a name it doesn't know ("WAMP"),
    /// so `CorrectionStore` uses it to gate phonetic generalization purely — no
    /// dictionary/spell-checker required.
    static func isStrongTerm(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter }
        if word.count >= 2, word == word.uppercased(), word != word.lowercased(), letters.count >= 2 { return true }
        if word.contains(where: \.isNumber) && word.contains(where: \.isLetter) { return true }
        if hasInternalUppercase(word) { return true }
        return false
    }

    // MARK: - Tokenization

    /// Split into word tokens (letters/digits with internal apostrophes/hyphens),
    /// each carrying its range so we can locate it and test sentence position.
    private static func tokenize(_ string: String) -> [Token] {
        let pattern = "[\\p{L}\\p{N}][\\p{L}\\p{N}'’\\-]*"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(string.startIndex..., in: string)
        return re.matches(in: string, range: full).compactMap { match in
            guard let r = Range(match.range, in: string) else { return nil }
            return Token(text: String(string[r]), range: r, source: string)
        }
    }

    /// Whether a token sits at the start of a sentence (start of string, or right
    /// after sentence-ending punctuation), where capitalization carries no signal.
    private static func isSentenceInitial(_ token: Token) -> Bool {
        let s = token.source
        var idx = token.range.lowerBound
        guard idx != s.startIndex else { return true }
        while idx > s.startIndex {
            idx = s.index(before: idx)
            let c = s[idx]
            if c.isWhitespace { continue }
            return ".!?\n".contains(c)
        }
        return true
    }

    // MARK: - String distance / phonetics

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }

    /// Classic Soundex: a 4-char phonetic code so similar-sounding words bucket
    /// together (jon/john → J500, claude/cloud → C430). Exposed so callers can
    /// precompute a term's key once instead of recomputing it per token.
    static func soundex(_ word: String) -> String {
        let letters = word.uppercased().unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }
        guard let first = letters.first else { return "" }

        func code(_ scalar: Unicode.Scalar) -> Character? {
            switch Character(scalar) {
            case "B", "F", "P", "V": return "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": return "2"
            case "D", "T": return "3"
            case "L": return "4"
            case "M", "N": return "5"
            case "R": return "6"
            default: return nil   // vowels + H, W, Y
            }
        }

        var result = String(Character(first))
        var previous = code(first)
        for scalar in letters.dropFirst() {
            let c = code(scalar)
            if let c, c != previous { result.append(c) }
            // H and W don't reset the "previous" code; vowels do.
            let ch = Character(scalar)
            if ch != "H" && ch != "W" { previous = c }
            if result.count == 4 { break }
        }
        return String((result + "000").prefix(4))
    }

    // MARK: - Self-test (env-gated, mirrors the MURMUR_BENCH hook)

    /// Run a handful of cases and print PASS/FAIL. Triggered by setting the
    /// `MURMUR_TEST_CORRECTIONS` environment variable, so detection quality can
    /// be sanity-checked without the GUI.
    static func runSelfTest() {
        struct Case { let before: String; let after: String; let expect: Candidate? }
        let cases: [Case] = [
            .init(before: "I met Jon yesterday", after: "I met John yesterday",
                  expect: .init(heard: "Jon", corrected: "John")),
            .init(before: "deploy to cubernetes now", after: "deploy to Kubernetes now",
                  expect: .init(heard: "cubernetes", corrected: "Kubernetes")),
            .init(before: "we use claude daily", after: "we use Claude daily",
                  expect: .init(heard: "claude", corrected: "Claude")),
            .init(before: "sign the nda today", after: "sign the NDA today",
                  expect: .init(heard: "nda", corrected: "NDA")),
            // Loosened gate: roughly-related spelling now learns (was rejected at 0.55).
            .init(before: "we deployed to clod today", after: "we deployed to Claude today",
                  expect: .init(heard: "clod", corrected: "Claude")),
            // Still blocked: an unrelated proper-noun swap (would corrupt transcripts).
            .init(before: "tell John about it", after: "tell Michael about it", expect: nil),
            // Sentence-initial capitalization is ambiguous → not learned.
            .init(before: "the cat sat", after: "The cat sat", expect: nil),
            // Different word, not a mishearing → not learned.
            .init(before: "send the file", after: "send the document", expect: nil),
            // Number formatting is not a term → not learned.
            .init(before: "meet at noon", after: "meet at 12", expect: nil),
            // More than one word changed → reword, not a term fix.
            .init(before: "call him later", after: "phone her later", expect: nil),
        ]
        var passed = 0
        for c in cases {
            let got = candidate(before: c.before, after: c.after, insertedRange: nil)
            let ok = got == c.expect
            if ok { passed += 1 }
            print("[CorrectionDetector] \(ok ? "PASS" : "FAIL") “\(c.before)” → “\(c.after)”  got=\(String(describing: got)) expect=\(String(describing: c.expect))")
        }
        print("[CorrectionDetector] \(passed)/\(cases.count) passed")
    }
}
