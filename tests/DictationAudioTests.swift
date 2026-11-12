import AVFoundation
import Foundation
import WhisperCppKit

/// Exercises the production gate and tail filter with actual speech, including
/// the same recording at several gains. Optionally runs the installed model.
@main
struct DictationAudioTests {
    static func main() throws {
        var failures = DecodeCoverage.runSelfTest()
        func check(_ name: String, _ passed: Bool) {
            print("[DictationAudio] \(passed ? "PASS" : "FAIL") \(name)")
            if !passed { failures += 1 }
        }

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let speech = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let peak = speech.map { abs($0) }.max()!
        let duration = Double(speech.count) / 16_000
        let segments = [WhisperSegment(text: "The first sentence.", start: 0, end: duration / 2),
                        WhisperSegment(text: "The final sentence must remain complete.", start: duration / 2, end: duration)]

        for gain: Float in [0.06, 0.01, 0.005, 0.002] {
            let quiet = speech.map { $0 * gain / peak }
            let reference = DecodeCoverage.speechReferenceLevel(quiet)
            check("speech at peak \(gain) reaches the recognizer", DecodeCoverage.containsSpeech(quiet))
            check("speech at peak \(gain) keeps its ending",
                  DecodeCoverage.trimmingFabricatedTail(segments, samples: quiet, reference: reference) == segments)
            check("quiet speech before long silence survives",
                  DecodeCoverage.containsSpeech(quiet + [Float](repeating: 0, count: 120 * 16_000)))
            check("missing quiet speech is recoverable",
                  DecodeCoverage.firstRecoverableGap(in: [], samples: quiet, reference: 0.01) != nil)
        }

        // The user gets quieter during a take. The beginning's volume must not
        // determine whether the end of the transcript is retained.
        let fading = speech.enumerated().map { index, value in
            value / peak * (index < speech.count / 2 ? Float(0.06) : Float(0.002))
        }
        check("quiet second half remains intact",
              DecodeCoverage.trimmingFabricatedTail(segments, samples: fading,
                  reference: DecodeCoverage.speechReferenceLevel(fading)) == segments)

        // A short final word and a slightly late timestamp both used to lose text.
        func pulse(start: Double, seconds: Double) -> [Float] {
            var samples = [Float](repeating: 0, count: 4 * 16_000)
            for i in Int(start * 16_000)..<Int((start + seconds) * 16_000) {
                samples[i] = i % 2 == 0 ? 0.002 : -0.002
            }
            return samples
        }
        let shortWord = pulse(start: 2, seconds: 0.12)
        let shortSegments = [WhisperSegment(text: "First sentence.", start: 0, end: 1.5),
                             WhisperSegment(text: "Yes.", start: 2, end: 2.2)]
        check("short quiet word is not silence", DecodeCoverage.containsSpeech(shortWord))
        check("short final word is kept",
              DecodeCoverage.trimmingFabricatedTail(shortSegments, samples: shortWord, reference: 0) == shortSegments)
        check("timestamp tolerance protects a final word",
              DecodeCoverage.trimmingFabricatedTail(shortSegments, samples: pulse(start: 1.8, seconds: 0.12), reference: 0) == shortSegments)
        check("brief click is not speech", !DecodeCoverage.containsSpeech(pulse(start: 2, seconds: 0.02)))
        // Same 120 ms word at 24 kHz, used by the realtime engine.
        let at24k = [Float](repeating: 0, count: 24_000)
            + [Float](repeating: 0.002, count: 2_880)
            + [Float](repeating: 0, count: 24_000)
        check("24 kHz uses the same speech duration", DecodeCoverage.containsSpeech(at24k, sampleRate: 24_000))

        if CommandLine.arguments.count > 2 {
            guard let model = WhisperModel(path: CommandLine.arguments[2]) else {
                print("[DictationAudio] FAIL could not load requested model")
                exit(1)
            }
            for (name, samples) in [("quiet", speech.map { $0 * 0.002 / peak }), ("fading", fading)] {
                guard let decoded = model.transcribe(samples: samples, language: "en", vocabulary: []) else {
                    check("\(name) model decode", false)
                    continue
                }
                let kept = DecodeCoverage.trimmingFabricatedTail(decoded, samples: samples,
                    reference: DecodeCoverage.speechReferenceLevel(samples))
                let text = kept.map(\.text).joined(separator: " ").lowercased()
                check("\(name) actual model keeps beginning, middle and end",
                      DecodeCoverage.containsSpeech(samples)
                      && text.contains("keep every word")
                      && text.contains("explains the problem")
                      && text.contains("final sentence must remain complete"))
            }
        }
        print("[DictationAudio] failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
