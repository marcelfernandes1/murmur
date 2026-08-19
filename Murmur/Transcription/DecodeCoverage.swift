import Foundation
import WhisperCppKit

/// Checks a whisper.cpp decode against the audio it was given.
///
/// whisper.cpp can return successfully having transcribed only part of what it
/// was handed: its internal no-speech check can write off a whole 30 s window as
/// silence, and a window whose decode ends early costs whatever was left in it.
/// Neither is reported as an error — the take simply stops mid-sentence, which
/// is the "it only transcribed the first half of what I said" bug.
///
/// Segment timings make that detectable: every second of audio should be
/// accounted for by some segment, so an uncovered stretch that still *sounds*
/// like speech is audio that was dropped and should be decoded again.
///
/// Pure and dependency-free so `runSelfTest` can exercise it directly.
enum DecodeCoverage {
    static let sampleRate = 16_000

    // MARK: Speech presence
    //
    // Handing whisper a take with no speech in it does not produce an empty
    // transcript — it produces an invented one. On a silent take it emits its
    // stock hallucinations ("Thank you.", "."), and when a custom vocabulary is
    // in play it simply echoes the initial prompt back, so every accidental
    // trigger pasted "VTURB, Whop, Fernandes". whisper's own `no_speech_prob`
    // does not catch this: it reports 0.00 on pure silence, measured.
    //
    // Level alone can't decide it — a quiet dictation and room tone can sit at
    // the same amplitude. What separates them is that speech *stands out from
    // the take's own noise floor*: it is modulated, and its loud frames tower
    // over the quiet ones. Room tone is flat, so nothing towers over anything.
    //
    // The test is deliberately "is there speech ANYWHERE", not "is this take
    // mostly speech". An earlier version compared the 90th percentile against
    // the 10th, which measured the *duty cycle* instead: a hands-free take where
    // the user said one sentence and then read quietly for three minutes put the
    // 90th percentile down in the room tone and the whole dictation was thrown
    // away with no paste, no history and no error. Speech occupying a small
    // fraction of a long recording is the normal case for hands-free, not a
    // silent take.

    /// A frame must stand this far above the take's noise floor to be speech.
    static let speechFloorMultiple: Float = 3.0
    /// …and clear this absolute level, so digital silence (where the floor is
    /// zero) can never qualify.
    static let minSpeechLevel: Float = 0.004
    /// A frame this loud is speech whatever the floor says. Needed because the
    /// ratio test alone fails on a loud noise floor — speech recorded next to a
    /// fan does not tower over the fan — while room tone never reaches this
    /// level (the loudest silent take observed in the field framed at 0.005).
    static let absoluteSpeechLevel: Float = 0.02
    /// Total speech needed anywhere in the take for it to be worth decoding.
    /// Shorter than the briefest real one-word dictation.
    static let minSpeechSecondsInTake = 0.2

    /// Whether these samples contain anything worth transcribing. False means a
    /// silent take: decoding it would invent words, so the caller should not.
    static func containsSpeech(_ samples: [Float], sampleRate: Int = sampleRate) -> Bool {
        let levels = frameLevels(samples[samples.startIndex..<samples.endIndex],
                                 frame: max(1, sampleRate / 10))
        guard !levels.isEmpty else { return false }
        return speechSeconds(levels: levels, reference: noiseFloor(of: levels)) >= minSpeechSecondsInTake
    }

    /// The take's noise floor, as the 10th-percentile frame level. A low
    /// percentile so it tracks the quiet background even when most of the
    /// recording is speech.
    static func noiseFloor(of levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0 }
        let sorted = levels.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.1))]
    }

    /// Ignore uncovered stretches shorter than this — ordinary gaps between
    /// segments, not lost audio.
    static let minGapSeconds = 1.5
    /// …and only re-decode a gap that actually sounds like speech, so leading or
    /// trailing silence (the common, legitimate case) costs nothing.
    static let minGapSpeechSeconds = 0.6
    /// Level metering frame for the speech check.
    static let energyFrameSamples = sampleRate / 10   // 100 ms

    /// A stretch of the samples that no segment accounts for.
    struct Gap: Equatable {
        let start: Int
        let end: Int
    }

    /// The first uncovered stretch long enough — and loud enough — to be worth
    /// decoding again, or nil when the decode covered everything audible.
    /// `excluding` holds the start offsets of gaps already attempted, so a gap
    /// that could not be recovered is skipped rather than blocking every later
    /// one (an early unrecoverable gap used to abort recovery for the whole take).
    static func firstRecoverableGap(in segments: [WhisperSegment],
                                    samples: [Float],
                                    reference: Float,
                                    excluding: Set<Int> = []) -> Gap? {
        let sampleCount = samples.count
        let minGap = Int(minGapSeconds * Double(sampleRate))
        var cursor = 0
        var gaps: [Gap] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let start = clampToSamples(segment.start, limit: sampleCount)
            let end = clampToSamples(segment.end, limit: sampleCount)
            if start > cursor { gaps.append(Gap(start: cursor, end: start)) }
            cursor = max(cursor, end)
        }
        if cursor < sampleCount { gaps.append(Gap(start: cursor, end: sampleCount)) }

        for gap in gaps where gap.end - gap.start >= minGap && !excluding.contains(gap.start) {
            if speechSeconds(samples[gap.start..<gap.end], reference: reference) >= minGapSpeechSeconds {
                return gap
            }
        }
        return nil
    }

    // MARK: Fabricated tail
    //
    // whisper does not stop at the last word — it keeps decoding into whatever
    // silence follows, and on silence it invents. Its stock line is "Thank you."
    // (the same one a wholly silent take produces), tacked onto the end of a
    // perfectly good dictation. 124 transcripts in the field ended that way.
    //
    // Timestamps make it separable from real speech: a fabricated closing sits
    // over audio where nobody is talking. So rather than pattern-matching the
    // text against a list of known whisper tics — which would never be complete —
    // trailing segments are dropped when there is no speech underneath them.

    /// A trailing segment is only ever dropped if it holds less speech than this.
    static let maxFabricatedTailSpeechSeconds = 0.15
    /// …and is short. Real invented closings are; the cap bounds what a bad
    /// timestamp could cost to a few words rather than a sentence. Measured in
    /// characters as well as words, because whitespace-splitting counts a whole
    /// Chinese/Japanese/Korean sentence as one "word" and would bound nothing.
    static let maxFabricatedTailWords = 10
    static let maxFabricatedTailCharacters = 60

    /// Drop trailing segments that sit on silence — whisper talking to itself
    /// after the speaker stopped. Stops at the first segment with speech under
    /// it, so nothing before the real end of the dictation is ever considered.
    static func trimmingFabricatedTail(_ segments: [WhisperSegment],
                                       samples: [Float],
                                       reference: Float) -> [WhisperSegment] {
        var result = segments.sorted { $0.start < $1.start }
        // Never trim the take down to nothing. If every segment looks fabricated
        // the timestamps are not trustworthy, and delivering whisper's best guess
        // beats delivering an empty transcript the user is never told about.
        while result.count > 1, let last = result.last {
            let start = clampToSamples(last.start, limit: samples.count)
            let end = clampToSamples(last.end, limit: samples.count)
            // Can't judge a segment with no measurable span — leave it alone.
            guard end > start else { break }
            guard last.text.split(whereSeparator: \.isWhitespace).count <= maxFabricatedTailWords,
                  last.text.count <= maxFabricatedTailCharacters else { break }
            guard speechSeconds(samples[start..<end], reference: reference) < maxFabricatedTailSpeechSeconds else { break }
            result.removeLast()
        }
        return result
    }

    /// The yardstick the gap and tail checks measure against: this take's noise
    /// floor. Computed once per take and passed down, so a quietly-recorded
    /// dictation isn't written off and a noisy one doesn't count its hiss as
    /// speech.
    static func speechReferenceLevel(_ samples: [Float]) -> Float {
        noiseFloor(of: frameLevels(samples[samples.startIndex..<samples.endIndex]))
    }

    /// Seconds of speech-level audio inside `slice`.
    static func speechSeconds(_ slice: ArraySlice<Float>, reference: Float) -> Double {
        speechSeconds(levels: frameLevels(slice), reference: reference)
    }

    /// Speech must clear both bars: well above this take's own noise floor, and
    /// above an absolute level so a silent take (floor ≈ 0) can't qualify by
    /// ratio alone.
    static func speechSeconds(levels: [Float], reference: Float) -> Double {
        let threshold = min(max(reference * speechFloorMultiple, minSpeechLevel), absoluteSpeechLevel)
        var loud = 0
        for level in levels where level > threshold { loud += 1 }
        return Double(loud) * Double(energyFrameSamples) / Double(sampleRate)
    }

    /// Clamp BEFORE converting: `Int(Double)` traps on NaN, infinity, or
    /// anything beyond Int64, and whisper timestamps are unvalidated C int64s
    /// that degenerate decoding can make wild. Clamping the Int afterwards, as
    /// this used to, cannot prevent the trap.
    /// Public clamp for callers working in a slice's own coordinate space.
    static func clamp(_ seconds: Double, within limit: Int) -> Int {
        clampToSamples(seconds, limit: limit)
    }

    private static func clampToSamples(_ seconds: Double, limit: Int) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(0, seconds) * Double(sampleRate), Double(limit)))
    }

    private static func frameLevels(_ slice: ArraySlice<Float>, frame: Int = energyFrameSamples) -> [Float] {
        var levels: [Float] = []
        var index = slice.startIndex
        while index < slice.endIndex {
            let end = min(index + frame, slice.endIndex)
            var sumSquares: Float = 0
            for i in index..<end { sumSquares += slice[i] * slice[i] }
            levels.append((sumSquares / Float(end - index)).squareRoot())
            index = end
        }
        return levels
    }

    // MARK: - Self-test

    /// Env-gated self-test (mirrors `DictationController.runCaptureSelfTest`).
    /// Run with: `MURMUR_TEST_COVERAGE=1 open Murmur.app` and read the log.
    /// Returns the number of failures so a harness can exit non-zero.
    @discardableResult
    static func runSelfTest() -> Int {
        let rate = sampleRate
        /// `speech` marks which whole seconds carry speech; the rest is silence.
        func audio(seconds: Int, speech: Range<Int>) -> [Float] {
            (0..<(seconds * rate)).map { i in
                speech.contains(i / rate) ? (i % 2 == 0 ? 0.2 : -0.2) : 0
            }
        }
        func segment(_ start: Double, _ end: Double) -> WhisperSegment {
            WhisperSegment(text: "x", start: start, end: end)
        }

        struct Case {
            let name: String
            let samples: [Float]
            let segments: [WhisperSegment]
            let expect: Gap?
        }
        // The reported bug: a 20 s window decoded ~1 s and dropped the rest.
        let allSpeech = audio(seconds: 20, speech: 0..<20)
        let cases: [Case] = [
            .init(name: "tail dropped after 1s of a 20s window", samples: allSpeech,
                  segments: [segment(0, 1)], expect: Gap(start: rate, end: 20 * rate)),
            .init(name: "fully covered", samples: allSpeech,
                  segments: [segment(0, 10), segment(10, 20)], expect: nil),
            // whisper.cpp's no-speech check writing off a window mid-take.
            .init(name: "gap in the middle", samples: allSpeech,
                  segments: [segment(0, 5), segment(14, 20)],
                  expect: Gap(start: 5 * rate, end: 14 * rate)),
            // Legitimate silence must not trigger a pointless re-decode.
            .init(name: "trailing silence is not a gap",
                  samples: audio(seconds: 20, speech: 0..<8),
                  segments: [segment(0, 8)], expect: nil),
            .init(name: "leading silence is not a gap",
                  samples: audio(seconds: 20, speech: 10..<20),
                  segments: [segment(10, 20)], expect: nil),
            // Short gaps are ordinary breathing room between segments.
            .init(name: "1s gap is below threshold", samples: allSpeech,
                  segments: [segment(0, 9), segment(10, 20)], expect: nil),
            // A decode that returned nothing at all for real speech.
            .init(name: "no segments at all", samples: allSpeech, segments: [],
                  expect: Gap(start: 0, end: 20 * rate)),
            // Timestamps running past the audio must not invent a gap.
            .init(name: "segment end beyond audio", samples: allSpeech,
                  segments: [segment(0, 45)], expect: nil),
            // Out-of-order segments must still be measured correctly.
            .init(name: "unsorted segments", samples: allSpeech,
                  segments: [segment(14, 20), segment(0, 5)],
                  expect: Gap(start: 5 * rate, end: 14 * rate)),
            // Digital silence is never worth a re-decode, however long.
            .init(name: "silent take", samples: audio(seconds: 20, speech: 0..<0),
                  segments: [], expect: nil),
        ]

        var failed = 0
        for c in cases {
            let reference = speechReferenceLevel(c.samples)
            let got = firstRecoverableGap(in: c.segments, samples: c.samples, reference: reference)
            let ok = got == c.expect
            if !ok { failed += 1 }
            print("[Coverage] \(ok ? "PASS" : "FAIL") \(c.name)  got=\(String(describing: got)) expect=\(String(describing: c.expect))")
        }

        // Speech presence. Levels below are the ones actually measured off the
        // reporter's mic: silent takes peaked at 0.0033–0.0089, every real
        // dictation at 0.0285 or above.
        func noise(seconds: Double, peak: Float) -> [Float] {
            var state: UInt64 = 88172645463325252
            return (0..<Int(seconds * Double(rate))).map { _ in
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return (Float(state % 2000) / 1000 - 1) * peak
            }
        }
        /// Speech-shaped: loud syllables separated by quiet gaps.
        func speech(seconds: Double, peak: Float) -> [Float] {
            (0..<Int(seconds * Double(rate))).map { i in
                let syllable = (i / (rate / 5)) % 2 == 0        // 200 ms on, 200 ms off
                let level = syllable ? peak : peak * 0.01
                return (i % 2 == 0 ? level : -level)
            }
        }
        struct SpeechCase { let name: String; let samples: [Float]; let expect: Bool }
        let speechCases: [SpeechCase] = [
            .init(name: "room tone at the level that echoed the vocabulary",
                  samples: noise(seconds: 0.94, peak: 0.0033), expect: false),
            .init(name: "room tone, 2 s", samples: noise(seconds: 2, peak: 0.0057), expect: false),
            .init(name: "room tone at the loudest silent take seen",
                  samples: noise(seconds: 1.4, peak: 0.0089), expect: false),
            .init(name: "digital silence", samples: [Float](repeating: 0, count: 2 * rate), expect: false),
            .init(name: "normal dictation", samples: speech(seconds: 3, peak: 0.09), expect: true),
            .init(name: "very quiet dictation", samples: speech(seconds: 3, peak: 0.03), expect: true),
            // Must survive: flat-looking because of the noise, but plainly loud.
            .init(name: "speech in a noisy room stays speech",
                  samples: zip(speech(seconds: 3, peak: 0.05), noise(seconds: 3, peak: 0.04)).map(+),
                  expect: true),
            // Must survive: too short to show modulation, but plainly loud.
            .init(name: "one short loud word", samples: speech(seconds: 0.3, peak: 0.08), expect: true),
            .init(name: "empty buffer", samples: [], expect: false),
        ]
        for c in speechCases {
            let got = containsSpeech(c.samples)
            let ok = got == c.expect
            if !ok { failed += 1 }
            print("[Coverage] \(ok ? "PASS" : "FAIL") speech: \(c.name)  got=\(got) expect=\(c.expect)")
        }

        // Fabricated tail. `speech` below is 200 ms on / 200 ms off, so a span
        // over the speech region reads as speech and one over silence does not.
        struct TailCase {
            let name: String
            let samples: [Float]
            let segments: [WhisperSegment]
            let expectKept: Int
        }
        let realThenSilence = speech(seconds: 10, peak: 0.09) + [Float](repeating: 0, count: 5 * rate)
        let tailCases: [TailCase] = [
            // The reported bug: "Thank you." invented over trailing silence.
            .init(name: "invented closing over trailing silence", samples: realThenSilence,
                  segments: [segment(0, 10), WhisperSegment(text: "Thank you.", start: 11, end: 13)],
                  expectKept: 1),
            // Several in a row all go.
            .init(name: "two invented closings", samples: realThenSilence,
                  segments: [segment(0, 10),
                             WhisperSegment(text: "Thank you.", start: 10.5, end: 12),
                             WhisperSegment(text: "Bye.", start: 12.5, end: 14)],
                  expectKept: 1),
            // Must NOT trim: the last segment is real speech.
            .init(name: "real final segment is kept", samples: realThenSilence,
                  segments: [segment(0, 5), segment(5, 10)], expectKept: 2),
            .init(name: "nothing but real speech", samples: speech(seconds: 10, peak: 0.09),
                  segments: [segment(0, 5), segment(5, 10)], expectKept: 2),
            // Must NOT trim: too long to be a whisper tic, so leave it be even
            // though the timestamps put it over silence.
            .init(name: "long trailing segment is left alone", samples: realThenSilence,
                  segments: [segment(0, 10),
                             WhisperSegment(text: "one two three four five six seven eight nine ten eleven",
                                            start: 11, end: 13)],
                  expectKept: 2),
            // Must NOT trim on a zero-length span — nothing to judge.
            .init(name: "zero-length span is left alone", samples: realThenSilence,
                  segments: [segment(0, 10), WhisperSegment(text: "Thank you.", start: 12, end: 12)],
                  expectKept: 2),
        ]
        for c in tailCases {
            let reference = speechReferenceLevel(c.samples)
            let kept = trimmingFabricatedTail(c.segments, samples: c.samples, reference: reference)
            let ok = kept.count == c.expectKept
            if !ok { failed += 1 }
            print("[Coverage] \(ok ? "PASS" : "FAIL") tail: \(c.name)  kept=\(kept.count) expect=\(c.expectKept)")
        }

        let total = cases.count + speechCases.count + tailCases.count
        print("[Coverage] \(total - failed)/\(total) passed")
        fflush(stdout) // GUI launch block-buffers stdout; flush so the result is observable.
        return failed
    }
}
