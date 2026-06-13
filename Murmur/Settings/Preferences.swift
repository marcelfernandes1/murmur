import Foundation
import Observation
import ServiceManagement

/// User-facing settings, persisted to UserDefaults.
@MainActor
@Observable
final class Preferences {
    enum ModelChoice: String, CaseIterable, Identifiable {
        case parakeet
        case tiny
        case base
        case small
        case turbo = "large-v3_turbo_954MB"
        case distilTurbo = "distil-large-v3_turbo_600MB"
        case turboFull = "large-v3_turbo"

        enum Engine { case whisper, parakeet }

        var id: String { rawValue }
        var engine: Engine { self == .parakeet ? .parakeet : .whisper }
        /// WhisperKit model name (unused for Parakeet).
        var whisperKitName: String { rawValue }
        var isEnglishOnly: Bool { self == .distilTurbo }

        var displayName: String {
            switch self {
            case .parakeet: return "Parakeet TDT 0.6B v3 — fastest, multilingual (~600 MB)"
            case .tiny: return "Whisper Tiny — fastest Whisper, basic accuracy (~75 MB)"
            case .base: return "Whisper Base — fast (~145 MB)"
            case .small: return "Whisper Small — balanced, multilingual (~480 MB)"
            case .turbo: return "Whisper Large v3 Turbo — accurate, multilingual (~950 MB)"
            case .distilTurbo: return "Whisper Distil Turbo — fast, English only (~600 MB)"
            case .turboFull: return "Whisper Large v3 Turbo (full) — max accuracy, slow load (~3 GB)"
            }
        }
    }

    /// Local LLM used for the optional "smart cleanup" pass.
    enum CleanupModel: String, CaseIterable, Identifiable {
        case qwen3B
        case qwen1_5B

        var id: String { rawValue }
        var repo: String {
            switch self {
            case .qwen3B: return "bartowski/Qwen2.5-3B-Instruct-GGUF"
            case .qwen1_5B: return "bartowski/Qwen2.5-1.5B-Instruct-GGUF"
            }
        }
        var fileName: String {
            switch self {
            case .qwen3B: return "Qwen2.5-3B-Instruct-Q4_K_M.gguf"
            case .qwen1_5B: return "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
            }
        }
        var displayName: String {
            switch self {
            case .qwen3B: return "Qwen2.5 3B — best cleanup (~2 GB)"
            case .qwen1_5B: return "Qwen2.5 1.5B — fastest (~1 GB)"
            }
        }
    }

    /// Spoken language. `auto` lets Whisper detect it per utterance.
    enum Language: String, CaseIterable, Identifiable {
        case auto, en, pt, es, fr, de, it, nl, zh, ja, ko, ru

        var id: String { rawValue }
        /// nil for auto-detect; otherwise the ISO code Whisper expects.
        var code: String? { self == .auto ? nil : rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto-detect (any language)"
            case .en: return "English"
            case .pt: return "Portuguese"
            case .es: return "Spanish"
            case .fr: return "French"
            case .de: return "German"
            case .it: return "Italian"
            case .nl: return "Dutch"
            case .zh: return "Chinese"
            case .ja: return "Japanese"
            case .ko: return "Korean"
            case .ru: return "Russian"
            }
        }
    }

    var model: ModelChoice {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }

    var language: Language {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    /// Use the Fn / 🌐 key as a trigger (in addition to any custom shortcuts).
    var fnTriggerEnabled: Bool {
        didSet { defaults.set(fnTriggerEnabled, forKey: Keys.fnTrigger) }
    }

    /// Transcribe live while recording (shows a preview in the notch).
    var streaming: Bool {
        didSet { defaults.set(streaming, forKey: Keys.streaming) }
    }

    /// Strip filler words (um, uh, erm…) from the final transcript.
    var removeFillers: Bool {
        didSet { defaults.set(removeFillers, forKey: Keys.removeFillers) }
    }

    /// Run a local LLM pass to remove fillers + false starts, format numbers, and
    /// fix punctuation (Wispr-style). Supersedes the simple filler removal.
    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Keys.smartCleanup) }
    }

    var cleanupModel: CleanupModel {
        didSet { defaults.set(cleanupModel.rawValue, forKey: Keys.cleanupModel) }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            try? (launchAtLogin ? SMAppService.mainApp.register()
                                : SMAppService.mainApp.unregister())
        }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults

        model = ModelChoice(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .turbo

        language = Language(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .auto
        fnTriggerEnabled = defaults.object(forKey: Keys.fnTrigger) == nil
            ? true
            : defaults.bool(forKey: Keys.fnTrigger)
        streaming = defaults.bool(forKey: Keys.streaming)
        removeFillers = defaults.object(forKey: Keys.removeFillers) == nil
            ? true
            : defaults.bool(forKey: Keys.removeFillers)
        smartCleanup = defaults.bool(forKey: Keys.smartCleanup)
        cleanupModel = CleanupModel(rawValue: defaults.string(forKey: Keys.cleanupModel) ?? "") ?? .qwen3B
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let model = "whisperModel"
        static let language = "language"
        static let fnTrigger = "fnTriggerEnabled"
        static let streaming = "streamingEnabled"
        static let removeFillers = "removeFillers"
        static let smartCleanup = "smartCleanup"
        static let cleanupModel = "cleanupModel"
        static let onboarded = "hasCompletedOnboarding"
        static let migratedTurboV2 = "migratedToTurboV2"
    }
}
