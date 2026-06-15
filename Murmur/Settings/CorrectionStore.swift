import Foundation
import Observation
import AppKit

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
@MainActor
@Observable
final class CorrectionStore {
    private(set) var corrections: [LearnedCorrection]

    private let defaults = UserDefaults.standard
    private let key = "learnedCorrections"

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([LearnedCorrection].self, from: data) {
            corrections = decoded
        } else {
            corrections = []
        }
    }

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

    /// Replace learned mis-hearings in `text` with their corrected spellings.
    /// Whole-word and case-insensitive; longer terms first so they win over any
    /// shorter overlap. Then a phonetic pass generalizes to *new* mishearings of
    /// an already-learned term.
    func apply(to text: String) -> String {
        guard !corrections.isEmpty, !text.isEmpty else { return text }
        var result = text
        for c in corrections.sorted(by: { $0.heard.count > $1.heard.count }) {
            guard !c.heard.isEmpty else { continue }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: c.heard) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: c.corrected)
            result = re.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return applyPhonetic(to: result)
    }

    /// Generalize learned terms: replace any transcript token that *isn't a real
    /// word* but sounds/looks like a learned term with that term — so learning
    /// "Whop" (from a "WAP" mishearing) also fixes a later "WAMP", "Wop", etc.
    /// Real words (per the system spell-checker) are never touched, so we don't
    /// clobber legitimate vocabulary that merely resembles a learned name.
    private func applyPhonetic(to text: String) -> String {
        let targets = biasTerms
        guard !targets.isEmpty, !text.isEmpty else { return text }
        let pattern = "[\\p{L}][\\p{L}'’\\-]*"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = true
        let result = NSMutableString(string: text)
        // Replace back-to-front so earlier match ranges stay valid.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            guard token.count >= 2 else { continue }
            // Already one of our terms → leave it.
            if targets.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) { continue }
            // Only touch *likely mishearings*: non-dictionary tokens, or ALL-CAPS
            // tokens (Whisper tends to emit caps when guessing an unknown name —
            // "WAP"/"WAMP"). A lowercase real word ("map", "wrap", "cloud") is left
            // alone so we never clobber legitimate vocabulary.
            let isAllCaps = token == token.uppercased() && token != token.lowercased()
            let isRealWord = checker.checkSpelling(of: token, startingAt: 0).location == NSNotFound
            guard !isRealWord || isAllCaps else { continue }
            // …that plausibly mishears a learned term → swap it in.
            if let target = targets.first(where: {
                $0.caseInsensitiveCompare(token) != .orderedSame
                    && CorrectionDetector.isPlausibleMishearing(heard: token, corrected: $0)
            }) {
                result.replaceCharacters(in: match.range, with: target)
            }
        }
        return result as String
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(corrections) {
            defaults.set(data, forKey: key)
        }
    }
}
