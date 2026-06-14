import Foundation

/// A swappable post-transcription cleanup backend. Implementation: `LLMCleaner`
/// (llama.cpp / Metal). Stateless per call.
protocol TextCleaner: Sendable {
    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) async
    func preload() async
    /// Returns the cleaned text, or the original on any failure (never blocks delivery).
    func clean(_ text: String) async -> String
}
