import Foundation
import WhisperKit

/// WhisperKit-backed engine. The model loads once (downloaded on first use) and
/// is reused. Load lifecycle is reported via `setStateHandler`.
actor WhisperService: SpeechEngine {
    private let modelName: String
    private var loadTask: Task<WhisperKit, Error>?
    private var stateHandler: (@Sendable (EngineLoadState) -> Void)?

    init(modelName: String) {
        self.modelName = modelName
    }

    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) {
        stateHandler = handler
    }

    func preload() async {
        _ = try? await loadPipe()
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let pipe = try await loadPipe()

        var options = DecodingOptions()
        // Speed: timestamps ~double decode steps, and capping fallbacks avoids
        // re-decoding borderline segments up to 5×.
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.temperatureFallbackCount = 1
        if let language {
            options.language = language
            options.detectLanguage = false
        } else {
            options.language = nil
            options.detectLanguage = true
        }

        if !vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            let promptText = " " + vocabulary.joined(separator: ", ")
            let specialBegin = tokenizer.specialTokens.specialTokenBegin
            options.usePrefillPrompt = true
            options.promptTokens = tokenizer.encode(text: promptText).filter { $0 < specialBegin }
        }

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadPipe() async throws -> WhisperKit {
        do {
            return try await pipeTask().value
        } catch {
            loadTask = nil
            stateHandler?(.failed(error.localizedDescription))
            throw error
        }
    }

    private func pipeTask() -> Task<WhisperKit, Error> {
        if let loadTask { return loadTask }
        let name = modelName
        let notify = stateHandler
        let task = Task { () throws -> WhisperKit in
            notify?(.preparing)
            let kit = try await WhisperKit(WhisperKitConfig(model: name))
            notify?(.ready)
            return kit
        }
        loadTask = task
        return task
    }
}
