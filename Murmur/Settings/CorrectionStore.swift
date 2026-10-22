import Foundation
import Observation

struct LearnedCorrection: Codable, Equatable, Identifiable, Sendable {
    let heard: String
    let corrected: String
    var createdAt: Date
    /// Evidence of a verified user edit, absent in legacy global replacements.
    var contexts: [CorrectionDetector.Context]? = nil

    var id: String { CorrectionDetector.normalized(heard) }
    var needsContext: Bool { contexts?.contains(where: \.hasEnoughEvidence) != true }
    var usageDescription: String {
        needsContext ? "Paused — edit a dictation to relearn" : "Checked against audio before use"
    }
}

struct IgnoredCorrection: Codable, Equatable, Identifiable, Sendable {
    let heard: String
    let corrected: String
    var id: String { CorrectionDetector.normalized(heard) + "→" + CorrectionDetector.normalized(corrected) }
}

struct AppliedLearning: Sendable {
    let correction: LearnedCorrection
    /// UTF-16 location in the delivered text, not the original ASR text.
    let range: NSRange
}

struct LearningApplication: Sendable {
    let text: String
    let applied: [AppliedLearning]
}

/// Retrieval and reconciliation only. A plan NEVER rewrites text without a
/// second recognition of the same audio. Exact observed aliases limit what can
/// be proposed; the second recognizer can keep the original or abstain.
struct LearningPlan: Sendable {
    struct Proposal: Sendable {
        let correction: LearnedCorrection
        let range: NSRange
        let tokenStart: Int
        let tokenCount: Int
    }
    let original: String
    let proposals: [Proposal]
    var hints: [String] {
        var seen = Set<String>()
        return proposals.compactMap {
            seen.insert($0.correction.corrected.lowercased()).inserted ? $0.correction.corrected : nil
        }
    }

    static func make(text: String, corrections: [LearnedCorrection]) -> LearningPlan {
        guard (text as NSString).length <= CorrectionDetector.maxTextLength else {
            return LearningPlan(original: text, proposals: [])
        }
        struct Rule { let correction: LearnedCorrection; let words: [String] }
        var byFirst: [String: [Rule]] = [:]
        for correction in corrections.prefix(500) where !correction.needsContext {
            guard CorrectionDetector.validTerm(correction.heard), CorrectionDetector.validTerm(correction.corrected) else { continue }
            let words = CorrectionDetector.tokens(in: correction.heard).map { $0.text.lowercased() }
            guard let first = words.first else { continue }
            byFirst[first, default: []].append(Rule(correction: correction, words: words))
        }
        let tokens = CorrectionDetector.tokens(in: text)
        let source = text as NSString
        var proposals: [Proposal] = [], selectedTerms = Set<String>(), position = 0
        while position < tokens.count {
            let rules = (byFirst[tokens[position].text.lowercased()] ?? []).sorted { $0.words.count > $1.words.count }
            var chosen: Proposal?
            for rule in rules {
                let end = position + rule.words.count
                guard end <= tokens.count,
                      tokens[position..<end].map({ $0.text.lowercased() }) == rule.words else { continue }
                let range = NSRange(location: tokens[position].range.location,
                                    length: NSMaxRange(tokens[end - 1].range) - tokens[position].range.location)
                let sourceSpan = source.substring(with: range)
                guard CorrectionDetector.validTerm(sourceSpan), sourceSpan != rule.correction.corrected else { continue }
                let term = rule.correction.corrected.lowercased()
                guard selectedTerms.contains(term) || selectedTerms.count < 6 else { continue }
                selectedTerms.insert(term)
                chosen = Proposal(correction: rule.correction, range: range, tokenStart: position, tokenCount: rule.words.count)
                break
            }
            if let chosen {
                proposals.append(chosen)
                position += chosen.tokenCount
            } else { position += 1 }
            // Bound work and prompt size. An oversized plan abstains completely.
            if proposals.count > 16 { return LearningPlan(original: text, proposals: []) }
        }
        return LearningPlan(original: text, proposals: proposals)
    }

    /// Homophones cannot be resolved by spelling hints alone. Require a nearby
    /// content word from a real user correction, on the same side of the name.
    /// Function/time words are not evidence; no semantic guesses or fuzzy match.
    var matchingContextPositions: Set<Int> {
        let tokens = CorrectionDetector.tokens(in: original)
        func anchors(_ words: [String]) -> Set<String> {
            Set(words.map { $0.lowercased() }.filter {
                // Short content words (API, SDK, tax, app) can be the only
                // useful evidence next to a name. Filter function words by
                // meaning rather than discarding every three-letter anchor.
                $0.count >= 3 && !Self.contextStopWords.contains($0)
            })
        }
        return Set(proposals.compactMap { proposal in
            let current = CorrectionDetector.context(at: proposal.tokenStart,
                through: proposal.tokenStart + proposal.tokenCount - 1, tokens: tokens, text: original)
            let matches = (proposal.correction.contexts ?? []).contains { prior in
                !anchors(prior.before).isDisjoint(with: anchors(current.before))
                    || !anchors(prior.after).isDisjoint(with: anchors(current.after))
            }
            return matches ? proposal.tokenStart : nil
        })
    }

    private static let contextStopWords: Set<String> = Set("""
        this that these those there their they them then than with without from into onto over under
        through about around here have having been were will would should could might must just very
        really please today tomorrow yesterday later before after again next last first every some any
        more most only also even still already always never when where what which while because though
        and the for you your our its it's now not use using used want need make made going get gets got
        all are but can did had has how let off out say she her him his too was who why yet
        com das dos ela ele nas nos nao não por que sem sim tem ter
        isso isto esse essa estes estas como para pela pelo pelas pelos uma umas uns voce você voces vocês
        hoje ontem amanha amanhã depois antes muito mais menos tudo todos todas quando onde porque
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Accept only outputs expressible as unchanged words plus known proposed
    /// substitutions. Ignore the verifier's formatting and never copy its prose.
    /// Any unrelated insertion, deletion or rewrite rejects the whole result.
    func confirm(verifiedText: String?) -> LearningApplication {
        let unchanged = LearningApplication(text: original, applied: [])
        guard !proposals.isEmpty, let verifiedText,
              (verifiedText as NSString).length <= CorrectionDetector.maxTextLength else { return unchanged }
        let contextApproved = matchingContextPositions
        let sourceTokens = CorrectionDetector.tokens(in: original)
        let verifiedTokens = CorrectionDetector.tokens(in: verifiedText)
        let byPosition = Dictionary(uniqueKeysWithValues: proposals.map { ($0.tokenStart, $0) })
        var accepted: [Proposal] = [], sourceIndex = 0, verifiedIndex = 0
        while sourceIndex < sourceTokens.count {
            if let proposal = byPosition[sourceIndex] {
                let targetTokens = CorrectionDetector.tokens(in: proposal.correction.corrected)
                let end = verifiedIndex + targetTokens.count
                if contextApproved.contains(proposal.tokenStart), end <= verifiedTokens.count,
                   verifiedTokens[verifiedIndex..<end].map({ $0.text.lowercased() })
                    == targetTokens.map({ $0.text.lowercased() }) {
                    // Casing/spacing-only corrections are formatting, so require
                    // the verifier to actually produce the saved spelling.
                    let onlyFormatting = CorrectionDetector.normalized(proposal.correction.heard)
                        == CorrectionDetector.normalized(proposal.correction.corrected)
                    let actualRange = NSRange(location: verifiedTokens[verifiedIndex].range.location,
                        length: NSMaxRange(verifiedTokens[end - 1].range) - verifiedTokens[verifiedIndex].range.location)
                    if !onlyFormatting || (verifiedText as NSString).substring(with: actualRange) == proposal.correction.corrected {
                        accepted.append(proposal)
                        sourceIndex += proposal.tokenCount
                        verifiedIndex = end
                        continue
                    }
                }
            }
            if let proposal = byPosition[sourceIndex], contextApproved.contains(proposal.tokenStart),
               CorrectionDetector.normalized(proposal.correction.heard) != CorrectionDetector.normalized(proposal.correction.corrected) {
                let end = verifiedIndex + proposal.tokenCount
                guard end <= verifiedTokens.count,
                      verifiedTokens[verifiedIndex..<end].map({ $0.text.lowercased() })
                        == sourceTokens[sourceIndex..<(sourceIndex + proposal.tokenCount)].map({ $0.text.lowercased() }) else { return unchanged }
                accepted.append(proposal)
                sourceIndex += proposal.tokenCount
                verifiedIndex = end
                continue
            }
            guard verifiedIndex < verifiedTokens.count,
                  sourceTokens[sourceIndex].text.lowercased() == verifiedTokens[verifiedIndex].text.lowercased() else { return unchanged }
            sourceIndex += 1
            verifiedIndex += 1
        }
        guard verifiedIndex == verifiedTokens.count, !accepted.isEmpty else { return unchanged }
        let source = original as NSString
        var output = "", cursor = 0, applied: [AppliedLearning] = []
        for proposal in accepted {
            output += source.substring(with: NSRange(location: cursor, length: proposal.range.location - cursor))
            let range = NSRange(location: (output as NSString).length, length: (proposal.correction.corrected as NSString).length)
            output += proposal.correction.corrected
            applied.append(AppliedLearning(correction: proposal.correction, range: range))
            cursor = NSMaxRange(proposal.range)
        }
        output += source.substring(from: cursor)
        return LearningApplication(text: output, applied: applied)
    }

    /// Cleanup/chunk stitching can shift ranges. Keep receipts only for a unique
    /// unchanged local phrase on each side, never guess which repeated name moved.
    static func relocate(_ applications: [LearningApplication], into text: String) -> [AppliedLearning] {
        let destination = CorrectionDetector.tokens(in: text)
        var receipts: [AppliedLearning] = []
        for application in applications {
            if applications.count == 1, application.text == text { return application.applied }
            let source = CorrectionDetector.tokens(in: application.text)
            for receipt in application.applied {
                guard let start = source.firstIndex(where: { $0.range.location == receipt.range.location }),
                      let end = source.firstIndex(where: { NSMaxRange($0.range) == NSMaxRange(receipt.range) }) else { continue }
                let lower = max(0, start - 2), upper = min(source.count, end + 3)
                let signature = source[lower..<upper].map { $0.text.lowercased() }
                guard !signature.isEmpty, signature.count <= destination.count else { continue }
                let matches = (0...(destination.count - signature.count)).filter {
                    destination[$0..<($0 + signature.count)].map { $0.text.lowercased() } == signature
                }
                guard matches.count == 1, let match = matches.first else { continue }
                let first = match + start - lower, last = match + end - lower
                let range = NSRange(location: destination[first].range.location,
                                    length: NSMaxRange(destination[last].range) - destination[first].range.location)
                guard (text as NSString).substring(with: range) == receipt.correction.corrected,
                      !receipts.contains(where: { $0.range == range }) else { continue }
                receipts.append(AppliedLearning(correction: receipt.correction, range: range))
            }
        }
        return receipts
    }
}

@MainActor
@Observable
final class CorrectionStore {
    typealias AppliedCorrection = AppliedLearning
    typealias Application = LearningApplication
    private(set) var corrections: [LearnedCorrection]
    private(set) var ignored: [IgnoredCorrection]
    private let defaults: UserDefaults
    private let key = "learnedCorrectionsV3"
    private let ignoredKey = "ignoredCorrections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([LearnedCorrection].self, from: data) {
            corrections = decoded
        } else if let data = defaults.data(forKey: "learnedCorrections") {
            // Preserve the old key for rollback. Both released storage formats
            // import without promoting unscoped historical mappings to active rules.
            struct LegacyTerm: Decodable { let corrected: String; let variants: [String]; let createdAt: Date }
            if let terms = try? JSONDecoder().decode([LegacyTerm].self, from: data) {
                corrections = terms.flatMap { term in
                    term.variants.map { LearnedCorrection(heard: $0, corrected: term.corrected, createdAt: term.createdAt) }
                }
            } else {
                corrections = ((try? JSONDecoder().decode([LearnedCorrection].self, from: data)) ?? []).map {
                    LearnedCorrection(heard: $0.heard, corrected: $0.corrected, createdAt: $0.createdAt)
                }
            }
        } else { corrections = [] }
        ignored = defaults.data(forKey: ignoredKey).flatMap { try? JSONDecoder().decode([IgnoredCorrection].self, from: $0) } ?? []
        var seen = Set<String>()
        corrections = corrections.filter { seen.insert($0.id).inserted }
    }

    @discardableResult
    func learn(_ candidate: CorrectionDetector.Candidate) -> LearnedCorrection? {
        let suppression = IgnoredCorrection(heard: candidate.heard, corrected: candidate.corrected)
        guard CorrectionDetector.isLearnable(candidate), !ignored.contains(where: { $0.id == suppression.id }) else { return nil }
        let previous = corrections.first { $0.id == CorrectionDetector.normalized(candidate.heard) }
        var contexts = previous?.corrected == candidate.corrected ? previous?.contexts ?? [] : []
        if let context = candidate.context, context.hasEnoughEvidence {
            contexts.removeAll { $0 == context }
            contexts.insert(context, at: 0)
        }
        let entry = LearnedCorrection(heard: candidate.heard, corrected: candidate.corrected,
                                      createdAt: Date(), contexts: Array(contexts.prefix(8)))
        corrections.removeAll { $0.id == entry.id }
        corrections.insert(entry, at: 0)
        persist()
        return entry
    }

    func remove(_ correction: LearnedCorrection) {
        let suppression = IgnoredCorrection(heard: correction.heard, corrected: correction.corrected)
        if !ignored.contains(where: { $0.id == suppression.id }) { ignored.append(suppression) }
        corrections.removeAll { $0.id == correction.id }
        persist()
    }

    func allowLearning(_ item: IgnoredCorrection) {
        ignored.removeAll { $0.id == item.id }
        persist()
    }

    func undoLearning(_ entry: LearnedCorrection, previous: LearnedCorrection?) {
        guard corrections.first(where: { $0.id == entry.id }) == entry else { return }
        if let previous {
            corrections.removeAll { $0.id == entry.id }
            corrections.insert(previous, at: 0)
            persist()
        } else { remove(entry) }
    }

    @discardableResult
    func reject(edit: CorrectionDetector.Candidate, applied: [AppliedCorrection]) -> Bool {
        guard let match = applied.first(where: { $0.range == edit.range && $0.correction.corrected == edit.heard }),
              corrections.first(where: { $0.id == match.correction.id }) == match.correction else { return false }
        remove(match.correction)
        return true
    }

    func update(_ original: LearnedCorrection, heard: String, corrected: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CorrectionDetector.validTerm(heard), CorrectionDetector.validTerm(corrected),
              let position = corrections.firstIndex(where: { $0.id == original.id }) else { return }
        let updated = LearnedCorrection(heard: heard, corrected: corrected, createdAt: original.createdAt,
                                        contexts: CorrectionDetector.normalized(heard) == original.id ? original.contexts : nil)
        corrections.removeAll { $0.id == original.id || $0.id == updated.id }
        corrections.insert(updated, at: min(position, corrections.count))
        ignored.removeAll { $0.id == IgnoredCorrection(heard: heard, corrected: corrected).id }
        persist()
    }

    func apply(to text: String, verifiedText: String? = nil) -> String { application(to: text, verifiedText: verifiedText).text }
    func application(to text: String, verifiedText: String? = nil) -> Application {
        LearningPlan.make(text: text, corrections: corrections).confirm(verifiedText: verifiedText)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(corrections) { defaults.set(data, forKey: key) }
        if let data = try? JSONEncoder().encode(ignored) { defaults.set(data, forKey: ignoredKey) }
    }
}

extension LearningPlan {
    static func runSelfTest() -> Int {
        let rule = LearnedCorrection(heard: "fan basis", corrected: "Fanbasis", createdAt: Date(),
                                     contexts: [.init(before: ["use"], after: ["for", "invoices"])])
        let plan = make(text: "Use fan basis for invoices.", corrections: [rule])
        let checks = [plan.confirm(verifiedText: nil).text == plan.original,
                      plan.confirm(verifiedText: "Use Fanbasis for invoices.").text == "Use Fanbasis for invoices.",
                      plan.confirm(verifiedText: "Use Fanbasis for refunds.").text == plan.original]
        let failures = checks.filter { !$0 }.count
        print("[LearningPlan] \(failures == 0 ? "PASS" : "FAIL") audio-gated correction checks")
        return failures
    }
}
