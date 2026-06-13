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
    private var cleaner: LLMCleaner

    private var isRecording = false
    private var awaitingResult = false
    private var streamTask: Task<Void, Never>?

    init(appState: AppState, history: HistoryStore, preferences: Preferences, vocabulary: VocabularyStore) {
        self.appState = appState
        self.history = history
        self.preferences = preferences
        self.vocabulary = vocabulary
        self.engine = Self.makeEngine(for: preferences.model)
        self.cleaner = LLMCleaner(repo: preferences.cleanupModel.repo, fileName: preferences.cleanupModel.fileName)
    }

    private static func makeEngine(for choice: Preferences.ModelChoice) -> SpeechEngine {
        switch choice.engine {
        case .whisper: return WhisperService(modelName: choice.whisperKitName)
        case .parakeet: return ParakeetService()
        }
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

    /// Rebuild + (re)load the cleanup LLM for the current preference.
    func applyCleanup() {
        cleaner = LLMCleaner(repo: preferences.cleanupModel.repo, fileName: preferences.cleanupModel.fileName)
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
                if preferences.streaming { startStreamingLoop() }
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
                if preferences.smartCleanup {
                    notch.showPreparing("Polishing…")
                    text = await cleaner.clean(text)
                } else if preferences.removeFillers {
                    text = TranscriptCleaner.removeFillers(text)
                }
                deliver(text)
                appState.status = .idle
            } catch {
                appState.status = .error(error.localizedDescription)
                notch.showError(error.localizedDescription)
            }
            awaitingResult = false
        }
    }

    /// Diagnostic: transcribe a synthetic 15s buffer twice (cold + warm) and log
    /// timings to a file (stdout is block-buffered when redirected). Triggered by
    /// the MURMUR_BENCH env var.
    func runBenchmark() async {
        var out = ""
        let path = "/tmp/murmur_bench_result.txt"
        func log(_ s: String) {
            out += "[\(Date())] \(s)\n"
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        }

        log("bench start; building audio…")
        let count = 16_000 * 15
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = 0.02 * sin(Float(i) * 2 * .pi * 220 / 16_000)
        }
        log("audio built (\(count) samples); pass 1 includes model load…")

        for pass in 1...2 {
            let start = Date()
            let text = (try? await engine.transcribe(samples, language: "en", vocabulary: [])) ?? "<error>"
            let elapsed = Date().timeIntervalSince(start)
            log("pass \(pass): \(String(format: "%.2f", elapsed))s (RTF \(String(format: "%.1f", 15 / elapsed))x) -> \"\(text.prefix(40))\"")
        }
        log("done")
    }

    /// Diagnostic: run the cleanup LLM on a sample dirty transcript (cold + warm).
    func runCleanupBenchmark() async {
        var out = ""
        let path = "/tmp/murmur_clean_result.txt"
        func log(_ s: String) {
            out += "[\(Date())] \(s)\n"
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let testCleaner = LLMCleaner(repo: Preferences.CleanupModel.qwen3B.repo, fileName: Preferences.CleanupModel.qwen3B.fileName)
        let sample = "Okay so now I'm testing um the Parakeet by NVIDIA again and uh while I'm watching the game now in twenty twenty six. Um whereas in OpenAI's Whisper they it doesn't do that."
        log("loading cleanup model + cleaning (cold)…")
        for pass in 1...2 {
            let start = Date()
            let cleaned = await testCleaner.clean(sample)
            let elapsed = Date().timeIntervalSince(start)
            log("pass \(pass) (\(String(format: "%.2f", elapsed))s):")
            if pass == 1 { log("IN : \(sample)") }
            log("OUT: \(cleaned)")
        }
        log("done")
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            notch.dismiss()
            return
        }
        appState.lastTranscript = text
        history.add(text)

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
