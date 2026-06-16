import Foundation
import Observation

/// One auto-learned correction: a word the recognizer mis-produced (`heard`) and
/// the spelling the user changed it to (`corrected`).
struct LearnedCorrection: Codable, Equatable, Identifiable, Sendable {
    let heard: String
    let corrected: String
    var createdAt: Date

    /// Identity is the misheard form (case-insensitive) so re-learning the same
    /// word updates in place rather than piling up duplicates.
    var id: String { heard.lowercased() }
}

/// Persists the words Murmur has learned from your edits and applies them to
/// future transcripts. Two levers: `apply(to:)` does an exact, reliable
/// find-and-replace on the final text, and `biasTerms` nudges the recognizer
/// toward the right spelling in the first place (via the existing vocab prompt).
///
/// `apply(to:)` is on the transcription **delivery hot path**, so it must be
/// fast and self-contained: it runs only precomputed, in-memory string matching
/// and never calls AppKit, a spell-checker, or any XPC service. (An earlier
/// version used `NSSpellChecker` per word to gate phonetic generalization; that
/// blocks the main thread on the `AppleSpell` XPC service, which intermittently
/// stalls for seconds and froze the whole app — "Polishing…" beachball.)
@MainActor
@Observable
final class CorrectionStore {
    /// Bounds so a pathological transcript or a huge learned-word list can never
    /// make delivery slow. Generalization is skipped past these; exact matches
    /// (cheap, capped) always run.
    private enum Limit {
        static let corrections = 500      // exact rules compiled
        static let targets = 200          // distinct terms considered for generalization
        static let transcriptChars = 20_000
        static let tokens = 2_000
        static let comparisons = 50_000   // token × target candidate checks
    }

    private(set) var corrections: [LearnedCorrection] { didSet { rebuildIndex() } }

    private let defaults = UserDefaults.standard
    private let key = "learnedCorrections"

    // MARK: - Precomputed index (rebuilt only when `corrections` changes)

    /// A compiled exact rule: a whole-word, case-insensitive regex and the
    /// replacement template, built once rather than per `apply(to:)` call.
    private struct ExactRule {
        let regex: NSRegularExpression
        let template: String
    }

    /// A generalization target with its phonetic key precomputed.
    private struct Target {
        let term: String
        let lower: String
        let soundex: String
    }

    private struct Index {
        let exact: [ExactRule]          // longest `heard` first, so they win over overlaps
        let targets: [Target]
        let targetLowercased: Set<String>
    }

    private var index = Index(exact: [], targets: [], targetLowercased: [])

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([LearnedCorrection].self, from: data) {
            corrections = decoded
        } else {
            corrections = []
        }
        rebuildIndex()   // didSet doesn't fire from an initializer
    }

    private func rebuildIndex() {
        let exact = corrections
            .filter { !$0.heard.isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
            .prefix(Limit.corrections)
            .compactMap { c -> ExactRule? in
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: c.heard) + "\\b"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
                return ExactRule(regex: re, template: NSRegularExpression.escapedTemplate(for: c.corrected))
            }

        var seen = Set<String>()
        var targets: [Target] = []
        for c in corrections {
            let lower = c.corrected.lowercased()
            guard !c.corrected.isEmpty, !seen.contains(lower) else { continue }
            seen.insert(lower)
            targets.append(Target(term: c.corrected, lower: lower, soundex: CorrectionDetector.soundex(c.corrected)))
            if targets.count >= Limit.targets { break }
        }

        index = Index(exact: Array(exact), targets: targets, targetLowercased: seen)
    }

    // MARK: - Mutation

    /// Record (or refresh) a correction, newest first. Returns the stored entry.
    @discardableResult
    func learn(heard: String, corrected: String) -> LearnedCorrection {
        let entry = LearnedCorrection(
            heard: heard.trimmingCharacters(in: .whitespacesAndNewlines),
            corrected: corrected.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )
        corrections.removeAll { $0.id == entry.id }
        corrections.insert(entry, at: 0)
        persist()
        return entry
    }

    func remove(_ correction: LearnedCorrection) {
        corrections.removeAll { $0.id == correction.id }
        persist()
    }

    /// Edit an existing correction in place. `original` identifies the entry to
    /// replace (by its current `heard` value); the new `heard`/`corrected` are
    /// trimmed. Empty fields are rejected. Editing keeps the entry's position so
    /// the list doesn't reshuffle while you type.
    func update(_ original: LearnedCorrection, heard: String, corrected: String) {
        let newHeard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let newCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newHeard.isEmpty, !newCorrected.isEmpty else { return }
        guard let index = corrections.firstIndex(where: { $0.id == original.id }) else { return }
        let updated = LearnedCorrection(
            heard: newHeard,
            corrected: newCorrected,
            createdAt: original.createdAt
        )
        // If the new `heard` collides with a *different* entry, drop that one so
        // we don't end up with two corrections for the same mishearing.
        corrections.removeAll { $0.id == updated.id && $0.id != original.id }
        if let index = corrections.firstIndex(where: { $0.id == original.id }) {
            corrections[index] = updated
        } else {
            corrections.insert(updated, at: min(index, corrections.count))
        }
        persist()
    }

    /// The corrected spellings, de-duplicated — fed to the recognizer as bias terms.
    var biasTerms: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in corrections {
            let key = c.corrected.lowercased()
            guard !c.corrected.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(c.corrected)
        }
        return out
    }

    // MARK: - Apply (delivery hot path — pure, bounded, no AppKit/XPC)

    /// Replace learned mis-hearings in `text` with their corrected spellings.
    /// Whole-word and case-insensitive; longer terms first so they win over any
    /// shorter overlap. Then a phonetic pass generalizes to *new* mishearings of
    /// an already-learned term. Entirely in-memory; safe to call synchronously on
    /// the delivery path.
    func apply(to text: String) -> String {
        guard !text.isEmpty, !index.exact.isEmpty || !index.targets.isEmpty else { return text }
        var result = text
        for rule in index.exact {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.template)
        }
        return generalize(result)
    }

    /// Generalize learned terms: replace a transcript token that the recognizer
    /// emitted as a *guessed unknown term* (ALL-CAPS acronym, letter+digit, or
    /// internal-caps — see `CorrectionDetector.isStrongTerm`) when it sounds/looks
    /// like a learned term. So learning "SupaBase" also fixes a later "SUPRBASE".
    ///
    /// Restricting to that shape replaces the old `NSSpellChecker` "is this a real
    /// word?" gate: ordinary prose words ("cloud", "map", "database") don't have
    /// the shape, so legitimate vocabulary is never clobbered — and it costs
    /// nothing and never touches an XPC service.
    private func generalize(_ text: String) -> String {
        guard !index.targets.isEmpty, !text.isEmpty, text.count <= Limit.transcriptChars else { return text }
        let pattern = "[\\p{L}][\\p{L}'’\\-]*"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        var comparisons = 0
        // Replace back-to-front so earlier match ranges stay valid.
        for match in matches.reversed().prefix(Limit.tokens) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            guard token.count >= 2 else { continue }
            let tokenLower = token.lowercased()
            // Already one of our terms → leave it.
            if index.targetLowercased.contains(tokenLower) { continue }
            // Only generalize over recognizer "unknown term" guesses, never prose.
            guard CorrectionDetector.isStrongTerm(token) else { continue }
            let tokenSoundex = CorrectionDetector.soundex(token)
            for target in index.targets {
                comparisons += 1
                if comparisons > Limit.comparisons { return result as String }
                if target.lower == tokenLower { continue }
                // Cheap precomputed phonetic check first; fall back to the full
                // (still pure) plausibility test for spelling-close variants.
                if target.soundex == tokenSoundex
                    || CorrectionDetector.isPlausibleMishearing(heard: token, corrected: target.term, allowStrongTermShortcut: false) {
                    result.replaceCharacters(in: match.range, with: target.term)
                    break
                }
            }
        }
        return result as String
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(corrections) {
            defaults.set(data, forKey: key)
        }
    }

    // MARK: - Self-test (env-gated, mirrors CorrectionDetector.runSelfTest)

    /// Inject corrections without persisting — testing only.
    private func setForTesting(_ list: [LearnedCorrection]) { corrections = list }

    /// Correctness + performance checks for `apply(to:)`. Triggered alongside the
    /// detector self-test via `MURMUR_TEST_CORRECTIONS`. Prints PASS/FAIL and a
    /// timing line; the performance assertion guards against the hot path ever
    /// regressing back to something slow/blocking.
    static func runSelfTest() {
        func mk(_ heard: String, _ corrected: String) -> LearnedCorrection {
            LearnedCorrection(heard: heard, corrected: corrected, createdAt: Date(timeIntervalSince1970: 0))
        }
        let store = CorrectionStore()
        store.setForTesting([
            mk("SuperBass", "SupaBase"),
            mk("cloud", "Claude"),
            mk("Versal", "Vercel"),
        ])

        struct Case { let input: String; let expect: String; let note: String }
        let cases: [Case] = [
            .init(input: "we use cloud daily", expect: "we use Claude daily", note: "exact replace"),
            .init(input: "ship to SUPRBASE tonight", expect: "ship to SupaBase tonight", note: "generalize ALL-CAPS mishearing"),
            .init(input: "the database is fast", expect: "the database is fast", note: "lowercase prose untouched"),
            .init(input: "open a PR now", expect: "open a PR now", note: "no PR→SupaBase overmatch"),
            .init(input: "deploy on Versal please", expect: "deploy on Vercel please", note: "exact, mixed case"),
        ]
        var passed = 0
        for c in cases {
            let got = store.apply(to: c.input)
            let ok = got == c.expect
            if ok { passed += 1 }
            print("[CorrectionStore] \(ok ? "PASS" : "FAIL") [\(c.note)] “\(c.input)” → “\(got)” expect “\(c.expect)”")
        }
        print("[CorrectionStore] \(passed)/\(cases.count) correctness passed")

        // Performance: a long transcript against a large rule set must stay well
        // under any human-perceptible delay and must not block.
        var many: [LearnedCorrection] = []
        for i in 0..<200 { many.append(mk("term\(i)x", "Term\(i)X")) }
        store.setForTesting(many)
        let words = Array(repeating: "the quick BROWN fox JUMPED over LAZY dogs", count: 600).joined(separator: " ")
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = store.apply(to: words) }
        let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0 + Double(elapsed.components.seconds) * 1000.0
        let fast = ms < 250
        print("[CorrectionStore] \(fast ? "PASS" : "FAIL") perf: apply() on \(words.count) chars × \(many.count) rules took \(String(format: "%.1f", ms)) ms (budget 250 ms)")
    }
}
