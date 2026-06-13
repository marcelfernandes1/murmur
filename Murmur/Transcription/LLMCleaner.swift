import Foundation
import LLM

/// Wispr-style post-transcription cleanup with a local LLM (llama.cpp / Metal,
/// via LLM.swift). Removes fillers + false starts, converts spoken numbers to
/// digits, and fixes punctuation — fully offline. Stateless: each call builds a
/// fresh ChatML prompt (no growing history).
actor LLMCleaner {
    static let systemPrompt = """
    You clean up raw speech-to-text dictation into polished written text.
    Output ONLY the cleaned text — no preamble, quotes, labels, or explanation.
    Rules:
    - Remove filler words (um, uh, er, ah, hmm).
    - Remove false starts and self-corrections, keeping the speaker's intended final phrasing.
    - Convert spoken numbers, dates, and times to digits (e.g. "twenty twenty six" -> "2026").
    - Add natural punctuation and capitalization.
    - Do NOT add, remove, summarize, translate, or change the meaning.
    - Preserve the original language.
    """

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
            guard let llm = LLM(from: dest, template: .chatML(), temp: 0.3, maxTokenCount: 4096) else {
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
