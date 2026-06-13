import Foundation

/// Model load lifecycle, surfaced so the UI never looks frozen.
enum EngineLoadState: Sendable, Equatable {
    case preparing
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
