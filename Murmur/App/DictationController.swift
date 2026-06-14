import AppKit
import AVFoundation
import Observation

/// Orchestrates one dictation: trigger down → record → trigger up → transcribe →
/// deliver. If an editable field is focused the text is pasted in; otherwise it
/// is left on the clipboard.
@MainActor
@Observable
final class DictationController {
    private let appState: AppState
    private let preferences: Preferences
    private let vocabulary: VocabularyStore
    private let recorder = AudioRecorder()
    private var engine: SpeechEngine
    private let hotkeys = HotkeyManager()
    private let accessibility = AccessibilityManager()
    private let notch = NotchController()
    private let history: HistoryStore
    private var cleaner: any TextCleaner

    private var isRecording = false
    private var awaitingResult = false
    private var streamTask: Task<Void, Never>?

    init(appState: AppState, history: HistoryStore, preferences: Preferences, vocabulary: VocabularyStore) {
        self.appState = appState
        self.history = history
        self.preferences = preferences
        self.vocabulary = vocabulary
        self.engine = Self.makeEngine(for: preferences.model)
        self.cleaner = Self.makeCleaner(for: preferences.cleanupModel)
    }

    private static func makeEngine(for choice: Preferences.ModelChoice) -> SpeechEngine {
        switch choice.engine {
        case .whisper: return WhisperService(modelName: choice.whisperKitName)
        case .parakeet: return ParakeetService()
        }
    }

    private static func makeCleaner(for choice: Preferences.CleanupModel) -> any TextCleaner {
        LLMCleaner(repo: choice.repo, fileName: choice.fileName)
    }

    private func attachStateHandler(to engine: SpeechEngine) {
        Task {
            await engine.setStateHandler { [weak self] state in
                Task { @MainActor in self?.handleModelState(state) }
            }
            await engine.preload()
        }
    }

    func bootstrap() {
        hotkeys.onPress = { [weak self] in self?.beginRecording() }
        hotkeys.onRelease = { [weak self] in self?.endRecording() }
        hotkeys.start(fnEnabled: preferences.fnTriggerEnabled)
        appState.shortcutHint = "Trigger: \(hotkeys.triggersDescription)"

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.notch.updateLevel(level) }
        }

        attachStateHandler(to: engine)
        if preferences.smartCleanup { attachCleanupHandler() }

        refreshPermissions()
        if !accessibility.isTrusted {
            accessibility.promptForTrust()
        }
    }

    // MARK: - Settings actions

    /// Re-apply the Fn-key toggle (custom shortcuts are handled live by the recorder).
    func applyTriggers() {
        hotkeys.setFnEnabled(preferences.fnTriggerEnabled)
        appState.shortcutHint = "Trigger: \(hotkeys.triggersDescription)"
    }

    func applyModel() {
        appState.modelPhase = .preparing
        let newEngine = Self.makeEngine(for: preferences.model)
        engine = newEngine
        attachStateHandler(to: newEngine)
    }

    /// Rebuild + (re)load the cleanup backend for the current preference.
    func applyCleanup() {
        cleaner = Self.makeCleaner(for: preferences.cleanupModel)
        if preferences.smartCleanup {
            appState.cleanupPhase = .preparing
            attachCleanupHandler()
        } else {
            appState.cleanupPhase = .idle
        }
    }

    private func attachCleanupHandler() {
        let cleaner = cleaner
        Task {
            await cleaner.setStateHandler { [weak self] state in
                Task { @MainActor in self?.handleCleanupState(state) }
            }
            await cleaner.preload()
        }
    }

    private func handleCleanupState(_ state: EngineLoadState) {
        switch state {
        case .preparing: appState.cleanupPhase = .preparing
        case .ready: appState.cleanupPhase = .ready
        case .failed(let message): appState.cleanupPhase = .failed(message)
        }
    }

    func refreshPermissions() {
        appState.accessibilityEnabled = accessibility.isTrusted
        appState.micEnabled = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissions()
        }
    }

    /// Re-check Accessibility and offer to open System Settings if still missing.
    func enableAccessibility() {
        appState.accessibilityEnabled = accessibility.isTrusted
        if !accessibility.isTrusted {
            accessibility.promptForTrust()
            accessibility.openSettings()
        }
    }

    // MARK: - Model state

    private func handleModelState(_ state: EngineLoadState) {
        switch state {
        case .preparing:
            appState.modelPhase = .preparing
            if awaitingResult { notch.showPreparing("Preparing model…") }
        case .ready:
            appState.modelPhase = .ready
            if awaitingResult { notch.showTranscribing() }
        case .failed(let message):
            appState.modelPhase = .failed(message)
            if awaitingResult {
                awaitingResult = false
                notch.showError("Model failed to load")
            }
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        // The notch live preview only makes sense on a fast, non-autoregressive
        // engine. With Whisper, repeatedly transcribing the growing buffer is
        // O(n²) and starves the final transcription — so we skip it there and just
        // transcribe once on release.
        let streamingCapable = preferences.model.engine == .parakeet
        Task {
            do {
                try await recorder.start()
                guard isRecording else {
                    _ = recorder.stop()
                    notch.dismiss()
                    return
                }
                appState.status = .listening
                notch.showListening()
                if preferences.streaming && streamingCapable {
                    startStreamingLoop()
                }
            } catch {
                isRecording = false
                appState.status = .error(error.localizedDescription)
                notch.showError(error.localizedDescription)
            }
        }
    }

    /// While recording, periodically transcribe the audio-so-far for a live
    /// preview in the notch. Passes serialize on the WhisperService actor.
    private func startStreamingLoop() {
        let language = preferences.language.code
        let vocab = vocabulary.terms
        streamTask?.cancel()
        streamTask = Task {
            while isRecording {
                try? await Task.sleep(for: .milliseconds(800))
                guard isRecording else { break }
                let full = recorder.currentSamples()
                guard full.count >= 12_000 else { continue } // ~0.75s minimum
                // Preview only the most recent ~8s so each pass stays cheap and
                // can't pile up or block the final transcription on release.
                let recent = full.count > 128_000 ? Array(full.suffix(128_000)) : full
                let text = try? await engine.transcribe(recent, language: language, vocabulary: vocab)
                if isRecording, let text, !text.isEmpty {
                    notch.showStreamingPartial(text)
                }
            }
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        streamTask?.cancel()
        streamTask = nil

        let samples = recorder.stop()
        awaitingResult = true
        appState.status = .transcribing
        if appState.modelPhase == .ready {
            notch.showTranscribing()
        } else {
            notch.showPreparing("Preparing model…")
        }

        Task {
            do {
                var text = try await engine.transcribe(
                    samples,
                    language: preferences.language.code,
                    vocabulary: vocabulary.terms
                )
                var original: String? = nil
                if preferences.smartCleanup {
                    notch.showPreparing("Polishing…")
                    // Strip basic fillers deterministically FIRST (instant, 100% reliable
                    // for um/uh/ah/erm/hmm) so the LLM never has to — it's slow and
                    // unreliable at it, and offloading mechanical work leaves it only the
                    // judgment calls (self-corrections, punctuation, spoken numbers, and
                    // contextual fillers like "you know"/"like"). Fewer reasons for it to
                    // "fix" things means less over-editing.
                    if preferences.removeFillers { text = TranscriptCleaner.removeFillers(text) }
                    original = text // the exact input to the LLM, for the comparison screen
                    let cleaned = await cleaner.clean(text)
                    // Reject refusals / "answers" so a guardrailed model can never
                    // paste "As an LLM I cannot…" into your text in place of cleanup.
                    text = CleanupGuard.sanitize(cleaned, original: text)
                } else if preferences.removeFillers {
                    text = TranscriptCleaner.removeFillers(text)
                }
                deliver(text, original: original)
                appState.status = .idle
            } catch {
                appState.status = .error(error.localizedDescription)
                notch.showError(error.localizedDescription)
            }
            awaitingResult = false
        }
    }

    private func deliver(_ text: String, original: String? = nil) {
        guard !text.isEmpty else {
            notch.dismiss()
            return
        }
        appState.lastTranscript = text
        // Only record `original` when it actually differs from the delivered text,
        // so the comparison screen highlights real edits (not no-ops).
        history.add(text, original: original != text ? original : nil)

        appState.accessibilityEnabled = accessibility.isTrusted
        let canInsert = accessibility.isTrusted
            && !accessibility.isSecureInputActive
            && accessibility.isEditableFieldFocused()

        if canInsert {
            TextInserter.paste(text)
            notch.finish(message: "Inserted")
        } else {
            TextInserter.copyToClipboard(text)
            notch.finish(message: "Copied")
        }
    }
}
