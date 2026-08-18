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
    // Level alone can't decide it either — a quiet dictation and room tone can
    // sit at the same amplitude. What separates them is *shape*: speech is
    // modulated (syllables, stops, gaps between words) so its loud frames tower
    // over its quiet ones, while room tone is flat. Measured over 100 ms frames:
    // room tone p90/p10 = 1.0; speech = 8.1 even at a peak of 0.03, and higher
    // at normal levels. Suppression needs BOTH a flat shape and a low level, so
    // speech recorded into a noisy room (flat-ish, but loud) is never written
    // off.

    /// Below this ratio of loud frames to quiet frames, audio looks unmodulated.
    static let minSpeechDynamicRange: Float = 3.0
    /// …and only that flat audio this quiet counts as no speech at all.
    static let maxSilenceLevel: Float = 0.01

    /// Whether these samples contain anything worth transcribing. False means a
    /// silent take: decoding it would invent words, so the caller should not.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        let levels = frameLevels(samples[samples.startIndex..<samples.endIndex]).sorted()
        guard !levels.isEmpty else { return false }
        let p10 = levels[min(levels.count - 1, Int(Double(levels.count) * 0.1))]
        let p90 = levels[min(levels.count - 1, Int(Double(levels.count) * 0.9))]
        let dynamicRange = p90 / max(p10, 1e-6)
        return dynamicRange >= minSpeechDynamicRange || p90 >= maxSilenceLevel
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
    static func firstRecoverableGap(in segments: [WhisperSegment],
                                    samples: [Float],
                                    reference: Float) -> Gap? {
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

        for gap in gaps where gap.end - gap.start >= minGap {
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
    /// timestamp could cost to a few words rather than a sentence.
    static let maxFabricatedTailWords = 10

    /// Drop trailing segments that sit on silence — whisper talking to itself
    /// after the speaker stopped. Stops at the first segment with speech under
    /// it, so nothing before the real end of the dictation is ever considered.
    static func trimmingFabricatedTail(_ segments: [WhisperSegment],
                                       samples: [Float],
                                       reference: Float) -> [WhisperSegment] {
        var result = segments.sorted { $0.start < $1.start }
        while let last = result.last {
            let start = clampToSamples(last.start, limit: samples.count)
            let end = clampToSamples(last.end, limit: samples.count)
            // Can't judge a segment with no measurable span — leave it alone.
            guard end > start else { break }
            guard last.text.split(whereSeparator: \.isWhitespace).count <= maxFabricatedTailWords else { break }
            guard speechSeconds(samples[start..<end], reference: reference) < maxFabricatedTailSpeechSeconds else { break }
            result.removeLast()
        }
        return result
    }

    /// How loud this take's speech is, as the 90th-percentile frame level. Used
    /// as the yardstick for the gap check so a quietly-recorded dictation isn't
    /// written off as silence, and a noisy one doesn't count its noise as speech.
    static func speechReferenceLevel(_ samples: [Float]) -> Float {
        let levels = frameLevels(samples[samples.startIndex..<samples.endIndex]).sorted()
        guard !levels.isEmpty else { return 0 }
        return levels[min(levels.count - 1, Int(Double(levels.count) * 0.9))]
    }

    /// Seconds of speech-level audio inside `slice`.
    static func speechSeconds(_ slice: ArraySlice<Float>, reference: Float) -> Double {
        // 15% of the take's speech level, with an absolute floor so digital
        // silence (or a dead-mic hiss) can never clear the bar.
        let threshold = max(reference * 0.15, 0.002)
        let loud = frameLevels(slice).filter { $0 > threshold }.count
        return Double(loud) * Double(energyFrameSamples) / Double(sampleRate)
    }

    private static func clampToSamples(_ seconds: Double, limit: Int) -> Int {
        min(max(0, Int(seconds * Double(sampleRate))), limit)
    }

    private static func frameLevels(_ slice: ArraySlice<Float>) -> [Float] {
        var levels: [Float] = []
        var index = slice.startIndex
        while index < slice.endIndex {
            let end = min(index + energyFrameSamples, slice.endIndex)
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
