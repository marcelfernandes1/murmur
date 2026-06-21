import SwiftUI
import KeyboardShortcuts

/// A Settings category (also the deep-link target for the menu's History / Compare).
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, dictation, microphone, appearance, vocabulary, learned, history, comparison, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:    return "General"
        case .dictation:  return "Dictation"
        case .microphone: return "Microphone"
        case .appearance: return "Appearance"
        case .vocabulary: return "Vocabulary"
        case .learned:    return "Learned Words"
        case .history:    return "History"
        case .comparison: return "Cleanup Comparison"
        case .advanced:   return "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .dictation:  return "mic"
        case .microphone: return "waveform"
        case .appearance: return "paintpalette"
        case .vocabulary: return "character.book.closed"
        case .learned:    return "sparkles"
        case .history:    return "clock.arrow.circlepath"
        case .comparison: return "text.magnifyingglass"
        case .advanced:   return "slider.horizontal.3"
        }
    }
}

/// Holds the selected Settings category so the menu bar can deep-link into a
/// section (History / Comparison) of the single Settings window.
@MainActor
@Observable
final class SettingsRouter {
    var category: SettingsCategory = .general
}

/// Settings, organized System-Settings-style: a glass sidebar of categories on the
/// left, content on the right. History and the Cleanup Comparison live here too;
/// the technical knobs (model + smart cleanup) live under **Advanced**.
struct SettingsView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppState.self) private var appState
    @Environment(DictationController.self) private var dictation
    @Environment(VocabularyStore.self) private var vocabulary
    @Environment(CorrectionStore.self) private var corrections
    @Environment(SettingsRouter.self) private var router

    @State private var newTerm = ""
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var editingCorrectionID: LearnedCorrection.ID?
    @State private var editHeard = ""
    @State private var editCorrected = ""

    private let setupCats: [SettingsCategory] = [.general, .dictation, .microphone, .appearance]
    private let wordCats: [SettingsCategory] = [.vocabulary, .learned]
    private let libraryCats: [SettingsCategory] = [.history, .comparison]

    var body: some View {
        @Bindable var prefs = prefs
        @Bindable var router = router

        NavigationSplitView {
            List(selection: $router.category) {
                Section { forEach(setupCats) }
                Section("Words") { forEach(wordCats) }
                Section("Library") { forEach(libraryCats) }
                Section { forEach([.advanced]) }
            }
            .navigationSplitViewColumnWidth(min: 196, ideal: 196, max: 230)
            .scrollContentBackground(.hidden)
        } detail: {
            Group {
                switch router.category {
                case .history:
                    HistoryView()
                case .comparison:
                    CleanupComparisonView()
                default:
                    Form { formDetail(prefs: $prefs) }
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(router.category.title)
        }
        .frame(width: 760, height: 560)
        .liquidGlassWindow()
        .onChange(of: prefs.accentTheme) { dictation.applyAccent() }
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

    private func forEach(_ cats: [SettingsCategory]) -> some View {
        ForEach(cats) { cat in
            Label(cat.title, systemImage: cat.icon).tag(cat)
        }
    }

    // MARK: - Form detail routing

    @ViewBuilder
    private func formDetail(prefs: Bindable<Preferences>) -> some View {
        switch router.category {
        case .general:    generalDetail(prefs)
        case .dictation:  dictationDetail(prefs)
        case .microphone: microphoneDetail(prefs)
        case .appearance: appearanceDetail(prefs)
        case .vocabulary: vocabularyDetail()
        case .learned:    learnedDetail(prefs)
        case .advanced:   advancedDetail(prefs)
        default:          EmptyView()
        }
    }

    // MARK: General

    @ViewBuilder
    private func generalDetail(_ prefs: Bindable<Preferences>) -> some View {
        Section("Permissions") {
            permissionRow(
                title: "Microphone",
                detail: "Required to record your voice. Audio never leaves your Mac.",
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
        Section("Startup") {
            Toggle("Launch at login", isOn: prefs.launchAtLogin)
        }
    }

    // MARK: Dictation

    @ViewBuilder
    private func dictationDetail(_ prefs: Bindable<Preferences>) -> some View {
        Section {
            Toggle("Use 🌐 Fn key", isOn: prefs.fnTriggerEnabled)
            KeyboardShortcuts.Recorder("Shortcut 1", name: .dictation)
            KeyboardShortcuts.Recorder("Shortcut 2", name: .dictation2)
            KeyboardShortcuts.Recorder("Shortcut 3", name: .dictation3)
            LabeledContent("Single key") {
                SingleKeyRecorder(name: .dictationSingle) { dictation.applyTriggers() }
            }
        } header: {
            Text("Triggers")
        } footer: {
            Text("Click a box and press a key or combo. Combo boxes need a modifier (⌘/⌥/⌃); use “Single key” to bind one bare key. Hold a trigger to dictate; release to transcribe.")
        }

        Section {
            Toggle("Hands-free lock", isOn: prefs.handsFreeLock)
            Toggle("Sound effects", isOn: prefs.soundEffects)
        } header: {
            Text("Hands-free & feedback")
        } footer: {
            Text("With hands-free lock on, press Space while holding your trigger to keep recording without holding it — then tap the trigger again to insert. Sound effects play soft cues when recording starts, stops, and locks.")
        }

        Section("Language") {
            Picker("Spoken language", selection: prefs.language) {
                ForEach(Preferences.Language.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
        }

        Section {
            Toggle("Remove filler words (um, uh, erm…)", isOn: prefs.removeFillers)
            Toggle("Streaming (live preview while you talk)", isOn: prefs.streaming)
        } header: {
            Text("Transcript")
        } footer: {
            Text("Filler removal runs instantly. Streaming is experimental — it previews words in the notch as you speak (Parakeet only), best for longer dictations.")
        }
    }

    // MARK: Microphone

    @ViewBuilder
    private func microphoneDetail(_ prefs: Bindable<Preferences>) -> some View {
        Section {
            Picker("Input device", selection: prefs.inputDeviceUID) {
                Text("System Default").tag(String?.none)
                ForEach(inputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            Button("Refresh devices") { inputDevices = AudioDevices.inputDevices() }
        } header: {
            Text("Input")
        } footer: {
            Text("Which microphone Murmur records from. “System Default” follows System Settings ▸ Sound. If the waveform stays flat the mic is delivering silence — try a specific device, and confirm Murmur is enabled in System Settings ▸ Privacy & Security ▸ Microphone.")
        }
    }

    // MARK: Appearance

    @ViewBuilder
    private func appearanceDetail(_ prefs: Bindable<Preferences>) -> some View {
        Section {
            LabeledContent("Waveform color") {
                HStack(spacing: Spacing.md) {
                    ForEach(AccentTheme.allCases) { theme in
                        swatch(theme)
                    }
                }
            }
        } header: {
            Text("Waveform")
        } footer: {
            Text("Accent for the live waveform — bright on the dark notch, deeper on light backgrounds. Vivid blue by default; White and Graphite are the monochrome options.")
        }
    }

    private func swatch(_ theme: AccentTheme) -> some View {
        Circle()
            .fill(theme.swatch)
            .frame(width: 22, height: 22)
            .overlay { Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5) }
            .overlay {
                if prefs.accentTheme == theme {
                    Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-4)
                }
            }
            .contentShape(Circle())
            .onTapGesture { prefs.accentTheme = theme }
            .help(theme.displayName)
            .accessibilityLabel(theme.displayName)
            .accessibilityAddTraits(prefs.accentTheme == theme ? [.isSelected] : [])
    }

    // MARK: Vocabulary

    @ViewBuilder
    private func vocabularyDetail() -> some View {
        Section {
            HStack {
                TextField("Add a name, term, or acronym", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Custom vocabulary")
        } footer: {
            Text("Add words Whisper often gets wrong — names, jargon, acronyms — to nudge it toward them.")
        }

        if !vocabulary.terms.isEmpty {
            Section {
                ForEach(vocabulary.terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button { vocabulary.remove(term) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Learned words

    @ViewBuilder
    private func learnedDetail(_ prefs: Bindable<Preferences>) -> some View {
        Section {
            Toggle("Learn corrections when I edit dictated text", isOn: prefs.autoLearnFromEdits)
        } header: {
            Text("Auto-learn")
        } footer: {
            Text("When you fix a name, acronym, or term in text Murmur typed, it remembers the correction and applies it next time. Needs Accessibility. Only names/acronyms/jargon that sound like what was heard are learned.")
        }

        Section("Learned") {
            if corrections.corrections.isEmpty {
                Text("Nothing learned yet. Edit a word Murmur got wrong and it'll show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(corrections.corrections) { correction in
                    correctionRow(correction)
                }
            }
        }
    }

    @ViewBuilder
    private func correctionRow(_ correction: LearnedCorrection) -> some View {
        if editingCorrectionID == correction.id {
            HStack(spacing: 6) {
                TextField("Heard", text: $editHeard)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit(correction) }
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
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
                Text(correction.heard).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(correction.corrected)
                Spacer()
                Button { startEditing(correction) } label: {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button { corrections.remove(correction) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private func advancedDetail(_ prefs: Bindable<Preferences>) -> some View {
        Section {
            Picker("Model", selection: prefs.model) {
                ForEach(Preferences.ModelChoice.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            LabeledContent("Status") {
                StatusChip(kind: phaseKind(appState.modelPhase), label: modelStatus)
            }
        } header: {
            Text("Speech model")
        } footer: {
            Text("Runs on-device. Switching models downloads the new one on first use — the larger whisper.cpp models are 1–3 GB, so the first run can take a while. whisper.cpp models run on the GPU (Metal); WhisperKit models use the Neural Engine.")
        }

        Section {
            Toggle("Polish transcripts with an on-device model", isOn: prefs.smartCleanup)
            if prefs.wrappedValue.smartCleanup {
                Picker("Cleanup model", selection: prefs.cleanupModel) {
                    ForEach(Preferences.CleanupModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                LabeledContent("Status") {
                    StatusChip(kind: phaseKind(appState.cleanupPhase), label: cleanupStatus)
                }
            }
        } header: {
            Text("Smart cleanup")
        } footer: {
            Text("Resolves self-corrections, turns spoken numbers into digits, and fixes punctuation — verbatim-first, fully offline. The Qwen models download once. See Cleanup Comparison in the menu to audit changes.")
        }
    }

    // MARK: - Status helpers

    private func phaseKind(_ phase: AppState.ModelPhase) -> StatusKind {
        switch phase {
        case .ready:     return .success
        case .failed:    return .error
        case .preparing: return .working
        case .idle:      return .neutral
        }
    }

    private var cleanupStatus: String { statusText(appState.cleanupPhase) }
    private var modelStatus: String { statusText(appState.modelPhase) }

    private func statusText(_ phase: AppState.ModelPhase) -> String {
        switch phase {
        case .idle: return "Idle"
        case .preparing:
            if let progress = appState.modelDownloadProgress {
                return "Downloading… \(Int(progress * 100))%"
            }
            return "Preparing…"
        case .ready: return "Ready"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    // MARK: - Actions

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
                        .foregroundStyle(granted ? Palette.success : Palette.warning)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                StatusChip(kind: .success, label: "Granted")
            } else {
                Button(actionLabel, action: action)
            }
        }
    }
}
