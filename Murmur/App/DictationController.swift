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
    private let corrections: CorrectionStore
    private let recorder = AudioRecorder()
    private var engine: SpeechEngine
    private let hotkeys = HotkeyManager()
    private let accessibility = AccessibilityManager()
    private let notch = NotchController()
    private let history: HistoryStore
    private let editWatcher = FieldEditWatcher()
    private var cleaner: any TextCleaner

    private var isRecording = false
    private var awaitingResult = false
    private var streamTask: Task<Void, Never>?
    private var undoClearTask: Task<Void, Never>?

    init(appState: AppState, history: HistoryStore, preferences: Preferences, vocabulary: VocabularyStore, corrections: CorrectionStore) {
        self.appState = appState
        self.history = history
        self.preferences = preferences
        self.vocabulary = vocabulary
        self.corrections = corrections
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
        recorder.preferredDeviceUID = preferences.inputDeviceUID

        editWatcher.onCorrection = { [weak self] candidate in
            self?.learn(candidate)
        }

        // Sanity-check correction detection from the CLI (mirrors MURMUR_BENCH):
        // `MURMUR_TEST_CORRECTIONS=1 open Murmur.app` prints PASS/FAIL to the log.
        if ProcessInfo.processInfo.environment["MURMUR_TEST_CORRECTIONS"] != nil {
            CorrectionDetector.runSelfTest()
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

    /// Apply the chosen microphone (takes effect on the next recording).
    func applyInputDevice() {
        recorder.preferredDeviceUID = preferences.inputDeviceUID
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
        // A new dictation supersedes watching the previous field for edits.
        editWatcher.cancel()
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
        let vocab = biasVocabulary()
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

        // A working mic always has some noise floor; essentially-zero peak means
        // the input delivered digital silence (no Mic permission, a muted/wrong
        // device, etc.). Transcribing that is pointless — flag it instead.
        if !samples.isEmpty && recorder.peakAmplitude < 0.0005 {
            appState.status = .error("No microphone signal")
            notch.showError("No mic signal — check input & permission")
            return
        }

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
                    vocabulary: biasVocabulary()
                )
                // The exact ASR output, recorded for the comparison screen so it
                // shows every dictation (raw vs. final) — even when nothing changed.
                let rawTranscript = text
                if preferences.smartCleanup {
                    notch.showPreparing("Polishing…")
                    // Strip basic fillers deterministically FIRST (instant, 100% reliable
                    // for um/uh/ah/erm/hmm) so the LLM never has to — it's slow and
                    // unreliable at it, and offloading mechanical work leaves it only the
                    // judgment calls (self-corrections, punctuation, spoken numbers, and
                    // contextual fillers like "you know"/"like"). Fewer reasons for it to
                    // "fix" things means less over-editing.
                    if preferences.removeFillers { text = TranscriptCleaner.removeFillers(text) }
                    let cleaned = await cleaner.clean(text)
                    // Reject refusals / "answers" so a guardrailed model can never
                    // paste "As an LLM I cannot…" into your text in place of cleanup.
                    text = CleanupGuard.sanitize(cleaned, original: text)
                } else if preferences.removeFillers {
                    text = TranscriptCleaner.removeFillers(text)
                }
                // Apply previously-learned corrections last, so they reliably win
                // over whatever the recognizer/cleanup produced.
                text = corrections.apply(to: text)
                deliver(text, original: rawTranscript)
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
        // Always record the raw transcript so the comparison screen has an entry
        // for every dictation — identical columns when nothing was changed.
        history.add(text, original: original)

        appState.accessibilityEnabled = accessibility.isTrusted
        let canInsert = accessibility.isTrusted
            && !accessibility.isSecureInputActive
            && accessibility.isEditableFieldFocused()

        if canInsert {
            TextInserter.paste(text)
            notch.finish(message: "Inserted")
            // Watch the field for the user correcting a word, so we can learn it.
            FieldEditWatcher.diag("deliver: pasted, autoLearnFromEdits=\(preferences.autoLearnFromEdits)")
            if preferences.autoLearnFromEdits {
                editWatcher.start(insertedText: text)
            }
        } else {
            FieldEditWatcher.diag("deliver: NOT inserted (canInsert=false) → copied, no watcher. trusted=\(accessibility.isTrusted) secureInput=\(accessibility.isSecureInputActive) editableFocused=\(accessibility.isEditableFieldFocused())")
            TextInserter.copyToClipboard(text)
            notch.finish(message: "Copied")
        }
    }

    // MARK: - Learning from edits

    /// The recognizer bias list: manual vocabulary plus every learned spelling,
    /// de-duplicated (case-insensitive), original order preserved.
    private func biasVocabulary() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in vocabulary.terms + corrections.biasTerms {
            let key = term.lowercased()
            guard !term.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(term)
        }
        return out
    }

    /// Store a detected correction and flash a "Learned <term>" confirmation,
    /// keeping it briefly undoable from the menu.
    private func learn(_ candidate: CorrectionDetector.Candidate) {
        FieldEditWatcher.diag("learn: storing “\(candidate.heard)” → “\(candidate.corrected)” + flashing notch")
        let entry = corrections.learn(heard: candidate.heard, corrected: candidate.corrected)
        appState.recentlyLearned = entry
        notch.showLearned(entry.corrected)

        undoClearTask?.cancel()
        undoClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.appState.recentlyLearned == entry else { return }
            self.appState.recentlyLearned = nil
        }
    }

    /// Undo the most recently learned word (invoked from the menu).
    func undoLastLearned() {
        guard let entry = appState.recentlyLearned else { return }
        corrections.remove(entry)
        appState.recentlyLearned = nil
        notch.finish(message: "Removed “\(entry.corrected)”")
    }
}
