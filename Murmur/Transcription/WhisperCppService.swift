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

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let model = try await loadModel()
        // Synchronous inside the actor: serializes calls (whisper_full is not
        // reentrant on a shared context) and never touches the main thread.
        return try decode(samples, model: model, language: language, vocabulary: vocabulary)
    }

    /// Decode the take, then verify the decode actually covered it. Any
    /// speech-bearing stretch whisper.cpp skipped is decoded again on its own and
    /// spliced back in time order, so a bailed-out window costs a re-decode
    /// instead of the rest of the dictation.
    private func decode(_ samples: [Float],
                        model: WhisperModel,
                        language: String?,
                        vocabulary: [String]) throws -> String {
        guard var segments = model.transcribe(samples: samples, language: language, vocabulary: vocabulary) else {
            throw WhisperCppError.inferenceFailed
        }

        let reference = DecodeCoverage.speechReferenceLevel(samples)
        var passes = 0
        while passes < Self.maxRecoveryPasses,
              let gap = DecodeCoverage.firstRecoverableGap(in: segments, samples: samples,
                                                           reference: reference) {
            passes += 1
            let recovered = model.transcribe(samples: Array(samples[gap.start..<gap.end]),
                                             language: language, vocabulary: vocabulary) ?? []
            let from = Double(gap.start) / Double(Self.sampleRate)
            let to = Double(gap.end) / Double(Self.sampleRate)
            // Logged at every occurrence: this firing means whisper.cpp dropped
            // speech, so it's the trail to follow if the bug ever resurfaces.
            Self.log.warning("coverage gap \(from, privacy: .public)s–\(to, privacy: .public)s was not transcribed → re-decoded, recovered \(recovered.count, privacy: .public) segments")
            #if DEBUG
            Self.fileLog("WHISPER_CPP recovered gap \(gap.start)–\(gap.end) segments=\(recovered.count)")
            #endif
            // Nothing came back for a stretch we believed held speech — stop
            // rather than re-decoding the same silence up to the pass cap.
            guard !recovered.isEmpty else { break }
            let offset = Double(gap.start) / Double(Self.sampleRate)
            segments.append(contentsOf: recovered.map {
                WhisperSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            })
            segments.sort { $0.start < $1.start }
        }

        // whisper keeps decoding past the last word and invents a closing over the
        // trailing silence ("Thank you."). Drop anything at the end that has no
        // speech under it, after recovery so a real dropped tail is back first.
        let trimmed = DecodeCoverage.trimmingFabricatedTail(segments, samples: samples, reference: reference)
        if trimmed.count < segments.count {
            Self.log.log("dropped \(segments.count - trimmed.count, privacy: .public) fabricated trailing segment(s) sitting on silence")
        }

        let text = trimmed.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        return TranscriptCleaner.removeDegenerateRepeats(text)
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
            // Trust the cache only if its size still matches the pin (instant check);
            // a truncated/corrupt cache is removed and re-downloaded.
            if ModelManifest.sizeMatches(fileName: fileName, at: dest) { return dest }
            try? FileManager.default.removeItem(at: dest)
        }

        guard let remote = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)?download=true") else {
            throw WhisperCppError.modelLoadFailed
        }
        notify?(.downloading(0))
        let downloader = ModelDownloader { fraction in notify?(.downloading(fraction)) }
        let url = try await downloader.download(from: remote, to: dest)
        // Verify SHA-256 against the build-pinned hash before the C parser ever sees
        // the file. On mismatch, delete it so a poisoned/corrupt file can't persist.
        do {
            try ModelManifest.verify(fileName: fileName, at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
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
