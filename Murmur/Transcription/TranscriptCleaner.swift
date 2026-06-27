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

    /// Join chunk transcripts while removing duplicate text from overlapping
    /// audio. Matching ignores case and punctuation because adjacent chunks often
    /// disagree only on capitalization or a trailing period.
    static func stitchChunks(_ chunks: [String]) -> String {
        var stitched = ""
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if stitched.isEmpty {
                stitched = trimmed
            } else {
                stitched = appendChunk(trimmed, to: stitched)
            }
        }
        return tidySpacing(stitched)
    }

    private static func appendChunk(_ chunk: String, to base: String) -> String {
        let baseWords = splitWords(base)
        let chunkWords = splitWords(chunk)
        guard !baseWords.isEmpty, !chunkWords.isEmpty else {
            return tidySpacing([base, chunk].filter { !$0.isEmpty }.joined(separator: " "))
        }

        let baseNorm = baseWords.map(normalizeForRepeatDetection)
        let chunkNorm = chunkWords.map(normalizeForRepeatDetection)
        let maxOverlap = min(40, baseWords.count, chunkWords.count)
        if maxOverlap >= 3 {
            for count in stride(from: maxOverlap, through: 3, by: -1) {
                let suffix = Array(baseNorm[(baseNorm.count - count)..<baseNorm.count])
                let prefix = Array(chunkNorm[0..<count])
                if suffix == prefix {
                    return tidySpacing((baseWords + chunkWords.dropFirst(count)).joined(separator: " "))
                }
            }
        }

        if let overlap = fuzzyOverlap(baseNorm: baseNorm, chunkNorm: chunkNorm) {
            return tidySpacing((baseWords.prefix(overlap.baseStart) + chunkWords.dropFirst(overlap.chunkStart)).joined(separator: " "))
        }

        return tidySpacing((baseWords + chunkWords).joined(separator: " "))
    }

    /// Find a shared phrase near the boundary even when one chunk has a small
    /// disagreement inside the overlap. We keep the later chunk from that phrase
    /// onward because it has more right-side audio context.
    private static func fuzzyOverlap(baseNorm: [String], chunkNorm: [String]) -> (baseStart: Int, chunkStart: Int)? {
        let maxWindow = 60
        let minCommonWords = 6
        let baseWindowStart = max(0, baseNorm.count - maxWindow)
        let chunkWindowEnd = min(chunkNorm.count, maxWindow)
        var best: (baseStart: Int, chunkStart: Int, length: Int)?

        guard chunkWindowEnd >= minCommonWords else { return nil }

        for baseIndex in baseWindowStart..<baseNorm.count {
            guard !baseNorm[baseIndex].isEmpty else { continue }
            for chunkIndex in 0..<chunkWindowEnd {
                guard !chunkNorm[chunkIndex].isEmpty else { continue }
                var length = 0
                while baseIndex + length < baseNorm.count,
                      chunkIndex + length < chunkWindowEnd,
                      !baseNorm[baseIndex + length].isEmpty,
                      baseNorm[baseIndex + length] == chunkNorm[chunkIndex + length] {
                    length += 1
                }
                if length >= minCommonWords, best == nil || length > best!.length {
                    best = (baseIndex, chunkIndex, length)
                }
            }
        }

        guard let best else { return nil }
        // Only trust matches that are genuinely near the stitch boundary. This
        // avoids deleting real repeated phrases that occur well inside a chunk.
        let baseWordsAfterMatch = baseNorm.count - best.baseStart
        guard best.chunkStart <= 12, baseWordsAfterMatch <= maxWindow else { return nil }
        return (best.baseStart, best.chunkStart)
    }

    private static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalizeForRepeatDetection(_ word: String) -> String {
        word.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func tidySpacing(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
