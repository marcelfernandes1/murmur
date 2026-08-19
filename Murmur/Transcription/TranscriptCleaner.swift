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

    /// Collapse obvious recognizer loops, e.g. a 10+ word phrase repeated many
    /// times after Whisper loses the plot on a long take. This is deliberately
    /// narrow: short emphasis ("really really") and ordinary two-pass phrasing
    /// are left untouched.
    static func removeDegenerateRepeats(_ text: String) -> String {
        let words = splitWords(text)
        guard words.count >= 18 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }

        let normalized = words.map(normalizeForRepeatDetection)
        var output: [String] = []
        var i = 0
        let maxPhraseLength = min(30, words.count / 3)
        let minPhraseLength = 5

        while i < words.count {
            var collapsed = false
            if maxPhraseLength >= minPhraseLength {
                for phraseLength in stride(from: maxPhraseLength, through: minPhraseLength, by: -1) {
                    guard i + phraseLength * 3 <= words.count else { continue }
                    let phrase = Array(normalized[i..<(i + phraseLength)])
                    guard phrase.allSatisfy({ !$0.isEmpty }) else { continue }

                    var repeatCount = 1
                    while i + phraseLength * (repeatCount + 1) <= words.count {
                        let start = i + phraseLength * repeatCount
                        let next = Array(normalized[start..<(start + phraseLength)])
                        if next == phrase {
                            repeatCount += 1
                        } else {
                            break
                        }
                    }

                    if repeatCount >= 3, phraseLength * repeatCount >= 18 {
                        output.append(contentsOf: words[i..<(i + phraseLength)])
                        i += phraseLength * repeatCount
                        collapsed = true
                        break
                    }
                }
            }

            if !collapsed {
                output.append(words[i])
                i += 1
            }
        }

        return tidySpacing(output.joined(separator: " "))
    }

    /// Remove the custom vocabulary echoed back at the end of a transcript.
    ///
    /// Both whisper engines bias recognition by feeding the vocabulary in as an
    /// initial prompt — prior context the model is meant to condition on, not
    /// transcribe. It does not reliably tell the difference: run out of speech
    /// and it carries straight on into the prompt and emits it as if spoken, so
    /// dictations came back with "… that actually ran VTURB, Whop, Fernande,"
    /// stuck on the end. (A take with no speech at all is caught earlier, by
    /// `DecodeCoverage.containsSpeech` — this handles the leak onto real speech.)
    ///
    /// Only a run of at least two vocabulary terms, in the order they were fed
    /// in, is treated as an echo — that is the prompt being replayed, not
    /// someone naming one of their own terms in a sentence. The last word may be
    /// cut short ("Fernande"), which is how it usually arrives.
    static func stripPromptEcho(_ text: String, vocabulary: [String]) -> String {
        // Match whole TERMS, in the order they were fed to the engine. Flattening
        // the vocabulary into loose words was wrong twice over: one multi-word
        // entry ("Marcel Fernandes") armed the strip on its own, and any two
        // adjacent words from the bias list — which carries up to 200
        // auto-learned terms — could delete the end of a real sentence.
        let promptTerms: [[String]] = vocabulary
            .map { splitWords($0).map(normalizeForRepeatDetection).filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
        guard promptTerms.count >= 2 else { return text }

        let words = splitWords(text)
        let tokens = words.map(normalizeForRepeatDetection)
        guard !tokens.isEmpty else { return text }

        // Try every run of two-or-more consecutive terms, longest first, and see
        // whether the transcript ends with exactly that run.
        for length in stride(from: promptTerms.count, through: 2, by: -1) {
            for offset in 0...(promptTerms.count - length) {
                let run = Array(promptTerms[offset..<(offset + length)]).flatMap { $0 }
                guard run.count <= tokens.count else { continue }
                let tail = Array(tokens.suffix(run.count))
                guard tail.allSatisfy({ !$0.isEmpty }), matchesAllowingClippedLastWord(tail, run) else { continue }
                let kept = words.dropLast(run.count).joined(separator: " ")
                return tidySpacing(kept).replacingOccurrences(
                    of: #"[,;:]+$"#, with: "", options: .regularExpression)
            }
        }
        return text
    }

    /// Equal token for token, except the final one, which may be a truncation of
    /// the prompt's ("fernande" for "fernandes") — as long as it's long enough
    /// not to match by accident.
    private static func matchesAllowingClippedLastWord(_ tail: [String], _ prompt: [String]) -> Bool {
        guard tail.count == prompt.count, let last = tail.last, let expected = prompt.last else { return false }
        for i in 0..<(tail.count - 1) where tail[i] != prompt[i] { return false }
        if last == expected { return true }
        return last.count >= 3 && expected.hasPrefix(last)
    }

    private static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalizeForRepeatDetection(_ word: String) -> String {
        word.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// Env-gated self-test for the prompt-echo strip (mirrors the others).
    /// Run with: `MURMUR_TEST_COVERAGE=1 open Murmur.app` and read the log.
    /// Returns the number of failures so a harness can exit non-zero.
    @discardableResult
    static func runPromptEchoSelfTest() -> Int {
        let vocab = ["VTURB", "Whop", "Fernandes"]
        struct Case { let name: String; let input: String; let vocab: [String]; let expect: String }
        let cases: [Case] = [
            // Exactly what the reporter's history is full of.
            .init(name: "echo on the end of a real dictation",
                  input: "I want us to keep the creatives that actually ran VTURB, Whop, Fernande,",
                  vocab: vocab,
                  expect: "I want us to keep the creatives that actually ran"),
            .init(name: "whole transcript is the echo",
                  input: "VTURB, Whop, Fernandes", vocab: vocab, expect: ""),
            .init(name: "echo with the last word clipped",
                  input: "Check the checkout page VTURB, Whop, Fernande", vocab: vocab,
                  expect: "Check the checkout page"),
            // A run from the middle of the list is still the prompt replaying.
            .init(name: "partial run from mid-list",
                  input: "Ship it today Whop, Fernandes", vocab: vocab, expect: "Ship it today"),
            // Must NOT strip: one term used in an actual sentence.
            .init(name: "single term in real speech is kept",
                  input: "Please check the numbers on Whop", vocab: vocab,
                  expect: "Please check the numbers on Whop"),
            .init(name: "single term at the end after a comma is kept",
                  input: "Upload that to VTURB", vocab: vocab, expect: "Upload that to VTURB"),
            // Must NOT strip: terms present but not in prompt order.
            .init(name: "terms out of order are kept",
                  input: "Move it from Whop to VTURB", vocab: vocab,
                  expect: "Move it from Whop to VTURB"),
            // Must NOT strip: two terms genuinely spoken mid-sentence.
            .init(name: "run that isn't at the end is kept",
                  input: "VTURB, Whop and the rest are fine", vocab: vocab,
                  expect: "VTURB, Whop and the rest are fine"),
            // A short clipped word must not match loosely ("f" vs "fernandes").
            .init(name: "two-letter fragment is not a match",
                  input: "Send it to Whop, fe", vocab: vocab, expect: "Send it to Whop, fe"),
            // Nothing to do.
            .init(name: "no vocabulary configured",
                  input: "VTURB, Whop, Fernandes", vocab: [], expect: "VTURB, Whop, Fernandes"),
            .init(name: "single-term vocabulary is left alone",
                  input: "All done VTURB", vocab: ["VTURB"], expect: "All done VTURB"),
            // A multi-word vocabulary entry must not arm the strip on its own,
            // and must not be deleted when it legitimately ends a sentence.
            .init(name: "single multi-word term is left alone",
                  input: "send the deck to Marcel Fernandes", vocab: ["Marcel Fernandes"],
                  expect: "send the deck to Marcel Fernandes"),
            .init(name: "one multi-word term among others is kept in real speech",
                  input: "send the deck to Marcel Fernandes", vocab: ["Marcel Fernandes", "VTURB"],
                  expect: "send the deck to Marcel Fernandes"),
            .init(name: "two whole terms in prompt order are still stripped",
                  input: "ship it today Marcel Fernandes, VTURB",
                  vocab: ["Marcel Fernandes", "VTURB"], expect: "ship it today"),
            .init(name: "ordinary transcript untouched",
                  input: "Okay, now what I want you to do is check the page.", vocab: vocab,
                  expect: "Okay, now what I want you to do is check the page."),
        ]

        var failed = 0
        for c in cases {
            let got = stripPromptEcho(c.input, vocabulary: c.vocab)
            let ok = got == c.expect
            if !ok { failed += 1 }
            print("[PromptEcho] \(ok ? "PASS" : "FAIL") \(c.name)  got=\"\(got)\" expect=\"\(c.expect)\"")
        }
        print("[PromptEcho] \(cases.count - failed)/\(cases.count) passed")
        fflush(stdout) // GUI launch block-buffers stdout; flush so the result is observable.
        return failed
    }

    private static func tidySpacing(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
