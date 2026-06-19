import Foundation
import Observation
import ServiceManagement

/// User-facing settings, persisted to UserDefaults.
@MainActor
@Observable
final class Preferences {
    enum ModelChoice: String, CaseIterable, Identifiable {
        // WhisperKit (Core ML / ANE) and Parakeet (FluidAudio) — the original engines.
        case parakeet
        case base
        case small
        case turbo = "large-v3_turbo_954MB"

        // whisper.cpp (Metal) — the full ggml matrix for speed/accuracy testing.
        // rawValue is the exact ggml filename stem; the `.bin` is at
        // huggingface.co/ggerganov/whisper.cpp. `.en` = English-only (more accurate
        // per size); Q5/Q8 = quantized (smaller + faster, slight accuracy cost).
        case cppTiny = "ggml-tiny"
        case cppTinyEn = "ggml-tiny.en"
        case cppBase = "ggml-base"
        case cppBaseEn = "ggml-base.en"
        case cppSmall = "ggml-small"
        case cppSmallEn = "ggml-small.en"
        case cppSmallQ5 = "ggml-small-q5_1"
        case cppMedium = "ggml-medium"
        case cppMediumEn = "ggml-medium.en"
        case cppMediumQ5 = "ggml-medium-q5_0"
        case cppMediumEnQ5 = "ggml-medium.en-q5_0"
        case cppLargeV2 = "ggml-large-v2"
        case cppLargeV2Q5 = "ggml-large-v2-q5_0"
        case cppLargeV3 = "ggml-large-v3"
        case cppLargeV3Q5 = "ggml-large-v3-q5_0"
        case cppLargeV3Turbo = "ggml-large-v3-turbo"
        case cppLargeV3TurboQ5 = "ggml-large-v3-turbo-q5_0"
        case cppLargeV3TurboQ8 = "ggml-large-v3-turbo-q8_0"

        enum Engine { case whisper, parakeet, whisperCpp }

        var id: String { rawValue }

        var engine: Engine {
            if self == .parakeet { return .parakeet }
            if rawValue.hasPrefix("ggml-") { return .whisperCpp }
            return .whisper
        }

        /// WhisperKit model name (only meaningful for the `.whisper` engine).
        var whisperKitName: String { rawValue }

        /// ggml weights filename (only meaningful for the `.whisperCpp` engine).
        var ggmlFileName: String { rawValue + ".bin" }

        var displayName: String {
            switch self {
            case .parakeet: return "Parakeet TDT 0.6B v3 — fastest, multilingual (~600 MB)"
            case .base: return "Whisper Base (Core ML) — fast (~145 MB)"
            case .small: return "Whisper Small (Core ML) — balanced, multilingual (~480 MB)"
            case .turbo: return "Whisper Large v3 Turbo (Core ML) — accurate, multilingual (~950 MB)"
            case .cppTiny: return "whisper.cpp: Tiny — fastest, least accurate (78 MB)"
            case .cppTinyEn: return "whisper.cpp: Tiny (English) — fastest (78 MB)"
            case .cppBase: return "whisper.cpp: Base — fast (148 MB)"
            case .cppBaseEn: return "whisper.cpp: Base (English) — fast (148 MB)"
            case .cppSmall: return "whisper.cpp: Small — balanced (488 MB)"
            case .cppSmallEn: return "whisper.cpp: Small (English) — balanced (488 MB)"
            case .cppSmallQ5: return "whisper.cpp: Small Q5 — balanced, smaller (190 MB)"
            case .cppMedium: return "whisper.cpp: Medium — more accurate, slower (1.5 GB)"
            case .cppMediumEn: return "whisper.cpp: Medium (English) — more accurate (1.5 GB)"
            case .cppMediumQ5: return "whisper.cpp: Medium Q5 — accurate, smaller (539 MB)"
            case .cppMediumEnQ5: return "whisper.cpp: Medium Q5 (English) — accurate, smaller (539 MB)"
            case .cppLargeV2: return "whisper.cpp: Large v2 — very accurate, slow (3.1 GB)"
            case .cppLargeV2Q5: return "whisper.cpp: Large v2 Q5 — very accurate (1.1 GB)"
            case .cppLargeV3: return "whisper.cpp: Large v3 — most accurate, slow (3.1 GB)"
            case .cppLargeV3Q5: return "whisper.cpp: Large v3 Q5 — most accurate (1.1 GB)"
            case .cppLargeV3Turbo: return "whisper.cpp: Large v3 Turbo — accurate + faster (1.6 GB)"
            case .cppLargeV3TurboQ5: return "whisper.cpp: Large v3 Turbo Q5 — accurate, fast (574 MB)"
            case .cppLargeV3TurboQ8: return "whisper.cpp: Large v3 Turbo Q8 — accurate, fast (874 MB)"
            }
        }
    }

    /// Local LLM used for the optional "smart cleanup" pass.
    enum CleanupModel: String, CaseIterable, Identifiable {
        case qwen1_5B
        case qwen3B

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
            case .qwen1_5B: return "Qwen2.5 1.5B — fastest (~1 GB)"
            case .qwen3B: return "Qwen2.5 3B — best cleanup, slower (~2 GB)"
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

    /// UID of the chosen microphone, or nil to follow the macOS default input.
    var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
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

    /// Learn a correction when you edit a word in text Murmur just inserted
    /// (Wispr-style "word learned"). Needs Accessibility.
    var autoLearnFromEdits: Bool {
        didSet { defaults.set(autoLearnFromEdits, forKey: Keys.autoLearn) }
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

    /// Brand accent driving the live waveform. Defaults to vivid blue.
    var accentTheme: AccentTheme {
        didSet { defaults.set(accentTheme.rawValue, forKey: Keys.accentTheme) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults

        // New default: whisper.cpp Large v3 Turbo (F16) — fast on Metal and the most
        // accurate turbo variant. A one-time migration moves EVERY existing user to
        // it on this update too (not just new installs), gated by a flag so it fires
        // exactly once; afterwards the user's own model choice is honored. New
        // installs (no stored value) also start here.
        if defaults.bool(forKey: Keys.migratedTurboCpp) {
            model = ModelChoice(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .cppLargeV3Turbo
        } else {
            model = .cppLargeV3Turbo
            defaults.set(ModelChoice.cppLargeV3Turbo.rawValue, forKey: Keys.model)
            defaults.set(true, forKey: Keys.migratedTurboCpp)
        }

        language = Language(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .auto
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
        fnTriggerEnabled = defaults.object(forKey: Keys.fnTrigger) == nil
            ? true
            : defaults.bool(forKey: Keys.fnTrigger)
        // First-launch defaults: streaming, filler removal, and smart cleanup all
        // OFF (`bool(forKey:)` is false when unset). Each persists once toggled.
        streaming = defaults.bool(forKey: Keys.streaming)
        removeFillers = defaults.bool(forKey: Keys.removeFillers)
        smartCleanup = defaults.bool(forKey: Keys.smartCleanup)
        let storedCleanup = defaults.string(forKey: Keys.cleanupModel) ?? ""
        cleanupModel = CleanupModel(rawValue: storedCleanup) ?? .qwen1_5B
        autoLearnFromEdits = defaults.object(forKey: Keys.autoLearn) == nil
            ? true
            : defaults.bool(forKey: Keys.autoLearn)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
        accentTheme = AccentTheme(rawValue: defaults.string(forKey: Keys.accentTheme) ?? "") ?? .blue

        // Apple's on-device cleanup was removed (too slow). Rewrite any stale or
        // unknown stored value (e.g. the old "appleFoundation") to the fast Qwen
        // default so it doesn't keep silently falling back each launch.
        if CleanupModel(rawValue: storedCleanup) == nil {
            defaults.set(CleanupModel.qwen1_5B.rawValue, forKey: Keys.cleanupModel)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let model = "whisperModel"
        static let language = "language"
        static let inputDeviceUID = "inputDeviceUID"
        static let fnTrigger = "fnTriggerEnabled"
        static let streaming = "streamingEnabled"
        static let removeFillers = "removeFillers"
        static let smartCleanup = "smartCleanup"
        static let cleanupModel = "cleanupModel"
        static let autoLearn = "autoLearnFromEdits"
        static let onboarded = "hasCompletedOnboarding"
        static let accentTheme = "accentTheme"
        static let migratedTurboV2 = "migratedToTurboV2"
        /// One-time gate: force everyone to the new whisper.cpp Turbo default once.
        static let migratedTurboCpp = "migratedToTurboCpp"
    }
}
