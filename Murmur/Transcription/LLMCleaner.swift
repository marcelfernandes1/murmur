import Foundation
import LLM
import OSLog

/// Wispr-style post-transcription cleanup with a local LLM (llama.cpp / Metal,
/// via LLM.swift). Removes fillers + false starts, converts spoken numbers to
/// digits, and fixes punctuation — fully offline. Stateless: each call builds a
/// fresh ChatML prompt (no growing history).
actor LLMCleaner: TextCleaner {
    private static let log = Logger(subsystem: "com.murmur.app", category: "cleanup")
    private let repo: String
    private let fileName: String
    private var llm: LLM?
    private var loadTask: Task<LLM, Error>?
    private var stateHandler: (@Sendable (EngineLoadState) -> Void)?

    init(repo: String, fileName: String) {
        self.repo = repo
        self.fileName = fileName
    }

    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) {
        stateHandler = handler
    }

    func preload() async {
        _ = try? await load()
    }

    /// Context budget shared by the system prompt, the few-shot examples, the
    /// transcript AND the generated output. `maxTokenCount` below is 4096; the
    /// prompt scaffolding costs roughly 500, and the output is about as long as
    /// the input, so anything past this simply cannot round-trip.
    private static let maxTranscriptCharacters = 6_000

    /// Returns the cleaned text, or the original on any failure (never blocks delivery).
    func clean(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Too long to fit the context. The model does not error on overrun — it
        // stops generating mid-sentence and returns the partial text, which is a
        // valid subsequence of the original and used to sail through CleanupGuard.
        // Skipping cleanup loses some polish; truncating loses the user's words.
        guard trimmed.count <= Self.maxTranscriptCharacters else {
            Self.log.log("skipping cleanup: \(trimmed.count, privacy: .public) chars exceeds the model's context budget")
            return trimmed
        }
        guard let llm = try? await load() else { return text }

        // Defense-in-depth: strip ChatML control tokens from the transcript before
        // interpolating it into the template. Whisper never emits these from speech,
        // but a future input path (pasted text, a different ASR) mustn't be able to
        // forge a system/assistant turn and hijack the cleanup instructions.
        let safe = Self.stripChatML(trimmed)
        var prompt = "<|im_start|>system\n\(CleanupPrompt.system)<|im_end|>\n"
        for example in CleanupPrompt.examples {
            prompt += "<|im_start|>user\n\(example.input)<|im_end|>\n"
            prompt += "<|im_start|>assistant\n\(example.output)<|im_end|>\n"
        }
        prompt += "<|im_start|>user\n\(safe)<|im_end|>\n<|im_start|>assistant\n"

        let raw = await llm.getCompletion(from: prompt)
        // LLM.swift's getCompletion does NOT clear the context afterwards, so the
        // KV cache would otherwise accumulate every dictation — making each call
        // slower, conditioning the model on its own prior "cleaned" outputs (which
        // pushes it to over-polish), and eventually silently no-op'ing once the
        // context fills. Reset so the next cleanup starts fresh and stateless. The
        // gap before the next dictation guarantees this completes in time.
        llm.reset()
        let cleaned = Self.tidy(raw)
        return cleaned.isEmpty ? trimmed : cleaned
    }

    private func load() async throws -> LLM {
        if let llm { return llm }
        if let loadTask { return try await loadTask.value }
        let repo = repo
        let fileName = fileName
        let notify = stateHandler
        let task = Task { () throws -> LLM in
            notify?(.preparing)
            let dest = try await Self.downloadIfNeeded(repo: repo, fileName: fileName)
            // Greedy decoding (topK 1) so it follows instructions literally instead
            // of "creatively" rewriting the transcript.
            guard let llm = LLM(from: dest, template: .chatML(), topK: 1, temp: 0.0, maxTokenCount: 4096) else {
                throw CleanerError.modelLoadFailed
            }
            notify?(.ready)
            return llm
        }
        loadTask = task
        do {
            let llm = try await task.value
            self.llm = llm
            return llm
        } catch {
            loadTask = nil
            notify?(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Download the GGUF straight from Hugging Face's resolve endpoint (robust,
    /// unlike LLM.swift's HTML scraping) into Application Support.
    private static func downloadIfNeeded(repo: String, fileName: String) async throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            if (try? ModelManifest.verify(fileName: fileName, at: dest)) != nil { return dest }
            try? FileManager.default.removeItem(at: dest)
        }

        guard let remote = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)?download=true") else {
            throw CleanerError.modelLoadFailed
        }
        let (tmp, response) = try await URLSession.shared.download(from: remote)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CleanerError.downloadFailed
        }
        // Verify BEFORE the file reaches its real name, so an interrupted verify
        // can never strand unverified weights at the path the cache trusts.
        let staging = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.moveItem(at: tmp, to: staging)
        do {
            try ModelManifest.verify(fileName: fileName, at: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: dest)
        }
        return dest
    }

    /// ChatML control tokens that must never survive into (or out of) user text.
    private static let chatMLTokens = ["<|im_start|>", "<|im_end|>"]
    private static func stripChatML(_ s: String) -> String {
        chatMLTokens.reduce(s) { $0.replacingOccurrences(of: $1, with: "") }
    }

    private static func tidy(_ raw: String) -> String {
        // Strip the full set of control tokens (not just <|im_end|>) so a stray
        // <|im_start|> can't be pasted into the user's document.
        var text = stripChatML(raw)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CleanerError: Error { case modelLoadFailed, downloadFailed }
}
