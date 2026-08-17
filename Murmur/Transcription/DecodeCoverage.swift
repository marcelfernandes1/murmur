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
        print("[Coverage] \(cases.count - failed)/\(cases.count) passed")
        fflush(stdout) // GUI launch block-buffers stdout; flush so the result is observable.
        return failed
    }
}
