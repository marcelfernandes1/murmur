import Foundation

/// Model load lifecycle, surfaced so the UI never looks frozen.
enum EngineLoadState: Sendable, Equatable {
    case preparing
    /// Fraction (0…1) of a model download completed. Emitted by engines that
    /// fetch large weights on demand (whisper.cpp's ggml files run 75 MB–3 GB),
    /// so a multi-minute download shows progress instead of a frozen "Preparing".
    case downloading(Double)
    case ready
    case failed(String)
}

/// A swappable speech-to-text backend (WhisperKit or Parakeet/FluidAudio).
protocol SpeechEngine: Sendable {
    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) async
    func preload() async
    /// - Parameters:
    ///   - language: ISO code to force, or nil to auto-detect (engines may ignore).
    ///   - vocabulary: custom terms to bias toward (engines may ignore).
    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String
}
