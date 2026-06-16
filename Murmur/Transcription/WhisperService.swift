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
        //
        // BUT: WhisperKit decodes in 30s windows and relies on segment timestamps
        // to seek to the next window. With `withoutTimestamps = true` it can't
        // advance past the first window, so audio longer than ~30s gets truncated
        // (the "it cut off what I said" bug). So we only take the fast no-timestamps
        // path for short clips; longer audio keeps timestamps for correct long-form.
        let longAudio = samples.count > 28 * 16_000   // ~28s of 16 kHz mono
        options.withoutTimestamps = !longAudio
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
        let transcript = results
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // TEMP DIAGNOSTIC — confirm long audio isn't being truncated.
        let line = "WHISPER in=\(samples.count) (\(samples.count / 16_000)s) timestamps=\(longAudio ? "on" : "off") segments=\(results.count) outChars=\(transcript.count)\n"
        let url = URL(fileURLWithPath: "/tmp/murmur_audio.log")
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: url) }
        }

        return transcript
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
            // Run the encoder + autoregressive decoder on the Neural Engine.
            // Measured on M4 Max / large-v3-turbo: ANE decode is ~3x faster than
            // the GPU (RTF 0.21 vs 0.68) — the decoder runs one forward pass per
            // token and the ANE's low per-call latency crushes the GPU's dispatch
            // overhead on that serial workload. Mel stays on the GPU (a parallel
            // matmul it's well suited for); prefill stays on CPU (tiny).
            //
            // The cold ANE "specialization" the GPU path was avoiding is a
            // one-time, OS-cached cost — and `load: true` below forces it to
            // happen here, during the visible "Preparing model…" phase, never on
            // the transcribe path (the old "hung on Transcribing…" symptom).
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
                prefillCompute: .cpuOnly
            )
            // `load: true` forces the model to fully load here, during the
            // "Preparing model…" phase, so `.ready` is truthful. Without it
            // WhisperKit only downloads and defers the heavy load into the first
            // transcribe, where it looks like an endless transcription.
            let config = WhisperKitConfig(model: name, computeOptions: compute, load: true)
            let kit = try await WhisperKit(config)
            notify?(.ready)
            return kit
        }
        loadTask = task
        return task
    }
}
