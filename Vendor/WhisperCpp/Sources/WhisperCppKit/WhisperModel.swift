import Foundation
import whisper

/// A loaded whisper.cpp model. Owns a `whisper_context` and runs Metal-accelerated
/// inference. This is the ONLY place `import whisper` appears in the build — the
/// public API exposes only Swift types so the raw ggml C headers never reach the
/// app target (where they'd clash with LLM.swift's bundled llama/ggml). See
/// Package.swift for the full rationale.
///
/// `@unchecked Sendable`: the context is not reentrant, but callers serialize all
/// access (Murmur's `WhisperCppService` actor runs one transcription at a time).
public final class WhisperModel: @unchecked Sendable {
    private let ctx: OpaquePointer

    /// Silence whisper.cpp/ggml's verbose stderr logging once per process. A
    /// non-capturing closure bridges to the C `ggml_log_callback` pointer.
    private static let quiet: Void = {
        whisper_log_set({ _, _, _ in }, nil)
    }()

    /// Load a ggml model file. Returns nil if the file is missing/unreadable.
    public init?(path: String) {
        _ = Self.quiet
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true   // Metal; the XCFramework ships the backend compiled in.
        guard let ctx = path.withCString({ whisper_init_from_file_with_params($0, cparams) }) else {
            return nil
        }
        self.ctx = ctx
    }

    /// Transcribe 16 kHz mono float samples. `language` nil = auto-detect;
    /// `vocabulary` biases decoding toward custom terms via the initial prompt.
    /// Returns nil on inference failure. Synchronous and blocking — call off the
    /// main thread and serialized (see class note).
    public func transcribe(samples: [Float], language: String?, vocabulary: [String]) -> String? {
        guard !samples.isEmpty else { return "" }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.no_timestamps = true        // whisper_full does its own 30s windowing
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.single_segment = false
        params.suppress_blank = true

        // Anti-hallucination / anti-repetition hardening. Long dictations were looping
        // (a phrase repeated many times) and dropping tail words — the classic
        // whisper.cpp degenerate-decoding failure. Two guards fix it:
        //
        //   1. no_context: transcribe each internal 30 s window independently. By
        //      default whisper.cpp seeds each window with the *previous* window's
        //      tokens as a prompt; once a repeat starts it feeds itself and snowballs
        //      across the rest of the take. Dropping the carry-over keeps a hiccup in
        //      one window from poisoning everything after it. (No effect on takes that
        //      fit in a single window — i.e. most dictations — so it's strictly safer.)
        //
        //   2. Temperature fallback: if a window decodes with suspiciously low entropy
        //      (a repetition loop) or low average log-prob (garbage), re-decode it
        //      hotter (0.0 → 0.2 → … → 1.0) so the model jumps out of the loop instead
        //      of emitting it. These are whisper.cpp's own recommended thresholds, set
        //      explicitly so a future change to the library defaults can't silently
        //      disable the safety net.
        params.no_context = true
        params.temperature = 0.0
        params.temperature_inc = 0.2
        params.entropy_thold = 2.4
        params.logprob_thold = -1.0
        params.no_speech_thold = 0.6
        params.suppress_nst = true         // drop non-speech tokens (annotation artifacts)

        // Hold C strings alive across the whole `whisper_full` call (the params
        // struct just borrows the pointers). `strdup` copies are freed on exit.
        //
        // For auto-detect pass the "auto" sentinel — NOT `detect_language = true`.
        // In whisper_full, `detect_language = true` runs language detection and then
        // RETURNS EARLY WITHOUT TRANSCRIBING (it's the `--detect-language` CLI flag's
        // behavior), producing an empty transcript. Passing "auto" (or any ISO code)
        // with detect_language = false makes it auto-detect *and* transcribe.
        let langC = strdup(language ?? "auto")
        let promptC = vocabulary.isEmpty ? nil : strdup(" " + vocabulary.joined(separator: ", "))
        defer { langC.map { free($0) }; promptC.map { free($0) } }

        if let langC { params.language = UnsafePointer(langC) }
        params.detect_language = false
        if let promptC { params.initial_prompt = UnsafePointer(promptC) }

        let status = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard status == 0 else { return nil }

        var transcript = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                transcript += String(cString: cstr)
            }
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit { whisper_free(ctx) }
}
