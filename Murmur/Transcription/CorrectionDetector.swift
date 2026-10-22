import Foundation

/// Conservative, text-only evidence of a correction. Similar spelling is useful
/// when observing an edit; it is never permission to rewrite other sound-alikes.
enum CorrectionDetector {
    struct Context: Codable, Equatable, Sendable {
        let before: [String]
        let after: [String]

        var hasEnoughEvidence: Bool { before.count + after.count >= 2 }
    }

    struct Candidate: Equatable, Sendable {
        let heard: String
        let corrected: String
        var context: Context? = nil
        /// UTF-16 range relative to the dictated text, before the user's edit.
        var range: NSRange? = nil
        var sentenceInitial = false
    }

    struct Token: Sendable {
        let text: String
        let range: NSRange
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}][\\p{L}\\p{M}\\p{N}'’_\\-]*")
    static let maxTextLength = 20_000

    static func tokens(in text: String) -> [Token] {
        let source = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { Token(text: source.substring(with: $0.range), range: $0.range) }
    }

    /// Only observe one word changed inside a verified paste. Surrounding field
    /// content must be untouched; an unknown insertion range is never trusted.
    static func edit(before: String, after: String, insertedRange: NSRange?) -> Candidate? {
        let old = before as NSString
        let new = after as NSString
        guard old.length <= maxTextLength, new.length <= maxTextLength,
              before != after, let insertedRange,
              valid(insertedRange, length: old.length), insertedRange.length > 0 else { return nil }
        let prefix = old.substring(to: insertedRange.location)
        let suffix = old.substring(from: NSMaxRange(insertedRange))
        guard after.hasPrefix(prefix), after.hasSuffix(suffix),
              new.length >= (prefix as NSString).length + (suffix as NSString).length else { return nil }
        let beforeText = old.substring(with: insertedRange)
        let afterText = new.substring(with: NSRange(
            location: insertedRange.location,
            length: new.length - (prefix as NSString).length - (suffix as NSString).length))
        let oldTokens = tokens(in: beforeText)
        let newTokens = tokens(in: afterText)
        // One contiguous edit, including split/join errors such as
        // "fan basis" → "Fanbasis". Unchanged prefix/suffix establish ownership.
        var start = 0
        while start < min(oldTokens.count, newTokens.count),
              oldTokens[start].text == newTokens[start].text { start += 1 }
        var oldEnd = oldTokens.count, newEnd = newTokens.count
        while oldEnd > start, newEnd > start,
              oldTokens[oldEnd - 1].text == newTokens[newEnd - 1].text {
            oldEnd -= 1
            newEnd -= 1
        }
        guard (1...3).contains(oldEnd - start), (1...3).contains(newEnd - start) else { return nil }
        let oldRange = NSRange(location: oldTokens[start].range.location,
                               length: NSMaxRange(oldTokens[oldEnd - 1].range) - oldTokens[start].range.location)
        let newRange = NSRange(location: newTokens[start].range.location,
                               length: NSMaxRange(newTokens[newEnd - 1].range) - newTokens[start].range.location)
        let heard = (beforeText as NSString).substring(with: oldRange)
        let corrected = (afterText as NSString).substring(with: newRange)
        guard validTerm(heard), validTerm(corrected),
              (beforeText as NSString).substring(to: oldRange.location)
                == (afterText as NSString).substring(to: newRange.location),
              (beforeText as NSString).substring(from: NSMaxRange(oldRange))
                == (afterText as NSString).substring(from: NSMaxRange(newRange)) else { return nil }
        let absoluteStart = insertedRange.location + oldRange.location
        let absoluteEnd = absoluteStart + oldRange.length
        let fullTokens = tokens(in: before)
        guard fullTokens.contains(where: { $0.range.location == absoluteStart }),
              fullTokens.contains(where: { NSMaxRange($0.range) == absoluteEnd }) else { return nil }
        let context = context(at: start, through: oldEnd - 1, tokens: oldTokens, text: beforeText)
        return Candidate(heard: heard, corrected: corrected, context: context,
                         range: oldRange, sentenceInitial: context.before.isEmpty)
    }

    static func validTerm(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 60,
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0.isWhitespace || "-'’".contains($0) }) else { return false }
        return (1...3).contains(tokens(in: text).count)
    }

    static func normalized(_ text: String) -> String {
        tokens(in: text).map { $0.text.lowercased() }.joined(separator: " ")
    }

    static func candidate(before: String, after: String, insertedRange: NSRange?) -> Candidate? {
        guard let edit = edit(before: before, after: after, insertedRange: insertedRange),
              isLearnable(edit) else { return nil }
        return edit
    }

    static func isLearnable(_ edit: Candidate) -> Bool {
        if tokens(in: edit.heard).count > 1 || tokens(in: edit.corrected).count > 1 {
            let a = normalized(edit.heard).replacingOccurrences(of: " ", with: "")
            let b = normalized(edit.corrected).replacingOccurrences(of: " ", with: "")
            guard !a.isEmpty, !b.isEmpty,
                  1 - Double(levenshtein(a, b)) / Double(max(a.count, b.count)) >= 0.75 else { return false }
        }
        guard validTerm(edit.heard), validTerm(edit.corrected),
              isPlausibleMishearing(heard: edit.heard.replacingOccurrences(of: " ", with: ""),
                                    corrected: edit.corrected.replacingOccurrences(of: " ", with: "")),
              isLearnableTerm(edit.corrected, sentenceInitial:
                edit.sentenceInitial && edit.heard.lowercased() == edit.corrected.lowercased()) else { return false }
        // Even case-only changes can alter meaning (us → US, it → IT).
        return edit.context?.hasEnoughEvidence == true
    }

    static func isLearnableTerm(_ word: String, sentenceInitial: Bool) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if isStrongTerm(word) { return true }
        return !sentenceInitial && word.first?.isUppercase == true
            && word.dropFirst().contains(where: \.isLowercase)
    }

    static func isStrongTerm(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return (word == word.uppercased() && word != word.lowercased())
            || word.contains(where: \.isNumber)
            || word.dropFirst().contains(where: \.isUppercase)
    }

    static func isPlausibleMishearing(heard: String, corrected: String) -> Bool {
        let a = heard.lowercased(), b = corrected.lowercased()
        guard !a.isEmpty, !b.isEmpty, a.count <= 40, b.count <= 40 else { return false }
        if a == b { return true }
        let ratio = 1 - Double(levenshtein(a, b)) / Double(max(a.count, b.count))
        if ratio >= 0.6 { return true }
        // "wh" and "w" commonly share pronunciation (Whop/Womp). This
        // only admits an observed user edit; retrieval never uses this fold.
        let foldedA = a.replacingOccurrences(of: "wh", with: "w")
        let foldedB = b.replacingOccurrences(of: "wh", with: "w")
        if ratio >= 0.5,
           1 - Double(levenshtein(foldedA, foldedB)) / Double(max(foldedA.count, foldedB.count)) >= 0.6 { return true }
        // Soundex is only supporting evidence for an observed edit, never a
        // standalone match or a substitute for acoustics during transcription.
        return min(a.count, b.count) >= 3 && ratio >= 0.4 && soundex(a) == soundex(b)
    }

    /// At most two words on each side, contained in this sentence/dictation.
    static func context(at index: Int, through end: Int? = nil, tokens: [Token], text: String) -> Context {
        let source = text as NSString
        func crossesBoundary(_ left: Int, _ right: Int) -> Bool {
            let start = NSMaxRange(tokens[left].range)
            let gap = source.substring(with: NSRange(location: start, length: tokens[right].range.location - start))
            return gap.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?;\n\r")) != nil
        }
        var before: [String] = [], after: [String] = []
        var i = index
        while i > 0, before.count < 2, !crossesBoundary(i - 1, i) {
            i -= 1
            before.insert(tokens[i].text.lowercased(), at: 0)
        }
        i = end ?? index
        while i + 1 < tokens.count, after.count < 2, !crossesBoundary(i, i + 1) {
            i += 1
            after.append(tokens[i].text.lowercased())
        }
        return Context(before: before, after: after)
    }

    /// Verify that this field actually received our paste, using its pre-paste
    /// value and selection. Without a selection, accept only a unique insertion
    /// whose removal recovers the previous value exactly.
    static func insertionRange(text: String, before: String, after: String, selection: NSRange?) -> NSRange? {
        let old = before as NSString, new = after as NSString
        let length = (text as NSString).length
        guard length > 0, old.length <= maxTextLength, new.length <= maxTextLength else { return nil }
        if let selection, valid(selection, length: old.length) {
            guard old.replacingCharacters(in: selection, with: text) == after else { return nil }
            return NSRange(location: selection.location, length: length)
        }
        let first = new.range(of: text)
        guard first.location != NSNotFound, first == new.range(of: text, options: .backwards),
              new.replacingCharacters(in: first, with: "") == before else { return nil }
        return first
    }

    private static func valid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= length && range.length <= length - range.location
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }

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
            default: return nil
            }
        }
        var result = String(Character(first)), previous = code(first)
        for scalar in letters.dropFirst() {
            let c = code(scalar)
            if let c, c != previous { result.append(c) }
            let ch = Character(scalar)
            if ch != "H" && ch != "W" { previous = c }
            if result.count == 4 { break }
        }
        return String((result + "000").prefix(4))
    }
}
