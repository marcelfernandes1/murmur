# Murmur 🎙️

A fast, **100% local / offline** macOS dictation app — a stripped-down [Wispr Flow](https://wisprflow.ai) clone.

Hold a key, speak, and your words are typed into whatever app you're in (or copied to the clipboard if there's no text field). Everything runs **on-device** — no cloud, no API keys, no subscription.

## Features
- **Push-to-talk** — hold the **Fn / 🌐 key** (or your own shortcut) to dictate.
- **Two speech engines** (switch in Settings):
  - **Parakeet TDT 0.6B v3** (NVIDIA, via FluidAudio) — blazing fast, multilingual.
  - **Whisper** (via WhisperKit) — tiny → large-v3-turbo, with custom vocabulary + language pinning.
- **Smart cleanup (local LLM)** — an optional on-device Llama/Qwen pass (llama.cpp / Metal GPU) that removes filler words ("um", "uh"), deletes false starts, turns spoken numbers into digits ("twenty twenty six" → "2026"), and fixes punctuation — like Wispr Flow's formatting, but offline.
- **Notch animation** — a live waveform flows from the MacBook notch while you talk.
- **History** — searchable list of past transcripts; click to re-copy.
- **Menu-bar app** — no Dock icon.

## Requirements
- **Apple Silicon Mac** (M1 or newer), **macOS 14+**
- **Xcode 15+** (free, from the Mac App Store)

## Install (build it yourself in Xcode)
1. **Clone the repo:**
   ```bash
   git clone https://github.com/marcelfernandes1/murmur.git
   cd murmur
   ```
2. **Open the project:** double-click `Murmur.xcodeproj` (or `open Murmur.xcodeproj`).
3. **Trust the macro:** Xcode will prompt about a Swift macro from `LLM.swift` → click **Trust & Enable**.
4. **Set signing:** select the **Murmur** target → **Signing & Capabilities** → pick your Apple ID under **Team** (add your free Apple ID in Xcode ▸ Settings ▸ Accounts if needed).
5. **Run:** press **⌘R**. The app launches into your menu bar (look for the waveform icon).
6. **Grant permissions** when asked (or in System Settings ▸ Privacy & Security):
   - **Microphone** (to record)
   - **Accessibility** (to type into apps + use the Fn key)
7. **Recommended:** System Settings ▸ Keyboard ▸ **"Press 🌐 key to" → Do Nothing** (stops the emoji picker from popping when you dictate).

## Using it
- **Hold Fn (🌐)**, speak, release → text is inserted at your cursor (or copied if no text field is focused).
- Open the menu-bar icon ▸ **Settings** to choose the engine/model, set custom shortcuts, language, custom vocabulary, and toggle **Smart cleanup**.

### Learning from edits (Mac)

With **Learn corrections when I edit dictated text** enabled, Murmur watches a verified paste for about 30 seconds. A name or short phrase correction must settle for three seconds. It remembers the exact mishearing, desired spelling and up to two nearby words on each side, locally. Split/join edits such as `fan basis → Fanbasis` are supported.

The first recognition receives only your manual Vocabulary. An exact observed alias can trigger a second recognition of the same audio with at most six relevant names. Only the proposed substitutions can reach your text; unrelated word changes reject the verification result. Learned words never become blanket prompts or fuzzy replacements.

All aliases additionally require a matching nearby content word on the same side of the name. If both recognition passes keep the same alias, this context can resolve its spelling; casing-only changes still require the verifier's exact spelling. Ordinary words such as “today” and “through” do not count as evidence. For example, learning `payment through WAP → payment through Whop` can help `payment via WAP`, while `Play WAP next` stays unchanged. This is deliberately conservative: new subjects or weak context may require another correction.

The whisper.cpp engine preserves its complete decode and coverage recovery, then uses timestamped regions for longer takes (at most eight verification regions). Other engines verify recordings up to 25 seconds and keep longer results unchanged. Cloud engines use a local small Whisper verifier, with no additional cloud upload; that verifier may download once (~465 MB). No language model is used for learning decisions.

Editing an automatic replacement or deleting its entry saves a persistent rejection. **Allow learning again** clears that rejection. Undo restores earlier evidence. Old saved aliases remain visible but paused until corrected in a new dictation; their original storage is retained for rollback. Learning skips fields whose paste, focus or text cannot be verified through Accessibility.

See [research, design decisions and validation](docs/learned-words-research.md). This is personalization around existing recognizers, not model training or a guarantee against homophone errors.

Run the isolated regression suite without downloading speech models:

```bash
scripts/test-corrections.sh
```

The suite uses temporary settings and simulated accessibility reads; it does not change your learned words or type into your apps.

> **First-run downloads (one-time, then cached, all local):** the Parakeet model (~600 MB) downloads on your first dictation. If you enable **Smart cleanup**, the Qwen model (~2 GB for 3B, ~1 GB for 1.5B) downloads on first use.

## Build from source without the committed project
The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen):
```bash
brew install xcodegen
xcodegen generate
```

## How it works
- Audio → 16 kHz mono → ASR engine (Parakeet or Whisper) → optional local-LLM cleanup → inserted/copied.
- Built with Swift + SwiftUI + AppKit. Dependencies: KeyboardShortcuts, WhisperKit, FluidAudio, DynamicNotchKit, LLM.swift.
