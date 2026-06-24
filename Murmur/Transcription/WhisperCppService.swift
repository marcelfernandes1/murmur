import Foundation
import WhisperCppKit

/// whisper.cpp-backed engine (Metal-accelerated via the official XCFramework,
/// wrapped by the WhisperCppKit package). Loads a ggml model file once —
/// downloading it from Hugging Face on first use — and reuses the context. Added
/// so we can A/B every ggml model variant (sizes × quantizations × English-only)
/// against the WhisperKit/Parakeet engines to find the best speed/accuracy ratio.
///
/// Unlike WhisperService (WhisperKit), whisper.cpp's `whisper_full` does its own
/// internal 30 s windowing, so long audio transcribes correctly without us having
/// to juggle timestamps — no "it cut off what I said past 30 s" caveat here.
actor WhisperCppService: SpeechEngine {
    /// ggml weights filename, e.g. `ggml-large-v3-turbo-q5_0.bin`.
    private let fileName: String
    private var model: WhisperModel?
    private var loadTask: Task<WhisperModel, Error>?
    private var stateHandler: (@Sendable (EngineLoadState) -> Void)?

    /// All ggml models live in this one Hugging Face repo.
    private static let repo = "ggerganov/whisper.cpp"

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
        guard let text = model.transcribe(samples: samples, language: language, vocabulary: vocabulary) else {
            throw WhisperCppError.inferenceFailed
        }
        return text
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
