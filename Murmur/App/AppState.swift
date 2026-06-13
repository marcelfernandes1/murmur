import Foundation
import Observation

/// Central app state. For Phase 0 this is intentionally tiny; later phases hang
/// the recorder, transcriber, hotkey manager, notch controller, and history
/// store off of it.
@Observable
final class AppState {
    /// High-level lifecycle of a dictation, surfaced to the UI / notch.
    enum Status: Equatable {
        case idle
        case listening
        case transcribing
        case error(String)
    }

    /// Model download/load lifecycle, surfaced so the UI never looks frozen.
    enum ModelPhase: Equatable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    var status: Status = .idle
    var modelPhase: ModelPhase = .idle
    /// Load state of the optional smart-cleanup LLM.
    var cleanupPhase: ModelPhase = .idle

    /// Human-readable description of the active dictation shortcut.
    var shortcutHint: String = ""

    /// Whether Accessibility is granted (needed to type into the focused app).
    var accessibilityEnabled: Bool = false

    /// Whether Microphone access is granted.
    var micEnabled: Bool = false

    /// The most recent transcript (shown in the menu for quick confirmation in
    /// Phase 1; the History view supersedes this in Phase 3).
    var lastTranscript: String = ""

    var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return "v\(short)"
    }
}
