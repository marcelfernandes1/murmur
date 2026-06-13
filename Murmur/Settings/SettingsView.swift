import SwiftUI
import KeyboardShortcuts

/// Settings + first-run onboarding: permissions, triggers, language/model,
/// streaming, custom vocabulary, and general options.
struct SettingsView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppState.self) private var appState
    @Environment(DictationController.self) private var dictation
    @Environment(VocabularyStore.self) private var vocabulary

    @State private var newTerm = ""

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

            Section("Triggers") {
                Toggle("Use 🌐 Fn key", isOn: $prefs.fnTriggerEnabled)
                KeyboardShortcuts.Recorder("Shortcut 1", name: .dictation)
                KeyboardShortcuts.Recorder("Shortcut 2", name: .dictation2)
                KeyboardShortcuts.Recorder("Shortcut 3", name: .dictation3)
                Text("Click a box and press a key or combo. Hold any trigger to dictate; release to transcribe.")
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
                    .disabled(prefs.smartCleanup)

                Toggle("Streaming (live preview while you talk)", isOn: $prefs.streaming)
                Text("Experimental: transcribes as you speak and previews it in the notch. Best for longer dictations; may not speed up short ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Smart cleanup (local LLM)") {
                Toggle("Polish transcripts with a local LLM", isOn: $prefs.smartCleanup)
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
                Text("Runs a local Llama-style model (llama.cpp / Metal GPU) to remove fillers + false starts, turn spoken numbers into digits, and fix punctuation — like Wispr Flow, fully offline. Adds ~0.3–1 s and downloads the model once.")
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
        .onAppear { dictation.refreshPermissions() }
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
