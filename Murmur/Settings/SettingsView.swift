import SwiftUI
import KeyboardShortcuts

/// Settings + first-run onboarding: permissions, triggers, language/model,
/// streaming, custom vocabulary, and general options.
struct SettingsView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppState.self) private var appState
    @Environment(DictationController.self) private var dictation
    @Environment(VocabularyStore.self) private var vocabulary
    @Environment(CorrectionStore.self) private var corrections

    @State private var newTerm = ""
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var editingCorrectionID: LearnedCorrection.ID?
    @State private var editHeard = ""
    @State private var editCorrected = ""

    var body: some View {
        @Bindable var prefs = prefs

        Form {
            Section("Permissions") {
                permissionRow(
                    title: "Microphone",
                    detail: "Required to record your voice.",
                    granted: appState.micEnabled,
                    actionLabel: "Request",
                    action: { dictation.requestMicrophone() }
                )
                permissionRow(
                    title: "Accessibility",
                    detail: "Lets Murmur type into the focused app and use the Fn key.",
                    granted: appState.accessibilityEnabled,
                    actionLabel: "Open Settings",
                    action: { dictation.enableAccessibility() }
                )
            }

            Section("Microphone") {
                Picker("Input device", selection: $prefs.inputDeviceUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Button("Refresh devices") { inputDevices = AudioDevices.inputDevices() }
                Text("Which microphone Murmur records from. “System Default” follows System Settings ▸ Sound. If the waveform stays flat, the mic is delivering silence — try a specific device here, and confirm Murmur is enabled in System Settings ▸ Privacy & Security ▸ Microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Triggers") {
                Toggle("Use 🌐 Fn key", isOn: $prefs.fnTriggerEnabled)
                KeyboardShortcuts.Recorder("Shortcut 1", name: .dictation)
                KeyboardShortcuts.Recorder("Shortcut 2", name: .dictation2)
                KeyboardShortcuts.Recorder("Shortcut 3", name: .dictation3)
                LabeledContent("Single key") {
                    SingleKeyRecorder(name: .dictationSingle) { dictation.applyTriggers() }
                }
                Text("Click a box and press a key or combo. The combo boxes need a modifier (⌘/⌥/⌃); use “Single key” to bind one bare key — no modifier needed. A single key is captured globally and won't type, so pick one you don't otherwise use (a function key is ideal). Hold any trigger to dictate; release to transcribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Language", selection: $prefs.language) {
                    ForEach(Preferences.Language.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }

                Picker("Model", selection: $prefs.model) {
                    ForEach(Preferences.ModelChoice.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                LabeledContent("Status") {
                    Text(modelStatus).foregroundStyle(modelStatusColor)
                }
                Text("Switching models downloads the new one on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remove filler words (um, uh, erm…)", isOn: $prefs.removeFillers)
                Text("Runs instantly and always. With smart cleanup on, fillers are stripped before the model sees the text, so it can't leave any behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Streaming (live preview while you talk)", isOn: $prefs.streaming)
                Text("Experimental: transcribes as you speak and previews it in the notch (Parakeet only). Best for longer dictations; may not speed up short ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Smart cleanup (on-device LLM)") {
                Toggle("Polish transcripts with an on-device model", isOn: $prefs.smartCleanup)
                if prefs.smartCleanup {
                    Picker("Cleanup model", selection: $prefs.cleanupModel) {
                        ForEach(Preferences.CleanupModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    LabeledContent("Status") {
                        Text(cleanupStatus).foregroundStyle(cleanupStatusColor)
                    }
                }
                Text("Resolves self-corrections, turns spoken numbers into digits, and fixes punctuation — verbatim-first, so it keeps your exact words. Fully offline. Apple Intelligence runs on the Neural Engine with no download (macOS 26+); the Qwen models use llama.cpp and download once. See Cleanup Comparison in the menu to audit what it changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom vocabulary") {
                HStack {
                    TextField("Add a name, term, or acronym", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if vocabulary.terms.isEmpty {
                    Text("Add words Whisper often gets wrong — names, jargon, acronyms — to nudge it toward them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vocabulary.terms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button { vocabulary.remove(term) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Section("Learned words") {
                Toggle("Learn corrections when I edit dictated text", isOn: $prefs.autoLearnFromEdits)
                Text("When you fix a name, acronym, or term in text Murmur typed, it remembers the correction and applies it next time — and flashes “Learned …”. Needs Accessibility. Only names/acronyms/jargon that sound like what was heard are learned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if corrections.corrections.isEmpty {
                    Text("Nothing learned yet. Edit a word Murmur got wrong and it'll show up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(corrections.corrections) { correction in
                        if editingCorrectionID == correction.id {
                            HStack(spacing: 6) {
                                TextField("Heard", text: $editHeard)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { commitEdit(correction) }
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("Corrected", text: $editCorrected)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { commitEdit(correction) }
                                Button("Save") { commitEdit(correction) }
                                    .disabled(
                                        editHeard.trimmingCharacters(in: .whitespaces).isEmpty
                                            || editCorrected.trimmingCharacters(in: .whitespaces).isEmpty
                                    )
                                Button("Cancel") { editingCorrectionID = nil }
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(correction.heard)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(correction.corrected)
                                Spacer()
                                Button { startEditing(correction) } label: {
                                    Image(systemName: "pencil")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                Button { corrections.remove(correction) } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
        .onChange(of: prefs.fnTriggerEnabled) { dictation.applyTriggers() }
        .onChange(of: prefs.model) { dictation.applyModel() }
        .onChange(of: prefs.smartCleanup) { dictation.applyCleanup() }
        .onChange(of: prefs.cleanupModel) { dictation.applyCleanup() }
        .onChange(of: prefs.inputDeviceUID) { dictation.applyInputDevice() }
        .onAppear {
            dictation.refreshPermissions()
            inputDevices = AudioDevices.inputDevices()
        }
    }

    private var cleanupStatus: String {
        switch appState.cleanupPhase {
        case .idle: return "Idle"
        case .preparing: return "Preparing… (first use downloads the model)"
        case .ready: return "Ready"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var cleanupStatusColor: Color {
        switch appState.cleanupPhase {
        case .ready: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var modelStatus: String {
        switch appState.modelPhase {
        case .idle: return "Idle"
        case .preparing: return "Preparing… (first use downloads the model)"
        case .ready: return "Ready"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var modelStatusColor: Color {
        switch appState.modelPhase {
        case .ready: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private func addTerm() {
        vocabulary.add(newTerm)
        newTerm = ""
    }

    private func startEditing(_ correction: LearnedCorrection) {
        editingCorrectionID = correction.id
        editHeard = correction.heard
        editCorrected = correction.corrected
    }

    private func commitEdit(_ correction: LearnedCorrection) {
        corrections.update(correction, heard: editHeard, corrected: editCorrected)
        editingCorrectionID = nil
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(granted ? Color.green : Color.orange)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button(actionLabel, action: action)
            }
        }
    }
}
