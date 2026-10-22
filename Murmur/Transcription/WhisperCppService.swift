import Foundation
import OSLog
import WhisperCppKit

/// whisper.cpp-backed engine (Metal-accelerated via the official XCFramework,
/// wrapped by the WhisperCppKit package). Loads a ggml model file once —
/// downloading it from Hugging Face on first use — and reuses the context. Added
/// so we can A/B every ggml model variant (sizes × quantizations × English-only)
/// against the WhisperKit/Parakeet engines to find the best speed/accuracy ratio.
///
/// Takes are decoded in ONE `whisper_full` call, however long they are —
/// whisper.cpp does its own 30 s windowing internally and, with timestamps on
/// (see `WhisperModel`), advances correctly between windows.
///
/// This used to be split into overlapping 25 s chunks that were transcribed
/// separately and stitched back together by matching words across the seam.
/// That existed to contain the damage from the `no_timestamps` bug, and once
/// that was fixed it was pure downside: every 20 s the audio was cut at an
/// arbitrary instant, usually mid-phrase, and the two halves had to be rejoined
/// by guessing which words overlapped. On repetitive speech that guess deletes
/// real words — a dictation lost "thank you page" at exactly such a seam. There
/// is no seam now, so there is nothing to guess.
actor WhisperCppService: SpeechEngine {
    /// ggml weights filename, e.g. `ggml-large-v3-turbo-q5_0.bin`.
    private let fileName: String
    private var model: WhisperModel?
    private var loadTask: Task<WhisperModel, Error>?
    private var stateHandler: (@Sendable (EngineLoadState) -> Void)?

    /// Shares the "audio" category with `AudioRecorder` / `DictationController`
    /// so one log stream shows capture and transcription together.
    private static let log = Logger(subsystem: "com.murmur.app", category: "audio")

    /// All ggml models live in this one Hugging Face repo.
    private static let repo = "ggerganov/whisper.cpp"
    private static let sampleRate = 16_000

    // MARK: Coverage recovery tuning
    //
    // Even with timestamps on (see WhisperModel), whisper.cpp has paths that
    // abandon a window outright — most notably its own no-speech check, which
    // can decide a window is silence and skip all 30 s of it. When that lands on
    // real speech the take loses that stretch with no error of any kind. So we
    // check the decode against the audio: every second we handed in should be
    // accounted for by some segment, and any stretch that isn't gets decoded
    // again on its own and spliced back into place.

    /// Hard cap on re-decodes per take so a pathological one can't spin. Higher
    /// than it needed to be per-chunk, since one take is now one decode.
    /// What counts as a gap lives in `DecodeCoverage`.
    private static let maxRecoveryPasses = 8

    init(fileName: String) {
        self.fileName = fileName
    }

    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) {
        stateHandler = handler
    }

    func preload() async {
        _ = try? await loadModel()
    }


    func verifyLearning(_ samples: [Float], language: String?, hints: [String]) async throws -> String {
        try await transcribe(samples, language: language, vocabulary: hints)
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let model = try await loadModel()
        // Synchronous inside the actor: serializes calls (whisper_full is not
        // reentrant on a shared context) and never touches the main thread.
        return try decode(samples, model: model, language: language, vocabulary: vocabulary)
            .map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func transcribePersonalized(_ samples: [Float], language: String?, vocabulary: [String],
                                corrections: [LearnedCorrection]) async throws -> PersonalizedTranscript {
        guard !samples.isEmpty else { return PersonalizedTranscript(text: "", original: "", applications: []) }
        let model = try await loadModel()
        // Keep the full decode and coverage recovery intact. Timestamps, never
        // text overlap guesses, locate the audio for optional verification.
        let segments = try decode(samples, model: model, language: language, vocabulary: vocabulary)
            .filter { !$0.text.isEmpty }
        let original = segments.map(\.text).joined(separator: " ")
        guard corrections.contains(where: { !$0.needsContext }) else {
            return PersonalizedTranscript(text: original, original: original, applications: [])
        }
        if samples.count <= 25 * Self.sampleRate {
            let application = try await verifyPersonalization(original, samples: samples, language: language, corrections: corrections)
            return PersonalizedTranscript(text: application.text, original: original, applications: [application])
        }
        var applications: [LearningApplication] = []
        var cursor = 0, checks = 0
        while cursor < segments.count {
            try Task.checkCancellation()
            let first = cursor
            cursor += 1
            while cursor < segments.count, segments[cursor].end - segments[first].start <= 24 {
                cursor += 1
            }
            let text = segments[first..<cursor].map(\.text).joined(separator: " ")
            let start = DecodeCoverage.clamp(segments[first].start, within: samples.count)
            let end = DecodeCoverage.clamp(segments[cursor - 1].end, within: samples.count)
            if checks < 8, end > start, end - start <= 25 * Self.sampleRate,
               !LearningPlan.make(text: text, corrections: corrections).proposals.isEmpty {
                checks += 1
                applications.append(try await verifyPersonalization(text, samples: Array(samples[start..<end]),
                                                                      language: language, corrections: corrections))
            } else {
                applications.append(LearningApplication(text: text, applied: []))
            }
        }
        return PersonalizedTranscript(text: applications.map(\.text).joined(separator: " "), original: original, applications: applications)
    }

    /// Decode the take, then verify the decode actually covered it. Any
    /// speech-bearing stretch whisper.cpp skipped is decoded again on its own and
    /// spliced back in time order, so a bailed-out window costs a re-decode
    /// instead of the rest of the dictation.
    private func decode(_ samples: [Float],
                        model: WhisperModel,
                        language: String?,
                        vocabulary: [String]) throws -> [WhisperSegment] {
        guard var segments = model.transcribe(samples: samples, language: language, vocabulary: vocabulary) else {
            throw WhisperCppError.inferenceFailed
        }

        let reference = DecodeCoverage.speechReferenceLevel(samples)
        var passes = 0
        var attempted: Set<Int> = []
        while passes < Self.maxRecoveryPasses,
              let gap = DecodeCoverage.firstRecoverableGap(in: segments, samples: samples,
                                                           reference: reference,
                                                           excluding: attempted) {
            passes += 1
            attempted.insert(gap.start)
            let slice = Array(samples[gap.start..<gap.end])
            // NO vocabulary here. A gap slice is short, and whisper_full pads
            // anything under 30 s with silence — handing it the vocabulary as an
            // initial prompt again is precisely the condition that makes whisper
            // transcribe the prompt itself, and a recovered segment lands in the
            // MIDDLE of the transcript where neither the tail trim nor the echo
            // strip can reach it. Recovery buys back dropped audio; it must not
            // be able to introduce text.
            let recovered = model.transcribe(samples: slice, language: language, vocabulary: []) ?? []
            let offset = Double(gap.start) / Double(Self.sampleRate)
            // Keep only what genuinely sits on speech inside this gap. whisper
            // invents over the padding too, and an invented closing here would be
            // spliced mid-sentence.
            let kept = recovered.compactMap { segment -> WhisperSegment? in
                guard segment.end > segment.start else { return nil }
                let start = DecodeCoverage.clamp(segment.start, within: slice.count)
                let end = DecodeCoverage.clamp(segment.end, within: slice.count)
                guard end > start,
                      DecodeCoverage.speechSeconds(slice[start..<end], reference: reference) > 0 else { return nil }
                return WhisperSegment(text: segment.text,
                                      start: segment.start + offset,
                                      end: segment.end + offset)
            }
            let from = offset
            let to = Double(gap.end) / Double(Self.sampleRate)
            Self.log.warning("coverage gap \(from, privacy: .public)s–\(to, privacy: .public)s was not transcribed → re-decoded, recovered \(kept.count, privacy: .public) segments")
            #if DEBUG
            Self.fileLog("WHISPER_CPP recovered gap \(gap.start)–\(gap.end) segments=\(kept.count)")
            #endif
            // Nothing usable here — move on to the next gap rather than giving up
            // on the rest of the take.
            guard !kept.isEmpty else { continue }
            segments.append(contentsOf: kept)
            segments.sort { $0.start < $1.start }
        }

        // whisper keeps decoding past the last word and invents a closing over the
        // trailing silence ("Thank you."). Drop anything at the end that has no
        // speech under it, after recovery so a real dropped tail is back first.
        let trimmed = DecodeCoverage.trimmingFabricatedTail(segments, samples: samples, reference: reference)
        if trimmed.count < segments.count {
            Self.log.log("dropped \(segments.count - trimmed.count, privacy: .public) fabricated trailing segment(s) sitting on silence")
        }

        return trimmed
    }

    private func loadModel() async throws -> WhisperModel {
        if let model { return model }
        if let loadTask { return try await loadTask.value }
        let fileName = fileName
        let notify = stateHandler
        let task = Task { () throws -> WhisperModel in
            notify?(.preparing)
            let modelURL = try await Self.downloadIfNeeded(fileName: fileName, notify: notify)
            guard let model = WhisperModel(path: modelURL.path) else {
                throw WhisperCppError.modelLoadFailed
            }
            notify?(.ready)
            return model
        }
        loadTask = task
        do {
            let model = try await task.value
            self.model = model
            return model
        } catch {
            loadTask = nil
            notify?(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Fetch the ggml file from Hugging Face into Application Support (matches
    /// LLMCleaner / WhisperService — keeps weights out of ~/Documents, avoiding the
    /// TCC prompt). Reports download progress so a multi-GB fetch isn't a frozen UI.
    private static func downloadIfNeeded(fileName: String,
                                         notify: (@Sendable (EngineLoadState) -> Void)?) async throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            // Verify the cached file against the pinned SHA-256, not just its
            // size. Size alone meant the hash was checked exactly once ever — on
            // first download — so any process running as the user could swap in a
            // tampered file of the same byte count and it would be fed to the
            // ggml C parser unchecked on every later launch. Hashing costs a
            // second or two, once per launch, off the main thread.
            if (try? ModelManifest.verify(fileName: fileName, at: dest)) != nil { return dest }
            try? FileManager.default.removeItem(at: dest)
        }

        guard let remote = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)?download=true") else {
            throw WhisperCppError.modelLoadFailed
        }
        notify?(.downloading(0))
        let downloader = ModelDownloader { fraction in notify?(.downloading(fraction)) }
        // Land the download beside the real path and only move it into place once
        // it verifies. Downloading straight to `dest` meant a crash or quit during
        // the multi-second hash of a multi-gigabyte file left an UNVERIFIED file
        // at the real filename, which every later launch then trusted.
        let staging = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: staging)
        let url = try await downloader.download(from: remote, to: staging)
        do {
            try ModelManifest.verify(fileName: fileName, at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: url)
        } else {
            try FileManager.default.moveItem(at: url, to: dest)
        }
        return dest
    }

    enum WhisperCppError: Error { case modelLoadFailed, inferenceFailed }
}

#if DEBUG
private extension WhisperCppService {
    static func fileLog(_ message: String) {
        let line = "\(message)\n"
        let url = URL(fileURLWithPath: "/tmp/murmur_audio.log")
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif

#if DEBUG
import AVFoundation

extension WhisperCppService {
    /// Explicit developer-only fixture runner; never records, pastes, or writes
    /// the user's vocabulary. Outputs synthetic fixture text only.
    static func runLearningAudioTests(fixtures: String) async -> Int {
        struct Fixture: Decodable { let path: String; let contains: String; let excludes: [String] }
        var failures = 0
        do {
            let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: fixtures)))
            let context = CorrectionDetector.Context(before: ["payment", "through"], after: ["for", "subscriptions"])
            let corrections = ["wap", "womp", "wop", "wapt"].map {
                LearnedCorrection(heard: $0, corrected: "Whop", createdAt: Date(), contexts: [context])
            } + [LearnedCorrection(heard: "fan basis", corrected: "Fanbasis", createdAt: Date(), contexts: [context])]
            let engine = WhisperCppService(fileName: ProcessInfo.processInfo.environment["MURMUR_TEST_MODEL"] ?? "ggml-large-v3.bin")
            for fixture in cases {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture.path))
                guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return 1 }
                try file.read(into: buffer)
                guard let channel = buffer.floatChannelData?[0] else { return 1 }
                let audio = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                let result = try await engine.transcribePersonalized(audio, language: "en", vocabulary: [], corrections: corrections)
                let pass = result.text.localizedCaseInsensitiveContains(fixture.contains)
                    && !fixture.excludes.contains(where: { result.text.localizedCaseInsensitiveContains($0) })
                if !pass { failures += 1 }
                print("[LearningAudio] \(pass ? "PASS" : "FAIL") \(URL(fileURLWithPath: fixture.path).lastPathComponent) raw=\(result.original) final=\(result.text)")
                fflush(stdout)
            }
            for (text, replace) in [
                ("Send the payment through WAP today.", true),
                ("Play the song WAP next.", false),
                ("I am listening to WAP by Cardi B.", false),
                ("Send payment through fan basis today.", true),
                ("The band has a growing fan basis around the world.", false)
            ] {
                let plan = LearningPlan.make(text: text, corrections: corrections)
                let changed = plan.confirm(verifiedText: text).text != text
                if changed != replace { failures += 1 }
                print("[LearningContext] \(changed == replace ? "PASS" : "FAIL") replace=\(changed) \(text)")
                fflush(stdout)
            }
        } catch { print("[LearningAudio] ERROR \(error)"); return 1 }
        print("[LearningAudio] failures=\(failures)")
        return failures
    }
}
#endif
