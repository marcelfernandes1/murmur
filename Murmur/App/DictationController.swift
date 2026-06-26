import AppKit
import AVFoundation
import Observation
import OSLog

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
    private let sounds = FeedbackSounds()
    private let spaceLock = SpaceLockMonitor()
    private let controlBar = HandsFreeControlBar()
    private var cleaner: any TextCleaner

    /// Instruments delivery stages so latency is visible in Instruments / `log
    /// stream` without console spam. View with: Instruments → os_signpost, or
    /// `log stream --predicate 'subsystem == "com.murmur.app"'`.
    private static let signposter = OSSignposter(subsystem: "com.murmur.app", category: "delivery")
    /// Capture diagnostics (sample count / duration before transcription). Shares the
    /// "audio" category with `AudioRecorder` so one log stream shows the whole path.
    private static let audioLog = Logger(subsystem: "com.murmur.app", category: "audio")

    /// Held for the app's lifetime to keep macOS from App-Napping / throttling Murmur
    /// while it sits idle in the menu bar. A napped background app wakes with latency,
    /// so the FIRST hotkey after a few idle seconds was slow while rapid repeats were
    /// instant — the reported "fast on repeat, laggy after idle" pattern. Uses the
    /// "...AllowingIdleSystemSleep" variant so we stay responsive but never block the
    /// Mac from sleeping.
    private var appActivity: NSObjectProtocol?

    private var isRecording = false
    /// Hands-free: the recording was "locked" (Space while holding the trigger) so
    /// it keeps capturing after the trigger is released, until the next trigger
    /// press commits it.
    private var isLocked = false
    private var awaitingResult = false
    private var didWarmOthers = false
    private var streamTask: Task<Void, Never>?
    private var undoClearTask: Task<Void, Never>?
    private var errorClearTask: Task<Void, Never>?
    /// The begin-recording Task (audio-unit start). Tracked so a quick release that
    /// beats a slow (e.g. Bluetooth) `recorder.start()` can defer the commit until
    /// capture is actually live, instead of stopping an empty buffer.
    private var startTask: Task<Void, Never>?
    /// The transcribe→deliver Task, tracked so a new (or cancelled) dictation can
    /// abandon an in-flight one rather than letting a stale result paste itself.
    private var transcribeTask: Task<Void, Never>?
    /// True once `recorder.start()` has actually brought capture up.
    private var captureLive = false
    /// Trigger released before capture went live — commit as soon as it does.
    private var commitPending = false
    /// Engine bound to the in-flight dictation, captured at begin so switching models
    /// mid-recording can't make the commit transcribe on a not-yet-loaded engine.
    private var dictationEngine: SpeechEngine?
    /// Monotonic per-dictation tag so a late/stale transcribe result can't clobber a
    /// newer dictation's UI state.
    private var dictationGeneration = 0

    /// Wall-clock trigger-down instant, used to tell an accidental tap (released
    /// almost immediately) from a real hold that happened to capture nothing.
    private let recordingClock = ContinuousClock()
    private var recordingStartedAt: ContinuousClock.Instant?

    /// Hold the trigger for less than this and capture no audio ⇒ treat it as an
    /// accidental tap, not a failure — so a stray brush never flashes a warning
    /// (or leaves the menu-bar icon stuck on it). Comfortably longer than a brush,
    /// shorter than a real one-word dictation.
    private static let minIntentionalHold: Duration = .milliseconds(400)

    /// What a just-ended recording's buffer warrants. Pure decision, kept out of
    /// `commitRecording` so it can be exercised by `runCaptureSelfTest`.
    enum CaptureOutcome: Equatable {
        case accidentalTap   // too short to be real + the trigger was barely held
        case noAudio         // held a real beat but the engine delivered ~nothing
        case noSignal        // audio arrived but it's digital silence (dead mic)
        case transcribe      // good buffer — go transcribe it
    }

    /// `held` is the wall-clock trigger hold (nil if unknown ⇒ never an accidental tap).
    static func captureOutcome(sampleCount: Int, held: Duration?, peak: Float) -> CaptureOutcome {
        if sampleCount < 1_600 { // < 0.1 s at 16 kHz
            if let held, held < minIntentionalHold { return .accidentalTap }
            return .noAudio
        }
        if peak < 0.0005 { return .noSignal }
        return .transcribe
    }

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
        case .whisperCpp: return WhisperCppService(fileName: choice.ggmlFileName)
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
        // Keep Murmur out of App Nap so the dictation hotkey is handled instantly even
        // after the app has been idle in the menu bar for a while (see appActivity).
        appActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Respond to the dictation hotkey instantly, even after idle")

        hotkeys.onPress = { [weak self] in self?.handleTriggerDown() }
        hotkeys.onRelease = { [weak self] in self?.handleTriggerUp() }
        spaceLock.onLock = { [weak self] in self?.lockRecording() }
        // Esc cancels the recording (same as Trash), without transcribing.
        spaceLock.onCancel = { [weak self] in self?.discardRecording() }
        // The hands-free control bubble's buttons: ✓ commits (like pressing the
        // trigger again), 🗑 discards the audio without transcribing.
        controlBar.onDone = { [weak self] in self?.commitRecording() }
        controlBar.onCancel = { [weak self] in self?.discardRecording() }
        hotkeys.start(fnEnabled: preferences.fnTriggerEnabled)
        appState.shortcutHint = "Trigger: \(hotkeys.triggersDescription)"

        notch.model.accent = preferences.accentTheme

        // The waveform is advanced by the notch's own fixed visual clock, which
        // pulls the interval RMS from the recorder here — decoupled from audio
        // callback cadence so scroll speed is identical across mics/buffer sizes.
        notch.levelProvider = { [weak recorder] in recorder?.drainLevel() }
        recorder.preferredDeviceUID = preferences.inputDeviceUID
        // Let the recorder's config-change diagnostics report whether the trigger is
        // believed held (thread-safe snapshot; no MainActor hop from the audio queue).
        recorder.hotkeyHeldProvider = { [heldState = hotkeys.heldState] in heldState.get() }

        editWatcher.onCorrection = { [weak self] candidate in
            self?.learn(candidate)
        }

        // Sanity-check correction detection from the CLI (mirrors MURMUR_BENCH):
        // `MURMUR_TEST_CORRECTIONS=1 open Murmur.app` prints PASS/FAIL to the log.
        if ProcessInfo.processInfo.environment["MURMUR_TEST_CORRECTIONS"] != nil {
            CorrectionDetector.runSelfTest()
            CorrectionStore.runSelfTest()
        }
        if ProcessInfo.processInfo.environment["MURMUR_TEST_CAPTURE"] != nil {
            Self.runCaptureSelfTest()
        }
        // Visual preview of the notch + hands-free bubble together (no recording),
        // for screenshotting the layout: `MURMUR_PREVIEW_CONTROLBAR=1 open Murmur.app`.
        if ProcessInfo.processInfo.environment["MURMUR_PREVIEW_CONTROLBAR"] != nil {
            notch.showListening()
            controlBar.show()
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
        // An in-flight dictation keeps the engine it captured at begin (see
        // `dictationEngine`), so swapping here can't redirect its commit to a not-yet-
        // loaded model — the new choice simply takes effect from the next dictation.
        appState.modelPhase = .preparing
        let newEngine = Self.makeEngine(for: preferences.model)
        engine = newEngine
        attachStateHandler(to: newEngine)
    }

    /// Apply the chosen microphone (takes effect on the next recording).
    func applyInputDevice() {
        recorder.preferredDeviceUID = preferences.inputDeviceUID
    }

    /// Push the chosen brand accent to the notch waveform (live).
    func applyAccent() {
        notch.model.accent = preferences.accentTheme
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
        case .preparing, .downloading: appState.cleanupPhase = .preparing
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
            appState.modelDownloadProgress = nil
            appState.modelPhase = .preparing
            if awaitingResult { notch.showPreparing("Preparing model… (first run can take a couple minutes)") }
        case .downloading(let fraction):
            appState.modelDownloadProgress = fraction
            appState.modelPhase = .preparing
            if awaitingResult { notch.showPreparing("Downloading model… \(Int(fraction * 100))%") }
        case .ready:
            appState.modelDownloadProgress = nil
            appState.modelPhase = .ready
            if awaitingResult { notch.showTranscribing() }
            // Proactive warming of every *other* model is intentionally NOT run: users
            // settle on one model and rarely switch, so eagerly downloading + ANE-
            // compiling the whole matrix on launch wastes disk / Neural Engine / battery
            // and adds startup CPU contention for no real benefit. Models warm on demand
            // the first time they're actually selected (with the existing progress UI).
            // (warmOtherModels remains below, unused, in case we want it behind an opt-in.)
        case .failed(let message):
            appState.modelDownloadProgress = nil
            appState.modelPhase = .failed(message)
            if awaitingResult {
                awaitingResult = false
                notch.showError("Model failed to load")
            }
        }
    }

    /// Once the selected model is ready, quietly load every *other* model a single
    /// time so Core ML downloads + ANE-specializes each and caches the result on
    /// disk. Switching models later then hits a warm cache (instant) instead of
    /// triggering a fresh multi-minute Neural Engine compile. Runs at background
    /// priority, sequentially (only one extra model resident at a time), and drops
    /// each instance once its cache is warmed — the on-disk cache is what persists.
    private func warmOtherModels() {
        guard !didWarmOthers else { return }
        didWarmOthers = true
        let selected = preferences.model
        Task.detached(priority: .background) {
            // Let the just-loaded model settle before competing for the ANE.
            try? await Task.sleep(for: .seconds(5))
            // Only warm the original WhisperKit/Parakeet models. The whisper.cpp
            // matrix is a large set of opt-in *testing* models (up to 3 GB each) —
            // blanket-warming them would silently download tens of GB. Those fetch
            // on demand the first time the user actually selects one.
            for choice in Preferences.ModelChoice.allCases
            where choice != selected && choice.engine != .whisperCpp {
                let engine = await MainActor.run { Self.makeEngine(for: choice) }
                await engine.preload()
            }
        }
    }

    // MARK: - Recording

    /// Trigger pressed. Starts a recording, or — when already hands-free locked —
    /// commits the in-flight one (the "press again to insert" half of the gesture).
    private func handleTriggerDown() {
        if isRecording {
            if isLocked { commitRecording() }
            return
        }
        beginRecording()
    }

    /// Trigger released. Commits a normal push-to-talk recording; ignored while
    /// hands-free locked, so releasing the trigger keeps the recording running.
    private func handleTriggerUp() {
        guard isRecording, !isLocked else { return }
        commitRecording()
    }

    /// Lock the live recording into hands-free mode (Space pressed while holding the
    /// trigger). The trigger can now be released without ending capture.
    private func lockRecording() {
        guard isRecording, !isLocked else { return }
        isLocked = true
        if preferences.soundEffects { sounds.play(.lock) }
        controlBar.show()
    }

    /// Discard the in-flight recording without transcribing (the 🗑 button). Drops
    /// the captured audio and resets to idle.
    private func discardRecording() {
        guard isRecording else { return }
        isRecording = false
        isLocked = false
        captureLive = false
        commitPending = false
        spaceLock.stop()
        controlBar.hide()
        streamTask?.cancel()
        streamTask = nil
        transcribeTask?.cancel()
        _ = recorder.stop(reason: .hotkeyCancelled)
        recordingStartedAt = nil
        awaitingResult = false
        appState.status = .idle
        notch.dismiss()
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        isLocked = false
        captureLive = false
        commitPending = false
        recordingStartedAt = recordingClock.now
        errorClearTask?.cancel()
        // Starting a new dictation abandons any still-in-flight transcription from a
        // previous one (its result must not paste into this new context) and clears a
        // stuck "awaiting" state, so a wedged prior dictation can't freeze the UI.
        transcribeTask?.cancel()
        awaitingResult = false
        // Bind the engine for this whole dictation up front, so switching the model in
        // Settings mid-recording can't make the commit transcribe on an unloaded one.
        dictationEngine = engine
        // A new dictation supersedes watching the previous field for edits.
        editWatcher.cancel()
        // Show the notch the INSTANT the trigger goes down, and (below) kick off capture
        // immediately — BEFORE the audio cue and the hands-free tap. Creating the Space-
        // lock CGEventTap round-trips to the window server (slow on a busy/long-uptime
        // system) and the cue touches audio output; neither belongs on the press→notch /
        // press→record critical path, so they're deferred to just after capture goes
        // live. The waveform stays flat until capture is actually live, then animates — a
        // natural "I'm hearing you now" cue — so the instant notch can't mislead the user
        // into talking before the mic is live. This also fixes the leading-word clipping
        // that came from the notch (the user's go-cue) trailing the key press.
        appState.status = .listening
        notch.showListening()

        // The notch live preview only makes sense on a fast, non-autoregressive
        // engine. With Whisper, repeatedly transcribing the growing buffer is
        // O(n²) and starves the final transcription — so we skip it there and just
        // transcribe once on release.
        let streamingCapable = preferences.model.engine == .parakeet
        startTask = Task {
            do {
                try await recorder.start()
                guard isRecording else {
                    _ = recorder.stop(reason: .hotkeyCancelled)
                    spaceLock.stop()
                    notch.dismiss()
                    return
                }
                captureLive = true
                // Non-critical extras, now that capture is live and the notch is up: the
                // "recording started" cue and arming Space-to-lock (the user can't reach
                // for Space this fast, so arming it here is plenty early). Kept off the
                // press critical path so a slow window-server tap-create can't delay the
                // notch or the start of recording.
                if preferences.soundEffects { sounds.play(.start) }
                if preferences.handsFreeLock, !spaceLock.start() {
                    Self.audioLog.error("Hands-free lock unavailable — Space-lock tap couldn't be created (Accessibility not granted?)")
                }
                if preferences.streaming && streamingCapable {
                    startStreamingLoop()
                }
                // If the trigger was released during a slow start, the commit was
                // deferred (see commitRecording) — run it now that capture is live.
                if commitPending {
                    commitPending = false
                    commitRecording()
                }
            } catch {
                isRecording = false
                isLocked = false
                captureLive = false
                commitPending = false
                spaceLock.stop()
                controlBar.hide()
                flagError(.error(error.localizedDescription), notch: error.localizedDescription)
            }
        }
    }

    /// While recording, periodically transcribe the audio-so-far for a live
    /// preview in the notch. Passes serialize on the WhisperService actor.
    private func startStreamingLoop() {
        let language = preferences.language.code
        let vocab = biasVocabulary()
        let engine = dictationEngine ?? self.engine
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

    /// Stop capturing and run the transcribe → deliver pipeline. Fired by releasing
    /// the trigger (push-to-talk) or by pressing it again after a hands-free lock.
    private func commitRecording() {
        guard isRecording else { return }
        // If capture hasn't actually gone live yet (slow Bluetooth start), defer the
        // commit: the start Task re-invokes commitRecording the moment it's live, so
        // we never stop and transcribe an empty buffer (the lost-first-capture bug).
        if !captureLive {
            commitPending = true
            return
        }
        isRecording = false
        isLocked = false
        captureLive = false
        commitPending = false
        spaceLock.stop()
        controlBar.hide()
        streamTask?.cancel()
        streamTask = nil

        let samples = recorder.stop(reason: .hotkeyReleased)
        let held = recordingStartedAt.map { recordingClock.now - $0 }
        recordingStartedAt = nil
        let duration = Double(samples.count) / 16_000.0
        let peak = recorder.peakAmplitude
        Self.audioLog.log("commitRecording: samples=\(samples.count, privacy: .public) duration=\(duration, privacy: .public)s peak=\(peak, privacy: .public)")

        // Decide what to do with the buffer (pure + unit-tested — see runCaptureSelfTest).
        switch Self.captureOutcome(sampleCount: samples.count, held: held, peak: peak) {
        case .accidentalTap:
            // A quick brush of the trigger that captured nothing — the user never
            // meant to dictate. Drop it silently so it doesn't flash a warning or
            // leave the menu-bar icon stuck on one.
            appState.status = .idle
            notch.dismiss()
            return
        case .noAudio:
            // Held the trigger a real beat but the engine delivered nothing — the
            // "records, then nothing comes out" symptom. Worth surfacing.
            flagError(.error("No audio captured"), notch: "No audio captured — check mic & input device")
            return
        case .noSignal:
            // A working mic always has some noise floor; essentially-zero peak means
            // the input delivered digital silence (no Mic permission, a muted/wrong
            // device, etc.). Transcribing that is pointless — flag it instead.
            flagError(.error("No microphone signal"), notch: "No mic signal — check input & permission")
            return
        case .transcribe:
            break
        }

        // A real recording is ending — the "let go / press to insert" cue.
        if preferences.soundEffects { sounds.play(.stop) }

        awaitingResult = true
        appState.status = .transcribing
        if appState.modelPhase == .ready {
            notch.showTranscribing()
        } else {
            notch.showPreparing("Preparing model… (first run can take a couple minutes)")
        }

        // Tag this dictation and bind its engine so a late result can't clobber a
        // newer dictation, and a mid-recording model switch can't redirect the commit.
        dictationGeneration &+= 1
        let generation = dictationGeneration
        let engine = dictationEngine ?? self.engine
        transcribeTask = Task {
            let signposter = Self.signposter
            do {
                let transcribeState = signposter.beginInterval("transcribe")
                var text = try await engine.transcribe(
                    samples,
                    language: preferences.language.code,
                    vocabulary: biasVocabulary()
                )
                signposter.endInterval("transcribe", transcribeState)
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
                    let cleanupState = signposter.beginInterval("cleanup")
                    let cleaned = await cleaner.clean(text)
                    signposter.endInterval("cleanup", cleanupState)
                    // Reject refusals / "answers" so a guardrailed model can never
                    // paste "As an LLM I cannot…" into your text in place of cleanup.
                    text = CleanupGuard.sanitize(cleaned, original: text)
                } else if preferences.removeFillers {
                    text = TranscriptCleaner.removeFillers(text)
                }
                // Drop a superseded or cancelled result: if a newer dictation started
                // (or this one was discarded) while we were transcribing/polishing, it
                // must not paste into the new field or overwrite fresher UI state.
                guard !Task.isCancelled, generation == dictationGeneration else { return }
                // Apply previously-learned corrections last, so they reliably win
                // over whatever the recognizer/cleanup produced. Pure, bounded,
                // in-memory — it cannot block delivery (see CorrectionStore).
                let correctState = signposter.beginInterval("corrections")
                text = corrections.apply(to: text)
                signposter.endInterval("corrections", correctState)
                deliver(text, original: rawTranscript)
                appState.status = .idle
                awaitingResult = false
            } catch {
                // Only the current dictation owns the shared UI state.
                guard generation == dictationGeneration else { return }
                flagError(.error(error.localizedDescription), notch: error.localizedDescription)
                awaitingResult = false
            }
        }
    }

    /// Surface a recoverable error in the notch + menu-bar icon, then quietly
    /// revert to idle so the warning glyph doesn't linger until the next
    /// dictation. Guarded: if a new dictation (or a different error) changes the
    /// status during the window, the pending revert leaves it alone.
    private func flagError(_ status: AppState.Status, notch message: String) {
        errorClearTask?.cancel()
        appState.status = status
        notch.showError(message)
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.appState.status == status else { return }
            self.appState.status = .idle
        }
    }

    /// Env-gated self-test for the capture decision (mirrors CorrectionDetector.runSelfTest).
    /// Run with: `MURMUR_TEST_CAPTURE=1 open Murmur.app` and read the log for PASS/FAIL.
    static func runCaptureSelfTest() {
        struct Case { let name: String; let samples: Int; let held: Duration?; let peak: Float; let expect: CaptureOutcome }
        let cases: [Case] = [
            // The reported bug: a light, accidental tap captures nothing → no warning.
            .init(name: "accidental brush (50 ms, empty)", samples: 0, held: .milliseconds(50), peak: 0, expect: .accidentalTap),
            .init(name: "quick tap (200 ms, empty)", samples: 0, held: .milliseconds(200), peak: 0, expect: .accidentalTap),
            // Held a real beat but nothing came back → the genuine "records, nothing out" bug.
            .init(name: "real hold, no audio (2 s, empty)", samples: 0, held: .seconds(2), peak: 0, expect: .noAudio),
            // Just under / over the threshold boundary.
            .init(name: "just under threshold (399 ms, empty)", samples: 0, held: .milliseconds(399), peak: 0, expect: .accidentalTap),
            .init(name: "just over threshold (401 ms, empty)", samples: 0, held: .milliseconds(401), peak: 0, expect: .noAudio),
            // Unknown hold time must never be silently dropped.
            .init(name: "empty, hold unknown", samples: 0, held: nil, peak: 0, expect: .noAudio),
            // A tiny-but-nonzero buffer from a quick tap is still an accidental tap.
            .init(name: "few samples, quick tap", samples: 800, held: .milliseconds(120), peak: 0.2, expect: .accidentalTap),
            // Enough audio but digital silence → dead-mic warning, regardless of hold.
            .init(name: "silent mic (3 s, flat)", samples: 48_000, held: .seconds(3), peak: 0.0001, expect: .noSignal),
            // A normal, valid dictation transcribes.
            .init(name: "valid dictation (3 s)", samples: 48_000, held: .seconds(3), peak: 0.3, expect: .transcribe),
            // A short-but-real word (held past the threshold, audible) transcribes.
            .init(name: "short word (600 ms, audible)", samples: 9_600, held: .milliseconds(600), peak: 0.15, expect: .transcribe),
        ]
        var passed = 0
        for c in cases {
            let got = captureOutcome(sampleCount: c.samples, held: c.held, peak: c.peak)
            let ok = got == c.expect
            if ok { passed += 1 }
            print("[CaptureOutcome] \(ok ? "PASS" : "FAIL") \(c.name)  got=\(got) expect=\(c.expect)")
        }
        print("[CaptureOutcome] \(passed)/\(cases.count) passed")
        fflush(stdout) // GUI launch block-buffers stdout; flush so the result is observable.
    }

    private func deliver(_ text: String, original: String? = nil) {
        guard !text.isEmpty else {
            notch.dismiss()
            return
        }
        let signposter = Self.signposter
        appState.lastTranscript = text

        // Get the text to the user FIRST — pasting must not wait on history I/O.
        appState.accessibilityEnabled = accessibility.isTrusted
        let canInsert = accessibility.isTrusted
            && !accessibility.isSecureInputActive
            && accessibility.isEditableFieldFocused()

        let deliverState = signposter.beginInterval("paste")
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
        signposter.endInterval("paste", deliverState)

        // Persist history separately, after delivery, so a slow SwiftData write
        // can never delay the user getting their text. Always record the raw
        // transcript so the comparison screen has an entry for every dictation —
        // identical columns when nothing was changed.
        let historyState = signposter.beginInterval("history")
        history.add(text, original: original)
        signposter.endInterval("history", historyState)
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
