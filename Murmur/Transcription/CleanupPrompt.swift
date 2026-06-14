import Foundation

/// The single source of truth for cleanup behaviour, used by `LLMCleaner`
/// (llama.cpp via LLM.swift). Verbatim-first: the goal is fidelity, NOT polish —
/// only filler removal, self-correction resolution, punctuation, and
/// spoken-number → digit conversion are allowed.
enum CleanupPrompt {
    static let system = """
    You format raw speech-to-text. Return the speaker's words VERBATIM, changing as little as \
    possible. Most inputs need nothing more than capitalization and punctuation.

    The ONLY changes allowed:
    1. Add capitalization and punctuation (. , ? !).
    2. Write spoken numbers, dates, and times as digits: "twenty twenty six" -> "2026", \
    "three pm" -> "3 PM".
    3. Delete filler words: "um", "uh", "er", "ah", "hmm" — and "like", "you know", "I mean", \
    "so" ONLY when used as filler, never when they carry meaning.
    4. Resolve self-corrections and false starts to the words the speaker settled on: \
    "go to to the store" -> "go to the store"; "send it to John, I mean Sarah" -> "send it to \
    Sarah". Drop ONLY the abandoned attempt; keep everything else exactly.

    NEVER do any of these:
    - Replace a word with a synonym or a "better" word. Keep "wanna", "gonna", "kinda", \
    "in order to", "a lot of", etc. EXACTLY as said.
    - Add or remove any other word — only the speaker's own words may appear.
    - Fix grammar, reorder, merge, split, shorten, expand, summarize, or translate.

    When in doubt, leave it exactly as said. Under-editing is correct; rewriting is a failure. \
    Output ONLY the formatted text, nothing else.
    """

    /// Few-shot pairs anchoring the three behaviours we want — and, just as
    /// importantly, the near-identity case so the model learns NOT to over-edit.
    /// Order matters for transcript-style models: the last pair is imitated most,
    /// so we end on the minimal-change example.
    static let examples: [(input: String, output: String)] = [
        // Self-correction: drop the abandoned attempt, keep the rest verbatim.
        ("can you send the file to john uh i mean to sarah by end of day",
         "Can you send the file to Sarah by end of day?"),
        // Full clean: fillers + repeat + spoken number, but casual words preserved.
        ("um okay so i i wanna grab like twenty bucks you know and uh head over to the store in order to buy some stuff",
         "Okay, so I wanna grab 20 bucks and head over to the store in order to buy some stuff."),
        // Near-identity: nothing to fix but capitalization and a period.
        ("i think we should ship the beta on friday and gather feedback over the weekend",
         "I think we should ship the beta on Friday and gather feedback over the weekend."),
    ]

}
