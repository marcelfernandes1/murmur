import Foundation
import FluidAudio

/// Parakeet TDT 0.6B v3 via FluidAudio (CoreML / ANE). Non-autoregressive, so
/// it's far faster than Whisper on long utterances. Multilingual (incl.
/// Portuguese). Ignores the forced-language and custom-vocabulary hints.
actor ParakeetService: SpeechEngine {
    private var loadTask: Task<AsrManager, Error>?
    private var stateHandler: (@Sendable (EngineLoadState) -> Void)?

    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) {
        stateHandler = handler
    }

    func preload() async {
        _ = try? await loadManager()
    }

    /// True while the committed take is being decoded. Actors are reentrant
    /// across `await`, so without this a streaming preview pass could enter the
    /// actor mid-decode and use the shared AsrManager concurrently — the preview
    /// is disposable, the final result is not.
    private var decodingFinal = false

    /// Preview pass for the live notch. Skipped outright if the real decode is
    /// running; a dropped preview frame costs nothing.
    func transcribePreview(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        guard !decodingFinal else { return "" }
        return try await transcribe(samples, language: language, vocabulary: vocabulary)
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        decodingFinal = true
        defer { decodingFinal = false }
        let manager = try await loadManager()
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadManager() async throws -> AsrManager {
        if let loadTask { return try await loadTask.value }
        let notify = stateHandler
        let task = Task { () throws -> AsrManager in
            notify?(.preparing)
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager()
            try await manager.loadModels(models)
            notify?(.ready)
            return manager
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil
            notify?(.failed(error.localizedDescription))
            throw error
        }
    }
}
