# Murmur — build plan

> Working title: **Murmur** (a quiet voice → text app). Rename anytime; it's only referenced in `project.yml`, the bundle id, and folder names.

A native macOS menu-bar app: hold a hotkey → record mic → transcribe locally with Whisper → insert text at the cursor (or copy to clipboard if no text field is focused). Plus a notch animation and a searchable history.

## Tech decisions (locked)
- **Language/UI:** Swift + SwiftUI + AppKit where needed.
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` → `.xcodeproj`). Keeps the project text-based and agent-editable. User opens the generated `.xcodeproj` in Xcode to run/sign.
- **Deps (SwiftPM):**
  - [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) — global push-to-talk hotkey (key-down/key-up).
  - [`WhisperKit`](https://github.com/argmaxinc/WhisperKit) — local Core ML Whisper, offline, on-device.
  - [`DynamicNotchKit`](https://github.com/MrKai77/DynamicNotchKit) — notch-anchored animated panel.
- **Persistence:** SwiftData.
- **Min target:** macOS 14 (Sonoma). Apple Silicon strongly recommended (WhisperKit/Core ML).

## Prerequisites (user, one-time)
- Xcode 15+ installed.
- `brew install xcodegen`
- Apple Silicon Mac on macOS 14+.

## Permissions the app will request
- **Microphone** (`NSMicrophoneUsageDescription`) — recording.
- **Accessibility** — focused-element detection + synthetic ⌘V insertion.
- (Possibly **Input Monitoring** depending on hotkey behavior.)

## Target file layout
```
WisprFlow Dupe/
  project.yml                 # XcodeGen spec
  PLAN.md                     # this file (progress tracker)
  Murmur/
    App/        MurmurApp.swift, AppState.swift
    Audio/      AudioRecorder.swift
    Transcription/ WhisperService.swift
    Input/      HotkeyManager.swift, TextInserter.swift, AccessibilityManager.swift
    History/    Transcript.swift, HistoryStore.swift, HistoryView.swift
    Notch/      NotchController.swift, NotchView.swift, WaveformView.swift
    Settings/   SettingsView.swift, Preferences.swift
    Support/    Info.plist, Murmur.entitlements, Assets.xcassets
```

---

## Phase 0 — Scaffolding & toolchain  ✅
**Goal:** a menu-bar app that compiles from the CLI and launches with an icon in the menu bar (no dock icon).
- `project.yml` (XcodeGen) defining the app target, deployment target, SPM deps, Info.plist, entitlements.
- `Info.plist` with `LSUIElement=YES`, usage strings. `Murmur.entitlements`.
- `MurmurApp.swift` — `@main` `MenuBarExtra` with a placeholder menu (About / Quit).
- `AppState.swift` — central `@Observable` state stub.
- **Verify:** `xcodegen generate` succeeds; `xcodebuild -scheme Murmur build` compiles; user runs it → menu-bar icon appears, Quit works.

## Phase 1 — Core transcription loop (de-risk)  ✅
**Goal:** hold hotkey → speak → release → transcript on the clipboard. No fancy UI.
- `HotkeyManager.swift` — KeyboardShortcuts hold-to-record (key-down starts, key-up stops).
- `AudioRecorder.swift` — `AVAudioEngine` mic tap → resample to 16kHz mono Float32 (`AVAudioConverter`); expose level metering.
- `WhisperService.swift` — load WhisperKit model (`base.en` default), transcribe Float32 buffer → text.
- Mic permission request + denied-state handling.
- On release: transcribe → `NSPasteboard` copy. Log result.
- **Verify:** user holds hotkey, speaks, releases → text is in clipboard (paste anywhere to confirm).

## Phase 2 — Smart insert vs. auto-copy  ✅
**Goal:** type into the focused field if editable; otherwise copy + toast (your spec).
- `AccessibilityManager.swift` — request Accessibility; read `kAXFocusedUIElementAttribute`, decide if editable (AXTextField/AXTextArea/AXComboBox/role+settable value).
- `TextInserter.swift` — editable → set clipboard + synthesize ⌘V via `CGEvent`; else → copy + lightweight toast/notification. Handle secure-input fields gracefully (fall back to copy).
- Accessibility onboarding prompt if not granted.
- **Verify:** dictate into TextEdit → text typed in; dictate with nothing focused → copied + toast shown.

## Phase 3 — History  ✅
**Goal:** persistent, searchable list of past transcripts; click to re-copy.
- `Transcript.swift` — SwiftData model (text, createdAt, duration?).
- `HistoryStore.swift` — save on each successful transcription; fetch/delete/search.
- `HistoryView.swift` — list newest-first, search field, click-to-recopy, swipe/delete. Surfaced from the menu-bar menu.
- **Verify:** transcripts persist across relaunch; re-copy and delete work; search filters.

## Phase 4 — Notch animation  ✅
**Goal:** a polished indicator that flows from the notch through the dictation lifecycle.
- `NotchController.swift` — DynamicNotchKit panel; state machine: idle(hidden) → listening → transcribing → done.
- `WaveformView.swift` — live waveform driven by `AudioRecorder` levels.
- `NotchView.swift` — listening waveform, transcribing shimmer/spinner, done checkmark flourish.
- Handle non-notched + external displays (graceful top-center fallback).
- **Verify:** user observes animation during a full dictation; behaves on notched + non-notched screens.

## Phase 5 — Polish & settings  ✅
**Goal:** ship-ready feel.
- `Preferences.swift` + `SettingsView.swift` — shortcut recorder, Whisper model picker (+ download/progress), mic picker, insert-mode toggle, launch-at-login.
- First-run onboarding flow for Mic + Accessibility permissions.
- Latency tuning, empty/short-audio handling, error toasts.
- App icon + assets; final naming pass.
- Notes for signing/notarization if distributing.
- **Verify:** full end-to-end run; settings persist; permissions onboarding is clean.

---

## Progress log
- **Wispr-style LLM cleanup (local, llama.cpp)** — Researched: Wispr uses fine-tuned **Llama 3.1 in the cloud** (Baseten). MLX is fastest local runtime BUT conflicts with WhisperKit (incompatible swift-transformers: WhisperKit [1.1.6,1.2) vs MLX-examples <1.0 or 1.3+; no overlap). FluidAudio has zero deps. Decision (user): keep both engines + **llama.cpp via `LLM.swift` 2.1.0** (prebuilt Metal xcframework, no swift-transformers → no conflict; needs `-skipMacroValidation` on CLI / "Trust & Enable" in Xcode). Built `LLMCleaner` (actor, Qwen2.5 + ChatML, stateless `getCompletion`, low temp). `Template.llama` is Llama-2 format so used Qwen+chatML. LLM.swift's HF HTML-scrape downloader fails → wrote own resolve-URL downloader into App Support/Murmur/Models. `Preferences.smartCleanup` + `cleanupModel` (Qwen 3B default / 1.5B), `AppState.cleanupPhase`, Settings section, applied in `endRecording` ("Polishing…" notch) before deliver; supersedes filler regex. Models: tiny/base/small + quantized turbo + distil turbo + full turbo (Whisper) + Parakeet. `xcodebuild` → BUILD SUCCEEDED.
- **Transcript cleanup (fillers)** — Parakeet is verbatim (keeps um/uh, spells out numbers "twenty twenty six", keeps self-corrections). Added deterministic `TranscriptCleaner.removeFillers` + `Preferences.removeFillers` toggle (default on) + Settings toggle; applied in `deliver`. **Numbers/ITN dead end:** FluidAudio's `TextNormalizer` calls a native NeMo lib via `dlopen`/`dlsym` that isn't bundled in the SPM package → `isNativeAvailable == false` → no-op. So numbers + disfluencies (self-corrections) need an LLM pass — recommended next: on-device Apple **FoundationModels** (macOS 26, free/local) cleanup pass. Awaiting user decision (latency vs polish; needs Apple Intelligence). `xcodebuild` → BUILD SUCCEEDED.
- **Speed bug + Parakeet engine** — **Root cause of "1 min for 30s":** `streamingEnabled` was ON, and the streaming loop re-transcribed the *entire growing buffer* every 0.8s (O(n²)), saturating the engine + blocking the final pass. Synthetic bench proved the engine itself is fast (warm 0.14s / ~107× RTF; the autoregressive decoder is the real cost for many-token real speech). **Fixes:** (1) streaming now previews only the last ~8s window (bounded cost); (2) Whisper decode options `withoutTimestamps=true` + `wordTimestamps=false` + `temperatureFallbackCount=1` (timestamps ~double decode steps). **Parakeet:** added FluidAudio 0.15.3 → `ParakeetService` (Parakeet TDT 0.6B v3, CoreML/ANE, non-autoregressive, multilingual). Introduced `SpeechEngine` protocol + `EngineLoadState`; `WhisperService` + `ParakeetService` conform; `DictationController` swaps engine by `Preferences.ModelChoice` (renamed from WhisperModel; added `.parakeet`, `.engine`). Removed turbo migration. `xcodebuild` → BUILD SUCCEEDED. Added a `MURMUR_BENCH` env-gated benchmark hook in `DictationController`/`AppDelegate`.
- **Hang fix + models + multi-trigger + streaming** — **Root cause of "infinite transcribing":** the 3 GB full-precision `large-v3_turbo` downloaded fine but its first Core ML/ANE compile is brutally slow with zero UI feedback. **Fixes:** (1) default → quantized **`large-v3_turbo_954MB`** (migration v2; verified it downloads ~1 GB and resolves); (2) `AppState.modelPhase` + `WhisperService` `setStateHandler` surface preparing/ready/failed in the menu, Settings, and notch — never a silent hang. **Models** (from WhisperKit M-series benchmarks): tiny/base/small + quantized turbo (recommended, multilingual) + **Distil Turbo** (`distil-large-v3_turbo_600MB`, fastest ~53 tok/s, English-only) + full turbo (max accuracy, slow load). No "medium" exists in WhisperKit's CoreML repo. **Multi-trigger:** `HotkeyManager` rewritten — Fn toggle + 3 `KeyboardShortcuts.Recorder` slots (`.dictation`/`2`/`3`), all push-to-talk. **Streaming toggle:** `Preferences.streaming` → live partial transcribe loop (800 ms cadence) previewing in the notch; final authoritative pass on release. `xcodebuild` → BUILD SUCCEEDED. Old 3 GB model still on disk (user can delete `openai_whisper-large-v3_turbo/`).
- **Accuracy pass (post-Phase 5)** — Upgraded default model to **`large-v3_turbo`** (verified id + ANE-optimized via WhisperKit checkout; one-time `migratedToTurbo` bumps existing installs). Added **Language** setting (Auto-detect + 11 languages) → `DecodingOptions.language`/`detectLanguage`. Added **custom vocabulary** (`VocabularyStore`, UserDefaults) fed as `promptTokens` via `tokenizer.encode` (special tokens filtered) to bias names/jargon. Settings gains Language picker + Custom vocabulary editor. `WhisperService.transcribe(_:language:vocabulary:)`. `xcodebuild` → BUILD SUCCEEDED; boots. Turbo (~1.5 GB) downloads on first dictation. **Deferred:** auto-learn-on-edit (Wispr's "learned the word" popup) — needs AX edit-observation + diffing; manual vocab landed instead.
- **Phase 5 ✅** — `Preferences` (@Observable, UserDefaults: model, hotkey mode, onboarding; launch-at-login via `SMAppService`). `WhisperService.setModel` for runtime model switch. `DictationController` now takes `Preferences`, applies hotkey mode + model, tracks mic/AX permissions, requests mic. `SettingsView` (Form: permissions w/ status + actions, trigger Fn-vs-custom + `KeyboardShortcuts.Recorder`, model picker tiny/base/small/large-v3, launch-at-login). `SettingsWindowController` (AppKit-hosted). First-run auto-opens Settings for onboarding. Menu gains "Settings…" (⌘,). **App icon** generated via `tools/make_icon.swift` (gradient squircle + waveform) → 10 PNGs + `AppIcon.icns` in bundle. `xcodebuild` → BUILD SUCCEEDED. **Deliberately cut:** mic picker (uses system default input; pick in System Settings ▸ Sound) — Core Audio device routing was high-cost/low-value; can add on request.
- **Phase 4 ✅** — Added DynamicNotchKit 1.1.0 (read its real API from the checkout first). Built `NotchViewModel` (rolling RMS level buffer + phase), `WaveformView` (animated capsule bars), `DictationNotchView` (listening waveform / transcribing spinner / done checkmark / error), `NotchController` (`DynamicNotch(.auto)`, expand/hide, auto-hide timers). `DictationController` feeds live mic levels to the notch (`onLevel` → main-thread `updateLevel`) and drives phases through the lifecycle; notch shows "Inserted"/"Copied" on finish (replaced the toast → deleted `ToastPresenter`). Added a fast-tap race guard (release-before-start-completes). `xcodebuild` → BUILD SUCCEEDED; boots.
- **Phase 3 ✅** — **Fn/🌐 push-to-talk:** rewrote `HotkeyManager` with a `.fnKey` mode (monitors `flagsChanged` for keyCode 0x3F, global+local) since the Fn key can't be a Carbon hotkey; `.shortcut` mode kept for Phase 5 picker. **History:** `Transcript` (SwiftData `@Model`), `HistoryStore` (shared `ModelContainer`), `HistoryView` (searchable list, click/context-menu re-copy with checkmark feedback, swipe + Clear All), `HistoryWindowController` (AppKit-hosted window so it doesn't auto-open at launch). `DictationController` saves every transcript; menu gains "History…". `xcodebuild` → BUILD SUCCEEDED; boots. Default trigger is now 🌐 (Fn), needs Accessibility (already granted Phase 2). ⚠️ user should set System Settings ▸ Keyboard ▸ "Press 🌐 key to" → Do Nothing.
- **Phase 2 ✅** — Switched default model `base.en` → `small` (multilingual) with `DecodingOptions.detectLanguage = true` so Portuguese + auto-detect work. Added `AccessibilityManager` (AX trust, prompt, open-settings, focused-editable detection, secure-input guard), `TextInserter` (synthetic ⌘V paste w/ clipboard restore; clipboard-only fallback), `ToastPresenter` (floating HUD). `DictationController.deliver` now: editable field → paste; else → copy + toast. Menu shows an "Enable Accessibility" row when not trusted. `xcodebuild` → BUILD SUCCEEDED; boots. Note: `small` (~466 MB) re-downloads on next dictation.
- **Phase 1 ✅** — Resolved KeyboardShortcuts 2.4.0 + WhisperKit 0.18.0. Built `AudioRecorder` (AVAudioEngine tap → AVAudioConverter → 16kHz mono Float32, RMS level callback, lock-protected buffer), `WhisperService` (actor; `base.en`; preload-on-launch), `HotkeyManager` (default ⌥Space push-to-talk), `DictationController` (down→record, up→transcribe→clipboard), `AppDelegate` bootstrap. Default deliver = clipboard (Phase 2 → smart insert). `xcodebuild` → BUILD SUCCEEDED; app boots without crashing. Fix: `AppDelegate` marked `@MainActor`.
- **Phase 0 ✅** — Toolchain verified (macOS 26.5.1 / Apple Silicon / Xcode 26.5 / Swift 6.3.2); installed `xcodegen` 2.45.4. Created `project.yml`, `Info.plist` (LSUIElement, mic usage string), `Murmur.entitlements` (non-sandboxed, audio-input), asset catalog, `MurmurApp.swift` (MenuBarExtra), `AppState.swift`. `xcodebuild` → BUILD SUCCEEDED. App launches as a menu-bar item (waveform icon). Note: third-party SPM deps deferred to their phases; Swift language mode pinned to 5.0 to avoid Swift 6 strict-concurrency friction during the build.
