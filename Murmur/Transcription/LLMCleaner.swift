import Foundation
import LLM

/// Wispr-style post-transcription cleanup with a local LLM (llama.cpp / Metal,
/// via LLM.swift). Removes fillers + false starts, converts spoken numbers to
/// digits, and fixes punctuation — fully offline. Stateless: each call builds a
/// fresh ChatML prompt (no growing history).
actor LLMCleaner {
    static let systemPrompt = """
    You are a strict transcription cleaner. You are given raw speech-to-text and must \
    return the SAME text with only minimal, mechanical fixes. Preserve the speaker's EXACT words.

    ONLY these edits are allowed:
    1. Delete filler words / verbal tics: "um", "uh", "er", "ah", "hmm", "you know", "I mean", \
    and "like"/"so" only when used as filler.
    2. Delete false starts and accidental repeats, e.g. "I I want" -> "I want", \
    "go to to the store" -> "go to the store". Keep the words the speaker ended up using.
    3. Fix capitalization and add punctuation (. , ? !).
    4. Write spoken numbers, dates, and times as digits, e.g. "twenty twenty six" -> "2026".

    You are FORBIDDEN from:
    - Rewording or replacing ANY word with a synonym. Keep "in order to", "wanna", "gonna", \
    "kinda", etc. EXACTLY as said.
    - Adding ANY word the speaker did not say (never add words like "feature", "intend", \
    "since", "however", "performs").
    - Reordering, restructuring, merging, or splitting the speaker's ideas beyond adding punctuation.
    - Summarizing, shortening, expanding, or translating.

    If in doubt, leave it unchanged. Under-editing is correct; rewriting is a failure. \
    Output ONLY the cleaned text, nothing else.
    """

    /// One-shot example to anchor minimal-edit behaviour.
    private static let exampleInput =
        "um okay so i i wanna grab like twenty bucks you know and uh head over to the store in order to buy some stuff"
    private static let exampleOutput =
        "Okay, so I wanna grab 20 bucks and head over to the store in order to buy some stuff."

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

    /// Returns the cleaned text, or the original on any failure (never blocks delivery).
    func clean(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard let llm = try? await load() else { return text }

        let prompt = """
        <|im_start|>system
        \(Self.systemPrompt)<|im_end|>
        <|im_start|>user
        \(Self.exampleInput)<|im_end|>
        <|im_start|>assistant
        \(Self.exampleOutput)<|im_end|>
        <|im_start|>user
        \(trimmed)<|im_end|>
        <|im_start|>assistant

        """
        let raw = await llm.getCompletion(from: prompt)
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
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        guard let remote = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)?download=true") else {
            throw CleanerError.modelLoadFailed
        }
        let (tmp, response) = try await URLSession.shared.download(from: remote)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CleanerError.downloadFailed
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private static func tidy(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<|im_end|>", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CleanerError: Error { case modelLoadFailed, downloadFailed }
}
