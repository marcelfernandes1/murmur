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

/// A swappable speech-to-text backend (local WhisperKit / whisper.cpp /
/// Parakeet, or a cloud engine).
protocol SpeechEngine: Sendable {
    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) async
    func preload() async
    /// Sample rate this engine wants its audio in. The recorder captures at this
    /// rate directly rather than resampling afterwards — the microphone runs at
    /// 48 kHz, so going 48→16→24 would band-limit the audio to 8 kHz and no later
    /// resample can recover the missing band.
    nonisolated var inputSampleRate: Int { get }
    /// - Parameters:
    ///   - language: ISO code to force, or nil to auto-detect (engines may ignore).
    ///   - vocabulary: custom terms to bias toward (engines may ignore).
    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String
}

extension SpeechEngine {
    /// What every local Whisper-family model expects.
    nonisolated var inputSampleRate: Int { 16_000 }
    /// Called when recording starts. Cloud engines use it to get the TLS
    /// handshake out of the way while the user is still talking, instead of
    /// paying for it after they stop. No-op for local engines.
    func warmUp() async {}
}

/// An engine that transcribes *while* the user is still speaking, so the text is
/// ready the moment they release the trigger. The controller pumps audio in as
/// it is captured and asks for the final transcript at commit.
protocol LiveSpeechEngine: SpeechEngine {
    /// Called with the transcript-so-far every time the server sends more of it,
    /// so the UI can show the words appearing while the user is still speaking.
    /// Without this the streaming is invisible: the text is being produced live
    /// on the wire but the user sees nothing until they release the trigger.
    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async
    func beginLive(language: String?, vocabulary: [String]) async
    /// Newly captured samples, in order, at `inputSampleRate`.
    func appendLive(_ samples: [Float]) async
    /// Flush, wait for the last transcript, and tear the session down.
    func finishLive() async throws -> String
    func cancelLive() async
}
