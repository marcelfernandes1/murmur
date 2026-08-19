import Foundation
import Observation

/// One learned term: the spelling the user wants (`corrected`) plus every
/// mis-hearing the recognizer has produced for it (`variants`). All variants map
/// to the single corrected spelling.
///
/// This is the industry-standard shape (VoiceInk, Superwhisper, Wispr Flow all
/// store an exact term with one-or-more trigger spellings): a word that gets
/// misheard several ways collects its mishearings under one entry instead of
/// spawning rival rules. Each new mishearing costs the user exactly one
/// correction, then it's fixed forever.
struct LearnedTerm: Codable, Equatable, Identifiable, Sendable {
    /// What the user wants written, e.g. "Whop". Replacements always resolve *to* this.
    let corrected: String
    /// Observed mis-hearings that should all become `corrected`, e.g. ["WAP", "Wapp"].
    var variants: [String]
    var createdAt: Date

    /// Identity is the corrected spelling (case-insensitive), so re-correcting the
    /// same term folds new mishearings into the existing entry rather than piling
    /// up duplicates.
    var id: String { corrected.lowercased() }
}

/// Persists the words Murmur has learned from your edits and applies them to
/// future transcripts. Two levers: `apply(to:)` does an exact, reliable
/// find-and-replace on the final text, and `biasTerms` nudges the recognizer
/// toward the right spelling in the first place (via the existing vocab prompt).
///
/// **Exact-only by design.** An earlier version also ran a *phonetic
/// generalization* pass that rewrote never-corrected transcript tokens when they
/// merely sounded/looked like a learned term. That over-fired badly — with a
/// learned "Whop", tokens like "WhatsApp", "WiFi", and "WEB" were all rewritten
/// to "Whop" because the match test was an OR of three weak signals at a 34%
/// similarity floor. Every shipping dictation app (VoiceInk, Superwhisper, Wispr
/// Flow, MacWhisper) applies corrections as **exact, deterministic replacements**
/// and puts any fuzziness at *learn* time, anchored to a real human edit — never
/// at apply time against unseen words. This store does the same: the fuzzy
/// phonetic logic lives in `CorrectionDetector` (deciding whether an edit is a
/// learnable mishearing) and in `learn` (folding a new mishearing into the right
/// term); `apply(to:)` only ever swaps spellings it has literally been taught.
///
/// `apply(to:)` is on the transcription **delivery hot path**, so it must be fast
/// and self-contained: it runs only precomputed, in-memory string matching and
/// never calls AppKit, a spell-checker, or any XPC service. (An even earlier
/// version used `NSSpellChecker` per word; that blocks the main thread on the
/// `AppleSpell` XPC service, which intermittently stalls for seconds and froze
/// the whole app — the "Polishing…" beachball.)
@MainActor
@Observable
final class CorrectionStore {
    /// Bounds so a pathological transcript or a huge learned list can never make
    /// delivery slow.
    private enum Limit {
        static let rules = 500        // compiled variant→corrected rules
        static let biasTerms = 200    // most-recent terms fed to the recognizer
    }

    private(set) var terms: [LearnedTerm] { didSet { rebuildIndex() } }

    private let defaults: UserDefaults
    private let key = "learnedCorrections"

    // MARK: - Precomputed index (rebuilt only when `terms` changes)

    /// A compiled exact rule: a whole-word, case-insensitive regex for one
    /// variant, plus the corrected-spelling replacement template.
    private struct ExactRule {
        let regex: NSRegularExpression
        let template: String
    }

    private var exactRules: [ExactRule] = []
    /// One alternation of every variant, longest first, plus the lookup from a
    /// matched variant to its corrected spelling. Applying the rules through a
    /// single pass is what stops them chaining into each other.
    private var combinedRegex: NSRegularExpression?
    private var correctedByVariant: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var didMigrate = false
        terms = Self.load(from: defaults, key: key, didMigrate: &didMigrate)
        rebuildIndex()   // didSet doesn't fire from an initializer
        if didMigrate { persist() }   // rewrite legacy data in the new shape once
    }

    private func rebuildIndex() {
        // Flatten to (variant → corrected) pairs, longest variant first so a
        // specific trigger wins over any shorter overlapping one.
        let pairs = terms
            .flatMap { term in term.variants.map { (variant: $0, corrected: term.corrected) } }
            .sorted { $0.variant.count > $1.variant.count }
            .prefix(Limit.rules)

        exactRules = pairs.compactMap { pair in
            // Unicode-aware word boundary via look-arounds (not `\b`): a letter or
            // number may not sit directly adjacent, but punctuation, whitespace,
            // and the string edges may. Handles digits/hyphens inside terms
            // ("GPT-4") and non-ASCII names ("Fernández") correctly.
            let escaped = NSRegularExpression.escapedPattern(for: pair.variant)
            let pattern = Self.boundaryBefore + escaped + Self.boundaryAfter
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return ExactRule(regex: re, template: NSRegularExpression.escapedTemplate(for: pair.corrected))
        }

        correctedByVariant = Dictionary(pairs.map { ($0.variant.lowercased(), $0.corrected) },
                                        uniquingKeysWith: { first, _ in first })
        let alternation = pairs
            .map { NSRegularExpression.escapedPattern(for: $0.variant) }
            .joined(separator: "|")
        combinedRegex = alternation.isEmpty ? nil : try? NSRegularExpression(
            pattern: Self.boundaryBefore + "(" + alternation + ")" + Self.boundaryAfter,
            options: [.caseInsensitive])
    }

    /// Unicode-aware word boundary via look-arounds (not `\b`). Letters, digits,
    /// hyphens and apostrophes may not sit directly adjacent; whitespace, other
    /// punctuation and the string edges may.
    ///
    /// Hyphen and apostrophe are in the set because they join words: without
    /// them a rule `Anne → Ana` rewrote the middle of "Anne-Marie", `co → CO`
    /// hit "co-founder", and `GPT-4 → GPT-5` rewrote inside "X-GPT-4-turbo".
    private static let joiners = "\\p{L}\\p{N}\\-'\u{2019}"
    private static let boundaryBefore = "(?<![" + joiners + "])"
    private static let boundaryAfter = "(?![" + joiners + "])"

    // MARK: - Loading / migration

    /// Load the stored terms, transparently upgrading the old
    /// `[{heard, corrected}]` format to the new term/variant shape.
    private static func load(from defaults: UserDefaults, key: String, didMigrate: inout Bool) -> [LearnedTerm] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        // New format first; it has a `variants` array the legacy shape lacks, so
        // legacy data fails this decode and falls through.
        if let terms = try? decoder.decode([LearnedTerm].self, from: data) {
            return normalize(terms)
        }
        if let legacy = try? decoder.decode([LegacyCorrection].self, from: data) {
            didMigrate = true
            return normalize(migrate(legacy))
        }
        return []
    }

    /// The pre-variant on-disk shape: one row per mishearing.
    private struct LegacyCorrection: Codable {
        let heard: String
        let corrected: String
        var createdAt: Date
    }

    /// Fold legacy rows (newest-first) into per-term variant lists.
    private static func migrate(_ legacy: [LegacyCorrection]) -> [LearnedTerm] {
        var order: [String] = []                 // corrected keys, first-seen (newest) order
        var byKey: [String: LearnedTerm] = [:]
        for c in legacy {
            let corrected = c.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            let heard = c.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty, !heard.isEmpty else { continue }
            let k = corrected.lowercased()
            if var term = byKey[k] {
                term.variants.append(heard)
                byKey[k] = term
            } else {
                order.append(k)
                byKey[k] = LearnedTerm(corrected: corrected, variants: [heard], createdAt: c.createdAt)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Enforce the store's invariants (order preserved, newest-first):
    /// 1. corrected and every variant are trimmed and non-empty;
    /// 2. a variant literally equal to its corrected form is dropped (a no-op
    ///    rule) — but a case-only difference is *kept*, since it still normalizes
    ///    casing ("openai" → "OpenAI");
    /// 3. variants are de-duplicated case-insensitively within a term;
    /// 4. a given variant belongs to only one term — the earliest (newest) in the
    ///    list wins, so the most recent correction owns the mishearing;
    /// 5. terms with no surviving variants are dropped;
    /// 6. corrected terms are de-duplicated case-insensitively (newest kept).
    private static func normalize(_ input: [LearnedTerm]) -> [LearnedTerm] {
        var out: [LearnedTerm] = []
        var termKeys = Set<String>()          // corrected.lowercased() already emitted
        var claimedVariants = Set<String>()   // variant.lowercased() already owned
        for term in input {
            let corrected = term.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty else { continue }
            let termKey = corrected.lowercased()
            guard !termKeys.contains(termKey) else { continue }
            var seenHere = Set<String>()
            var variants: [String] = []
            for raw in term.variants {
                let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty, v != corrected else { continue }
                let vKey = v.lowercased()
                guard !seenHere.contains(vKey), !claimedVariants.contains(vKey) else { continue }
                seenHere.insert(vKey)
                variants.append(v)
            }
            guard !variants.isEmpty else { continue }
            for v in variants { claimedVariants.insert(v.lowercased()) }
            termKeys.insert(termKey)
            out.append(LearnedTerm(corrected: corrected, variants: variants, createdAt: term.createdAt))
        }
        return out
    }

    // MARK: - Mutation

    /// Learn from a detected edit: fold the mishearing `heard` into the term for
    /// `corrected`, newest-first. Returns the affected term, or `nil` when nothing
    /// was learned (empty input, or a *revert* — see below).
    ///
    /// Revert protection: if the user changed one of our corrected outputs back to
    /// a spelling we already treat as a mishearing of it (they're undoing a
    /// replacement we made), we forget that variant instead of learning the
    /// inverse — otherwise the two rules would ping-pong the word forever.
    @discardableResult
    func learn(heard: String, corrected: String) -> LearnedTerm? {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !c.isEmpty else { return nil }

        // Revert: `h` is an existing corrected term and `c` is one of its variants.
        if let i = terms.firstIndex(where: { $0.corrected.caseInsensitiveEquals(h) }),
           terms[i].variants.contains(where: { $0.caseInsensitiveEquals(c) }) {
            var reverted = terms.remove(at: i)
            reverted.variants.removeAll { $0.caseInsensitiveEquals(c) }
            if !reverted.variants.isEmpty { terms.insert(reverted, at: i) }
            terms = Self.normalize(terms)
            persist()
            return nil
        }

        // Normal learn: add `h` to the term for `c` (creating it if new), and move
        // that term to the front so it owns the mishearing (last correction wins).
        if let i = terms.firstIndex(where: { $0.corrected.caseInsensitiveEquals(c) }) {
            var existing = terms.remove(at: i)
            existing.variants.insert(h, at: 0)
            terms.insert(LearnedTerm(corrected: c, variants: existing.variants, createdAt: Date()), at: 0)
        } else {
            terms.insert(LearnedTerm(corrected: c, variants: [h], createdAt: Date()), at: 0)
        }
        terms = Self.normalize(terms)
        persist()
        return terms.first { $0.corrected.caseInsensitiveEquals(c) }
    }

    /// Remove an entire learned term.
    func remove(_ term: LearnedTerm) {
        terms.removeAll { $0.id == term.id }
        persist()
    }

    /// Remove a single mishearing from a term; drops the term if it was the last one.
    func removeVariant(_ variant: String, from term: LearnedTerm) {
        guard let i = terms.firstIndex(where: { $0.id == term.id }) else { return }
        terms[i].variants.removeAll { $0.caseInsensitiveEquals(variant) }
        if terms[i].variants.isEmpty { terms.remove(at: i) }
        persist()
    }

    /// Edit a term in place (from the settings UI): a new corrected spelling and a
    /// new variant list. Keeps the entry's position so the list doesn't reshuffle
    /// while you type. The edited term owns its variants — they're stripped from
    /// every other entry first so normalization can't hand ownership elsewhere.
    func update(_ original: LearnedTerm, corrected: String, variants: [String]) {
        let c = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let i = terms.firstIndex(where: { $0.id == original.id }) else { return }
        let cleanVariants = variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let owned = Set(cleanVariants.map { $0.lowercased() })
        for j in terms.indices where j != i {
            terms[j].variants.removeAll { owned.contains($0.lowercased()) }
        }
        terms[i] = LearnedTerm(corrected: c, variants: cleanVariants, createdAt: original.createdAt)
        terms = Self.normalize(terms)
        persist()
    }

    /// The corrected spellings of the most-recently-touched terms — fed to the
    /// recognizer as bias terms. Capped: Superwhisper's own guidance is to keep
    /// the vocab hint list small, since an overloaded one degrades punctuation and
    /// base-word accuracy.
    var biasTerms: [String] {
        terms.prefix(Limit.biasTerms).map(\.corrected)
    }

    // MARK: - Apply (delivery hot path — pure, bounded, no AppKit/XPC)

    /// Replace learned mis-hearings in `text` with their corrected spellings.
    /// Whole-word and case-insensitive; longer variants first so they win over any
    /// shorter overlap. Exact matches only — a token is rewritten solely when it
    /// literally equals a taught variant. Entirely in-memory; safe to call
    /// synchronously on the delivery path.
    /// Apply every learned correction in ONE left-to-right pass.
    ///
    /// Running each rule over the whole string in sequence let one rule's output
    /// be re-matched by the next: with `GPT-4 → GPT-5` and `GPT-5 → GPT-6`
    /// stored, "we use GPT-4" came out as "we use GPT-6". A single pass reads
    /// each character of the ORIGINAL once, so a replacement can never be
    /// re-examined. The alternation is ordered longest-variant-first, so the
    /// most specific rule wins where two could match at the same position.
    func apply(to text: String) -> String {
        guard !text.isEmpty, let regex = combinedRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var cursor = 0
        for match in matches {
            let range = match.range
            guard range.location >= cursor else { continue }   // never overlap
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let matched = ns.substring(with: range)
            result += correctedByVariant[matched.lowercased()] ?? matched
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(terms) {
            defaults.set(data, forKey: key)
        }
    }

    // MARK: - Self-test (env-gated, mirrors CorrectionDetector.runSelfTest)

    /// Inject terms without persisting — testing only.
    private func setForTesting(_ list: [LearnedTerm]) { terms = list }

    /// Correctness + performance checks for the exact-replace model. Triggered
    /// alongside the detector self-test via `MURMUR_TEST_CORRECTIONS`. Runs against
    /// a throwaway defaults suite so it never touches the user's real data.
    @discardableResult
    static func runSelfTest() -> Int {
        let suiteName = "com.murmur.correctionstore.selftest"
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)
        func term(_ corrected: String, _ variants: [String]) -> LearnedTerm {
            LearnedTerm(corrected: corrected, variants: variants, createdAt: Date(timeIntervalSince1970: 0))
        }

        // --- apply(): exact, bounded, no over-matching ---
        let store = CorrectionStore(defaults: suite)
        store.setForTesting([
            term("Whop", ["WAP", "Wapp"]),
            term("Vercel", ["Versal"]),
            term("OpenAI", ["openai"]),
        ])
        struct Case { let input: String; let expect: String; let note: String }
        let cases: [Case] = [
            .init(input: "pay with WAP today", expect: "pay with Whop today", note: "exact variant → corrected"),
            .init(input: "open WhatsApp now", expect: "open WhatsApp now", note: "HEADLINE: WhatsApp is NOT Whop"),
            .init(input: "I love wifi and web", expect: "I love wifi and web", note: "no phonetic overmatch"),
            .init(input: "please swap the cable", expect: "please swap the cable", note: "word-boundary: swap ≠ WAP"),
            .init(input: "wap then wapp", expect: "Whop then Whop", note: "case-insensitive, both variants"),
            .init(input: "deploy on Versal please", expect: "deploy on Vercel please", note: "second term still works"),
            .init(input: "ship openai models", expect: "ship OpenAI models", note: "casing-only correction applies"),
        ]
        // Chaining: one rule's OUTPUT must never be re-matched by another rule.
        let chain = CorrectionStore(defaults: suite)
        chain.setForTesting([term("GPT-5", ["GPT-4"]), term("GPT-6", ["GPT-5"])])
        let chainCases: [Case] = [
            .init(input: "we use GPT-4 daily", expect: "we use GPT-5 daily",
                  note: "HEADLINE: A→B must not then run through B→C"),
            .init(input: "we use GPT-5 daily", expect: "we use GPT-6 daily",
                  note: "the second rule still applies on its own"),
        ]
        // Word joiners: a hyphen or apostrophe binds words together, so a rule
        // must not rewrite the middle of a compound.
        let joined = CorrectionStore(defaults: suite)
        joined.setForTesting([term("Ana", ["Anne"]), term("CO", ["co"]), term("Whop", ["WAP"])])
        let joinerCases: [Case] = [
            .init(input: "Anne-Marie called", expect: "Anne-Marie called",
                  note: "HEADLINE: hyphenated name is left alone"),
            .init(input: "the co-founder agreed", expect: "the co-founder agreed",
                  note: "HEADLINE: co-founder is not CO-founder"),
            .init(input: "Anne called", expect: "Ana called", note: "standalone still corrects"),
            .init(input: "WAP's dashboard", expect: "WAP's dashboard",
                  note: "apostrophe binds too — possessive left alone"),
        ]
        var passed = 0
        for c in cases {
            let got = store.apply(to: c.input)
            let ok = got == c.expect
            if ok { passed += 1 }
            print("[CorrectionStore] \(ok ? "PASS" : "FAIL") [\(c.note)] “\(c.input)” → “\(got)” expect “\(c.expect)”")
        }
        for c in chainCases {
            let got = chain.apply(to: c.input)
            let ok = got == c.expect
            if ok { passed += 1 }
            print("[CorrectionStore] \(ok ? "PASS" : "FAIL") [\(c.note)] “\(c.input)” → “\(got)” expect “\(c.expect)”")
        }
        for c in joinerCases {
            let got = joined.apply(to: c.input)
            let ok = got == c.expect
            if ok { passed += 1 }
            print("[CorrectionStore] \(ok ? "PASS" : "FAIL") [\(c.note)] “\(c.input)” → “\(got)” expect “\(c.expect)”")
        }
        let applyTotal = cases.count + chainCases.count + joinerCases.count
        print("[CorrectionStore] \(passed)/\(applyTotal) apply() cases passed")

        // --- learn(): mishearings accumulate, then revert protection ---
        let learnStore = CorrectionStore(defaults: suite)
        learnStore.setForTesting([])
        learnStore.learn(heard: "WAP", corrected: "Whop")
        learnStore.learn(heard: "Wapp", corrected: "Whop")     // second mishearing folds in
        let folded = learnStore.terms.count == 1 && (learnStore.terms.first?.variants.count ?? 0) == 2
        print("[CorrectionStore] \(folded ? "PASS" : "FAIL") learn: two mishearings fold into one term \(learnStore.terms.map(\.variants))")

        learnStore.learn(heard: "Whop", corrected: "WAP")      // user reverts our replacement
        let noInverse = !learnStore.terms.contains { $0.corrected.caseInsensitiveEquals("WAP") }
        let variantGone = (learnStore.terms.first { $0.corrected == "Whop" }?.variants
            .contains { $0.caseInsensitiveEquals("WAP") }) == false
        print("[CorrectionStore] \(noInverse && variantGone ? "PASS" : "FAIL") learn: revert forgets the variant, no ping-pong \(learnStore.terms.map { ($0.corrected, $0.variants) })")

        // --- performance: long transcript × large rule set stays fast ---
        var many: [LearnedTerm] = []
        for i in 0..<200 { many.append(term("Term\(i)X", ["term\(i)x"])) }
        store.setForTesting(many)
        let words = Array(repeating: "the quick brown fox jumped over lazy dogs", count: 600).joined(separator: " ")
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = store.apply(to: words) }
        let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0 + Double(elapsed.components.seconds) * 1000.0
        let fast = ms < 250
        print("[CorrectionStore] \(fast ? "PASS" : "FAIL") perf: apply() on \(words.count) chars × \(many.count) rules took \(String(format: "%.1f", ms)) ms (budget 250 ms)")

        let storeFailures = (applyTotal - passed)
            + (folded ? 0 : 1) + (noInverse && variantGone ? 0 : 1) + (fast ? 0 : 1)
        print("[CorrectionStore] \(storeFailures) failures")
        fflush(stdout)
        suite.removePersistentDomain(forName: suiteName)
        return storeFailures
    }
}

private extension String {
    func caseInsensitiveEquals(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}
